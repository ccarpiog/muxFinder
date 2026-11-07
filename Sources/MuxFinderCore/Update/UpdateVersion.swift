import Foundation

/// A muxFinder version as the update check compares it (PLAN.md D39): three non-negative
/// integers, `major.minor.patch`, compared numerically. Each part is 1 to 9 ASCII digits with no
/// sign, no space and no leading zero (`0` itself is fine), so `0.02.0`, `+1.0.0`, ` 1.0.0` and
/// `1.0.0.0` are not versions of ours. A release tag is exactly `v` plus a version (`v0.3.0`;
/// never `V0.3.0` or `0.3.0`); the running version is `CFBundleShortVersionString`, parsed the
/// same way without the `v`.
public struct UpdateVersion: Sendable, Hashable, Comparable, CustomStringConvertible {
  /// The most digits a part may have, which keeps every part well inside `Int`.
  public static let maximumPartDigits = 9

  /// The major number.
  public let major: Int
  /// The minor number.
  public let minor: Int
  /// The patch number.
  public let patch: Int

  /// A version from its parts; `nil` when a part is negative or longer than
  /// `maximumPartDigits` digits.
  public init?(major: Int, minor: Int, patch: Int) {
    let limit = 999_999_999
    guard (0...limit).contains(major), (0...limit).contains(minor), (0...limit).contains(patch)
    else { return nil }
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  /// Parses `major.minor.patch` exactly (see the type's rules); `nil` for anything else.
  public init?(_ text: String) {
    let parts = text.split(separator: ".", omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    var numbers: [Int] = []
    for part in parts {
      guard let number = Self.number(part) else { return nil }
      numbers.append(number)
    }
    self.init(major: numbers[0], minor: numbers[1], patch: numbers[2])
  }

  /// Parses a release tag: exactly a lowercase `v` followed by a version; `nil` otherwise.
  public init?(tag: String) {
    guard tag.hasPrefix("v") else { return nil }
    self.init(String(tag.dropFirst()))
  }

  /// One part's value: 1 to `maximumPartDigits` ASCII digits, no leading zero unless the part
  /// is `0`; `nil` otherwise.
  static func number(_ part: Substring) -> Int? {
    let bytes = Array(part.utf8)
    guard !bytes.isEmpty, bytes.count <= maximumPartDigits,
      bytes.allSatisfy({ (0x30...0x39).contains($0) })
    else { return nil }
    guard bytes.count == 1 || bytes[0] != 0x30 else { return nil }
    return bytes.reduce(0) { $0 * 10 + Int($1 - 0x30) }
  }

  /// `major.minor.patch`.
  public var description: String { "\(major).\(minor).\(patch)" }

  /// The release tag for this version, `v` plus the version.
  public var tag: String { "v" + description }

  /// Numeric order: major first, then minor, then patch.
  public static func < (lhs: UpdateVersion, rhs: UpdateVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

/// Where muxFinder's releases come from (PLAN.md D39). The owner and the repository are
/// compiled in, never read from a file or the environment, and every URL the check accepts is
/// built from them here.
public enum UpdateSource {
  /// The GitHub account that owns the repository.
  public static let owner = "ccarpiog"
  /// The repository.
  public static let repository = "muxFinder"
  /// The only host the check sends a request to.
  public static let apiHost = "api.github.com"
  /// The host of release pages and release downloads.
  public static let webHost = "github.com"
  /// The installable asset's exact name.
  public static let assetName = "muxFinder.zip"

  /// `GET /repos/ccarpiog/muxFinder/releases/latest` on GitHub's API (drafts and prereleases
  /// are left out by GitHub itself).
  public static var latestReleaseURL: URL {
    URL(string: "https://\(apiHost)/repos/\(owner)/\(repository)/releases/latest")!
  }

  /// The path every accepted release page starts with.
  public static var releasePagePathPrefix: String { "/\(owner)/\(repository)/releases/" }

  /// The exact download URL the installable asset of `tag`'s release must have.
  public static func assetDownloadURL(forTag tag: String) -> String {
    "https://\(webHost)/\(owner)/\(repository)/releases/download/\(tag)/\(assetName)"
  }
}
