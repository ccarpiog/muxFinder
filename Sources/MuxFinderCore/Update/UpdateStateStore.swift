import Darwin
import Foundation

/// The outcome of loading the update state.
public struct UpdateStateLoadResult: Sendable, Hashable {
  /// What was found.
  public enum Found: Sendable, Hashable {
    /// A usable file.
    case saved
    /// No file (or no folder): never checked.
    case missing
    /// A file that cannot be used, with a machine-readable reason: never checked, and the file
    /// is replaced at the next save unless it is a symbolic link or not a regular file.
    case invalid(String)
  }

  /// The state; empty ("never checked") unless `found` is `saved`.
  public var state: UpdateState
  /// What was found.
  public var found: Found

  /// Creates a result.
  public init(state: UpdateState, found: Found) {
    self.state = state
    self.found = found
  }
}

/// Why the update state could not be saved. Messages and codes hold no file contents.
public enum UpdateStateStoreError: Error, Sendable, Hashable, LocalizedError {
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
  /// A folder that must already be private (`UpdateStateStore.DirectoryPolicy.existingPrivate`)
  /// gives group or others a permission, or carries an extended access control list; it was
  /// left as it is and nothing was written.
  case directoryNotPrivate
  /// A symbolic link or something other than a regular file has the state file's name; it was
  /// left alone and nothing was written.
  case existingFileNotRegular
  /// The state could not be encoded.
  case encodingFailed
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .directoryMissing: return "directoryMissing"
    case .directoryIsSymbolicLink: return "directoryIsSymbolicLink"
    case .directoryNotADirectory: return "directoryNotADirectory"
    case .directoryNotOwnedByUser: return "directoryNotOwnedByUser"
    case .directoryHasExtendedACL: return "directoryHasExtendedACL"
    case .directoryNotPrivate: return "directoryNotPrivate"
    case .existingFileNotRegular: return "existingFileNotRegular"
    case .encodingFailed: return "encodingFailed"
    case .systemCallFailed(let name, let code): return "systemCallFailed.\(name).\(code)"
    }
  } // End of var code

  /// The explanation, in English.
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
    case .directoryNotPrivate:
      return "The update state folder is open to other users or has an access control list, "
        + "so muxFinder left it as it is."
    case .existingFileNotRegular:
      return "The update state file isn't a regular file, so muxFinder left it as it is."
    case .encodingFailed:
      return "The update state couldn't be encoded."
    case .systemCallFailed(let name, let code):
      return "muxFinder couldn't save its update state (\(name): "
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
    case .fileTooLarge: self = .existingFileNotRegular
    case .systemCallFailed(let name, let code): self = .systemCallFailed(name: name, errno: code)
    }
  } // End of init(_:)
}

/// Where the update state lives (PLAN.md D39): `UpdateStateStore` on `update-state.json` in the
/// app and in the probe with `--state`, `InMemoryUpdateStateStore` in tests and in the probe
/// without it.
public protocol UpdateStateStoring: Sendable {
  /// Loads the state without writing anything; never fails (anything unusable is "never
  /// checked").
  func load() async -> UpdateStateLoadResult

  /// Keeps `state`.
  func save(_ state: UpdateState) async throws(UpdateStateStoreError)
}

/// Persists the update state as `update-state.json` in muxFinder's folder (PLAN.md D39), never
/// in the app's defaults domain. The format is `UpdateStateCoding`'s, at most
/// `maximumFileSize` bytes.
///
/// - **Loading never writes anything.** No folder or no file is `missing`; a file that cannot
///   be used (a symbolic link, never followed; not a regular file; another user's, readable by
///   others or with an extended ACL, D14's rules for files read; too large; not a valid state)
///   is `invalid`. Both give an empty state: never checked.
/// - **Saving** (the default `createAndSecure` policy, the app's, as the other stores do)
///   creates the folder (0700) when missing, its parent must exist, tightens it and strips any
///   ACL; with `existingPrivate` (the probe's `--state`) the folder must already exist and be
///   private, and is never created or changed (`directoryNotPrivate` otherwise). Either way a
///   save refuses when a symbolic link or anything other than a regular file has the file's
///   name (`existingFileNotRegular`, nothing written through it or in its place), and
///   otherwise writes a temporary file (0600, no ACL, flushed) and renames it over the name in
///   one step. An invalid file is replaced: it is a cache, so it gets no backup, and two
///   muxFinders saving at once need no lock (the last rename wins).
public actor UpdateStateStore: UpdateStateStoring {
  /// How a save treats the folder that holds the file.
  public enum DirectoryPolicy: Sendable, Hashable {
    /// Created (0700) when missing, then tightened to 0700 and stripped of any extended ACL,
    /// as the other stores do: muxFinder's own folder.
    case createAndSecure
    /// Used only when it already exists as the user's folder with no permission for group or
    /// others and no extended ACL; never created, tightened or stripped (a folder of the
    /// user's own choosing, the probe's `--state`).
    case existingPrivate
  }

  /// The state file's name in muxFinder's folder.
  public static let fileName = "update-state.json"
  /// The largest file loaded, in bytes.
  public static let maximumFileSize = 64 * 1024

  /// The state file.
  public nonisolated let fileURL: URL
  /// The user id that must own the folder and the file.
  nonisolated let owner: uid_t
  /// How a save treats the folder.
  public nonisolated let directoryPolicy: DirectoryPolicy

  /// The store at `<root>/update-state.json`. Production uses the default,
  /// `~/Library/Application Support/muxFinder/update-state.json`. Nothing is created.
  public init(paths: AppPaths = .standard) {
    self.init(
      fileURL: paths.applicationSupportDirectory.appending(
        path: Self.fileName, directoryHint: .notDirectory),
      owner: geteuid())
  }

  /// The store at `fileURL`, treating its folder as `directoryPolicy` says; its parent must
  /// exist for a save.
  public init(fileURL: URL, directoryPolicy: DirectoryPolicy = .createAndSecure) {
    self.init(fileURL: fileURL, owner: geteuid(), directoryPolicy: directoryPolicy)
  }

  /// The designated initializer. Tests pass another `owner`.
  init(fileURL: URL, owner: uid_t, directoryPolicy: DirectoryPolicy = .createAndSecure) {
    self.fileURL = fileURL
    self.owner = owner
    self.directoryPolicy = directoryPolicy
  }

  /// The folder that holds the file.
  public nonisolated var directoryURL: URL { fileURL.deletingLastPathComponent() }
  /// The file's name within its folder.
  nonisolated var name: String { fileURL.lastPathComponent }

  /// Loads the state without writing anything (see the type).
  public func load() -> UpdateStateLoadResult {
    let never = UpdateState()
    let directory: Int32
    do throws(PrivateStorageError) {
      directory = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL), owner: owner, access: .inspect)
    } catch .directoryMissing {
      return UpdateStateLoadResult(state: never, found: .missing)
    } catch {
      return UpdateStateLoadResult(state: never, found: .invalid("directory"))
    }
    defer { Darwin.close(directory) }
    switch read(in: directory) {
    case .missing:
      return UpdateStateLoadResult(state: never, found: .missing)
    case .unusable(let reason):
      return UpdateStateLoadResult(state: never, found: .invalid(reason))
    case .contents(let data):
      switch UpdateStateCoding.decode(data) {
      case .success(let state): return UpdateStateLoadResult(state: state, found: .saved)
      case .failure(let problem):
        return UpdateStateLoadResult(state: never, found: .invalid(problem.rawValue))
      }
    }
  } // End of func load()

  /// What reading the file gave.
  enum Read {
    /// No file.
    case missing
    /// A file that is not used, with the reason's code.
    case unusable(String)
    /// The bytes of a trusted regular file.
    case contents(Data)
  }

  /// Opens the file in `directory` without following a link or blocking and reads it when it
  /// is a regular file of `owner`'s, private (no group or other permission, no extended ACL),
  /// of at most `maximumFileSize` bytes.
  func read(in directory: Int32) -> Read {
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      switch errno {
      case ENOENT: return .missing
      case ELOOP: return .unusable("unsafe.symbolicLink")
      default: return .unusable("unreadable")
      }
    }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return .unusable("unreadable") }
    guard info.st_mode & S_IFMT == S_IFREG else { return .unusable("unsafe.notARegularFile") }
    guard info.st_uid == owner else { return .unusable("unsafe.notOwnedByUser") }
    guard info.st_mode & 0o077 == 0 else { return .unusable("unsafe.permissionsTooOpen") }
    guard (try? ExtendedACL.isPresent(on: descriptor)) == false else {
      return .unusable("unsafe.extendedACL")
    }
    guard info.st_size <= off_t(Self.maximumFileSize),
      let data = try? PrivateStorage.readAll(from: descriptor, limit: Self.maximumFileSize)
    else { return .unusable("unsafe.tooLarge") }
    return .contents(data)
  } // End of func read(in:)

  /// Saves `state` (see the type).
  public func save(_ state: UpdateState) throws(UpdateStateStoreError) {
    guard let data = UpdateStateCoding.encode(state), data.count <= Self.maximumFileSize else {
      throw .encodingFailed
    }
    let directory: Int32
    do throws(PrivateStorageError) {
      directory = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directoryURL), owner: owner,
        access: directoryPolicy == .createAndSecure ? .createAndSecure : .inspect)
    } catch {
      throw UpdateStateStoreError(error)
    }
    defer { Darwin.close(directory) }
    if directoryPolicy == .existingPrivate {
      try Self.checkAlreadyPrivate(directory)
    }
    try checkReplaceable(in: directory)
    do throws(PrivateStorageError) {
      try PrivateStorage.writeFile(
        data, named: name, exclusive: false, synchronize: true, in: directory)
    } catch {
      throw UpdateStateStoreError(error)
    }
  } // End of func save(_:)

  /// Refuses an open folder that is not already private: any permission for group or others,
  /// or an extended ACL entry (`directoryNotPrivate`). Reads only; changes nothing.
  static func checkAlreadyPrivate(_ directory: Int32) throws(UpdateStateStoreError) {
    var info = stat()
    guard fstat(directory, &info) == 0 else {
      throw .systemCallFailed(name: "fstat", errno: errno)
    }
    guard info.st_mode & 0o077 == 0 else { throw .directoryNotPrivate }
    let hasACL: Bool
    do throws(PrivateStorageError) {
      hasACL = try ExtendedACL.isPresent(on: directory)
    } catch {
      throw UpdateStateStoreError(error)
    }
    if hasACL { throw .directoryNotPrivate }
  } // End of static func checkAlreadyPrivate(_:)

  /// Refuses the save when a symbolic link or anything other than a regular file has the
  /// file's name; a regular file (whatever it holds) or no entry is fine.
  func checkReplaceable(in directory: Int32) throws(UpdateStateStoreError) {
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      let code = errno
      if code == ENOENT { return }
      throw .systemCallFailed(name: "fstatat", errno: code)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw .existingFileNotRegular }
  }
}

/// The update state kept in memory only: the tests' store, and the probe's without `--state`.
/// It never reads or writes a file.
public actor InMemoryUpdateStateStore: UpdateStateStoring {
  /// The state.
  public private(set) var state: UpdateState
  /// How many saves were kept.
  public private(set) var saveCount = 0
  /// When set, every save fails with this error and keeps nothing (tests).
  public private(set) var failure: UpdateStateStoreError?

  /// A store holding `state`.
  public init(_ state: UpdateState = UpdateState()) {
    self.state = state
  }

  /// Makes every later save fail with `failure` (`nil`: succeed again).
  public func setFailure(_ failure: UpdateStateStoreError?) {
    self.failure = failure
  }

  /// The state, as a usable file would give it (`missing` while it is empty).
  public func load() -> UpdateStateLoadResult {
    UpdateStateLoadResult(state: state, found: state == UpdateState() ? .missing : .saved)
  }

  /// Keeps `state`; fails with `failure` when one is set.
  public func save(_ state: UpdateState) throws(UpdateStateStoreError) {
    if let failure { throw failure }
    self.state = state
    saveCount += 1
  }
}
