import Darwin

/// Extended access control lists (macOS ACLs) on open descriptors, for `LaunchStore`
/// (PLAN.md D14).
///
/// An ACL entry can grant other users access whatever the mode bits say, and a new file or
/// directory inherits the entries of its parent that are marked `file_inherit` or
/// `directory_inherit`. Mode 0700/0600 is only a private boundary when no extended ACL is
/// present, so the store removes them from its directory and from every file it creates, and
/// refuses to read a file that carries one. Everything works on descriptors, never on paths.
///
/// Measured on macOS 27.2: `acl_get_fd_np` fails with `ENOENT` when a file has no extended ACL,
/// and setting an empty ACL (`acl_init`) with `acl_set_fd_np` removes every entry.
enum ExtendedACL {
  /// Whether the open file carries at least one extended ACL entry (allow or deny). A file
  /// system without ACL support counts as having none.
  static func isPresent(on descriptor: Int32) throws(LaunchStoreError) -> Bool {
    guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
      let code = errno
      if code == ENOENT || code == ENOTSUP || code == EOPNOTSUPP { return false }
      throw .systemCallFailed(name: "acl_get_fd_np", errno: code)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    return acl_get_entry(acl, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == 0
  }

  /// Removes every extended ACL entry from the open file, then checks that none is left.
  /// Does nothing when there is none.
  static func removeAll(from descriptor: Int32) throws(LaunchStoreError) {
    guard try isPresent(on: descriptor) else { return }
    guard let empty = acl_init(1) else {
      throw .systemCallFailed(name: "acl_init", errno: errno)
    }
    defer { acl_free(UnsafeMutableRawPointer(empty)) }
    guard acl_set_fd_np(descriptor, empty, ACL_TYPE_EXTENDED) == 0 else {
      throw .systemCallFailed(name: "acl_set_fd_np", errno: errno)
    }
    if try isPresent(on: descriptor) {
      throw .systemCallFailed(name: "acl_set_fd_np", errno: EPERM)
    }
  } // End of func removeAll(from:)
}
