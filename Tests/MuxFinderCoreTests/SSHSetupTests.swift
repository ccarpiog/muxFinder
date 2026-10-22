import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// "Set up SSH in iTerm2…" (PLAN.md D24) on the launch side: the request kind in the request
/// file (old attach files read exactly as before), the store refusing a request of the other
/// kind, the ssh argv (`/usr/bin/ssh`, `--`, the destination last) and its refusals, the
/// helper's `ssh-setup` mode with its hold, and `SSHSetupLauncher` opening the launch tab
/// through fakes. No test runs ssh, opens a tab or contacts iTerm2.
@Suite("SSH setup: request kind, argv, helper mode and launcher")
struct SSHSetupTests {
  /// The configured host id of the requests here.
  static let hostID = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!

  /// An ssh setup request for `destination`, written at the launch tests' request time.
  static func setupRequest(
    destination: String = "saturno.example",
    id: LaunchToken = LaunchToken()
  ) -> SSHSetupRequest {
    SSHSetupRequest(
      id: id, createdAt: LaunchTestSupport.requestTime, hostID: hostID, destination: destination)
  }

  /// Writes `data` as `id`'s request file the way the store writes one (0600, no ACL), without
  /// any check, so a test can hand the helper a file the app would never write.
  static func writeRawRequest(_ data: Data, id: LaunchToken, in store: LaunchStore) throws {
    try store.withDirectory(create: true) { (directory) throws(LaunchStoreError) in
      try LaunchStore.writeFile(
        data, named: LaunchStore.requestFileName(for: id), exclusive: true, in: directory)
    }
  }

  /// The top-level keys of a JSON object.
  static func keys(of data: Data) throws -> [String] {
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    return object.keys.sorted()
  }

  // MARK: - Request kind

  /// An attach request is still written without a `kind` field (byte for byte what earlier
  /// builds wrote) and reads back as an attach; an ssh setup request carries
  /// `"kind":"sshSetup"` and only its own fields, and survives the round trip.
  @Test func encodesTheKindOnlyForSSHSetup() throws {
    let attach = LaunchTestSupport.request(host: .ssh(destination: "saturno.example"))
    let attachData = try LaunchCoding.encoder().encode(attach)
    #expect(try !Self.keys(of: attachData).contains("kind"))
    #expect(try LaunchRequestFile.decode(attachData) == .attach(attach))

    let setup = Self.setupRequest()
    let setupData = try LaunchCoding.encoder().encode(setup)
    #expect(
      try Self.keys(of: setupData)
        == ["createdAt", "destination", "formatVersion", "hostID", "id", "kind"])
    #expect(String(decoding: setupData, as: UTF8.self).contains(#""kind":"sshSetup""#))
    let decoded = try LaunchRequestFile.decode(setupData)
    #expect(decoded == .sshSetup(setup))
    #expect(decoded.kind == .sshSetup && decoded.id == setup.id && decoded.isWellFormed)
    #expect(LaunchRequestKind.attach.helperMode == "attach")
    #expect(LaunchRequestKind.sshSetup.helperMode == "ssh-setup")
  } // End of func encodesTheKindOnlyForSSHSetup()

  /// A request file as earlier builds wrote it (no `kind`, the host's own nested `kind`) is
  /// taken as the same attach request, locally and over ssh; an explicit `"kind":"attach"` is
  /// an attach too; an unknown kind, or an ssh setup kind with an attach body, is unreadable.
  @Test func oldAttachFilesStillDecode() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let created = LaunchTestSupport.requestTime.formatted(LaunchCoding.dateStyle)
    for host in [#"{"kind":"local"}"#, #"{"destination":"saturno.example","kind":"ssh"}"#] {
      let id = LaunchToken()
      let old =
        #"{"createdAt":"\#(created)","expectedServerPID":4242,"#
        + #""expectedServerStartTime":1792599999,"expectedSessionCreated":1792600001,"#
        + #""formatVersion":1,"host":\#(host),"hostID":"\#(Self.hostID.uuidString)","#
        + #""id":"\#(id.rawValue)","sessionID":"$3"}"#
      try Self.writeRawRequest(Data(old.utf8), id: id, in: store)
      let taken = try store.takeRequest(id)
      let expected = LaunchTestSupport.request(
        id: id,
        host: host.contains("ssh") ? .ssh(destination: "saturno.example") : .local)
      #expect(taken == expected)
      let explicit = old.replacingOccurrences(
        of: #"{"createdAt""#, with: #"{"kind":"attach","createdAt""#)
      try Self.writeRawRequest(Data(explicit.utf8), id: id, in: store)
      #expect(try store.takeRequest(id) == expected)
      for kind in [#""restart""#, #""sshSetup""#, "3"] {
        let other = old.replacingOccurrences(
          of: #"{"createdAt""#, with: #"{"kind":\#(kind),"createdAt""#)
        try Self.writeRawRequest(Data(other.utf8), id: id, in: store)
        #expect(throws: LaunchStoreError.fileMalformed) { try store.takeRequestFile(id) }
      }
    } // End of loop over the old hosts
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
  } // End of func oldAttachFilesStillDecode()

  /// Each typed take accepts only its own kind: the other kind is refused as
  /// `requestKindMismatch` (the helper's 72), and the file is gone either way.
  @Test func storeRefusesTheOtherKind() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let setup = Self.setupRequest()
    try store.writeRequest(setup)
    #expect(throws: LaunchStoreError.requestKindMismatch(expected: .attach, found: .sshSetup)) {
      try store.takeRequest(setup.id)
    }
    #expect(throws: LaunchStoreError.fileMissing) { try store.takeSSHSetupRequest(setup.id) }
    let attach = LaunchTestSupport.request()
    try store.writeRequest(attach)
    #expect(throws: LaunchStoreError.requestKindMismatch(expected: .sshSetup, found: .attach)) {
      try store.takeSSHSetupRequest(attach.id)
    }
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
    let mismatch = LaunchStoreError.requestKindMismatch(expected: .attach, found: .sshSetup)
    #expect(mismatch.launchFailure == .requestUnreadable)
    #expect(mismatch.launchFailure.exitStatus == LaunchExitStatus.requestUnreadable)
    let again = Self.setupRequest()
    try store.writeRequest(again)
    #expect(try store.takeSSHSetupRequest(again.id) == again)
  } // End of func storeRefusesTheOtherKind()

  /// A destination that ssh could read as an option, or that is empty or holds whitespace or
  /// control characters, makes an ssh setup request not well formed: the store refuses to write
  /// it (creating nothing) and to take one written by anything else.
  @Test(arguments: ["", "-oProxyCommand=touch /tmp/x", "-", "--", "a b", "host\nname", "\t"])
  func refusesUnsafeDestinations(destination: String) throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let request = Self.setupRequest(destination: destination)
    #expect(!request.isWellFormed)
    #expect(throws: LaunchStoreError.fileMalformed) { try store.writeRequest(request) }
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
    try Self.writeRawRequest(try LaunchStore.encode(request), id: request.id, in: store)
    #expect(throws: LaunchStoreError.fileMalformed) { try store.takeSSHSetupRequest(request.id) }
    #expect(SSHSetup.sshArguments(destination: destination) == nil)
  } // End of func refusesUnsafeDestinations(destination:)

  // MARK: - Argv and outcome

  /// The argv is `/usr/bin/ssh -- <destination>`: no option, `--` right before the destination,
  /// the destination last and unchanged; the tab's command line names the `ssh-setup` mode.
  @Test func buildsThePlainSSHArgv() throws {
    #expect(SSHSetup.sshPath == "/usr/bin/ssh")
    for destination in ["saturno.example", "admin@saturno.example", "saturno-m4", "ünï.example"] {
      let arguments = try #require(SSHSetup.sshArguments(destination: destination))
      #expect(arguments == ["--", destination])
      #expect(arguments.last == destination)
      #expect(!arguments.dropLast().contains { $0.hasPrefix("-") && $0 != "--" })
    }
    #expect(
      SSHSetup.sshArguments(for: Self.setupRequest(destination: "sirio.example"))
        == ["--", "sirio.example"])
    let path = try LaunchHelperPath(validating: "/Applications/muxFinder.app/Contents/MacOS/x")
    let id = LaunchToken()
    #expect(path.commandLine(for: id, kind: .sshSetup) == "\(path.path) ssh-setup \(id.rawValue)")
    #expect(path.attachCommandLine(for: id) == "\(path.path) attach \(id.rawValue)")
  } // End of func buildsThePlainSSHArgv()

  /// Any exit but 255 means ssh reached the host (the remote shell's own status); 255 is ssh's
  /// own failure, classified from its standard error; a signal is `childSignaled`.
  @Test func mapsHowSSHEnded() {
    #expect(SSHSetup.failure(for: .exited(0), sshStandardError: Data()) == nil)
    #expect(SSHSetup.failure(for: .exited(1), sshStandardError: Data()) == nil)
    #expect(SSHSetup.failure(for: .exited(130), sshStandardError: Data()) == nil)
    let denied = Data("admin@saturno.example: Permission denied (publickey).\r\n".utf8)
    #expect(
      SSHSetup.failure(for: .exited(255), sshStandardError: denied) == .sshFailed(.authFailed))
    let unknownKey = Data("Host key verification failed.\r\n".utf8)
    #expect(
      SSHSetup.failure(for: .exited(255), sshStandardError: unknownKey)
        == .sshFailed(.hostKeyProblem))
    #expect(SSHSetup.failure(for: .exited(255), sshStandardError: Data()) == .sshFailed(.other))
    #expect(
      SSHSetup.failure(for: .signaled(SIGKILL), sshStandardError: Data()) == .childSignaled(9))
    #expect(LaunchFailure.sshFailed(.authFailed).sshSetupExplanation.hasPrefix("ssh could not log"))
    #expect(!LaunchFailure.requestMissing.sshSetupExplanation.contains("attach"))
    #expect(LaunchFailure.spawnFailed(errno: ENOENT).sshSetupExplanation.contains("start ssh"))
  } // End of func mapsHowSSHEnded()

  // MARK: - Helper mode

  /// Writes `request` and runs `ssh-setup <id>` in `fixture`. Returns the exit status.
  static func runSetup(
    _ fixture: LaunchHelperTests.Fixture,
    request: SSHSetupRequest = setupRequest()
  ) async throws -> Int32 {
    try fixture.store.writeRequest(request)
    return await fixture.helper.run(
      arguments: [LaunchHelperTests.helperPath, "ssh-setup", request.id.rawValue])
  }

  /// `ssh-setup <id>` takes its request and runs exactly `/usr/bin/ssh -- <destination>` on the
  /// tab's terminal, with no check, the helper's cleaned environment and ssh's standard error
  /// relayed; ssh's own exit status, whatever the remote shell returned, is a success, written
  /// before the hold that keeps the tab until the helper is 10 s old.
  @Test(arguments: [0 as Int32, 1])
  func runsPlainSSH(exitStatus: Int32) async throws {
    let fixture = try LaunchHelperTests.fixture(
      .termination(.exited(exitStatus), forwarded: []), interactive: true,
      environment: ["PATH": "/usr/bin:/bin", "TMUX": "/tmp/x,1,0", "LANG": "en_US.UTF-8"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.setupRequest(destination: "admin@saturno.example")
    #expect(try await Self.runSetup(fixture, request: request) == 0)
    #expect(fixture.runner.checks.isEmpty)
    let call = try #require(fixture.runner.calls.first)
    #expect(fixture.runner.calls.count == 1)
    #expect(call.executable == "/usr/bin/ssh")
    #expect(call.arguments == ["--", "admin@saturno.example"])
    #expect(call.relaysStandardError)
    #expect(call.environment["TMUX"] == nil && call.environment["LANG"] == "en_US.UTF-8")
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.succeeded && result.childTermination == .exited(exitStatus))
    #expect(throws: LaunchStoreError.fileMissing) { try fixture.store.takeRequestFile(request.id) }
    #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
    #expect(!fixture.terminal.text.contains("muxFinder:"))
    let details = await fixture.log.events().map(\.detail)
    #expect(details.contains("ssh ended normally."))
    #expect(!details.contains { $0.contains("saturno") })
  } // End of func runsPlainSSH(exitStatus:)

  /// ssh failing fast (255) is classified from its relayed standard error, explained in the
  /// tab with the ssh setup wording, and on a visible tab waits for Return and then holds the
  /// rest of the 10 s, so the tab never ends inside iTerm2's 3 s window.
  @Test func explainsSSHFailuresAndHolds() async throws {
    let fixture = try LaunchHelperTests.fixture(
      .termination(
        .exited(255), forwarded: [],
        standardError: "admin@saturno.example: Permission denied (publickey).\r\n"),
      interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.setupRequest()
    #expect(try await Self.runSetup(fixture, request: request) == 255)
    #expect(try fixture.store.takeResult(request.id)?.failure == .sshFailed(.authFailed))
    #expect(
      fixture.terminal.text.contains(LaunchFailure.sshFailed(.authFailed).sshSetupExplanation))
    #expect(fixture.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
  } // End of func explainsSSHFailuresAndHolds()

  /// Every way an ssh setup ends keeps the tab until the minimum lifetime on a visible
  /// terminal: a success, an ssh failure, a spawn failure, a missing or expired request, a
  /// request of the other kind; only a closed tab (SIGHUP passed on) ends at once.
  @Test func holdsOnEveryExitPath() async throws {
    let cases: [(FakeLaunchChildRunner.Behavior, TimeInterval, Bool, Int32)] = [
      (.termination(.exited(0), forwarded: []), 1, false, 0),
      (.termination(.exited(255), forwarded: []), 1, false, 255),
      (.error(.spawnFailed(errno: ENOENT)), 1, false, LaunchExitStatus.spawnFailed),
      (.termination(.exited(0), forwarded: []), 121, false, LaunchExitStatus.requestExpired),
      (.termination(.exited(0), forwarded: []), 1, true, LaunchExitStatus.requestUnreadable),
    ]
    for (behavior, clockOffset, attachRequest, status) in cases {
      let fixture = try LaunchHelperTests.fixture(
        behavior, interactive: true, clockOffset: clockOffset)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let id = LaunchToken()
      if attachRequest {
        try fixture.store.writeRequest(LaunchTestSupport.request(id: id))
      } else {
        try fixture.store.writeRequest(Self.setupRequest(id: id))
      }
      let exit = await fixture.helper.run(
        arguments: [LaunchHelperTests.helperPath, "ssh-setup", id.rawValue])
      #expect(exit == status, "\(status)")
      #expect(fixture.terminal.holds == [.seconds(10)], "\(status)")
      #expect(try fixture.store.takeResult(id)?.exitStatus == status, "\(status)")
    } // End of loop over the exit paths
    let missing = try LaunchHelperTests.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: missing.root) }
    let id = LaunchToken()
    #expect(
      await missing.helper.run(arguments: [LaunchHelperTests.helperPath, "ssh-setup", id.rawValue])
        == LaunchExitStatus.requestMissing)
    #expect(missing.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
    #expect(missing.terminal.text.contains(LaunchFailure.requestMissing.sshSetupExplanation))
    let closed = try LaunchHelperTests.fixture(
      .termination(.exited(255), forwarded: [SIGHUP]), interactive: true)
    defer { try? FileManager.default.removeItem(at: closed.root) }
    #expect(try await Self.runSetup(closed) == 255)
    #expect(closed.terminal.pauses.isEmpty)
  } // End of func holdsOnEveryExitPath()

  /// A request whose kind does not match the helper mode is refused as unreadable (72) with
  /// nothing run and the request consumed: an ssh setup request given to `attach`, and an
  /// attach request given to `ssh-setup`.
  @Test func refusesAKindThatDoesNotMatchTheMode() async throws {
    let attachMode = try LaunchHelperTests.fixture()
    defer { try? FileManager.default.removeItem(at: attachMode.root) }
    let setup = Self.setupRequest()
    try attachMode.store.writeRequest(setup)
    #expect(
      await attachMode.helper.run(
        arguments: [LaunchHelperTests.helperPath, "attach", setup.id.rawValue])
        == LaunchExitStatus.requestUnreadable)
    #expect(attachMode.runner.checks.isEmpty && attachMode.runner.calls.isEmpty)
    let refused = try #require(try attachMode.store.takeResult(setup.id))
    #expect(refused.failure == .requestUnreadable && refused.childStartedAt == nil)
    #expect(try LaunchTestSupport.names(in: attachMode.store.directory).isEmpty)

    let setupMode = try LaunchHelperTests.fixture()
    defer { try? FileManager.default.removeItem(at: setupMode.root) }
    let attach = LaunchTestSupport.request()
    try setupMode.store.writeRequest(attach)
    #expect(
      await setupMode.helper.run(
        arguments: [LaunchHelperTests.helperPath, "ssh-setup", attach.id.rawValue])
        == LaunchExitStatus.requestUnreadable)
    #expect(setupMode.runner.checks.isEmpty && setupMode.runner.calls.isEmpty)
    #expect(try setupMode.store.takeResult(attach.id)?.failure == .requestUnreadable)
    #expect(try LaunchTestSupport.names(in: setupMode.store.directory).isEmpty)
    let details = await setupMode.log.events().map(\.detail)
    #expect(details.contains { $0.contains("for the helper's attach mode, not ssh-setup") })
  } // End of func refusesAKindThatDoesNotMatchTheMode()

  /// A request file holding a destination ssh could read as an option (written by anything
  /// but the app) is refused (72) before any process starts.
  @Test func refusesAnOptionLikeDestinationBeforeAnyProcess() async throws {
    let fixture = try LaunchHelperTests.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.setupRequest(destination: "-oProxyCommand=touch /tmp/x")
    try Self.writeRawRequest(try LaunchStore.encode(request), id: request.id, in: fixture.store)
    #expect(
      await fixture.helper.run(
        arguments: [LaunchHelperTests.helperPath, "ssh-setup", request.id.rawValue])
        == LaunchExitStatus.requestUnreadable)
    #expect(fixture.runner.checks.isEmpty && fixture.runner.calls.isEmpty)
    #expect(fixture.terminal.holds == [.seconds(10)])
  } // End of func refusesAnOptionLikeDestinationBeforeAnyProcess()

  /// `ssh-setup` takes exactly one canonical launch id; anything else is a usage error that
  /// runs and consumes nothing. In test mode the argv digest records the ssh child (never
  /// detaching anything).
  @Test func parsesTheModeAndDigestsTheSSHChild() async throws {
    let fixture = try LaunchHelperTests.fixture(environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = Self.setupRequest(id: LaunchToken("0f8fad5b-d9cb-469f-a165-70867728950e")!)
    try fixture.store.writeRequest(pending)
    for arguments in [
      ["ssh-setup"], ["ssh-setup", "0F8FAD5B-D9CB-469F-A165-70867728950E"],
      ["ssh-setup", pending.id.rawValue, "saturno.example"], ["ssh_setup", pending.id.rawValue],
    ] {
      #expect(
        await fixture.helper.run(arguments: [LaunchHelperTests.helperPath] + arguments)
          == LaunchExitStatus.usage)
    }
    #expect(fixture.runner.calls.isEmpty)
    _ = try fixture.store.takeArgvDigests()
    #expect(
      await fixture.helper.run(
        arguments: [LaunchHelperTests.helperPath, "ssh-setup", pending.id.rawValue]) == 0)
    let digest = try #require(try fixture.store.takeArgvDigests().last)
    let child = try #require(digest.attachChild)
    #expect(
      child
        == LaunchArgvDigest.AttachChild(
          executable: "/usr/bin/ssh", arguments: ["--", "saturno.example"],
          detachesOtherClients: false))
    #expect(LaunchHelper.usage.contains("ssh-setup"))
  } // End of func parsesTheModeAndDigestsTheSSHChild()

  // MARK: - Launcher

  /// Everything a launcher test needs.
  struct LauncherFixture {
    /// The launcher.
    let launcher: SSHSetupLauncher
    /// Its iTerm2 fake.
    let iTerm2: FakeITerm2Integration
    /// Its real store, in a temporary directory.
    let store: LaunchStore
    /// The helper path it gives iTerm2.
    let helper: LaunchHelperPath
    /// The diagnostics log.
    let log: DiagnosticsLog
    /// The temporary root to remove.
    let root: URL
  }

  /// A launcher over a fake iTerm2 (scripted by `script`), a real store in a temporary
  /// directory and a fixed helper path (`helper`: `nil` stands for a missing helper).
  static func launcher(
    script: FakeITerm2Integration.Script = openingScript(),
    helperAvailable: Bool = true
  ) throws -> LauncherFixture {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    let iTerm2 = FakeITerm2Integration(script: script)
    let helper = try LaunchHelperPath(
      validating: "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")
    let log = DiagnosticsLog(writesToSystemLog: false)
    let launcher = SSHSetupLauncher(
      iTerm2: iTerm2, store: store,
      locateHelper: { helperAvailable ? .success(helper) : .failure(.notFound) },
      diagnostics: log)
    return LauncherFixture(
      launcher: launcher, iTerm2: iTerm2, store: store, helper: helper, log: log, root: root)
  } // End of static func launcher(script:helperAvailable:)

  /// A script whose `CreateTab` answers a tab with a session id.
  static func openingScript() -> FakeITerm2Integration.Script {
    var script = FakeITerm2Integration.Script()
    script.createTab = .init(.success(ITerm2API.CreateTabResponse(sessionID: "launch-tab")))
    return script
  }

  /// An SSH host for the launcher.
  static func host(_ destination: String, profile: String? = "Work") -> HostConfig {
    HostConfig(
      id: hostID, displayName: "Saturno", mode: .ssh, sshDestination: destination,
      iTermProfileName: profile, isEnabled: false)
  }

  /// The launcher opens the launch tab the attach's way (D15): an ssh setup request with the
  /// destination, `ensureRunning()`, then one `CreateTab` in a new window with the host's
  /// profile, the command `<helper> ssh-setup <id>` and Close Sessions On End; it reports the
  /// tab's session id and logs no destination.
  @Test func opensTheLaunchTab() async throws {
    let fixture = try Self.launcher()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let result = await fixture.launcher.openSSHSetup(for: Self.host("admin@saturno.example"))
    #expect(result == .opened(sessionID: "launch-tab"))
    let names = try LaunchTestSupport.names(in: fixture.store.directory)
    let name = try #require(names.first)
    #expect(names.count == 1 && name.hasSuffix(".request.json"))
    let id = try #require(LaunchToken(String(name.prefix(36))))
    let tab = LaunchTab.request(
      commandLine: fixture.helper.commandLine(for: id, kind: .sshSetup), profileName: "Work")
    #expect(tab.windowID == nil)
    #expect(
      tab.customProfileProperties
        == ITerm2API.ProfileProperty.customCommand(
          "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch ssh-setup \(id.rawValue)")
        + [ITerm2API.ProfileProperty.closeSessionsOnEnd(true)])
    #expect(await fixture.iTerm2.calls == [.ensureRunning, .createTab(tab)])
    let taken = try fixture.store.takeSSHSetupRequest(id)
    #expect(taken.destination == "admin@saturno.example" && taken.hostID == Self.hostID)
    let events = await fixture.log.events()
    #expect(events.map(\.detail) == ["ssh setup tab opened"])
    #expect(events.first?.hostID == Self.hostID.uuidString)
  } // End of func opensTheLaunchTab()

  /// Refused before anything is written, started or contacted: This Mac, a destination ssh
  /// could read as an option (or empty, or with whitespace), a missing helper, a cancelled
  /// caller.
  @Test func refusesBeforeAnything() async throws {
    let refusals: [(HostConfig, Bool, SSHSetupFailure)] = [
      (HostConfig(displayName: "Neptuno", mode: .local), true, .notAnSSHHost),
      (Self.host("-oProxyCommand=x"), true, .invalidDestination(.sshDestinationStartsWithHyphen)),
      (Self.host(""), true, .invalidDestination(.sshDestinationEmpty)),
      (Self.host("a b"), true, .invalidDestination(.sshDestinationContainsWhitespace)),
      (Self.host("saturno.example"), false, .helperUnavailable(.notFound)),
    ]
    for (host, helperAvailable, failure) in refusals {
      let fixture = try Self.launcher(helperAvailable: helperAvailable)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      #expect(await fixture.launcher.openSSHSetup(for: host) == .failed(failure))
      #expect(await fixture.iTerm2.calls.isEmpty)
      #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
    }
    let fixture = try Self.launcher()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let launcher = fixture.launcher
    let cancelled = await Task {
      withUnsafeCurrentTask { $0?.cancel() }
      return await launcher.openSSHSetup(for: Self.host("saturno.example"))
    }.value
    #expect(cancelled == .failed(.cancelled))
    #expect(await fixture.iTerm2.calls.isEmpty)
    #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
    #expect(SSHSetupFailure.cancelled.message == "Opening the tab was cancelled.")
  } // End of func refusesBeforeAnything()

  /// A failure after the request was written withdraws it, so a tab that starts late runs
  /// nothing: iTerm2 not starting, `CreateTab` refused, a tab without a session id.
  @Test func withdrawsTheRequestOnFailure() async throws {
    var notStarting = Self.openingScript()
    notStarting.ensureRunning = .init(.failure(.apiDisabled))
    var refused = Self.openingScript()
    refused.createTab = .init(.failure(.createTabFailed(.invalidProfileName)))
    var noSession = Self.openingScript()
    noSession.createTab = .init(.success(ITerm2API.CreateTabResponse()))
    let cases: [(FakeITerm2Integration.Script, SSHSetupFailure, Int)] = [
      (notStarting, .iTerm2(.apiDisabled), 1),
      (refused, .iTerm2(.createTabFailed(.invalidProfileName)), 2),
      (noSession, .iTerm2(.protocolError("the new tab has no session id")), 2),
    ]
    for (script, failure, callCount) in cases {
      let fixture = try Self.launcher(script: script)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let result = await fixture.launcher.openSSHSetup(for: Self.host("saturno.example"))
      #expect(result == .failed(failure))
      #expect(await fixture.iTerm2.calls.count == callCount)
      #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
      let events = await fixture.log.events()
      #expect(events.map(\.outcome) == [.failure])
      #expect(!events.contains { $0.detail.contains("saturno") })
    } // End of loop over the failing scripts
    #expect(SSHSetupFailure.iTerm2(.apiDisabled).kind == "iTerm2.apiDisabled")
  } // End of func withdrawsTheRequestOnFailure()
}

/// `muxfinder-launch ssh-setup` built and run in a pseudo-terminal (`PseudoTerminalHelper`),
/// so it is interactive. Its request is an attach request (the wrong kind), so it refuses it
/// (72) without starting ssh or any other child, then waits for Return and holds its tab until
/// its minimum lifetime (3 s here), exactly as an attach does.
@Suite("SSH setup: helper binary (terminal)")
struct SSHSetupTerminalTests {
  /// Return pressed at once still leaves the tab open until the helper is 3 s old; the result
  /// was written, nothing was started, and the tab showed the ssh setup wording.
  @Test(.enabled(if: LaunchHelperBinaryTests.helperURL != nil), .timeLimit(.minutes(1)))
  func holdsAfterARefusedRequest() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let request = LaunchTestSupport.request(createdAt: Date())
    try store.writeRequest(request)
    var environment = LaunchHelperBinaryTests.environment(launchDirectory: store.directory)
    environment[StandardLaunchTerminal.noWaitVariable] = nil
    environment[LaunchHelper.minimumLifetimeVariable] = "3000"
    let terminal = try PseudoTerminalHelper(
      helper: try #require(LaunchHelperBinaryTests.helperURL),
      arguments: ["ssh-setup", request.id.rawValue],
      environment: environment)
    defer { terminal.stop() }
    try await LaunchHelperTerminalTests.waitForPrompt(terminal)
    _ = try await LaunchHelperTerminalTests.endWait(terminal) { terminal.pressReturn() }
    let exited = await PseudoTerminalHelper.repeating(
      {}, until: { terminal.hasExited }, within: .seconds(20))
    let exitedAt = try #require(exited, "the helper did not exit: \(terminal.text)")
    #expect(terminal.reap() == .exited(LaunchExitStatus.requestUnreadable), "\(terminal.text)")
    #expect(exitedAt - terminal.startedAt >= .seconds(3))
    #expect(terminal.text.contains(LaunchFailure.requestUnreadable.sshSetupExplanation))
    let result = try #require(try store.takeResult(request.id))
    #expect(result.failure == .requestUnreadable && result.childStartedAt == nil)
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
  } // End of func holdsAfterARefusedRequest()
}
