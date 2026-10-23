import Darwin
import Foundation

/// Why the helper's path cannot be given to iTerm2. `message` is English, sentence case.
public enum LaunchHelperPathError: Error, Sendable, Hashable, LocalizedError {
  /// The path does not start with `/`.
  case notAbsolute
  /// The path contains a character outside `[A-Za-z0-9._/-]` (PLAN.md D2).
  case unsupportedCharacters
  /// The running executable's location is unknown.
  case executableUnknown
  /// No executable `muxfinder-launch` is next to the running executable.
  case notFound

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .notAbsolute, .unsupportedCharacters:
      return "muxFinder can't open sessions from where it is installed, because the path to "
        + "its helper contains spaces or other special characters. Move muxFinder to "
        + "/Applications and try again."
    case .executableUnknown, .notFound:
      return "muxFinder's helper (muxfinder-launch) is missing. Reinstall muxFinder and try "
        + "again."
    }
  } // End of var message

  /// `LocalizedError` conformance, so `localizedDescription` shows `message`.
  public var errorDescription: String? { message }
}

/// The validated absolute path of `muxfinder-launch`, the only path iTerm2 ever receives
/// (PLAN.md D2).
///
/// iTerm2 splits the tab's `Command` property with its own rules (Phase 4b records them), so
/// until a test proves those rules for a path with a space, only paths made of
/// `[A-Za-z0-9._/-]` are accepted: such a path is one word under any splitting rule, and the
/// command line `<path> attach <launch id>` needs no quoting.
public struct LaunchHelperPath: Sendable, Hashable, CustomStringConvertible {
  /// The helper's executable name.
  public static let executableName = "muxfinder-launch"

  /// The bytes allowed in the path.
  static let allowedBytes: Set<UInt8> = Set(
    "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._/-".utf8
  )

  /// The validated path.
  public let path: String

  /// Validates `path`: absolute, and only `[A-Za-z0-9._/-]` (so no spaces, quotes, `$`,
  /// control characters or non-ASCII).
  public init(validating path: String) throws(LaunchHelperPathError) {
    guard path.hasPrefix("/") else { throw .notAbsolute }
    guard path.utf8.allSatisfy(Self.allowedBytes.contains) else { throw .unsupportedCharacters }
    self.path = path
  }

  /// The helper next to `executableURL` (by default the running executable): in the bundle's
  /// `Contents/MacOS/`, or in the SwiftPM build directory during development. The executable's
  /// directory is resolved through symbolic links first. The helper must be an executable
  /// regular file, and its path must pass `init(validating:)`.
  public static func locate(
    nextTo executableURL: URL? = Bundle.main.executableURL
  ) throws(LaunchHelperPathError) -> LaunchHelperPath {
    guard let executableURL else { throw .executableUnknown }
    let directory = executableURL.deletingLastPathComponent().path(percentEncoded: false)
    guard let resolved = realpath(directory, nil) else { throw .executableUnknown }
    let base = String(cString: resolved)
    free(resolved)
    let candidate = (base.hasSuffix("/") ? base : base + "/") + executableName
    var info = stat()
    guard stat(candidate, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      access(candidate, X_OK) == 0
    else { throw .notFound }
    return try LaunchHelperPath(validating: candidate)
  } // End of func locate(nextTo:)

  /// The command line iTerm2 runs in the launch tab: `<path> attach <launch id>`. Both parts
  /// are validated, so the line has exactly three words under any splitting rule.
  public func attachCommandLine(for id: LaunchToken) -> String {
    commandLine(for: id, kind: .attach)
  }

  /// The command line of a launch tab for a request of `kind`: `<path> <mode> <launch id>`,
  /// with the helper mode that takes that kind (`attach`, or `ssh-setup` for "Set up SSH in
  /// iTerm2…", PLAN.md D24). The path and the id are validated and the mode is a constant, so
  /// the line has exactly three words under any splitting rule.
  public func commandLine(for id: LaunchToken, kind: LaunchRequestKind) -> String {
    "\(path) \(kind.helperMode) \(id.rawValue)"
  }

  /// The `Command` of a host's persistent profile (PLAN.md D26): `<path> profile <host id>`,
  /// the host id in the canonical lowercase form a launch id has. The path is validated, the
  /// mode a constant and the id hexadecimal digits and `-`, so iTerm2 splits the line into
  /// exactly three arguments under any splitting rule.
  public func profileCommandLine(forHostID hostID: UUID) -> String {
    "\(path) \(ProfileLaunch.helperMode) \(LaunchToken(uuid: hostID).rawValue)"
  }

  /// The path.
  public var description: String { path }
}
