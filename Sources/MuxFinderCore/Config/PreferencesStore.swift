import Darwin
import Foundation

/// What is wrong with a preferences file that cannot be used (PLAN.md D32). Loading leaves the
/// file exactly as it is (the session switcher shortcut is then off), and every change refuses
/// it (`PreferencesStoreError.fileNotUsable`) until it is fixed or moved away.
public enum PreferencesFileProblem: Error, Sendable, Hashable, CustomStringConvertible {
  /// Why the file is not trusted, whatever it contains: D14's and D19's rules for files read.
  public typealias UnsafeReason = HostFileProblem.UnsafeReason

  /// The file is not safe to trust.
  case unsafe(UnsafeReason)
  /// The file is not valid JSON.
  case notJSON
  /// The file is JSON but not an object with an integer `schemaVersion`.
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

  /// The user-facing explanation, in English and sentence case.
  public var message: String {
    switch self {
    case .unsafe(.symbolicLink):
      return "The preferences file is a symbolic link, so muxFinder doesn't use it."
    case .unsafe(.notARegularFile):
      return "The preferences file isn't a regular file."
    case .unsafe(.notOwnedByUser):
      return "The preferences file belongs to another user."
    case .unsafe(.permissionsTooOpen):
      return "Other users have access to the preferences file."
    case .unsafe(.extendedACL):
      return "The preferences file has an access control list, so other users might have access."
    case .unsafe(.tooLarge):
      return "The preferences file is too large."
    case .notJSON:
      return "The preferences file isn't valid JSON."
    case .malformed:
      return "The preferences file doesn't contain preferences muxFinder understands."
    case .newerSchemaVersion(let version):
      return "The preferences were saved by a newer version of muxFinder (format \(version))."
    case .unsupportedSchemaVersion(let version):
      return "The preferences file uses format \(version), which muxFinder doesn't support."
    }
  } // End of var message

  /// The same as `message`.
  public var description: String { message }
}

/// muxFinder's preferences (PLAN.md D32): today only the session switcher shortcut.
public struct Preferences: Sendable, Hashable {
  /// The session switcher's shortcut; `nil` when the hotkey is off.
  public var globalShortcut: GlobalShortcut?

  /// Preferences from their parts.
  public init(globalShortcut: GlobalShortcut? = nil) {
    self.globalShortcut = globalShortcut
  }
}

/// The outcome of loading the preferences.
public struct PreferencesLoadResult: Sendable, Hashable {
  /// What was found.
  public enum State: Sendable, Hashable {
    /// A usable file.
    case saved
    /// No file: nothing was recorded yet.
    case notSavedYet
    /// A file that cannot be used, left untouched.
    case invalid(PreferencesFileProblem)
  }

  /// The preferences, empty when there is no usable file.
  public var preferences: Preferences
  /// What was found.
  public var state: State
  /// Whether a usable file held a `globalShortcut` value that is not a usable shortcut (left
  /// out: the hotkey is off until the user records one).
  public var droppedShortcut: Bool

  /// Creates a result.
  public init(preferences: Preferences, state: State, droppedShortcut: Bool = false) {
    self.preferences = preferences
    self.state = state
    self.droppedShortcut = droppedShortcut
  }
}

/// The outcome of a change.
public struct PreferencesChangeResult: Sendable, Hashable {
  /// The preferences after the change.
  public var preferences: Preferences
  /// Whether the file was written (a change that changes nothing writes nothing).
  public var wrote: Bool
  /// The backup of the file the change displaced, when one was kept.
  public var backup: URL?
  /// `displacedFileNotKept` when the displaced file could not get a backup name; the new
  /// preferences are in place all the same.
  public var displacedFileError: PreferencesStoreError?

  /// Creates a result.
  public init(
    preferences: Preferences, wrote: Bool, backup: URL? = nil,
    displacedFileError: PreferencesStoreError? = nil
  ) {
    self.preferences = preferences
    self.wrote = wrote
    self.backup = backup
    self.displacedFileError = displacedFileError
  }
}

/// Why the preferences could not be loaded or changed. Messages and codes hold no file
/// contents.
public enum PreferencesStoreError: Error, Sendable, Hashable, LocalizedError {
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
  /// The file cannot be used, so the change was refused and the file left exactly as it is.
  case fileNotUsable(PreferencesFileProblem)
  /// A symbolic link or other non-regular file took the name after the change looked at it;
  /// it was left alone and nothing was written.
  case existingFileNotRegular
  /// A file too large to back up took the name after the change looked at it; it was left
  /// alone and nothing was written.
  case existingFileTooLarge
  /// Another muxFinder held `preferences.lock` for longer than a change waits.
  case busy
  /// `preferences.lock` could not be used (a symbolic link, not a regular file, another
  /// user's, or a system call failed).
  case lockUnavailable
  /// The preferences could not be encoded.
  case encodingFailed
  /// The encoded preferences are larger than `PreferencesStore.maximumFileSize`.
  case preferencesTooLarge
  /// The preferences were written, but the file they displaced could not be renamed to a
  /// backup name (this errno); it is still in the folder under this hidden temporary name.
  case displacedFileNotKept(temporaryName: String, errno: Int32)
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)

  /// A stable, machine-readable name: what the operation log records of a failure.
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
    case .encodingFailed: return "encodingFailed"
    case .preferencesTooLarge: return "preferencesTooLarge"
    case .displacedFileNotKept: return "displacedFileNotKept"
    case .systemCallFailed(let name, let code): return "systemCallFailed.\(name).\(code)"
    }
  } // End of var code

  /// The user-facing explanation.
  public var errorDescription: String? {
    switch self {
    case .directoryMissing:
      return "The folder that holds muxFinder's settings is missing."
    case .directoryIsSymbolicLink:
      return "muxFinder's settings folder is a symbolic link, so muxFinder doesn't use it."
    case .directoryNotADirectory:
      return "Something other than a folder is where muxFinder keeps its settings."
    case .directoryNotOwnedByUser:
      return "muxFinder's settings folder belongs to another user."
    case .directoryHasExtendedACL:
      return "muxFinder's settings folder has an access control list that couldn't be removed."
    case .fileNotUsable(let problem):
      return problem.message + " muxFinder left it as it is. Fix it or move it away."
    case .existingFileNotRegular:
      return "The preferences file isn't a regular file, so muxFinder left it as it is."
    case .existingFileTooLarge:
      return "The preferences file is too large to back up, so muxFinder left it as it is."
    case .busy:
      return "Another muxFinder is changing its preferences. Try again in a moment."
    case .lockUnavailable:
      return "muxFinder couldn't use the lock file in its settings folder."
    case .encodingFailed:
      return "The preferences couldn't be encoded."
    case .preferencesTooLarge:
      return "The preferences are too large to save."
    case .displacedFileNotKept(let temporaryName, let code):
      return "muxFinder saved its preferences but couldn't keep the file it replaced as a backup "
        + "(\(String(cString: strerror(code)))). That file is in muxFinder's settings folder "
        + "as \(temporaryName)."
    case .systemCallFailed(let name, let code):
      return "muxFinder couldn't read or write its preferences (\(name): "
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

/// Where muxFinder's preferences live (PLAN.md D32): `PreferencesStore` on `preferences.json`
/// in the app, `InMemoryPreferencesStore` in tests and previews.
public protocol PreferencesStoring: Sendable {
  /// Loads the preferences without writing anything.
  func load() async throws(PreferencesStoreError) -> PreferencesLoadResult

  /// Records `shortcut` as the session switcher's shortcut, or clears it (`nil`), and keeps
  /// the result. While the file cannot be used every change is refused (`fileNotUsable`) and
  /// the file stays as it is.
  func setGlobalShortcut(
    _ shortcut: GlobalShortcut?
  ) async throws(PreferencesStoreError) -> PreferencesChangeResult
}

/// Persists muxFinder's preferences as `preferences.json` in muxFinder's folder (PLAN.md D8,
/// D32), apart from `hosts.json` and `directories.json`, and never in the app's defaults
/// domain: muxFinder owns only its support folder (and `DynamicProfiles/muxFinder.json`), tests
/// then run on a private folder like the other stores, and nothing reaches
/// `~/Library/Preferences`.
///
/// The file is a JSON object, schema 1:
/// `{"globalShortcut": {"keyCode": 49, "modifiers": ["control", "option"]}, "schemaVersion": 1}`,
/// written pretty-printed with sorted keys and a final newline, at most `maximumFileSize`.
/// Modifier names are `control`, `option`, `shift` and `command`. Other keys are ignored when
/// read and kept as they are when the file is written. A missing or `null` `globalShortcut`
/// means the hotkey is off; one that is not a usable shortcut (not an object, a key code that
/// is not an integer up to `GlobalShortcut.maximumKeyCode`, an unknown modifier, a combination
/// `GlobalShortcut.check` refuses) is left out and reported (`droppedShortcut`), so the hotkey
/// is off too.
///
/// It is loaded and written as D19 and D31 treat `hosts.json` and `directories.json`:
/// - **Loading never writes anything**, not even the folder. No file gives empty preferences
///   (`notSavedYet`). A file that cannot be used (unsafe by D14's rules for files read, not
///   JSON, malformed, another schema version) gives empty preferences too, reported as
///   `invalid` with the problem, and stays exactly as it is.
/// - **A change** (`setGlobalShortcut(_:)`, only when the user records or clears a shortcut)
///   first reads the file as a load does, without the lock: a file that cannot be used refuses
///   it, and a change that changes nothing (the same shortcut, or a clear with none) ends there,
///   both writing nothing. Any other change takes an exclusive `flock` on `preferences.lock` in
///   the store's folder (waited for at most `lockWait`), reads the file again holding it, and
///   writes the result: the folder created (0700) or tightened and stripped of any ACL, a
///   temporary file (no ACL, 0600, flushed) published with one rename (`RENAME_SWAP` over a
///   file, `RENAME_EXCL` where none is). The displaced file is deleted only when it holds
///   exactly the bytes this store last read as fully usable or wrote; anything else is kept as
///   `preferences.backup-<UTC yyyyMMddTHHmmssZ>[-n].json`.
/// - The store is an actor, so its own changes never interleave.
public actor PreferencesStore: PreferencesStoring {
  /// The preferences file's name in muxFinder's folder.
  public static let fileName = "preferences.json"
  /// The schema version this muxFinder reads and writes.
  public static let schemaVersion = 1
  /// The largest file loaded, in bytes. A change that would write a larger one is refused.
  public static let maximumFileSize = 64 * 1024
  /// The largest file a write backs up when it displaces one it did not expect, in bytes.
  public static let maximumBackupSize = 16 * 1024 * 1024
  /// The lock file's name in the store's folder.
  public static let lockFileName = "preferences.lock"
  /// The file's key for the session switcher's shortcut.
  static let shortcutKey = "globalShortcut"
  /// How long a change waits for the lock unless told otherwise.
  static let defaultLockWait: Duration = .seconds(2)
  /// How many backup names with the same timestamp a write tries.
  static let maximumBackupAttempts = 100
  /// How many renames a write tries to publish its file.
  static let maximumPublishAttempts = 8

  /// The preferences file.
  public nonisolated let fileURL: URL
  /// The user id that must own the folder and the file.
  nonisolated let owner: uid_t
  /// The clock that dates backups.
  nonisolated let now: @Sendable () -> Date
  /// How long a change waits for `preferences.lock` before `busy`.
  nonisolated let lockWait: Duration
  /// Runs inside a write just before publication (tests); otherwise `nil`.
  nonisolated let beforePublishing: (@Sendable () -> Void)?
  /// The bytes this store last read as a fully usable file or wrote, or `nil`.
  var lastKnownContents: Data?

  /// The store at `<root>/preferences.json`. Production uses the default,
  /// `~/Library/Application Support/muxFinder/preferences.json`. Nothing is created.
  public init(paths: AppPaths = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
    self.init(
      fileURL: paths.applicationSupportDirectory.appending(
        path: Self.fileName, directoryHint: .notDirectory),
      owner: geteuid(), now: now)
  }

  /// The store at `fileURL`, for tests; its parent must exist for a write.
  public init(fileURL: URL, now: @escaping @Sendable () -> Date = { Date() }) {
    self.init(fileURL: fileURL, owner: geteuid(), now: now)
  }

  /// The designated initializer. Tests pass another `owner`, a short `lockWait` and a
  /// `beforePublishing` hook.
  init(
    fileURL: URL,
    owner: uid_t,
    now: @escaping @Sendable () -> Date,
    lockWait: Duration = PreferencesStore.defaultLockWait,
    beforePublishing: (@Sendable () -> Void)? = nil
  ) {
    self.fileURL = fileURL
    self.owner = owner
    self.now = now
    self.lockWait = lockWait
    self.beforePublishing = beforePublishing
  } // End of init(fileURL:owner:now:lockWait:beforePublishing:)

  /// The folder that holds the file.
  public nonisolated var directoryURL: URL { fileURL.deletingLastPathComponent() }
  /// The file's name within its folder.
  nonisolated var name: String { fileURL.lastPathComponent }

  // MARK: - Loading

  /// Loads the preferences without writing anything. Throws only when the folder cannot be
  /// used (a link, not a folder, another user's) or a system call fails.
  public func load() throws(PreferencesStoreError) -> PreferencesLoadResult {
    let read = Self.reading(try lookAtFile())
    lastKnownContents = read.usable
    return read.result
  }

  /// What is at the file's name now, looked at without writing anything.
  func lookAtFile() throws(PreferencesStoreError) -> Found {
    let directory: Int32
    do throws(PrivateStorageError) {
      directory = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL), owner: owner, access: .inspect)
    } catch .directoryMissing {
      return .missing
    } catch {
      throw PreferencesStoreError(error)
    }
    defer { Darwin.close(directory) }
    return try Self.examine(named: name, in: directory, owner: owner)
  } // End of func lookAtFile()

  /// One reading of the file: the load result, the file's JSON object when usable (what a write
  /// starts from) and its bytes when fully usable (what a write may delete when it displaces
  /// them).
  struct Reading {
    /// What a load returns.
    var result: PreferencesLoadResult
    /// The file's top-level object when it is usable; empty when there is no file.
    var fields: [String: Any]?
    /// The bytes, when usable with nothing left out.
    var usable: Data?
  }

  /// The reading of `found`.
  static func reading(_ found: Found) -> Reading {
    switch found {
    case .missing:
      return Reading(
        result: PreferencesLoadResult(preferences: Preferences(), state: .notSavedYet),
        fields: [:], usable: nil)
    case .notAFile(let reason), .file(_, .some(let reason)):
      return Reading(
        result: PreferencesLoadResult(preferences: Preferences(), state: .invalid(.unsafe(reason))),
        fields: nil, usable: nil)
    case .file(let data, .none):
      switch decode(data ?? Data()) {
      case .problem(let problem):
        return Reading(
          result: PreferencesLoadResult(preferences: Preferences(), state: .invalid(problem)),
          fields: nil, usable: nil)
      case .preferences(let preferences, let fields, let dropped):
        return Reading(
          result: PreferencesLoadResult(
            preferences: preferences, state: .saved, droppedShortcut: dropped),
          fields: fields, usable: dropped ? nil : data)
      }
    }
  } // End of static func reading(_:)

  // MARK: - Changing

  /// What a change comes to on the file as it is now.
  enum Plan {
    /// Nothing to write.
    case unchanged(PreferencesChangeResult)
    /// These preferences, encoded as `data`, must be written.
    case write(Data, Preferences)
  }

  /// Records `shortcut` as the session switcher's shortcut, or clears it (`nil`), keeping every
  /// other key of the file, and writes the result under `preferences.lock` unless it is what
  /// the file holds already. A file that cannot be used refuses the change and is left as it
  /// is. The shortcut is stored as given; the caller checks it first.
  public func setGlobalShortcut(
    _ shortcut: GlobalShortcut?
  ) throws(PreferencesStoreError) -> PreferencesChangeResult {
    // A first look without the lock, so a change that writes nothing never creates the folder
    // or the lock file, and an unusable file's folder is never touched.
    if case .unchanged(let result) = try plan(shortcut) { return result }
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
    switch try plan(shortcut) {
    case .unchanged(let result): return result
    case .write(let data, let preferences): return try write(data, preferences, in: directory)
    }
  } // End of func setGlobalShortcut(_:)

  /// Reads the file as a load does and works out what setting `shortcut` comes to: a file that
  /// cannot be used is `fileNotUsable`; the same shortcut (or a clear with none, with no
  /// unusable value to remove) is `unchanged`.
  func plan(_ shortcut: GlobalShortcut?) throws(PreferencesStoreError) -> Plan {
    let read = Self.reading(try lookAtFile())
    lastKnownContents = read.usable
    if case .invalid(let problem) = read.result.state { throw .fileNotUsable(problem) }
    var fields = read.fields ?? [:]
    let preferences = Preferences(globalShortcut: shortcut)
    let hadEntry = fields[Self.shortcutKey] != nil && !(fields[Self.shortcutKey] is NSNull)
    if read.result.preferences.globalShortcut == shortcut, shortcut != nil || !hadEntry {
      return .unchanged(PreferencesChangeResult(preferences: preferences, wrote: false))
    }
    fields["schemaVersion"] = Self.schemaVersion
    if let shortcut {
      fields[Self.shortcutKey] =
        [
          "keyCode": Int(shortcut.keyCode), "modifiers": shortcut.modifiers.names,
        ] as [String: Any]
    } else {
      fields[Self.shortcutKey] = nil
    }
    return .write(try Self.encode(fields), preferences)
  } // End of func plan(_:)

  /// Opens the store's folder for a write: created (0700) when missing, its parent must exist;
  /// tightened and stripped of any extended ACL.
  func openDirectoryForWriting() throws(PreferencesStoreError) -> Int32 {
    do throws(PrivateStorageError) {
      return try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL), owner: owner, access: .createAndSecure)
    } catch {
      throw PreferencesStoreError(error)
    }
  }

  /// Writes `data` in the open `directory` and publishes it, then settles the displaced entry.
  /// The caller holds the lock.
  func write(
    _ data: Data,
    _ preferences: Preferences,
    in directory: Int32
  ) throws(PreferencesStoreError) -> PreferencesChangeResult {
    let present = try prepareReplacement(in: directory)
    let temporary: String
    do throws(PrivateStorageError) {
      temporary = try PrivateStorage.writeTemporaryFile(
        data, for: name, synchronize: true, in: directory)
    } catch {
      throw PreferencesStoreError(error)
    }
    beforePublishing?()
    let displaced: Bool
    do throws(PreferencesStoreError) {
      displaced = try publish(temporary, replacing: present, in: directory)
    } catch {
      unlinkat(directory, temporary, 0)
      throw error
    }
    let expected = lastKnownContents
    lastKnownContents = data
    var result = PreferencesChangeResult(preferences: preferences, wrote: true)
    guard displaced else { return result }
    do throws(PreferencesStoreError) {
      let backup = try settleDisplaced(temporary, expecting: expected, in: directory)
      result.backup = backup.map { directoryURL.appending(path: $0, directoryHint: .notDirectory) }
    } catch {
      result.displacedFileError = error
    }
    return result
  } // End of func write(_:_:in:)

  /// Looks at the file's name before a write and returns whether a file is there. A symbolic
  /// link or other non-regular file and a file over `maximumBackupSize` refuse the write; a
  /// regular file of the user's loses any extended ACL, which would make the swap fail.
  func prepareReplacement(in directory: Int32) throws(PreferencesStoreError) -> Bool {
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

  /// Publishes the temporary file and returns whether that displaced an entry, which is then at
  /// `temporary`: `RENAME_SWAP` over a file, `RENAME_EXCL` where none is, switching on
  /// `ENOENT` / `EEXIST`, at most `maximumPublishAttempts` renames.
  func publish(
    _ temporary: String,
    replacing present: Bool,
    in directory: Int32
  ) throws(PreferencesStoreError) -> Bool {
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

  /// Deletes the displaced entry, now at `temporary`, when it is a trusted regular file
  /// holding exactly `expected`; keeps anything else as a backup and returns its name.
  func settleDisplaced(
    _ temporary: String,
    expecting expected: Data?,
    in directory: Int32
  ) throws(PreferencesStoreError) -> String? {
    let found = try? Self.examine(named: temporary, in: directory, owner: owner)
    switch found {
    case .missing:
      return nil
    case .file(.some(let data), .none) where data == expected:
      unlinkat(directory, temporary, 0)
      return nil
    default:
      break
    }
    PrivateStorage.makePrivate(named: temporary, in: directory, owner: owner)
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
  } // End of func settleDisplaced(_:expecting:in:)

  // MARK: - File contents

  /// Only the schema version, read before the rest.
  struct SchemaHeader: Decodable {
    /// The file's schema version.
    var schemaVersion: Int
  }

  /// The shortcut entry's shape.
  struct ShortcutEntry: Decodable {
    /// The virtual key code.
    var keyCode: Int
    /// The modifier names.
    var modifiers: [String]
  }

  /// The result of decoding a file's bytes.
  enum Decoded {
    /// Usable preferences, the file's object, and whether a shortcut value was left out.
    case preferences(Preferences, fields: [String: Any], dropped: Bool)
    /// Why the bytes are not usable.
    case problem(PreferencesFileProblem)
  }

  /// Decodes a preferences file: valid JSON, an object with an integer `schemaVersion`, that
  /// version; then the shortcut, left out (`dropped`) when it is not usable.
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
    var shortcut: GlobalShortcut?
    var dropped = false
    if let value = fields[shortcutKey], !(value is NSNull) {
      shortcut = Self.shortcut(from: value)
      dropped = shortcut == nil
    }
    return .preferences(Preferences(globalShortcut: shortcut), fields: fields, dropped: dropped)
  } // End of static func decode(_:)

  /// The usable shortcut in a `globalShortcut` value, or `nil`.
  static func shortcut(from value: Any) -> GlobalShortcut? {
    guard JSONSerialization.isValidJSONObject([value]),
      let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
      let entry = try? JSONDecoder().decode(ShortcutEntry.self, from: data),
      (0...Int(GlobalShortcut.maximumKeyCode)).contains(entry.keyCode),
      let modifiers = GlobalShortcut.Modifiers(names: entry.modifiers)
    else { return nil }
    let shortcut = GlobalShortcut(keyCode: UInt16(entry.keyCode), modifiers: modifiers)
    return shortcut.check.isUsable ? shortcut : nil
  } // End of static func shortcut(from:)

  /// Encodes the file's object (sorted keys, pretty-printed, slashes unescaped, a final
  /// newline).
  static func encode(_ fields: [String: Any]) throws(PreferencesStoreError) -> Data {
    guard JSONSerialization.isValidJSONObject(fields),
      var data = try? JSONSerialization.data(
        withJSONObject: fields, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    else { throw .encodingFailed }
    data.append(0x0A)
    guard data.count <= maximumFileSize else { throw .preferencesTooLarge }
    return data
  } // End of static func encode(_:)

  // MARK: - Reading the file

  /// What is at the file's name.
  enum Found {
    /// Nothing.
    case missing
    /// A symbolic link (never followed) or something other than a regular file; never read.
    case notAFile(PreferencesFileProblem.UnsafeReason)
    /// A regular file: its bytes (`nil` when larger than `maximumFileSize`) and the first
    /// reason, if any, not to trust them.
    case file(Data?, PreferencesFileProblem.UnsafeReason?)
  }

  /// Opens `name` in `directory` without following links or blocking, and reads it if it is a
  /// regular file of at most `maximumFileSize` bytes; the trust checks are D14's for files
  /// read (owned by `owner`, no group or other permissions, no extended ACL). Never writes.
  static func examine(
    named name: String,
    in directory: Int32,
    owner: uid_t
  ) throws(PreferencesStoreError) -> Found {
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
    var reason: PreferencesFileProblem.UnsafeReason?
    if info.st_uid != owner {
      reason = .notOwnedByUser
    } else if info.st_mode & 0o077 != 0 {
      reason = .permissionsTooOpen
    } else {
      do throws(PrivateStorageError) {
        if try ExtendedACL.isPresent(on: descriptor) { reason = .extendedACL }
      } catch {
        throw PreferencesStoreError(error)
      }
    }
    guard info.st_size <= off_t(maximumFileSize) else { return .file(nil, reason ?? .tooLarge) }
    do throws(PrivateStorageError) {
      return .file(try PrivateStorage.readAll(from: descriptor, limit: maximumFileSize), reason)
    } catch .fileTooLarge {
      return .file(nil, reason ?? .tooLarge)
    } catch {
      throw PreferencesStoreError(error)
    }
  } // End of static func examine(named:in:owner:)
}

/// Preferences kept in memory only (PLAN.md D32): the tests' and previews' store. It never
/// reads or writes a file, so `preferences.json` is never touched.
public actor InMemoryPreferencesStore: PreferencesStoring {
  /// The preferences.
  public private(set) var preferences: Preferences
  /// How many changes were kept (tests count the writes a real store would have made).
  public private(set) var changeCount = 0
  /// When set, every change fails with this error and keeps nothing (tests).
  public var failure: PreferencesStoreError?

  /// A store holding `preferences`.
  public init(_ preferences: Preferences = Preferences()) {
    self.preferences = preferences
  }

  /// Makes every later change fail with `failure` (`nil`: succeed again).
  public func setFailure(_ failure: PreferencesStoreError?) {
    self.failure = failure
  }

  /// The preferences, as a usable file would give them.
  public func load() -> PreferencesLoadResult {
    PreferencesLoadResult(preferences: preferences, state: .saved)
  }

  /// Keeps `shortcut` (or none) in memory; fails with `failure` when one is set.
  public func setGlobalShortcut(
    _ shortcut: GlobalShortcut?
  ) throws(PreferencesStoreError) -> PreferencesChangeResult {
    if let failure { throw failure }
    let changed = preferences.globalShortcut != shortcut
    preferences.globalShortcut = shortcut
    if changed { changeCount += 1 }
    return PreferencesChangeResult(preferences: preferences, wrote: false)
  }
}
