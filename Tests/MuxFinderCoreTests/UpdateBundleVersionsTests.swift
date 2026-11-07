import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The version step (PLAN.md D39, I-13b1): the identifier, the short version against the
/// release's tag, the build as a plain positive integer strictly greater than the running
/// build (an unparseable running build refuses), and the bounded, link-refusing read of
/// `Contents/Info.plist`; through the verifier only after the code check passed.
@Suite("Update bundle versions")
struct UpdateBundleVersionsTests {
  /// Shorthand.
  typealias Support = UpdateVerifyTestSupport

  /// The release version the tests expect.
  static let expected = UpdateVersion("0.3.0")!

  /// An `Info.plist` dictionary.
  static func info(
    identifier: Any? = "cc.carpio.muxfinder", short: Any? = "0.3.0", build: Any? = "3"
  ) -> [String: Any] {
    var info: [String: Any] = [:]
    info["CFBundleIdentifier"] = identifier
    info["CFBundleShortVersionString"] = short
    info["CFBundleVersion"] = build
    return info
  }

  /// Checks `info` against 0.3.0 and `running`.
  static func check(_ info: [String: Any], running: String? = "2") -> Result<
    UpdateBundleVersionFacts, UpdateVersionProblem
  > {
    UpdateBundleVersions.check(info: info, expected: expected, runningBuild: running)
  }

  /// The happy path, and each problem.
  @Test func rules() {
    #expect(
      Self.check(Self.info())
        == .success(UpdateBundleVersionFacts(version: Self.expected, build: 3)))
    #expect(
      Self.check(Self.info(build: "1"), running: "0")
        == .success(UpdateBundleVersionFacts(version: Self.expected, build: 1)))
    #expect(
      Self.check(Self.info(build: "999999999"), running: "999999998").map(\.build)
        == .success(999_999_999))
    for identifier in [nil, "cc.carpio.muxFinder", "cc.carpio.muxfinder.x", "", 1] as [Any?] {
      #expect(Self.check(Self.info(identifier: identifier)) == .failure(.identifierMismatch))
    }
    for short in [nil, "0.3", "v0.3.0", "0.03.0", "0.3.0 ", 0.3, "0.3.0.0"] as [Any?] {
      #expect(
        Self.check(Self.info(short: short)) == .failure(.shortVersionUnparseable),
        "\(String(describing: short))")
    }
    for short in ["0.3.1", "0.2.0", "1.0.0"] {
      #expect(Self.check(Self.info(short: short)) == .failure(.shortVersionNotTag))
    }
    for build in [nil, "", "0", "03", "-3", "+3", " 3", "3 ", "3.0", "1234567890", "٣", "0x3", 3]
      as [Any?]
    {
      #expect(
        Self.check(Self.info(build: build)) == .failure(.buildUnparseable),
        "\(String(describing: build))")
    } // End of loop over unparseable builds
    for running in [nil, "", "x", "2.0", "02", "-1", "1234567890"] as [String?] {
      #expect(
        Self.check(Self.info(), running: running) == .failure(.runningBuildUnknown),
        "\(String(describing: running))")
    }
    #expect(Self.check(Self.info(build: "3"), running: "3") == .failure(.buildNotNewer))
    #expect(Self.check(Self.info(build: "3"), running: "10") == .failure(.buildNotNewer))
    #expect(UpdateBundleVersions.build("0") == 0)
    #expect(UpdateBundleVersions.build("12") == 12)
  } // End of func rules()

  /// `Info.plist` is read only as a regular file under a real `Contents` folder, at most
  /// 256 KiB, holding a dictionary.
  @Test func infoReading() throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let manager = FileManager.default
    /// Reads the `Info.plist` of the app `name` in `folder`.
    func read(_ name: String) -> [String: Any]? {
      let app = open(
        folder.appending(path: name).path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
      guard app >= 0 else { return nil }
      defer { close(app) }
      return UpdateBundleVersions.readInfo(app: app)
    }
    let good = folder.appending(path: "good.app", directoryHint: .isDirectory)
    try Support.makeApp(at: good)
    #expect(read("good.app")?["CFBundleVersion"] as? String == "3")

    let large = folder.appending(path: "large.app", directoryHint: .isDirectory)
    try Support.makeApp(at: large)
    try Data(count: 256 * 1024 + 1).write(to: large.appending(path: "Contents/Info.plist"))
    #expect(read("large.app") == nil)

    let array = folder.appending(path: "array.app", directoryHint: .isDirectory)
    try Support.makeApp(at: array)
    try PropertyListSerialization.data(fromPropertyList: ["a"], format: .xml, options: 0).write(
      to: array.appending(path: "Contents/Info.plist"))
    #expect(read("array.app") == nil)

    let linked = folder.appending(path: "linked.app", directoryHint: .isDirectory)
    try Support.makeApp(at: linked)
    try manager.removeItem(at: linked.appending(path: "Contents/Info.plist"))
    try manager.createSymbolicLink(
      atPath: linked.appending(path: "Contents/Info.plist").path(percentEncoded: false),
      withDestinationPath: good.appending(path: "Contents/Info.plist").path(percentEncoded: false))
    #expect(read("linked.app") == nil)

    let contentsLink = folder.appending(path: "contents-link.app", directoryHint: .isDirectory)
    try manager.createDirectory(at: contentsLink, withIntermediateDirectories: false)
    try manager.createSymbolicLink(
      atPath: contentsLink.appending(path: "Contents").path(percentEncoded: false),
      withDestinationPath: good.appending(path: "Contents").path(percentEncoded: false))
    #expect(read("contents-link.app") == nil)
  } // End of func infoReading()

  /// Through the verifier (a passing fake code checker on an unsigned stub): each version
  /// problem fails the versions step after the code check, and leaves nothing; the release's
  /// own version and a greater build pass, keeping only the bundle.
  @Test func throughTheVerifier() async throws {
    let cases: [(Data, String, UpdateVersionProblem?)] = [
      (Support.infoPlist(), "2", nil),
      (Support.infoPlist(identifier: "cc.example.other"), "2", .identifierMismatch),
      (Support.infoPlist(short: "0.3.1"), "2", .shortVersionNotTag),
      (Support.infoPlist(short: "0.3"), "2", .shortVersionUnparseable),
      (Support.infoPlist(build: "3.1"), "2", .buildUnparseable),
      (Support.infoPlist(build: "3"), "3", .buildNotNewer),
      (Support.infoPlist(build: "3"), "two", .runningBuildUnknown),
    ]
    for (info, running, problem) in cases {
      let zip = try await Support.makeZip { source in
        try Support.makeApp(
          at: source.appending(path: "muxFinder.app", directoryHint: .isDirectory), info: info)
      }
      defer { try? FileManager.default.removeItem(at: zip.folder) }
      let (staging, folder) = try Support.makeStaging()
      defer { try? FileManager.default.removeItem(at: folder) }
      let checker = FakeUpdateCodeChecker(.passed)
      let report = await UpdateVerifier(
        staging: staging, team: Support.team, runningBuild: running, codeChecker: checker
      ).verifyLocalZip(
        atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
        expectedVersion: Self.expected)
      #expect(checker.paths == [folder.path(percentEncoded: false) + "extracted/muxFinder.app"])
      #expect(report.verdict(of: .notarization) == .passed)
      if let problem {
        #expect(report.failure == .versions(problem), "\(problem)")
        #expect(try Support.names(folder).isEmpty)
      } else {
        #expect(report.verifiedBundle?.version == Self.expected)
        #expect(report.verifiedBundle?.build == 3)
        #expect(try Support.names(folder) == ["extracted"])
        #expect(try Support.names(folder.appending(path: "extracted")) == ["muxFinder.app"])
      }
    } // End of loop over the cases
  } // End of func throughTheVerifier()
}
