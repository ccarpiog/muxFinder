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
  /// The request is well formed but of another kind than the helper mode taking it asked for
  /// (PLAN.md D24): an ssh setup request given to `attach`, or the other way round. It was
  /// deleted like any refused request.
  case requestKindMismatch(expected: LaunchRequestKind, found: LaunchRequestKind)
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
    case .requestKindMismatch(let expected, let found):
      return "The launch request is for the helper's \(found.helperMode) mode, not "
        + "\(expected.helperMode)."
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
    case .fileAlreadyExists, .fileUnsafe, .fileMalformed, .requestKindMismatch,
      .systemCallFailed:
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
///   underneath. These directory and write rules are `PrivateStorage`'s, shared with
///   `HostStore`.
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
  public static let directoryPermissions: mode_t = PrivateStorage.directoryPermissions
  /// Permissions of every launch file.
  public static let filePermissions: mode_t = PrivateStorage.filePermissions
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
  static let temporarySuffix = PrivateStorage.temporarySuffix

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
  var directoryPath: String { PrivateStorage.path(of: directory) }

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
  /// Every open tightens it to 0700 and removes any extended ACL (`directoryHasExtendedACL` if
  /// that fails). The caller closes the returned descriptor.
  func openDirectory(create: Bool) throws(LaunchStoreError) -> Int32 {
    if create, let root {
      do {
        try root.prepareApplicationSupportDirectory()
      } catch AppPathsError.notADirectory {
        throw .directoryNotADirectory
      } catch {
        throw .systemCallFailed(name: "mkdir", errno: PrivateStorage.posixCode(of: error))
      }
    }
    let path = directoryPath
    let ownerID = owner
    return try Self.bridged { () throws(PrivateStorageError) -> Int32 in
      try PrivateStorage.openDirectory(
        atPath: path,
        owner: ownerID,
        access: create ? .createAndSecure : .secure
      )
    }
  } // End of func openDirectory(create:)

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

  /// Writes the ssh setup `request` (PLAN.md D24) atomically as `<id>.request.json` (0600),
  /// creating the directory if needed, exactly as an attach request is written. A request that
  /// is not well formed (its destination fails `Validation.sshDestination(_:)`) is refused as
  /// `fileMalformed` before anything is created. Refuses an id that already has a request.
  public func writeRequest(_ request: SSHSetupRequest) throws(LaunchStoreError) {
    guard request.isWellFormed else { throw .fileMalformed }
    let data = try Self.encode(request)
    try withDirectory(create: true) { (directory) throws(LaunchStoreError) in
      try Self.writeFile(
        data,
        named: Self.requestFileName(for: request.id),
        exclusive: true,
        in: directory
      )
    }
  } // End of func writeRequest(_:) for ssh setup

  /// Takes the attach request for `id` (see `takeRequestFile(_:)`). A well-formed request of
  /// another kind is refused as `requestKindMismatch`, and is gone like any refused request.
  public func takeRequest(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchRequest {
    let file = try takeRequestFile(id)
    guard case .attach(let request) = file else {
      throw .requestKindMismatch(expected: .attach, found: file.kind)
    }
    return request
  }

  /// Takes the ssh setup request for `id` (see `takeRequestFile(_:)`). A well-formed request of
  /// another kind (an attach request) is refused as `requestKindMismatch`, and is gone like any
  /// refused request.
  public func takeSSHSetupRequest(_ id: LaunchToken) throws(LaunchStoreError) -> SSHSetupRequest {
    let file = try takeRequestFile(id)
    guard case .sshSetup(let request) = file else {
      throw .requestKindMismatch(expected: .sshSetup, found: file.kind)
    }
    return request
  }

  /// Takes the request for `id`, whatever its kind: deletes the file and returns its contents
  /// if it is safe, well formed for its kind (`LaunchRequestFile.decode(_:)`), for `id` and not
  /// expired. Never creates the directory.
  public func takeRequestFile(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchRequestFile {
    let data = try withDirectory(create: false) { (directory) throws(LaunchStoreError) in
      try Self.takeFile(named: Self.requestFileName(for: id), in: directory, owner: owner)
    }
    guard let file = try? LaunchRequestFile.decode(data), file.id == id, file.isWellFormed
    else { throw .fileMalformed }
    let age = now().timeIntervalSince(file.createdAt)
    guard age <= timeToLive, age >= -Self.futureTolerance else { throw .fileExpired }
    return file
  } // End of func takeRequestFile(_:)

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

  /// Writes `data` to `name` in `directory` through a temporary file and a rename
  /// (`PrivateStorage.writeFile`). With `exclusive`, an existing `name` is never replaced
  /// (`fileAlreadyExists`).
  static func writeFile(
    _ data: Data,
    named name: String,
    exclusive: Bool,
    in directory: Int32
  ) throws(LaunchStoreError) {
    try bridged { () throws(PrivateStorageError) in
      try PrivateStorage.writeFile(data, named: name, exclusive: exclusive, in: directory)
    }
  } // End of func writeFile(_:named:exclusive:in:)

  /// The names in the open directory, without `.` and `..`.
  static func entryNames(in directory: Int32) throws(LaunchStoreError) -> [String] {
    try bridged { () throws(PrivateStorageError) -> [String] in
      try PrivateStorage.entryNames(in: directory)
    }
  }

  /// Runs a private storage operation and reports its failure as the matching
  /// `LaunchStoreError`.
  static func bridged<Value>(
    _ body: () throws(PrivateStorageError) -> Value
  ) throws(LaunchStoreError) -> Value {
    do throws(PrivateStorageError) {
      return try body()
    } catch {
      throw LaunchStoreError(error)
    }
  } // End of func bridged(_:)

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
      if code == EPERM || code == EACCES,
        PrivateStorage.removeExtendedACL(of: descriptor, owner: owner),
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
    let hasACL = try bridged { () throws(PrivateStorageError) -> Bool in
      try ExtendedACL.isPresent(on: descriptor)
    }
    guard !hasACL else { throw .fileUnsafe(.extendedACL) }
    guard info.st_size <= off_t(maximumFileSize) else { throw .fileUnsafe(.tooLarge) }
    return try bridged { () throws(PrivateStorageError) -> Data in
      try PrivateStorage.readAll(from: descriptor, limit: maximumFileSize)
    }
  } // End of func takeFile(named:in:owner:)
}

extension LaunchStoreError {
  /// The launch store's error for a failed private storage operation.
  init(_ error: PrivateStorageError) {
    switch error {
    case .directoryMissing: self = .directoryMissing
    case .directoryIsSymbolicLink: self = .directoryIsSymbolicLink
    case .directoryNotADirectory: self = .directoryNotADirectory
    case .directoryNotOwnedByUser: self = .directoryNotOwnedByUser
    case .directoryHasExtendedACL: self = .directoryHasExtendedACL
    case .fileAlreadyExists: self = .fileAlreadyExists
    case .fileTooLarge: self = .fileUnsafe(.tooLarge)
    case .systemCallFailed(let name, let code): self = .systemCallFailed(name: name, errno: code)
    }
  } // End of init(_:)
}
