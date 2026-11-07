import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `muxfinder-probe update verify …` (`UpdateVerifyProbe`, PLAN.md D39, I-13b1) over injected
/// transports, process runner and code checker and synthetic zips, so no request is sent:
/// `--help` and bad arguments contact nothing and write nothing, `--into`'s rules, the zip
/// mode's JSON for a pass and for each kind of failure (never the Team ID, never a path in the
/// home folder), and the latest mode over a fake check and a fake download.
@Suite("Update verify probe")
struct UpdateVerifyProbeTests {
  /// Shorthand.
  typealias Support = UpdateVerifyTestSupport

  /// What one run printed and made.
  struct Run {
    /// The exit status.
    var status: Int32
    /// Standard output.
    var output: String
    /// Standard error.
    var error: String
    /// The running versions check transports were made with.
    var checksMade: [String]
    /// The running versions download transports were made with.
    var downloadsMade: [String]

    /// The output's JSON object.
    func json() throws -> [String: Any] {
      try #require(try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }

    /// The output's steps, as name to verdict.
    func steps() throws -> [String: String] {
      let steps = try #require(try json()["steps"] as? [[String: Any]])
      return Dictionary(
        uniqueKeysWithValues: steps.map { ($0["step"] as! String, $0["verdict"] as! String) })
    }
  }

  /// Records which transports were made.
  final class Made: Sendable {
    /// The versions.
    private let versions = OSAllocatedUnfairLock<[String]>(initialState: [])
    /// Records one.
    func record(_ version: String) { versions.withLock { $0.append(version) } }
    /// All so far.
    var all: [String] { versions.withLock { $0 } }
  }

  /// Runs `update` with `arguments`.
  static func run(
    _ arguments: [String],
    check: FakeUpdateTransport = FakeUpdateTransport(),
    download: FakeUpdateDownloadTransport = FakeUpdateDownloadTransport(.failure(.offline)),
    codeChecker: FakeUpdateCodeChecker = FakeUpdateCodeChecker(.passed)
  ) async -> Run {
    var output = ""
    var error = ""
    var checks: [String] = []
    let downloads = Made()
    let environment = UpdateVerifyProbe.Environment(
      makeDownloadTransport: { version in
        downloads.record(version)
        return download
      },
      processRunner: PosixSpawnProcessRunner(),
      codeChecker: codeChecker)
    let status = await UpdateProbe.run(
      arguments,
      makeTransport: { version in
        checks.append(version)
        return check
      },
      verifyEnvironment: environment,
      now: { ManualUpdateClock.baseDate },
      standardOutput: { output += $0 },
      standardError: { error += $0 })
    return Run(
      status: status, output: output, error: error, checksMade: checks,
      downloadsMade: downloads.all)
  } // End of static func run(_:check:download:codeChecker:)

  /// A new empty private `--into` folder and its path (no trailing slash).
  static func into() throws -> (URL, String) {
    let folder = try UpdateTestSupport.makePrivateFolder()
    return (folder, String(folder.path(percentEncoded: false).dropLast()))
  }

  /// A zip of a stub app (0.3.0, build 3) and its digest.
  static func stubZip() async throws -> (
    data: Data, url: URL, folder: URL, path: String, digest: String
  ) {
    let zip = try await Support.makeZip { source in
      try Support.makeApp(at: source.appending(path: "muxFinder.app", directoryHint: .isDirectory))
    }
    return (
      zip.data, zip.url, zip.folder, zip.url.path(percentEncoded: false), Support.sha256(zip.data)
    )
  }

  /// `--help` in `verify` prints the usage, exits 0 and makes nothing.
  @Test func helpContactsNothing() async {
    for arguments in [
      ["verify", "--help"], ["verify", "-h"], ["verify", "--latest", "--help"], ["--help"],
    ] {
      let run = await Self.run(arguments)
      #expect(run.status == 0, "\(arguments)")
      #expect(run.output.contains("update verify --into <dir> --team-id <id>"))
      #expect(run.output.contains("update check [--running-version <x.y.z>]"))
      #expect(run.checksMade.isEmpty)
      #expect(run.downloadsMade.isEmpty)
    } // End of loop over help forms
  } // End of func helpContactsNothing()

  /// Unusable arguments exit 64, make no transport and write nothing.
  @Test func usageErrorsContactNothing() async throws {
    let (folder, into) = try Self.into()
    defer { try? FileManager.default.removeItem(at: folder) }
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let team = Support.team.value
    let zipArgs = ["--zip", zip.path, "--sha256", zip.digest, "--expect-version", "0.3.0"]
    let cases: [[String]] = [
      ["verify"],
      ["verify", "--team-id", team, "--latest"],
      ["verify", "--into", into, "--latest"],
      ["verify", "--into", into, "--team-id", "abcde12345", "--latest"],
      ["verify", "--into", into, "--team-id", "ABCDE1234", "--latest"],
      ["verify", "--into", into, "--team-id", "ABCDE\"1234", "--latest"],
      ["verify", "--into", into, "--team-id", team],
      ["verify", "--into", into, "--team-id", team, "--latest"] + zipArgs,
      ["verify", "--into", into, "--team-id", team, "--latest", "--sha256", zip.digest],
      ["verify", "--into", into, "--team-id", team, "--zip", zip.path, "--sha256", zip.digest],
      [
        "verify", "--into", into, "--team-id", team, "--zip", zip.path, "--expect-version", "0.3.0",
      ],
      [
        "verify", "--into", into, "--team-id", team, "--zip", "relative.zip", "--sha256",
        zip.digest,
        "--expect-version", "0.3.0",
      ],
      [
        "verify", "--into", into, "--team-id", team, "--zip", zip.path, "--sha256", "abc",
        "--expect-version", "0.3.0",
      ],
      [
        "verify", "--into", into, "--team-id", team, "--zip", zip.path, "--sha256", zip.digest,
        "--expect-version", "v0.3.0",
      ],
      ["verify", "--into", into, "--team-id", team, "--latest", "--running-build", "2.0"],
      ["verify", "--into", into, "--team-id", team, "--latest", "--running-build", "02"],
      ["verify", "--into", into, "--team-id", team, "--latest", "--latest"],
      ["verify", "--into", into, "--into", into, "--team-id", team, "--latest"],
      ["verify", "--into", into, "--team-id", team, "--latest", "--bogus"],
      ["verify", "--into", into, "--team-id", team, "--latest", "--running-build"],
      [
        "verify", "--into", into, "--team-id", team, "--zip", zip.path + ".missing", "--sha256",
        zip.digest, "--expect-version", "0.3.0",
      ],
      ["verify", "--into", into + "/missing", "--team-id", team, "--latest"],
      ["verify", "--into", "/tmp", "--team-id", team, "--latest"],
      ["verify", "--into", "relative", "--team-id", team, "--latest"],
      ["verify", "--into", "/private/var", "--team-id", team, "--latest"],
    ]
    for arguments in cases {
      let run = await Self.run(arguments)
      #expect(run.status == 64, "\(arguments)")
      #expect(run.checksMade.isEmpty, "\(arguments)")
      #expect(run.downloadsMade.isEmpty)
      #expect(run.output.isEmpty)
      #expect(run.error.hasPrefix("muxfinder-probe: "), "\(arguments)")
      #expect(!run.error.contains(team), "\(arguments)")
    } // End of loop over unusable arguments
    #expect(try Support.names(folder).isEmpty)
  } // End of func usageErrorsContactNothing()

  /// `--into` must be empty and private, and is never changed.
  @Test func intoRules() async throws {
    let (folder, into) = try Self.into()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(UpdateVerifyProbe.intoProblem(into) == nil)
    try Data("x".utf8).write(to: folder.appending(path: "existing"))
    let notEmpty = await Self.run([
      "verify", "--into", into, "--team-id", Support.team.value, "--latest",
    ])
    #expect(notEmpty.status == 64)
    #expect(notEmpty.error.contains("empty"))
    #expect(try Support.names(folder) == ["existing"])
    let open = folder.appending(path: "open", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: open, withIntermediateDirectories: false)
    #expect(chmod(open.path(percentEncoded: false), 0o755) == 0)
    #expect(UpdateVerifyProbe.intoProblem(open.path(percentEncoded: false)) != nil)
    #expect(try LaunchTestSupport.permissions(of: open) == 0o755)
  } // End of func intoRules()

  /// The zip mode: every step passed, exit 0, the bundle kept at its relative path, no Team
  /// ID or home path printed, no transport made, the zip deleted.
  @Test func zipModePasses() async throws {
    let (folder, into) = try Self.into()
    defer { try? FileManager.default.removeItem(at: folder) }
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let checker = FakeUpdateCodeChecker(.passed)
    let run = await Self.run(
      [
        "verify", "--into", into, "--team-id", Support.team.value, "--zip", zip.path,
        "--sha256", "sha256:" + zip.digest.uppercased(), "--expect-version", "0.3.0",
        "--running-build", "2",
      ], codeChecker: checker)
    #expect(run.status == 0)
    #expect(run.checksMade.isEmpty)
    #expect(run.downloadsMade.isEmpty)
    let json = try run.json()
    #expect(json["mode"] as? String == "zip")
    #expect(json["verdict"] as? String == "verified")
    #expect(json["expectedVersion"] as? String == "0.3.0")
    #expect(json["runningBuild"] as? String == "2")
    #expect(json["zipSize"] as? Int == zip.data.count)
    #expect(JSONValue.boolean(json["cleanedUp"]) == true)
    #expect(json["failedStep"] == nil)
    let bundle = try #require(json["bundle"] as? [String: Any])
    #expect(bundle["path"] as? String == "extracted/muxFinder.app")
    #expect(bundle["version"] as? String == "0.3.0")
    #expect(bundle["build"] as? Int == 3)
    let steps = try run.steps()
    #expect(steps.count == 7)
    #expect(steps.values.allSatisfy { $0 == "passed" })
    #expect(!run.output.contains(Support.team.value))
    #expect(!run.output.contains(NSHomeDirectory()))
    #expect(!run.output.contains(into))
    #expect(try Support.names(folder) == ["extracted"])
    #expect(checker.paths == [into + "/extracted/muxFinder.app"])
  } // End of func zipModePasses()

  /// The zip mode's failures exit 1 with the failed step, its code and reason; nothing is left.
  @Test func zipModeFailures() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let wrongDigest = String(repeating: "0", count: 64)
    let cases: [(String, String, FakeUpdateCodeChecker, String, String, String)] = [
      (
        wrongDigest, "2", FakeUpdateCodeChecker(.passed), "digest", "digestMismatch",
        "the download doesn't match the release's checksum"
      ),
      (
        zip.digest, "2", FakeUpdateCodeChecker(.signatureFailed(.otherTeam)), "signature",
        "otherTeam", "the app is signed by another developer"
      ),
      (
        zip.digest, "2", FakeUpdateCodeChecker(.notarizationFailed(.notNotarized(-67050))),
        "notarization", "notNotarized", "the app isn't notarized by Apple"
      ),
      (
        zip.digest, "3", FakeUpdateCodeChecker(.passed), "versions", "buildNotNewer",
        "the app isn't newer than this copy"
      ),
    ]
    for (digest, running, checker, step, code, reason) in cases {
      let (folder, into) = try Self.into()
      defer { try? FileManager.default.removeItem(at: folder) }
      let run = await Self.run(
        [
          "verify", "--into", into, "--team-id", Support.team.value, "--zip", zip.path,
          "--sha256", digest, "--expect-version", "0.3.0", "--running-build", running,
        ], codeChecker: checker)
      #expect(run.status == 1, "\(step)")
      let json = try run.json()
      #expect(json["verdict"] as? String == "failed")
      #expect(json["failedStep"] as? String == step)
      #expect(json["code"] as? String == code)
      #expect(json["reason"] as? String == reason)
      #expect(json["bundle"] == nil)
      #expect(JSONValue.boolean(json["cleanedUp"]) == true)
      let steps = try run.steps()
      #expect(steps[step] == "failed")
      #expect(steps["versions"] == (step == "versions" ? "failed" : "notRun"))
      #expect(!run.output.contains(Support.team.value))
      #expect(try Support.names(folder).isEmpty, "\(step)")
    } // End of loop over the failures
  } // End of func zipModeFailures()

  /// The latest mode: one check (running version 0.0.0), then the download of its asset and
  /// every step; a failed check or a release without an asset stops before any download.
  @Test func latestMode() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let body = UpdateTestSupport.body(
      tag: "v0.3.0",
      assets: [
        UpdateTestSupport.asset(
          tag: "v0.3.0", digest: "sha256:" + zip.digest, size: zip.data.count)
      ])
    let (folder, into) = try Self.into()
    defer { try? FileManager.default.removeItem(at: folder) }
    let download = FakeUpdateDownloadTransport(.success(zip.data))
    let run = await Self.run(
      [
        "verify", "--into", into, "--team-id", Support.team.value, "--latest", "--running-build",
        "2",
      ],
      check: FakeUpdateTransport([.body(body, etag: "\"e\"")]), download: download)
    #expect(run.status == 0)
    #expect(run.checksMade == ["0.0.0"])
    #expect(run.downloadsMade == ["0.0.0"])
    #expect(download.assets.map(\.size) == [zip.data.count])
    let json = try run.json()
    #expect(json["mode"] as? String == "latest")
    #expect(json["verdict"] as? String == "verified")
    #expect(json["expectedVersion"] as? String == "0.3.0")
    let check = try #require(json["check"] as? [String: Any])
    #expect(check["outcome"] as? String == "newer")
    #expect(check["latestTag"] as? String == "v0.3.0")
    #expect(JSONValue.boolean(check["assetPresent"]) == true)
    #expect(try Support.names(folder) == ["extracted"])

    for (response, failedStep, code) in [
      (UpdateCheckResponse.failed(.offline), "check", "failed.offline"),
      (.body(UpdateTestSupport.body(assets: []), etag: nil), "download", "noInstallableAsset"),
      (.body(UpdateTestSupport.body(draft: true), etag: nil), "download", "noInstallableAsset"),
    ] {
      let (emptyFolder, emptyInto) = try Self.into()
      defer { try? FileManager.default.removeItem(at: emptyFolder) }
      let failed = await Self.run(
        ["verify", "--into", emptyInto, "--team-id", Support.team.value, "--latest"],
        check: FakeUpdateTransport([response]))
      #expect(failed.status == 1, "\(code)")
      #expect(failed.downloadsMade.isEmpty)
      let failedJSON = try failed.json()
      #expect(failedJSON["failedStep"] as? String == failedStep)
      #expect(failedJSON["code"] as? String == code)
      #expect(failedJSON["runningBuild"] as? String == "0")
      #expect(try Support.names(emptyFolder).isEmpty)
    } // End of loop over check outcomes that offer no download
  } // End of func latestMode()
}
