import Darwin
import Foundation

/// Why an operation on one of muxFinder's private directories or files failed. Each store
/// (`LaunchStore`, `HostStore`) reports it through its own error type.
enum PrivateStorageError: Error, Sendable, Hashable {
  /// The directory does not exist (or, when creating it, its parent does not).
  case directoryMissing
  /// The directory is a symbolic link.
  case directoryIsSymbolicLink
  /// Something other than a directory is at the directory's path.
  case directoryNotADirectory
  /// Another user owns the directory.
  case directoryNotOwnedByUser
  /// The directory carries an extended access control list that could not be removed.
  case directoryHasExtendedACL
  /// An exclusive write found the file already there.
  case fileAlreadyExists
  /// The file is larger than the caller's limit.
  case fileTooLarge
  /// A system call failed with this errno.
  case systemCallFailed(name: String, errno: Int32)
}

/// Descriptor-based primitives for muxFinder's private directories and files (PLAN.md D8,
/// D14, D19), shared by `LaunchStore` and `HostStore`.
///
/// - A directory is refused if it is a symbolic link, not a directory, or owned by another
///   user. When it is secured (every open that may write), it is tightened to 0700 and any
///   extended ACL is removed, and it is refused if that removal fails (`ExtendedACL`). An
///   `inspect` open checks the same things but changes nothing, for loads that must never
///   write.
/// - Files are written atomically: a temporary file in the same directory, created with
///   `O_CREAT | O_EXCL | O_NOFOLLOW`, stripped of any inherited ACL and set to 0600 before its
///   first byte, optionally flushed to stable storage, then renamed into place (`RENAME_EXCL`
///   for exclusive writes, so an existing file is never replaced), or handed to a caller that
///   publishes it itself (`writeTemporaryFile`, used by `HostStore`).
/// - Every file call goes through the directory's descriptor (`openat`, `renameat`), so the
///   checked directory cannot be swapped underneath.
enum PrivateStorage {
  /// How a directory is opened.
  enum DirectoryAccess: Sendable, Equatable {
    /// Checked (no link, a directory, owned by the user) and left exactly as it is.
    case inspect
    /// Checked, tightened to 0700 and stripped of any extended ACL.
    case secure
    /// Created with mode 0700 if missing (its parent must exist), then secured.
    case createAndSecure
  }

  /// Permissions of every private directory.
  static let directoryPermissions: mode_t = 0o700
  /// Permissions of every private file.
  static let filePermissions: mode_t = 0o600
  /// File-name suffix of temporary files (their names also start with `.`).
  static let temporarySuffix = ".tmp"

  /// The path of `url` without a trailing slash (a trailing slash would make the kernel follow
  /// a symbolic link despite `O_NOFOLLOW`).
  static func path(of url: URL) -> String {
    var path = url.path(percentEncoded: false)
    while path.count > 1, path.hasSuffix("/") { path.removeLast() }
    return path
  }

  // MARK: - Directories

  /// Opens the directory at `path` after checking it, creating and securing it as `access`
  /// says. The caller closes the returned descriptor.
  static func openDirectory(
    atPath path: String,
    owner: uid_t,
    access: DirectoryAccess
  ) throws(PrivateStorageError) -> Int32 {
    if access == .createAndSecure, mkdir(path, directoryPermissions) != 0, errno != EEXIST {
      let code = errno
      throw code == ENOENT ? .directoryMissing : .systemCallFailed(name: "mkdir", errno: code)
    }
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
    do throws(PrivateStorageError) {
      try checkDirectory(descriptor, owner: owner, secure: access != .inspect)
    } catch {
      Darwin.close(descriptor)
      throw error
    }
    return descriptor
  } // End of func openDirectory(atPath:owner:access:)

  /// Checks that the open directory is a directory owned by `owner`. With `secure`, also
  /// tightens it to 0700 and removes any extended ACL (`directoryHasExtendedACL` if that
  /// fails).
  static func checkDirectory(
    _ descriptor: Int32,
    owner: uid_t,
    secure: Bool
  ) throws(PrivateStorageError) {
    var info = stat()
    guard fstat(descriptor, &info) == 0 else {
      throw .systemCallFailed(name: "fstat", errno: errno)
    }
    guard info.st_mode & S_IFMT == S_IFDIR else { throw .directoryNotADirectory }
    guard info.st_uid == owner else { throw .directoryNotOwnedByUser }
    guard secure else { return }
    if info.st_mode & 0o7777 != directoryPermissions {
      guard fchmod(descriptor, directoryPermissions) == 0 else {
        throw .systemCallFailed(name: "fchmod", errno: errno)
      }
    }
    do throws(PrivateStorageError) {
      try ExtendedACL.removeAll(from: descriptor)
    } catch {
      throw .directoryHasExtendedACL
    }
  } // End of func checkDirectory(_:owner:secure:)

  // MARK: - Files

  /// Writes `data` to `name` in `directory` through a temporary file and a rename. With
  /// `exclusive`, an existing `name` is never replaced (`fileAlreadyExists`). With
  /// `synchronize`, the bytes are flushed to stable storage (`F_FULLFSYNC`, else `fsync`)
  /// before the rename.
  static func writeFile(
    _ data: Data,
    named name: String,
    exclusive: Bool,
    synchronize: Bool = false,
    in directory: Int32
  ) throws(PrivateStorageError) {
    let temporary = try writeTemporaryFile(
      data,
      for: name,
      synchronize: synchronize,
      in: directory
    )
    let code =
      exclusive
      ? renameatx_np(directory, temporary, directory, name, UInt32(RENAME_EXCL))
      : renameat(directory, temporary, directory, name)
    guard code == 0 else {
      let failure = errno
      unlinkat(directory, temporary, 0)
      throw failure == EEXIST
        ? .fileAlreadyExists : .systemCallFailed(name: "renameat", errno: failure)
    }
  } // End of func writeFile(_:named:exclusive:synchronize:in:)

  /// Creates a new temporary file for `name` in `directory` (`.<name>.<random hex>.tmp`, with
  /// `O_CREAT | O_EXCL | O_NOFOLLOW`), removes any inherited ACL and sets it to 0600 before its
  /// first byte, writes `data` and, with `synchronize`, flushes it. Returns its name; the caller
  /// renames it into place or removes it. On failure nothing is left behind.
  static func writeTemporaryFile(
    _ data: Data,
    for name: String,
    synchronize: Bool,
    in directory: Int32
  ) throws(PrivateStorageError) -> String {
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
    do throws(PrivateStorageError) {
      // A new file inherits the directory's inheritable ACL entries; none may survive to the
      // first byte written.
      try ExtendedACL.removeAll(from: descriptor)
      // The umask can only remove permission bits; fchmod makes the mode exactly 0600.
      guard fchmod(descriptor, filePermissions) == 0 else {
        throw .systemCallFailed(name: "fchmod", errno: errno)
      }
      try writeAll(data, to: descriptor)
      if synchronize { try flush(descriptor) }
    } catch {
      Darwin.close(descriptor)
      unlinkat(directory, temporary, 0)
      throw error
    }
    Darwin.close(descriptor)
    return temporary
  } // End of func writeTemporaryFile(_:for:synchronize:in:)

  /// Flushes the open file to stable storage: `F_FULLFSYNC` (which also empties the drive's
  /// cache), or `fsync` where the file system does not support it.
  static func flush(_ descriptor: Int32) throws(PrivateStorageError) {
    if fcntl(descriptor, F_FULLFSYNC) == 0 { return }
    guard fsync(descriptor) == 0 else { throw .systemCallFailed(name: "fsync", errno: errno) }
  }

  /// Writes all of `data` to `descriptor`, retrying on `EINTR`.
  static func writeAll(_ data: Data, to descriptor: Int32) throws(PrivateStorageError) {
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

  /// Reads `descriptor` to end of file. More than `limit` bytes is `fileTooLarge`.
  static func readAll(from descriptor: Int32, limit: Int) throws(PrivateStorageError) -> Data {
    var data = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        data.append(contentsOf: buffer[0..<count])
        if data.count > limit { throw .fileTooLarge }
      } else if count == 0 {
        return data
      } else if errno != EINTR {
        throw .systemCallFailed(name: "read", errno: errno)
      }
    } // End of loop over reads
  } // End of func readAll(from:limit:)

  /// Removes the extended ACL of the open file if `owner` owns it and it has one. Returns
  /// whether an ACL was removed.
  static func removeExtendedACL(of descriptor: Int32, owner: uid_t) -> Bool {
    var info = stat()
    guard fstat(descriptor, &info) == 0, info.st_uid == owner,
      (try? ExtendedACL.isPresent(on: descriptor)) == true
    else { return false }
    return (try? ExtendedACL.removeAll(from: descriptor)) != nil
  }

  /// The names in the open directory, without `.` and `..`.
  static func entryNames(in directory: Int32) throws(PrivateStorageError) -> [String] {
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
