import Darwin
import Foundation

/// Why a folder cannot be the update's staging folder (PLAN.md D39, I-13b1). Nothing is
/// written in a refused folder.
public enum UpdateStagingProblem: Error, Sendable, Hashable {
  /// The path is not absolute, or has an empty, `.` or `..` component.
  case notAPlainAbsolutePath
  /// A component of the path does not exist.
  case missing
  /// A component of the path is a symbolic link.
  case symbolicLinkOnPath
  /// A component of the path is not a folder.
  case notADirectory
  /// Another user owns the folder.
  case notOwnedByUser
  /// The folder gives group or others a permission, or carries an extended ACL.
  case notPrivate
  /// The folder at the path is no longer the one checked (another device or inode).
  case replaced
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .notAPlainAbsolutePath: return "notAPlainAbsolutePath"
    case .missing: return "missing"
    case .symbolicLinkOnPath: return "symbolicLinkOnPath"
    case .notADirectory: return "notADirectory"
    case .notOwnedByUser: return "notOwnedByUser"
    case .notPrivate: return "notPrivate"
    case .replaced: return "replaced"
    case .systemCallFailed(let name, let code): return "systemCallFailed.\(name).\(code)"
    }
  } // End of var code
}

/// The private folder the update's download and verification work in (PLAN.md D39, I-13b1).
/// The caller hands it over (I-13b2 chooses it on the installed bundle's volume; the probe
/// takes `--into`): an existing folder of the user's, absolute, with no symbolic link on its
/// path, no permission for group or others and no extended ACL. It is checked once here and
/// its device and inode recorded; every later use reopens it without following a link and
/// refuses it unless it is still that folder and still private. Nothing here changes the
/// folder's own permissions.
///
/// Every file created in it is created exclusively (`O_CREAT | O_EXCL | O_NOFOLLOW`, any
/// inherited ACL removed, mode 0600 before the first byte) and every folder with `mkdirat`
/// (0700, its ACL removed), so nothing is ever written through a link or over an existing
/// entry. Removal never follows a link.
public struct UpdateStagingFolder: Sendable, Hashable {
  /// The folder's absolute path (no symbolic link on it).
  public let path: String
  /// The folder's device, recorded when it was checked.
  let device: dev_t
  /// The folder's inode, recorded when it was checked.
  let inode: ino_t
  /// The user who must own it.
  let owner: uid_t

  /// Checks the folder at `path` (see the type) and records it.
  public init(path: String) throws(UpdateStagingProblem) {
    try self.init(path: path, owner: geteuid())
  }

  /// The designated initializer; tests pass another `owner`.
  init(path: String, owner: uid_t) throws(UpdateStagingProblem) {
    guard path.hasPrefix("/") else { throw .notAPlainAbsolutePath }
    var trimmed = path
    while trimmed.count > 1, trimmed.hasSuffix("/") { trimmed.removeLast() }
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).dropFirst()
    guard !components.isEmpty,
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { throw .notAPlainAbsolutePath }
    var current = ""
    var info = stat()
    for component in components {
      current += "/" + component
      guard lstat(current, &info) == 0 else {
        let code = errno
        throw code == ENOENT ? .missing : .systemCallFailed(name: "lstat", errno: code)
      }
      if info.st_mode & S_IFMT == S_IFLNK { throw .symbolicLinkOnPath }
      guard info.st_mode & S_IFMT == S_IFDIR else { throw .notADirectory }
    } // End of loop over the path's components
    self.path = current
    self.device = info.st_dev
    self.inode = info.st_ino
    self.owner = owner
    let descriptor = try openDirectory()
    Darwin.close(descriptor)
  } // End of init(path:owner:)

  /// Opens the folder without following a link and checks that it is still the folder
  /// recorded, the user's, and private. The caller closes the descriptor.
  func openDirectory() throws(UpdateStagingProblem) -> Int32 {
    let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard descriptor >= 0 else {
      let code = errno
      switch code {
      case ENOENT: throw .missing
      case ELOOP: throw .symbolicLinkOnPath
      case ENOTDIR: throw .notADirectory
      default: throw .systemCallFailed(name: "open", errno: code)
      }
    }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      throw .systemCallFailed(name: "fstat", errno: code)
    }
    let problem: UpdateStagingProblem?
    if info.st_dev != device || info.st_ino != inode {
      problem = .replaced
    } else if info.st_uid != owner {
      problem = .notOwnedByUser
    } else if info.st_mode & 0o077 != 0 || (try? ExtendedACL.isPresent(on: descriptor)) != false {
      problem = .notPrivate
    } else {
      problem = nil
    }
    if let problem {
      Darwin.close(descriptor)
      throw problem
    }
    return descriptor
  } // End of func openDirectory()

  /// The absolute path of `name` in the folder.
  public func path(of name: String) -> String { path + "/" + name }

  /// The names in the folder, without `.` and `..`.
  func entryNames() throws(UpdateStagingProblem) -> [String] {
    let directory = try openDirectory()
    defer { Darwin.close(directory) }
    do throws(PrivateStorageError) {
      return try PrivateStorage.entryNames(in: directory)
    } catch {
      throw .systemCallFailed(name: "readdir", errno: PrivateStorage.posixCode(of: error))
    }
  }

  /// Creates the new file `name` in the folder exclusively (see the type) and returns its
  /// descriptor, open for writing; the caller closes it. Fails with the errno (`EEXIST` when
  /// something already has the name).
  func createFile(named name: String) throws(UpdateStagingFileError) -> Int32 {
    let directory: Int32
    do throws(UpdateStagingProblem) {
      directory = try openDirectory()
    } catch {
      throw .staging(error)
    }
    defer { Darwin.close(directory) }
    let descriptor = openat(
      directory, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
      PrivateStorage.filePermissions)
    guard descriptor >= 0 else { throw .systemCall(name: "openat", errno: errno) }
    do throws(PrivateStorageError) {
      try ExtendedACL.removeAll(from: descriptor)
    } catch {
      Darwin.close(descriptor)
      unlinkat(directory, name, 0)
      throw .systemCall(name: "acl", errno: PrivateStorage.posixCode(of: error))
    }
    guard fchmod(descriptor, PrivateStorage.filePermissions) == 0 else {
      let code = errno
      Darwin.close(descriptor)
      unlinkat(directory, name, 0)
      throw .systemCall(name: "fchmod", errno: code)
    }
    return descriptor
  } // End of func createFile(named:)

  /// Creates the new, empty folder `name` in the folder (0700, no ACL); fails with the errno
  /// (`EEXIST` when something already has the name).
  func createFolder(named name: String) throws(UpdateStagingFileError) {
    let directory: Int32
    do throws(UpdateStagingProblem) {
      directory = try openDirectory()
    } catch {
      throw .staging(error)
    }
    defer { Darwin.close(directory) }
    guard mkdirat(directory, name, PrivateStorage.directoryPermissions) == 0 else {
      throw .systemCall(name: "mkdirat", errno: errno)
    }
    let folder = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard folder >= 0 else { throw .systemCall(name: "openat", errno: errno) }
    defer { Darwin.close(folder) }
    guard fchmod(folder, PrivateStorage.directoryPermissions) == 0 else {
      throw .systemCall(name: "fchmod", errno: errno)
    }
    do throws(PrivateStorageError) {
      try ExtendedACL.removeAll(from: folder)
    } catch {
      throw .systemCall(name: "acl", errno: PrivateStorage.posixCode(of: error))
    }
  } // End of func createFolder(named:)

  /// Opens the entry at `relativePath` (components separated by `/`) below the folder as a
  /// folder, following no link on the way. The caller closes the descriptor.
  func openFolder(atRelativePath relativePath: String) throws(UpdateStagingFileError) -> Int32 {
    let directory: Int32
    do throws(UpdateStagingProblem) {
      directory = try openDirectory()
    } catch {
      throw .staging(error)
    }
    var current = directory
    for component in relativePath.split(separator: "/") {
      let next = openat(current, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      let code = errno
      Darwin.close(current)
      guard next >= 0 else { throw .systemCall(name: "openat", errno: code) }
      current = next
    } // End of loop over the relative path's components
    return current
  } // End of func openFolder(atRelativePath:)

  /// The identity of the entry at `relativePath` below the folder, read with `lstat` (the
  /// folders on the way opened without following a link); it must be a real folder, so a
  /// symbolic link or a file there fails with `ENOTDIR`.
  func folderIdentity(atRelativePath relativePath: String) throws(UpdateStagingFileError)
    -> UpdateBundleIdentity
  {
    var components = relativePath.split(separator: "/").map(String.init)
    guard let last = components.popLast() else { throw .systemCall(name: "lstat", errno: EINVAL) }
    let parent = try openFolder(atRelativePath: components.joined(separator: "/"))
    defer { Darwin.close(parent) }
    var info = stat()
    guard fstatat(parent, last, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw .systemCall(name: "lstat", errno: errno)
    }
    guard info.st_mode & S_IFMT == S_IFDIR else { throw .systemCall(name: "lstat", errno: ENOTDIR) }
    return UpdateBundleIdentity(info)
  } // End of func folderIdentity(atRelativePath:)

  /// Removes the entry `name` from the folder, with everything below it when it is a folder,
  /// never following a link (a link is removed, not its target). Folders below are opened
  /// with `O_NOFOLLOW` and made 0700 first when they are the user's, so a read-only folder
  /// from an archive can still be emptied. Returns whether nothing is left under the name.
  @discardableResult
  func remove(named name: String) -> Bool {
    guard let directory = try? openDirectory() else { return false }
    defer { Darwin.close(directory) }
    return Self.removeEntry(name, in: directory, owner: owner, depth: 0)
  }

  /// The deepest folder `removeEntry` descends into.
  static let maximumRemovalDepth = 256

  /// Removes `name` from the open folder `directory` (see `remove(named:)`).
  static func removeEntry(_ name: String, in directory: Int32, owner: uid_t, depth: Int) -> Bool {
    var info = stat()
    guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT }
    guard info.st_mode & S_IFMT == S_IFDIR else {
      return unlinkat(directory, name, 0) == 0 || errno == ENOENT
    }
    guard depth < maximumRemovalDepth else { return false }
    if info.st_uid == owner, info.st_mode & 0o700 != 0o700 {
      _ = fchmodat(directory, name, 0o700, AT_SYMLINK_NOFOLLOW)
    }
    let folder = openat(directory, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    if folder >= 0 {
      let names = (try? PrivateStorage.entryNames(in: folder)) ?? []
      for child in names {
        _ = removeEntry(child, in: folder, owner: owner, depth: depth + 1)
      } // End of loop over the folder's entries
      Darwin.close(folder)
    }
    return unlinkat(directory, name, AT_REMOVEDIR) == 0 || errno == ENOENT
  } // End of static func removeEntry(_:in:owner:depth:)
}

/// Why creating or opening an entry in the staging folder failed.
enum UpdateStagingFileError: Error, Sendable, Hashable {
  /// The staging folder itself is no longer usable.
  case staging(UpdateStagingProblem)
  /// A system call failed with this errno.
  case systemCall(name: String, errno: Int32)

  /// The errno behind the failure (`EIO` when it is the folder's).
  var errnoValue: Int32 {
    switch self {
    case .staging: return EIO
    case .systemCall(_, let code): return code
    }
  }
}
