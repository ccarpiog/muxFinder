import Darwin
import Foundation

/// What is wrong with a host list file that cannot be used. Loading leaves the file exactly as
/// it is, and the next save that replaces it keeps it as a backup (PLAN.md D19).
public enum HostFileProblem: Error, Sendable, Hashable, CustomStringConvertible {
  /// Why the file is not trusted, whatever it contains (the D14 rules for files read).
  public enum UnsafeReason: String, Sendable, Hashable {
    /// It is a symbolic link (never followed).
    case symbolicLink
    /// It is not a regular file (a directory, a FIFO, a socket …).
    case notARegularFile
    /// Another user owns it.
    case notOwnedByUser
    /// Group or others have permissions on it.
    case permissionsTooOpen
    /// It carries an extended access control list (any entry, allow or deny).
    case extendedACL
    /// It is larger than `HostStore.maximumFileSize`.
    case tooLarge
  }

  /// The file is not safe to trust.
  case unsafe(UnsafeReason)
  /// The file is not valid JSON.
  case notJSON
  /// The file is JSON but not a host list of its schema version (no version, wrong types,
  /// missing fields).
  case malformed
  /// The file was written by a newer muxFinder, with this schema version.
  case newerSchemaVersion(Int)
  /// The file has a schema version no muxFinder ever wrote (zero or negative).
  case unsupportedSchemaVersion(Int)
  /// The file's hosts break a host-list invariant.
  case invariantBroken(HostListError)

  /// A stable, machine-readable name for the problem (the probe prints it).
  public var code: String {
    switch self {
    case .unsafe(let reason): return "unsafe.\(reason.rawValue)"
    case .notJSON: return "notJSON"
    case .malformed: return "malformed"
    case .newerSchemaVersion: return "newerSchemaVersion"
    case .unsupportedSchemaVersion: return "unsupportedSchemaVersion"
    case .invariantBroken: return "invariantBroken"
    }
  } // End of var code

  /// The user-facing explanation, in English and sentence case. It names no host.
  public var message: String {
    switch self {
    case .unsafe(.symbolicLink):
      return "The host list file is a symbolic link, so muxFinder doesn't use it."
    case .unsafe(.notARegularFile):
      return "The host list file isn't a regular file."
    case .unsafe(.notOwnedByUser):
      return "The host list file belongs to another user."
    case .unsafe(.permissionsTooOpen):
      return "Other users have access to the host list file."
    case .unsafe(.extendedACL):
      return "The host list file has an access control list, so other users might have access."
    case .unsafe(.tooLarge):
      return "The host list file is too large."
    case .notJSON:
      return "The host list file isn't valid JSON."
    case .malformed:
      return "The host list file doesn't contain a host list muxFinder understands."
    case .newerSchemaVersion(let version):
      return "The host list was saved by a newer version of muxFinder (format \(version))."
    case .unsupportedSchemaVersion(let version):
      return "The host list file uses format \(version), which muxFinder doesn't support."
    case .invariantBroken(let error):
      return "The host list file isn't valid: \(error.message)"
    }
  } // End of var message

  /// The same as `message`.
  public var description: String { message }
}

/// The outcome of `HostStore.load()`.
public struct HostStoreLoadResult: Sendable, Hashable {
  /// What was found on disk.
  public enum State: Sendable, Hashable {
    /// A valid host list file; `hosts` is its list.
    case saved
    /// No host list file (nothing was saved yet); `hosts` is the onboarding defaults.
    case notSavedYet
    /// A file that cannot be used, left untouched; `hosts` is the onboarding defaults, and the
    /// next save that replaces the file keeps it as a backup.
    case invalid(HostFileProblem)
  }

  /// The loaded list, or the onboarding defaults when there is none to use.
  public var hosts: HostList
  /// What was found.
  public var state: State
}

/// Why the host list could not be loaded or saved. Messages hold no file contents.
public enum HostStoreError: Error, Sendable, Hashable, LocalizedError {
  /// The folder's parent does not exist, so the folder cannot be created.
  case directoryMissing
  /// muxFinder's folder is a symbolic link.
  case directoryIsSymbolicLink
  /// Something other than a folder is at the folder's path.
  case directoryNotADirectory
  /// Another user owns muxFinder's folder.
  case directoryNotOwnedByUser
  /// muxFinder's folder carries an extended access control list that could not be removed.
  case directoryHasExtendedACL
  /// The existing host list file is a symbolic link or not a regular file; it was left alone
  /// and nothing was saved.
  case existingFileNotRegular
  /// The existing host list file cannot be used and is too large to back up; it was left alone
  /// and nothing was saved.
  case existingFileTooLarge
  /// The list breaks an invariant; nothing was written.
  case invalidList(HostListError)
  /// The list could not be encoded.
  case encodingFailed
  /// The encoded list is larger than `HostStore.maximumFileSize`; nothing was written.
  case listTooLarge
  /// The list was saved, but the file it displaced could not be renamed to a backup name
  /// (this errno); that file is still in the folder under this hidden temporary name.
  case displacedFileNotKept(temporaryName: String, errno: Int32)
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)

  /// The user-facing explanation.
  public var errorDescription: String? {
    switch self {
    case .directoryMissing:
      return "muxFinder can't save its settings because the folder that holds them is missing."
    case .directoryIsSymbolicLink:
      return "muxFinder's settings folder is a symbolic link, so muxFinder doesn't use it."
    case .directoryNotADirectory:
      return "Something other than a folder is where muxFinder keeps its settings."
    case .directoryNotOwnedByUser:
      return "muxFinder's settings folder belongs to another user."
    case .directoryHasExtendedACL:
      return "muxFinder's settings folder has an access control list that couldn't be removed."
    case .existingFileNotRegular:
      return "The host list file isn't a regular file, so muxFinder left it as it is. "
        + "Move it away to save."
    case .existingFileTooLarge:
      return "The host list file is too large to back up, so muxFinder left it as it is. "
        + "Move it away to save."
    case .invalidList(let error):
      return error.message
    case .encodingFailed:
      return "The host list couldn't be encoded."
    case .listTooLarge:
      return "The host list is too large to save."
    case .displacedFileNotKept(let temporaryName, let code):
      return "muxFinder saved the host list but couldn't keep the file it replaced as a backup "
        + "(\(String(cString: strerror(code)))). That file is in muxFinder's settings folder "
        + "as \(temporaryName)."
    case .systemCallFailed(let name, let code):
      return "muxFinder couldn't read or write its host list (\(name): "
        + "\(String(cString: strerror(code))))."
    }
  } // End of var errorDescription

  /// The store's error for a failed private storage operation.
  init(_ error: PrivateStorageError) {
    switch error {
    case .directoryMissing: self = .directoryMissing
    case .directoryIsSymbolicLink: self = .directoryIsSymbolicLink
    case .directoryNotADirectory: self = .directoryNotADirectory
    case .directoryNotOwnedByUser: self = .directoryNotOwnedByUser
    case .directoryHasExtendedACL: self = .directoryHasExtendedACL
    case .fileAlreadyExists: self = .systemCallFailed(name: "renameat", errno: EEXIST)
    case .fileTooLarge: self = .existingFileTooLarge
    case .systemCallFailed(let name, let code): self = .systemCallFailed(name: name, errno: code)
    }
  } // End of init(_:)
}

/// Persists the host list as `hosts.json` in muxFinder's folder (PLAN.md D8, D19).
///
/// The file is a JSON object, schema 1:
/// `{"schemaVersion": 1, "hosts": [<HostConfig>, …]}`, each host with `id`, `displayName`,
/// `mode` (`local` or `ssh`), `sshDestination`, `isEnabled`, and `tmuxPathOverride` and
/// `iTermProfileName` when set.
///
/// - **Loading never writes anything**, not even the folder: it is opened with
///   `PrivateStorage`'s `inspect` access. No file gives the onboarding defaults, reported as
///   `notSavedYet`. A file that cannot be used (unsafe by D14's rules for files read, not
///   JSON, malformed, another schema version, an invariant broken) gives the defaults too,
///   reported as `invalid` with the problem, and stays exactly as it is.
/// - **Saving** checks the list (`invalidList`) and encodes it before touching the disk. It
///   creates the folder (0700; its parent must exist) or tightens it, and removes any extended
///   ACL from it (refused, `directoryHasExtendedACL`, if that fails). It then looks at the file
///   without reading it: a symbolic link or other non-regular file, or one over
///   `maximumBackupSize`, is left alone and the save refused; a regular file loses any
///   extended ACL (a deny-delete entry would block the swap below). The list goes to a
///   temporary file (no ACL, 0600, flushed) that is published with one rename: `RENAME_SWAP`
///   when a file is there, so whatever is at the name at that instant moves to the temporary
///   name, or `RENAME_EXCL` when none is, so a file that appeared is never overwritten. The
///   backup decision is about those displaced bytes: they are deleted only when they are a
///   trusted valid list identical to what this store last loaded (as `saved`) or wrote.
///   Anything else is kept: made 0600 without ACL when it is the user's regular file, then
///   renamed to a new backup beside it (`hosts.backup-<UTC yyyyMMddTHHmmssZ>[-n].json`, never
///   replacing an earlier one). If that rename fails, it stays under the temporary name and
///   the save throws `displacedFileNotKept`.
/// - The store is an actor, so its file work runs off the main actor and saves of one store
///   never interleave. The app is meant to be the only writer of the file; a change made by
///   anything else is kept as a backup by the next save.
public actor HostStore {
  /// The host list file's name in muxFinder's folder.
  public static let fileName = "hosts.json"
  /// The schema version this muxFinder reads and writes.
  public static let schemaVersion = 1
  /// The largest host list file loaded, in bytes. Saving refuses a list that would be larger.
  public static let maximumFileSize = 1024 * 1024
  /// The largest unusable file a save backs up before replacing it, in bytes.
  public static let maximumBackupSize = 16 * 1024 * 1024
  /// How many backup names with the same timestamp a save tries (`-2`, `-3`, …).
  static let maximumBackupAttempts = 100
  /// How many renames a save tries to publish its file while another process keeps creating
  /// or removing the file between them.
  static let maximumPublishAttempts = 8

  /// The host list file.
  public nonisolated let fileURL: URL
  /// The user id that must own the folder and the file (this process's effective uid).
  nonisolated let owner: uid_t
  /// The clock that dates backups.
  nonisolated let now: @Sendable () -> Date
  /// Runs inside `save` after the file was looked at and the temporary file written, just
  /// before publication. Tests use it to change the file in that window; otherwise `nil`.
  nonisolated let beforePublishing: (@Sendable () -> Void)?
  /// The bytes this store last loaded as `saved` or wrote, or `nil` when it has neither loaded
  /// a usable file nor written one since its last load. A save deletes the file it displaces
  /// only when it holds exactly these bytes.
  var lastKnownContents: Data?

  /// The store at `<root>/hosts.json`. Production uses the default,
  /// `~/Library/Application Support/muxFinder/hosts.json`. Nothing is created.
  public init(paths: AppPaths = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
    self.fileURL = paths.applicationSupportDirectory.appending(
      path: Self.fileName,
      directoryHint: .notDirectory
    )
    self.owner = geteuid()
    self.now = now
    self.beforePublishing = nil
  } // End of init(paths:now:)

  /// The store at `fileURL`, for tests and `muxfinder-probe hosts show --config`. Its folder
  /// gets the same rules as muxFinder's own; its parent must exist for a save.
  public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.init(fileURL: fileURL, owner: geteuid(), now: now)
  }

  /// The designated initializer. Tests pass another `owner` to simulate a foreign folder, and
  /// a `beforePublishing` hook to change the file while a save runs.
  init(
    fileURL: URL,
    owner: uid_t,
    now: @escaping @Sendable () -> Date,
    beforePublishing: (@Sendable () -> Void)? = nil
  ) {
    self.fileURL = fileURL
    self.owner = owner
    self.now = now
    self.beforePublishing = beforePublishing
  }

  /// The folder that holds the file.
  public nonisolated var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  /// The file's name within its folder.
  nonisolated var name: String { fileURL.lastPathComponent }

  // MARK: - Loading

  /// Loads the host list without writing anything. See the type's documentation for the
  /// states. Throws only when the folder cannot be used (a link, not a folder, another user's)
  /// or a system call fails. Remembers the bytes of a `saved` file (`lastKnownContents`), and
  /// that there are none otherwise.
  public func load() throws(HostStoreError) -> HostStoreLoadResult {
    let directory: Int32
    do throws(PrivateStorageError) {
      directory = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL),
        owner: owner,
        access: .inspect
      )
    } catch .directoryMissing {
      lastKnownContents = nil
      return HostStoreLoadResult(hosts: .onboardingDefaults(), state: .notSavedYet)
    } catch {
      throw HostStoreError(error)
    }
    defer { Darwin.close(directory) }
    let found = try Self.examine(
      named: name,
      in: directory,
      owner: owner,
      readLimit: Self.maximumFileSize
    )
    let state: HostStoreLoadResult.State
    switch found {
    case .missing:
      state = .notSavedYet
    case .notAFile(let reason):
      state = .invalid(.unsafe(reason))
    case .file(_, .some(let reason)):
      state = .invalid(.unsafe(reason))
    case .file(let data, .none):
      switch Self.decode(data ?? Data()) {
      case .list(let list):
        lastKnownContents = data
        return HostStoreLoadResult(hosts: list, state: .saved)
      case .problem(let problem):
        state = .invalid(problem)
      }
    }
    lastKnownContents = nil
    return HostStoreLoadResult(hosts: .onboardingDefaults(), state: state)
  } // End of func load()

  // MARK: - Saving

  /// Saves `list` atomically and returns the backup's URL when the file it displaced was kept.
  /// The backup decision is about the entry the publishing rename actually displaced, never
  /// about the file looked at earlier, so a file changed by another process in between is
  /// kept too (see the type's documentation).
  @discardableResult
  public func save(_ list: HostList) throws(HostStoreError) -> URL? {
    do throws(HostListError) {
      try list.validate()
    } catch {
      throw .invalidList(error)
    }
    let data = try Self.encode(list)
    let directory: Int32
    do throws(PrivateStorageError) {
      directory = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL),
        owner: owner,
        access: .createAndSecure
      )
    } catch {
      throw HostStoreError(error)
    }
    defer { Darwin.close(directory) }
    let present = try prepareReplacement(in: directory)
    let temporary: String
    do throws(PrivateStorageError) {
      temporary = try PrivateStorage.writeTemporaryFile(
        data,
        for: name,
        synchronize: true,
        in: directory
      )
    } catch {
      throw HostStoreError(error)
    }
    beforePublishing?()
    let displaced: Bool
    do throws(HostStoreError) {
      displaced = try publish(temporary, replacing: present, in: directory)
    } catch {
      // No rename succeeded, so the temporary file still holds only the new list.
      unlinkat(directory, temporary, 0)
      throw error
    }
    let expected = lastKnownContents
    lastKnownContents = data
    guard displaced else { return nil }
    let backup = try settleDisplaced(temporary, expecting: expected, in: directory)
    return backup.map { directoryURL.appending(path: $0, directoryHint: .notDirectory) }
  } // End of func save(_:)

  /// Looks at the file's name before a save writes anything, without reading the file, and
  /// returns whether a file is there. A symbolic link or other non-regular file
  /// (`existingFileNotRegular`) and a file over `maximumBackupSize` (`existingFileTooLarge`)
  /// are left exactly as they are and refuse the save. A regular file of the user's loses any
  /// extended ACL, because a deny-delete entry makes the swap that displaces it fail
  /// (`EACCES`); its bytes are untouched, and a backup never carries an ACL anyway.
  func prepareReplacement(in directory: Int32) throws(HostStoreError) -> Bool {
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { return false }
      if code == ELOOP { throw .existingFileNotRegular }
      throw .systemCallFailed(name: "openat", errno: code)
    }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .systemCallFailed(name: "fstat", errno: errno)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw .existingFileNotRegular }
    guard info.st_size <= off_t(Self.maximumBackupSize) else { throw .existingFileTooLarge }
    _ = PrivateStorage.removeExtendedACL(of: descriptor, owner: owner)
    return true
  } // End of func prepareReplacement(in:)

  /// Publishes the temporary file as the host list file and returns whether that displaced an
  /// entry, which is then at `temporary`. With `present`, `RENAME_SWAP` exchanges the two
  /// names atomically, so whatever is at the name at that instant is displaced, not lost;
  /// otherwise `RENAME_EXCL` never replaces a file that appeared. A swap finding no file
  /// (`ENOENT`) goes to the exclusive rename, an exclusive rename finding one (`EEXIST`) to
  /// the swap, at most `maximumPublishAttempts` renames in all. On a throw nothing was renamed.
  func publish(
    _ temporary: String,
    replacing present: Bool,
    in directory: Int32
  ) throws(HostStoreError) -> Bool {
    var swap = present
    var failure: Int32 = 0
    for _ in 1...Self.maximumPublishAttempts {
      let flags = swap ? RENAME_SWAP : RENAME_EXCL
      if renameatx_np(directory, temporary, directory, name, UInt32(flags)) == 0 { return swap }
      failure = errno
      switch (swap, failure) {
      case (true, ENOENT): swap = false
      case (false, EEXIST): swap = true
      default: throw .systemCallFailed(name: "renameatx_np", errno: failure)
      }
    } // End of loop over publication attempts
    throw .systemCallFailed(name: "renameatx_np", errno: failure)
  } // End of func publish(_:replacing:in:)

  /// Deletes or keeps the entry a save displaced, now at `temporary`. It is deleted only when
  /// it is a trusted regular file holding exactly `expected` (the bytes this store last loaded
  /// or wrote) and a valid list; anything else, including an entry that cannot be examined, is
  /// kept (`keepBackup`). Returns the backup's name when one was kept. Nothing at `temporary`
  /// is ever deleted on an error path.
  func settleDisplaced(
    _ temporary: String,
    expecting expected: Data?,
    in directory: Int32
  ) throws(HostStoreError) -> String? {
    let found = try? Self.examine(
      named: temporary,
      in: directory,
      owner: owner,
      readLimit: Self.maximumFileSize
    )
    switch found {
    case .missing:
      return nil
    case .file(.some(let data), .none) where data == expected:
      if case .list = Self.decode(data) {
        unlinkat(directory, temporary, 0)
        return nil
      }
    default:
      break
    }
    Self.makePrivate(named: temporary, in: directory, owner: owner)
    return try keepBackup(temporary, in: directory)
  } // End of func settleDisplaced(_:expecting:in:)

  /// Makes the displaced entry `name` a private backup before it gets its backup name, when it
  /// is a regular file of `owner`'s: no extended ACL, mode 0600, flushed to stable storage.
  /// Best effort: a link is not followed, another kind of entry or another user's file is left
  /// as it is, and failures leave the bytes as they are.
  static func makePrivate(named name: String, in directory: Int32, owner: uid_t) {
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner
    else { return }
    _ = PrivateStorage.removeExtendedACL(of: descriptor, owner: owner)
    if info.st_mode & 0o7777 != PrivateStorage.filePermissions {
      _ = fchmod(descriptor, PrivateStorage.filePermissions)
    }
    try? PrivateStorage.flush(descriptor)
  } // End of func makePrivate(named:in:owner:)

  /// Renames the displaced entry at `temporary` to a new backup name next to the file and
  /// returns that name. An existing backup is never replaced (`RENAME_EXCL`): the next free
  /// `-n` suffix is used. When no name is free or the rename fails, the entry stays at
  /// `temporary` and the save reports `displacedFileNotKept`.
  func keepBackup(_ temporary: String, in directory: Int32) throws(HostStoreError) -> String {
    let timestamp = Self.timestamp(now())
    var failure = EEXIST
    for attempt in 1...Self.maximumBackupAttempts {
      let candidate = Self.backupName(for: name, timestamp: timestamp, attempt: attempt)
      if renameatx_np(directory, temporary, directory, candidate, UInt32(RENAME_EXCL)) == 0 {
        return candidate
      }
      failure = errno
      guard failure == EEXIST else { break }
    } // End of loop over backup names
    throw .displacedFileNotKept(temporaryName: temporary, errno: failure)
  } // End of func keepBackup(_:in:)

  /// The backup name for `fileName`: `hosts.json` becomes `hosts.backup-<timestamp>.json`, and
  /// `hosts.backup-<timestamp>-<attempt>.json` from the second attempt on.
  static func backupName(for fileName: String, timestamp: String, attempt: Int) -> String {
    let tag = ".backup-\(timestamp)" + (attempt > 1 ? "-\(attempt)" : "")
    guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
      return fileName + tag
    }
    return String(fileName[..<dot]) + tag + String(fileName[dot...])
  }

  /// `date` in UTC as `yyyyMMddTHHmmssZ`.
  static func timestamp(_ date: Date) -> String {
    var seconds = time_t(date.timeIntervalSince1970.rounded(.down))
    var parts = tm()
    gmtime_r(&seconds, &parts)
    return String(
      format: "%04d%02d%02dT%02d%02d%02dZ",
      parts.tm_year + 1900,
      parts.tm_mon + 1,
      parts.tm_mday,
      parts.tm_hour,
      parts.tm_min,
      parts.tm_sec
    )
  } // End of func timestamp(_:)

  // MARK: - File contents

  /// The file's JSON shape, schema 1.
  struct FileContents: Codable {
    /// Always `HostStore.schemaVersion` when written.
    var schemaVersion: Int
    /// The hosts, in display order.
    var hosts: [HostConfig]
  }

  /// Only the schema version, read before the rest.
  struct SchemaHeader: Decodable {
    /// The file's schema version.
    var schemaVersion: Int
  }

  /// The result of decoding a file's bytes.
  enum Decoded {
    /// A valid list.
    case list(HostList)
    /// Why the bytes are not a usable list.
    case problem(HostFileProblem)
  }

  /// Decodes a host list file: valid JSON, then an object with an integer `schemaVersion`,
  /// then that version, then the hosts, then the invariants.
  static func decode(_ data: Data) -> Decoded {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return .problem(.notJSON) }
    guard object is [String: Any] else { return .problem(.malformed) }
    let decoder = JSONDecoder()
    guard let header = try? decoder.decode(SchemaHeader.self, from: data) else {
      return .problem(.malformed)
    }
    if header.schemaVersion > schemaVersion {
      return .problem(.newerSchemaVersion(header.schemaVersion))
    }
    guard header.schemaVersion == schemaVersion else {
      return .problem(.unsupportedSchemaVersion(header.schemaVersion))
    }
    guard let contents = try? decoder.decode(FileContents.self, from: data) else {
      return .problem(.malformed)
    }
    do throws(HostListError) {
      return .list(try HostList(contents.hosts))
    } catch {
      return .problem(.invariantBroken(error))
    }
  } // End of func decode(_:)

  /// Encodes `list` as a schema 1 file (sorted keys, pretty-printed, a final newline).
  static func encode(_ list: HostList) throws(HostStoreError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let contents = FileContents(schemaVersion: schemaVersion, hosts: list.hosts)
    guard var data = try? encoder.encode(contents) else { throw .encodingFailed }
    data.append(0x0A)
    guard data.count <= maximumFileSize else { throw .listTooLarge }
    return data
  }

  // MARK: - Reading the file

  /// What is at the file's name.
  enum Found {
    /// Nothing.
    case missing
    /// A symbolic link (never followed) or something other than a regular file; never read.
    case notAFile(HostFileProblem.UnsafeReason)
    /// A regular file: its bytes (`nil` when larger than the read limit) and the first
    /// reason, if any, not to trust them.
    case file(Data?, HostFileProblem.UnsafeReason?)
  }

  /// Opens `name` in `directory` without following links or blocking, and reads it if it is a
  /// regular file of at most `readLimit` bytes. The trust checks are D14's for files read:
  /// owned by `owner`, no group or other permissions, no extended ACL, at most
  /// `maximumFileSize` bytes. Never writes.
  static func examine(
    named name: String,
    in directory: Int32,
    owner: uid_t,
    readLimit: Int
  ) throws(HostStoreError) -> Found {
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { return .missing }
      if code == ELOOP { return .notAFile(.symbolicLink) }
      throw .systemCallFailed(name: "openat", errno: code)
    }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .systemCallFailed(name: "fstat", errno: errno)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { return .notAFile(.notARegularFile) }
    var reason = try trustProblem(of: descriptor, info: info, owner: owner)
    guard info.st_size <= off_t(readLimit) else { return .file(nil, reason ?? .tooLarge) }
    let data: Data
    do throws(PrivateStorageError) {
      data = try PrivateStorage.readAll(from: descriptor, limit: readLimit)
    } catch .fileTooLarge {
      return .file(nil, reason ?? .tooLarge)
    } catch {
      throw HostStoreError(error)
    }
    if reason == nil, data.count > maximumFileSize { reason = .tooLarge }
    return .file(data, reason)
  } // End of func examine(named:in:owner:readLimit:)

  /// The first reason not to trust the open regular file, if any.
  static func trustProblem(
    of descriptor: Int32,
    info: stat,
    owner: uid_t
  ) throws(HostStoreError) -> HostFileProblem.UnsafeReason? {
    if info.st_uid != owner { return .notOwnedByUser }
    if info.st_mode & 0o077 != 0 { return .permissionsTooOpen }
    let hasACL: Bool
    do throws(PrivateStorageError) {
      hasACL = try ExtendedACL.isPresent(on: descriptor)
    } catch {
      throw HostStoreError(error)
    }
    if hasACL { return .extendedACL }
    if info.st_size > off_t(maximumFileSize) { return .tooLarge }
    return nil
  } // End of func trustProblem(of:info:owner:)
}
