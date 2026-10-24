import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The helper's launch tab restore (PLAN.md Phase 13 item 4, D29), through the `LaunchTerminal`
/// seam: in `attach` mode, once the attach child has ended, the result is written, then a line
/// feed, the `Disinter` sequence and a status report request (again without the line feed at
/// once when that went unanswered), before the explanation, the wait and the hold, and the
/// same again just before the helper exits; nothing of it in `profile` or `ssh-setup` mode,
/// without an attach child, or after a hang-up. Test mode records the attach child's process
/// id and every restore in the argv digest, and honors the request's `testSuppressDisinter`.
@Suite("Launch tab restore")
struct LaunchTabRestoreTests {
  /// The first restore's status report request: a line feed (ending tmux mode after an
  /// abnormal end), then the `Disinter` sequence.
  static let first = FakeLaunchTerminal.Event.statusReport(
    prefix: LaunchHelper.tmuxModeEndSequence + LaunchHelper.disinterSequence,
    timeout: LaunchHelper.tabRestoreTimeout)
  /// Every later restore's status report request, with the `Disinter` sequence.
  static let restore = FakeLaunchTerminal.Event.statusReport(
    prefix: LaunchHelper.disinterSequence, timeout: LaunchHelper.tabRestoreTimeout)

  /// The bytes of `OSC 1337 ; Disinter ST` and the timing are the ones PLAN.md names.
  @Test func usesTheDocumentedSequences() {
    #expect(LaunchHelper.disinterSequence == Array("\u{1B}]1337;Disinter\u{1B}\\".utf8))
    #expect(LaunchHelper.tmuxModeEndSequence == [0x0A])
    #expect(TerminalStatusRequest.request == Array("\u{1B}[5n".utf8))
    #expect(TerminalStatusRequest.answer == Array("\u{1B}[0n".utf8))
    #expect(LaunchHelper.tabRestoreTimeout == .seconds(2))
  }

  /// A clean detach on a visible tab: the result first (it exists when the first restore
  /// starts), then the restore, the hold, and the restore again as the last thing; nothing is
  /// printed and nothing is logged for answered requests.
  @Test func restoresAfterTheChildAndAgainBeforeExit() async throws {
    let fixture = try LaunchHelperTests.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = LaunchTestSupport.request()
    let resultPath = fixture.store.directory.appending(path: request.id.rawValue + ".result.json")
      .path(percentEncoded: false)
    let resultSeen = OSAllocatedUnfairLock(initialState: [Bool]())
    fixture.terminal.onStatusReport {
      let exists = FileManager.default.fileExists(atPath: resultPath)
      resultSeen.withLock { $0.append(exists) }
    }
    let (status, _) = try await LaunchHelperTests.attach(fixture, request: request)
    #expect(status == 0)
    #expect(fixture.terminal.events == [Self.first, .hold(.seconds(10)), Self.restore])
    #expect(resultSeen.withLock { $0 } == [true, true])
    #expect(try fixture.store.takeResult(request.id)?.succeeded == true)
    #expect(await fixture.log.events().map(\.outcome) == [.success])
  } // End of func restoresAfterTheChildAndAgainBeforeExit()

  /// A failed attach on a visible tab: the first restore comes before the explanation, so the
  /// tab is back before the text is written; the wait for Return and the hold follow, and the
  /// last restore ends it.
  @Test func restoresBeforeTheExplanation() async throws {
    let fixture = try LaunchHelperTests.fixture(
      .termination(.exited(1), forwarded: []), interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let (status, request) = try await LaunchHelperTests.attach(fixture)
    #expect(status == 1)
    let events = fixture.terminal.events
    #expect(events.first == Self.first)
    #expect(events.last == Self.restore)
    #expect(events.filter { $0 == Self.restore }.count == 1)
    let explanation = try #require(
      events.firstIndex {
        if case .text(let text) = $0 { return text.contains("muxFinder:") }
        return false
      })
    let wait = try #require(events.firstIndex(of: .waitForReturn))
    let hold = try #require(events.firstIndex(of: .hold(.seconds(10))))
    #expect(0 < explanation && explanation < wait && wait < hold && hold < events.count - 1)
    #expect(try fixture.store.takeResult(request.id)?.failure == .childExited(1))
  } // End of func restoresBeforeTheExplanation()

  /// Every way the attach child can end (a detach, an error, a signal, and ssh's own failure on
  /// a remote host) is followed by both restores, also on a terminal nobody waits on (the real
  /// terminal itself decides whether it can ask: `unavailable` off a terminal).
  @Test(arguments: [
    (ProcessResult.Termination.exited(0), LaunchHost.local, true),
    (.exited(1), .local, false),
    (.signaled(SIGKILL), .local, true),
    (.exited(255), .ssh(destination: "tester@remote.example.test"), true),
  ])
  func restoresForEveryOutcomeOfTheChild(
    termination: ProcessResult.Termination,
    host: LaunchHost,
    interactive: Bool
  ) async throws {
    let fixture = try LaunchHelperTests.fixture(
      .termination(termination, forwarded: [], standardError: "ssh: connect to host failed\n"),
      interactive: interactive)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await LaunchHelperTests.attach(fixture, request: LaunchTestSupport.request(host: host))
    #expect(fixture.terminal.statusReports.count == 2)
    #expect(fixture.terminal.events.first == Self.first)
    #expect(fixture.terminal.events.last == Self.restore)
  } // End of func restoresForEveryOutcomeOfTheChild(termination:host:interactive:)

  /// No attach child, no restore: a refused or missing request, a failed or timed-out check,
  /// an interrupted check, and a child that could not be spawned (the tab cannot have been
  /// buried, since no tmux ever ran).
  @Test func noRestoreWithoutAnAttachChild() async throws {
    let cases: [(FakeLaunchChildRunner.Behavior, FakeLaunchChildRunner.CheckBehavior?)] = [
      (.termination(.exited(0), forwarded: []), .exits(LaunchExitStatus.sessionGone)),
      (.termination(.exited(0), forwarded: []), .timesOut),
      (.termination(.exited(0), forwarded: []), .interrupted([SIGINT])),
      (.error(.spawnFailed(errno: ENOENT)), nil),
    ]
    for (behavior, check) in cases {
      let fixture = try LaunchHelperTests.fixture(behavior, check: check, interactive: true)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      _ = try await LaunchHelperTests.attach(fixture)
      #expect(fixture.terminal.statusReports.isEmpty, "\(behavior) \(String(describing: check))")
    }
    let missing = try LaunchHelperTests.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: missing.root) }
    _ = await missing.helper.run(
      arguments: [LaunchHelperTests.helperPath, "attach", LaunchToken().rawValue])
    #expect(missing.terminal.statusReports.isEmpty)
  } // End of func noRestoreWithoutAnAttachChild()

  /// A closed tab (SIGHUP passed on to the child): nobody can see the tab, so nothing is
  /// written to it and nothing waits.
  @Test func noRestoreAfterAHangUp() async throws {
    let fixture = try LaunchHelperTests.fixture(
      .termination(.exited(1), forwarded: [SIGHUP]), interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await LaunchHelperTests.attach(fixture)
    #expect(fixture.terminal.statusReports.isEmpty)
  }

  /// A missing answer (every time) is logged once per restore, with kinds and times only, and
  /// the helper goes on: the second restore follows the first at once, the hold still runs and
  /// the exit status is tmux's.
  @Test func logsAMissingAnswerAndGoesOn() async throws {
    let fixture = try LaunchHelperTests.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.terminal.answerStatusReports([.unanswered])
    let request = LaunchTestSupport.request(tmuxPathOverride: fixture.tmuxPath)
    let (status, _) = try await LaunchHelperTests.attach(fixture, request: request)
    #expect(status == 0)
    #expect(
      fixture.terminal.events == [Self.first, Self.restore, .hold(.seconds(10)), Self.restore])
    let events = await fixture.log.events()
    let missing = events.filter { $0.detail.contains("did not answer") }
    #expect(missing.count == 3)
    #expect(missing.allSatisfy { $0.outcome == .failure })
    #expect(missing.map { $0.detail.contains("afterChild") } == [true, false, false])
    #expect(missing.map { $0.detail.contains("afterTmuxModeEnd") } == [false, true, false])
    #expect(missing.last?.detail.contains("beforeExit") == true)
    #expect(!events.contains { $0.detail.contains("secret-path") || $0.detail.contains("$3") })
  } // End of func logsAMissingAnswerAndGoesOn()

  /// After an abnormal end (the attach child killed while iTerm2 still parses the tab as a tmux
  /// gateway), the first status report goes unanswered: the second restore, without the line
  /// feed, comes at once, before the explanation, and is the one answered; the digest records
  /// all three. An unavailable first report (no terminal) is not repeated.
  @Test func restoresAgainWhenTheFirstGoesUnanswered() async throws {
    let fixture = try LaunchHelperTests.fixture(
      .termination(.signaled(SIGKILL), forwarded: []), interactive: true,
      environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.terminal.answerStatusReports([.unanswered, .answered(after: .milliseconds(7))])
    let (_, request) = try await LaunchHelperTests.attach(fixture)
    let events = fixture.terminal.events
    #expect(Array(events.prefix(2)) == [Self.first, Self.restore])
    let explanation = try #require(
      events.firstIndex {
        if case .text(let text) = $0 { return text.contains("muxFinder:") }
        return false
      })
    #expect(explanation == 2)
    #expect(events.last == Self.restore)
    #expect(try fixture.store.takeResult(request.id)?.failure != nil)
    let restores = try #require(try fixture.store.takeArgvDigests().first?.tabRestores)
    #expect(restores.map(\.stage) == [.afterChild, .afterTmuxModeEnd, .beforeExit])
    #expect(restores.map(\.outcome) == ["unanswered", "answered", "answered"])

    let unavailable = try LaunchHelperTests.fixture(interactive: false)
    defer { try? FileManager.default.removeItem(at: unavailable.root) }
    unavailable.terminal.answerStatusReports([.unavailable])
    _ = try await LaunchHelperTests.attach(unavailable)
    #expect(unavailable.terminal.statusReports.count == 2)
  } // End of func restoresAgainWhenTheFirstGoesUnanswered()

  /// In test mode the digest records the attach child's process id and both restores (their
  /// stage, whether `Disinter` was written, the outcome and the answer's delay); without test
  /// mode no digest exists.
  @Test func testModeRecordsTheChildAndTheRestores() async throws {
    let fixture = try LaunchHelperTests.fixture(
      interactive: true, environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    fixture.terminal.answerStatusReports([.answered(after: .milliseconds(4)), .unanswered])
    let (_, request) = try await LaunchHelperTests.attach(fixture)
    let digest = try #require(try fixture.store.takeArgvDigests().first)
    #expect(digest.launchID == request.id)
    #expect(digest.attachChild != nil)
    #expect(digest.attachChildProcessID == FakeLaunchChildRunner.childProcessID)
    let restores = try #require(digest.tabRestores)
    #expect(restores.map(\.stage) == [.afterChild, .beforeExit])
    #expect(restores.map(\.wroteDisinter) == [true, true])
    #expect(restores.map(\.outcome) == ["answered", "unanswered"])
    #expect(restores.map(\.answeredAfterMilliseconds) == [4, nil])
    #expect(restores.allSatisfy { $0.requestedAt <= $0.endedAt })

    let plain = try LaunchHelperTests.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: plain.root) }
    _ = try await LaunchHelperTests.attach(plain)
    #expect(try plain.store.takeArgvDigests().isEmpty)
  } // End of func testModeRecordsTheChildAndTheRestores()

  /// The test switch (`testSuppressDisinter`) suppresses every `Disinter` in test mode (the
  /// first restore's line feed and the status report requests still go out, and the digest
  /// says so); outside test mode it changes nothing, so a request alone cannot keep a tab
  /// buried.
  @Test func theSuppressSwitchWorksOnlyInTestMode() async throws {
    var request = LaunchTestSupport.request()
    request.testSuppressDisinter = true
    let testMode = try LaunchHelperTests.fixture(
      interactive: true, environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: testMode.root) }
    _ = try await LaunchHelperTests.attach(testMode, request: request)
    let lineFeed = FakeLaunchTerminal.Event.statusReport(
      prefix: LaunchHelper.tmuxModeEndSequence, timeout: LaunchHelper.tabRestoreTimeout)
    let bare = FakeLaunchTerminal.Event.statusReport(
      prefix: [], timeout: LaunchHelper.tabRestoreTimeout)
    #expect(testMode.terminal.events == [lineFeed, .hold(.seconds(10)), bare])
    let digest = try #require(try testMode.store.takeArgvDigests().first)
    #expect(digest.tabRestores?.map(\.wroteDisinter) == [false, false])

    var other = request
    other.id = LaunchToken()
    let normal = try LaunchHelperTests.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: normal.root) }
    _ = try await LaunchHelperTests.attach(normal, request: other)
    #expect(normal.terminal.events == [Self.first, .hold(.seconds(10)), Self.restore])
  } // End of func theSuppressSwitchWorksOnlyInTestMode()

  /// The switch is a plain optional field: absent from a normal request's file, and a request
  /// with it reads back the same.
  @Test func theSuppressSwitchRoundTrips() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let plain = LaunchTestSupport.request()
    try store.writeRequest(plain)
    let file = store.directory.appending(path: plain.id.rawValue + ".request.json")
    #expect(!(try String(contentsOf: file, encoding: .utf8)).contains("testSuppressDisinter"))
    #expect(try store.takeRequest(plain.id) == plain)
    var suppressed = LaunchTestSupport.request()
    suppressed.testSuppressDisinter = true
    #expect(suppressed.isWellFormed)
    try store.writeRequest(suppressed)
    #expect(try store.takeRequest(suppressed.id).testSuppressDisinter == true)
  } // End of func theSuppressSwitchRoundTrips()

  /// `ssh-setup` and `profile` write none of it, in test mode too, and record no child process
  /// id: only an attach can have been buried.
  @Test func otherModesWriteNone() async throws {
    let setup = try LaunchHelperTests.fixture(
      interactive: true, environment: [LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: setup.root) }
    _ = try await SSHSetupTests.runSetup(setup)
    #expect(setup.terminal.statusReports.isEmpty)
    let setupDigest = try #require(try setup.store.takeArgvDigests().first)
    #expect(setupDigest.attachChild != nil)
    #expect(setupDigest.attachChildProcessID == nil && setupDigest.tabRestores == nil)

    let profile = try await LaunchHelperProfileTests.fixture(
      environment: ["HOME": "/Users/tester", LaunchHelper.testModeVariable: "1"])
    defer { try? FileManager.default.removeItem(at: profile.root) }
    let status = await LaunchHelperProfileTests.run(
      profile, hostID: LaunchHelperProfileTests.local.id)
    #expect(status == 0)
    #expect(profile.runner.calls.count == 1)
    #expect(profile.terminal.statusReports.isEmpty)
    let profileDigest = try #require(try profile.store.takeArgvDigests().first)
    #expect(profileDigest.attachChildProcessID == nil && profileDigest.tabRestores == nil)
  } // End of func otherModesWriteNone()
} // End of struct LaunchTabRestoreTests

/// The status report exchange itself (`TerminalStatusRequest`) on a real pseudo-terminal whose
/// master side the test plays iTerm2 on: the bytes written, the answer found among other
/// bytes, the bounded wait, input typed earlier discarded, raw mode while waiting and the
/// modes restored after; and nothing at all off a terminal.
@Suite("Terminal status report")
struct TerminalStatusRequestTests {
  /// A pseudo-terminal: the slave is the helper's terminal, the master the test's iTerm2.
  final class PseudoTerminal: Sendable {
    /// The master side (non-blocking).
    let master: Int32
    /// The slave side.
    let slave: Int32
    /// Whether the master side is still open (`hangUp()` closes it once).
    private let masterOpen = OSAllocatedUnfairLock(initialState: true)

    /// Opens a pair.
    init() throws {
      var master: Int32 = -1
      var slave: Int32 = -1
      guard openpty(&master, &slave, nil, nil, nil) == 0 else {
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
      _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
      self.master = master
      self.slave = slave
    }

    /// Closes the master side, once: the terminal goes away, which also ends a wait that a
    /// regression left hanging, so a failing test still ends.
    func hangUp() {
      let open = masterOpen.withLock { open -> Bool in
        defer { open = false }
        return open
      }
      if open { Darwin.close(master) }
    }

    /// Closes both sides.
    func close() {
      hangUp()
      Darwin.close(slave)
    }

    /// Writes `bytes` as the terminal's input (what iTerm2 sends the program).
    func type(_ bytes: [UInt8]) {
      _ = bytes.withUnsafeBytes { write(master, $0.baseAddress, $0.count) }
    }

    /// Reads what the program wrote until `count` bytes arrived or `limit` passed.
    func readOutput(count: Int, within limit: Duration) async -> [UInt8] {
      var collected: [UInt8] = []
      var buffer = [UInt8](repeating: 0, count: 256)
      let deadline = ContinuousClock.now + limit
      while collected.count < count, ContinuousClock.now < deadline {
        let read = Darwin.read(master, &buffer, buffer.count)
        if read > 0 {
          collected += buffer.prefix(read)
        } else {
          try? await Task.sleep(for: .milliseconds(5))
        }
      } // End of loop reading the program's output
      return collected
    } // End of func readOutput(count:within:)

    /// The slave's local modes (without `PENDIN`, which the BSD terminal driver sets by itself
    /// whenever a terminal goes back to canonical mode) and its `VMIN` and `VTIME`.
    func modes() -> (localFlags: tcflag_t, minimum: cc_t, time: cc_t) {
      var current = termios()
      _ = tcgetattr(slave, &current)
      let characters = withUnsafeBytes(of: current.c_cc) { Array($0) }
      return (current.c_lflag & ~tcflag_t(PENDIN), characters[Int(VMIN)], characters[Int(VTIME)])
    }

    /// Whether the slave descriptor's open file description is non-blocking.
    var slaveIsNonBlocking: Bool { fcntl(slave, F_GETFL) & O_NONBLOCK != 0 }

    /// Fills the slave's output queue, which the master never reads, through a non-blocking
    /// descriptor of its own, until the terminal takes nothing more (`EAGAIN`). Returns whether
    /// it got there (bounded at 4 MiB).
    func fillOutput() -> Bool {
      guard let filler = NonBlockingTerminal.reopen(slave, access: O_WRONLY) else { return false }
      defer { Darwin.close(filler) }
      let chunk = [UInt8](repeating: 0x2E, count: 1024)
      for _ in 0..<4096 {
        let count = chunk.withUnsafeBytes { write(filler, $0.baseAddress, $0.count) }
        if count < 0, errno == EAGAIN { return true }
        if count < 0, errno != EINTR { return false }
      } // End of loop writing until the terminal takes nothing more
      return false
    } // End of func fillOutput()
  } // End of class PseudoTerminal

  /// A blocking call on a thread of its own, whose result a test waits for with a bound, so a
  /// call that never returns (a regression) fails the test instead of hanging it.
  final class BackgroundCall<Value: Sendable>: Sendable {
    /// The call's result, once it returned, with how long it took.
    private let outcome = OSAllocatedUnfairLock<(value: Value, elapsed: Duration)?>(
      initialState: nil)

    /// Starts `work` on a new thread.
    init(_ work: @escaping @Sendable () -> Value) {
      let thread = Thread { [outcome] in
        let start = ContinuousClock.now
        let value = work()
        let elapsed = ContinuousClock.now - start
        outcome.withLock { $0 = (value, elapsed) }
      }
      thread.name = "cc.carpio.muxfinder.test-terminal-call"
      thread.start()
    }

    /// The result and the call's duration once it returned, waiting at most `limit`; `nil`
    /// when it is still running.
    func outcome(within limit: Duration) async -> (value: Value, elapsed: Duration)? {
      _ = await TestSupport.eventually(within: limit) { outcome.withLock { $0 != nil } }
      return outcome.withLock { $0 }
    }
  } // End of class BackgroundCall

  /// Runs the exchange on `terminal`'s slave in the background.
  static func start(
    on terminal: PseudoTerminal,
    prefix: [UInt8],
    timeout: Duration,
    reopening: Bool = true
  ) -> Task<(TerminalStatusReport, Duration), Never> {
    let slave = terminal.slave
    return Task.detached {
      let start = ContinuousClock.now
      let report = TerminalStatusRequest.perform(
        input: slave, output: slave, prefix: prefix, timeout: timeout, reopening: reopening)
      return (report, ContinuousClock.now - start)
    }
  } // End of static func start(on:prefix:timeout:reopening:)

  /// The terminal answers (after the request is out): `answered`, long before the timeout; the
  /// program wrote exactly the prefix and the request, and the answer was not echoed back. Also
  /// through the fallback on the shared descriptor (`reopening: false`), whose `O_NONBLOCK` is
  /// taken off again.
  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func findsTheAnswer(reopening: Bool) async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let before = terminal.modes()
    let prefix = LaunchHelper.disinterSequence
    let running = Self.start(
      on: terminal, prefix: prefix, timeout: .seconds(10), reopening: reopening)
    let written = await terminal.readOutput(
      count: prefix.count + TerminalStatusRequest.request.count, within: .seconds(5))
    #expect(written == prefix + TerminalStatusRequest.request)
    let during = terminal.modes()
    #expect(during.localFlags & tcflag_t(ICANON | ECHO) == 0)
    #expect(during.minimum == 1 && during.time == 0)
    terminal.type(TerminalStatusRequest.answer)
    let (report, elapsed) = await running.value
    guard case .answered(let after) = report else {
      Issue.record("expected an answer, got \(report)")
      return
    }
    #expect(after <= elapsed && elapsed < .seconds(5))
    #expect(await terminal.readOutput(count: 1, within: .milliseconds(200)).isEmpty)
    let afterwards = terminal.modes()
    #expect(afterwards.localFlags == before.localFlags)
    #expect(afterwards.minimum == before.minimum && afterwards.time == before.time)
    #expect(!terminal.slaveIsNonBlocking)
  } // End of func findsTheAnswer(reopening:)

  /// Other bytes before and inside the answer's arrival (another report, typing, a lone ESC)
  /// are dropped, and the answer split across writes is still found.
  @Test(.timeLimit(.minutes(1)))
  func skipsOtherBytes() async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let running = Self.start(on: terminal, prefix: [], timeout: .seconds(10))
    _ = await terminal.readOutput(count: TerminalStatusRequest.request.count, within: .seconds(5))
    terminal.type(Array("x\u{1B}[12;3Rab\u{1B}\u{1B}[0".utf8))
    try await Task.sleep(for: .milliseconds(50))
    terminal.type(Array("n".utf8))
    let (report, _) = await running.value
    #expect(report.kind == "answered")
  } // End of func skipsOtherBytes()

  /// No answer, or only other bytes: `unanswered` once the timeout has passed (not before, and
  /// not much later), with the modes restored.
  @Test(.timeLimit(.minutes(1)), arguments: [[UInt8](), Array("\u{1B}[1n garbage \u{1B}[".utf8)])
  func boundsTheWait(typed: [UInt8]) async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let before = terminal.modes()
    let timeout: Duration = .milliseconds(400)
    let running = Self.start(on: terminal, prefix: [], timeout: timeout)
    _ = await terminal.readOutput(count: TerminalStatusRequest.request.count, within: .seconds(5))
    if !typed.isEmpty { terminal.type(typed) }
    let (report, elapsed) = await running.value
    #expect(report == .unanswered)
    #expect(elapsed >= timeout && elapsed < timeout + .seconds(2), "\(elapsed)")
    #expect(terminal.modes().localFlags == before.localFlags)
  } // End of func boundsTheWait(typed:)

  /// Output back-pressure (PLAN.md D29): a terminal that takes no more output (its queue full,
  /// the master never read) cannot hold the exchange past its timeout, which counts the writes
  /// too: `unanswered` within the bound, with the modes and the shared descriptor's flags
  /// restored, through the reopened descriptor and through the fallback alike.
  @Test(.timeLimit(.minutes(1)), arguments: [true, false])
  func boundsAWriteTheTerminalDoesNotTake(reopening: Bool) async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let before = terminal.modes()
    try #require(terminal.fillOutput(), "the terminal's output queue never filled")
    let timeout: Duration = .milliseconds(400)
    let slave = terminal.slave
    let call = BackgroundCall {
      TerminalStatusRequest.perform(
        input: slave, output: slave, prefix: LaunchHelper.disinterSequence, timeout: timeout,
        reopening: reopening)
    }
    let outcome = await call.outcome(within: timeout + .seconds(3))
    if outcome == nil {
      Issue.record("the exchange outlasted its timeout on a terminal that takes no output")
      terminal.hangUp()
    }
    let finished = await call.outcome(within: .seconds(10))
    let (report, elapsed) = try #require(finished)
    #expect(report == .unanswered)
    #expect(elapsed >= timeout && elapsed < timeout + .seconds(2), "\(elapsed)")
    #expect(terminal.modes().localFlags == before.localFlags)
    #expect(!terminal.slaveIsNonBlocking)
  } // End of func boundsAWriteTheTerminalDoesNotTake(reopening:)

  /// Input typed before the request, even an answer-shaped one, is discarded first: it never
  /// counts as the answer.
  @Test(.timeLimit(.minutes(1)))
  func discardsEarlierInput() async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    terminal.type(TerminalStatusRequest.answer + Array("typed earlier\r".utf8))
    try await Task.sleep(for: .milliseconds(50))
    let (report, _) = await Self.start(on: terminal, prefix: [], timeout: .milliseconds(300)).value
    #expect(report == .unanswered)
  }

  /// The terminal going away (the master closed) ends the wait at once as `unanswered`.
  @Test(.timeLimit(.minutes(1)))
  func endsWhenTheTerminalGoes() async throws {
    var master: Int32 = -1
    var slave: Int32 = -1
    try #require(openpty(&master, &slave, nil, nil, nil) == 0)
    defer { Darwin.close(slave) }
    let input = slave
    let running = Task.detached {
      TerminalStatusRequest.perform(input: input, output: input, prefix: [], timeout: .seconds(20))
    }
    var buffer = [UInt8](repeating: 0, count: 16)
    _ = Darwin.read(master, &buffer, buffer.count)
    let closedAt = ContinuousClock.now
    Darwin.close(master)
    #expect(await running.value == .unanswered)
    #expect(ContinuousClock.now - closedAt < .seconds(5))
  } // End of func endsWhenTheTerminalGoes()

  /// Off a terminal (pipes, as in the binary tests and any helper not run in a tab), nothing is
  /// written and the outcome is `unavailable` at once.
  @Test func isUnavailableOffATerminal() throws {
    var descriptors: [Int32] = [-1, -1]
    try #require(pipe(&descriptors) == 0)
    defer {
      for descriptor in descriptors { Darwin.close(descriptor) }
    }
    _ = fcntl(descriptors[0], F_SETFL, fcntl(descriptors[0], F_GETFL) | O_NONBLOCK)
    let report = TerminalStatusRequest.perform(
      input: descriptors[0], output: descriptors[1], prefix: LaunchHelper.disinterSequence,
      timeout: .seconds(5))
    #expect(report == .unavailable)
    var byte: UInt8 = 0
    #expect(Darwin.read(descriptors[0], &byte, 1) == -1)
  } // End of func isUnavailableOffATerminal()

  /// The scanner finds the answer across pieces and after look-alikes, and nothing else.
  @Test func scansForTheAnswer() {
    var scanner = StatusAnswerScanner()
    let start = scanner.feed(Array("\u{1B}[".utf8))
    let rest = scanner.feed(Array("0n".utf8))
    #expect(!start && rest)
    var other = StatusAnswerScanner()
    let lookAlikes = other.feed(Array("\u{1B}[3n\u{1B}[0x\u{1B}0n[0n".utf8))
    let answer = other.feed(Array("\u{1B}\u{1B}[0n".utf8))
    #expect(!lookAlikes && answer)
    var empty = StatusAnswerScanner()
    let nothing = empty.feed([UInt8]())
    #expect(!nothing)
  } // End of func scansForTheAnswer()
} // End of struct TerminalStatusRequestTests

/// The wait for Return's reader (`TerminalReturnReader`) on a real pseudo-terminal: it ends on
/// Return or when the terminal goes away, ignores input typed before it started, and `stop()`
/// (what a SIGINT or SIGTERM does) ends it at once, so once it has returned nothing reads the
/// terminal any more and the launch tab's last restore gets its answer (the finding of the
/// Phase 13a review, PLAN.md D29).
@Suite("Return reader")
struct TerminalReturnReaderTests {
  /// The pseudo-terminal type of the status report tests.
  typealias PseudoTerminal = TerminalStatusRequestTests.PseudoTerminal
  /// A blocking call with a bounded wait for its result.
  typealias BackgroundCall = TerminalStatusRequestTests.BackgroundCall

  /// Return (a carriage return, which the terminal turns into a line end in canonical mode)
  /// ends it, after other typing.
  @Test(.timeLimit(.minutes(1)))
  func endsOnReturn() async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let reader = TerminalReturnReader(input: terminal.slave)
    let call = BackgroundCall { reader.run() }
    try await Task.sleep(for: .milliseconds(100))
    terminal.type(Array("typed\r".utf8))
    let outcome = await call.outcome(within: .seconds(5))
    if outcome == nil { terminal.hangUp() }
    #expect(outcome?.value == .lineEnd)
  } // End of func endsOnReturn()

  /// The terminal going away (the master closed) ends it.
  @Test(.timeLimit(.minutes(1)))
  func endsWhenTheTerminalGoes() async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let reader = TerminalReturnReader(input: terminal.slave)
    let call = BackgroundCall { reader.run() }
    try await Task.sleep(for: .milliseconds(100))
    terminal.hangUp()
    let outcome = await call.outcome(within: .seconds(5))
    let end = outcome?.value
    #expect(end == .endOfInput || end == .failed, "\(String(describing: end))")
  } // End of func endsWhenTheTerminalGoes()

  /// Return typed before the reader started is discarded: the reader goes on until stopped.
  @Test(.timeLimit(.minutes(1)))
  func discardsEarlierInput() async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    terminal.type(Array("early\r".utf8))
    try await Task.sleep(for: .milliseconds(50))
    let reader = TerminalReturnReader(input: terminal.slave)
    let call = BackgroundCall { reader.run() }
    let early = await call.outcome(within: .milliseconds(300))
    #expect(early == nil, "the reader ended on Return typed before it started")
    reader.stop()
    let outcome = await call.outcome(within: .seconds(5))
    if outcome == nil { terminal.hangUp() }
    #expect(outcome?.value == .stopped)
  } // End of func discardsEarlierInput()

  /// A stop before `run()` makes it return at once, and stopping again does nothing.
  @Test(.timeLimit(.minutes(1)))
  func stopsBeforeItRuns() async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let reader = TerminalReturnReader(input: terminal.slave)
    reader.stop()
    reader.stop()
    #expect(reader.isStopped)
    let outcome = await BackgroundCall { reader.run() }.outcome(within: .seconds(5))
    if outcome == nil { terminal.hangUp() }
    #expect(outcome?.value == .stopped)
  } // End of func stopsBeforeItRuns()

  /// The review's race: a stop (a signal ending the wait for Return) while the reader waits
  /// for input ends it within a bound, and it has returned, so nothing reads the terminal any
  /// more. The last restore that follows on the same terminal then gets its whole answer, typed
  /// one byte at a time the moment its request arrives (before, a reader left blocked on
  /// standard input could take some of it, and the exchange's blocking read never returned);
  /// the modes and the descriptor's flags are restored afterwards.
  @Test(.timeLimit(.minutes(1)))
  func aStoppedReaderLeavesTheAnswerToTheLastRestore() async throws {
    let terminal = try PseudoTerminal()
    defer { terminal.close() }
    let before = terminal.modes()
    let reader = TerminalReturnReader(input: terminal.slave)
    let wait = BackgroundCall { reader.run() }
    try await Task.sleep(for: .milliseconds(100))
    DispatchQueue.global().async { reader.stop() }
    let stopped = await wait.outcome(within: .seconds(2))
    if stopped == nil { terminal.hangUp() }
    #expect(stopped?.value == .stopped, "the stopped reader did not return within 2 s")
    let slave = terminal.slave
    let exchange = BackgroundCall {
      TerminalStatusRequest.perform(
        input: slave, output: slave, prefix: LaunchHelper.disinterSequence, timeout: .seconds(2))
    }
    let restore = LaunchHelper.disinterSequence + TerminalStatusRequest.request
    let written = await terminal.readOutput(count: restore.count, within: .seconds(5))
    #expect(written == restore)
    for byte in TerminalStatusRequest.answer {
      terminal.type([byte])
      try await Task.sleep(for: .milliseconds(20))
    }
    let outcome = await exchange.outcome(within: .seconds(5))
    if outcome == nil { terminal.hangUp() }
    #expect(outcome?.value.kind == "answered", "\(String(describing: outcome))")
    #expect(terminal.modes().localFlags == before.localFlags)
    #expect(!terminal.slaveIsNonBlocking)
  } // End of func aStoppedReaderLeavesTheAnswerToTheLastRestore()
} // End of struct TerminalReturnReaderTests

/// The built `muxfinder-launch` with standard input, output and error all on one
/// pseudo-terminal, as in an iTerm2 tab, the test playing iTerm2 on the master side: after the
/// (fake) tmux attach ends, the result file exists by the time the first `Disinter` and status
/// report request arrive, the helper waits for the answer, and the same comes again before it
/// exits. Test mode records the attach child's process id and both answered restores.
@Suite("Launch tab restore (helper binary)")
struct LaunchTabRestoreBinaryTests {
  /// Spawns `request` with descriptors 0, 1 and 2 on `terminal`, in a new process group.
  static func spawn(_ request: ProcessRequest, terminal: Int32) throws -> pid_t {
    let parameters = try ProcessSupervisor.launchParameters(for: request)
    let argv = try CStringArray(parameters.argv)
    let envp = try CStringArray(parameters.environment)
    var actions = try SpawnFileActions()
    defer { actions.destroy() }
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
      try actions.duplicate(terminal, to: descriptor)
    }
    var attributes = try SpawnAttributes()
    defer { attributes.destroy() }
    var processID: pid_t = 0
    let code = argv.withUnsafePointer { argvPointer in
      envp.withUnsafePointer { envPointer in
        posix_spawn(
          &processID, parameters.path, &actions.raw, &attributes.raw, argvPointer, envPointer)
      }
    }
    guard code == 0 else { throw ProcessRunnerError.spawnFailed(errno: code) }
    return processID
  } // End of static func spawn(_:terminal:)

  /// Reads `master` until `pattern` occurs after `offset` in what was read, or `limit` passes;
  /// returns the end of the occurrence, or `nil`.
  static func awaitBytes(
    _ pattern: [UInt8],
    on master: Int32,
    output: inout [UInt8],
    after offset: Int,
    within limit: Duration
  ) async -> Int? {
    var buffer = [UInt8](repeating: 0, count: 512)
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if let range = output[offset...].firstRange(of: pattern) { return range.upperBound }
      let count = Darwin.read(master, &buffer, buffer.count)
      if count > 0 {
        output += buffer.prefix(count)
      } else {
        try? await Task.sleep(for: .milliseconds(5))
      }
    } // End of loop reading the helper's terminal output
    return output[offset...].firstRange(of: pattern)?.upperBound
  } // End of static func awaitBytes(_:on:output:after:within:)

  /// See the suite's documentation.
  @Test(.enabled(if: LaunchHelperBinaryTests.helperURL != nil), .timeLimit(.minutes(1)))
  func restoresOnARealTerminal() async throws {
    let helper = try #require(LaunchHelperBinaryTests.helperURL)
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
    try store.writeRequest(request)
    var master: Int32 = -1
    var slave: Int32 = -1
    try #require(openpty(&master, &slave, nil, nil, nil) == 0)
    defer { Darwin.close(master) }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    let environment = LaunchHelperBinaryTests.environment(
      launchDirectory: store.directory,
      [
        "MUXFINDER_FAKE_IDENTITY": LaunchTestSupport.identity(of: request),
        "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
        LaunchHelper.testModeVariable: "1",
      ])
    let processID: pid_t
    do {
      processID = try Self.spawn(
        ProcessRequest(
          executableURL: helper, arguments: ["attach", request.id.rawValue],
          environment: environment),
        terminal: slave)
    } catch {
      Darwin.close(slave)
      throw error
    }
    Darwin.close(slave)
    // Reaped once only: after a reap the pid may name another process.
    var reaped = false
    defer {
      if !reaped {
        if !ProcessSupervisor.hasExited(processID) { _ = kill(processID, SIGKILL) }
        _ = ProcessSupervisor.reap(processID)
      }
    }
    // The fake tmux reads one line from the terminal, then exits 0.
    _ = Array("hello\r".utf8).withUnsafeBytes { Darwin.write(master, $0.baseAddress, $0.count) }
    let restore = LaunchHelper.disinterSequence + TerminalStatusRequest.request
    let resultURL = store.directory.appending(path: request.id.rawValue + ".result.json")
    var output: [UInt8] = []
    let first = await Self.awaitBytes(
      restore, on: master, output: &output, after: 0, within: .seconds(20))
    let firstEnd = try #require(first, "no Disinter and status report request arrived")
    #expect(firstEnd > restore.count && output[firstEnd - restore.count - 1] == 0x0A)
    #expect(FileManager.default.fileExists(atPath: resultURL.path(percentEncoded: false)))
    _ = TerminalStatusRequest.answer.withUnsafeBytes {
      Darwin.write(master, $0.baseAddress, $0.count)
    }
    let second = await Self.awaitBytes(
      restore, on: master, output: &output, after: firstEnd, within: .seconds(10))
    #expect(second != nil)
    _ = TerminalStatusRequest.answer.withUnsafeBytes {
      Darwin.write(master, $0.baseAddress, $0.count)
    }
    let exited = await TestSupport.eventually(within: .seconds(10)) {
      ProcessSupervisor.hasExited(processID)
    }
    try #require(exited, "the helper did not exit")
    reaped = true
    guard case .success(let waitStatus) = ProcessSupervisor.reap(processID) else {
      Issue.record("the helper could not be reaped")
      return
    }
    #expect(ProcessSupervisor.termination(fromWaitStatus: waitStatus) == .exited(0))
    #expect(try store.takeResult(request.id)?.succeeded == true)
    let digest = try #require(try store.takeArgvDigests().first)
    #expect(digest.attachChildProcessID != nil && digest.attachChildProcessID != processID)
    #expect(digest.tabRestores?.map(\.stage) == [.afterChild, .beforeExit])
    #expect(digest.tabRestores?.map(\.outcome) == ["answered", "answered"])
    #expect(digest.tabRestores?.map(\.wroteDisinter) == [true, true])
  } // End of func restoresOnARealTerminal()

  /// The finding of the Phase 13a review (PLAN.md D29), on the built helper: after a failed
  /// attach (the fake tmux exits 1), a SIGINT or SIGTERM ends the wait for Return, and the
  /// signal keeps coming through the hold and the last restore. That restore's answer, typed
  /// one byte at a time the moment its request arrives (so each byte races whatever still
  /// reads the terminal), must reach the restore whole (`answered` in the digest) and the
  /// helper must exit soon after, with the terminal's modes back as they were and no
  /// `O_NONBLOCK` left on the descriptor it shares with the test. Before the fix, the wait's
  /// reader, left blocked on standard input, took some of those bytes: the restore went
  /// unanswered, or its blocking read never returned and the helper never exited.
  @Test(
    .enabled(if: LaunchHelperBinaryTests.helperURL != nil),
    .timeLimit(.minutes(1)),
    arguments: [SIGINT, SIGTERM]
  )
  func lastRestoreAfterASignalEndedTheWait(signalNumber: Int32) async throws {
    let helper = try #require(LaunchHelperBinaryTests.helperURL)
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
    try store.writeRequest(request)
    let terminal = try TerminalStatusRequestTests.PseudoTerminal()
    defer { terminal.close() }
    let before = terminal.modes()
    var environment = LaunchHelperBinaryTests.environment(
      launchDirectory: store.directory,
      [
        "MUXFINDER_FAKE_IDENTITY": LaunchTestSupport.identity(of: request),
        "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
        "MUXFINDER_FAKE_EXIT": "1",
        LaunchHelper.testModeVariable: "1",
      ])
    environment[StandardLaunchTerminal.noWaitVariable] = nil
    environment[LaunchHelper.minimumLifetimeVariable] = "2000"
    let processID = try Self.spawn(
      ProcessRequest(
        executableURL: helper, arguments: ["attach", request.id.rawValue],
        environment: environment),
      terminal: terminal.slave)
    // Reaped once only: after a reap the pid may name another process.
    var reaped = false
    defer {
      if !reaped {
        if !ProcessSupervisor.hasExited(processID) { _ = kill(processID, SIGKILL) }
        _ = ProcessSupervisor.reap(processID)
      }
    }
    // The fake tmux reads one line from the terminal, then exits 1.
    terminal.type(Array("hello\r".utf8))
    let restore = LaunchHelper.disinterSequence + TerminalStatusRequest.request
    var output: [UInt8] = []
    let first = await Self.awaitBytes(
      restore, on: terminal.master, output: &output, after: 0, within: .seconds(20))
    let firstEnd = try #require(first, "no first restore arrived")
    terminal.type(TerminalStatusRequest.answer)
    let prompt = Array("Press Return to close.".utf8)
    let prompted = await Self.awaitBytes(
      prompt, on: terminal.master, output: &output, after: firstEnd, within: .seconds(10))
    let promptEnd = try #require(prompted, "no prompt")
    // The signal every 50 ms from now on; the restore's answer the moment its request shows.
    var lastRequestSeenAt: ContinuousClock.Instant?
    var nextSignal = ContinuousClock.now
    var buffer = [UInt8](repeating: 0, count: 512)
    let deadline = ContinuousClock.now + .seconds(20)
    while !ProcessSupervisor.hasExited(processID), ContinuousClock.now < deadline {
      if ContinuousClock.now >= nextSignal {
        _ = kill(processID, signalNumber)
        nextSignal = ContinuousClock.now + .milliseconds(50)
      }
      let count = Darwin.read(terminal.master, &buffer, buffer.count)
      if count > 0 { output += buffer.prefix(count) }
      if lastRequestSeenAt == nil, output[promptEnd...].firstRange(of: restore) != nil {
        lastRequestSeenAt = .now
        // One byte at a time: each byte is a race of its own with any other reader.
        for byte in TerminalStatusRequest.answer {
          terminal.type([byte])
          try? await Task.sleep(for: .milliseconds(30))
        }
      }
      if count <= 0 { try? await Task.sleep(for: .milliseconds(5)) }
    } // End of loop signalling and answering until the helper exits
    let requestedAt = try #require(lastRequestSeenAt, "no last restore arrived")
    let exited = await TestSupport.eventually(within: .seconds(1)) {
      ProcessSupervisor.hasExited(processID)
    }
    try #require(exited, "the helper did not exit after its last restore was answered")
    #expect(ContinuousClock.now - requestedAt < .seconds(5))
    reaped = true
    guard case .success(let waitStatus) = ProcessSupervisor.reap(processID) else {
      Issue.record("the helper could not be reaped")
      return
    }
    #expect(ProcessSupervisor.termination(fromWaitStatus: waitStatus) == .exited(1))
    let ended = output[promptEnd...].prefix(2)
    #expect(ended.contains(0x0A), "the wait for Return did not end")
    #expect(try store.takeResult(request.id)?.failure == .childExited(1))
    let digest = try #require(try store.takeArgvDigests().first)
    #expect(digest.tabRestores?.map(\.stage) == [.afterChild, .beforeExit])
    #expect(digest.tabRestores?.map(\.outcome) == ["answered", "answered"])
    let afterwards = terminal.modes()
    #expect(afterwards.localFlags == before.localFlags)
    #expect(afterwards.minimum == before.minimum && afterwards.time == before.time)
    #expect(!terminal.slaveIsNonBlocking)
  } // End of func lastRestoreAfterASignalEndedTheWait(signalNumber:)
} // End of struct LaunchTabRestoreBinaryTests
