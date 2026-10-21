import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for `AppPaths`. Every test uses its own temporary root, never the real
/// Application Support folder.
@Suite("App paths")
struct AppPathsTests {
  /// The POSIX permission bits of the item at `url`.
  static func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(
      atPath: url.path(percentEncoded: false))
    let value = try #require(attributes[.posixPermissions] as? NSNumber)
    return value.intValue
  }

  /// The standard location is `~/Library/Application Support/muxFinder`, computed without
  /// creating anything.
  @Test func standardLocation() {
    let path = AppPaths.standard.applicationSupportDirectory.path(percentEncoded: false)
    #expect(path.hasSuffix("/Library/Application Support/muxFinder/"))
  }

  /// A missing root (and its missing parent) is created with permissions 0700.
  @Test func createsTheRootPrivately() throws {
    let base = TestSupport.temporaryURL()
    defer { try? FileManager.default.removeItem(at: base) }
    let paths = AppPaths(applicationSupportDirectory: base.appending(path: "nested/muxFinder"))
    let root = try paths.prepareApplicationSupportDirectory()
    #expect(root == paths.applicationSupportDirectory)
    #expect(try Self.permissions(of: root) == 0o700)
  }

  /// An existing root with looser permissions is tightened to 0700.
  @Test func tightensExistingPermissions() throws {
    let root = TestSupport.temporaryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(
      at: root,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755]
    )
    #expect(try Self.permissions(of: root) == 0o755)
    try AppPaths(applicationSupportDirectory: root).prepareApplicationSupportDirectory()
    #expect(try Self.permissions(of: root) == 0o700)
  } // End of func tightensExistingPermissions()

  /// Subdirectories are created under the root, both with permissions 0700.
  @Test func createsPrivateSubdirectories() throws {
    let root = TestSupport.temporaryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    let subdirectory = try AppPaths(applicationSupportDirectory: root)
      .preparePrivateSubdirectory(named: "launch")
    #expect(subdirectory.lastPathComponent == "launch")
    #expect(try Self.permissions(of: root) == 0o700)
    #expect(try Self.permissions(of: subdirectory) == 0o700)
  }

  /// A regular file in the way is reported, not replaced.
  @Test func refusesAFileInTheWay() throws {
    let root = TestSupport.temporaryURL()
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("x".utf8).write(to: root)
    #expect(throws: AppPathsError.notADirectory(path: root.path(percentEncoded: false))) {
      try AppPaths(applicationSupportDirectory: root).prepareApplicationSupportDirectory()
    }
  }
}
