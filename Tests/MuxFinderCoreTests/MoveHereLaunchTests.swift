import Foundation
import Testing

@testable import MuxFinderCore

/// Move here on the launch side (PLAN.md D21): the request's `detachOtherClients` field (absent
/// for a normal attach, so older request files still attach normally), the local tmux argv and
/// the remote D3 string with and without `-d`, the helper choosing between them from the
/// request alone, and the test-mode argv digest recording the attach child.
@Suite("Move here: launch request, argv and helper")
struct MoveHereLaunchTests {
  /// A request for `$3` on the fixture server that moves the session here.
  static func moveHereRequest(
    host: LaunchHost = .local,
    tmuxPathOverride: String? = nil
  ) -> LaunchRequest {
    var request = LaunchTestSupport.request(host: host, tmuxPathOverride: tmuxPathOverride)
    request.detachOtherClients = true
    return request
  }

  // MARK: - Request file

  /// A normal request is written without the field (byte for byte what earlier builds wrote)
  /// and reads back as a normal attach; a file that has the field reads as written; `false` is
  /// a normal attach too; anything but a Boolean makes the file unreadable.
  @Test func requestDecodesWithAndWithoutTheField() throws {
    let normal = LaunchTestSupport.request()
    let data = try LaunchCoding.encoder().encode(normal)
    let text = String(decoding: data, as: UTF8.self)
    #expect(!text.contains("detachOtherClients"))
    let decoded = try LaunchCoding.decoder().decode(LaunchRequest.self, from: data)
    #expect(decoded == normal)
    #expect(decoded.detachOtherClients == nil && !decoded.detachesOtherClients)
    #expect(decoded.isWellFormed)

    let moving = try LaunchCoding.encoder().encode(Self.moveHereRequest())
    #expect(String(decoding: moving, as: UTF8.self).contains(#""detachOtherClients":true"#))
    let movedBack = try LaunchCoding.decoder().decode(LaunchRequest.self, from: moving)
    #expect(movedBack.detachesOtherClients && movedBack.isWellFormed)

    /// The normal request's JSON with `"detachOtherClients":<value>` added.
    func withField(_ value: String) -> Data {
      Data(
        text.replacingOccurrences(
          of: #""expectedServerPID""#, with: #""detachOtherClients":\#(value),"expectedServerPID""#
        ).utf8)
    }
    let explicitFalse = try LaunchCoding.decoder().decode(
      LaunchRequest.self, from: withField("false"))
    #expect(explicitFalse.detachOtherClients == false && !explicitFalse.detachesOtherClients)
    #expect(
      try LaunchCoding.decoder().decode(LaunchRequest.self, from: withField("true"))
        .detachesOtherClients)
    for bad in [#""yes""#, "1", "[]"] {
      #expect(throws: DecodingError.self) {
        try LaunchCoding.decoder().decode(LaunchRequest.self, from: withField(bad))
      }
    }
    #expect(
      try LaunchCoding.decoder().decode(LaunchRequest.self, from: withField("null")) == normal)
  } // End of func requestDecodesWithAndWithoutTheField()

  /// Through the real store: a move-here request survives the write and the take; an older file
  /// without the field is taken as a normal attach.
  @Test func storeKeepsTheChoice() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let moving = Self.moveHereRequest()
    try store.writeRequest(moving)
    #expect(try store.takeRequest(moving.id).detachesOtherClients)
    let normal = LaunchTestSupport.request()
    try store.writeRequest(normal)
    let taken = try store.takeRequest(normal.id)
    #expect(taken.detachOtherClients == nil && !taken.detachesOtherClients)
  } // End of func storeKeepsTheChoice()

  // MARK: - Argv

  /// The local attach child: `-d` only for a move here, right before `-t`; a normal request
  /// (and one with `false`) never gets it.
  @Test func localArgvHasDashDOnlyForMoveHere() {
    let normal = LaunchTestSupport.request()
    #expect(
      LaunchGuard.attachArguments(for: normal) == ["-u", "-CC", "attach-session", "-t", "$3"])
    #expect(!LaunchGuard.attachArguments(for: normal).contains("-d"))
    var explicitFalse = normal
    explicitFalse.detachOtherClients = false
    #expect(
      LaunchGuard.attachArguments(for: explicitFalse) == LaunchGuard.attachArguments(for: normal))
    #expect(
      LaunchGuard.attachArguments(for: Self.moveHereRequest())
        == ["-u", "-CC", "attach-session", "-d", "-t", "$3"])
  } // End of func localArgvHasDashDOnlyForMoveHere()

  /// The remote D3 string: the static `script` for a normal attach, the static
  /// `moveHereScript` for a move here. The two scripts differ only in their last step (`-d`),
  /// and the five quoted check values are the same, so no runtime value selects anything on
  /// the remote side.
  @Test func remoteCommandUsesTheMoveHereScriptOnlyWhenAsked() throws {
    let host = LaunchHost.ssh(destination: "fixture-remote")
    let normal = LaunchTestSupport.request(host: host)
    let moving = Self.moveHereRequest(host: host)
    let values = ["", "$3", "4242", "1792599999", "1792600001"]
    #expect(
      RemoteLaunch.command(for: normal)
        == ShellQuoting.remoteCommand(script: RemoteLaunch.script, args: values))
    #expect(
      RemoteLaunch.command(for: moving)
        == ShellQuoting.remoteCommand(script: RemoteLaunch.moveHereScript, args: values))
    #expect(!RemoteLaunch.command(for: normal).contains("attach-session -d"))
    #expect(RemoteLaunch.command(for: moving).contains(#"attach-session -d -t "$id""#))
    #expect(
      RemoteLaunch.moveHereScript.source.hasSuffix(
        #"exec "$t" -u -CC attach-session -d -t "$id""# + "\n"))
    #expect(
      RemoteLaunch.moveHereScript.source
        == RemoteLaunch.script.source.replacingOccurrences(
          of: RemoteLaunch.attachTail.source, with: RemoteLaunch.moveHereTail.source))
    #expect(RemoteLaunch.moveHereScript != RemoteLaunch.script)
    let arguments = try #require(RemoteLaunch.sshArguments(for: moving))
    #expect(
      arguments == [
        "-t", "-o", "ConnectTimeout=10", "--", "fixture-remote", RemoteLaunch.command(for: moving),
      ])
  } // End of func remoteCommandUsesTheMoveHereScriptOnlyWhenAsked()

  /// Both D3 strings through `/bin/sh` against the fake tmux: a normal attach runs
  /// `attach-session -t $3`, a move here `attach-session -d -t $3` (the fake marks it), each
  /// after the same guard check.
  @Test func remoteScriptsRunTheRightAttach() async throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let host = LaunchHost.ssh(destination: "fixture-remote")
    /// Runs `request`'s D3 string through `/bin/sh` with a matching identity.
    func run(_ request: LaunchRequest) async throws -> ProcessResult {
      try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", RemoteLaunch.command(for: request)],
          environment: [
            "PATH": ProcessEnvironment.systemSearchPath,
            "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
            "MUXFINDER_FAKE_IDENTITY": LaunchTestSupport.identity(of: request),
          ], timeout: .seconds(10)))
    }
    let normal = try await run(LaunchTestSupport.request(host: host, tmuxPathOverride: tmux))
    #expect(
      normal.termination == .exited(0), "\(String(decoding: normal.standardError, as: UTF8.self))")
    #expect(TestSupport.fileExists("attach", in: root))
    #expect(!TestSupport.fileExists("detach-others", in: root))
    let moving = try await run(Self.moveHereRequest(host: host, tmuxPathOverride: tmux))
    #expect(
      moving.termination == .exited(0), "\(String(decoding: moving.standardError, as: UTF8.self))")
    #expect(TestSupport.fileExists("detach-others", in: root))
    let attached = try String(contentsOf: root.appending(path: "attach"), encoding: .utf8)
    #expect(attached.hasPrefix("$3 "))
  } // End of func remoteScriptsRunTheRightAttach()

  // MARK: - Helper

  /// The helper (fake child runner, test mode) spawns `-d` only for a move-here request and
  /// rewrites its argv digest with the attach child: its exact argv and whether it detaches.
  @Test(arguments: [false, true])
  func helperSpawnsDashDOnlyWhenAsked(moving: Bool) async throws {
    let fixture = try LaunchHelperTests.fixture(environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var request = LaunchTestSupport.request(tmuxPathOverride: fixture.tmuxPath)
    if moving { request.detachOtherClients = true }
    let (status, _) = try await LaunchHelperTests.attach(fixture, request: request)
    #expect(status == 0)
    let call = try #require(fixture.runner.calls.first)
    let expected = ["-u", "-CC", "attach-session"] + (moving ? ["-d"] : []) + ["-t", "$3"]
    #expect(call.executable == fixture.tmuxPath)
    #expect(call.arguments == expected)
    let digest = try #require(try fixture.store.takeArgvDigests().first)
    #expect(digest.launchID == request.id)
    #expect(
      digest.attachChild
        == LaunchArgvDigest.AttachChild(
          executable: fixture.tmuxPath, arguments: expected, detachesOtherClients: moving))
    #expect(digest.attachChild?.argumentCount == expected.count + 1)
  } // End of func helperSpawnsDashDOnlyWhenAsked(moving:)

  /// A remote move here runs ssh with the move-here D3 string; the digest says it detaches.
  @Test func helperRunsTheMoveHereScriptOverSSH() async throws {
    let fixture = try LaunchHelperTests.fixture(environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.moveHereRequest(host: .ssh(destination: "fixture-remote"))
    let (status, _) = try await LaunchHelperTests.attach(fixture, request: request)
    #expect(status == 0)
    #expect(fixture.runner.checks.isEmpty)
    let call = try #require(fixture.runner.calls.first)
    #expect(call.executable == RemoteLaunch.sshPath)
    let command = ShellQuoting.remoteCommand(
      script: RemoteLaunch.moveHereScript, args: ["", "$3", "4242", "1792599999", "1792600001"])
    #expect(call.arguments == RemoteLaunch.sshOptions + ["--", "fixture-remote", command])
    let child = try #require(try fixture.store.takeArgvDigests().first?.attachChild)
    #expect(child.detachesOtherClients)
    #expect(
      child
        == LaunchArgvDigest.AttachChild(
          executable: RemoteLaunch.sshPath, arguments: call.arguments, detachesOtherClients: true))
  } // End of func helperRunsTheMoveHereScriptOverSSH()

  /// A launch that ends before its attach child (the guard refusing a move here) leaves the
  /// digest without one, and nothing ran with `-d`; outside test mode no digest is written.
  @Test func noAttachChildWithoutAnAttach() async throws {
    let refused = try LaunchHelperTests.fixture(
      check: .exits(LaunchExitStatus.sessionGone),
      environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: refused.root) }
    let (status, _) = try await LaunchHelperTests.attach(refused, request: Self.moveHereRequest())
    #expect(status == LaunchExitStatus.sessionGone)
    #expect(refused.runner.calls.isEmpty)
    let digest = try #require(try refused.store.takeArgvDigests().first)
    #expect(digest.attachChild == nil)

    let plain = try LaunchHelperTests.fixture()
    defer { try? FileManager.default.removeItem(at: plain.root) }
    _ = try await LaunchHelperTests.attach(plain, request: Self.moveHereRequest())
    #expect(plain.runner.calls.first?.arguments.contains("-d") == true)
    #expect(try plain.store.takeArgvDigests().isEmpty)
  } // End of func noAttachChildWithoutAnAttach()

  /// A digest written without an attach child (as earlier builds wrote them) still reads.
  @Test func digestWithoutAttachChildStillReads() throws {
    let digest = LaunchArgvDigest(
      argv: [Array("muxfinder-launch".utf8)], helperPID: 7,
      recordedAt: LaunchTestSupport.requestTime)
    let data = try LaunchCoding.encoder().encode(digest)
    #expect(!String(decoding: data, as: UTF8.self).contains("attachChild"))
    let read = try LaunchCoding.decoder().decode(LaunchArgvDigest.self, from: data)
    #expect(read == digest && read.attachChild == nil)
  } // End of func digestWithoutAttachChildStillReads()

  /// The built `muxfinder-launch` against the fake tmux: a move-here request makes it attach
  /// with `-d` (the fake marks it) and its digest records it; a normal request does neither.
  @Test(.enabled(if: LaunchHelperBinaryTests.helperURL != nil), .timeLimit(.minutes(1)))
  func binaryAttachesWithDashDOnlyForMoveHere() async throws {
    for moving in [false, true] {
      let (store, root) = try LaunchTestSupport.makeStore(now: Date())
      defer { try? FileManager.default.removeItem(at: root) }
      let tmux = try LaunchTestSupport.installFakeTmux(in: root)
      var request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
      if moving { request.detachOtherClients = true }
      try store.writeRequest(request)
      let result = try await LaunchHelperBinaryTests.runHelper(
        ["attach", request.id.rawValue],
        environment: LaunchHelperBinaryTests.environment(
          launchDirectory: store.directory,
          [
            "MUXFINDER_FAKE_IDENTITY": LaunchTestSupport.identity(of: request),
            "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
            LaunchHelper.testModeVariable: "1",
          ]),
        standardInput: .data(Data("hello\n".utf8)))
      #expect(
        result.termination == .exited(0),
        "\(LaunchHelperBinaryTests.text(result.standardError))")
      #expect(TestSupport.fileExists("attach", in: root))
      #expect(TestSupport.fileExists("detach-others", in: root) == moving)
      let child = try #require(try store.takeArgvDigests().first?.attachChild)
      #expect(child.detachesOtherClients == moving)
      #expect(
        child
          == LaunchArgvDigest.AttachChild(
            executable: tmux,
            arguments: ["-u", "-CC", "attach-session"] + (moving ? ["-d"] : []) + ["-t", "$3"],
            detachesOtherClients: moving))
      #expect(try store.takeResult(request.id)?.succeeded == true)
    } // End of loop over a normal attach and a move here
  } // End of func binaryAttachesWithDashDOnlyForMoveHere()
}
