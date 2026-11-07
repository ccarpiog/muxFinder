import Foundation
import Testing

@testable import MuxFinderCore

/// `UpdateVersion` (PLAN.md D39): exactly three plain integers, numeric order, and tags of
/// exactly `v<major>.<minor>.<patch>`.
@Suite("Update version")
struct UpdateVersionTests {
  /// Plain versions parse to their parts.
  @Test func parsesPlainVersions() throws {
    let version = try #require(UpdateVersion("0.2.0"))
    #expect((version.major, version.minor, version.patch) == (0, 2, 0))
    #expect(version.description == "0.2.0")
    #expect(version.tag == "v0.2.0")
    #expect(UpdateVersion("10.20.30")?.description == "10.20.30")
    #expect(UpdateVersion("999999999.0.1")?.major == 999_999_999)
  }

  /// Everything else is refused: missing or extra parts, leading zeros, signs, spaces,
  /// non-ASCII digits, huge numbers, suffixes.
  @Test func refusesOddVersions() {
    for text in [
      "", "1", "1.0", "1.0.0.0", "1..0", ".1.0", "1.0.", "01.0.0", "0.02.0", "0.2.00", "+1.0.0",
      "-1.0.0", "1.-1.0", " 1.0.0", "1.0.0 ", "1. 0.0", "1.0.0\n", "1.0.0-beta", "1.0.0+2",
      "1.0.x", "１.0.0", "٠.1.0", "1000000000.0.0", "0.0.99999999999999999999", "0x1.0.0",
      "1e3.0.0", "v1.0.0",
    ] {
      #expect(UpdateVersion(text) == nil, "\(text)")
    } // End of loop over odd versions
    #expect(UpdateVersion(major: -1, minor: 0, patch: 0) == nil)
    #expect(UpdateVersion(major: 1_000_000_000, minor: 0, patch: 0) == nil)
  } // End of func refusesOddVersions()

  /// Tags need exactly a lowercase `v`.
  @Test func parsesTags() {
    #expect(UpdateVersion(tag: "v0.3.0") == UpdateVersion("0.3.0"))
    for tag in [
      "0.3.0", "V0.3.0", "vv0.3.0", "v 0.3.0", " v0.3.0", "v0.3", "v0.3.0.1", "v0.03.0",
      "v0.3.0-rc1", "release-0.3.0", "v-0.3.0", "v+0.3.0", "v0.3.0\t", "",
    ] {
      #expect(UpdateVersion(tag: tag) == nil, "\(tag)")
    } // End of loop over odd tags
  }

  /// Order is numeric, part by part.
  @Test func comparesNumerically() throws {
    func version(_ text: String) throws -> UpdateVersion { try #require(UpdateVersion(text)) }
    #expect(try version("0.10.0") > version("0.9.0"))
    #expect(try version("0.2.10") > version("0.2.9"))
    #expect(try version("1.0.0") > version("0.99.99"))
    #expect(try version("0.2.0") == version("0.2.0"))
    #expect(try !(version("0.2.0") < version("0.2.0")))
    #expect(try version("2.0.0") < version("10.0.0"))
    #expect(try version("999999999.999999999.999999999") > version("999999999.999999999.0"))
  }

  /// The source's URLs are built from the compiled-in owner and repository.
  @Test func sourceIsCompiledIn() {
    #expect(UpdateSource.owner == "ccarpiog")
    #expect(UpdateSource.repository == "muxFinder")
    #expect(
      UpdateSource.latestReleaseURL.absoluteString
        == "https://api.github.com/repos/ccarpiog/muxFinder/releases/latest")
    #expect(
      UpdateSource.assetDownloadURL(forTag: "v0.3.0")
        == "https://github.com/ccarpiog/muxFinder/releases/download/v0.3.0/muxFinder.zip")
  }
}
