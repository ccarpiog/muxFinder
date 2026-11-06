import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `muxfinder-launch attach-plain <launch id>` in this process (PLAN.md D14, D38; Phase
/// I-12b2), with a fake child runner and terminal, fixed early-report facts and a temporary
/// launch directory: the mode words, the request's `terminal` field and its refusals in both
/// directions, the plain argv locally and remotely (move here included), what plain mode writes
/// to the terminal and what it leaves out, the minimum-lifetime rule, the early report and test
/// mode. Nothing real is started.
@Suite("Launch helper plain mode")
struct LaunchHelperPlainTests {
  /// Everything one test needs.
  struct Fixture {
    /// The helper under test.
    let helper: LaunchHelper
    /// Its store.
    let store: LaunchStore
    /// The fake child runner.
    let base: FakeLaunchChildRunner
    /// The runner the helper uses, recording each call's standard input.
    let runner: StandardInputRecordingRunner
    /// The fake terminal.
    let terminal: FakeLaunchTerminal
    /// The diagnostics log.
    let log: DiagnosticsLog
    /// The temporary root to remove.
    let root: URL
    /// A real executable (the fake tmux), which a passing check prints by default.
    let tmuxPath: String
  }

  /// Builds a helper over a fresh store (its clock `requestTime + 1 s`, standing still, so
  /// every hold is the whole minimum lifetime) with fixed facts. The check passes and prints
  /// `Fixture.tmuxPath` unless `check` says otherwise.
  static func fixture(
    _ behavior: FakeLaunchChildRunner.Behavior = .termination(.exited(0), forwarded: []),
    check: FakeLaunchChildRunner.CheckBehavior? = nil,
    interactive: Bool = true,
    environment: [String: String] = ["LANG": "en_US.UTF-8"],
    facts: PlainLaunchFacts = PlainLaunchTestSupport.facts,
    afterSpawn: (@Sendable (LaunchStore) -> Void)? = nil
  ) throws -> Fixture {
    let now = LaunchTestSupport.requestTime.addingTimeInterval(1)
    let (store, root) = try LaunchTestSupport.makeStore(now: now)
    let tmuxPath = try LaunchTestSupport.installFakeTmux(in: root)
    let base = FakeLaunchChildRunner(behavior, check: check ?? .passes(tmuxPath: tmuxPath))
    var hook: (@Sendable () -> Void)?
    if let afterSpawn { hook = { afterSpawn(store) } }
    let runner = StandardInputRecordingRunner(base, afterSpawn: hook)
    let terminal = FakeLaunchTerminal(isInteractive: interactive)
    let log = DiagnosticsLog(writesToSystemLog: false)
    let helper = LaunchHelper(
      store: store, environment: environment, childRunner: runner, terminal: terminal, log: log,
      processID: 4321, now: { now }, checkTimeout: .seconds(7), plainFacts: facts)
    return Fixture(
      helper: helper, store: store, base: base, runner: runner, terminal: terminal, log: log,
      root: root, tmuxPath: tmuxPath)
  } // End of func fixture(_:check:interactive:environment:facts:afterSpawn:)

  /// Writes `request` and runs the helper in `mode` for its id.
  static func run(
    _ fixture: Fixture,
    _ request: LaunchRequest,
    mode: LaunchHelperMode = .attachPlain
  ) async throws -> Int32 {
    try fixture.store.writeRequest(request)
    return await fixture.helper.run(
      arguments: [LaunchHelperTests.helperPath, mode.word, request.id.rawValue])
  }

  /// Whether `text` holds an OSC 1337 sequence or a status report request.
  static func holdsTabRestoreBytes(_ text: String) -> Bool {
    text.contains("\u{1B}]1337") || text.contains("\u{1B}[5n") || text.contains("Disinter")
  }

  // MARK: - Mode words

  /// The five mode words are named constants, the existing ones unchanged; the plain words are
  /// D2's characters, so every form of a terminal's launch command takes them as `{mode}`; the
  /// parser accepts exactly `<mode> <canonical id>`, and the usage line names both.
  @Test func modeWords() throws {
    #expect(LaunchHelperMode.attach.word == LaunchRequestKind.attach.helperMode)
    #expect(LaunchHelperMode.sshSetup.word == LaunchRequestKind.sshSetup.helperMode)
    #expect(LaunchHelperMode.profile.word == ProfileLaunch.helperMode)
    #expect(LaunchHelperMode.attachPlain.word == "attach-plain")
    #expect(LaunchHelperMode.profilePlain.word == "profile-plain")
    #expect(ProfileLaunch.plainHelperMode == "profile-plain")
    let id = LaunchToken()
    let argv = { (words: [String]) in words.map { Array($0.utf8) } }
    #expect(LaunchHelper.parse(argv(["h", "attach-plain", id.rawValue])) == .attachPlain(id))
    #expect(LaunchHelper.parse(argv(["h", "profile-plain", id.rawValue])) == .profilePlain(id))
    #expect(LaunchHelper.parse(argv(["h", "attach-plain", id.rawValue.uppercased()])) == nil)
    #expect(LaunchHelper.parse(argv(["h", "attach-plain"])) == nil)
    #expect(LaunchHelper.parse(argv(["h", "Attach-Plain", id.rawValue])) == nil)
    #expect(LaunchHelper.parse(argv(["h", "attach", id.rawValue])) == .attach(id))
    #expect(
      LaunchHelper.usage.contains("attach-plain") && LaunchHelper.usage.contains("profile-plain"))
    for mode in [LaunchHelperMode.attachPlain, .profilePlain] {
      let command = TerminalLaunchCommand(
        helperPath: LaunchHelperTests.helperPath, mode: mode.word, token: id.rawValue)
      #expect(
        try command.appleScriptArguments(form: .words)
          == ["", LaunchHelperTests.helperPath, mode.word, id.rawValue])
      #expect(try command.shellText().contains("'\(mode.word)'"))
      let exec = TerminalOpenMethod.exec(
        executable: "Contents/MacOS/wezterm",
        arguments: [
          .literal("start"), .placeholder(.helper), .placeholder(.mode), .placeholder(.token),
        ])
      let built = try #require(
        try command.execArgv(exec, inApp: URL(fileURLWithPath: "/Applications/W.app")))
      #expect(built.arguments == ["start", LaunchHelperTests.helperPath, mode.word, id.rawValue])
    } // End of loop over the plain mode words
    let path = try LaunchHelperPath(validating: LaunchHelperTests.helperPath)
    let host = UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!
    #expect(
      path.plainProfileCommandLine(forHostID: host)
        == "\(LaunchHelperTests.helperPath) profile-plain 0f8fad5b-d9cb-469f-a165-70867728950e")
  } // End of func modeWords()

  /// Plain mode is chosen by the mode word alone: `attach` with a terminal-looking environment
  /// still runs its control-mode attach, unchanged.
  @Test func neverGuessesPlainModeFromTheEnvironment() async throws {
    let fixture = try Self.fixture(
      environment: ["TERM_PROGRAM": "Apple_Terminal", "TERM": "xterm-ghostty"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let status = try await Self.run(fixture, LaunchTestSupport.request(), mode: .attach)
    #expect(status == 0)
    #expect(fixture.base.calls.first?.arguments == ["-u", "-CC", "attach-session", "-t", "$3"])
    #expect(fixture.runner.standardInputs == [.inherited])
  }

  // MARK: - The request's terminal

  /// `terminal` round-trips (`iterm2` by default, a definition id for a plain request, with
  /// `keepsMinimumLifetime`); a file without it reads as `iterm2`, equal to a request made in
  /// code; a value that is neither is a decoding error; `keepsMinimumLifetime` makes an iTerm2
  /// request ill-formed.
  @Test func requestTerminalField() throws {
    let iterm2 = LaunchTestSupport.request()
    #expect(iterm2.terminal == .iterm2)
    let iterm2Data = try LaunchCoding.encoder().encode(iterm2)
    #expect(String(decoding: iterm2Data, as: UTF8.self).contains(#""terminal":"iterm2""#))
    #expect(!String(decoding: iterm2Data, as: UTF8.self).contains("keepsMinimumLifetime"))
    #expect(try LaunchCoding.decoder().decode(LaunchRequest.self, from: iterm2Data) == iterm2)

    let plain = PlainLaunchTestSupport.request(keepsMinimumLifetime: true)
    let plainData = try LaunchCoding.encoder().encode(plain)
    let plainText = String(decoding: plainData, as: UTF8.self)
    #expect(plainText.contains(#""terminal":"terminal""#))
    #expect(plainText.contains(#""keepsMinimumLifetime":true"#))
    #expect(try LaunchCoding.decoder().decode(LaunchRequest.self, from: plainData) == plain)
    #expect(plain.isWellFormed && plain.holdsMinimumLifetimeInPlainMode)
    #expect(!PlainLaunchTestSupport.request().holdsMinimumLifetimeInPlainMode)

    let old = try PlainLaunchTestSupport.jsonWithoutTerminal(iterm2)
    #expect(!old.contains("terminal"))
    #expect(try LaunchCoding.decoder().decode(LaunchRequest.self, from: Data(old.utf8)) == iterm2)

    for bad in [
      #""ITerm2""#, #""""#, #""a b""#, #""Terminal""#, #""a/b""#, "5", "null x",
      "\"\(String(repeating: "a", count: 33))\"",
    ] {
      let text = plainText.replacingOccurrences(
        of: #""terminal":"terminal""#, with: #""terminal":\#(bad)"#)
      #expect(throws: (any Error).self, "\(bad)") {
        try LaunchCoding.decoder().decode(LaunchRequest.self, from: Data(text.utf8))
      }
    } // End of loop over the unusable terminal values
    #expect(LaunchTerminalApp("iterm2") == .iterm2)
    #expect(LaunchTerminalApp("ghostty") == .plain(definitionID: "ghostty"))
    #expect(LaunchTerminalApp("Ghostty") == nil)

    var keeping = iterm2
    keeping.keepsMinimumLifetime = false
    #expect(!keeping.isWellFormed)
    var badID = plain
    badID.terminal = .plain(definitionID: "Not valid")
    #expect(!badID.isWellFormed)
    var reserved = plain
    reserved.terminal = .plain(definitionID: "iterm2")
    #expect(!reserved.isWellFormed)
  } // End of func requestTerminalField()

  /// The store's typed takes refuse the other terminal (`requestTerminalMismatch`, the
  /// helper's 72), the file gone either way: `takeRequest` a plain request, `takePlainRequest`
  /// an iTerm2 one (explicit or without the field); an iTerm2 request carrying
  /// `keepsMinimumLifetime` is unreadable for both, and an ssh setup request is the other kind.
  @Test func storeRefusesTheOtherTerminal() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = PlainLaunchTestSupport.request()
    try store.writeRequest(plain)
    let toAttach = LaunchStoreError.requestTerminalMismatch(
      helperMode: .attach, found: .plain(definitionID: "terminal"))
    #expect(throws: toAttach) { try store.takeRequest(plain.id) }
    #expect(toAttach.launchFailure == .requestUnreadable)
    #expect(LaunchFailure.requestUnreadable.exitStatus == 72)
    #expect(throws: LaunchStoreError.fileMissing) { try store.takePlainRequest(plain.id) }

    let iterm2 = LaunchTestSupport.request()
    try store.writeRequest(iterm2)
    let toPlain = LaunchStoreError.requestTerminalMismatch(helperMode: .attachPlain, found: .iterm2)
    #expect(throws: toPlain) { try store.takePlainRequest(iterm2.id) }
    #expect(throws: LaunchStoreError.fileMissing) { try store.takeRequest(iterm2.id) }

    try PlainLaunchTestSupport.writeRawRequest(
      try PlainLaunchTestSupport.jsonWithoutTerminal(iterm2), id: iterm2.id, in: store)
    #expect(throws: toPlain) { try store.takePlainRequest(iterm2.id) }

    var keeping = iterm2
    keeping.keepsMinimumLifetime = true
    try store.writeRequest(keeping)
    #expect(throws: LaunchStoreError.fileMalformed) { try store.takeRequest(keeping.id) }
    try store.writeRequest(keeping)
    #expect(throws: LaunchStoreError.fileMalformed) { try store.takePlainRequest(keeping.id) }

    let setup = SSHSetupRequest(
      createdAt: LaunchTestSupport.requestTime, hostID: UUID(), destination: "saturno.example")
    try store.writeRequest(setup)
    #expect(throws: LaunchStoreError.requestKindMismatch(expected: .attach, found: .sshSetup)) {
      try store.takePlainRequest(setup.id)
    }
    let kept = PlainLaunchTestSupport.request(keepsMinimumLifetime: true)
    try store.writeRequest(kept)
    #expect(try store.takePlainRequest(kept.id) == kept)
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
  } // End of func storeRefusesTheOtherTerminal()

  /// `attach` refuses a plain request with 72 and runs nothing (no check, no attach, no
  /// report), explaining, waiting and holding as it always does after a refused request.
  @Test func attachRefusesAPlainRequest() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = PlainLaunchTestSupport.request()
    let status = try await Self.run(fixture, request, mode: .attach)
    #expect(status == LaunchExitStatus.requestUnreadable)
    #expect(fixture.base.checks.isEmpty && fixture.base.calls.isEmpty)
    #expect(try fixture.store.peekReport(request.id) == nil)
    #expect(try fixture.store.takeResult(request.id)?.failure == .requestUnreadable)
    #expect(fixture.terminal.text.contains(LaunchFailure.requestUnreadable.explanation))
    #expect(fixture.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
    #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
  } // End of func attachRefusesAPlainRequest()

  /// `attach-plain` refuses an iTerm2 request, with `"terminal":"iterm2"` or without the field,
  /// with 72 and runs nothing; it explains and waits for Return, never holds (no request asked
  /// for the minimum lifetime) and writes no tab restore bytes.
  @Test(arguments: [true, false])
  func attachPlainRefusesAnITerm2Request(explicit: Bool) async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = LaunchTestSupport.request()
    if explicit {
      try fixture.store.writeRequest(request)
    } else {
      try PlainLaunchTestSupport.writeRawRequest(
        try PlainLaunchTestSupport.jsonWithoutTerminal(request), id: request.id, in: fixture.store)
    }
    let status = await fixture.helper.run(
      arguments: [LaunchHelperTests.helperPath, "attach-plain", request.id.rawValue])
    #expect(status == LaunchExitStatus.requestUnreadable)
    #expect(fixture.base.checks.isEmpty && fixture.base.calls.isEmpty)
    #expect(try fixture.store.takeResult(request.id)?.failure == .requestUnreadable)
    #expect(fixture.terminal.pauses == [.waitForReturn])
    #expect(fixture.terminal.statusReports.isEmpty)
    #expect(!Self.holdsTabRestoreBytes(fixture.terminal.text))
    #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
  } // End of func attachPlainRefusesAnITerm2Request(explicit:)

  // MARK: - The plain attach

  /// On This Mac: the same check as `attach` (`/bin/sh` with the guard, the request's values,
  /// the deadline and the cleaned environment), then the printed tmux with exactly
  /// `PlainLaunch.localAttachArguments(session:detachingOthers:)` over the request's four
  /// values (`-d` only for a move here), never `-CC`, on the terminal opened read-write.
  @Test(arguments: [false, true])
  func localArgvIsTheBuilders(moving: Bool) async throws {
    let fixture = try Self.fixture(
      environment: ["TMUX": "/tmp/x,1,0", "TMUX_PANE": "%1", "LANG": "en_US.UTF-8"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = PlainLaunchTestSupport.request(moving: moving)
    let status = try await Self.run(fixture, request)
    #expect(status == 0)
    let check = try #require(fixture.base.checks.first)
    #expect(fixture.base.checks.count == 1)
    #expect(check.executableURL.path(percentEncoded: false) == "/bin/sh")
    #expect(check.arguments == LaunchGuard.arguments(for: request))
    #expect(check.timeout == .seconds(7))
    let call = try #require(fixture.base.calls.first)
    #expect(fixture.base.calls.count == 1)
    #expect(call.executable == fixture.tmuxPath)
    let expected = try #require(
      PlainLaunch.localAttachArguments(
        session: PlainLaunchTestSupport.fourFields, detachingOthers: moving))
    #expect(call.arguments == expected)
    #expect(call.arguments == PlainLaunch.localAttachArguments(for: request))
    #expect(!call.arguments.contains("-CC"))
    #expect(call.arguments[6] == (moving ? "attach-session -d -t '$3'" : "attach-session -t '$3'"))
    #expect(!call.relaysStandardError)
    #expect(call.environment == check.environment)
    #expect(call.environment["TMUX"] == nil && call.environment["MUXFINDER_LAUNCHED"] == "1")
    #expect(fixture.runner.standardInputs == [.terminalReadWrite])
  } // End of func localArgvIsTheBuilders(moving:)

  /// On an SSH host: no local check, one `/usr/bin/ssh` child with D17's options, `--`, the
  /// destination and `PlainLaunch.remoteCommand` over the guard's five values and the launch
  /// id as the token (`remoteMoveHereScript` for a move here), its standard error relayed, on
  /// the terminal opened read-write.
  @Test(arguments: [false, true])
  func remoteArgvIsTheBuilders(moving: Bool) async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = PlainLaunchTestSupport.request(
      host: .ssh(destination: "saturno.example"), moving: moving)
    let status = try await Self.run(fixture, request)
    #expect(status == 0)
    #expect(fixture.base.checks.isEmpty)
    let call = try #require(fixture.base.calls.first)
    #expect(call.executable == "/usr/bin/ssh")
    let command = PlainLaunch.remoteCommand(
      checkArguments: ["", "$3", "4242", "1792599999", "1792600001"], token: request.id,
      detachingOthers: moving)
    #expect(call.arguments == ["-t", "-o", "ConnectTimeout=10", "--", "saturno.example", command])
    #expect(call.arguments == PlainLaunch.sshArguments(for: request))
    let script = moving ? PlainLaunch.remoteMoveHereScript : PlainLaunch.remoteScript
    #expect(command.contains(ShellQuoting.posixSingleQuote(script.source)))
    #expect(command.hasSuffix(" '\(request.id.rawValue)'"))
    #expect(call.relaysStandardError)
    #expect(fixture.runner.standardInputs == [.terminalReadWrite])
  } // End of func remoteArgvIsTheBuilders(moving:)

  /// Exit statuses map to the result kinds as `attach`'s do: 65 a changed session (the bound
  /// attach's refusal), 68 a bad token, ssh's 255 classified, a signal, tmux's 1, a spawn
  /// failure; the result is the one `attach` writes for the same end.
  @Test func exitStatusesMapLikeAttach() async throws {
    let local = LaunchHost.local
    let remote = LaunchHost.ssh(destination: "saturno.example")
    let cases: [(FakeLaunchChildRunner.Behavior, LaunchHost, LaunchFailure?)] = [
      (.termination(.exited(65), forwarded: []), local, .sessionChanged),
      (.termination(.exited(68), forwarded: []), remote, .guardUsage),
      (.termination(.exited(64), forwarded: []), remote, .sessionGone),
      (
        .termination(
          .exited(255), forwarded: [],
          standardError: "ssh: connect to host saturno.example port 22: Connection refused\n"),
        remote, .sshFailed(.unreachable)
      ),
      (.termination(.signaled(9), forwarded: []), local, .childSignaled(9)),
      (.termination(.exited(1), forwarded: []), local, .childExited(1)),
      (.error(.spawnFailed(errno: ENOENT)), local, .spawnFailed(errno: ENOENT)),
      (.termination(.exited(0), forwarded: []), remote, nil),
    ]
    for (behavior, host, failure) in cases {
      var results: [LaunchResult] = []
      for mode in [LaunchHelperMode.attach, .attachPlain] {
        let fixture = try Self.fixture(behavior, interactive: false)
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let id = LaunchToken(uuid: UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!)
        let request =
          mode == .attach
          ? LaunchTestSupport.request(id: id, host: host)
          : PlainLaunchTestSupport.request(id: id, host: host)
        let status = try await Self.run(fixture, request, mode: mode)
        #expect(status == (failure?.exitStatus ?? 0), "\(mode) \(String(describing: failure))")
        results.append(try #require(try fixture.store.takeResult(id)))
      } // End of loop over the two modes
      #expect(results[1].failure == failure)
      #expect(results[0] == results[1], "\(String(describing: failure))")
    } // End of loop over the cases
  } // End of func exitStatusesMapLikeAttach()

  /// A failed check ends the launch before any attach: no child, no report.
  @Test func checkFailureRunsNoAttach() async throws {
    let fixture = try Self.fixture(check: .exits(64), interactive: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = PlainLaunchTestSupport.request()
    #expect(try await Self.run(fixture, request) == LaunchExitStatus.sessionGone)
    #expect(fixture.base.calls.isEmpty)
    #expect(try fixture.store.peekReport(request.id) == nil)
    #expect(try fixture.store.takeResult(request.id)?.failure == .sessionGone)
  }

  // MARK: - What plain mode leaves out and keeps

  /// After a detach and after a failure: no status report request and no OSC 1337 byte (no
  /// `Disinter`), whatever the request's test switch says; a failure keeps the explanation and
  /// the wait for Return; the result is written either way.
  @Test(arguments: [0, 1] as [Int32])
  func writesNoTabRestore(exitStatus: Int32) async throws {
    let fixture = try Self.fixture(.termination(.exited(exitStatus), forwarded: []))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var request = PlainLaunchTestSupport.request()
    request.testSuppressDisinter = true
    let status = try await Self.run(fixture, request)
    #expect(status == exitStatus)
    #expect(fixture.terminal.statusReports.isEmpty)
    #expect(!Self.holdsTabRestoreBytes(fixture.terminal.text))
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.childTermination == .exited(exitStatus))
    if exitStatus == 0 {
      #expect(fixture.terminal.text.isEmpty)
      #expect(fixture.terminal.pauses.isEmpty)
    } else {
      #expect(
        fixture.terminal.text
          == "\nmuxFinder: \(LaunchFailure.childExited(1).explanation)\n\nPress Return to close.\n"
      )
      #expect(fixture.terminal.pauses == [.waitForReturn])
    }
  } // End of func writesNoTabRestore(exitStatus:)

  /// `attach` is unchanged by the field: an iTerm2 request written with `"terminal":"iterm2"`
  /// and one without it give the same children, terminal events (its tab restores included)
  /// and result.
  @Test func attachIsUnchangedByTheTerminalField() async throws {
    var runs: [([FakeLaunchChildRunner.Call], [FakeLaunchTerminal.Event], LaunchResult)] = []
    for explicit in [true, false] {
      let fixture = try Self.fixture(.termination(.exited(1), forwarded: []))
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let id = LaunchToken(uuid: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!)
      let request = LaunchTestSupport.request(id: id)
      if explicit {
        try fixture.store.writeRequest(request)
      } else {
        try PlainLaunchTestSupport.writeRawRequest(
          try PlainLaunchTestSupport.jsonWithoutTerminal(request), id: id, in: fixture.store)
      }
      let status = await fixture.helper.run(
        arguments: [LaunchHelperTests.helperPath, "attach", id.rawValue])
      #expect(status == 1)
      #expect(fixture.base.calls.first?.arguments == ["-u", "-CC", "attach-session", "-t", "$3"])
      #expect(fixture.runner.standardInputs == [.inherited])
      #expect(try fixture.store.peekReport(id) == nil)
      let calls = fixture.base.calls.map { call -> FakeLaunchChildRunner.Call in
        var stripped = call
        stripped.executable = "tmux"
        return stripped
      }
      runs.append((calls, fixture.terminal.events, try #require(try fixture.store.takeResult(id))))
    } // End of loop over the two request files
    #expect(runs[0].0 == runs[1].0)
    #expect(runs[0].1 == runs[1].1)
    #expect(runs[0].2 == runs[1].2)
    #expect(runs[0].1.contains { if case .statusReport = $0 { return true } else { return false } })
  } // End of func attachIsUnchangedByTheTerminalField()

  /// The minimum lifetime holds only when the request's `keepsMinimumLifetime` is `true`, after
  /// a detach and after a failure alike.
  @Test(arguments: [(nil, 0), (false, 0), (true, 0), (nil, 1), (true, 1)] as [(Bool?, Int32)])
  func minimumLifetimeOnlyWhenKept(keeps: Bool?, exitStatus: Int32) async throws {
    let fixture = try Self.fixture(.termination(.exited(exitStatus), forwarded: []))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = PlainLaunchTestSupport.request(keepsMinimumLifetime: keeps)
    #expect(try await Self.run(fixture, request) == exitStatus)
    #expect(fixture.terminal.holds == (keeps == true ? [.seconds(10)] : []))
    #expect(fixture.terminal.waits == (exitStatus == 0 ? 0 : 1))
  }

  // MARK: - The early report

  /// Right after the attach child is spawned, before the helper waits on it, the report is
  /// there: the schema, the launch id, the helper's pid, the terminal path, the child's pid and
  /// start time; 0600, written through a temporary file (none left); peeking leaves it, and
  /// taking the result removes it.
  @Test func writesTheEarlyReport() async throws {
    let seen = LockedBox<PlainLaunchReport?>(nil)
    let request = PlainLaunchTestSupport.request()
    let id = request.id
    let fixture = try Self.fixture(afterSpawn: { store in seen.set(try? store.peekReport(id)) })
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(try await Self.run(fixture, request) == 0)
    let expected = PlainLaunchReport(
      id: request.id, helperPID: 4321, terminalPath: PlainLaunchTestSupport.terminalPath,
      attachChildPID: FakeLaunchChildRunner.childProcessID,
      attachChildStartTime: PlainLaunchTestSupport.startTime)
    #expect(seen.value == expected)
    #expect(expected.schemaVersion == 1)
    let reportURL = fixture.store.directory.appending(
      path: "\(request.id.rawValue).report.json")
    #expect(try LaunchTestSupport.permissions(of: reportURL) == 0o600)
    #expect(try LaunchTestSupport.status(of: reportURL).st_mode & S_IFMT == S_IFREG)
    #expect(
      try LaunchTestSupport.names(in: fixture.store.directory)
        == ["\(request.id.rawValue).report.json", "\(request.id.rawValue).result.json"])
    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
    #expect(
      Set(object.keys) == [
        "schemaVersion", "id", "helperPID", "terminalPath", "attachChildPID",
        "attachChildStartTime",
      ])
    #expect(try fixture.store.peekReport(request.id) == expected)
    #expect(try fixture.store.peekReport(request.id) == expected)
    #expect(try fixture.store.takeResult(request.id)?.succeeded == true)
    #expect(try fixture.store.peekReport(request.id) == nil)
    #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
    let events = await fixture.log.events()
    #expect(events.contains { $0.detail == "Early report written (terminal known: true)." })
    #expect(!events.contains { $0.detail.contains("/dev/") })
  } // End of func writesTheEarlyReport()

  /// Standard input that is not a terminal makes a report with no terminal path ("cannot
  /// confirm here"); an unreadable start time writes no report (logged) and the attach goes on.
  @Test func reportWithoutATerminalOrAStartTime() async throws {
    let noTerminal = try Self.fixture(
      facts: PlainLaunchFacts(
        terminalPath: { nil }, startTime: { _ in PlainLaunchTestSupport.startTime }))
    defer { try? FileManager.default.removeItem(at: noTerminal.root) }
    let first = PlainLaunchTestSupport.request()
    #expect(try await Self.run(noTerminal, first) == 0)
    let report = try #require(try noTerminal.store.peekReport(first.id))
    #expect(report.terminalPath == nil && report.attachChildPID == 777)
    let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
    defer { close(null) }
    #expect(PlainLaunchFacts.terminalPath(of: null) == nil)

    let noStart = try Self.fixture(
      facts: PlainLaunchFacts(terminalPath: { "/dev/ttys042" }, startTime: { _ in nil }))
    defer { try? FileManager.default.removeItem(at: noStart.root) }
    let second = PlainLaunchTestSupport.request()
    #expect(try await Self.run(noStart, second) == 0)
    #expect(try noStart.store.peekReport(second.id) == nil)
    #expect(try noStart.store.takeResult(second.id)?.succeeded == true)
    let events = await noStart.log.events()
    #expect(events.contains { $0.detail.contains("start time is unreadable") })
  } // End of func reportWithoutATerminalOrAStartTime()

  /// `attach` writes no report.
  @Test func attachWritesNoReport() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = LaunchTestSupport.request()
    #expect(try await Self.run(fixture, request, mode: .attach) == 0)
    #expect(
      try LaunchTestSupport.names(in: fixture.store.directory)
        == ["\(request.id.rawValue).result.json"])
  }

  // MARK: - Test mode

  /// In test mode the argv digest records the plain attach child (its argv, whether it moves
  /// the session here) and its process id; `testSuppressDisinter` is accepted and changes
  /// nothing; `testLaunchDelaySeconds` runs the check-stage sleep first.
  @Test(arguments: [false, true])
  func testModeDigest(moving: Bool) async throws {
    let fixture = try Self.fixture(environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    var request = PlainLaunchTestSupport.request(moving: moving)
    request.testSuppressDisinter = true
    request.testLaunchDelaySeconds = 3
    #expect(try await Self.run(fixture, request) == 0)
    let digest = try #require(try fixture.store.takeArgvDigests().first)
    #expect(digest.launchID == request.id && digest.argumentCount == 3)
    let arguments = try #require(PlainLaunch.localAttachArguments(for: request))
    #expect(
      digest.attachChild
        == LaunchArgvDigest.AttachChild(
          executable: fixture.tmuxPath, arguments: arguments, detachesOtherClients: moving))
    #expect(digest.attachChildProcessID == FakeLaunchChildRunner.childProcessID)
    #expect(digest.tabRestores == nil)
    #expect(fixture.terminal.statusReports.isEmpty)
    #expect(fixture.base.checks.count == 2)
    #expect(fixture.base.checks.first?.executableURL.path(percentEncoded: false) == "/bin/sleep")
    #expect(fixture.base.checks.first?.arguments == ["3"])
    #expect(fixture.terminal.text.contains("muxFinder test mode: waiting 3 s before starting."))
  } // End of func testModeDigest(moving:)
} // End of struct LaunchHelperPlainTests

/// A value behind a lock, for closures that run on another thread.
final class LockedBox<Value: Sendable>: Sendable {
  /// The value.
  private let state: OSAllocatedUnfairLock<Value>

  /// Starts with `value`.
  init(_ value: Value) {
    state = OSAllocatedUnfairLock(initialState: value)
  }

  /// The current value.
  var value: Value { state.withLock { $0 } }

  /// Replaces the value.
  func set(_ value: Value) { state.withLock { $0 = value } }
}
