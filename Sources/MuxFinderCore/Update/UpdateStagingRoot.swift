import Darwin
import Foundation
import os

/// Why the update folder or a run folder in it could not be made ready (PLAN.md D39,
/// I-13b2). Nothing is written in a refused folder.
public enum UpdateStagingRootError: Error, Sendable, Hashable {
  /// The update folder, or a folder on its path, cannot be used (or created).
  case root(UpdateStagingProblem)
  /// Another muxFinder process held the update folder's lock for the whole wait.
  case busy
  /// The update folder's lock file cannot be used.
  case lockUnavailable
  /// The update folder is on another volume than the installed app.
  case differentVolume
  /// The run folder could not be created or secured (this errno).
  case runFolderNotCreated(errno: Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .root(let problem): return "root.\(problem.code)"
    case .busy: return "busy"
    case .lockUnavailable: return "lockUnavailable"
    case .differentVolume: return "differentVolume"
    case .runFolderNotCreated(let code): return "runFolderNotCreated.\(code)"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .root, .lockUnavailable, .runFolderNotCreated:
      return "muxFinder's update folder can't be used"
    case .busy: return "another update is running"
    case .differentVolume: return "this copy is on another disk than muxFinder's update folder"
    }
  }
}

/// The update folder, `~/Library/Application Support/muxFinder/update/` (PLAN.md D39, I-13b2):
/// the app owns only its support folder (and `DynamicProfiles/muxFinder.json`), so the update
/// works there, never beside the installed bundle. It must be on the installed bundle's
/// volume, so the swap is a rename.
///
/// - `inspect()` only looks (`lstat` along the path, then `UpdateStagingFolder`'s checks); it
///   never creates anything, so eligibility writes nothing.
/// - `prepare()` creates it when an update starts (0700, its ACL removed; the support folder
///   above it 0700 too when missing), and refuses it when it is a symbolic link, not a folder,
///   another user's, not private or with an extended ACL.
/// - `makeRunFolder(onDevice:)` creates one fresh, uniquely named 0700 run folder in it
///   (`run-` and 16 hex digits), I-13b1's staging folder, with a lock file (`run.lock`) held
///   while the update runs; the update folder's own lock (`update.lock`) is held only while
///   the run folder is created, so a cleanup in another process never sees it half made.
/// - `cleanLeftovers(processes:)` (at launch) deletes each run folder no live update holds, no
///   rollback marked for recovery and, by a complete process scan made after its lock was
///   taken, no process runs from.
public struct UpdateStagingRoot: Sendable, Hashable {
  /// The update folder's name in muxFinder's support folder.
  public static let folderName = "update"
  /// The update folder's lock file.
  public static let lockName = "update.lock"
  /// Each run folder's lock file.
  public static let runLockName = "run.lock"
  /// The marker a rollback that required recovery leaves in its run folder (an empty file,
  /// created exclusively): the cleanup never deletes a run folder holding an entry by this
  /// name.
  public static let recoveryMarkerName = "recovery-required"
  /// The start of every run folder's name.
  public static let runPrefix = "run-"
  /// How long a run folder's creation or a cleanup waits for the update folder's lock.
  static let lockWait = Duration.seconds(10)

  /// The update folder's absolute path.
  public let path: String

  /// The update folder at `path` (absolute; tests pass private folders under `/private/tmp`
  /// or `/private/var/folders`).
  public init(path: String) {
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    self.path = trimmed
  }

  /// The real update folder, `~/Library/Application Support/muxFinder/update`. Nothing is
  /// created.
  public static var standard: UpdateStagingRoot {
    UpdateStagingRoot(
      path: PrivateStorage.path(of: AppPaths.standard.applicationSupportDirectory) + "/"
        + folderName)
  }

  /// The components of the plain absolute `path` (no empty, `.` or `..` component), or `nil`.
  static func plainComponents(of path: String) -> [String]? {
    guard path.hasPrefix("/") else { return nil }
    let components = path.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    guard !components.isEmpty,
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { return nil }
    return components.map(String.init)
  }

  /// Whether `name` is a run folder's name: `run-` and 16 lowercase hex digits.
  public static func isRunFolderName(_ name: String) -> Bool {
    guard name.hasPrefix(runPrefix) else { return false }
    let digits = name.utf8.dropFirst(runPrefix.utf8.count)
    return digits.count == 16
      && digits.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
  }

  /// A new run folder name.
  static func newRunFolderName() -> String {
    let digits = String(UInt64.random(in: .min ... .max), radix: 16)
    return runPrefix + String(repeating: "0", count: 16 - digits.count) + digits
  }

  // MARK: - Looking

  /// Looks at the update folder without creating or changing anything (see the type).
  public func inspect() -> UpdateStagingRootState {
    inspect(owner: geteuid())
  }

  /// `inspect()`; tests pass another `owner`.
  func inspect(owner: uid_t) -> UpdateStagingRootState {
    guard let components = Self.plainComponents(of: path) else {
      return .unusable(.notAPlainAbsolutePath)
    }
    var info = stat()
    guard lstat("/", &info) == 0 else {
      return .unusable(.systemCallFailed(name: "lstat", errno: errno))
    }
    var device = Int64(info.st_dev)
    var current = ""
    for component in components {
      current += "/" + component
      guard lstat(current, &info) == 0 else {
        let code = errno
        if code == ENOENT { return .missing(device: device) }
        return .unusable(.systemCallFailed(name: "lstat", errno: code))
      }
      if info.st_mode & S_IFMT == S_IFLNK { return .unusable(.symbolicLinkOnPath) }
      guard info.st_mode & S_IFMT == S_IFDIR else { return .unusable(.notADirectory) }
      device = Int64(info.st_dev)
    } // End of loop over the path's components
    do throws(UpdateStagingProblem) {
      let folder = try UpdateStagingFolder(path: path, owner: owner)
      return .usable(device: Int64(folder.device))
    } catch {
      return .unusable(error)
    }
  } // End of func inspect(owner:)

  // MARK: - Creating

  /// Creates the update folder when it is missing (see the type) and returns it checked.
  public func prepare() throws(UpdateStagingRootError) -> UpdateStagingFolder {
    try prepare(owner: geteuid())
  }

  /// `prepare()`; tests pass another `owner`.
  func prepare(owner: uid_t) throws(UpdateStagingRootError) -> UpdateStagingFolder {
    switch inspect(owner: owner) {
    case .unusable(let problem): throw .root(problem)
    case .usable: break
    case .missing:
      let parent = UpdateInstalledBundleReader.parentPath(of: path)
      var info = stat()
      if lstat(parent, &info) != 0 {
        guard errno == ENOENT else { throw .root(.systemCallFailed(name: "lstat", errno: errno)) }
        guard mkdir(parent, PrivateStorage.directoryPermissions) == 0 || errno == EEXIST else {
          throw .root(errno == ENOENT ? .missing : .systemCallFailed(name: "mkdir", errno: errno))
        }
      }
      try createRoot()
    }
    do throws(UpdateStagingProblem) {
      return try UpdateStagingFolder(path: path, owner: owner)
    } catch {
      throw .root(error)
    }
  } // End of func prepare(owner:)

  /// Creates the update folder itself (0700, its ACL removed); one that appeared meanwhile is
  /// left as it is for the checks.
  func createRoot() throws(UpdateStagingRootError) {
    guard mkdir(path, PrivateStorage.directoryPermissions) == 0 else {
      let code = errno
      if code == EEXIST { return }
      throw .root(code == ENOENT ? .missing : .systemCallFailed(name: "mkdir", errno: code))
    }
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else { throw .root(.systemCallFailed(name: "open", errno: errno)) }
    defer { Darwin.close(descriptor) }
    guard fchmod(descriptor, PrivateStorage.directoryPermissions) == 0 else {
      throw .root(.systemCallFailed(name: "fchmod", errno: errno))
    }
    do throws(PrivateStorageError) {
      try ExtendedACL.removeAll(from: descriptor)
    } catch {
      throw .root(.notPrivate)
    }
  } // End of func createRoot()

  /// Creates the update folder when needed and one fresh run folder in it, locked, after
  /// checking that the update folder is on `device` (the installed bundle's; `nil` skips it).
  public func makeRunFolder(onDevice device: Int64?) throws(UpdateStagingRootError)
    -> UpdateRunFolder
  {
    try makeRunFolder(onDevice: device, owner: geteuid())
  }

  /// `makeRunFolder(onDevice:)`; tests pass another `owner`.
  func makeRunFolder(onDevice device: Int64?, owner: uid_t) throws(UpdateStagingRootError)
    -> UpdateRunFolder
  {
    let root = try prepare(owner: owner)
    if let device, Int64(root.device) != device { throw .differentVolume }
    let rootDescriptor: Int32
    do throws(UpdateStagingProblem) {
      rootDescriptor = try root.openDirectory()
    } catch {
      throw .root(error)
    }
    defer { Darwin.close(rootDescriptor) }
    let rootLock = try Self.lock(in: rootDescriptor, owner: owner)
    defer { Darwin.close(rootLock) }
    for _ in 0..<8 {
      let name = Self.newRunFolderName()
      guard mkdirat(rootDescriptor, name, PrivateStorage.directoryPermissions) == 0 else {
        if errno == EEXIST { continue }
        throw .runFolderNotCreated(errno: errno)
      }
      do throws(UpdateStagingRootError) {
        let lock = try Self.secureRunFolder(name, in: rootDescriptor, owner: owner)
        do throws(UpdateStagingProblem) {
          let staging = try UpdateStagingFolder(path: root.path(of: name), owner: owner)
          return UpdateRunFolder(name: name, staging: staging, root: root, lock: lock)
        } catch {
          Darwin.close(lock)
          throw UpdateStagingRootError.root(error)
        }
      } catch {
        _ = UpdateStagingFolder.removeEntry(name, in: rootDescriptor, owner: owner, depth: 0)
        throw error
      }
    } // End of loop over run folder names
    throw .runFolderNotCreated(errno: EEXIST)
  } // End of func makeRunFolder(onDevice:owner:)

  /// Takes the update folder's lock in the open folder `descriptor`, waiting at most `wait`;
  /// closing the returned descriptor releases it.
  static func lock(in descriptor: Int32, owner: uid_t, wait: Duration = lockWait)
    throws(UpdateStagingRootError) -> Int32
  {
    do throws(PrivateStorageLockError) {
      return try PrivateStorage.acquireLock(
        named: lockName, in: descriptor, owner: owner, wait: wait)
    } catch {
      throw error == .busy ? .busy : .lockUnavailable
    }
  }

  /// Makes the new run folder `name` 0700 with no ACL and takes its lock; returns the lock's
  /// descriptor.
  static func secureRunFolder(_ name: String, in root: Int32, owner: uid_t)
    throws(UpdateStagingRootError) -> Int32
  {
    let folder = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard folder >= 0 else { throw .runFolderNotCreated(errno: errno) }
    defer { Darwin.close(folder) }
    guard fchmod(folder, PrivateStorage.directoryPermissions) == 0 else {
      throw .runFolderNotCreated(errno: errno)
    }
    do throws(PrivateStorageError) {
      try ExtendedACL.removeAll(from: folder)
    } catch {
      throw .runFolderNotCreated(errno: PrivateStorage.posixCode(of: error))
    }
    do throws(PrivateStorageLockError) {
      return try PrivateStorage.acquireLock(
        named: runLockName, in: folder, owner: owner, wait: .zero)
    } catch {
      throw .runFolderNotCreated(errno: EAGAIN)
    }
  } // End of static func secureRunFolder(_:in:owner:)

  // MARK: - Cleaning up

  /// Deletes the update folder's leftover run folders (see `UpdateLeftoverCleanup`).
  public func cleanLeftovers(
    processes: any UpdateProcessListing = SystemUpdateProcessListing()
  ) -> UpdateCleanupReport {
    UpdateLeftoverCleanup(root: self, owner: geteuid(), processes: processes).run()
  }
}

/// One update's run folder (PLAN.md D39, I-13b2): I-13b1's staging folder, inside the update
/// folder, with its `run.lock` held from its creation until `release()` or `remove()` (or the
/// object's end), so a cleanup leaves it alone while the update runs.
public final class UpdateRunFolder: Sendable {
  /// The folder's name in the update folder.
  public let name: String
  /// The folder, checked, for I-13b1's steps.
  public let staging: UpdateStagingFolder
  /// The update folder.
  let root: UpdateStagingFolder
  /// The lock's descriptor, `-1` once released.
  private let lock: OSAllocatedUnfairLock<Int32>

  /// A run folder whose lock is held through `lock`.
  init(name: String, staging: UpdateStagingFolder, root: UpdateStagingFolder, lock: Int32) {
    self.name = name
    self.staging = staging
    self.root = root
    self.lock = OSAllocatedUnfairLock(initialState: lock)
  }

  /// Releases the lock if it is still held.
  deinit {
    release()
  }

  /// The folder's absolute path.
  public var path: String { staging.path }

  /// Whether the lock is still held.
  public var isLocked: Bool { lock.withLock { $0 >= 0 } }

  /// Releases the lock (the folder stays, for the cleanup at a later launch).
  public func release() {
    lock.withLock { descriptor in
      if descriptor >= 0 { Darwin.close(descriptor) }
      descriptor = -1
    }
  }

  /// Deletes the folder and everything in it (never following a link), then releases the
  /// lock. Returns whether nothing is left under its name.
  @discardableResult
  public func remove() -> Bool {
    let removed = root.remove(named: name)
    release()
    return removed
  }
}

/// What the leftover cleanup did (PLAN.md D39, I-13b2).
public struct UpdateCleanupReport: Sendable, Hashable {
  /// Why the cleanup touched nothing at all.
  public enum Skipped: Sendable, Hashable {
    /// There is no update folder (nothing to clean, nothing created).
    case missing
    /// The update folder failed its checks.
    case unusable(UpdateStagingProblem)
    /// Another muxFinder process held the update folder's lock for the whole wait.
    case busy
    /// The update folder's lock file cannot be used.
    case lockUnavailable
  }

  /// Why nothing was touched, if nothing was.
  public var skipped: Skipped?
  /// Run folders deleted.
  public var removed = 0
  /// Run folders kept because a process runs from inside them.
  public var keptInUse = 0
  /// Run folders kept because a live update holds their lock.
  public var keptLocked = 0
  /// Run folders kept because a rollback marked them for recovery (never deleted).
  public var keptForRecovery = 0
  /// Run folders kept because the process scan was incomplete.
  public var keptUnverified = 0
  /// The last incomplete scan's problem, if any.
  public var scanProblem: UpdateProcessScanProblem?
  /// Run folders that could not be checked or deleted.
  public var failed = 0
  /// Entries that are not run folders (left as they are).
  public var ignored = 0

  /// An empty report.
  public init(skipped: Skipped? = nil) {
    self.skipped = skipped
  }
}

/// The leftover cleanup a launch runs (PLAN.md D39, I-13b2; I-13c calls it). Under the update
/// folder's lock, each entry of the update folder that is a run folder (by name, a real folder
/// by `lstat`, the user's) is judged in this order, each step only after the one before:
///
/// 1. its `run.lock` is taken without waiting (held: a live update, kept) and held through
///    the deletion, so nothing below can be read while an update still runs in it;
/// 2. a recovery marker in it (`UpdateStagingRoot.recoveryMarkerName`, any entry by that name)
///    keeps it for good;
/// 3. only then the processes are scanned (`UpdateProcessListing`, once per run folder whose
///    lock was taken): an incomplete scan keeps it, and so does any running process's
///    executable inside it, compared with the folder's own path as the kernel gives it
///    (`F_GETPATH`, the form `proc_pidpath` uses);
/// 4. it is deleted while its name still names the folder opened (device and inode).
///
/// So a buried tab's old `muxfinder-launch` keeps the old bundle until a later launch, even
/// when the update swapped it in and released the lock while the cleanup ran. Removal never
/// follows a link and never leaves the update folder; anything else in it is left. An update
/// folder that is missing or fails its checks is not touched.
struct UpdateLeftoverCleanup {
  /// The update folder.
  let root: UpdateStagingRoot
  /// The user who must own everything.
  let owner: uid_t
  /// The process list.
  let processes: any UpdateProcessListing
  /// How long it waits for the update folder's lock.
  var lockWait = UpdateStagingRoot.lockWait

  /// Runs the cleanup.
  func run() -> UpdateCleanupReport {
    switch root.inspect(owner: owner) {
    case .missing: return UpdateCleanupReport(skipped: .missing)
    case .unusable(let problem): return UpdateCleanupReport(skipped: .unusable(problem))
    case .usable: break
    }
    let folder: UpdateStagingFolder
    let descriptor: Int32
    do throws(UpdateStagingProblem) {
      folder = try UpdateStagingFolder(path: root.path, owner: owner)
      descriptor = try folder.openDirectory()
    } catch {
      return UpdateCleanupReport(skipped: .unusable(error))
    }
    defer { Darwin.close(descriptor) }
    let rootLock: Int32
    do throws(UpdateStagingRootError) {
      rootLock = try UpdateStagingRoot.lock(in: descriptor, owner: owner, wait: lockWait)
    } catch {
      return UpdateCleanupReport(skipped: error == .busy ? .busy : .lockUnavailable)
    }
    defer { Darwin.close(rootLock) }
    var report = UpdateCleanupReport()
    guard let names = try? PrivateStorage.entryNames(in: descriptor) else {
      report.failed += 1
      return report
    }
    for name in names {
      clean(name, in: descriptor, report: &report)
    } // End of loop over the update folder's entries
    return report
  } // End of func run()

  /// Checks the entry `name` of the open update folder and deletes it when it is an unused
  /// run folder (the steps in the type's order); counts the outcome in `report`.
  func clean(_ name: String, in root: Int32, report: inout UpdateCleanupReport) {
    var info = stat()
    guard UpdateStagingRoot.isRunFolderName(name),
      fstatat(root, name, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR
    else {
      report.ignored += 1
      return
    }
    let folder = openat(root, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    var opened = stat()
    guard folder >= 0, fstat(folder, &opened) == 0,
      UpdateBundleIdentity(opened) == UpdateBundleIdentity(info), opened.st_uid == owner,
      let folderPath = Self.kernelPath(of: folder)
    else {
      if folder >= 0 { Darwin.close(folder) }
      report.failed += 1
      return
    }
    defer { Darwin.close(folder) }
    // 1. The lock first, held until this function returns (after the deletion).
    let lock = Self.takeRunLock(in: folder, owner: owner)
    defer { if let lock, lock >= 0 { Darwin.close(lock) } }
    guard lock != nil else {
      report.keptLocked += 1
      return
    }
    // 2. The recovery marker, read under the lock (the rollback writes it before the update
    //    releases the lock).
    switch Self.hasRecoveryMarker(in: folder) {
    case true?:
      report.keptForRecovery += 1
      return
    case false?: break
    case nil:
      report.failed += 1
      return
    }
    // 3. The process evidence, collected only now.
    switch processes.scan() {
    case .incomplete(let problem):
      report.keptUnverified += 1
      report.scanProblem = problem
      return
    case .complete(let executables):
      if executables.contains(where: { $0.hasPrefix(folderPath + "/") }) {
        report.keptInUse += 1
        return
      }
    }
    // 4. The deletion, only while the name still names the folder opened.
    var current = stat()
    guard fstatat(root, name, &current, AT_SYMLINK_NOFOLLOW) == 0,
      UpdateBundleIdentity(current) == UpdateBundleIdentity(opened),
      UpdateStagingFolder.removeEntry(name, in: root, owner: owner, depth: 0)
    else {
      report.failed += 1
      return
    }
    report.removed += 1
  } // End of func clean(_:in:report:)

  /// Whether the open run folder holds the recovery marker (any entry by that name, read
  /// without following a link); `nil` when that cannot be read.
  static func hasRecoveryMarker(in folder: Int32) -> Bool? {
    var info = stat()
    if fstatat(folder, UpdateStagingRoot.recoveryMarkerName, &info, AT_SYMLINK_NOFOLLOW) == 0 {
      return true
    }
    return errno == ENOENT ? false : nil
  }

  /// Takes the run folder's `run.lock` without waiting: its descriptor, `-1` when the folder
  /// has no usable lock file (no update can hold it), or `nil` when a live update holds it.
  static func takeRunLock(in folder: Int32, owner: uid_t) -> Int32? {
    let lock = openat(
      folder, UpdateStagingRoot.runLockName, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard lock >= 0 else { return -1 }
    var info = stat()
    guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner else {
      Darwin.close(lock)
      return -1
    }
    guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
      Darwin.close(lock)
      return nil
    }
    return lock
  } // End of static func takeRunLock(in:owner:)

  /// The open folder's path as the kernel gives it (`F_GETPATH`), the form `proc_pidpath`
  /// uses.
  static func kernelPath(of descriptor: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    let status = buffer.withUnsafeMutableBytes { fcntl(descriptor, F_GETPATH, $0.baseAddress!) }
    guard status == 0 else { return nil }
    return String(cString: buffer)
  }
}
