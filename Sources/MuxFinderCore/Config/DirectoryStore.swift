import Darwin
import Foundation

/// What is wrong with a directory list file that cannot be used (PLAN.md D31). Loading leaves
/// the file exactly as it is, and every change refuses it (`DirectoryStoreError.fileNotUsable`)
/// until it is fixed or moved away, so it is never replaced.
public enum DirectoryFileProblem: Error, Sendable, Hashable, CustomStringConvertible {
  /// Why the file is not trusted, whatever it contains: the rules D14 and D19 give for files
  /// read, the same as for `hosts.json`.
  public typealias UnsafeReason = HostFileProblem.UnsafeReason

  /// The file is not safe to trust.
  case unsafe(UnsafeReason)
  /// The file is not valid JSON.
  case notJSON
  /// The file is JSON but not a directory list of its schema version (not an object, no
  /// integer `schemaVersion`, `saved` not an array or `recent` not an object).
  case malformed
  /// The file was written by a newer muxFinder, with this schema version.
  case newerSchemaVersion(Int)
  /// The file has a schema version no muxFinder ever wrote (zero or negative).
  case unsupportedSchemaVersion(Int)

  /// A stable, machine-readable name for the problem.
  public var code: String {
    switch self {
    case .unsafe(let reason): return "unsafe.\(reason.rawValue)"
    case .notJSON: return "notJSON"
    case .malformed: return "malformed"
    case .newerSchemaVersion: return "newerSchemaVersion"
    case .unsupportedSchemaVersion: return "unsupportedSchemaVersion"
    }
  }

  /// The user-facing explanation, in English and sentence case. It names no directory.
  public var message: String {
    switch self {
    case .unsafe(.symbolicLink):
      return "The directory list file is a symbolic link, so muxFinder doesn't use it."
    case .unsafe(.notARegularFile):
      return "The directory list file isn't a regular file."
    case .unsafe(.notOwnedByUser):
      return "The directory list file belongs to another user."
    case .unsafe(.permissionsTooOpen):
      return "Other users have access to the directory list file."
    case .unsafe(.extendedACL):
      return
        "The directory list file has an access control list, so other users might have access."
    case .unsafe(.tooLarge):
      return "The directory list file is too large."
    case .notJSON:
      return "The directory list file isn't valid JSON."
    case .malformed:
      return "The directory list file doesn't contain directories muxFinder understands."
    case .newerSchemaVersion(let version):
      return
        "The directory list was saved by a newer version of muxFinder (format \(version))."
    case .unsupportedSchemaVersion(let version):
      return "The directory list file uses format \(version), which muxFinder doesn't support."
    }
  } // End of var message

  /// The same as `message`.
  public var description: String { message }
}

/// What a load has to tell the user about the directory list file (PLAN.md D31): it could not
/// be used, or some of its entries were left out. Counts only, never a directory.
public enum DirectoryStoreNotice: Sendable, Hashable {
  /// The file could not be used; the lists are empty and the file is left as it is.
  case fileNotUsed(DirectoryFileProblem)
  /// This many saved or recent entries broke a rule or a cap and were left out.
  case entriesDropped(Int)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .fileNotUsed(let problem): return "fileNotUsed.\(problem.code)"
    case .entriesDropped: return "entriesDropped"
    }
  }

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .fileNotUsed(let problem):
      return problem.message
        + " muxFinder shows no saved or recent directories from it, leaves it as it is and"
        + " saves no directories until it is fixed or moved away."
    case .entriesDropped(1):
      return "1 saved or recent directory in the directory list file wasn't usable and was left"
        + " out."
    case .entriesDropped(let count):
      return "\(count) saved or recent directories in the directory list file weren't usable and"
        + " were left out."
    }
  } // End of var message
}

/// The outcome of loading the directory lists.
public struct DirectoryStoreLoadResult: Sendable, Hashable {
  /// What was found.
  public enum State: Sendable, Hashable {
    /// A usable file; `lists` holds its entries (those that passed the checks).
    case saved
    /// No file (nothing was saved yet); the lists are empty.
    case notSavedYet
    /// A file that cannot be used, left untouched; the lists are empty.
    case invalid(DirectoryFileProblem)
  }

  /// The lists, empty when there is no usable file.
  public var lists: DirectoryLists
  /// What was found.
  public var state: State
  /// Entries of a usable file left out for breaking a rule or a cap.
  public var droppedEntryCount: Int

  /// Creates a result.
  public init(lists: DirectoryLists, state: State, droppedEntryCount: Int = 0) {
    self.lists = lists
    self.state = state
    self.droppedEntryCount = droppedEntryCount
  }

  /// What the user should be told, if anything.
  public var notice: DirectoryStoreNotice? {
    if case .invalid(let problem) = state { return .fileNotUsed(problem) }
    return droppedEntryCount > 0 ? .entriesDropped(droppedEntryCount) : nil
  }
}

/// The outcome of a change: the lists in place.
public struct DirectoryStoreChangeResult: Sendable, Hashable {
  /// The lists after the change (what the file holds now, unless it was not written).
  public var lists: DirectoryLists
  /// Whether the file was written (a change that changes nothing writes nothing; the in-memory
  /// store never writes).
  public var wrote: Bool
  /// The backup of the file the change displaced, when one was kept.
  public var backup: URL?
  /// `displacedFileNotKept` when the displaced file could not get a backup name; it is still in
  /// the folder under that temporary name, and the new lists are in place.
  public var displacedFileError: DirectoryStoreError?

  /// Creates a result.
  public init(
    lists: DirectoryLists,
    wrote: Bool,
    backup: URL? = nil,
    displacedFileError: DirectoryStoreError? = nil
  ) {
    self.lists = lists
    self.wrote = wrote
    self.backup = backup
    self.displacedFileError = displacedFileError
  }
}

/// Why the directory lists could not be loaded or changed. Messages and codes hold no
/// directory and no file contents.
public enum DirectoryStoreError: Error, Sendable, Hashable, LocalizedError {
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
  /// The file at the name cannot be used (unsafe, not JSON, malformed, another schema
  /// version), so the change was refused: the file was left exactly as it is, contents and
  /// metadata, and nothing was written (PLAN.md D31).
  case fileNotUsable(DirectoryFileProblem)
  /// A symbolic link or other non-regular file took the name after the change looked at it
  /// (only a program outside muxFinder can do that); it was left alone and nothing was written.
  case existingFileNotRegular
  /// A file too large to back up took the name after the change looked at it; it was left
  /// alone and nothing was written.
  case existingFileTooLarge
  /// Another muxFinder (another process, or another store in this one) held `directories.lock`
  /// for longer than a change waits; nothing was written.
  case busy
  /// `directories.lock` could not be used (a symbolic link, not a regular file, another user's,
  /// or a system call failed); nothing was written.
  case lockUnavailable
  /// The change was refused; nothing was written.
  case invalidChange(DirectoryListError)
  /// The lists could not be encoded.
  case encodingFailed
  /// The encoded lists are larger than `DirectoryStore.maximumFileSize`; nothing was written.
  case listsTooLarge
  /// The lists were written, but the file they displaced could not be renamed to a backup name
  /// (this errno); that file is still in the folder under this hidden temporary name.
  case displacedFileNotKept(temporaryName: String, errno: Int32)
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)

  /// A stable, machine-readable name: what the operation log records of a failed write.
  public var code: String {
    switch self {
    case .directoryMissing: return "directoryMissing"
    case .directoryIsSymbolicLink: return "directoryIsSymbolicLink"
    case .directoryNotADirectory: return "directoryNotADirectory"
    case .directoryNotOwnedByUser: return "directoryNotOwnedByUser"
    case .directoryHasExtendedACL: return "directoryHasExtendedACL"
    case .fileNotUsable(let problem): return "fileNotUsable.\(problem.code)"
    case .existingFileNotRegular: return "existingFileNotRegular"
    case .existingFileTooLarge: return "existingFileTooLarge"
    case .busy: return "busy"
    case .lockUnavailable: return "lockUnavailable"
    case .invalidChange(let error): return "invalidChange.\(error.code)"
    case .encodingFailed: return "encodingFailed"
    case .listsTooLarge: return "listsTooLarge"
    case .displacedFileNotKept: return "displacedFileNotKept"
    case .systemCallFailed(let name, let code): return "systemCallFailed.\(name).\(code)"
    }
  } // End of var code

  /// The user-facing explanation.
  public var errorDescription: String? {
    switch self {
    case .directoryMissing:
      return "muxFinder can't save its directories because the folder that holds them is missing."
    case .directoryIsSymbolicLink:
      return "muxFinder's settings folder is a symbolic link, so muxFinder doesn't use it."
    case .directoryNotADirectory:
      return "Something other than a folder is where muxFinder keeps its settings."
    case .directoryNotOwnedByUser:
      return "muxFinder's settings folder belongs to another user."
    case .directoryHasExtendedACL:
      return "muxFinder's settings folder has an access control list that couldn't be removed."
    case .fileNotUsable(let problem):
      return problem.message
        + " muxFinder left it as it is. Fix it or move it away to save directories."
    case .existingFileNotRegular:
      return "The directory list file isn't a regular file, so muxFinder left it as it is. "
        + "Move it away to save directories."
    case .existingFileTooLarge:
      return "The directory list file is too large to back up, so muxFinder left it as it is. "
        + "Move it away to save directories."
    case .busy:
      return "Another muxFinder is changing its directory list. Try again in a moment."
    case .lockUnavailable:
      return "muxFinder couldn't use the lock file in its settings folder, so it left its "
        + "directory list as it is."
    case .invalidChange(let error):
      return error.message
    case .encodingFailed:
      return "The directory list couldn't be encoded."
    case .listsTooLarge:
      return "The directory list is too large to save."
    case .displacedFileNotKept(let temporaryName, let code):
      return "muxFinder saved its directories but couldn't keep the file it replaced as a backup "
        + "(\(String(cString: strerror(code)))). That file is in muxFinder's settings folder "
        + "as \(temporaryName)."
    case .systemCallFailed(let name, let code):
      return "muxFinder couldn't read or write its directory list (\(name): "
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

/// Where New session's directories live (PLAN.md D31): `DirectoryStore` on
/// `directories.json` in the app, `InMemoryDirectoryStore` in the self-tests and tests.
public protocol DirectoryStoring: Sendable {
  /// Loads the lists without writing anything.
  func load() async throws(DirectoryStoreError) -> DirectoryStoreLoadResult

  /// Applies `change` to the lists as they are now, then forgets the recent directories of
  /// hosts not in `knownHosts` (`nil`: none are forgotten), and keeps the result. A refused
  /// change (`invalidChange`) keeps nothing, and neither does any change while the file cannot
  /// be used (`fileNotUsable`), which leaves it as it is.
  func apply(
    _ change: DirectoryListChange,
    knownHosts: Set<UUID>?
  ) async throws(DirectoryStoreError) -> DirectoryStoreChangeResult
}

/// Persists New session's directories as `directories.json` in muxFinder's folder (PLAN.md D8,
/// D31), beside `hosts.json` and apart from it: recent directories change at every creation,
/// and that must never race with, or create backups of, the host list.
///
/// The file is a JSON object, schema 1:
/// `{"schemaVersion": 1, "saved": ["~/…", …], "recent": {"<host id>": ["…", …]}}`, written
/// pretty-printed with sorted keys and a final newline, at most `maximumFileSize`. Unknown keys
/// are ignored when read. Every entry passes `DirectoryLists.check(_:)`; entries that break it
/// or the caps are left out when loading, and the result counts them (`droppedEntryCount`).
///
/// It is loaded and written the way PLAN.md D19 treats `hosts.json`:
/// - **Loading never writes anything**, not even the folder (`PrivateStorage`'s `inspect`
///   access). No file gives empty lists (`notSavedYet`). A file that cannot be used (unsafe by
///   D14's rules for files read, not JSON, malformed, another schema version) gives empty lists
///   too, reported as `invalid` with the problem, and stays exactly as it is.
/// - **A change** (`apply(_:knownHosts:)`) first reads the file as a load does, without the
///   lock. A file that cannot be used refuses every change (`fileNotUsable`): its contents and
///   metadata stay as they are and nothing is written, not even the folder or the lock file,
///   until the user fixes it or moves it away. A refused change (`invalidChange`), and one whose
///   result is what the file holds already (or empty lists with no file), end there too,
///   writing nothing. Any other change takes the lock and, holding it, reads the file again,
///   refuses it as above if it became unusable, applies the change to what it holds, forgets
///   the recent directories of hosts no longer in the host list and writes the result.
/// - **The lock** serializes that read, change and publication across every store instance and
///   muxFinder process (an installed app and a development build, say): an exclusive `flock`
///   on `directories.lock` in the store's folder (`PrivateStorage.acquireLock`, as
///   `profiles.lock` serializes D26's writers), created 0600 and never removed, waited for at
///   most `lockWait` (`busy`; a lock file that cannot be used is `lockUnavailable`). So no
///   change of another muxFinder is ever lost; only a program outside muxFinder can change the
///   file between the read and the publication, and what it wrote is then kept as a backup.
/// - **Writing** creates the folder (0700; its parent must exist) or tightens it and removes any
///   extended ACL, refuses a symbolic link or other non-regular file that took the name since
///   the read, or one over `maximumBackupSize`, writes a temporary file (no ACL, 0600, flushed)
///   and publishes it with one rename (`RENAME_SWAP` over a file, `RENAME_EXCL` where none is).
///   The displaced file is deleted only when it holds exactly the bytes this store last read
///   as fully usable (nothing left out) or wrote; anything else (a usable file with entries
///   left out, one another program put there during the write) is kept as
///   `directories.backup-<UTC yyyyMMddTHHmmssZ>[-n].json`, never replacing an earlier backup.
/// - The store is an actor, so its own changes never interleave either. It never reads or
///   writes `hosts.json` or its backups.
public actor DirectoryStore: DirectoryStoring {
  /// The directory list file's name in muxFinder's folder.
  public static let fileName = "directories.json"
  /// The schema version this muxFinder reads and writes.
  public static let schemaVersion = 1
  /// The largest file loaded, in bytes. A change that would write a larger one is refused.
  public static let maximumFileSize = 1024 * 1024
  /// The largest file a write backs up when it displaces one it did not expect, in bytes (a
  /// file that took the name after the read may be larger than `maximumFileSize`).
  public static let maximumBackupSize = 16 * 1024 * 1024
  /// The lock file's name in the store's folder.
  public static let lockFileName = "directories.lock"
  /// How long a change waits for the lock unless told otherwise. Holders keep it only for one
  /// read and one small write.
  static let defaultLockWait: Duration = .seconds(2)
  /// How many backup names with the same timestamp a write tries (`-2`, `-3`, …).
  static let maximumBackupAttempts = 100
  /// How many renames a write tries to publish its file while another process keeps creating
  /// or removing the file between them.
  static let maximumPublishAttempts = 8

  /// The directory list file.
  public nonisolated let fileURL: URL
  /// The user id that must own the folder and the file (this process's effective uid).
  nonisolated let owner: uid_t
  /// The clock that dates backups.
  nonisolated let now: @Sendable () -> Date
  /// How long a change waits for `directories.lock` before `busy`.
  nonisolated let lockWait: Duration
  /// Runs inside a write after the temporary file was written, just before publication (with
  /// the lock held). Tests use it to change the file in that window, or to start another
  /// store's change; otherwise `nil`.
  nonisolated let beforePublishing: (@Sendable () -> Void)?
  /// The bytes this store last read as a fully usable file or wrote, or `nil`. A write deletes
  /// the file it displaces only when it holds exactly these bytes.
  var lastKnownContents: Data?

  /// The store at `<root>/directories.json`. Production uses the default,
  /// `~/Library/Application Support/muxFinder/directories.json`. Nothing is created.
  public init(paths: AppPaths = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
    self.init(
      fileURL: paths.applicationSupportDirectory.appending(
        path: Self.fileName, directoryHint: .notDirectory),
      owner: geteuid(),
      now: now)
  }

  /// The store at `fileURL`, for tests. Its folder gets the same rules as muxFinder's own; its
  /// parent must exist for a write.
  public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.init(fileURL: fileURL, owner: geteuid(), now: now)
  }

  /// The designated initializer. Tests pass another `owner` to simulate a foreign folder, a
  /// short `lockWait`, and a `beforePublishing` hook to change the file while a write runs.
  init(
    fileURL: URL,
    owner: uid_t,
    now: @escaping @Sendable () -> Date,
    lockWait: Duration = DirectoryStore.defaultLockWait,
    beforePublishing: (@Sendable () -> Void)? = nil
  ) {
    self.fileURL = fileURL
    self.owner = owner
    self.now = now
    self.lockWait = lockWait
    self.beforePublishing = beforePublishing
  } // End of init(fileURL:owner:now:lockWait:beforePublishing:)

  /// The folder that holds the file.
  public nonisolated var directoryURL: URL {
    fileURL.deletingLastPathComponent()
  }

  /// The file's name within its folder.
  nonisolated var name: String { fileURL.lastPathComponent }

  // MARK: - Loading

  /// Loads the lists without writing anything. Throws only when the folder cannot be used (a
  /// link, not a folder, another user's) or a system call fails.
  public func load() throws(DirectoryStoreError) -> DirectoryStoreLoadResult {
    let (result, usable) = Self.loadResult(try lookAtFile())
    lastKnownContents = usable
    return result
  }

  /// What is at the file's name now, looked at without writing anything: the folder is only
  /// inspected (a missing folder means no file), the file read as `examine` reads it.
  func lookAtFile() throws(DirectoryStoreError) -> Found {
    let directory: Int32
    do throws(PrivateStorageError) {
      directory = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL), owner: owner, access: .inspect)
    } catch .directoryMissing {
      return .missing
    } catch {
      throw DirectoryStoreError(error)
    }
    defer { Darwin.close(directory) }
    return try Self.examine(named: name, in: directory, owner: owner)
  } // End of func lookAtFile()

  /// The load result for `found`, and its bytes when they are fully usable (a trusted, valid
  /// file with nothing left out), which a later write may then delete when it displaces them.
  static func loadResult(_ found: Found) -> (DirectoryStoreLoadResult, usable: Data?) {
    switch found {
    case .missing:
      return (DirectoryStoreLoadResult(lists: DirectoryLists(), state: .notSavedYet), nil)
    case .notAFile(let reason), .file(_, .some(let reason)):
      return (
        DirectoryStoreLoadResult(lists: DirectoryLists(), state: .invalid(.unsafe(reason))), nil
      )
    case .file(let data, .none):
      switch decode(data ?? Data()) {
      case .lists(let lists, let dropped):
        let result = DirectoryStoreLoadResult(
          lists: lists, state: .saved, droppedEntryCount: dropped)
        return (result, dropped == 0 ? data : nil)
      case .problem(let problem):
        return (DirectoryStoreLoadResult(lists: DirectoryLists(), state: .invalid(problem)), nil)
      }
    }
  } // End of static func loadResult(_:)

  // MARK: - Changing

  /// What a change comes to on the file as it is now.
  enum Plan {
    /// Nothing to write: the result is what the file holds already, or empty lists with no
    /// file.
    case unchanged(DirectoryStoreChangeResult)
    /// These lists, encoded as `data`, must be written.
    case write(Data, DirectoryLists)
  }

  /// Applies `change` to the file's lists as they are now (see the type's documentation) and
  /// writes the result under `directories.lock`, unless it is what the file holds already or
  /// there is no file and the lists are empty. With `knownHosts`, the recent directories of
  /// every other host are forgotten in the same write. A refused change, and every change
  /// while the file cannot be used (`fileNotUsable`), write nothing and leave the file as it is.
  public func apply(
    _ change: DirectoryListChange,
    knownHosts: Set<UUID>?
  ) throws(DirectoryStoreError) -> DirectoryStoreChangeResult {
    // A first look without the lock, so a change that writes nothing (or is refused) never
    // creates the folder or the lock file, and an unusable file's folder is never touched.
    if case .unchanged(let result) = try plan(change, knownHosts: knownHosts) { return result }
    let directory = try openDirectoryForWriting()
    defer { Darwin.close(directory) }
    let lock: Int32
    do throws(PrivateStorageLockError) {
      lock = try PrivateStorage.acquireLock(
        named: Self.lockFileName, in: directory, owner: owner, wait: lockWait)
    } catch .busy {
      throw .busy
    } catch {
      throw .lockUnavailable
    }
    defer { Darwin.close(lock) }
    // Under the lock, what another muxFinder wrote since the first look is read and kept.
    switch try plan(change, knownHosts: knownHosts) {
    case .unchanged(let result): return result
    case .write(let data, let lists): return try write(data, lists: lists, in: directory)
    }
  } // End of func apply(_:knownHosts:)

  /// Reads the file as a load does and works out what `change` (and the pruning) comes to: a
  /// file that cannot be used is `fileNotUsable` and a refused change `invalidChange`, both
  /// before anything is written. Remembers the bytes read when they are fully usable.
  func plan(
    _ change: DirectoryListChange,
    knownHosts: Set<UUID>?
  ) throws(DirectoryStoreError) -> Plan {
    let found = try lookAtFile()
    let (loaded, usable) = Self.loadResult(found)
    lastKnownContents = usable
    if case .invalid(let problem) = loaded.state { throw .fileNotUsable(problem) }
    var lists = loaded.lists
    do throws(DirectoryListError) {
      try lists.apply(change)
    } catch {
      throw .invalidChange(error)
    }
    if let knownHosts { lists.pruneRecents(keeping: knownHosts) }
    let data = try Self.encode(lists)
    if case .missing = found, lists.isEmpty {
      return .unchanged(DirectoryStoreChangeResult(lists: lists, wrote: false))
    }
    if usable == data { return .unchanged(DirectoryStoreChangeResult(lists: lists, wrote: false)) }
    return .write(data, lists)
  } // End of func plan(_:knownHosts:)

  /// Opens the store's folder for a write: created (0700) when missing, its parent must exist;
  /// tightened and stripped of any extended ACL.
  func openDirectoryForWriting() throws(DirectoryStoreError) -> Int32 {
    do throws(PrivateStorageError) {
      return try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL), owner: owner, access: .createAndSecure)
    } catch {
      throw DirectoryStoreError(error)
    }
  }

  /// Writes `data` (the encoded `lists`) in the open `directory` and publishes it, then
  /// settles the displaced entry. The caller holds the lock.
  func write(
    _ data: Data,
    lists: DirectoryLists,
    in directory: Int32
  ) throws(DirectoryStoreError) -> DirectoryStoreChangeResult {
    let present = try prepareReplacement(in: directory)
    let temporary: String
    do throws(PrivateStorageError) {
      temporary = try PrivateStorage.writeTemporaryFile(
        data, for: name, synchronize: true, in: directory)
    } catch {
      throw DirectoryStoreError(error)
    }
    beforePublishing?()
    let displaced: Bool
    do throws(DirectoryStoreError) {
      displaced = try publish(temporary, replacing: present, in: directory)
    } catch {
      // No rename succeeded, so the temporary file still holds only the new lists.
      unlinkat(directory, temporary, 0)
      throw error
    }
    let expected = lastKnownContents
    lastKnownContents = data
    var result = DirectoryStoreChangeResult(lists: lists, wrote: true)
    guard displaced else { return result }
    do throws(DirectoryStoreError) {
      let backup = try settleDisplaced(temporary, expecting: expected, in: directory)
      result.backup = backup.map { directoryURL.appending(path: $0, directoryHint: .notDirectory) }
    } catch {
      result.displacedFileError = error
    }
    return result
  } // End of func write(_:lists:in:)

  /// Looks at the file's name before a write, without reading the file, and returns whether a
  /// file is there. A symbolic link or other non-regular file (`existingFileNotRegular`) and a
  /// file over `maximumBackupSize` (`existingFileTooLarge`) are left as they are and refuse the
  /// write. A regular file of the user's loses any extended ACL, which would make the swap fail.
  func prepareReplacement(in directory: Int32) throws(DirectoryStoreError) -> Bool {
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

  /// Publishes the temporary file as the directory list file and returns whether that displaced
  /// an entry, which is then at `temporary`: `RENAME_SWAP` when a file was there, `RENAME_EXCL`
  /// when none was, switching on `ENOENT` / `EEXIST`, at most `maximumPublishAttempts` renames.
  /// On a throw nothing was renamed.
  func publish(
    _ temporary: String,
    replacing present: Bool,
    in directory: Int32
  ) throws(DirectoryStoreError) -> Bool {
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

  /// Deletes or keeps the entry a write displaced, now at `temporary`. It is deleted only when
  /// it is a trusted regular file holding exactly `expected` that loads with nothing left out;
  /// anything else, including an entry that cannot be examined, is kept (`keepBackup`).
  /// Returns the backup's name when one was kept.
  func settleDisplaced(
    _ temporary: String,
    expecting expected: Data?,
    in directory: Int32
  ) throws(DirectoryStoreError) -> String? {
    let found = try? Self.examine(named: temporary, in: directory, owner: owner)
    switch found {
    case .missing:
      return nil
    case .file(.some(let data), .none) where data == expected:
      if case .lists(_, 0) = Self.decode(data) {
        unlinkat(directory, temporary, 0)
        return nil
      }
    default:
      break
    }
    PrivateStorage.makePrivate(named: temporary, in: directory, owner: owner)
    return try keepBackup(temporary, in: directory)
  } // End of func settleDisplaced(_:expecting:in:)

  /// Renames the displaced entry at `temporary` to a new backup name next to the file and
  /// returns that name, never replacing an existing backup (`RENAME_EXCL`, the next free `-n`
  /// suffix). When no name is free or the rename fails, the entry stays at `temporary` and the
  /// write reports `displacedFileNotKept`.
  func keepBackup(_ temporary: String, in directory: Int32) throws(DirectoryStoreError) -> String {
    let timestamp = PrivateStorage.backupTimestamp(now())
    var failure = EEXIST
    for attempt in 1...Self.maximumBackupAttempts {
      let candidate = PrivateStorage.backupName(for: name, timestamp: timestamp, attempt: attempt)
      if renameatx_np(directory, temporary, directory, candidate, UInt32(RENAME_EXCL)) == 0 {
        return candidate
      }
      failure = errno
      guard failure == EEXIST else { break }
    } // End of loop over backup names
    throw .displacedFileNotKept(temporaryName: temporary, errno: failure)
  } // End of func keepBackup(_:in:)

  // MARK: - File contents

  /// The file's JSON shape, schema 1, as written.
  struct FileContents: Encodable {
    /// Always `DirectoryStore.schemaVersion`.
    var schemaVersion: Int
    /// The saved directories, in order.
    var saved: [String]
    /// The recent directories per host id (`UUID.uuidString`), newest first.
    var recent: [String: [String]]
  }

  /// Only the schema version, read before the rest (as `HostStore` reads it).
  struct SchemaHeader: Decodable {
    /// The file's schema version.
    var schemaVersion: Int
  }

  /// The result of decoding a file's bytes.
  enum Decoded {
    /// Usable lists, and how many entries were left out.
    case lists(DirectoryLists, dropped: Int)
    /// Why the bytes are not usable.
    case problem(DirectoryFileProblem)
  }

  /// Decodes a directory list file: valid JSON, an object with an integer `schemaVersion`, that
  /// version, then `saved` (an array, if present) and `recent` (an object of arrays, if
  /// present). An entry that is not a string or breaks `DirectoryLists.check(_:)`, a host key
  /// that is not a UUID (with its entries), a host value that is not an array, and entries past
  /// the caps are left out and counted; other keys are ignored.
  static func decode(_ data: Data) -> Decoded {
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return .problem(.notJSON) }
    guard let fields = object as? [String: Any] else { return .problem(.malformed) }
    guard let header = try? JSONDecoder().decode(SchemaHeader.self, from: data) else {
      return .problem(.malformed)
    }
    if header.schemaVersion > schemaVersion {
      return .problem(.newerSchemaVersion(header.schemaVersion))
    }
    guard header.schemaVersion == schemaVersion else {
      return .problem(.unsupportedSchemaVersion(header.schemaVersion))
    }
    var dropped = 0
    var saved: [String] = []
    if let value = fields["saved"] {
      guard let entries = value as? [Any] else { return .problem(.malformed) }
      saved = strings(in: entries, droppedCount: &dropped)
    }
    var recent: [UUID: [String]] = [:]
    if let value = fields["recent"] {
      guard let hosts = value as? [String: Any] else { return .problem(.malformed) }
      for key in hosts.keys.sorted() {
        guard let entries = hosts[key] as? [Any] else {
          dropped += 1
          continue
        }
        guard let hostID = UUID(uuidString: key) else {
          dropped += entries.count
          continue
        }
        recent[hostID, default: []] += strings(in: entries, droppedCount: &dropped)
      } // End of loop over recent hosts
    }
    let lists = DirectoryLists(saved: saved, recent: recent, droppedCount: &dropped)
    return .lists(lists, dropped: dropped)
  } // End of static func decode(_:)

  /// The strings of `entries`, in order; every other value is left out and counted.
  static func strings(in entries: [Any], droppedCount: inout Int) -> [String] {
    var strings: [String] = []
    for entry in entries {
      if let string = entry as? String {
        strings.append(string)
      } else {
        droppedCount += 1
      }
    }
    return strings
  }

  /// Encodes `lists` as a schema 1 file (sorted keys, pretty-printed, slashes unescaped, a final
  /// newline).
  static func encode(_ lists: DirectoryLists) throws(DirectoryStoreError) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let contents = FileContents(
      schemaVersion: schemaVersion,
      saved: lists.saved,
      recent: Dictionary(uniqueKeysWithValues: lists.recent.map { ($0.key.uuidString, $0.value) }))
    guard var data = try? encoder.encode(contents) else { throw .encodingFailed }
    data.append(0x0A)
    guard data.count <= maximumFileSize else { throw .listsTooLarge }
    return data
  } // End of static func encode(_:)

  // MARK: - Reading the file

  /// What is at the file's name.
  enum Found {
    /// Nothing.
    case missing
    /// A symbolic link (never followed) or something other than a regular file; never read.
    case notAFile(DirectoryFileProblem.UnsafeReason)
    /// A regular file: its bytes (`nil` when larger than `maximumFileSize`) and the first
    /// reason, if any, not to trust them.
    case file(Data?, DirectoryFileProblem.UnsafeReason?)
  }

  /// Opens `name` in `directory` without following links or blocking, and reads it if it is a
  /// regular file of at most `maximumFileSize` bytes. The trust checks are D14's for files
  /// read: owned by `owner`, no group or other permissions, no extended ACL, at most
  /// `maximumFileSize` bytes. Never writes.
  static func examine(
    named name: String,
    in directory: Int32,
    owner: uid_t
  ) throws(DirectoryStoreError) -> Found {
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
    let reason = try trustProblem(of: descriptor, info: info, owner: owner)
    guard info.st_size <= off_t(maximumFileSize) else { return .file(nil, reason ?? .tooLarge) }
    do throws(PrivateStorageError) {
      return .file(try PrivateStorage.readAll(from: descriptor, limit: maximumFileSize), reason)
    } catch .fileTooLarge {
      return .file(nil, reason ?? .tooLarge)
    } catch {
      throw DirectoryStoreError(error)
    }
  } // End of static func examine(named:in:owner:)

  /// The first reason not to trust the open regular file, if any.
  static func trustProblem(
    of descriptor: Int32,
    info: stat,
    owner: uid_t
  ) throws(DirectoryStoreError) -> DirectoryFileProblem.UnsafeReason? {
    if info.st_uid != owner { return .notOwnedByUser }
    if info.st_mode & 0o077 != 0 { return .permissionsTooOpen }
    let hasACL: Bool
    do throws(PrivateStorageError) {
      hasACL = try ExtendedACL.isPresent(on: descriptor)
    } catch {
      throw DirectoryStoreError(error)
    }
    if hasACL { return .extendedACL }
    if info.st_size > off_t(maximumFileSize) { return .tooLarge }
    return nil
  } // End of static func trustProblem(of:info:owner:)
}

/// Directories kept in memory only (PLAN.md D31): the self-tests' and the tests' store. It
/// never reads or writes a file, so `directories.json` is never touched.
public actor InMemoryDirectoryStore: DirectoryStoring {
  /// The lists.
  public private(set) var lists: DirectoryLists
  /// How many changes were kept (tests count the writes a real store would have made).
  public private(set) var changeCount = 0

  /// A store holding `lists`.
  public init(_ lists: DirectoryLists = DirectoryLists()) {
    self.lists = lists
  }

  /// The lists, as a usable file would give them.
  public func load() -> DirectoryStoreLoadResult {
    DirectoryStoreLoadResult(lists: lists, state: .saved)
  }

  /// Applies `change` (and the pruning) to the lists in memory, as `DirectoryStore` would to
  /// its file; a refused change keeps nothing.
  public func apply(
    _ change: DirectoryListChange,
    knownHosts: Set<UUID>?
  ) throws(DirectoryStoreError) -> DirectoryStoreChangeResult {
    var changed = lists
    do throws(DirectoryListError) {
      try changed.apply(change)
    } catch {
      throw .invalidChange(error)
    }
    if let knownHosts { changed.pruneRecents(keeping: knownHosts) }
    lists = changed
    changeCount += 1
    return DirectoryStoreChangeResult(lists: changed, wrote: false)
  } // End of func apply(_:knownHosts:)
}
