import Darwin
import Foundation

/// Why a launch file operation failed. Messages hold no file contents.
public enum LaunchStoreError: Error, Sendable, Hashable, CustomStringConvertible {
  /// What is wrong with a file found in the launch directory.
  public enum FileProblem: String, Sendable, Hashable {
    /// It is a symbolic link (it was removed).
    case symbolicLink
    /// It is not a regular file (a FIFO, a socket, a directory …).
    case notARegularFile
    /// Another user owns it.
    case notOwnedByUser
    /// Group or others have permissions on it.
    case permissionsTooOpen
    /// It is larger than `LaunchStore.maximumFileSize`.
    case tooLarge
    /// It carries an extended access control list (any entry, allow or deny).
    case extendedACL
  }

  /// The launch directory does not exist (nothing was ever written).
  case directoryMissing
  /// The launch directory is a symbolic link.
  case directoryIsSymbolicLink
  /// Something other than a directory is at the launch directory's path.
  case directoryNotADirectory
  /// Another user owns the launch directory.
  case directoryNotOwnedByUser
  /// The launch directory carries an extended access control list that could not be removed.
  case directoryHasExtendedACL
  /// No file exists for the id.
  case fileMissing
  /// The request is older than the time to live (or dated in the future); it was deleted.
  case fileExpired
  /// A request with this id already exists.
  case fileAlreadyExists
  /// The file is not safe to read; it was deleted (or never followed, for a link).
  case fileUnsafe(FileProblem)
  /// The file is not valid JSON for its type, is for another id, or has unusable values.
  case fileMalformed
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)

  /// A short developer-facing description.
  public var description: String {
    switch self {
    case .directoryMissing: return "The launch directory does not exist."
    case .directoryIsSymbolicLink: return "The launch directory is a symbolic link."
    case .directoryNotADirectory: return "The launch directory is not a directory."
    case .directoryNotOwnedByUser: return "The launch directory belongs to another user."
    case .directoryHasExtendedACL:
      return "The launch directory has an access control list that could not be removed."
    case .fileMissing: return "The launch file does not exist."
    case .fileExpired: return "The launch request has expired."
    case .fileAlreadyExists: return "A launch request with this id already exists."
    case .fileUnsafe(let problem): return "The launch file is unsafe (\(problem.rawValue))."
    case .fileMalformed: return "The launch file is malformed."
    case .systemCallFailed(let name, let code):
      return "\(name) failed: \(String(cString: strerror(code)))."
    }
  } // End of var description

  /// The failure the helper reports when taking its request fails this way.
  public var launchFailure: LaunchFailure {
    switch self {
    case .directoryMissing, .fileMissing: return .requestMissing
    case .directoryIsSymbolicLink, .directoryNotADirectory, .directoryNotOwnedByUser,
      .directoryHasExtendedACL:
      return .launchDirectoryUnusable
    case .fileExpired: return .requestExpired
    case .fileAlreadyExists, .fileUnsafe, .fileMalformed, .systemCallFailed:
      return .requestUnreadable
    }
  }
}

/// The request and result files shared by the app and `muxfinder-launch` (PLAN.md D2, D8),
/// in `~/Library/Application Support/muxFinder/launch/`.
///
/// Safety rules:
/// - The directory is created 0700 and tightened to 0700 if it exists looser. It is refused if
///   it is a symbolic link, not a directory, or owned by another user. Any extended ACL on it
///   (inherited from its parent, or added later) is removed every time it is opened, and the
///   directory is refused if that fails, since an ACL entry can grant access whatever the mode
///   says (`ExtendedACL`). Every file operation goes through a descriptor of the checked
///   directory (`openat`, `renameat`, `unlinkat`), so the directory cannot be swapped
///   underneath.
/// - Files are written atomically: a temporary file created with `O_CREAT | O_EXCL |
///   O_NOFOLLOW`, stripped of any inherited ACL and set to mode 0600 before a byte is written,
///   then renamed into place (`RENAME_EXCL` for requests, so an id is never reused).
/// - Taking a file opens it with `O_NOFOLLOW` and deletes it at once, before reading: whoever
///   deletes it first owns it, so a request is used at most once, and a file refused as unsafe,
///   malformed or expired is gone too. Only regular files owned by the user, without group or
///   other permissions, without any extended ACL and at most `maximumFileSize` bytes, are read.
///   The ACL rule is the strict one (any entry, even a deny-only one, is refused rather than
///   only entries that grant others access): the store never leaves an ACL on its own files,
///   and the ACL macOS puts on home folders (`group:everyone deny delete`) is not inheritable,
///   so a normal home directory never trips it. A deny-delete entry blocks even the owner's
///   unlink, so for a file the user owns the ACL is removed first and the file then deleted.
/// - Requests expire `timeToLive` (2 minutes) after `createdAt`, measured with the injectable
///   clock. `sweep()` deletes request, result, argv-digest and temporary files whose
///   modification time is older than that.
public struct LaunchStore: Sendable {
  /// Name of the launch directory inside muxFinder's Application Support folder.
  public static let directoryName = "launch"
  /// How long a request stays valid, and how old a file gets before `sweep()` removes it.
  public static let defaultTimeToLive: TimeInterval = 120
  /// How far in the future a request's `createdAt` may be (clock adjustments) before it is
  /// refused like an expired one.
  public static let futureTolerance: TimeInterval = 5
  /// Permissions of the launch directory.
  public static let directoryPermissions: mode_t = 0o700
  /// Permissions of every launch file.
  public static let filePermissions: mode_t = 0o600
  /// The largest file read, in bytes. Requests and results are a few hundred bytes.
  public static let maximumFileSize = 16 * 1024
  /// A regular file with this name in the launch directory turns on the helper's test mode
  /// (see `LaunchArgvDigest`).
  public static let testModeMarkerName = "test-mode"

  /// File-name suffix of requests.
  static let requestSuffix = ".request.json"
  /// File-name suffix of results.
  static let resultSuffix = ".result.json"
  /// File-name suffix of temporary files.
  static let temporarySuffix = ".tmp"

  /// The launch directory.
  public let directory: URL
  /// The Application Support root to prepare before creating `directory`, if the store was
  /// made from `AppPaths`.
  let root: AppPaths?
  /// How long requests stay valid.
  public let timeToLive: TimeInterval
  /// The user id that must own the directory and its files (this process's effective uid).
  let owner: uid_t
  /// The clock used for expiry and sweeping.
  let now: @Sendable () -> Date

  /// The store under `paths` (`<root>/launch`). Production uses the default,
  /// `~/Library/Application Support/muxFinder/launch`.
  public init(
    paths: AppPaths = .standard,
    timeToLive: TimeInterval = LaunchStore.defaultTimeToLive,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(
      directory: paths.applicationSupportDirectory.appending(
        path: Self.directoryName,
        directoryHint: .isDirectory
      ),
      root: paths,
      timeToLive: timeToLive,
      owner: geteuid(),
      now: now
    )
  } // End of init(paths:timeToLive:now:)

  /// A store in `directory` itself. Its parent must exist; only `directory` is created.
  public init(
    directory: URL,
    timeToLive: TimeInterval = LaunchStore.defaultTimeToLive,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.init(directory: directory, root: nil, timeToLive: timeToLive, owner: geteuid(), now: now)
  }

  /// The designated initializer. Tests pass another `owner` to simulate a foreign directory.
  init(
    directory: URL,
    root: AppPaths?,
    timeToLive: TimeInterval,
    owner: uid_t,
    now: @escaping @Sendable () -> Date
  ) {
    self.directory = directory
    self.root = root
    self.timeToLive = timeToLive
    self.owner = owner
    self.now = now
  }

  /// The request file name for `id`.
  public static func requestFileName(for id: LaunchToken) -> String {
    id.rawValue + requestSuffix
  }

  /// The result file name for `id`.
  public static func resultFileName(for id: LaunchToken) -> String {
    id.rawValue + resultSuffix
  }

  /// The launch directory's path without a trailing slash (a trailing slash would make the
  /// kernel follow a symbolic link despite `O_NOFOLLOW`).
  var directoryPath: String {
    var path = directory.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  // MARK: - Directory

  /// Creates the launch directory if needed (0700), tightens it to 0700, checks it, and
  /// returns its URL.
  @discardableResult
  public func prepareDirectory() throws(LaunchStoreError) -> URL {
    let descriptor = try openDirectory(create: true)
    Darwin.close(descriptor)
    return directory
  }

  /// Opens the launch directory after checking it, creating it first when `create` is set.
  /// The caller closes the returned descriptor.
  func openDirectory(create: Bool) throws(LaunchStoreError) -> Int32 {
    let path = directoryPath
    if create {
      if let root {
        do {
          try root.prepareApplicationSupportDirectory()
        } catch AppPathsError.notADirectory {
          throw .directoryNotADirectory
        } catch {
          throw .systemCallFailed(name: "mkdir", errno: Self.posixCode(of: error))
        }
      }
      if mkdir(path, Self.directoryPermissions) != 0, errno != EEXIST {
        let code = errno
        throw code == ENOENT ? .directoryMissing : .systemCallFailed(name: "mkdir", errno: code)
      }
    } // End of directory creation
    var linkInfo = stat()
    guard lstat(path, &linkInfo) == 0 else {
      let code = errno
      throw code == ENOENT ? .directoryMissing : .systemCallFailed(name: "lstat", errno: code)
    }
    if linkInfo.st_mode & S_IFMT == S_IFLNK { throw .directoryIsSymbolicLink }
    guard linkInfo.st_mode & S_IFMT == S_IFDIR else { throw .directoryNotADirectory }
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      switch code {
      case ENOENT: throw .directoryMissing
      case ELOOP: throw .directoryIsSymbolicLink
      case ENOTDIR: throw .directoryNotADirectory
      default: throw .systemCallFailed(name: "open", errno: code)
      }
    }
    do throws(LaunchStoreError) {
      try checkDirectory(descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  } // End of func openDirectory(create:)

  /// Checks that the open directory belongs to `owner`, tightens it to 0700 and removes any
  /// extended ACL (`directoryHasExtendedACL` if that fails).
  func checkDirectory(_ descriptor: Int32) throws(LaunchStoreError) {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .systemCallFailed(name: "fstat", errno: errno)
    }
    guard info.st_mode & S_IFMT == S_IFDIR else { throw .directoryNotADirectory }
    guard info.st_uid == owner else { throw .directoryNotOwnedByUser }
    if info.st_mode & 0o7777 != Self.directoryPermissions {
      guard fchmod(descriptor, Self.directoryPermissions) == 0 else {
        throw .systemCallFailed(name: "fchmod", errno: errno)
      }
    }
    do throws(LaunchStoreError) {
      try ExtendedACL.removeAll(from: descriptor)
    } catch {
      throw .directoryHasExtendedACL
    }
  } // End of func checkDirectory(_:)

  /// Runs `body` with a descriptor of the checked launch directory and closes it afterwards.
  func withDirectory<Value>(
    create: Bool,
    _ body: (Int32) throws(LaunchStoreError) -> Value
  ) throws(LaunchStoreError) -> Value {
    let descriptor = try openDirectory(create: create)
    defer { Darwin.close(descriptor) }
    return try body(descriptor)
  }

  // MARK: - Requests and results

  /// Writes `request` atomically as `<id>.request.json` (0600), creating the directory if
  /// needed. Refuses an id that already has a request.
  public func writeRequest(_ request: LaunchRequest) throws(LaunchStoreError) {
    let data = try Self.encode(request)
    try withDirectory(create: true) { (directory) throws(LaunchStoreError) in
      try Self.writeFile(
        data,
        named: Self.requestFileName(for: request.id),
        exclusive: true,
        in: directory
      )
    }
  } // End of func writeRequest(_:)

  /// Takes the request for `id`: deletes the file and returns its contents if it is safe,
  /// well formed, for `id` and not expired. Never creates the directory.
  public func takeRequest(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchRequest {
    let data = try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
      try Self.takeFile(named: Self.requestFileName(for: id), in: directory, owner: owner)
    }
    guard let request = try? LaunchCoding.decoder().decode(LaunchRequest.self, from: data),
      request.id == id, request.isWellFormed
    else { throw .fileMalformed }
    let age = now().timeIntervalSince(request.createdAt)
    guard age <= timeToLive, age >= -Self.futureTolerance else { throw .fileExpired }
    return request
  } // End of func takeRequest(_:)

  /// Deletes the request for `id` if it is still there (for example after iTerm2 refused to
  /// open the tab). Returns whether a file was removed.
  @discardableResult
  public func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    do throws(LaunchStoreError) {
      return try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
        if unlinkat(directory, Self.requestFileName(for: id), 0) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw .systemCallFailed(name: "unlinkat", errno: code)
      }
    } catch .directoryMissing {
      return false
    }
  } // End of func discardRequest(_:)

  /// Writes `result` atomically as `<id>.result.json` (0600), replacing an earlier one. Never
  /// creates the directory.
  public func writeResult(_ result: LaunchResult) throws(LaunchStoreError) {
    let data = try Self.encode(result)
    try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
      try Self.writeFile(
        data,
        named: Self.resultFileName(for: result.id),
        exclusive: false,
        in: directory
      )
    }
  } // End of func writeResult(_:)

  /// Takes the result for `id` (deleting the file), or returns `nil` if there is none yet.
  public func takeResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult? {
    let data: Data
    do throws(LaunchStoreError) {
      data = try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
        try Self.takeFile(named: Self.resultFileName(for: id), in: directory, owner: owner)
      }
    } catch .fileMissing, .directoryMissing {
      return nil
    }
    guard let result = try? LaunchCoding.decoder().decode(LaunchResult.self, from: data),
      result.id == id
    else { throw .fileMalformed }
    return result
  } // End of func takeResult(_:)

  // MARK: - Test mode

  /// Writes `digest` as `argv-<helper pid>.json` (0600). Never creates the directory.
  public func writeArgvDigest(_ digest: LaunchArgvDigest) throws(LaunchStoreError) {
    let data = try Self.encode(digest)
    try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
      try Self.writeFile(
        data,
        named: LaunchArgvDigest.fileName(helperPID: digest.helperPID),
        exclusive: false,
        in: directory
      )
    }
  } // End of func writeArgvDigest(_:)

  /// Takes every argv digest in the directory (deleting the files), oldest first. Files that
  /// are unsafe or malformed are deleted and skipped.
  public func takeArgvDigests() throws(LaunchStoreError) -> [LaunchArgvDigest] {
    do throws(LaunchStoreError) {
      return try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
        var digests: [LaunchArgvDigest] = []
        for name in try Self.entryNames(in: directory) where LaunchArgvDigest.isFileName(name) {
          guard let data = try? Self.takeFile(named: name, in: directory, owner: owner),
            let digest = try? LaunchCoding.decoder().decode(LaunchArgvDigest.self, from: data)
          else { continue }
          digests.append(digest)
        }
        return digests.sorted { $0.recordedAt < $1.recordedAt }
      }
    } catch .directoryMissing {
      return []
    }
  } // End of func takeArgvDigests()

  /// Creates the test-mode marker (an empty 0600 file, written like every other launch file),
  /// creating the directory if needed. Phase 4b's e2e run turns test mode on this way.
  public func createTestModeMarker() throws(LaunchStoreError) {
    try withDirectory(create: true) { (directory) throws(LaunchStoreError) in
      try Self.writeFile(Data(), named: Self.testModeMarkerName, exclusive: false, in: directory)
    }
  }

  /// Removes the test-mode marker. Returns whether there was one. Never creates the directory.
  @discardableResult
  public func removeTestModeMarker() throws(LaunchStoreError) -> Bool {
    do throws(LaunchStoreError) {
      return try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
        if unlinkat(directory, Self.testModeMarkerName, 0) == 0 { return true }
        let code = errno
        if code == ENOENT { return false }
        throw .systemCallFailed(name: "unlinkat", errno: code)
      }
    } catch .directoryMissing {
      return false
    }
  } // End of func removeTestModeMarker()

  /// Whether the test-mode marker exists as a regular file owned by the user. Never creates
  /// the directory.
  public func testModeMarkerExists() -> Bool {
    let found = try? withDirectory(create: false) { (directory) throws(LaunchStoreError) in
      var info = stat()
      guard fstatat(directory, Self.testModeMarkerName, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
        return false
      }
      return info.st_mode & S_IFMT == S_IFREG && info.st_uid == owner
    }
    return found ?? false
  } // End of func testModeMarkerExists()

  // MARK: - Sweep

  /// Deletes request, result, argv-digest and temporary files last modified more than
  /// `timeToLive` ago, and returns how many were removed. Other files (such as the test-mode
  /// marker) and directories are left alone. A missing directory is not an error.
  @discardableResult
  public func sweep() throws(LaunchStoreError) -> Int {
    let cutoff = now().addingTimeInterval(-timeToLive)
    do throws(LaunchStoreError) {
      return try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
        var removed = 0
        for name in try Self.entryNames(in: directory) where Self.isManagedFileName(name) {
          var info = stat()
          guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
            info.st_mode & S_IFMT != S_IFDIR
          else { continue }
          let modified = Date(
            timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
              + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000
          )
          if modified < cutoff, unlinkat(directory, name, 0) == 0 { removed += 1 }
        } // End of loop over directory entries
        return removed
      }
    } catch .directoryMissing {
      return 0
    }
  } // End of func sweep()

  /// Whether `name` is a file the store manages (and may sweep).
  static func isManagedFileName(_ name: String) -> Bool {
    if name.hasSuffix(requestSuffix) || name.hasSuffix(resultSuffix) { return true }
    if LaunchArgvDigest.isFileName(name) { return true }
    return name.hasPrefix(".") && name.hasSuffix(temporarySuffix)
  }

  // MARK: - File primitives

  /// Encodes `value` with `LaunchCoding`.
  static func encode<Value: Encodable>(_ value: Value) throws(LaunchStoreError) -> Data {
    guard let data = try? LaunchCoding.encoder().encode(value) else { throw .fileMalformed }
    guard data.count <= maximumFileSize else { throw .fileUnsafe(.tooLarge) }
    return data
  }

  /// Writes `data` to `name` in `directory` through a temporary file and a rename. With
  /// `exclusive`, an existing `name` is never replaced (`fileAlreadyExists`).
  static func writeFile(
    _ data: Data,
    named name: String,
    exclusive: Bool,
    in directory: Int32
  ) throws(LaunchStoreError) {
    let temporary =
      ".\(name).\(String(UInt64.random(in: .min ... .max), radix: 16))"
      + temporarySuffix
    let descriptor = openat(
      directory,
      temporary,
      O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      filePermissions
    )
    guard descriptor >= 0 else { throw .systemCallFailed(name: "openat", errno: errno) }
    var renamed = false
    defer {
      if !renamed { unlinkat(directory, temporary, 0) }
    }
    // A new file inherits the directory's inheritable ACL entries; none may survive to the
    // first byte written.
    do throws(LaunchStoreError) {
      try ExtendedACL.removeAll(from: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    // The umask can only remove permission bits; fchmod makes the mode exactly 0600.
    guard fchmod(descriptor, filePermissions) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw .systemCallFailed(name: "fchmod", errno: code)
    }
    do throws(LaunchStoreError) {
      try writeAll(data, to: descriptor)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    Darwin.close(descriptor)
    let code =
      exclusive
      ? renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
      : renameat(directory, temporary, directory, name)
    guard code == 0 else {
      let failure = errno
      throw failure == EEXIST
        ? .fileAlreadyExists : .systemCallFailed(name: "renameat", errno: failure)
    }
    renamed = true
  } // End of func writeFile(_:named:exclusive:in:)

  /// Writes all of `data` to `descriptor`, retrying on `EINTR`.
  static func writeAll(_ data: Data, to descriptor: Int32) throws(LaunchStoreError) {
    var offset = 0
    while offset < data.count {
      let written = data.withUnsafeBytes { bytes -> Int in
        guard let base = bytes.baseAddress else { return 0 }
        return Darwin.write(descriptor, base + offset, data.count - offset)
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        throw .systemCallFailed(name: "write", errno: written < 0 ? errno : EIO)
      }
    } // End of loop over writes
  } // End of func writeAll(_:to:)

  /// Opens `name` in `directory` without following links, deletes it, checks it (regular file,
  /// owner, mode, no extended ACL, size) and returns its bytes.
  static func takeFile(
    named name: String,
    in directory: Int32,
    owner: uid_t
  ) throws(LaunchStoreError) -> Data {
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { throw .fileMissing }
      if code == ELOOP {
        unlinkat(directory, name, 0)
        throw .fileUnsafe(.symbolicLink)
      }
      throw .systemCallFailed(name: "openat", errno: code)
    }
    defer { Darwin.close(descriptor) }
    // Claim the file: only the caller whose unlink succeeds may use it.
    guard unlinkat(directory, name, 0) == 0 else {
      let code = errno
      if code == ENOENT { throw .fileMissing }
      // A deny entry in an extended ACL (`everyone deny delete`) blocks even the owner's
      // unlink. Such a file is refused anyway, so its ACL goes first, then the file.
      if code == EPERM || code == EACCES, removeExtendedACL(of: descriptor, owner: owner),
        unlinkat(directory, name, 0) == 0
      {
        throw .fileUnsafe(.extendedACL)
      }
      throw .systemCallFailed(name: "unlinkat", errno: code)
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .systemCallFailed(name: "fstat", errno: errno)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw .fileUnsafe(.notARegularFile) }
    guard info.st_uid == owner else { throw .fileUnsafe(.notOwnedByUser) }
    guard info.st_mode & 0o077 == 0 else { throw .fileUnsafe(.permissionsTooOpen) }
    guard try !ExtendedACL.isPresent(on: descriptor) else { throw .fileUnsafe(.extendedACL) }
    guard info.st_size <= off_t(maximumFileSize) else { throw .fileUnsafe(.tooLarge) }
    return try readAll(from: descriptor)
  } // End of func takeFile(named:in:owner:)

  /// Removes the extended ACL of the open file if `owner` owns it and it has one. Returns
  /// whether an ACL was removed.
  static func removeExtendedACL(of descriptor: Int32, owner: uid_t) -> Bool {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == owner,
      (try? ExtendedACL.isPresent(on: descriptor)) == true
    else { return false }
    return (try? ExtendedACL.removeAll(from: descriptor)) != nil
  }

  /// Reads `descriptor` to end of file, at most `maximumFileSize` bytes.
  static func readAll(from descriptor: Int32) throws(LaunchStoreError) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        data.append(contentsOf: buffer[0..<count])
        if data.count > maximumFileSize { throw .fileUnsafe(.tooLarge) }
      } else if count == 0 {
        return data
      } else if errno != EINTR {
        throw .systemCallFailed(name: "read", errno: errno)
      }
    } // End of loop over reads
  } // End of func readAll(from:)

  /// The names in the open directory, without `.` and `..`.
  static func entryNames(in directory: Int32) throws(LaunchStoreError) -> [String] {
    let copy = dup(directory)
    guard copy >= 0 else { throw .systemCallFailed(name: "dup", errno: errno) }
    guard let stream = fdopendir(copy) else {
      let code = errno
      Darwin.close(copy)
      throw .systemCallFailed(name: "fdopendir", errno: code)
    }
    defer { closedir(stream) }
    rewinddir(stream)
    var names: [String] = []
    while let entry = readdir(stream) {
      var raw = entry.pointee.d_name
      let length = Int(entry.pointee.d_namlen)
      let name = withUnsafeBytes(of: &raw) { String(decoding: $0.prefix(length), as: UTF8.self) }
      if name != ".", name != ".." { names.append(name) }
    } // End of loop over directory entries
    return names
  } // End of func entryNames(in:)

  /// The POSIX error code inside `error`, or `EIO`.
  static func posixCode(of error: any Error) -> Int32 {
    let nsError = error as NSError
    if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
    if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
      underlying.domain == NSPOSIXErrorDomain
    {
      return Int32(underlying.code)
    }
    return EIO
  }
}
