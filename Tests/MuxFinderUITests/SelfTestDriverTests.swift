import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// This Mac's tmux for the self-test driver's tests, in memory: sessions by name on one fake
/// server. It is the driver's `SelfTestTmux`, the engine's and the coordinator's discovery
/// (node name `this-mac.node`) and New session's creator. Nothing runs a process.
final class SimulatedTmux: SelfTestTmux, HostDiscovering, SessionCreating {
  /// The fake server.
  static let server = ServerIdentity(
    socketPath: "/tmp/tmux-fixture/default", pid: 4_321, startTime: 1_799_999_000)
  /// The node name discovery reports.
  static let nodeName = "this-mac.node"

  /// Lock-protected state.
  private struct State {
    /// The sessions, in creation order.
    var sessions: [CreatedSession] = []
    /// The next session id.
    var nextID = 1
    /// Kills so far.
    var kills: [String] = []
    /// Whether creation fails.
    var creationFailure: SessionCreationError?
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates an empty server.
  init() {}

  /// The sessions' names.
  var names: [String] { state.withLock { $0.sessions.map(\.name) } }

  /// The names killed so far.
  var kills: [String] { state.withLock { $0.kills } }

  /// Makes every creation fail with `failure` (or succeed again with `nil`).
  func failCreation(_ failure: SessionCreationError?) {
    state.withLock { $0.creationFailure = failure }
  }

  /// Creates `name` unless it exists.
  private func create(_ name: String) throws(SessionCreationError) -> CreatedSession {
    let result = state.withLock { state -> Result<CreatedSession, SessionCreationError> in
      if let failure = state.creationFailure { return .failure(failure) }
      guard !state.sessions.contains(where: { $0.name == name }) else {
        return .failure(.sessionExists(.hasSession))
      }
      let session = CreatedSession(
        server: Self.server, sessionID: TmuxSessionID("$\(state.nextID)")!,
        createdAt: 1_800_000_000 + Int64(state.nextID), name: name)
      state.nextID += 1
      state.sessions.append(session)
      return .success(session)
    }
    return try result.get()
  } // End of func create(_:)

  /// `SelfTestTmux`: creates the session.
  func createSession(
    named name: String,
    command: [String],
    on host: HostConfig
  ) async throws(SessionCreationError) -> CreatedSession {
    try create(name)
  }

  /// `SessionCreating`: creates the session.
  func createSession(
    _ request: NewSessionRequest
  ) async throws(SessionCreationError) -> CreatedSession {
    try create(request.name)
  }

  /// Removes the session if it is still exactly `session`.
  func kill(_ session: CreatedSession) async -> CreatedSession.KillOutcome {
    state.withLock { state in
      guard let index = state.sessions.firstIndex(of: session) else { return .notThisSession }
      state.sessions.remove(at: index)
      state.kills.append(session.name)
      return .killed
    }
  }

  /// The session named exactly `name`.
  func findSession(named name: String, createdNoEarlierThan earliest: Int64) async
    -> CreatedSession?
  {
    state.withLock { $0.sessions.first { $0.name == name && $0.createdAt >= earliest } }
  }

  /// Lists the sessions on `host`.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    let sessions = state.withLock { $0.sessions }
    let discovered = sessions.map { session in
      DiscoveredSession(
        key: SessionKey(hostID: host.id, server: session.server, sessionID: session.sessionID),
        name: session.name, createdAt: session.createdAt, windowCount: 1,
        attachedClientCount: 0, lastActivityAt: session.createdAt, clients: [])
    }
    return DiscoveryResult(
      hostID: host.id, status: sessions.isEmpty ? .noServer : .ok(discovered),
      report: ProbeReport(nodeName: Self.nodeName), duration: .zero)
  } // End of func discover(_:)
}

/// Collects a self-test's output lines.
final class OutputLog: Sendable {
  /// The lines.
  private let lines = OSAllocatedUnfairLock(initialState: [String]())

  /// Creates an empty log.
  init() {}

  /// Records one line.
  func append(_ line: String) {
    lines.withLock { $0.append(line) }
  }

  /// Every line so far.
  var all: [String] { lines.withLock { $0 } }

  /// Whether a line starts with `prefix`.
  func contains(_ prefix: String) -> Bool { all.contains { $0.hasPrefix(prefix) } }
}

/// The self-test driver (PLAN.md D25) over the fakes: the real `AppModel`, engine and
/// coordinator, a `SimulatedITerm2`, a `SimulatedTmux` and a virtual clock. A connection the
/// user opened (`user-conn`, owned by `user-tab`) is present in every run and must never be
/// asked anything.
@Suite("Self-test drivers")
@MainActor
struct SelfTestDriverTests {
  /// The fakes of one run.
  struct Run {
    /// The driver.
    let driver: SelfTestDriver
    /// The fake iTerm2.
    let iTerm2: SimulatedITerm2
    /// The fake tmux.
    let tmux: SimulatedTmux
    /// The output.
    let log: OutputLog
  }

  /// A driver for `request` over fresh fakes; `holdAfter` stops the coordinator's clock, and
  /// `attachTimeout` bounds the waits for an attach (and cleanup's wait for the actions).
  static func run(
    _ request: SelfTestRequest,
    holdAfter: Duration? = nil,
    attachTimeout: Duration = .seconds(5)
  ) async -> Run {
    let store = MemoryLaunchStore()
    let tmux = SimulatedTmux()
    let log = OutputLog()
    let iTerm2 = SimulatedITerm2(store: store, defaultNodeName: SimulatedTmux.nodeName)
    let seams = SelfTestSeams(
      iTerm2: iTerm2,
      discovery: tmux, store: store, helperPath: AttachHarness.helper,
      clock: VirtualClock(holdAfter: holdAfter), indexClock: PatientClock(),
      sessionCreator: tmux, tmux: tmux,
      timeouts: SelfTestTimeouts(
        listing: .seconds(5), attach: attachTimeout, detach: .seconds(5),
        burial: .milliseconds(300), departure: .milliseconds(300), launchTabAge: .zero,
        pollInterval: .milliseconds(5)),
      sessionName: "muxfinder-test-0000abcd", wallClock: { 1_800_000_000 },
      output: { log.append($0) })
    let driver = SelfTestDriver(request: request, seams: seams)
    return Run(driver: driver, iTerm2: iTerm2, tmux: tmux, log: log)
  } // End of static func run(_:holdAfter:attachTimeout:)

  /// The fake iTerm2 of `run`, with the user's connection and This Mac's node name.
  static func prepare(_ run: Run) async {
    let other = SessionKey(
      hostID: run.driver.host.id, server: SimulatedTmux.server,
      sessionID: TmuxSessionID("$99")!)
    await run.iTerm2.addUserConnection("user-conn", owner: "user-tab", key: other)
  }

  /// `attach-local` passes: eight steps, one launch for the burst, its launch tab buried once
  /// (and never restored or closed by the app), a focus, one `detach-client` to its own
  /// connection, the launch tab gone by itself, the session killed, the user's connection
  /// never asked, no tab closed.
  @Test func attachLocalPasses() async {
    let run = await Self.run(SelfTestRequest(kind: .attachLocal))
    await Self.prepare(run)
    let outcome = await run.driver.run()
    #expect(outcome == .passed, "\(run.log.all)")
    for step in 1...8 { #expect(run.log.contains("PASS \(step) "), "step \(step)") }
    #expect(run.log.contains("PASS 4 launch tab buried"))
    #expect(run.log.contains("PASS 7 launch tab left"))
    #expect(await run.iTerm2.createTabCount == 1)
    #expect(
      await run.iTerm2.buriedRequests.map { "\($0.buried) \($0.sessionID)" } == ["true gateway-1"])
    #expect(await run.iTerm2.launchTabs.isEmpty)
    #expect(await run.driver.coordinatorITerm2.requests == [.buryLaunchTab(sessionID: "gateway-1")])
    #expect(await run.iTerm2.focusedConnections.contains("conn-1"))
    #expect(await run.iTerm2.commands(to: "conn-1").filter { $0 == "detach-client" }.count == 1)
    #expect(await run.iTerm2.commands(to: "user-conn").isEmpty)
    #expect(await run.iTerm2.closeCount == 0)
    #expect(run.tmux.names.isEmpty)
    #expect(run.tmux.kills == ["muxfinder-test-0000abcd"])
    #expect(run.driver.model?.lifecycle == .stopped)
    #expect(run.log.all.last == "muxFinder self-test attach-local: passed (8 steps)")
  } // End of func attachLocalPasses()

  /// `new-session-local` passes: created and confirmed through the sheet, its launch tab
  /// buried, the collision, the detach, the launch tab gone by itself and the kill; one launch,
  /// the user's connection never asked.
  @Test func newSessionLocalPasses() async {
    let run = await Self.run(SelfTestRequest(kind: .newSessionLocal))
    await Self.prepare(run)
    let outcome = await run.driver.run()
    #expect(outcome == .passed, "\(run.log.all)")
    for step in 1...7 { #expect(run.log.contains("PASS \(step) "), "step \(step)") }
    #expect(run.log.contains("PASS 3 launch tab buried"))
    #expect(run.log.contains("PASS 4 collision"))
    #expect(run.log.contains("PASS 6 launch tab left"))
    #expect(await run.iTerm2.createTabCount == 1)
    #expect(
      await run.iTerm2.buriedRequests.map { "\($0.buried) \($0.sessionID)" } == ["true gateway-1"])
    #expect(await run.iTerm2.launchTabs.isEmpty)
    #expect(await run.iTerm2.commands(to: "conn-1").filter { $0 == "detach-client" }.count == 1)
    #expect(await run.iTerm2.commands(to: "user-conn").isEmpty)
    #expect(await run.iTerm2.closeCount == 0)
    #expect(run.tmux.names.isEmpty)
    #expect(run.tmux.kills == ["muxfinder-test-0000abcd"])
    #expect(run.log.all.last == "muxFinder self-test new-session-local: passed (7 steps)")
  } // End of func newSessionLocalPasses()

  /// A bury iTerm2 refuses (`burial` `failed`) fails the buried step of either self-test;
  /// cleanup detaches its own attachment through the core (never closing a tab) and kills the
  /// session.
  @Test(arguments: SelfTestKind.allCases)
  func aRefusedBuryFailsTheBuriedStep(kind: SelfTestKind) async {
    let run = await Self.run(SelfTestRequest(kind: kind))
    await Self.prepare(run)
    await run.iTerm2.configure { $0.buryError = .setPropertyFailed(.impossible) }
    let outcome = await run.driver.run()
    #expect(outcome == .failed)
    let step = kind == .attachLocal ? 4 : 3
    #expect(
      run.log.all.contains {
        $0.hasPrefix("FAIL \(step) launch tab buried")
          && $0.hasSuffix("the launch tab was not buried: failed (setPropertyFailed)")
      }, "\(run.log.all)")
    #expect(run.log.contains("cleanup: detach detached"))
    #expect(run.log.contains("cleanup: kill killed"))
    #expect(await run.iTerm2.commands(to: "user-conn").isEmpty)
    #expect(await run.iTerm2.closeCount == 0)
    #expect(run.tmux.names.isEmpty)
  } // End of func aRefusedBuryFailsTheBuriedStep(kind:)

  /// A bury answered `OK` whose launch tab stays in its tab fails the buried step once the
  /// burial timeout passes, saying where the tab is.
  @Test func aLaunchTabLeftInItsTabFailsTheBuriedStep() async {
    let run = await Self.run(SelfTestRequest(kind: .attachLocal))
    await Self.prepare(run)
    await run.iTerm2.configure { $0.appliesBury = false }
    let outcome = await run.driver.run()
    #expect(outcome == .failed)
    #expect(
      run.log.all.contains {
        $0.hasPrefix("FAIL 4 launch tab buried")
          && $0.hasSuffix("the launch tab is in a tab, not only in buried_sessions")
      }, "\(run.log.all)")
    #expect(run.log.contains("cleanup: kill killed"))
    #expect(await run.iTerm2.closeCount == 0)
  } // End of func aLaunchTabLeftInItsTabFailsTheBuriedStep()

  /// A launch tab still buried after the detach (stranded) fails the departure step of either
  /// self-test; cleanup closes no tab (it is left as it is), sends no second detach and kills
  /// the session.
  @Test(arguments: SelfTestKind.allCases)
  func aStrandedLaunchTabFailsTheDepartureStep(kind: SelfTestKind) async {
    let run = await Self.run(SelfTestRequest(kind: kind))
    await Self.prepare(run)
    await run.iTerm2.configure { $0.closesLaunchTabOnDetach = false }
    let outcome = await run.driver.run()
    #expect(outcome == .failed)
    let step = kind == .attachLocal ? 7 : 6
    #expect(
      run.log.all.contains {
        $0.hasPrefix("FAIL \(step) launch tab left")
          && $0.contains("the launch tab was stranded in buried_sessions 300 ms after the detach")
      }, "\(run.log.all)")
    #expect(!run.log.contains("cleanup: detach"))
    #expect(run.log.contains("cleanup: kill killed"))
    #expect(await run.iTerm2.commands(to: "conn-1").filter { $0 == "detach-client" }.count == 1)
    #expect(await run.iTerm2.buried == ["gateway-1"])
    #expect(await run.iTerm2.closeCount == 0)
    #expect(run.tmux.names.isEmpty)
  } // End of func aStrandedLaunchTabFailsTheDepartureStep(kind:)

  /// A failing step (iTerm2 refuses the tab) stops the run; cleanup detaches nothing (nothing
  /// is attached) and kills the session; the outcome is `failed`.
  @Test func failingStepCleansUp() async {
    let run = await Self.run(SelfTestRequest(kind: .attachLocal))
    await Self.prepare(run)
    await run.iTerm2.configure { $0.createTabError = .createTabFailed(.invalidProfileName) }
    let outcome = await run.driver.run()
    #expect(outcome == .failed)
    #expect(run.log.contains("FAIL 3 open (5 clicks)"))
    #expect(!run.log.contains("PASS 4"))
    #expect(run.log.contains("cleanup: detach nothingAttached"))
    #expect(run.log.contains("cleanup: kill killed"))
    #expect(run.tmux.names.isEmpty)
    #expect(await run.iTerm2.sent.isEmpty)
    #expect(run.driver.model?.lifecycle == .stopped)
  }

  /// A detach whose connection never closes fails its step; cleanup detaches its own
  /// attachment again through the core (never closing a tab, never asking the user's
  /// connection), then kills the session.
  @Test func detachFailureCleansUpOwnAttachment() async {
    let run = await Self.run(SelfTestRequest(kind: .attachLocal))
    await Self.prepare(run)
    await run.iTerm2.configure { $0.closesOnDetach = false }
    let outcome = await run.driver.run()
    #expect(outcome == .failed)
    #expect(run.log.contains("FAIL 6 detach from this Mac"))
    #expect(run.log.contains("cleanup: detach notClosed"))
    #expect(run.log.contains("cleanup: kill killed"))
    #expect(await run.iTerm2.commands(to: "conn-1").filter { $0 == "detach-client" }.count == 2)
    #expect(await run.iTerm2.commands(to: "user-conn").isEmpty)
    #expect(await run.iTerm2.closeCount == 0)
    #expect(run.tmux.names.isEmpty)
  }

  /// A creation that fails at once kills nothing it did not create.
  @Test func creationFailureCreatesNothing() async {
    let run = await Self.run(SelfTestRequest(kind: .attachLocal))
    run.tmux.failCreation(.tmuxMissing)
    let outcome = await run.driver.run()
    #expect(outcome == .failed)
    #expect(run.log.contains("FAIL 1 create session"))
    #expect(run.tmux.kills.isEmpty)
    #expect(await run.iTerm2.createTabCount == 0)
  }

  /// Interrupting the run (SIGTERM cancels the driver's task) during the attach cleans up: the
  /// attach is cancelled, nothing is detached, the session is killed, the outcome is `failed`.
  @Test func interruptedRunCleansUp() async {
    let run = await Self.run(SelfTestRequest(kind: .attachLocal), holdAfter: .seconds(1))
    await Self.prepare(run)
    await run.iTerm2.configure { $0.attaches = false }
    let driver = run.driver
    let task = Task { await driver.run() }
    #expect(
      await UITestSupport.waitUntil {
        guard let model = driver.model, let key = driver.sessionKey else { return false }
        return model.activities[key] == .waitingForITerm2
      })
    task.cancel()
    #expect(await task.value == .failed)
    #expect(run.log.contains("FAIL 3 open (5 clicks)"))
    #expect(run.log.all.contains { $0.hasSuffix("interrupted") })
    #expect(run.log.contains("cleanup: kill killed"))
    #expect(run.tmux.names.isEmpty)
    #expect(await run.iTerm2.sent.isEmpty)
    #expect(await run.iTerm2.closeCount == 0)
  } // End of func interruptedRunCleansUp()

  /// Cleanup waits for the cancelled actions only within the attach timeout: interrupted while
  /// iTerm2 has not answered the launch's `CreateTab` (so that tab's age is unknown), it
  /// detaches and kills nothing, since ending the session could end a tab younger than
  /// iTerm2's 3 s limit, and reports what it left and how to clean up, instead of waiting
  /// without bound; the run still ends `failed`, and the attach withdraws its request once
  /// iTerm2 answers.
  @Test func cleanupReportsAnAttachStillRunning() async {
    let run = await Self.run(SelfTestRequest(kind: .attachLocal), attachTimeout: .milliseconds(300))
    await Self.prepare(run)
    await run.iTerm2.configure {
      $0.attaches = false
      $0.holdsCreateTab = true
    }
    let driver = run.driver
    let task = Task { await driver.run() }
    #expect(await UITestSupport.waitUntil { await run.iTerm2.heldCreateTabCount == 1 })
    task.cancel()
    let ended = Counter()
    let outcome = Task {
      let value = await task.value
      ended.increment()
      return value
    }
    #expect(await UITestSupport.waitUntil(timeout: .seconds(5)) { ended.value == 1 })
    await run.iTerm2.releaseCreateTab()
    #expect(await outcome.value == .failed)
    #expect(run.log.contains("FAIL 3 open (5 clicks)"))
    #expect(run.log.contains("cleanup: 1 session action(s) still running after 300 ms (open)"))
    #expect(run.log.contains("  tmux kill-session -t '=muxfinder-test-0000abcd'"))
    #expect(!run.log.contains("cleanup: detach"))
    #expect(!run.log.contains("cleanup: kill"))
    #expect(run.log.contains("cleanup: done"))
    #expect(run.tmux.names == ["muxfinder-test-0000abcd"])
    #expect(run.tmux.kills.isEmpty)
    #expect(await run.iTerm2.sent.isEmpty)
    #expect(await run.iTerm2.closeCount == 0)
    #expect(run.driver.model?.lifecycle == .stopped)
  } // End of func cleanupReportsAnAttachStillRunning()

  /// Keep mode stops once the attachment is confirmed and its launch tab buried, reports the
  /// session, the connection and the gateway, and leaves both in place (the launch tab still
  /// buried), also after the model stopped.
  @Test func keepModeLeavesWorkRunning() async {
    for kind in SelfTestKind.allCases {
      let run = await Self.run(SelfTestRequest(kind: kind, keep: true))
      await Self.prepare(run)
      let outcome = await run.driver.run()
      let info = SelfTestDriver.KeepInfo(
        sessionName: "muxfinder-test-0000abcd", connectionID: "conn-1",
        gatewaySessionID: "gateway-1")
      #expect(outcome == .kept(info), "\(run.log.all)")
      #expect(run.log.contains("PASS \(kind == .attachLocal ? 4 : 3) launch tab buried"))
      #expect(await run.iTerm2.buried == ["gateway-1"])
      #expect(
        info.line
          == "muxFinder self-test keep: session muxfinder-test-0000abcd connection conn-1 "
          + "gateway gateway-1")
      #expect(info.cleanupLines.contains { $0.contains("detach --connection conn-1 --gateway") })
      await run.driver.shutdown()
      #expect(run.driver.model?.lifecycle == .stopped)
      #expect(run.tmux.names == ["muxfinder-test-0000abcd"])
      #expect(run.tmux.kills.isEmpty)
      #expect(await run.iTerm2.connections.map(\.id).contains("conn-1"))
      #expect(await run.iTerm2.commands(to: "conn-1").contains("detach-client") == false)
      #expect(await run.iTerm2.closeCount == 0)
    } // End of loop over the self-tests
  } // End of func keepModeLeavesWorkRunning()
}
