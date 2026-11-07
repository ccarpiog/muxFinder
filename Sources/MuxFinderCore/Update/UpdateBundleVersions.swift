import Darwin
import Foundation

/// Why the bundle's versions refuse it (PLAN.md D39, I-13b1).
public enum UpdateVersionProblem: Error, Sendable, Hashable {
  /// `Contents/Info.plist` cannot be read as a property list dictionary of at most 256 KiB.
  case infoUnreadable
  /// `CFBundleIdentifier` is not exactly `cc.carpio.muxfinder`.
  case identifierMismatch
  /// `CFBundleShortVersionString` is not a version of ours.
  case shortVersionUnparseable
  /// `CFBundleShortVersionString` is not the release's tag.
  case shortVersionNotTag
  /// `CFBundleVersion` is not a plain positive integer of 1 to 9 digits.
  case buildUnparseable
  /// The running app's build cannot be parsed, so nothing is newer than it.
  case runningBuildUnknown
  /// `CFBundleVersion` is not greater than the running app's build.
  case buildNotNewer

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .infoUnreadable: return "infoUnreadable"
    case .identifierMismatch: return "identifierMismatch"
    case .shortVersionUnparseable: return "shortVersionUnparseable"
    case .shortVersionNotTag: return "shortVersionNotTag"
    case .buildUnparseable: return "buildUnparseable"
    case .runningBuildUnknown: return "runningBuildUnknown"
    case .buildNotNewer: return "buildNotNewer"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .infoUnreadable: return "the app's version can't be read"
    case .identifierMismatch: return "the app in the download isn't muxFinder"
    case .shortVersionUnparseable, .shortVersionNotTag:
      return "the app's version isn't the release's version"
    case .buildUnparseable: return "the app's build number can't be read"
    case .runningBuildUnknown: return "this copy's build number can't be read"
    case .buildNotNewer: return "the app isn't newer than this copy"
    }
  } // End of var reason
}

/// The verified bundle's versions.
public struct UpdateBundleVersionFacts: Sendable, Hashable {
  /// `CFBundleShortVersionString`.
  public let version: UpdateVersion
  /// `CFBundleVersion`.
  public let build: Int
}

/// The version check of the downloaded bundle (PLAN.md D39, I-13b1), read only after the code
/// check passed (the signature seals `Info.plist`): `CFBundleIdentifier` exactly
/// `cc.carpio.muxfinder`, `CFBundleShortVersionString` a version of ours equal to the
/// release's, and `CFBundleVersion` a plain positive integer (1 to 9 ASCII digits, no sign,
/// space or leading zero) strictly greater than the running app's build.
public enum UpdateBundleVersions {
  /// The largest `Info.plist` read.
  public static let maximumInfoSize = 256 * 1024

  /// A build number: 1 to 9 ASCII digits with no leading zero (`0` itself parses, and is no
  /// build of a release); `nil` otherwise.
  public static func build(_ text: String) -> Int? {
    UpdateVersion.number(Substring(text))
  }

  /// Checks `info` (an `Info.plist` dictionary) for the release `expected` against the
  /// running app's build `runningBuild`.
  public static func check(
    info: [String: Any], expected: UpdateVersion, runningBuild: String?
  ) -> Result<UpdateBundleVersionFacts, UpdateVersionProblem> {
    guard info["CFBundleIdentifier"] as? String == UpdateSource.bundleIdentifier else {
      return .failure(.identifierMismatch)
    }
    guard let short = info["CFBundleShortVersionString"] as? String,
      let version = UpdateVersion(short)
    else { return .failure(.shortVersionUnparseable) }
    guard version == expected else { return .failure(.shortVersionNotTag) }
    guard let buildText = info["CFBundleVersion"] as? String, let build = build(buildText),
      build >= 1
    else { return .failure(.buildUnparseable) }
    guard let running = runningBuild.flatMap(Self.build) else {
      return .failure(.runningBuildUnknown)
    }
    guard build > running else { return .failure(.buildNotNewer) }
    return .success(UpdateBundleVersionFacts(version: version, build: build))
  } // End of static func check(info:expected:runningBuild:)

  /// Reads `Contents/Info.plist` of the open app folder `app` without following a link: a
  /// regular file of at most `maximumInfoSize` bytes holding a property list dictionary.
  static func readInfo(app: Int32) -> [String: Any]? {
    let contents = openat(app, "Contents", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
    guard contents >= 0 else { return nil }
    defer { Darwin.close(contents) }
    let file = openat(contents, "Info.plist", O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard file >= 0 else { return nil }
    defer { Darwin.close(file) }
    var info = stat()
    guard fstat(file, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
      info.st_size <= off_t(maximumInfoSize),
      let data = try? PrivateStorage.readAll(from: file, limit: maximumInfoSize)
    else { return nil }
    return
      (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil))
      as? [String: Any]
  } // End of static func readInfo(app:)
}
