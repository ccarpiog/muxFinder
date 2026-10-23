import Darwin
import Foundation

/// Why muxFinder's dynamic profile file could not be read, written or removed. Nothing in a
/// message comes from a file. `message` is English, sentence case.
public enum PersistentProfileInstallerError: Error, Sendable, Hashable, LocalizedError {
  /// iTerm2's folder (the `DynamicProfiles` folder's parent) does not exist, so the folder
  /// cannot be created: iTerm2 has not been run as this user.
  case directoryMissing
  /// The `DynamicProfiles` folder is a symbolic link (never followed: a synced or shared folder
  /// would carry this Mac's profiles to other Macs).
  case directoryIsSymbolicLink
  /// Something other than a folder is at the `DynamicProfiles` path.
  case directoryNotADirectory
  /// Another user owns the `DynamicProfiles` folder.
  case directoryNotOwnedByUser
  /// `muxFinder.json` is a symbolic link; it was left as it is.
  case fileIsSymbolicLink
  /// `muxFinder.json` is not a regular file; it was left as it is.
  case fileNotRegular
  /// Another user owns `muxFinder.json`; it was left as it is.
  case fileNotOwnedByUser
  /// `muxFinder.json` is larger than `PersistentProfiles.maximumFileSize`; it was left as it
  /// is.
  case fileTooLarge
  /// `muxFinder.json` exists and the install was asked never to replace a file (the e2e
  /// harness's, which must not touch a file that is the user's); it was left as it is.
  case fileAlreadyExists
  /// `muxFinder.json` is not the file the operation expected (its bytes differ from what a
  /// removal expected, or another entry took its name while the file was being replaced or
  /// removed); it was left as it is, or put back.
  case fileChanged
  /// An entry that took `muxFinder.json`'s name during the operation could not be put back, or
  /// was displaced in turn by the swap that put another one back; it is in the folder under
  /// this hidden name, never deleted.
  case displacedEntryKept(temporaryName: String)
  /// Another muxFinder process held the lock that serializes changes to `muxFinder.json`
  /// longer than an install or removal waits; nothing was changed.
  case busy
  /// The lock in muxFinder's own folder could not be used (the folder or `profiles.lock` is a
  /// symbolic link, not what it should be or another user's, or a system call failed);
  /// nothing was changed.
  case lockUnavailable
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .directoryMissing:
      return "iTerm2's settings folder doesn't exist yet. Open iTerm2 once, then try again."
    case .directoryIsSymbolicLink:
      return "iTerm2's DynamicProfiles folder is a symbolic link, so muxFinder doesn't write "
        + "to it."
    case .directoryNotADirectory:
      return "Something other than a folder is where iTerm2 keeps its dynamic profiles."
    case .directoryNotOwnedByUser:
      return "iTerm2's DynamicProfiles folder belongs to another user."
    case .fileIsSymbolicLink:
      return "muxFinder.json in iTerm2's DynamicProfiles folder is a symbolic link, so "
        + "muxFinder left it as it is."
    case .fileNotRegular:
      return "muxFinder.json in iTerm2's DynamicProfiles folder isn't a regular file, so "
        + "muxFinder left it as it is."
    case .fileNotOwnedByUser:
      return "muxFinder.json in iTerm2's DynamicProfiles folder belongs to another user, so "
        + "muxFinder left it as it is."
    case .fileTooLarge:
      return "muxFinder.json in iTerm2's DynamicProfiles folder is too large to be "
        + "muxFinder's, so muxFinder left it as it is."
    case .fileAlreadyExists:
      return "muxFinder.json already exists in iTerm2's DynamicProfiles folder, so muxFinder "
        + "left it as it is."
    case .fileChanged:
      return "muxFinder.json changed while muxFinder was updating it, so muxFinder left it as "
        + "it is."
    case .displacedEntryKept(let temporaryName):
      return "Something replaced muxFinder.json while muxFinder was updating it. It was kept in "
        + "iTerm2's DynamicProfiles folder as \(temporaryName)."
    case .busy:
      return "Another muxFinder is updating its iTerm2 profiles. Try again in a moment."
    case .lockUnavailable:
      return "muxFinder couldn't use the lock file in its own folder, so it left its iTerm2 "
        + "profiles as they are."
    case .systemCallFailed(let name, let code):
      return "muxFinder couldn't update its iTerm2 profiles (\(name): "
        + "\(String(cString: strerror(code))))."
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }
}

/// How the installed `muxFinder.json` compares with a document.
public enum PersistentProfileFileStatus: String, Sendable, Hashable {
  /// No file is installed (and the document is empty, or not installed yet).
  case notInstalled
  /// The installed file holds exactly the document's bytes.
  case current
  /// The installed file differs from the document (for example, the helper moved, PLAN.md
  /// D26), or a file is installed while the document is empty.
  case stale
}

/// Writes and removes muxFinder's one iTerm2 file, `DynamicProfiles/muxFinder.json`
/// (PLAN.md D8, D26), and never touches anything else in that folder: no other file is read,
/// renamed or deleted, and the folder itself is never changed (no mode or ACL change). The
/// folder is injectable; tests use private temporary folders only.
///
/// - **Folder:** `~/Library/Application Support/iTerm2/DynamicProfiles` by default. It must be
///   the user's own folder and not a symbolic link (a synced or shared folder would carry this
///   Mac's helper path and host ids elsewhere). An install creates it (mode 0755, as iTerm2
///   does) only when it is missing and its parent exists; nothing else creates it.
/// - **The file:** `muxFinder.json` is only ever opened without following links
///   (`O_NOFOLLOW`): a symbolic link, a non-regular file, another user's file or one over
///   `PersistentProfiles.maximumFileSize` is refused and left exactly as it is.
/// - **Install** (atomic): a document identical to the installed bytes writes nothing
///   (`unchanged`). Otherwise the bytes go to a hidden temporary file in the same folder
///   (`.muxFinder.json.<random hex>.tmp`, `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, flushed;
///   iTerm2 skips names that start with a dot), which is published with one rename:
///   `RENAME_EXCL` when no file is there, so nothing that appeared is replaced, or `RENAME_SWAP`
///   with the checked file, after which the displaced entry is deleted only when it is still
///   that same file (device and inode); anything else that took the name meanwhile is swapped
///   back, and what that swap back displaces is deleted only when it is this install's own
///   temporary file (its device and inode, taken before publishing), else kept under the
///   hidden name (`displacedEntryKept`). An empty document (no host has a persistent profile)
///   removes the file instead.
/// - **Remove:** deletes only `muxFinder.json`: the checked file is first renamed aside to a
///   hidden temporary name (`RENAME_EXCL`) and deleted only when it is still that same file;
///   an expected content, when given, must match first (the e2e harness removes only the file
///   it wrote).
/// - **Serialization:** every install and removal, in every muxFinder process, holds an
///   exclusive `flock` on `profiles.lock` in muxFinder's own folder (`lockDirectory`, never
///   iTerm2's) from before it looks at the file until it is done, so cooperating writers never
///   interleave; only a writer outside muxFinder can take the name meanwhile. The lock is
///   waited for at most `lockWait` (`busy`). Reads take no lock.
/// - **Status:** compares the installed bytes with a document (`current`, `stale`,
///   `notInstalled`) without writing, for Phase 11c's rewrite at launch.
public struct PersistentProfileInstaller: Sendable {
  /// iTerm2's dynamic profiles folder.
  public static var standardDirectory: URL {
    URL.applicationSupportDirectory.appending(path: "iTerm2", directoryHint: .isDirectory)
      .appending(path: "DynamicProfiles", directoryHint: .isDirectory)
  }

  /// muxFinder's own folder, `~/Library/Application Support/muxFinder`, which holds the lock.
  public static var standardLockDirectory: URL {
    AppPaths.standard.applicationSupportDirectory
  }

  /// The mode of a `DynamicProfiles` folder an install creates.
  static let createdDirectoryPermissions: mode_t = 0o755
  /// The lock file's name in `lockDirectory`.
  static let lockFileName = "profiles.lock"
  /// How long an install or removal waits for the lock unless told otherwise.
  static let defaultLockWait: Duration = .seconds(5)
  /// The pause between two tries of a busy lock, in microseconds.
  static let lockRetryInterval: useconds_t = 10_000

  /// The folder.
  public let directory: URL
  /// The folder that holds `profiles.lock`: muxFinder's own.
  public let lockDirectory: URL
  /// The user id that must own the folders and the files (this process's effective uid).
  let owner: uid_t
  /// How long an install or removal waits for the lock before `busy`.
  let lockWait: Duration
  /// Runs inside `publish` after a swap displaced an entry that is not the checked file, just
  /// before the swap back. Tests use it to publish another file in that window; otherwise
  /// `nil`.
  let beforeSwappingBack: (@Sendable () -> Void)?

  /// An installer for iTerm2's own folder, its lock in muxFinder's own folder.
  public init() {
    self.init(directory: Self.standardDirectory, lockDirectory: Self.standardLockDirectory)
  }

  /// An installer for `directory`, its lock in `lockDirectory` (tests pass private folders for
  /// both).
  public init(directory: URL, lockDirectory: URL) {
    self.init(directory: directory, lockDirectory: lockDirectory, owner: geteuid())
  }

  /// The designated initializer; tests pass another `owner` to simulate a foreign folder, a
  /// short `lockWait`, and a `beforeSwappingBack` hook.
  init(
    directory: URL,
    lockDirectory: URL,
    owner: uid_t,
    lockWait: Duration = PersistentProfileInstaller.defaultLockWait,
    beforeSwappingBack: (@Sendable () -> Void)? = nil
  ) {
    self.directory = directory
    self.lockDirectory = lockDirectory
    self.owner = owner
    self.lockWait = lockWait
    self.beforeSwappingBack = beforeSwappingBack
  } // End of init(directory:lockDirectory:owner:lockWait:beforeSwappingBack:)

  /// The file's URL.
  public var fileURL: URL {
    directory.appending(path: PersistentProfiles.fileName, directoryHint: .notDirectory)
  }

  /// The file's name.
  var name: String { PersistentProfiles.fileName }

  // MARK: - Reading

  /// The installed file's bytes, or `nil` when there is no file (or no folder). Never writes.
  public func installedContents() throws(PersistentProfileInstallerError) -> Data? {
    guard let directory = try openDirectory(create: false) else { return nil }
    defer { Darwin.close(directory) }
    return try examine(in: directory)?.data
  }

  /// How the installed file compares with `document`. Never writes.
  public func status(
    for document: PersistentProfileDocument
  ) throws(PersistentProfileInstallerError) -> PersistentProfileFileStatus {
    guard let installed = try installedContents() else { return .notInstalled }
    return installed == document.data && !document.isEmpty ? .current : .stale
  }

  // MARK: - Installing

  /// What `install(_:replacing:)` did.
  public enum InstallOutcome: String, Sendable, Hashable {
    /// The document's bytes were written.
    case written
    /// The installed file already held exactly those bytes; nothing was written.
    case unchanged
    /// The document was empty and the installed file was removed.
    case removed
    /// The document was empty and no file was installed; nothing was done.
    case nothingToRemove
  }

  /// Whether an install may replace an existing `muxFinder.json`.
  public enum ReplacePolicy: Sendable, Hashable {
    /// Replace it (it is muxFinder's own file, D8): the app's install and rewrite.
    case replaceExisting
    /// Never replace one (`fileAlreadyExists`): the e2e harness, which must not touch a file
    /// that is the user's.
    case createOnly
  }

  /// Installs `document` atomically under the lock (see the type's documentation); an empty
  /// document removes the file.
  @discardableResult
  public func install(
    _ document: PersistentProfileDocument,
    replacing policy: ReplacePolicy = .replaceExisting
  ) throws(PersistentProfileInstallerError) -> InstallOutcome {
    guard !document.isEmpty else {
      return try remove() == .removed ? .removed : .nothingToRemove
    }
    guard document.data.count <= PersistentProfiles.maximumFileSize else { throw .fileTooLarge }
    guard let directory = try openDirectory(create: true) else { throw .directoryMissing }
    defer { Darwin.close(directory) }
    let lock = try acquireLock()
    defer { Darwin.close(lock) }
    let existing = try examine(in: directory)
    if let existing {
      if existing.data == document.data { return .unchanged }
      if policy == .createOnly { throw .fileAlreadyExists }
    }
    let temporary: String
    do throws(PrivateStorageError) {
      temporary = try PrivateStorage.writeTemporaryFile(
        document.data, for: name, synchronize: true, in: directory)
    } catch {
      throw Self.error(error)
    }
    try publish(temporary, replacing: existing?.identity, in: directory)
    return .written
  } // End of func install(_:replacing:)

  /// Publishes the temporary file as `muxFinder.json`. With no file there (`replacing` is
  /// `nil`), `RENAME_EXCL`: a file that appeared meanwhile is never replaced (`fileChanged`).
  /// Otherwise `RENAME_SWAP`, then the displaced entry is deleted only when it is the checked
  /// file; anything else is swapped back (`fileChanged`), or kept under the temporary name when
  /// that fails (`displacedEntryKept`). The swap back displaces whatever holds the name at that
  /// instant: it is deleted only when it is this install's own temporary file (identity taken
  /// before publishing); a file another writer published meanwhile is kept under the
  /// temporary name (`displacedEntryKept`), never deleted. On a throw, the new bytes are never
  /// left at the name unless the displaced entry could not be put back.
  func publish(
    _ temporary: String,
    replacing checked: EntryIdentity?,
    in directory: Int32
  ) throws(PersistentProfileInstallerError) {
    guard let checked else {
      guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL)) == 0 else {
        let code = errno
        unlinkat(directory, temporary, 0)
        throw code == EEXIST ? .fileChanged : .systemCallFailed(name: "renameatx_np", errno: code)
      }
      return
    }
    // This install's own file: the only entry a swap back may delete.
    guard let candidate = Self.identity(of: temporary, in: directory) else { throw .fileChanged }
    guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_SWAP)) == 0 else {
      let code = errno
      unlinkat(directory, temporary, 0)
      throw code == ENOENT ? .fileChanged : .systemCallFailed(name: "renameatx_np", errno: code)
    }
    if Self.identity(of: temporary, in: directory) == checked {
      unlinkat(directory, temporary, 0)
      return
    }
    // Another entry took the name between the check and the swap: put it back.
    beforeSwappingBack?()
    guard renameatx_np(directory, temporary, directory, name, UInt32(RENAME_SWAP)) == 0 else {
      throw .displacedEntryKept(temporaryName: temporary)
    }
    // A writer outside the lock may have published another file after the first swap; the
    // swap back displaced that one then, and it is kept.
    guard Self.identity(of: temporary, in: directory) == candidate else {
      throw .displacedEntryKept(temporaryName: temporary)
    }
    unlinkat(directory, temporary, 0)
    throw .fileChanged
  } // End of func publish(_:replacing:in:)

  // MARK: - Removing

  /// What `remove(expecting:)` did.
  public enum RemoveOutcome: String, Sendable, Hashable {
    /// `muxFinder.json` was deleted.
    case removed
    /// There was no `muxFinder.json` (or no folder); nothing was done.
    case notInstalled
  }

  /// Deletes `muxFinder.json`, and nothing else. With `expected`, only while the file holds
  /// exactly those bytes (`fileChanged` otherwise, nothing deleted). A symbolic link, a
  /// non-regular file, another user's file or one too large is refused and left as it is. Runs
  /// under the lock (`busy` when another muxFinder process keeps it).
  @discardableResult
  public func remove(
    expecting expected: Data? = nil
  ) throws(PersistentProfileInstallerError) -> RemoveOutcome {
    guard let directory = try openDirectory(create: false) else { return .notInstalled }
    defer { Darwin.close(directory) }
    let lock = try acquireLock()
    defer { Darwin.close(lock) }
    guard let existing = try examine(in: directory) else { return .notInstalled }
    if let expected, existing.data != expected { throw .fileChanged }
    let aside = PrivateStorage.temporaryName(for: name)
    guard renameatx_np(directory, name, directory, aside, UInt32(RENAME_EXCL)) == 0 else {
      let code = errno
      throw code == ENOENT ? .fileChanged : .systemCallFailed(name: "renameatx_np", errno: code)
    }
    if Self.identity(of: aside, in: directory) == existing.identity {
      guard unlinkat(directory, aside, 0) == 0 else {
        let code = errno
        // Put the file back rather than leave it under a hidden name.
        _ = renameatx_np(directory, aside, directory, name, UInt32(RENAME_EXCL))
        throw .systemCallFailed(name: "unlinkat", errno: code)
      }
      return .removed
    }
    // Another entry took the name between the check and the rename: put it back.
    guard renameatx_np(directory, aside, directory, name, UInt32(RENAME_EXCL)) == 0 else {
      throw .displacedEntryKept(temporaryName: aside)
    }
    throw .fileChanged
  } // End of func remove(expecting:)

  // MARK: - Primitives

  /// What was found at `muxFinder.json`: its bytes and its identity.
  struct Existing {
    /// The bytes.
    let data: Data
    /// Device and inode.
    let identity: EntryIdentity
  }

  /// A file's device and inode.
  struct EntryIdentity: Hashable {
    /// The device.
    let device: Int64
    /// The inode.
    let inode: UInt64
  }

  /// Opens the folder after checking it (the user's folder, not a symbolic link), without
  /// changing it. With `create`, a missing folder is made first (mode 0755; its parent must
  /// exist, else `directoryMissing`). Returns `nil` when it is missing and `create` is off.
  func openDirectory(create: Bool) throws(PersistentProfileInstallerError) -> Int32? {
    let path = PrivateStorage.path(of: directory)
    var created = false
    if create {
      if mkdir(path, Self.createdDirectoryPermissions) == 0 {
        created = true
      } else if errno != EEXIST {
        let code = errno
        throw code == ENOENT ? .directoryMissing : .systemCallFailed(name: "mkdir", errno: code)
      }
    }
    do throws(PrivateStorageError) {
      let descriptor = try PrivateStorage.openDirectory(
        atPath: path, owner: owner, access: .inspect)
      // Only a folder this call made gets its mode set (the umask may have narrowed it).
      if created { _ = fchmod(descriptor, Self.createdDirectoryPermissions) }
      return descriptor
    } catch .directoryMissing {
      if create { throw .directoryMissing }
      return nil
    } catch {
      throw Self.error(error)
    }
  } // End of func openDirectory(create:)

  /// Takes the lock that serializes installs and removals across muxFinder processes: an
  /// exclusive `flock` on `profiles.lock` in `lockDirectory`. The folder is opened as
  /// `HostStore` opens it (created 0700 if missing, its parent must exist; secured); the file
  /// is created empty (0600) when missing, opened without following a link, and must be the
  /// user's regular file (`lockUnavailable` otherwise). It is never removed: removing a lock
  /// file lets a process lock a new file while another still holds the old one. A busy lock is
  /// tried again every 10 ms for `lockWait`, then `busy`. Returns the descriptor; closing it
  /// releases the lock.
  func acquireLock() throws(PersistentProfileInstallerError) -> Int32 {
    let folder: Int32
    do throws(PrivateStorageError) {
      folder = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: lockDirectory), owner: owner, access: .createAndSecure)
    } catch {
      throw .lockUnavailable
    }
    defer { Darwin.close(folder) }
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = openat(
      folder, Self.lockFileName, O_RDONLY | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
      PrivateStorage.filePermissions)
    guard descriptor >= 0 else { throw .lockUnavailable }
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == owner
    else {
      Darwin.close(descriptor)
      throw .lockUnavailable
    }
    let deadline = ContinuousClock.now + lockWait
    while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
      let code = errno
      guard code == EWOULDBLOCK || code == EINTR else {
        Darwin.close(descriptor)
        throw .lockUnavailable
      }
      guard ContinuousClock.now < deadline else {
        Darwin.close(descriptor)
        throw .busy
      }
      usleep(Self.lockRetryInterval)
    } // End of loop waiting for the lock
    return descriptor
  } // End of func acquireLock()

  /// Reads `muxFinder.json` in `directory` without following a link or blocking: `nil` when
  /// there is none; refused (and left alone) when it is a link, not a regular file, another
  /// user's, or too large.
  func examine(in directory: Int32) throws(PersistentProfileInstallerError) -> Existing? {
    // O_NONBLOCK keeps a FIFO from blocking the open; it does not affect regular files.
    let descriptor = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      if code == ENOENT { return nil }
      if code == ELOOP { throw .fileIsSymbolicLink }
      throw .systemCallFailed(name: "openat", errno: code)
    }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .systemCallFailed(name: "fstat", errno: errno)
    }
    guard info.st_mode & S_IFMT == S_IFREG else { throw .fileNotRegular }
    guard info.st_uid == owner else { throw .fileNotOwnedByUser }
    guard info.st_size <= off_t(PersistentProfiles.maximumFileSize) else { throw .fileTooLarge }
    let data: Data
    do throws(PrivateStorageError) {
      data = try PrivateStorage.readAll(
        from: descriptor, limit: PersistentProfiles.maximumFileSize)
    } catch .fileTooLarge {
      throw .fileTooLarge
    } catch {
      throw Self.error(error)
    }
    return Existing(
      data: data,
      identity: EntryIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino)))
  } // End of func examine(in:)

  /// The device and inode of the entry `name` in `directory` (a link itself, never its
  /// target), or `nil` when there is none or it is not a regular file.
  static func identity(of name: String, in directory: Int32) -> EntryIdentity? {
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
      info.st_mode & S_IFMT == S_IFREG
    else { return nil }
    return EntryIdentity(device: Int64(info.st_dev), inode: UInt64(info.st_ino))
  }

  /// The installer's error for a failed private storage operation.
  static func error(_ error: PrivateStorageError) -> PersistentProfileInstallerError {
    switch error {
    case .directoryMissing: return .directoryMissing
    case .directoryIsSymbolicLink: return .directoryIsSymbolicLink
    case .directoryNotADirectory: return .directoryNotADirectory
    case .directoryNotOwnedByUser: return .directoryNotOwnedByUser
    case .directoryHasExtendedACL: return .systemCallFailed(name: "acl_set_fd_np", errno: EPERM)
    case .fileAlreadyExists: return .fileChanged
    case .fileTooLarge: return .fileTooLarge
    case .systemCallFailed(let name, let code): return .systemCallFailed(name: name, errno: code)
    }
  } // End of func error(_:)
}
