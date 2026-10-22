import CryptoKit
import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// Tests for `LaunchHelper` in this process, with a fake child runner and terminal and a
/// temporary launch directory. The real binary is covered by `LaunchHelperBinaryTests`.
@Suite("Launch helper")
struct LaunchHelperTests {
  /// The argv[0] used in these tests.
  static let helperPath = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"

  /// Everything one test needs.
  struct Fixture {
    /// The helper under test.
    let helper: LaunchHelper
    /// Its store.
    let store: LaunchStore
    /// The fake child runner.
    let runner: FakeLaunchChildRunner
    /// The fake terminal.
    let terminal: FakeLaunchTerminal
    /// The diagnostics log.
    let log: DiagnosticsLog
    /// The temporary root to remove.
    let root: URL
    /// A real executable (the fake tmux) under `root/secret-path/`, which a passing check
    /// prints by default.
    let tmuxPath: String
  }

  /// Builds a helper over a fresh store whose clock is `requestTime + clockOffset`. The check
  /// passes and prints `Fixture.tmuxPath` unless `check` says otherwise.
  static func fixture(
    _ behavior: FakeLaunchChildRunner.Behavior = .termination(.exited(0), forwarded: []),
    check: FakeLaunchChildRunner.CheckBehavior? = nil,
    interactive: Bool = false,
    environment: [String: String] = [:],
    clockOffset: TimeInterval = 1
  ) throws -> Fixture {
    let now = LaunchTestSupport.requestTime.addingTimeInterval(clockOffset)
    let (store, root) = try LaunchTestSupport.makeStore(now: now)
    let tools = root.appending(path: "secret-path")
    try FileManager.default.createDirectory(at: tools, withIntermediateDirectories: false)
    let tmuxPath = try LaunchTestSupport.installFakeTmux(in: tools)
    let runner = FakeLaunchChildRunner(behavior, check: check ?? .passes(tmuxPath: tmuxPath))
    let terminal = FakeLaunchTerminal(isInteractive: interactive)
    let log = DiagnosticsLog(writesToSystemLog: false)
    let helper = LaunchHelper(
      store: store,
      environment: environment,
      childRunner: runner,
      terminal: terminal,
      log: log,
      processID: 4321,
      now: { now },
      checkTimeout: .seconds(7)
    )
    return Fixture(
      helper: helper,
      store: store,
      runner: runner,
      terminal: terminal,
      log: log,
      root: root,
      tmuxPath: tmuxPath
    )
  } // End of func fixture(_:check:interactive:environment:clockOffset:)

  /// Writes a request and runs `attach <id>`. Returns the exit status and the request.
  static func attach(
    _ fixture: Fixture,
    request: LaunchRequest = LaunchTestSupport.request()
  ) async throws -> (status: Int32, request: LaunchRequest) {
    try fixture.store.writeRequest(request)
    let status = await fixture.helper.run(arguments: [helperPath, "attach", request.id.rawValue])
    return (status, request)
  }

  /// A detach (tmux exit 0): the request is consumed; the check ran as `/bin/sh` with the
  /// request's values, the helper's deadline and a cleaned environment; the attach ran the
  /// printed tmux directly with `-u -CC attach-session -t <id>` and the same environment; the
  /// result says success, and nothing is printed or waited for (the clock stands still, so the
  /// helper then holds its tab for its whole minimum lifetime).
  @Test func succeeds() async throws {
    let fixture = try Self.fixture(
      interactive: true,
      environment: [
        "PATH": "/usr/bin:/bin", "TMUX": "/tmp/x,1,0", "TMUX_PANE": "%1", "LANG": "en_US.UTF-8",
        "MUXFINDER_LAUNCH_NO_WAIT": "0",
      ]
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = LaunchTestSupport.request(tmuxPathOverride: fixture.tmuxPath)
    let (status, _) = try await Self.attach(fixture, request: request)
    #expect(status == 0)
    let check = try #require(fixture.runner.checks.first)
    #expect(fixture.runner.checks.count == 1)
    #expect(check.executableURL.path(percentEncoded: false) == "/bin/sh")
    #expect(check.arguments == LaunchGuard.arguments(for: request))
    #expect(check.timeout == .seconds(7))
    #expect(check.standardInput == .nullDevice)
    #expect(check.environment["TMUX"] == nil && check.environment["TMUX_PANE"] == nil)
    #expect(check.environment["MUXFINDER_LAUNCH_NO_WAIT"] == nil)
    #expect(check.environment["LANG"] == "en_US.UTF-8")
    #expect(check.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    let call = try #require(fixture.runner.calls.first)
    #expect(fixture.runner.calls.count == 1)
    #expect(call.executable == fixture.tmuxPath)
    #expect(call.arguments == ["-u", "-CC", "attach-session", "-t", "$3"])
    #expect(call.environment == check.environment)
    #expect(throws: LaunchStoreError.fileMissing) { try fixture.store.takeRequest(request.id) }
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.succeeded)
    #expect(result.childTermination == .exited(0))
    #expect(result.helperPID == 4321)
    #expect(result.childStartedAt == LaunchTestSupport.requestTime.addingTimeInterval(1))
    #expect(fixture.terminal.text.isEmpty)
    #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
    let events = await fixture.log.events()
    #expect(events.map(\.outcome) == [.success])
    #expect(events.first?.hostID == request.hostID.uuidString)
    #expect(!events.contains { $0.detail.contains("secret-path") || $0.detail.contains("$3") })
  } // End of func succeeds()

  /// tmux ending right after it attached (an early detach, a killed session) must not end the
  /// tab inside iTerm2's short-lived-session window, which would block iTerm2's API behind a
  /// modal warning: on an interactive terminal the helper holds until it is
  /// `defaultMinimumLifetime` (10 s) old, and only after its result is written, so the
  /// coordinator learns how tmux ended at once.
  @Test func holdsAQuickEndUntilTheMinimumLifetime() async throws {
    let fixture = try Self.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(LaunchHelper.defaultMinimumLifetime == .seconds(10))
    #expect(fixture.helper.minimumLifetime == LaunchHelper.defaultMinimumLifetime)
    let request = LaunchTestSupport.request()
    let resultPath = fixture.store.directory.appending(path: request.id.rawValue + ".result.json")
      .path(percentEncoded: false)
    let resultWrittenBeforeHold = OSAllocatedUnfairLock(initialState: false)
    fixture.terminal.onHold {
      let exists = FileManager.default.fileExists(atPath: resultPath)
      resultWrittenBeforeHold.withLock { $0 = exists }
    }
    let (status, _) = try await Self.attach(fixture, request: request)
    #expect(status == 0)
    #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
    #expect(resultWrittenBeforeHold.withLock { $0 })
    #expect(try fixture.store.takeResult(request.id)?.succeeded == true)
  } // End of func holdsAQuickEndUntilTheMinimumLifetime()

  /// The hold covers only what is left of the minimum lifetime, counted from the start of the
  /// run: nothing once the helper is old enough, and the whole lifetime when the clock went
  /// backwards.
  @Test(arguments: [
    (4.0, [Duration.seconds(6)]), (9.5, [.milliseconds(500)]), (10.0, []), (12.0, []),
    (-5.0, [.seconds(10)]),
  ])
  func holdsOnlyWhatIsLeft(elapsedSeconds: Double, holds: [Duration]) async throws {
    let fixture = try Self.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let start = LaunchTestSupport.requestTime.addingTimeInterval(1)
    let calls = OSAllocatedUnfairLock(initialState: 0)
    var helper = fixture.helper
    helper.now = {
      let call = calls.withLock { count -> Int in
        count += 1
        return count
      }
      return call == 1 ? start : start.addingTimeInterval(elapsedSeconds)
    }
    let request = LaunchTestSupport.request()
    try fixture.store.writeRequest(request)
    let status = await helper.run(arguments: [Self.helperPath, "attach", request.id.rawValue])
    #expect(status == 0)
    #expect(fixture.terminal.holds == holds)
  } // End of func holdsOnlyWhatIsLeft(elapsedSeconds:holds:)

  /// A usage error on an interactive terminal waits for Return, then holds the rest of the
  /// minimum lifetime; `help` (typed in a shell, never run in a launch tab) neither waits nor
  /// holds; a terminal that is not interactive never holds.
  @Test func holdsAUsageErrorButNotHelp() async throws {
    let fixture = try Self.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await fixture.helper.run(arguments: [Self.helperPath, "attach"]) == 2)
    #expect(fixture.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])

    let help = try Self.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: help.root) }
    #expect(await help.helper.run(arguments: [Self.helperPath, "help"]) == 0)
    #expect(help.terminal.pauses.isEmpty)

    let unseen = try Self.fixture(interactive: false)
    defer { try? FileManager.default.removeItem(at: unseen.root) }
    let (status, _) = try await Self.attach(unseen)
    #expect(status == 0)
    #expect(unseen.terminal.pauses.isEmpty)
  } // End of func holdsAUsageErrorButNotHelp()

  /// `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` (a test seam, removed from the children's
  /// environment by its prefix) sets the minimum lifetime only when it is 1 to 7 decimal
  /// digits; anything else keeps the 10 s default.
  @Test func readsTheMinimumLifetimeOverride() {
    let variable = LaunchHelper.minimumLifetimeVariable
    #expect(variable.hasPrefix(LaunchHelper.ownVariablePrefix))
    #expect(LaunchHelper.minimumLifetime(for: [variable: "1500"]) == .milliseconds(1500))
    #expect(LaunchHelper.minimumLifetime(for: [variable: "0"]) == .zero)
    #expect(LaunchHelper.minimumLifetime(for: [variable: "9999999"]) == .milliseconds(9_999_999))
    #expect(LaunchHelper.minimumLifetime(for: [:]) == LaunchHelper.defaultMinimumLifetime)
    for value in ["", "abc", "-1", "+5", "1.5", " 15", "15 ", "10000000", "١٢"] {
      #expect(
        LaunchHelper.minimumLifetime(for: [variable: value]) == .seconds(10), "\(value)")
    }
  } // End of func readsTheMinimumLifetimeOverride()

  /// The wait gate resumes its continuation exactly once: when the end comes after the
  /// continuation is stored, when it comes before (`arm` resumes at once and reports the wait
  /// over), and when several ends race (Return against a signal). A second resume would trap.
  @Test func endsAWaitOnce() async {
    let late = LaunchWaitGate()
    await withCheckedContinuation { continuation in
      #expect(late.arm(continuation))
      late.finish()
      late.finish()
    }
    let early = LaunchWaitGate()
    early.finish()
    await withCheckedContinuation { continuation in
      #expect(!early.arm(continuation))
    }
    early.finish()
    for _ in 0..<200 {
      let gate = LaunchWaitGate()
      await withCheckedContinuation { continuation in
        #expect(gate.arm(continuation))
        DispatchQueue.concurrentPerform(iterations: 4) { _ in gate.finish() }
      }
    }
  } // End of func endsAWaitOnce()

  /// A guard failure ends the launch before any attach: the typed failure and its exit status,
  /// the check's termination in the result, the explanation, and only on an interactive
  /// terminal a wait for Return followed by a hold for the rest of the minimum lifetime (Return
  /// pressed at once must not end the tab young either).
  @Test(arguments: [true, false])
  func explainsGuardFailures(interactive: Bool) async throws {
    let fixture = try Self.fixture(
      check: .exits(LaunchExitStatus.sessionGone),
      interactive: interactive
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (status, request) = try await Self.attach(fixture)
    #expect(status == 64)
    #expect(fixture.runner.calls.isEmpty)
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.failure == .sessionGone)
    #expect(result.exitStatus == 64)
    #expect(result.childTermination == .exited(64))
    #expect(fixture.terminal.text.contains(LaunchFailure.sessionGone.explanation))
    #expect(fixture.terminal.text.contains("Press Return") == interactive)
    #expect(fixture.terminal.pauses == (interactive ? [.waitForReturn, .hold(.seconds(10))] : []))
  } // End of func explainsGuardFailures(interactive:)

  /// The check's stderr (tmux's error line) reaches the tab as printable ASCII, before the
  /// explanation, and never the diagnostics.
  @Test func relaysCheckMessages() async throws {
    let fixture = try Self.fixture(
      check: .exits(67, errors: "tmux: protocol version mismatch\n\u{1B}[31mü")
    )
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (status, request) = try await Self.attach(fixture)
    #expect(status == LaunchExitStatus.tmuxCheckFailed)
    #expect(try fixture.store.takeResult(request.id)?.failure == .tmuxCheckFailed)
    #expect(
      fixture.terminal.text.hasPrefix("tmux: protocol version mismatch\n?[31m??\n\nmuxFinder: "))
    #expect(fixture.terminal.text.contains(LaunchFailure.tmuxCheckFailed.explanation))
    #expect(!(await fixture.log.events()).contains { $0.detail.contains("protocol") })
  } // End of func relaysCheckMessages()

  /// A check that exits 0 without a usable tmux path (missing, or not the override) is check
  /// failed (67), and nothing is attached.
  @Test func refusesAnUnusableTmuxPath() async throws {
    for output in ["/nonexistent/muxfinder-test/tmux\n", "/bin/sh\n"] {
      let fixture = try Self.fixture(check: .exits(0, output: output))
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let request = LaunchTestSupport.request(tmuxPathOverride: fixture.tmuxPath)
      let (status, _) = try await Self.attach(fixture, request: request)
      #expect(status == LaunchExitStatus.tmuxCheckFailed, "\(output)")
      #expect(fixture.runner.calls.isEmpty)
      #expect(try fixture.store.takeResult(request.id)?.failure == .tmuxCheckFailed)
    }
  } // End of func refusesAnUnusableTmuxPath()

  /// A check stopped by its deadline is `checkTimedOut` (75), with the check's termination
  /// recorded and nothing attached.
  @Test func reportsCheckTimeouts() async throws {
    let fixture = try Self.fixture(check: .timesOut)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (status, request) = try await Self.attach(fixture)
    #expect(status == LaunchExitStatus.checkTimedOut)
    #expect(fixture.runner.calls.isEmpty)
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.failure == .checkTimedOut)
    #expect(result.childTermination == .signaled(SIGTERM))
    #expect(fixture.terminal.text.contains(LaunchFailure.checkTimedOut.explanation))
  } // End of func reportsCheckTimeouts()

  /// A signal during the check is `interrupted(n)`, exit 128 + n, with nothing attached; a
  /// SIGHUP (the tab closed) is never waited for nor held, a SIGINT on an interactive terminal
  /// is both.
  @Test(arguments: [(SIGHUP, 0), (SIGINT, 1)])
  func reportsInterruptedChecks(signalNumber: Int32, waits: Int) async throws {
    let fixture = try Self.fixture(check: .interrupted([signalNumber]), interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (status, request) = try await Self.attach(fixture)
    #expect(status == 128 + signalNumber)
    #expect(fixture.runner.calls.isEmpty)
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.failure == .interrupted(signalNumber))
    #expect(result.childTermination == nil)
    #expect(result.childStartedAt != nil)
    #expect(fixture.terminal.text.contains(LaunchFailure.interrupted(signalNumber).explanation))
    #expect(fixture.terminal.waits == waits)
    #expect(fixture.terminal.holds == (waits == 0 ? [] : [.seconds(10)]))
  } // End of func reportsInterruptedChecks(signalNumber:waits:)

  /// A closed tab (SIGHUP passed on) is explained but never waited for nor held; a signal death
  /// exits 128 + n.
  @Test func handlesHangupsAndSignals() async throws {
    let hungUp = try Self.fixture(
      .termination(.exited(1), forwarded: [SIGHUP]),
      interactive: true
    )
    defer { try? FileManager.default.removeItem(at: hungUp.root) }
    let (status, request) = try await Self.attach(hungUp)
    #expect(status == 1)
    #expect(try hungUp.store.takeResult(request.id)?.failure == .childExited(1))
    #expect(hungUp.terminal.pauses.isEmpty)

    let killed = try Self.fixture(.termination(.signaled(SIGKILL), forwarded: []))
    defer { try? FileManager.default.removeItem(at: killed.root) }
    let (killedStatus, killedRequest) = try await Self.attach(killed)
    #expect(killedStatus == 137)
    let result = try #require(try killed.store.takeResult(killedRequest.id))
    #expect(result.failure == .childSignaled(SIGKILL))
    #expect(result.childTermination == .signaled(SIGKILL))
  } // End of func handlesHangupsAndSignals()

  /// A missing request exits 70 without running anything, and still records a result.
  @Test func reportsAMissingRequest() async throws {
    let fixture = try Self.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let id = LaunchToken()
    let status = await fixture.helper.run(arguments: [Self.helperPath, "attach", id.rawValue])
    #expect(status == LaunchExitStatus.requestMissing)
    #expect(fixture.runner.checks.isEmpty && fixture.runner.calls.isEmpty)
    let result = try #require(try fixture.store.takeResult(id))
    #expect(result.failure == .requestMissing)
    #expect(result.childTermination == nil && result.childStartedAt == nil)
    #expect(fixture.terminal.text.contains(LaunchFailure.requestMissing.explanation))
    #expect(fixture.terminal.waits == 1)
  } // End of func reportsAMissingRequest()

  /// An expired request (clock 121 s after it was written) exits 71 and is gone.
  @Test func reportsAnExpiredRequest() async throws {
    let fixture = try Self.fixture(clockOffset: 121)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (status, request) = try await Self.attach(fixture)
    #expect(status == LaunchExitStatus.requestExpired)
    #expect(fixture.runner.checks.isEmpty && fixture.runner.calls.isEmpty)
    #expect(try fixture.store.takeResult(request.id)?.failure == .requestExpired)
    #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
  }

  /// A spawn failure of either child exits 74 with its errno in the result; a check that
  /// cannot start attaches nothing.
  @Test func reportsSpawnFailures() async throws {
    let attach = try Self.fixture(.error(.spawnFailed(errno: ENOENT)))
    defer { try? FileManager.default.removeItem(at: attach.root) }
    let (status, request) = try await Self.attach(attach)
    #expect(status == LaunchExitStatus.spawnFailed)
    #expect(try attach.store.takeResult(request.id)?.failure == .spawnFailed(errno: ENOENT))

    let check = try Self.fixture(check: .error(.spawnFailed(errno: EACCES)))
    defer { try? FileManager.default.removeItem(at: check.root) }
    let (checkStatus, checkRequest) = try await Self.attach(check)
    #expect(checkStatus == LaunchExitStatus.spawnFailed)
    #expect(check.runner.calls.isEmpty)
    #expect(try check.store.takeResult(checkRequest.id)?.failure == .spawnFailed(errno: EACCES))
  } // End of func reportsSpawnFailures()

  /// Anything but `attach <canonical id>` is a usage error (exit 2) that runs nothing and
  /// consumes nothing; `help` prints the usage and exits 0.
  @Test(arguments: [
    [] as [String],
    ["attach"],
    ["attach", "0F8FAD5B-D9CB-469F-A165-70867728950E"],
    ["attach", "not-a-uuid"],
    ["attach", "0f8fad5b-d9cb-469f-a165-70867728950e", "extra"],
    ["detach", "0f8fad5b-d9cb-469f-a165-70867728950e"],
    ["0f8fad5b-d9cb-469f-a165-70867728950e"],
  ])
  func refusesBadUsage(arguments: [String]) async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let pending = LaunchTestSupport.request(
      id: LaunchToken("0f8fad5b-d9cb-469f-a165-70867728950e")!)
    try fixture.store.writeRequest(pending)
    let status = await fixture.helper.run(arguments: [Self.helperPath] + arguments)
    #expect(status == LaunchExitStatus.usage)
    #expect(fixture.runner.checks.isEmpty && fixture.runner.calls.isEmpty)
    #expect(fixture.terminal.text.hasPrefix(LaunchHelper.usage))
    #expect(try fixture.store.takeRequest(pending.id) == pending)
  } // End of func refusesBadUsage(arguments:)

  /// `help` prints the usage line and exits 0.
  @Test func printsHelp() async throws {
    let fixture = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await fixture.helper.run(arguments: [Self.helperPath, "help"]) == 0)
    #expect(fixture.terminal.text == LaunchHelper.usage + "\n")
  }

  /// An unusable directory override exits 73 and writes nothing.
  @Test func refusesAnUnusableDirectory() async throws {
    #expect(LaunchHelper.store(for: [LaunchHelper.directoryVariable: "relative/dir"]) == nil)
    #expect(LaunchHelper.store(for: [LaunchHelper.directoryVariable: ""]) == nil)
    let custom = LaunchHelper.store(for: [LaunchHelper.directoryVariable: "/tmp/mfx-custom"])
    #expect(custom?.directoryPath == "/tmp/mfx-custom")
    #expect(LaunchHelper.store(for: [:])?.directory == LaunchStore().directory)

    let terminal = FakeLaunchTerminal(isInteractive: false)
    let helper = LaunchHelper(
      store: nil,
      environment: [:],
      childRunner: FakeLaunchChildRunner(
        .termination(.exited(0), forwarded: []),
        check: .exits(0)
      ),
      terminal: terminal,
      log: DiagnosticsLog(writesToSystemLog: false),
      processID: 1
    )
    let status = await helper.run(arguments: [Self.helperPath, "attach", LaunchToken().rawValue])
    #expect(status == LaunchExitStatus.launchDirectoryUnusable)
    #expect(terminal.text.contains(LaunchFailure.launchDirectoryUnusable.explanation))
  } // End of func refusesAnUnusableDirectory()

  /// Test mode (environment variable or marker file) writes an argv digest before parsing,
  /// even for a usage error; without it nothing is written.
  @Test func writesAnArgvDigestInTestMode() async throws {
    let id = LaunchToken()
    let argv = [Self.helperPath, "attach", id.rawValue]

    let plain = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: plain.root) }
    _ = await plain.helper.run(arguments: argv)
    #expect(try plain.store.takeArgvDigests().isEmpty)

    let byVariable = try Self.fixture(environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: byVariable.root) }
    _ = await byVariable.helper.run(arguments: argv)
    let digest = try #require(try byVariable.store.takeArgvDigests().first)
    #expect(digest.argumentCount == 3)
    #expect(digest.helperPID == 4321)
    #expect(digest.launchID == id)
    #expect(digest.arguments.map(\.byteLength) == [Self.helperPath.utf8.count, 6, 36])
    let pathHash = SHA256.hash(data: Data(Self.helperPath.utf8))
    #expect(digest.arguments[0].sha256 == pathHash.map { String(format: "%02x", $0) }.joined())

    let byMarker = try Self.fixture()
    defer { try? FileManager.default.removeItem(at: byMarker.root) }
    try Data().write(to: byMarker.store.directory.appending(path: LaunchStore.testModeMarkerName))
    _ = await byMarker.helper.run(arguments: [Self.helperPath, "attach a b"])
    let split = try #require(try byMarker.store.takeArgvDigests().first)
    #expect(split.argumentCount == 2)
    #expect(split.launchID == nil)
    #expect(split.arguments[1].byteLength == 10)
  } // End of func writesAnArgvDigestInTestMode()
}

/// The helper in this process with the real `TerminalChildRunner` (short grace periods) and
/// the real guard against the fake tmux stalling in `display-message`, like a hung server: the
/// check is bounded by its deadline, a passed-on signal stops it, and either way nothing the
/// check started survives. The attach is never reached, so nothing touches this process's
/// terminal.
@Suite("Launch helper (stalled check)")
struct LaunchHelperStalledCheckTests {
  /// A helper over `store` whose check stalls in the fake tmux, with `control` for passing on
  /// signals.
  static func helper(
    store: LaunchStore,
    root: URL,
    control: TerminalChildControl = .init(),
    terminal: FakeLaunchTerminal,
    checkTimeout: Duration
  ) -> LaunchHelper {
    LaunchHelper(
      store: store,
      environment: [
        "PATH": ProcessEnvironment.systemSearchPath,
        "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
        "MUXFINDER_FAKE_DISPLAY_STALL": "1",
      ],
      childRunner: TerminalChildRunner(control: control, checkRunner: TestSupport.fastRunner),
      terminal: terminal,
      log: DiagnosticsLog(writesToSystemLog: false),
      processID: getpid(),
      checkTimeout: checkTimeout
    )
  } // End of func helper(store:root:control:terminal:checkTimeout:)

  /// A stalled check ends as `checkTimedOut` (75) once its deadline passes (plus the grace
  /// period), and the fake tmux and its sleeper, which ignore SIGTERM, are gone with their
  /// whole process group. A loaded machine may not reach `display-message` within a short
  /// deadline; such an attempt proves nothing about descendants and is retried with twice the
  /// deadline.
  @Test(.timeLimit(.minutes(1)))
  func boundsAStalledCheck() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let clock = ContinuousClock()
    var timeout: Duration = .seconds(1)
    var armed = false
    for _ in 0..<4 {
      try? FileManager.default.removeItem(at: root.appending(path: "stall"))
      let terminal = FakeLaunchTerminal(isInteractive: true)
      let helper = Self.helper(store: store, root: root, terminal: terminal, checkTimeout: timeout)
      let request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
      try store.writeRequest(request)
      let start = clock.now
      let status = await helper.run(arguments: ["muxfinder-launch", "attach", request.id.rawValue])
      let elapsed = start.duration(to: clock.now)
      #expect(status == LaunchExitStatus.checkTimedOut)
      let result = try #require(try store.takeResult(request.id))
      #expect(result.failure == .checkTimedOut)
      #expect(result.childTermination != nil && result.childTermination != .exited(0))
      #expect(elapsed >= timeout && elapsed < timeout + .seconds(5), "\(elapsed)")
      #expect(terminal.text.contains(LaunchFailure.checkTimedOut.explanation))
      #expect(!TestSupport.fileExists("attach", in: root))
      if let record = LaunchTestSupport.stallRecord(in: root) {
        #expect(record.checkParent == getpid())
        #expect(await LaunchTestSupport.waitUntilGone(record))
        armed = true
        break
      }
      timeout = timeout * 2
    } // End of loop over attempts
    #expect(armed, "The fake tmux never reached display-message before the deadline.")
  } // End of func boundsAStalledCheck()

  /// A SIGHUP passed on during the check (the tab closed) ends it at once as `interrupted`
  /// (129), long before its deadline, without a wait for Return; the fake tmux and its sleeper
  /// are gone with their whole process group.
  @Test(.timeLimit(.minutes(1)))
  func stopsTheCheckOnAPassedOnSignal() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let control = TerminalChildControl()
    let terminal = FakeLaunchTerminal(isInteractive: true)
    let helper = Self.helper(
      store: store,
      root: root,
      control: control,
      terminal: terminal,
      checkTimeout: .seconds(30)
    )
    let request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
    try store.writeRequest(request)
    let running = Task {
      await helper.run(arguments: ["muxfinder-launch", "attach", request.id.rawValue])
    }
    let ready = await TestSupport.eventually(within: .seconds(10)) {
      LaunchTestSupport.stallRecord(in: root) != nil
    }
    let clock = ContinuousClock()
    let signaledAt = clock.now
    control.forward(SIGHUP)
    let status = await running.value
    #expect(ready)
    #expect(signaledAt.duration(to: clock.now) < .seconds(5))
    #expect(status == 128 + SIGHUP)
    let result = try #require(try store.takeResult(request.id))
    #expect(result.failure == .interrupted(SIGHUP))
    #expect(terminal.text.contains(LaunchFailure.interrupted(SIGHUP).explanation))
    #expect(terminal.waits == 0)
    #expect(!TestSupport.fileExists("attach", in: root))
    let record = try #require(LaunchTestSupport.stallRecord(in: root))
    #expect(record.checkParent == getpid())
    #expect(await LaunchTestSupport.waitUntilGone(record))
  } // End of func stopsTheCheckOnAPassedOnSignal()
}
