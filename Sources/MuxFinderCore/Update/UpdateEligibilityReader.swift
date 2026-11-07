import Darwin
import Foundation
import Security

/// Reads a signature for eligibility (PLAN.md D39, I-13b2): whether it satisfies the Developer
/// ID requirement (`UpdateCodeRequirement.developerIDClause`: Apple's anchor, the Developer ID
/// intermediate marker and the Developer ID Application leaf marker), and its Team ID from
/// `SecCodeCopySigningInformation` (`kSecCodeInfoTeamIdentifier`), kept only as a well-formed
/// `UpdateTeamID`. Never the revocation-check flag or the one that lets trust evaluation use
/// the network. Unsigned code, an ad hoc signature and a development certificate all read as
/// "not Developer ID".
public enum UpdateSigningReader {
  /// The running process's own signature (`SecCodeCopySelf`, checked with
  /// `SecCodeCheckValidityWithErrors` and default flags).
  public static func readSelf() -> UpdateSigningReading {
    var created: SecCode?
    let status = SecCodeCopySelf([], &created)
    guard status == errSecSuccess, let code = created else {
      return .unreadable(status: status)
    }
    var staticCreated: SecStaticCode?
    let staticStatus = SecCodeCopyStaticCode(code, [], &staticCreated)
    guard staticStatus == errSecSuccess, let staticCode = staticCreated else {
      return .unreadable(status: staticStatus)
    }
    guard let requirement = developerIDRequirement() else {
      return .unreadable(status: errSecCSReqInvalid)
    }
    var error: Unmanaged<CFError>?
    let validity = SecCodeCheckValidityWithErrors(code, [], requirement, &error)
    error?.release()
    return reading(validity: validity, staticCode: staticCode)
  } // End of static func readSelf()

  /// The signature of the bundle (or other code) at `path`, read from disk
  /// (`SecStaticCodeCreateWithPath`, checked with `SecStaticCodeCheckValidityWithErrors` and
  /// `SecurityUpdateCodeChecker.validityFlags`). Tests and the real check on a release copy use
  /// it; the app reads its own with `readSelf()`.
  public static func read(bundleAt path: String) -> UpdateSigningReading {
    var created: SecStaticCode?
    let status = SecStaticCodeCreateWithPath(
      URL(fileURLWithPath: path, isDirectory: true) as CFURL, [], &created)
    guard status == errSecSuccess, let staticCode = created else {
      return .unreadable(status: status)
    }
    guard let requirement = developerIDRequirement() else {
      return .unreadable(status: errSecCSReqInvalid)
    }
    var error: Unmanaged<CFError>?
    let validity = SecStaticCodeCheckValidityWithErrors(
      staticCode, SecurityUpdateCodeChecker.validityFlags, requirement, &error)
    error?.release()
    return reading(validity: validity, staticCode: staticCode)
  } // End of static func read(bundleAt:)

  /// The compiled Developer ID requirement.
  static func developerIDRequirement() -> SecRequirement? {
    var requirement: SecRequirement?
    let status = SecRequirementCreateWithString(
      UpdateCodeRequirement.developerIDClause as CFString, [], &requirement)
    return status == errSecSuccess ? requirement : nil
  }

  /// The reading from a validity check's `validity` and the code's signing information: a
  /// passed check is Developer ID, a failed requirement or no signature is not, anything else
  /// is unreadable.
  static func reading(validity: OSStatus, staticCode: SecStaticCode) -> UpdateSigningReading {
    let isDeveloperID: Bool
    switch validity {
    case errSecSuccess: isDeveloperID = true
    case errSecCSReqFailed, errSecCSUnsigned: isDeveloperID = false
    default: return .unreadable(status: validity)
    }
    return .read(isDeveloperID: isDeveloperID, team: teamID(of: staticCode))
  }

  /// The Team ID in `staticCode`'s signing information, when it is a well-formed
  /// `UpdateTeamID`.
  static func teamID(of staticCode: SecStaticCode) -> UpdateTeamID? {
    var information: CFDictionary?
    let status = SecCodeCopySigningInformation(
      staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information)
    guard status == errSecSuccess, let information = information as? [String: Any],
      let text = information[kSecCodeInfoTeamIdentifier as String] as? String
    else { return nil }
    return UpdateTeamID(text)
  }
}

/// Reads the facts about the running app's bundle folder (PLAN.md D39, I-13b2), read-only:
/// the path walked with `lstat` (no symbolic link on it, every component a folder), the
/// bundle opened without following a link and its identity, owner and volume read through
/// that descriptor, `Contents/Info.plist` read through it (`CFBundleIdentifier`
/// `cc.carpio.muxfinder`, the versions), the running executable required to be the bundle's
/// main executable (the same device and inode as `Contents/MacOS/<CFBundleExecutable>`, opened
/// without following a link), App Translocation (a path component `AppTranslocation`; the SDK
/// has no public call for it), write access to the bundle and its parent (`faccessat` with
/// the effective ids), and a bundle that is a mount point refused.
public enum UpdateInstalledBundleReader {
  /// The path component App Translocation puts in a translocated app's path.
  public static let translocationComponent = "AppTranslocation"

  /// The running app's bundle (`Bundle.main.bundleURL`) and executable (the kernel's path
  /// for this process, `proc_pidpath`).
  public static func readMain() -> UpdateInstalledBundleFacts {
    let executable = SystemProcessTable.executablePath(getpid())
    return read(
      bundlePath: PrivateStorage.path(of: Bundle.main.bundleURL), executablePath: executable)
  }

  /// The facts about the bundle at `bundlePath` whose running executable is at
  /// `executablePath` (`nil` when it could not be read).
  public static func read(bundlePath: String, executablePath: String?) -> UpdateInstalledBundleFacts
  {
    read(bundlePath: bundlePath, executablePath: executablePath, owner: geteuid())
  }

  /// The designated reader; tests pass another `owner`.
  static func read(bundlePath: String, executablePath: String?, owner: uid_t)
    -> UpdateInstalledBundleFacts
  {
    var facts = UpdateInstalledBundleFacts(path: bundlePath)
    facts.isTranslocated =
      isTranslocated(bundlePath) || executablePath.map(isTranslocated) == true
    let parentDevice: Int64
    switch walk(bundlePath) {
    case .failure(let problem):
      facts.problem = problem
      return facts
    case .success(let device): parentDevice = device
    }
    let descriptor = open(bundlePath, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      facts.problem = code == ELOOP ? .symbolicLinkOnPath : .unreadable(errno: code)
      return facts
    }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      facts.problem = .unreadable(errno: errno)
      return facts
    }
    facts.identity = UpdateBundleIdentity(info)
    facts.isOwnedByUser = info.st_uid == owner
    var volume = statfs()
    if fstatfs(descriptor, &volume) == 0 {
      facts.isReadOnlyVolume = volume.f_flags & UInt32(MNT_RDONLY) != 0
    }
    facts.isBundleWritable = faccessat(AT_FDCWD, bundlePath, W_OK, AT_EACCESS) == 0
    facts.isParentWritable = faccessat(AT_FDCWD, parentPath(of: bundlePath), W_OK, AT_EACCESS) == 0
    facts.problem = checkContents(descriptor, executablePath: executablePath, facts: &facts)
    if facts.problem == nil, Int64(info.st_dev) != parentDevice { facts.problem = .mountPoint }
    return facts
  } // End of static func read(bundlePath:executablePath:owner:)

  /// Reads `Contents/Info.plist` through the open bundle `descriptor` (the identifier and
  /// versions into `facts`) and checks that the running executable is its main executable;
  /// the problem, or `nil`.
  static func checkContents(
    _ descriptor: Int32, executablePath: String?, facts: inout UpdateInstalledBundleFacts
  ) -> UpdateInstalledBundleProblem? {
    guard let info = UpdateBundleVersions.readInfo(app: descriptor) else { return .infoUnreadable }
    guard info["CFBundleIdentifier"] as? String == UpdateSource.bundleIdentifier else {
      return .identifierMismatch
    }
    facts.shortVersion = info["CFBundleShortVersionString"] as? String
    facts.build = info["CFBundleVersion"] as? String
    guard let name = info["CFBundleExecutable"] as? String, isPlainName(name),
      let executablePath, let main = executableIdentity(name, in: descriptor)
    else { return .executableOutside }
    var running = stat()
    guard stat(executablePath, &running) == 0, UpdateBundleIdentity(running) == main else {
      return .executableOutside
    }
    return nil
  } // End of static func checkContents(_:executablePath:facts:)

  /// The identity of the regular file `Contents/MacOS/<name>` below the open bundle folder,
  /// every step opened without following a link.
  static func executableIdentity(_ name: String, in bundle: Int32) -> UpdateBundleIdentity? {
    let contents = openat(bundle, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard contents >= 0 else { return nil }
    defer { Darwin.close(contents) }
    let macOS = openat(contents, "MacOS", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard macOS >= 0 else { return nil }
    defer { Darwin.close(macOS) }
    var info = stat()
    guard fstatat(macOS, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFREG
    else { return nil }
    return UpdateBundleIdentity(info)
  } // End of static func executableIdentity(_:in:)

  /// Whether `path` has a component `AppTranslocation`.
  public static func isTranslocated(_ path: String) -> Bool {
    path.split(separator: "/").contains { $0 == translocationComponent }
  }

  /// Whether `name` is one plain file name (not empty, `.` or `..`, no `/` or NUL).
  static func isPlainName(_ name: String) -> Bool {
    !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
  }

  /// The folder `path` is in (`/` for a top-level entry).
  static func parentPath(of path: String) -> String {
    guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
    return String(path[..<slash])
  }

  /// Walks the plain absolute `path` with `lstat`: every component must exist and be a folder
  /// (no symbolic link). Returns the device of the folder the last component is in.
  static func walk(_ path: String) -> Result<Int64, UpdateInstalledBundleProblem> {
    guard let components = UpdateStagingRoot.plainComponents(of: path), components.count >= 2,
      path == "/" + components.joined(separator: "/")
    else { return .failure(.notAPlainAbsolutePath) }
    var current = ""
    var parentDevice: Int64 = 0
    var info = stat()
    for (index, component) in components.enumerated() {
      if index == components.count - 1 { parentDevice = Int64(info.st_dev) }
      current += "/" + component
      guard lstat(current, &info) == 0 else {
        return .failure(errno == ENOENT ? .missing : .unreadable(errno: errno))
      }
      if info.st_mode & S_IFMT == S_IFLNK { return .failure(.symbolicLinkOnPath) }
      guard info.st_mode & S_IFMT == S_IFDIR else { return .failure(.notAFolder) }
    } // End of loop over the path's components
    return .success(parentDevice)
  } // End of static func walk(_:)
}

/// Gathers `UpdateEligibilityFacts` read-only (PLAN.md D39, I-13b2): the signature, the bundle
/// folder and the update folder. It creates and writes nothing.
public enum UpdateEligibilityReader {
  /// The running app's facts: its own signature (`SecCodeCopySelf`), `Bundle.main`'s folder
  /// with this process's executable, and `root` looked at without creating it.
  public static func current(root: UpdateStagingRoot) -> UpdateEligibilityFacts {
    UpdateEligibilityFacts(
      signing: UpdateSigningReader.readSelf(), bundle: UpdateInstalledBundleReader.readMain(),
      stagingRoot: root.inspect())
  }

  /// The facts of the bundle at `bundlePath` running `executablePath`, with `signing` read by
  /// the caller (tests pass a reading for an unsigned stub).
  public static func facts(
    bundlePath: String, executablePath: String?, signing: UpdateSigningReading,
    root: UpdateStagingRoot
  ) -> UpdateEligibilityFacts {
    UpdateEligibilityFacts(
      signing: signing,
      bundle: UpdateInstalledBundleReader.read(
        bundlePath: bundlePath, executablePath: executablePath),
      stagingRoot: root.inspect())
  }
}
