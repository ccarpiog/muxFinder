import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// `muxfinder-probe update …`'s arguments, check and output (`UpdateProbe`, PLAN.md D39) over
/// an injected transport, so no request is sent: `--help` and bad arguments make no transport,
/// the JSON for each outcome, and `--state` on a private folder only (one open to others or
/// with an ACL is refused and left as it is).
@Suite("Update probe")
struct UpdateProbeTests {
  /// Shorthand.
  typealias Support = UpdateTestSupport

  /// What one run printed and made.
  struct Run {
    /// The exit status.
    var status: Int32
    /// Standard output.
    var output = ""
    /// Standard error.
    var error = ""
    /// The running versions the transport was made with.
    var transportsMade: [String] = []

    /// The output's JSON object.
    func json() throws -> [String: Any] {
      try #require(
        try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])
    }
  }

  /// Runs `update` with `arguments` over `transport`.
  static func run(
    _ arguments: [String], transport: FakeUpdateTransport = FakeUpdateTransport()
  ) async -> Run {
    var run = Run(status: -1)
    var made: [String] = []
    var output = ""
    var error = ""
    run.status = await UpdateProbe.run(
      arguments,
      makeTransport: { version in
        made.append(version)
        return transport
      },
      now: { ManualUpdateClock.baseDate },
      standardOutput: { output += $0 },
      standardError: { error += $0 })
    run.output = output
    run.error = error
    run.transportsMade = made
    return run
  } // End of static func run(_:transport:)

  /// `--help` in every position prints the usage, exits 0 and makes no transport.
  @Test func helpContactsNothing() async {
    for arguments in [
      ["--help"], ["help"], ["-h"], ["check", "--help"], ["check", "-h"],
      ["check", "--running-version", "1.0.0", "--help"],
    ] {
      let run = await Self.run(arguments)
      #expect(run.status == 0, "\(arguments)")
      #expect(run.output.contains("update check [--running-version <x.y.z>] [--state <dir>]"))
      #expect(run.transportsMade.isEmpty)
    } // End of loop over help forms
  } // End of func helpContactsNothing()

  /// Unusable arguments exit 64 and make no transport.
  @Test func usageErrorsContactNothing() async throws {
    let file = try Support.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: file) }
    let plainFile = file.appending(path: "file")
    try Data().write(to: plainFile)
    let link = file.appending(path: "link")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
    for arguments in [
      [], ["fetch"], ["check", "--bogus"], ["check", "--running-version"],
      ["check", "--running-version", "0.2"], ["check", "--running-version", "v0.2.0"],
      ["check", "--running-version", "0.2.0", "--running-version", "0.3.0"],
      ["check", "--state"], ["check", "--state", "relative/folder"],
      ["check", "--state", link.path(percentEncoded: false)],
      ["check", "--state", plainFile.path(percentEncoded: false)],
      ["check", "--state", file.path(percentEncoded: false) + "/missing"],
      ["check", "--state", file.path(percentEncoded: false) + "/../x"],
      ["check", "--state", "/tmp"],
    ] {
      let run = await Self.run(arguments)
      #expect(run.status == 64, "\(arguments)")
      #expect(run.transportsMade.isEmpty, "\(arguments)")
      #expect(run.output.isEmpty)
      #expect(run.error.hasPrefix("muxfinder-probe: "))
    } // End of loop over unusable arguments
  } // End of func usageErrorsContactNothing()

  /// A newer release with its asset: every fact printed, exit 0, the default running version
  /// (also the transport's), nothing written.
  @Test func printsANewerRelease() async throws {
    let transport = FakeUpdateTransport([UpdateSchedulerTests.ok])
    let run = await Self.run(["check"], transport: transport)
    #expect(run.status == 0)
    #expect(run.transportsMade == ["0.0.0"])
    #expect(transport.etags == [nil])
    let json = try run.json()
    #expect(json["outcome"] as? String == "newer")
    #expect(JSONValue.boolean(json["sent"]) == true)
    #expect(json["runningVersion"] as? String == "0.0.0")
    #expect(json["latestTag"] as? String == "v0.3.0")
    #expect(JSONValue.boolean(json["newer"]) == true)
    #expect(
      json["releasePage"] as? String
        == "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0")
    #expect(JSONValue.boolean(json["assetPresent"]) == true)
    #expect(JSONValue.boolean(json["digestPresent"]) == true)
    #expect(json["size"] as? Int == 6_123_456)
    #expect(JSONValue.boolean(json["etagKept"]) == true)
    #expect(json["state"] == nil)
    #expect(json["assetProblem"] == nil)
  } // End of func printsANewerRelease()

  /// The same release for an app already on it is up to date; one without an asset is newer
  /// with no asset.
  @Test func printsOtherOffers() async throws {
    let upToDate = await Self.run(
      ["check", "--running-version", "0.3.0"],
      transport: FakeUpdateTransport([UpdateSchedulerTests.ok]))
    #expect(upToDate.status == 0)
    #expect(upToDate.transportsMade == ["0.3.0"])
    let json = try upToDate.json()
    #expect(json["outcome"] as? String == "upToDate")
    #expect(JSONValue.boolean(json["newer"]) == false)
    #expect(json["latestTag"] as? String == "v0.3.0")

    let bare = await Self.run(
      ["check", "--running-version", "0.2.0"],
      transport: FakeUpdateTransport([.body(Support.body(assets: []), etag: nil)]))
    let bareJSON = try bare.json()
    #expect(bare.status == 0)
    #expect(bareJSON["outcome"] as? String == "newer")
    #expect(JSONValue.boolean(bareJSON["assetPresent"]) == false)
    #expect(JSONValue.boolean(bareJSON["digestPresent"]) == false)
    #expect(bareJSON["assetProblem"] as? String == "missing")
    #expect(bareJSON["size"] == nil)
    #expect(JSONValue.boolean(bareJSON["etagKept"]) == false)

    let draft = await Self.run(
      ["check"], transport: FakeUpdateTransport([.body(Support.body(draft: true), etag: nil)]))
    #expect(draft.status == 0)
    #expect(try draft.json()["outcome"] as? String == "nothingOffered.draft")
  } // End of func printsOtherOffers()

  /// Failures and rate limits exit 1 with their outcome.
  @Test func printsFailures() async throws {
    let base = ManualUpdateClock.baseDate
    for (response, code) in [
      (UpdateCheckResponse.failed(.offline), "failed.offline"),
      (.failed(.timedOut), "failed.timedOut"), (.httpStatus(502), "failed.httpStatus.502"),
      (.tooLarge, "failed.unreadableAnswer.tooLarge"),
      (.body(Data("nope".utf8), etag: nil), "failed.unreadableAnswer.notJSON"),
      (.notModified, "failed.notModifiedWithoutRelease"),
      (.rateLimited(until: base.addingTimeInterval(90)), "rateLimited"),
    ] {
      let run = await Self.run(["check"], transport: FakeUpdateTransport([response]))
      #expect(run.status == 1, "\(code)")
      let json = try run.json()
      #expect(json["outcome"] as? String == code)
      #expect(json["latestTag"] == nil)
      #expect(JSONValue.boolean(json["newer"]) == false)
      if code == "rateLimited" {
        #expect(json["rateLimitedUntil"] as? String == "2027-01-15T08:01:30.000Z")
      }
    } // End of loop over the failures
  } // End of func printsFailures()

  /// With `--state` the state is read and written in that private folder only: the `ETag`
  /// goes back, a 304 reuses the kept release, and a recorded rate limit sends nothing.
  @Test func stateFolderRoundTrip() async throws {
    let folder = try Support.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.path(percentEncoded: false)
    let transport = FakeUpdateTransport(
      [UpdateSchedulerTests.ok, .notModified, .rateLimited(until: .distantFuture)])
    let first = await Self.run(["check", "--state", path], transport: transport)
    #expect(first.status == 0)
    let firstState = try #require(try first.json()["state"] as? [String: Any])
    #expect(firstState["found"] as? String == "missing")
    #expect(JSONValue.boolean(firstState["saved"]) == true)
    #expect(try LaunchTestSupport.names(in: folder) == [UpdateStateStore.fileName])
    #expect(
      try LaunchTestSupport.permissions(of: folder.appending(path: UpdateStateStore.fileName))
        == 0o600)

    let second = await Self.run(
      ["check", "--state", path, "--running-version", "0.2.0"], transport: transport)
    #expect(second.status == 0)
    #expect(transport.etags == [nil, "\"e1\""])
    let secondJSON = try second.json()
    #expect(secondJSON["outcome"] as? String == "newer")
    #expect((secondJSON["state"] as? [String: Any])?["found"] as? String == "saved")

    let third = await Self.run(["check", "--state", path], transport: transport)
    #expect(third.status == 1)
    #expect(try third.json()["outcome"] as? String == "rateLimited")
    let fourth = await Self.run(["check", "--state", path], transport: transport)
    #expect(fourth.status == 1)
    let fourthJSON = try fourth.json()
    #expect(fourthJSON["outcome"] as? String == "rateLimited")
    #expect(JSONValue.boolean(fourthJSON["sent"]) == false)
    #expect(fourth.transportsMade.isEmpty)
    #expect(transport.calls == 3)
    #expect(try LaunchTestSupport.names(in: folder) == [UpdateStateStore.fileName])
  } // End of func stateFolderRoundTrip()

  /// Runs `check --state <folder>` over a transport that would answer, and expects a usage
  /// error with no transport made, nothing printed on standard output and nothing written.
  static func expectRefused(_ folder: URL) async throws {
    let path = folder.path(percentEncoded: false)
    let transport = FakeUpdateTransport([UpdateSchedulerTests.ok])
    let run = await Self.run(["check", "--state", path], transport: transport)
    #expect(run.status == 64, "\(path)")
    #expect(run.transportsMade.isEmpty)
    #expect(transport.calls == 0)
    #expect(run.output.isEmpty)
    #expect(run.error.hasPrefix("muxfinder-probe: --state "))
    #expect(UpdateProbe.stateDirectoryProblem(path) != nil)
    #expect(try LaunchTestSupport.names(in: folder).isEmpty)
  } // End of static func expectRefused(_:)

  /// A `--state` folder that is not already private (a permission for group or others, or an
  /// extended ACL entry) is a usage error before any transport is made, and the folder is left
  /// as it was: its mode, its ACL and its (empty) contents. A regression of the phase's
  /// review: such a folder used to be accepted, then tightened to 0700 and stripped of its ACL
  /// by the save.
  @Test func nonPrivateStateFolderIsRefusedAndLeftAsItIs() async throws {
    let base = try Support.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    for mode: mode_t in [0o755, 0o750, 0o705, 0o770, 0o701] {
      let name = "open-\(String(mode, radix: 8))"
      let folder = base.appending(path: name, directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      #expect(chmod(folder.path(percentEncoded: false), mode) == 0)
      try await Self.expectRefused(folder)
      #expect(try LaunchTestSupport.permissions(of: folder) == mode)
    } // End of loop over open modes
    let withACL = base.appending(path: "acl", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: withACL, withIntermediateDirectories: false)
    #expect(chmod(withACL.path(percentEncoded: false), 0o700) == 0)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: withACL)
    #expect(try LaunchTestSupport.aclEntryCount(of: withACL) == 1)
    try await Self.expectRefused(withACL)
    #expect(try LaunchTestSupport.aclEntryCount(of: withACL) == 1)
    #expect(try LaunchTestSupport.permissions(of: withACL) == 0o700)
  } // End of func nonPrivateStateFolderIsRefusedAndLeftAsItIs()

  /// The state folder rule.
  @Test func stateFolderRule() throws {
    let folder = try Support.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(UpdateProbe.stateDirectoryProblem(folder.path(percentEncoded: false)) == nil)
    #expect(UpdateProbe.stateDirectoryProblem("/tmp") != nil)
    #expect(UpdateProbe.stateDirectoryProblem("/") != nil)
    #expect(UpdateProbe.stateDirectoryProblem("private/tmp") != nil)
    #expect(UpdateProbe.stateDirectoryProblem("/private/./tmp") != nil)
  }
}
