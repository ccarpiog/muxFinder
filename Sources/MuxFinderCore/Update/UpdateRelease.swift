import Foundation

/// The installable asset of a release (PLAN.md D39): `muxFinder.zip` at its exact GitHub
/// download URL, with its SHA-256 digest (64 lowercase hex characters) and its size. Only the
/// parser and the state file make one (the memberwise initializer is internal), after checking
/// every part.
public struct UpdateAsset: Sendable, Hashable {
  /// `https://github.com/ccarpiog/muxFinder/releases/download/<tag>/muxFinder.zip`.
  public let downloadURL: URL
  /// The SHA-256 digest GitHub reports for the file, lowercase hex.
  public let sha256: String
  /// The file's size in bytes, from 1 to `UpdateReleaseParser.maximumAssetSize`.
  public let size: Int
}

/// Why a release has no installable asset, so it is offered with its release page only.
public enum UpdateAssetProblem: String, Error, Sendable, Hashable, CaseIterable {
  /// No entry of `assets` is named exactly `muxFinder.zip`.
  case missing
  /// More than one entry is named `muxFinder.zip`, so none is trusted.
  case duplicate
  /// The entry's `browser_download_url` is not exactly the expected GitHub download URL.
  case foreignURL
  /// The entry has no `digest`.
  case digestMissing
  /// The entry's `digest` is not `sha256:` plus 64 hex characters.
  case digestMalformed
  /// The entry's `size` is not an integer from 1 to 50 MiB.
  case sizeOutOfRange
  /// The entry's `state` is present and not `uploaded`.
  case notUploaded
}

/// A published release of muxFinder as the check keeps it (PLAN.md D39): its version, its
/// release page and its installable asset, or why it has none. It never says whether it is
/// newer: that is worked out against the running version at every use (`UpdateOffer`), so an
/// updated app stops offering the release it now runs.
public struct UpdateRelease: Sendable, Hashable {
  /// The release's version, from its tag.
  public let version: UpdateVersion
  /// The release page (`html_url`): `https` on `github.com`, under the repository's releases.
  public let pageURL: URL
  /// The installable asset, or `nil` (see `assetProblem`).
  public let asset: UpdateAsset?
  /// Why there is no installable asset; `nil` when there is one.
  public let assetProblem: UpdateAssetProblem?

  /// A release from its checked parts.
  init(
    version: UpdateVersion, pageURL: URL, asset: UpdateAsset?, assetProblem: UpdateAssetProblem?
  ) {
    self.version = version
    self.pageURL = pageURL
    self.asset = asset
    self.assetProblem = asset == nil ? (assetProblem ?? .missing) : nil
  }

  /// The release's tag, `v` plus its version.
  public var tag: String { version.tag }
}

/// Why an answer offers nothing (PLAN.md D39). The first three make the check a failure (the
/// answer could not be read); the others are a successful check that offers nothing.
public enum UpdateNoOfferReason: String, Sendable, Hashable, CaseIterable {
  /// The body is larger than `UpdateReleaseParser.maximumBodySize`.
  case tooLarge
  /// The body is not JSON.
  case notJSON
  /// The body is JSON but not a release object as GitHub sends it (a field missing or of the
  /// wrong type).
  case malformed
  /// The tag is not exactly `v<major>.<minor>.<patch>` (see `UpdateVersion`).
  case unrecognizedTag
  /// `html_url` is not an `https` page on `github.com` under the repository's releases.
  case releasePageNotOurs
  /// The release is a draft.
  case draft
  /// The release is a prerelease.
  case prerelease
  /// The running app's version cannot be parsed, so nothing is newer than it.
  case runningVersionUnknown

  /// Whether this reason means the answer could not be read, which counts as a failed check.
  public var isUnreadableAnswer: Bool {
    switch self {
    case .tooLarge, .notJSON, .malformed: return true
    default: return false
    }
  }
}

/// What a `releases/latest` body comes to.
public enum UpdateReleaseDocument: Sendable, Hashable {
  /// A published release of ours.
  case release(UpdateRelease)
  /// Nothing is offered, for this reason.
  case nothingOffered(UpdateNoOfferReason)
}

/// What the check offers against the running version (PLAN.md D39). Never `newer` for an
/// equal, older or malformed tag.
public enum UpdateOffer: Sendable, Hashable {
  /// The latest release is not newer than the running app.
  case upToDate(latest: UpdateVersion)
  /// The latest release is newer: with its asset an Update can be offered, without one only
  /// its release page.
  case newer(UpdateRelease)
  /// Nothing is offered, for this reason.
  case nothingOffered(UpdateNoOfferReason)

  /// What `release` offers to an app running `runningVersion` (`CFBundleShortVersionString`):
  /// `newer` only when its version is strictly greater; nothing when the running version cannot
  /// be parsed.
  public static func evaluate(_ release: UpdateRelease, runningVersion: String?) -> UpdateOffer {
    guard let running = runningVersion.flatMap({ UpdateVersion($0) }) else {
      return .nothingOffered(.runningVersionUnknown)
    }
    return release.version > running ? .newer(release) : .upToDate(latest: release.version)
  }

  /// What `document` offers to an app running `runningVersion`.
  public static func evaluate(
    _ document: UpdateReleaseDocument, runningVersion: String?
  ) -> UpdateOffer {
    switch document {
    case .release(let release): return evaluate(release, runningVersion: runningVersion)
    case .nothingOffered(let reason): return .nothingOffered(reason)
    }
  }

  /// The newer release, when there is one.
  public var newerRelease: UpdateRelease? {
    if case .newer(let release) = self { return release }
    return nil
  }

  /// The newer release's installable asset, when there is one.
  public var installableAsset: UpdateAsset? { newerRelease?.asset }
}

/// The bounded parser of `GET /repos/ccarpiog/muxFinder/releases/latest` (PLAN.md D39). It
/// reads at most `maximumBodySize` bytes, needs a JSON object with `tag_name` and `html_url`,
/// offers nothing for a draft or a prerelease, and accepts as installable only the one asset
/// named exactly `muxFinder.zip` at its exact download URL, with a `sha256:` digest of 64 hex
/// characters, a size from 1 byte to `maximumAssetSize` and, when present, `state` `uploaded`.
public enum UpdateReleaseParser {
  /// The largest body read: 1 MiB.
  public static let maximumBodySize = 1 << 20
  /// The largest asset accepted: 50 MiB.
  public static let maximumAssetSize = 50 << 20
  /// The digest's prefix.
  static let digestPrefix = "sha256:"

  /// Parses a `releases/latest` body.
  public static func parse(_ data: Data) -> UpdateReleaseDocument {
    guard data.count <= maximumBodySize else { return .nothingOffered(.tooLarge) }
    guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    else { return .nothingOffered(.notJSON) }
    guard let fields = object as? [String: Any] else { return .nothingOffered(.malformed) }
    guard let draft = flag(fields["draft"]), let prerelease = flag(fields["prerelease"]),
      let tag = fields["tag_name"] as? String, let page = fields["html_url"] as? String
    else { return .nothingOffered(.malformed) }
    if draft { return .nothingOffered(.draft) }
    if prerelease { return .nothingOffered(.prerelease) }
    guard let version = UpdateVersion(tag: tag) else { return .nothingOffered(.unrecognizedTag) }
    guard let pageURL = releasePage(page) else { return .nothingOffered(.releasePageNotOurs) }
    switch asset(in: fields["assets"], tag: tag) {
    case .success(let asset):
      return .release(
        UpdateRelease(version: version, pageURL: pageURL, asset: asset, assetProblem: nil))
    case .failure(let problem):
      return .release(
        UpdateRelease(version: version, pageURL: pageURL, asset: nil, assetProblem: problem))
    }
  } // End of static func parse(_:)

  /// A `draft` or `prerelease` value: `false` when absent or `null`, the boolean when it is
  /// one, `nil` (malformed) for any other value.
  static func flag(_ value: Any?) -> Bool? {
    guard let value, !(value is NSNull) else { return false }
    return JSONValue.boolean(value)
  }

  /// The release page in `text` when it is an `https` URL on `github.com` (no user, password,
  /// port, query or fragment, no percent escape) whose path starts with the repository's
  /// releases and has no `.` or `..` segment; `nil` otherwise.
  public static func releasePage(_ text: String) -> URL? {
    guard let components = URLComponents(string: text), components.scheme == "https",
      components.host == UpdateSource.webHost, components.user == nil,
      components.password == nil, components.port == nil, components.query == nil,
      components.fragment == nil
    else { return nil }
    let path = components.percentEncodedPath
    guard !path.contains("%"), path.hasPrefix(UpdateSource.releasePagePathPrefix),
      path.count > UpdateSource.releasePagePathPrefix.count
    else { return nil }
    let segments = path.split(separator: "/", omittingEmptySubsequences: false)
    guard !segments.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
    return components.url
  } // End of static func releasePage(_:)

  /// The installable asset in an `assets` value for the release `tag`, or why there is none.
  static func asset(in value: Any?, tag: String) -> Result<UpdateAsset, UpdateAssetProblem> {
    let entries = (value as? [Any] ?? []).compactMap { $0 as? [String: Any] }
    let named = entries.filter { $0["name"] as? String == UpdateSource.assetName }
    guard let entry = named.first else { return .failure(.missing) }
    guard named.count == 1 else { return .failure(.duplicate) }
    let expected = UpdateSource.assetDownloadURL(forTag: tag)
    guard entry["browser_download_url"] as? String == expected, let url = URL(string: expected)
    else { return .failure(.foreignURL) }
    guard let digestValue = entry["digest"], !(digestValue is NSNull) else {
      return .failure(.digestMissing)
    }
    guard let digest = (digestValue as? String).flatMap(sha256) else {
      return .failure(.digestMalformed)
    }
    guard let size = JSONValue.integer(entry["size"]), (1...maximumAssetSize).contains(size) else {
      return .failure(.sizeOutOfRange)
    }
    if let state = entry["state"], !(state is NSNull), state as? String != "uploaded" {
      return .failure(.notUploaded)
    }
    return .success(UpdateAsset(downloadURL: url, sha256: digest, size: size))
  } // End of static func asset(in:tag:)

  /// The lowercase hex digest in `sha256:<64 hex>`, or `nil`.
  public static func sha256(_ text: String) -> String? {
    guard text.hasPrefix(digestPrefix) else { return nil }
    let hex = text.dropFirst(digestPrefix.count)
    guard hex.utf8.count == 64, hex.utf8.allSatisfy(isHexDigit) else { return nil }
    return hex.lowercased()
  }

  /// Whether `byte` is an ASCII hex digit.
  static func isHexDigit(_ byte: UInt8) -> Bool {
    (0x30...0x39).contains(byte) || (0x41...0x46).contains(byte) || (0x61...0x66).contains(byte)
  }
}

/// Reading JSON values from `JSONSerialization` without Foundation's bridging surprises: a JSON
/// `true` is not the number 1, and the number 1 is not `true`.
enum JSONValue {
  /// The boolean in `value` when it is a JSON `true` or `false`; `nil` for anything else.
  static func boolean(_ value: Any?) -> Bool? {
    guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
      return nil
    }
    return number.boolValue
  }

  /// The Objective-C type codes of the integer numbers `JSONSerialization` makes.
  static let integerTypeCodes: Set<String> = ["c", "s", "i", "l", "q", "C", "S", "I", "L", "Q"]

  /// The integer in `value` when it is a JSON number read as an integer (no fraction or
  /// exponent) that fits in `Int`; `nil` for anything else (a boolean, a floating-point or
  /// decimal number included).
  static func integer(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
      integerTypeCodes.contains(String(cString: number.objCType))
    else { return nil }
    let integer = number.int64Value
    guard number == NSNumber(value: integer) else { return nil }
    return Int(integer)
  }
}
