import Foundation

/// Why a muxFinder directory could not be prepared.
public enum AppPathsError: Error, Sendable, Equatable, LocalizedError {
  /// Something other than a directory exists at the path.
  case notADirectory(path: String)

  /// The user-facing explanation.
  public var errorDescription: String? {
    switch self {
    case .notADirectory(let path):
      return "muxFinder can't use \(path) because it isn't a folder."
    }
  }
}

/// Locations of muxFinder's own files (PLAN.md D8).
///
/// Production code uses `standard`, which points at
/// `~/Library/Application Support/muxFinder`. Tests pass their own root to
/// `init(applicationSupportDirectory:)` so they never touch the real one.
public struct AppPaths: Sendable, Equatable {
  /// Name of muxFinder's folder inside Application Support.
  public static let directoryName = "muxFinder"
  /// Permissions for every directory muxFinder creates: owner only.
  public static let directoryPermissions: Int16 = 0o700

  /// Root of muxFinder's private storage.
  public let applicationSupportDirectory: URL

  /// Uses `applicationSupportDirectory` as the root. This is the override for tests.
  public init(applicationSupportDirectory: URL) {
    self.applicationSupportDirectory = applicationSupportDirectory
  }

  /// The real location, `~/Library/Application Support/muxFinder`. Nothing is created.
  public static var standard: AppPaths {
    AppPaths(
      applicationSupportDirectory: URL.applicationSupportDirectory.appending(
        path: directoryName,
        directoryHint: .isDirectory
      )
    )
  }

  /// Creates the root directory if needed, makes sure its permissions are 0700, and returns it.
  @discardableResult
  public func prepareApplicationSupportDirectory() throws -> URL {
    try Self.preparePrivateDirectory(at: applicationSupportDirectory)
    return applicationSupportDirectory
  }

  /// Returns the URL of a subdirectory of the root, creating both with permissions 0700.
  @discardableResult
  public func preparePrivateSubdirectory(named name: String) throws -> URL {
    try prepareApplicationSupportDirectory()
    let url = applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    try Self.preparePrivateDirectory(at: url)
    return url
  }

  /// Creates `url` (and missing parents) with permissions 0700, or tightens an existing
  /// directory to 0700.
  ///
  /// - Throws: `AppPathsError.notADirectory` if a file is in the way, or the file system error.
  public static func preparePrivateDirectory(at url: URL) throws {
    let fileManager = FileManager.default
    let path = url.path(percentEncoded: false)
    let permissions: [FileAttributeKey: Any] = [.posixPermissions: directoryPermissions]
    var isDirectory: ObjCBool = false
    if fileManager.fileExists(atPath: path, isDirectory: &isDirectory) {
      guard isDirectory.boolValue else { throw AppPathsError.notADirectory(path: path) }
    } else {
      try fileManager.createDirectory(
        at: url,
        withIntermediateDirectories: true,
        attributes: permissions
      )
    }
    try fileManager.setAttributes(permissions, ofItemAtPath: path)
  } // End of func preparePrivateDirectory(at:)
}
