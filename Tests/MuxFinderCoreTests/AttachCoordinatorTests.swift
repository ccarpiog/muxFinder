import Foundation
import Testing

@testable import MuxFinderCore

/// `AttachCoordinator` against fakes for iTerm2, discovery, the launch store and the clock.
/// Nothing touches iTerm2, tmux or the launch directory.
@Suite("Attach coordinator")
struct AttachCoordinatorTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The fakes of one test.
  struct Harness {
    /// The session being attached.
    let session: DiscoveredSession
    /// iTerm2.
    let iTerm2: FakeITerm2Integration
    /// Discovery.
    let discovery: FakeDiscovery
    /// The launch store.
    let store: FakeLaunchStore
    /// The clock.
    let clock: ManualAttachClock
    /// The updates.
    let log: UpdateLog
    /// The coordinator.
    let coordinator: AttachCoordinator

    /// The attach target.
    var target: AttachTarget { AttachTarget(host: Support.host, session: session) }
  }

  /// A harness whose iTerm2 follows `script` (by default a successful attach) and whose
  /// discovery reports `status` (by default the session).
  static func harness(
    session: DiscoveredSession = Support.session(),
    status: HostStatus? = nil,
    gated: Bool = false,
    holdsSleeps: Bool = false,
    script: ((inout FakeITerm2Integration.Script) -> Void)? = nil
  ) -> Harness {
    var fakeScript = Support.successScript(for: session)
    script?(&fakeScript)
    let iTerm2 = FakeITerm2Integration(script: fakeScript)
    let discovery = FakeDiscovery(status ?? .ok([session]), gated: gated)
    let store = FakeLaunchStore()
    let clock = ManualAttachClock(holdsSleeps: holdsSleeps)
    let log = UpdateLog()
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, clock: clock, log: log)
    return Harness(
      session: session, iTerm2: iTerm2, discovery: discovery, store: store, clock: clock, log: log,
      coordinator: coordinator)
  } // End of func harness(session:status:gated:holdsSleeps:script:)

  /// The tmux commands asked of iTerm2, in order, with or without an ownership check.
  static func tmuxCommands(_ calls: [FakeITerm2Integration.Call]) -> [String] {
    calls.compactMap { call in
      switch call {
      case .sendTmuxCommand(let command, _), .sendOwnedTmuxCommand(let command, _, _):
        return command
      default:
        return nil
      }
    }
  } // End of func tmuxCommands(_:)

  /// The owners the tmux commands were bound to, in order (`nil` for an unbound command).
  static func commandOwners(_ calls: [FakeITerm2Integration.Call]) -> [String?] {
    calls.compactMap { call in
      switch call {
      case .sendTmuxCommand: return .some(nil)
      case .sendOwnedTmuxCommand(_, _, let owner): return owner
      default: return nil
      }
    }
  }

  /// A coordinator over the usual fakes whose iTerm2 is wrapped in an `InstrumentedITerm2`.
  static func instrumented(
    session: DiscoveredSession = Support.session(),
    holdsSleeps: Bool = false,
    holdsFirstCreateTab: Bool = false,
    script: ((inout FakeITerm2Integration.Script) -> Void)? = nil
  ) -> (Harness, InstrumentedITerm2) {
    var fakeScript = Support.successScript(for: session)
    script?(&fakeScript)
    let fake = FakeITerm2Integration(script: fakeScript)
    let clock = ManualAttachClock(holdsSleeps: holdsSleeps)
    let wrapped = InstrumentedITerm2(fake, clock: clock, holdsFirstCreateTab: holdsFirstCreateTab)
    let discovery = FakeDiscovery(.ok([session]))
    let store = FakeLaunchStore()
    let log = UpdateLog()
    let coordinator = Support.coordinator(
      iTerm2: wrapped, discovery: discovery, store: store, clock: clock, log: log)
    let harness = Harness(
      session: session, iTerm2: fake, discovery: discovery, store: store, clock: clock, log: log,
      coordinator: coordinator)
    return (harness, wrapped)
  } // End of func instrumented(session:holdsSleeps:holdsFirstCreateTab:script:)

  /// The tab requests sent to iTerm2, in order.
  static func createdTabs(_ calls: [FakeITerm2Integration.Call]) -> [ITerm2API.CreateTabRequest] {
    calls.compactMap { call in
      if case .createTab(let request) = call { return request }
      return nil
    }
  }

  /// The activate requests sent to iTerm2, in order.
  static func activations(_ calls: [FakeITerm2Integration.Call]) -> [ITerm2API.ActivateRequest] {
    calls.compactMap { call in
      if case .activate(let request) = call { return request }
      return nil
    }
  }

  // MARK: - Success

  /// A successful attach: the state sequence, the request file, the launch tab, the identity
  /// check through the connection, and activation of the connection's first tab.
  @Test func successfulAttach() async throws {
    let harness = Self.harness()
    let result = await harness.coordinator.attach(harness.target)
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .confirmed(connectionID: Support.connection),
      ])
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.gatewaySessionID == Support.gateway)
    #expect(result.connectionID == Support.connection)
    #expect(result.activation == .activated(tabID: "t3"))
    #expect(await harness.coordinator.state(of: harness.target.key) == result.state)

    let store = harness.store.snapshot
    #expect(store.sweeps == 1)
    #expect(store.discarded.isEmpty)
    let request = try #require(store.written.first)
    #expect(store.written.count == 1)
    #expect(request.id == result.launchID)
    #expect(request.host == .local)
    #expect(request.hostID == Support.host.id)
    #expect(request.sessionID == harness.session.key.sessionID)
    #expect(request.expectedServerPID == 4242)
    #expect(request.expectedServerStartTime == 1_792_599_999)
    #expect(request.expectedSessionCreated == 1_792_600_001)
    #expect(request.createdAt == ManualAttachClock.baseDate)
    #expect(request.tmuxPathOverride == nil)

    let calls = await harness.iTerm2.calls
    #expect(calls.first == .ensureRunning)
    let tab = try #require(Self.createdTabs(calls).first)
    #expect(
      tab
        == ITerm2API.CreateTabRequest(
          customProfileProperties: ITerm2API.ProfileProperty.customCommand(
            Support.helper.attachCommandLine(for: result.launchID))
            + [ITerm2API.ProfileProperty.closeSessionsOnEnd(true)]))
    #expect(Self.tmuxCommands(calls) == [ConnectionIdentity.command])
    #expect(
      calls.contains(
        .sendOwnedTmuxCommand(
          command: ConnectionIdentity.command, connectionID: Support.connection,
          owningSessionID: Support.gateway)))
    #expect(
      Self.activations(calls) == [
        .init(
          target: .tab("t3"), orderWindowFront: true, selectTab: true, selectSession: false,
          activateApp: .init(ignoringOtherApps: true))
      ])
    #expect(!calls.contains { if case .close = $0 { return true } else { return false } })
    #expect(harness.discovery.calls == 1)
    #expect(result.timings.confirmed != nil && result.timings.finished != nil)
  } // End of func successfulAttach()

  /// The host's profile and tmux override reach the tab request and the request file.
  @Test func profileAndOverride() async throws {
    var host = Support.host
    host.iTermProfileName = "fixture-profile-1"
    host.tmuxPathOverride = "/opt/fixture/bin/tmux"
    let harness = Self.harness()
    let result = await harness.coordinator.attach(
      AttachTarget(host: host, session: harness.session))
    #expect(result.isConfirmed)
    let tab = try #require(Self.createdTabs(await harness.iTerm2.calls).first)
    #expect(tab.profileName == "fixture-profile-1")
    #expect(tab.windowID == nil)
    #expect(harness.store.snapshot.written.first?.tmuxPathOverride == "/opt/fixture/bin/tmux")
  } // End of func profileAndOverride()

  /// The connection may appear only after a few polls, next to connections of other tabs.
  @Test func connectionAppearsAfterPolls() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)]),
        queued: [
          .success([]), .success([.init(connectionID: "other", owningSessionID: "someone-else")]),
        ])
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.connectionID == Support.connection)
    #expect(harness.clock.elapsed == .milliseconds(400))
    #expect(harness.store.snapshot.takes == 3)
  } // End of func connectionAppearsAfterPolls()

  /// Activation targets the connection's first tab once it appears, and a connection whose tabs
  /// never appear is still confirmed, with `noTab`.
  @Test func activationWaitsForTheFirstTab() async throws {
    let late = Self.harness { script in
      script.listSessions = .init(.success(Support.sessions), queued: [.success(.init())])
    }
    let result = await late.coordinator.attach(late.target)
    #expect(result.activation == .activated(tabID: "t3"))

    let never = Self.harness { script in script.listSessions = .init(.success(.init())) }
    let noTab = await never.coordinator.attach(never.target)
    #expect(noTab.state == .confirmed(connectionID: Support.connection))
    #expect(noTab.activation == .noTab)
    #expect(Self.activations(await never.iTerm2.calls).isEmpty)
    #expect(never.clock.elapsed >= .seconds(5))
  } // End of func activationWaitsForTheFirstTab()

  /// A refused activation is reported, and the attach stays confirmed.
  @Test func activationFailure() async throws {
    let harness = Self.harness { script in
      script.activate = .init(.failure(.activateFailed(.invalidOption)))
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.isConfirmed)
    #expect(result.activation == .failed(.activateFailed(.invalidOption)))
    #expect(Self.activations(await harness.iTerm2.calls).count == 1)
  }

  /// The review's finding, for step 9: when the launch tab's connection closed and iTerm2 gave
  /// its short id to another tab's connection between the identity check and the activation,
  /// that connection's tab is not activated (`failed(tmuxConnectionNotOwned)`); the attach
  /// stays confirmed.
  @Test func activationRefusesAReusedConnectionID() async throws {
    let launched = ITerm2API.TmuxConnection(
      connectionID: Support.connection, owningSessionID: Support.gateway)
    let harness = Self.harness { script in
      // The poll and the identity check see the launch tab's connection; then the id is
      // another tab's.
      script.listTmuxConnections = .init(
        .success([.init(connectionID: Support.connection, owningSessionID: "someone-else")]),
        queued: [.success([launched]), .success([launched])])
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.activation == .failed(.tmuxConnectionNotOwned))
    let calls = await harness.iTerm2.calls
    #expect(Self.activations(calls).isEmpty)
    #expect(
      calls.contains(
        .activateOwnedTmuxTab(connectionID: Support.connection, owningSessionID: Support.gateway)))
    #expect(!calls.contains(.listSessions))
  } // End of func activationRefusesAReusedConnectionID()

  // MARK: - Single flight

  /// Concurrent attaches for the same session share one launch and one result.
  @Test func concurrentAttachesCoalesce() async throws {
    let harness = Self.harness(gated: true)
    let coordinator = harness.coordinator
    let target = harness.target
    let first = Task { await coordinator.attach(target) }
    let second = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "both callers joined") {
      await coordinator.waiterCount(for: target.key) == 2
    }
    #expect(harness.discovery.calls == 1)
    harness.discovery.release()
    let results = await [first.value, second.value]
    #expect(results[0] == results[1])
    #expect(results[0].isConfirmed)
    #expect(Self.createdTabs(await harness.iTerm2.calls).count == 1)
    #expect(harness.store.snapshot.written.count == 1)
    #expect(harness.log.states.filter { $0.kind == "launched" }.count == 1)
    #expect(await coordinator.waiterCount(for: target.key) == 0)

    let later = await coordinator.attach(target)
    #expect(later.launchID != results[0].launchID)
    #expect(Self.createdTabs(await harness.iTerm2.calls).count == 2)
  } // End of func concurrentAttachesCoalesce()

  /// Attaches for different sessions do not coalesce.
  @Test func differentSessionsLaunchSeparately() async throws {
    let other = Support.session(id: "$4")
    let harness = Self.harness(status: .ok([Support.session(), other]), gated: true)
    let coordinator = harness.coordinator
    let first = Task { await coordinator.attach(harness.target) }
    let second = Task { await coordinator.attach(AttachTarget(host: Support.host, session: other)) }
    try await waitUntil(timeout: .seconds(5), "both launches started") {
      harness.discovery.calls == 2
    }
    harness.discovery.release()
    _ = await (first.value, second.value)
    #expect(Self.createdTabs(await harness.iTerm2.calls).count == 2)
  } // End of func differentSessionsLaunchSeparately()

  /// The review's finding: a launch whose callers were all cancelled, still waiting for its
  /// `CreateTab`, finishes after a newer launch for the same session was confirmed. Its updates
  /// are still reported (with its launch tab), marked as not current, and the session's state
  /// stays the newer launch's.
  @Test func olderCancelledLaunchDoesNotOverwriteTheNewerState() async throws {
    let (harness, iTerm2) = Self.instrumented(holdsFirstCreateTab: true) { script in
      script.createTab = .init(
        .success(.init(status: .ok, windowID: "w9", tabID: 9, sessionID: Support.gateway)),
        queued: [
          .success(.init(status: .ok, windowID: "w8", tabID: 8, sessionID: "old-gateway"))
        ])
    }
    let coordinator = harness.coordinator
    let target = harness.target
    let older = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "the first CreateTab is held") {
      iTerm2.isHoldingCreateTab
    }
    older.cancel()
    try await waitUntil(timeout: .seconds(5), "the first launch is winding down") {
      await coordinator.cancelledWaiterCount(for: target.key) == 1
    }
    let newer = await coordinator.attach(target)
    #expect(newer.state == .confirmed(connectionID: Support.connection))
    #expect(await coordinator.state(of: target.key) == newer.state)

    iTerm2.releaseCreateTab()
    let old = await older.value
    #expect(old.failure == .cancelled)
    #expect(old.gatewaySessionID == "old-gateway")
    #expect(await coordinator.state(of: target.key) == newer.state)
    let oldUpdates = harness.log.all.filter { $0.launchID == old.launchID }
    #expect(
      oldUpdates.map(\.state) == [
        .requested, .launched(sessionID: "old-gateway"), .failed(.cancelled),
      ])
    #expect(oldUpdates.map(\.isCurrent) == [true, false, false])
    let newerUpdates = harness.log.all.filter { $0.launchID == newer.launchID }
    #expect(newerUpdates.map(\.isCurrent) == [true, true, true])
  } // End of func olderCancelledLaunchDoesNotOverwriteTheNewerState()

  /// When every waiting caller is cancelled, the launch stops at its next step, fails with
  /// `cancelled`, withdraws its request, and still reports the tab it opened.
  @Test func cancellingEveryCallerStopsTheLaunch() async throws {
    let harness = Self.harness(holdsSleeps: true) { script in
      script.listTmuxConnections = .init(.success([]))
    }
    let coordinator = harness.coordinator
    let target = harness.target
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "the launch is polling") {
      harness.clock.heldSleeps > 0
    }
    attach.cancel()
    let result = await attach.value
    #expect(result.failure == .cancelled)
    #expect(result.gatewaySessionID == Support.gateway)
    #expect(harness.store.snapshot.discarded == [result.launchID])
    #expect(harness.log.states.last == .failed(.cancelled))
  } // End of func cancellingEveryCallerStopsTheLaunch()

  // MARK: - Failures

  /// No connection and no helper result within 15 s: `timedOut`, and the request is withdrawn.
  @Test func connectionPollTimesOut() async throws {
    let harness = Self.harness { script in script.listTmuxConnections = .init(.success([])) }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .timedOut)
    #expect(result.gatewaySessionID == Support.gateway)
    #expect(result.connectionID == nil)
    #expect(harness.clock.elapsed >= .seconds(15))
    #expect(harness.clock.elapsed < .seconds(16))
    #expect(harness.store.snapshot.discarded == [result.launchID])
    #expect(
      harness.log.states == [.requested, .launched(sessionID: Support.gateway), .failed(.timedOut)])
    let calls = await harness.iTerm2.calls
    #expect(Self.tmuxCommands(calls).isEmpty)
    #expect(Self.activations(calls).isEmpty)
  } // End of func connectionPollTimesOut()

  /// The failures a helper result maps to (PLAN.md D14).
  static let resultFailures: [(LaunchFailure?, AttachFailure)] = [
    (.sessionGone, .sessionGone), (.sessionChanged, .sessionChanged), (.tmuxMissing, .tmuxMissing),
    (.tmuxCheckFailed, .helperFailed(.tmuxCheckFailed)),
    (.checkTimedOut, .helperFailed(.checkTimedOut)),
    (.requestExpired, .helperFailed(.requestExpired)),
    (.interrupted(1), .helperFailed(.interrupted(1))),
    (.childExited(1), .helperFailed(.childExited(1))), (nil, .helperEnded),
  ]

  /// A helper result found while polling ends the attach with the mapped failure; nothing is
  /// sent through a connection.
  @Test(arguments: 0..<resultFailures.count)
  func helperResultFailure(_ index: Int) async throws {
    let (launchFailure, expected) = Self.resultFailures[index]
    let harness = Self.harness { script in script.listTmuxConnections = .init(.success([])) }
    harness.store.update { state in
      state.resultAfterTakes = 2
      state.makeResult = { Support.result(for: $0, failure: launchFailure) }
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == expected)
    #expect(result.gatewaySessionID == Support.gateway)
    #expect(harness.log.states.last == .failed(expected))
    #expect(harness.clock.elapsed == .milliseconds(400))
    #expect(Self.tmuxCommands(await harness.iTerm2.calls).isEmpty)
  } // End of func helperResultFailure(_:)

  /// Identity answers that name another server or session (and unreadable ones) fail the
  /// attach and detach the connection, bound to the launch tab, only once the launch tab is
  /// 10 s old; nothing is activated.
  @Test(arguments: [
    (AttachTestSupport.identityLine(pid: "4243"), true),
    (AttachTestSupport.identityLine(startTime: "1792599998"), true),
    (AttachTestSupport.identityLine(socketPath: "/private/tmp/tmux-502/default"), true),
    (AttachTestSupport.identityLine(sessionID: "$4"), true),
    (AttachTestSupport.identityLine(socketLength: 28), false),
    (
      AttachTestSupport.identityLine(socketPath: "/private/tmp/tmux_501/default", utf8: false),
      false
    ),
    ("fixture-node.local\t4242\t1792599999\t/private/tmp/tmux-501/default\t$3", false),
    ("garbage", false), ("", false),
  ])
  func identityMismatch(_ output: String, readable: Bool) async throws {
    let harness = Self.harness { script in script.sendTmuxCommand = .init(.success(output)) }
    let result = await harness.coordinator.attach(harness.target)
    #expect((ConnectionIdentity.parse(output) != nil) == readable)
    #expect(result.failure == (readable ? .identityMismatch : .identityCheckFailed(nil)))
    #expect(result.connectionID == Support.connection)
    let calls = await harness.iTerm2.calls
    #expect(
      Self.tmuxCommands(calls) == [ConnectionIdentity.command, ConnectionIdentity.detachCommand])
    #expect(Self.commandOwners(calls) == [Support.gateway, Support.gateway])
    #expect(harness.clock.elapsed == .seconds(10))
    #expect(Self.activations(calls).isEmpty)
    #expect(!harness.log.states.contains(.confirmed(connectionID: Support.connection)))
  } // End of func identityMismatch(_:readable:)

  /// The review's finding: the detach after a failed identity check waits until the launch tab
  /// is 10 s old, counted from when it opened (not from the check), so iTerm2's blocking
  /// short-lived-session warning cannot appear.
  @Test func identityFailureDetachWaitsForTheMinimumAge() async throws {
    let (harness, iTerm2) = Self.instrumented { script in
      script.listTmuxConnections = .init(
        .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)]),
        queued: [.success([]), .success([])])
      script.sendTmuxCommand = .init(
        .success(Support.identityLine(startTime: "1", sessionID: "$9") + "\n"))
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .identityMismatch)
    #expect(
      iTerm2.sent == [
        .init(
          command: ConnectionIdentity.command, connectionID: Support.connection,
          at: .milliseconds(400)),
        .init(
          command: ConnectionIdentity.detachCommand, connectionID: Support.connection,
          at: .seconds(10)),
      ])
    #expect(result.timings.finished == .seconds(10))
  } // End of func identityFailureDetachWaitsForTheMinimumAge()

  /// A failed identity request is reported as is; nothing more is sent (D13).
  @Test func identityRequestFailure() async throws {
    let harness = Self.harness { script in script.sendTmuxCommand = .init(.failure(.timedOut)) }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .identityCheckFailed(.timedOut))
    #expect(Self.tmuxCommands(await harness.iTerm2.calls) == [ConnectionIdentity.command])
  }

  /// Revalidation failures end the attach before anything is written or opened.
  @Test(arguments: [
    (HostStatus.noServer, AttachFailure.sessionGone),
    (.tmuxNotFound, .tmuxMissing),
    (.ok([]), .sessionGone),
    (.ok([AttachTestSupport.session(createdAt: 1_792_600_002)]), .sessionChanged),
    (
      .ok([
        AttachTestSupport.session(
          server: ServerIdentity(
            socketPath: "/private/tmp/tmux-501/default", pid: 5000, startTime: 1))
      ]), .sessionChanged
    ),
    (.probeError("fixture"), .discoveryFailed("probeError")),
  ])
  func revalidationFailure(_ status: HostStatus, _ expected: AttachFailure) async throws {
    let harness = Self.harness(status: status)
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == expected)
    #expect(harness.log.states == [.requested, .failed(expected)])
    #expect(harness.store.snapshot.written.isEmpty)
    #expect(await harness.iTerm2.calls.isEmpty)
  }

  /// SSH hosts are not attached yet.
  @Test func sshHostsAreUnsupported() async throws {
    let harness = Self.harness()
    let host = HostConfig(displayName: "Remote", mode: .ssh, sshDestination: "fixture-host")
    let result = await harness.coordinator.attach(
      AttachTarget(host: host, session: harness.session))
    #expect(result.failure == .unsupportedHost)
    #expect(harness.discovery.calls == 0)
  }

  /// A request that cannot be written ends the attach before iTerm2 is asked anything.
  @Test func requestWriteFailure() async throws {
    let harness = Self.harness()
    harness.store.update { $0.writeError = .directoryIsSymbolicLink }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .launchStore(.directoryIsSymbolicLink))
    #expect(await harness.iTerm2.calls.isEmpty)
  }

  /// iTerm2 failures before the tab exists withdraw the request, and `CreateTab` is sent once,
  /// never retried (D13).
  @Test(arguments: [
    ITerm2Error.createTabFailed(.invalidProfileName), .notSent(.timedOut), .timedOut,
  ])
  func createTabFailure(_ error: ITerm2Error) async throws {
    let harness = Self.harness { script in script.createTab = .init(.failure(error)) }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .iTerm2(error))
    #expect(result.gatewaySessionID == nil)
    #expect(Self.createdTabs(await harness.iTerm2.calls).count == 1)
    #expect(harness.store.snapshot.discarded == [result.launchID])
    #expect(harness.log.states == [.requested, .failed(.iTerm2(error))])
  }

  /// A tab without a session id, and a failed `ensureRunning()`, withdraw the request too.
  @Test func otherLaunchFailures() async throws {
    let noSession = Self.harness { script in script.createTab = .init(.success(.init(status: .ok)))
    }
    let missing = await noSession.coordinator.attach(noSession.target)
    #expect(missing.failure?.kind == "iTerm2")
    #expect(noSession.store.snapshot.discarded == [missing.launchID])

    let notRunning = Self.harness { script in
      script.ensureRunning = .init(.failure(.apiDisabled))
    }
    let refused = await notRunning.coordinator.attach(notRunning.target)
    #expect(refused.failure == .iTerm2(.apiDisabled))
    #expect(Self.createdTabs(await notRunning.iTerm2.calls).isEmpty)
    #expect(notRunning.store.snapshot.discarded == [refused.launchID])
  } // End of func otherLaunchFailures()

  // MARK: - Detach

  /// Detach sends `detach-client` on the connection, bound to its launch tab (never closes a
  /// tab), waits for the connection to close and takes the helper's result. A launch tab this
  /// coordinator did not open counts as opened at the call, so the command waits 10 s.
  @Test func detachSendsDetachClient() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([]),
        queued: [
          .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)])
        ])
    }
    let launchID = LaunchToken()
    let request = LaunchTestSupport.request(id: launchID)
    harness.store.update { $0.results[launchID] = Support.result(for: request, failure: nil) }
    let result = await harness.coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway, launchID: launchID)
    #expect(result.connectionClosed)
    #expect(result.commandError == nil)
    #expect(!result.cancelled)
    #expect(result.isClean)
    #expect(result.helperResult?.exitStatus == 0)
    #expect(harness.clock.elapsed == .seconds(10))
    let calls = await harness.iTerm2.calls
    #expect(
      calls.first
        == .sendOwnedTmuxCommand(
          command: "detach-client", connectionID: Support.connection,
          owningSessionID: Support.gateway))
    #expect(calls.filter { $0 == .listTmuxConnections }.count == 1)
    #expect(!calls.contains { if case .close = $0 { return true } else { return false } })
  } // End of func detachSendsDetachClient()

  /// A `detach-client` that certainly was not sent is not waited for; one whose connection never
  /// closes ends after the budget, without a second command.
  @Test func detachFailures() async throws {
    let unsent = Self.harness { script in
      script.sendTmuxCommand = .init(.failure(.notSent(.timedOut)))
    }
    let notSent = await unsent.coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway)
    #expect(!notSent.connectionClosed)
    #expect(notSent.commandError == .notSent(.timedOut))
    #expect(await unsent.iTerm2.calls.count == 1)

    let stuck = Self.harness()
    let open = await stuck.coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway)
    #expect(!open.connectionClosed)
    #expect(!open.isClean)
    #expect(stuck.clock.elapsed >= .seconds(20))
    #expect(Self.tmuxCommands(await stuck.iTerm2.calls) == ["detach-client"])
  } // End of func detachFailures()

  /// The review's finding: a detach right after the attach waits until the launch tab is 10 s
  /// old (counted from when the coordinator opened it); one issued later does not wait.
  @Test func detachWaitsUntilTheLaunchTabIsOldEnough() async throws {
    let (soon, soonITerm2) = Self.instrumented()
    let attached = await soon.coordinator.attach(soon.target)
    #expect(attached.isConfirmed)
    #expect(soon.clock.elapsed == .zero)
    await soon.iTerm2.updateScript { script in
      script.listTmuxConnections = .init(
        .success([]),
        queued: [
          .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)])
        ])
    }
    let early = await soon.coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway)
    #expect(early.connectionClosed)
    #expect(
      soonITerm2.sent.last
        == .init(command: "detach-client", connectionID: Support.connection, at: .seconds(10)))

    let (later, laterITerm2) = Self.instrumented()
    _ = await later.coordinator.attach(later.target)
    try await later.clock.sleep(for: .seconds(12))
    await later.iTerm2.updateScript { script in
      script.listTmuxConnections = .init(
        .success([]),
        queued: [
          .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)])
        ])
    }
    let late = await later.coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway)
    #expect(late.connectionClosed)
    #expect(
      laterITerm2.sent.last
        == .init(command: "detach-client", connectionID: Support.connection, at: .seconds(12)))
  } // End of func detachWaitsUntilTheLaunchTabIsOldEnough()

  /// A caller cancelled while the detach waits for the launch tab's age sends nothing.
  @Test func detachCancelledDuringTheWaitSendsNothing() async throws {
    let (harness, iTerm2) = Self.instrumented(holdsSleeps: true)
    let attached = await harness.coordinator.attach(harness.target)
    #expect(attached.isConfirmed)
    let coordinator = harness.coordinator
    let detach = Task {
      await coordinator.detach(connectionID: Support.connection, gatewaySessionID: Support.gateway)
    }
    try await waitUntil(timeout: .seconds(5), "the detach is waiting") {
      harness.clock.heldSleeps > 0
    }
    detach.cancel()
    let result = await detach.value
    #expect(result.cancelled)
    #expect(!result.connectionClosed)
    #expect(result.commandError == nil)
    #expect(iTerm2.sent.map(\.command) == [ConnectionIdentity.command])
  } // End of func detachCancelledDuringTheWaitSendsNothing()

  /// The review's finding: after an iTerm2 restart the short connection id can name another
  /// session's connection. Detach then refuses (`tmuxConnectionNotOwned`), sends nothing and
  /// waits for nothing.
  @Test func detachRefusesAConnectionNoLongerOwnedByTheLaunchTab() async throws {
    let (harness, iTerm2) = Self.instrumented()
    _ = await harness.coordinator.attach(harness.target)
    await harness.iTerm2.updateScript { script in
      script.listTmuxConnections = .init(
        .success([
          .init(
            connectionID: Support.connection,
            owningSessionID: "00000000-0000-4000-8000-0000000000ff")
        ]))
    }
    await harness.iTerm2.clearCalls()
    let result = await harness.coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway)
    #expect(result.commandError == .tmuxConnectionNotOwned)
    #expect(!result.connectionClosed)
    #expect(iTerm2.sent.map(\.command) == [ConnectionIdentity.command])
    #expect(
      await harness.iTerm2.calls == [
        .sendOwnedTmuxCommand(
          command: "detach-client", connectionID: Support.connection,
          owningSessionID: Support.gateway)
      ])
  } // End of func detachRefusesAConnectionNoLongerOwnedByTheLaunchTab()

  // MARK: - Models

  /// Every failure has a kind and an English message; helper failures map as D14 says.
  @Test func failureDescriptions() {
    let failures: [AttachFailure] = [
      .unsupportedHost, .sessionGone, .sessionChanged, .tmuxMissing, .discoveryFailed("probeError"),
      .launchStore(.fileMissing), .iTerm2(.timedOut), .helperFailed(.checkTimedOut), .helperEnded,
      .timedOut, .identityCheckFailed(nil), .identityMismatch, .cancelled,
      .attachmentCheckFailed(.timedOut), .attachmentChanged,
    ]
    #expect(Set(failures.map(\.kind)).count == failures.count)
    for failure in failures {
      #expect(failure.message.count > 10)
      #expect(failure.message.hasSuffix("."))
    }
    #expect(AttachFailure.from(.sessionGone) == .sessionGone)
    #expect(AttachFailure.from(.spawnFailed(errno: 2)) == .helperFailed(.spawnFailed(errno: 2)))
  } // End of func failureDescriptions()
}

/// `ConnectionIdentity`: the static commands and the strict reader, for tmux clients in UTF-8
/// mode and not (PLAN.md D16, *Verified facts*, Phase 5a).
@Suite("Connection identity")
struct ConnectionIdentityTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The commands are the static strings PLAN.md names; nothing is inserted into them.
  @Test func commands() {
    #expect(
      ConnectionIdentity.command
        == "display-message -p \"#{client_utf8}:#{n:host}:#{host}:#{pid}:#{start_time}:"
        + "#{n:socket_path}:#{socket_path}:#{session_id}\"")
    #expect(ConnectionIdentity.detachCommand == "detach-client")
  }

  /// Well-formed answers from a client in UTF-8 mode are exact, whatever the host name and
  /// socket path hold (`:`, `_`, a tab, non-ASCII), with or without a trailing line break.
  @Test func readsExactAnswers() throws {
    let plain = try #require(
      ConnectionIdentity.parse(
        "1:16:Fixture-M4.local:4242:1792599999:29:/private/tmp/tmux-501/default:$3\n"))
    #expect(plain.host == "Fixture-M4.local")
    #expect(plain.pid == 4242)
    #expect(plain.startTime == 1_792_599_999)
    #expect(plain.socketPath == "/private/tmp/tmux-501/default")
    #expect(plain.sessionID == TmuxSessionID("$3"))
    #expect(plain.server == Support.server)
    #expect(plain.matches(Support.session().key))
    let odd = "/tmp/mfx.é_x:7:\tz/tmux-501/default"
    let unusual = try #require(
      ConnectionIdentity.parse(
        Support.identityLine(host: "mäc-ü:1", pid: "1", startTime: "0", socketPath: odd)
          + "\r\n"))
    #expect(unusual.host == "mäc-ü:1")
    #expect(unusual.socketPath == odd)
    #expect(!unusual.matches(Support.session().key))
    // With exact bytes, a separator inside a field is part of it: the lengths decide.
    let shifted = try #require(ConnectionIdentity.parse("1:11:a:7:5:11:/p:1:2:2:/q:$3"))
    #expect(shifted.host == "a:7:5:11:/p")
    #expect(shifted.socketPath == "/q")
  } // End of func readsExactAnswers()

  /// A client not in UTF-8 mode: an answer that cannot have lost anything (printable ASCII
  /// without `_` or `:` in the host name and socket path) is exact.
  @Test func readsExactAnswersOfANonUTF8Client() throws {
    let reported = try #require(ConnectionIdentity.parse(Support.identityLine(utf8: false)))
    #expect(reported.host == Support.nodeName)
    #expect(reported.matches(Support.session().key))
  }

  /// The review's finding: what tmux 3.8 sends a client not in UTF-8 mode (one `_` per column
  /// in place of every tab, other control character and non-ASCII character; a zero-width
  /// character vanishes) is `nonUTF8`, never an identity: `é` replaced (the field one byte
  /// shorter than its length says), a tab replaced (same length), a `_` that may be either, a
  /// host and path with `:`, a zero-width character dropped so the host swallows the next
  /// separators (`a` plus five combining marks: 11 bytes, sent as `a`), a byte tmux never sends
  /// such a client, and the old tab-separated line with its tabs replaced.
  @Test(arguments: [
    Support.identityLine(
      socketPath: "/tmp/mfx.dud/__x/tmux-501/default", utf8: false, socketLength: 34),
    Support.identityLine(socketPath: "/tmp/a_b/default", utf8: false),
    Support.identityLine(host: "fixture_node.local", utf8: false),
    Support.identityLine(host: "fixture:node", utf8: false),
    Support.identityLine(socketPath: "/tmp/a:b/default", utf8: false),
    "0:11:a:7:5:11:/p:1:2:2:/q:$3",
    Support.identityLine(host: "mäc", utf8: false),
    "0:fixture-node.local_4242_1792599999_/private/tmp/tmux-501/default_$3",
  ])
  func nonUTF8AnswersNeverMatch(_ output: String) {
    #expect(ConnectionIdentity.read(output) == .nonUTF8)
    #expect(ConnectionIdentity.parse(output) == nil)
  }

  /// Anything else is unreadable: no or another UTF-8 flag, the old tab-separated line, wrong
  /// lengths, missing or extra fields, an empty or control-character host, non-canonical or
  /// overflowing numbers, a relative path, a second line, a bad session id. A client not in
  /// UTF-8 mode whose clean answer has an invalid value is unreadable too.
  @Test(arguments: [
    "", "\n", "1", "1:", "2:" + Support.identityLine().dropFirst(2),
    Support.identityLine().dropFirst(2).description,
    "fixture-node.local\t4242\t1792599999\t/private/tmp/tmux-501/default\t$3",
    Support.identityLine(hostLength: 17), Support.identityLine(hostLength: 19),
    Support.identityLine(socketLength: 30),
    Support.identityLine(hostLength: 99_999_999_999_999_999),
    Support.identityLine(host: ""), Support.identityLine(host: "h\u{1}x"),
    Support.identityLine(host: "h\u{7F}"), Support.identityLine(pid: "04242"),
    Support.identityLine(pid: "+4242"), Support.identityLine(pid: "-1"),
    Support.identityLine(pid: "0"),
    Support.identityLine(pid: "99999999999"), Support.identityLine(startTime: " 1"),
    Support.identityLine(startTime: ""), Support.identityLine(socketPath: "relative"),
    Support.identityLine(socketPath: ""), Support.identityLine(sessionID: "3"),
    Support.identityLine(sessionID: "$3 "), Support.identityLine(sessionID: ""),
    Support.identityLine() + "\nextra", Support.identityLine() + ":",
    Support.identityLine(pid: "0", utf8: false),
    Support.identityLine(socketPath: "relative", utf8: false),
  ])
  func refusesMalformedAnswers(_ output: String) {
    #expect(ConnectionIdentity.read(output) == .unreadable)
    #expect(ConnectionIdentity.parse(output) == nil)
  }
}
