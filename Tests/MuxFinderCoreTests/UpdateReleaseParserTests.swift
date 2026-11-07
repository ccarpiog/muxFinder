import Foundation
import Testing

@testable import MuxFinderCore

/// `UpdateReleaseParser` and `UpdateOffer` (PLAN.md D39) over synthetic bodies written by hand:
/// the body bound, the release page rule, drafts and prereleases, odd tags, every asset rule,
/// and what is offered against the running version.
@Suite("Update release parser")
struct UpdateReleaseParserTests {
  /// Shorthand.
  typealias Support = UpdateTestSupport

  /// The asset problem of a body whose only asset is `entry` (or whose assets are `assets`).
  static func assetProblem(
    _ entry: [String: Any]? = nil, assets: [[String: Any]]? = nil
  ) -> UpdateAssetProblem? {
    let body = Support.body(assets: assets ?? entry.map { [$0] })
    guard case .release(let release) = UpdateReleaseParser.parse(body) else { return nil }
    return release.assetProblem
  }

  /// The hand-written body parses to v0.3.0 with its asset, the digest normalized.
  @Test func parsesTheCanonicalBody() throws {
    let document = UpdateReleaseParser.parse(Data(Support.canonicalBody.utf8))
    guard case .release(let release) = document else {
      Issue.record("not a release: \(document)")
      return
    }
    #expect(release.version == UpdateVersion("0.3.0"))
    #expect(release.tag == "v0.3.0")
    #expect(
      release.pageURL.absoluteString == "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0")
    let asset = try #require(release.asset)
    #expect(release.assetProblem == nil)
    #expect(asset.sha256 == Support.normalizedDigest)
    #expect(asset.size == 6_123_456)
    #expect(
      asset.downloadURL.absoluteString
        == "https://github.com/ccarpiog/muxFinder/releases/download/v0.3.0/muxFinder.zip")
  } // End of func parsesTheCanonicalBody()

  /// Newer only when strictly greater; never for an equal, older or unparseable running
  /// version.
  @Test func offersOnlyNewerReleases() {
    let release = Support.release("v0.3.0")
    #expect(UpdateOffer.evaluate(release, runningVersion: "0.2.0") == .newer(release))
    #expect(UpdateOffer.evaluate(release, runningVersion: "0.2.9").installableAsset != nil)
    #expect(
      UpdateOffer.evaluate(release, runningVersion: "0.3.0")
        == .upToDate(latest: release.version))
    #expect(
      UpdateOffer.evaluate(release, runningVersion: "0.10.0")
        == .upToDate(latest: release.version))
    #expect(
      UpdateOffer.evaluate(release, runningVersion: "1.0.0").newerRelease == nil)
    for running in [nil, "", "0.2", "0.2.0 (2)", "v0.2.0", "02.0.0"] as [String?] {
      #expect(
        UpdateOffer.evaluate(release, runningVersion: running)
          == .nothingOffered(.runningVersionUnknown), "\(String(describing: running))")
    }
  } // End of func offersOnlyNewerReleases()

  /// A newer release without an installable asset is offered with its page only.
  @Test func newerWithoutAssetOffersThePageOnly() throws {
    let release = Support.release("v0.3.0", withAsset: false)
    #expect(release.asset == nil)
    #expect(release.assetProblem == .missing)
    let offer = UpdateOffer.evaluate(release, runningVersion: "0.2.0")
    let newer = try #require(offer.newerRelease)
    #expect(newer.pageURL.absoluteString.hasPrefix("https://github.com/ccarpiog/muxFinder/"))
    #expect(offer.installableAsset == nil)
  }

  /// Drafts and prereleases offer nothing; their flags must be JSON booleans.
  @Test func draftsAndPrereleasesOfferNothing() {
    #expect(UpdateReleaseParser.parse(Support.body(draft: true)) == .nothingOffered(.draft))
    #expect(
      UpdateReleaseParser.parse(Support.body(prerelease: true)) == .nothingOffered(.prerelease))
    for odd in ["true", 1, 0, "false"] as [Any] {
      #expect(UpdateReleaseParser.parse(Support.body(draft: odd)) == .nothingOffered(.malformed))
      #expect(
        UpdateReleaseParser.parse(Support.body(prerelease: odd)) == .nothingOffered(.malformed))
    }
    if case .release = UpdateReleaseParser.parse(Support.body(draft: nil, prerelease: NSNull())) {
    } else {
      Issue.record("absent or null flags must read as false")
    }
  } // End of func draftsAndPrereleasesOfferNothing()

  /// Tags other than `v<major>.<minor>.<patch>` offer nothing; a missing or non-string tag is
  /// malformed.
  @Test func oddTagsOfferNothing() {
    for tag in [
      "0.3.0", "V0.3.0", "v0.3", "v0.3.0.1", "v0.03.0", " v0.3.0", "v0.3.0 ", "v-1.0.0",
      "v1.0.0-beta", "v99999999999.0.0", "latest",
    ] {
      #expect(
        UpdateReleaseParser.parse(Support.body(tag: tag)) == .nothingOffered(.unrecognizedTag),
        "\(tag)")
    } // End of loop over odd tags
    #expect(UpdateReleaseParser.parse(Support.body(tag: nil)) == .nothingOffered(.malformed))
    #expect(UpdateReleaseParser.parse(Support.body(tag: 3)) == .nothingOffered(.malformed))
  } // End of func oddTagsOfferNothing()

  /// `html_url` must be an `https` page on `github.com` under the repository's releases.
  @Test func releasePageMustBeOurs() {
    for page in [
      "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://github.com/ccarpiog/muxFinder/releases/latest",
    ] {
      #expect(UpdateReleaseParser.releasePage(page) != nil, "\(page)")
    }
    for page in [
      "http://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://api.github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://gist.github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://github.com.evil.example/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://evil.example/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://github.com/someone/muxFinder/releases/tag/v0.3.0",
      "https://github.com/ccarpiog/muxfinder/releases/tag/v0.3.0",
      "https://github.com/ccarpiog/muxFinder/issues/1",
      "https://github.com/ccarpiog/muxFinder/releases/",
      "https://github.com/ccarpiog/muxFinder/releases/../../../evil/repo",
      "https://github.com/ccarpiog/muxFinder/releases/./tag",
      "https://github.com/ccarpiog/muxFinder/releases/tag/%2e%2e",
      "https://github.com:8443/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://user@github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
      "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0?x=1",
      "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0#x",
      "javascript:alert(1)", "", "github.com/ccarpiog/muxFinder/releases/tag/v0.3.0",
    ] {
      #expect(UpdateReleaseParser.releasePage(page) == nil, "\(page)")
      #expect(
        UpdateReleaseParser.parse(Support.body(page: page))
          == .nothingOffered(.releasePageNotOurs), "\(page)")
    } // End of loop over foreign pages
    #expect(UpdateReleaseParser.parse(Support.body(page: nil)) == .nothingOffered(.malformed))
    #expect(UpdateReleaseParser.parse(Support.body(page: 7)) == .nothingOffered(.malformed))
  } // End of func releasePageMustBeOurs()

  /// A body over 1 MiB is too large; one that is not JSON, or not an object, offers nothing.
  @Test func unreadableBodies() {
    let padding = String(repeating: "x", count: UpdateReleaseParser.maximumBodySize)
    let big = Data("{\"tag_name\": \"v0.3.0\", \"body\": \"\(padding)\"}".utf8)
    #expect(UpdateReleaseParser.parse(big) == .nothingOffered(.tooLarge))
    for text in ["", "not json", "{\"tag_name\": \"v0.3.0\"", "<html></html>"] {
      #expect(UpdateReleaseParser.parse(Data(text.utf8)) == .nothingOffered(.notJSON), "\(text)")
    }
    for text in ["[]", "\"v0.3.0\"", "3", "null", "{}"] {
      #expect(
        UpdateReleaseParser.parse(Data(text.utf8)) == .nothingOffered(.malformed), "\(text)")
    }
    #expect(UpdateNoOfferReason.tooLarge.isUnreadableAnswer)
    #expect(UpdateNoOfferReason.malformed.isUnreadableAnswer)
    #expect(!UpdateNoOfferReason.draft.isUnreadableAnswer)
  } // End of func unreadableBodies()

  /// No asset named exactly `muxFinder.zip`: missing; two: none trusted.
  @Test func assetMustBeTheOnlyMuxFinderZip() {
    #expect(Self.assetProblem(assets: []) == .missing)
    #expect(Self.assetProblem(Support.asset(name: "muxFinder.ZIP")) == .missing)
    #expect(Self.assetProblem(Support.asset(name: "muxFinder.zip ")) == .missing)
    #expect(Self.assetProblem(Support.asset(name: "muxFinder-0.3.0.zip")) == .missing)
    #expect(Self.assetProblem(Support.asset(name: nil)) == .missing)
    #expect(Self.assetProblem(assets: [Support.asset(), Support.asset()]) == .duplicate)
    #expect(
      Self.assetProblem(assets: [Support.asset(name: "notes.txt"), Support.asset()]) == nil)
    let noAssets = Support.body(assets: [])
    guard case .release(let release) = UpdateReleaseParser.parse(noAssets) else {
      Issue.record("an empty asset list is still a release")
      return
    }
    #expect(release.asset == nil)
    var fields = try! JSONSerialization.jsonObject(with: Support.body()) as! [String: Any]
    fields["assets"] = nil
    let withoutKey = try! JSONSerialization.data(withJSONObject: fields)
    guard case .release(let bare) = UpdateReleaseParser.parse(withoutKey) else {
      Issue.record("a release without assets is still a release")
      return
    }
    #expect(bare.assetProblem == .missing)
    fields["assets"] = "muxFinder.zip"
    let notAnArray = try! JSONSerialization.data(withJSONObject: fields)
    guard case .release(let odd) = UpdateReleaseParser.parse(notAnArray) else {
      Issue.record("odd assets still make a release")
      return
    }
    #expect(odd.assetProblem == .missing)
  } // End of func assetMustBeTheOnlyMuxFinderZip()

  /// The download URL must be exactly the release's own on `github.com`.
  @Test func assetURLMustBeExact() {
    for url in [
      "https://objects.githubusercontent.com/ccarpiog/muxFinder/releases/download/v0.3.0/muxFinder.zip",
      "http://github.com/ccarpiog/muxFinder/releases/download/v0.3.0/muxFinder.zip",
      "https://github.com/ccarpiog/muxFinder/releases/download/v0.2.0/muxFinder.zip",
      "https://github.com/someone/muxFinder/releases/download/v0.3.0/muxFinder.zip",
      "https://github.com/ccarpiog/muxFinder/releases/download/v0.3.0/muxFinder.zip?x=1",
      "https://github.com/ccarpiog/muxFinder/releases/download/v0.3.0/other.zip",
      "https://evil.example/muxFinder.zip", "",
    ] {
      #expect(Self.assetProblem(Support.asset(url: url)) == .foreignURL, "\(url)")
    } // End of loop over foreign URLs
    #expect(Self.assetProblem(Support.asset(url: 5)) == .foreignURL)
  } // End of func assetURLMustBeExact()

  /// The digest must be `sha256:` and 64 hex characters, normalized to lowercase.
  @Test func digestRules() {
    #expect(Self.assetProblem(Support.asset(digest: nil)) == .digestMissing)
    #expect(Self.assetProblem(Support.asset(digest: NSNull())) == .digestMissing)
    let hex = String(repeating: "0f", count: 32)
    for digest in [
      "sha512:" + hex, "SHA256:" + hex, "sha256:" + hex.dropLast(), "sha256:" + hex + "0",
      "sha256:" + hex.dropLast() + "g", "sha256: " + hex.dropLast(), hex, "", 42,
    ] as [Any] {
      #expect(Self.assetProblem(Support.asset(digest: digest)) == .digestMalformed, "\(digest)")
    }
    #expect(UpdateReleaseParser.sha256("sha256:" + hex.uppercased()) == hex)
    #expect(UpdateReleaseParser.sha256("sha256:" + hex) == hex)
  } // End of func digestRules()

  /// The size must be an integer from 1 byte to 50 MiB.
  @Test func sizeRules() {
    let limit = UpdateReleaseParser.maximumAssetSize
    #expect(limit == 52_428_800)
    #expect(Self.assetProblem(Support.asset(size: 1)) == nil)
    #expect(Self.assetProblem(Support.asset(size: limit)) == nil)
    for size in [0, -1, limit + 1, "6123456", 1.5, true, NSNull()] as [Any] {
      #expect(Self.assetProblem(Support.asset(size: size)) == .sizeOutOfRange, "\(size)")
    }
    #expect(Self.assetProblem(Support.asset(size: nil)) == .sizeOutOfRange)
    let huge = Data(
      Support.canonicalBody.replacingOccurrences(of: "6123456", with: "1e7").utf8)
    guard case .release(let release) = UpdateReleaseParser.parse(huge) else {
      Issue.record("still a release")
      return
    }
    #expect(release.assetProblem == .sizeOutOfRange)
  } // End of func sizeRules()

  /// `state`, when present, must be `uploaded`.
  @Test func stateRules() {
    #expect(Self.assetProblem(Support.asset(state: nil)) == nil)
    #expect(Self.assetProblem(Support.asset(state: NSNull())) == nil)
    #expect(Self.assetProblem(Support.asset(state: "new")) == .notUploaded)
    #expect(Self.assetProblem(Support.asset(state: "starter")) == .notUploaded)
    #expect(Self.assetProblem(Support.asset(state: 1)) == .notUploaded)
  }

  /// JSON booleans and integers are told apart from each other.
  @Test func jsonValues() throws {
    let object = try #require(
      try JSONSerialization.jsonObject(
        with: Data("{\"t\": true, \"one\": 1, \"half\": 0.5, \"big\": 1e30, \"neg\": -3}".utf8))
        as? [String: Any])
    #expect(JSONValue.boolean(object["t"]) == true)
    #expect(JSONValue.boolean(object["one"]) == nil)
    #expect(JSONValue.integer(object["one"]) == 1)
    #expect(JSONValue.integer(object["neg"]) == -3)
    #expect(JSONValue.integer(object["t"]) == nil)
    #expect(JSONValue.integer(object["half"]) == nil)
    #expect(JSONValue.integer(object["big"]) == nil)
    #expect(JSONValue.integer(nil) == nil)
  } // End of func jsonValues()
}
