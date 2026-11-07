import Foundation

/// What the update check remembers between launches (PLAN.md D39), kept in
/// `update-state.json`. It is a cache, not the user's data: when it is missing or cannot be
/// used the check starts over as if it never ran.
public struct UpdateState: Sendable, Hashable {
  /// When a check last succeeded (a 200 answer that could be read, or a 304 with a kept
  /// release).
  public var lastSuccessfulCheck: Date?
  /// When a request was last sent, whatever came of it.
  public var lastAttempt: Date?
  /// The `ETag` of the 200 answer whose release is kept, sent back as `If-None-Match`.
  public var etag: String?
  /// The release of the last 200 answer that offered one (never whether it is newer).
  public var keptRelease: UpdateRelease?
  /// The version whose notice the user has seen (for the menu bar icon's dot, Phase I-13c).
  public var noticeSeenVersion: UpdateVersion?
  /// No request is sent before this date: GitHub said the rate limit is used up until then.
  public var rateLimitedUntil: Date?

  /// A state from its parts; with none, "never checked".
  public init(
    lastSuccessfulCheck: Date? = nil, lastAttempt: Date? = nil, etag: String? = nil,
    keptRelease: UpdateRelease? = nil, noticeSeenVersion: UpdateVersion? = nil,
    rateLimitedUntil: Date? = nil
  ) {
    self.lastSuccessfulCheck = lastSuccessfulCheck
    self.lastAttempt = lastAttempt
    self.etag = etag
    self.keptRelease = keptRelease
    self.noticeSeenVersion = noticeSeenVersion
    self.rateLimitedUntil = rateLimitedUntil
  } // End of UpdateState.init(lastSuccessfulCheck:…:rateLimitedUntil:)
}

/// The `update-state.json` format, schema 1 (PLAN.md D39): a JSON object with
/// `schemaVersion`, and, each only when known, `lastSuccessfulCheck`, `lastAttempt` and
/// `rateLimitedUntil` (ISO 8601 in UTC with milliseconds), `etag`, `noticeSeenVersion`
/// (`major.minor.patch`) and `release` (`tag`, `page`, then either `asset` with `url`, `sha256`
/// and `size`, or `assetProblem`). A file is used only when every value passes the same rules
/// as the answer it came from (`UpdateReleaseParser`); anything else reads as never checked.
enum UpdateStateCoding {
  /// The schema version written and read.
  static let schemaVersion = 1

  /// The file's top-level object.
  struct File: Codable {
    /// The schema version.
    var schemaVersion: Int
    /// `UpdateState.lastSuccessfulCheck`.
    var lastSuccessfulCheck: String?
    /// `UpdateState.lastAttempt`.
    var lastAttempt: String?
    /// `UpdateState.etag`.
    var etag: String?
    /// `UpdateState.keptRelease`.
    var release: Release?
    /// `UpdateState.noticeSeenVersion`.
    var noticeSeenVersion: String?
    /// `UpdateState.rateLimitedUntil`.
    var rateLimitedUntil: String?
  }

  /// A kept release.
  struct Release: Codable {
    /// The tag.
    var tag: String
    /// The release page.
    var page: String
    /// The installable asset, or `nil`.
    var asset: Asset?
    /// Why there is no installable asset, or `nil`.
    var assetProblem: String?
  }

  /// A kept asset.
  struct Asset: Codable {
    /// The download URL.
    var url: String
    /// The lowercase hex SHA-256 digest.
    var sha256: String
    /// The size in bytes.
    var size: Int
  }

  /// Only the schema version, read before the rest.
  struct Header: Decodable {
    /// The file's schema version.
    var schemaVersion: Int
  }

  /// Encodes `state` (sorted keys, pretty-printed, slashes unescaped, a final newline).
  static func encode(_ state: UpdateState) -> Data? {
    let file = File(
      schemaVersion: schemaVersion,
      lastSuccessfulCheck: state.lastSuccessfulCheck.map(text),
      lastAttempt: state.lastAttempt.map(text),
      etag: state.etag,
      release: state.keptRelease.map { release in
        Release(
          tag: release.tag, page: release.pageURL.absoluteString,
          asset: release.asset.map {
            Asset(url: $0.downloadURL.absoluteString, sha256: $0.sha256, size: $0.size)
          },
          assetProblem: release.assetProblem?.rawValue)
      },
      noticeSeenVersion: state.noticeSeenVersion?.description,
      rateLimitedUntil: state.rateLimitedUntil.map(text))
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard var data = try? encoder.encode(file) else { return nil }
    data.append(0x0A)
    return data
  } // End of static func encode(_:)

  /// Why bytes are not a usable state.
  enum Problem: String, Error {
    /// Not JSON, or JSON of another shape.
    case malformed
    /// Another schema version.
    case otherSchemaVersion
    /// A value fails its rule.
    case invalidValue
  }

  /// Decodes a state file; every value must pass its rule.
  static func decode(_ data: Data) -> Result<UpdateState, Problem> {
    guard let header = try? JSONDecoder().decode(Header.self, from: data) else {
      return .failure(.malformed)
    }
    guard header.schemaVersion == schemaVersion else { return .failure(.otherSchemaVersion) }
    guard let file = try? JSONDecoder().decode(File.self, from: data) else {
      return .failure(.malformed)
    }
    var state = UpdateState()
    do throws(Problem) {
      state.lastSuccessfulCheck = try file.lastSuccessfulCheck.map(date)
      state.lastAttempt = try file.lastAttempt.map(date)
      state.rateLimitedUntil = try file.rateLimitedUntil.map(date)
      if let etag = file.etag {
        guard let usable = URLSessionUpdateTransport.usableETag(etag) else { throw .invalidValue }
        state.etag = usable
      }
      if let seen = file.noticeSeenVersion {
        guard let version = UpdateVersion(seen) else { throw .invalidValue }
        state.noticeSeenVersion = version
      }
      state.keptRelease = try file.release.map(release)
    } catch {
      return .failure(error)
    }
    return .success(state)
  } // End of static func decode(_:)

  /// The kept release in `entry`, checked by the rules its answer had to pass.
  static func release(_ entry: Release) throws(Problem) -> UpdateRelease {
    guard let version = UpdateVersion(tag: entry.tag),
      let page = UpdateReleaseParser.releasePage(entry.page)
    else { throw .invalidValue }
    switch (entry.asset, entry.assetProblem) {
    case (.some(let asset), .none):
      guard asset.url == UpdateSource.assetDownloadURL(forTag: entry.tag),
        let url = URL(string: asset.url),
        UpdateReleaseParser.sha256(UpdateReleaseParser.digestPrefix + asset.sha256)
          == asset.sha256,
        (1...UpdateReleaseParser.maximumAssetSize).contains(asset.size)
      else { throw .invalidValue }
      return UpdateRelease(
        version: version, pageURL: page,
        asset: UpdateAsset(downloadURL: url, sha256: asset.sha256, size: asset.size),
        assetProblem: nil)
    case (.none, .some(let problem)):
      guard let problem = UpdateAssetProblem(rawValue: problem) else { throw .invalidValue }
      return UpdateRelease(version: version, pageURL: page, asset: nil, assetProblem: problem)
    default:
      throw .invalidValue
    }
  } // End of static func release(_:)

  /// `date` as ISO 8601 in UTC with milliseconds.
  static func text(_ date: Date) -> String {
    formatter().string(from: date)
  }

  /// The date in an ISO 8601 text with milliseconds, as `text(_:)` writes it.
  static func date(_ text: String) throws(Problem) -> Date {
    guard let date = formatter().date(from: text) else { throw .invalidValue }
    return date
  }

  /// A formatter for ISO 8601 in UTC with fractional seconds (a new one each time: the class is
  /// not `Sendable`).
  static func formatter() -> ISO8601DateFormatter {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    formatter.timeZone = TimeZone(identifier: "UTC")
    return formatter
  }
}
