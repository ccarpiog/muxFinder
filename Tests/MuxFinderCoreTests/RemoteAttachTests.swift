import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The coordinator with an SSH host (PLAN.md D17): the launch request's host kind, the identity
/// check naming the remote node, the 20 s budget and `stillWaiting` (never a success, a later
/// confirmation still published, the helper's result, the launch tab closing, the wait limit,
/// a caller joining, cancellation), focus of an existing remote attachment and
/// `detach(session:on:)` for a remote host. Fakes for iTerm2, discovery, the store and clocks.
@Suite("Attach coordinator: remote")
struct RemoteAttachTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The remote host's `uname -n`, as its discovery reports it.
  static let remoteNode = "Fixture-Remote.local"
  /// The remote host. It shares the fixture host id, so the fixture session's key is its own.
  static let remoteHost = HostConfig(
    id: Support.host.id, displayName: "Remote", mode: .ssh, sshDestination: "fixture-remote")
  /// The session `$3` on the remote host's server.
  static let session = Support.session()
  /// The attach target.
  static let target = AttachTarget(host: remoteHost, session: session)
  /// The launch tab's connection.
  static let launchConnection = ITerm2API.TmuxConnection(
    connectionID: Support.connection, owningSessionID: Support.gateway)
  /// What the identity check prints through a connection to the remote session.
  static let remoteIdentity = Support.identityOutput(for: session.key, host: remoteNode)

  /// iTerm2's windows while the launch tab is open: its window, then the fixture windows with
  /// the connection's tabs.
  static let withLaunchTab = ITerm2API.ListSessionsResponse(
    windows: [
      .init(
        windowID: "w9",
        tabs: [
          .init(
            tabID: "t9",
            root: ITerm2API.SplitTreeNode(
              vertical: false, links: [.session(.init(uniqueIdentifier: Support.gateway))]),
            tmuxWindowID: "-1")
        ])
    ] + Support.sessions.windows)

  /// The fakes of one test.
  struct Harness {
    /// iTerm2's fake.
    let fake: FakeITerm2Integration
    /// The wrapper the coordinator talks to.
    let iTerm2: InstrumentedITerm2
    /// Discovery, reporting the remote node name.
    let discovery: FakeDiscovery
    /// The launch store.
    let store: FakeLaunchStore
    /// The updates.
    let log: UpdateLog
    /// The coordinator.
    let coordinator: AttachCoordinator
  }

  /// A coordinator for the remote host whose iTerm2 starts from a successful launch (the
  /// identity naming the remote node, the launch tab listed) changed by `script`. With
  /// `existingAttachments`, its attach check and `detach(session:on:)` use an index whose
  /// timeouts never fire, so answers decide every outcome; otherwise the check is off.
  static func harness(
    clock: any VirtualTimeClock = ManualAttachClock(),
    existingAttachments: Bool = false,
    script: ((inout FakeITerm2Integration.Script) -> Void)? = nil
  ) -> Harness {
    var fakeScript = Support.successScript(for: session)
    fakeScript.sendTmuxCommand = .init(.success(remoteIdentity))
    fakeScript.listSessions = .init(.success(withLaunchTab))
    script?(&fakeScript)
    let fake = FakeITerm2Integration(script: fakeScript)
    let iTerm2 = InstrumentedITerm2(fake, clock: clock)
    let discovery = FakeDiscovery(.ok([session]), nodeName: remoteNode)
    let store = FakeLaunchStore()
    let log = UpdateLog()
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, clock: clock,
      existingAttachments: existingAttachments ? .index(Support.patientIndex(iTerm2)) : .off,
      log: log)
    return Harness(
      fake: fake, iTerm2: iTerm2, discovery: discovery, store: store, log: log,
      coordinator: coordinator)
  } // End of func harness(clock:existingAttachments:script:)

  /// `count` empty connection listings, then the launch tab's connection for good.
  static func connectionAfter(_ count: Int)
    -> FakeITerm2Integration.Responses<
      [ITerm2API.TmuxConnection]
    >
  {
    .init(.success([launchConnection]), queued: Array(repeating: .success([]), count: count))
  }

  /// Advances `clock` by 200 ms whenever the coordinator sleeps, until `done` holds.
  static func drive(_ clock: GatedAttachClock, until done: () async -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(30)
    while await !done() {
      guard ContinuousClock.now < deadline else {
        Issue.record("timed out driving the clock")
        throw CancellationError()
      }
      if clock.waiting > 0 {
        clock.advance(by: .milliseconds(200))
      } else {
        try await Task.sleep(for: .milliseconds(1))
      }
    } // End of loop driving the clock
  } // End of func drive(_:until:)

  /// Whether `call` is a `createTab`.
  static func isCreateTab(_ call: FakeITerm2Integration.Call) -> Bool {
    if case .createTab = call { return true }
    return false
  }

  // MARK: - Attach

  /// A remote attach writes an SSH request (the host's destination, the session's identity),
  /// opens the same launch tab as a local one, and confirms within its budget: no
  /// `stillWaiting`, and the launch tab is never listed for it.
  @Test func attachesARemoteSession() async throws {
    let harness = Self.harness()
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.timings.stillWaiting == nil)
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .confirmed(connectionID: Support.connection),
      ])
    let request = try #require(harness.store.snapshot.written.first)
    #expect(request.host == .ssh(destination: "fixture-remote"))
    #expect(request.sessionID == Self.session.key.sessionID)
    #expect(request.expectedServerPID == Self.session.key.server.pid)
    #expect(request.expectedSessionCreated == Self.session.createdAt)
    let calls = await harness.fake.calls
    let tab = calls.compactMap { call -> ITerm2API.CreateTabRequest? in
      if case .createTab(let request) = call { return request }
      return nil
    }
    #expect(
      tab.first?.customProfileProperties
        == ITerm2API.ProfileProperty.customCommand(
          Support.helper.attachCommandLine(for: result.launchID))
        + [ITerm2API.ProfileProperty.closeSessionsOnEnd(true)])
    #expect(!calls.contains(.listSessions))
    #expect(result.activation == .activated(tabID: "t3"))
  } // End of func attachesARemoteSession()

  /// The identity check must name the remote host's node name, not only its server and
  /// session: an answer from another Mac (here this Mac's node name) with the same socket,
  /// pid, start time and session is a mismatch, detached once the launch tab is 10 s old.
  @Test func identityMustNameTheRemoteHost() async throws {
    let clock = ManualAttachClock()
    let harness = Self.harness(clock: clock) { script in
      script.sendTmuxCommand = .init(.success(Support.identityOutput(for: Self.session.key)))
    }
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.failure == .identityMismatch)
    let detach = harness.iTerm2.sent.filter { $0.command == ConnectionIdentity.detachCommand }
    #expect(detach.map(\.at) == [.seconds(10)])
  } // End of func identityMustNameTheRemoteHost()

  /// No connection within 20 s while the launch tab stays open: the attach publishes
  /// `stillWaiting` (at 20 s, not success) and keeps polling once a second; when the
  /// connection appears later its identity is checked and the attach is confirmed.
  @Test func reportsStillWaitingThenConfirms() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = Self.connectionAfter(106)
    }
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .stillWaiting(sessionID: Support.gateway), .confirmed(connectionID: Support.connection),
      ])
    #expect(result.timings.stillWaiting == .seconds(20))
    #expect(result.timings.connected == .seconds(26))
    #expect(harness.store.snapshot.discarded.isEmpty)
    let listings = await harness.fake.calls.filter { $0 == .listSessions }.count
    #expect(listings == 6)
  } // End of func reportsStillWaitingThenConfirms()

  /// A local attach keeps its 15 s budget and never reports `stillWaiting`: without a
  /// connection it times out, and never lists iTerm2's sessions to look for its tab.
  @Test func localAttachesNeverWait() async throws {
    let harness = Self.harness { script in script.listTmuxConnections = .init(.success([])) }
    let local = AttachTarget(host: Support.host, session: Self.session)
    let result = await harness.coordinator.attach(local)
    #expect(result.failure == .timedOut)
    #expect(
      harness.log.states == [.requested, .launched(sessionID: Support.gateway), .failed(.timedOut)])
    #expect(result.timings.finished.map { $0 < .seconds(16) } == true)
    #expect(!(await harness.fake.calls.contains(.listSessions)))
  } // End of func localAttachesNeverWait()

  /// While waiting, the helper reports (ssh failed: authentication): the attach fails with the
  /// helper's failure after `stillWaiting`, never confirmed.
  @Test func stillWaitingThenTheHelperFails() async throws {
    let harness = Self.harness { script in script.listTmuxConnections = .init(.success([])) }
    harness.store.update { state in
      state.makeResult = { Support.result(for: $0, failure: .sshFailed(.authFailed)) }
      state.resultAfterTakes = 103
    }
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.failure == .helperFailed(.sshFailed(.authFailed)))
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .stillWaiting(sessionID: Support.gateway), .failed(.helperFailed(.sshFailed(.authFailed))),
      ])
  } // End of func stillWaitingThenTheHelperFails()

  /// At the budget the launch tab is already gone (its helper ended) and no result arrives
  /// within the closed-tab result budget (10 s): `timedOut`, with no `stillWaiting` and the
  /// request withdrawn.
  @Test func aClosedTabWithoutAResultTimesOut() async throws {
    let clock = ManualAttachClock()
    let harness = Self.harness(clock: clock) { script in
      script.listTmuxConnections = .init(.success([]))
      script.listSessions = .init(.success(Support.sessions))
    }
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.failure == .timedOut)
    #expect(AttachCoordinator.Configuration().closedTabResultBudget == .seconds(10))
    #expect(clock.elapsed == .seconds(30))
    #expect(
      harness.log.states == [.requested, .launched(sessionID: Support.gateway), .failed(.timedOut)])
    #expect(harness.store.snapshot.discarded == [result.launchID])
  } // End of func aClosedTabWithoutAResultTimesOut()

  /// The launch tab closes while waiting (the user closed it, the helper saw SIGHUP): the
  /// attach takes the helper's result and fails with it, also when the result comes 7 s after
  /// the tab left iTerm2's listing (iTerm2 ended ssh about 5 s after a forced close in the
  /// real runs, past the 5 s an ordinary result wait allows).
  @Test(arguments: [0, 35])
  func aTabClosedWhileWaitingEndsWithItsResult(laterPolls: Int) async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(.success([]))
      script.listSessions = .init(
        .success(Support.sessions), queued: [.success(Self.withLaunchTab)])
    }
    harness.store.update { state in
      state.makeResult = { Support.result(for: $0, failure: .childSignaled(SIGHUP)) }
      state.resultAfterTakes = 102 + laterPolls
    }
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.failure == .helperFailed(.childSignaled(SIGHUP)))
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .stillWaiting(sessionID: Support.gateway), .failed(.helperFailed(.childSignaled(SIGHUP))),
      ])
  } // End of func aTabClosedWhileWaitingEndsWithItsResult(laterPolls:)

  /// A launch tab that keeps waiting is watched until the wait limit (5 minutes from launch),
  /// then the attach ends `waitLimitReached` with its request withdrawn.
  @Test func stopsWatchingAtTheWaitLimit() async throws {
    let clock = ManualAttachClock()
    let harness = Self.harness(clock: clock) { script in
      script.listTmuxConnections = .init(.success([]))
    }
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.failure == .waitLimitReached)
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .stillWaiting(sessionID: Support.gateway), .failed(.waitLimitReached),
      ])
    #expect(clock.elapsed == .seconds(300))
    #expect(harness.store.snapshot.discarded == [result.launchID])
    #expect(AttachCoordinator.Configuration().remoteWaitLimit == .seconds(300))
    #expect(AttachCoordinator.Configuration().remoteConfirmationBudget == .seconds(20))
  } // End of func stopsWatchingAtTheWaitLimit()

  /// A second caller arriving while the attach is `stillWaiting` joins it (no second tab), and
  /// both get the confirmation once the connection appears.
  @Test(.timeLimit(.minutes(1)))
  func aCallerJoiningWhileWaitingSharesTheLaunch() async throws {
    let clock = GatedAttachClock()
    let harness = Self.harness(clock: clock) { script in
      script.listTmuxConnections = .init(.success([]))
    }
    let first = Task { await harness.coordinator.attach(Self.target) }
    try await Self.drive(clock) {
      harness.log.states.contains(.stillWaiting(sessionID: Support.gateway))
    }
    let second = Task { await harness.coordinator.attach(Self.target) }
    try await waitUntil("the second caller joined") {
      await harness.coordinator.waiterCount(for: Self.session.key) == 2
    }
    await harness.fake.updateScript { script in
      script.listTmuxConnections = .init(.success([Self.launchConnection]))
    }
    try await Self.drive(clock) {
      harness.log.states.last == .confirmed(connectionID: Support.connection)
    }
    let results = await [first.value, second.value]
    #expect(results.allSatisfy(\.isConfirmed) && results[0] == results[1])
    #expect(await harness.fake.calls.filter(Self.isCreateTab).count == 1)
    #expect(
      harness.log.states.filter { $0 == .stillWaiting(sessionID: Support.gateway) }.count == 1)
  } // End of func aCallerJoiningWhileWaitingSharesTheLaunch()

  /// Cancelling the only caller while `stillWaiting` ends the attach `cancelled` (the request
  /// withdrawn); the launch tab is left to the user.
  @Test(.timeLimit(.minutes(1)))
  func cancellingWhileWaitingEndsTheAttach() async throws {
    let clock = GatedAttachClock()
    let harness = Self.harness(clock: clock) { script in
      script.listTmuxConnections = .init(.success([]))
    }
    let attach = Task { await harness.coordinator.attach(Self.target) }
    try await Self.drive(clock) {
      harness.log.states.contains(.stillWaiting(sessionID: Support.gateway))
    }
    attach.cancel()
    let result = await attach.value
    #expect(result.failure == .cancelled)
    #expect(result.gatewaySessionID == Support.gateway)
    #expect(harness.store.snapshot.discarded == [result.launchID])
    #expect(!(await harness.fake.calls.contains { if case .close = $0 { true } else { false } }))
  } // End of func cancellingWhileWaitingEndsTheAttach()

  // MARK: - Existing remote attachments

  /// The remote session is attached in this Mac's iTerm2 already (the user's own tab running
  /// `ssh … tmux -CC`): its connection answers the remote node name and server, the index maps
  /// it for the remote host, and the attach focuses it, opening nothing.
  @Test func focusesAnExistingRemoteAttachment() async throws {
    let user = ITerm2API.TmuxConnection(connectionID: "user", owningSessionID: "user-tab")
    let harness = Self.harness(existingAttachments: true) { script in
      script.listTmuxConnections = .init(.success([user]))
      script.listSessions = .init(
        .success(
          ITerm2API.ListSessionsResponse(windows: [
            .init(
              windowID: "w5",
              tabs: [
                .init(
                  tabID: "t5", root: Support.leaves(2), tmuxWindowID: "0",
                  tmuxConnectionID: "user")
              ])
          ])))
    }
    harness.iTerm2.setAnswers([.success(Self.remoteIdentity)], for: "user")
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.state == .focused(connectionID: "user"))
    #expect(result.gatewaySessionID == "user-tab")
    #expect(result.activation == .activated(tabID: "t5"))
    #expect(result.existingAttachments == .init(mapped: 1))
    #expect(harness.log.states == [.requested, .focused(connectionID: "user")])
    let calls = await harness.fake.calls
    #expect(calls.filter(Self.isCreateTab).isEmpty && !calls.contains(.ensureRunning))
    #expect(harness.store.snapshot.written.isEmpty)
  } // End of func focusesAnExistingRemoteAttachment()

  /// A connection showing the same socket path, pid, start time and session, but on another
  /// Mac (this Mac's node name), is not the remote session: it stays `unknown` and the attach
  /// launches.
  @Test func anotherMacsSessionIsNotFocused() async throws {
    let other = ITerm2API.TmuxConnection(connectionID: "other", owningSessionID: "other-tab")
    let harness = Self.harness(existingAttachments: true) { script in
      script.listTmuxConnections = .init(
        .success([other, Self.launchConnection]), queued: [.success([other])])
    }
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: Self.session.key))], for: "other")
    let result = await harness.coordinator.attach(Self.target)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.existingAttachments == .init(unknown: 1))
    #expect(harness.store.snapshot.written.first?.host == .ssh(destination: "fixture-remote"))
  } // End of func anotherMacsSessionIsNotFocused()

  /// `detach(session:on:)` for the remote host: it discovers the remote host, maps the user's
  /// connection by the remote node name, waits until its tab is 10 s old (from the snapshot),
  /// checks the identity again and sends `detach-client` bound to that tab.
  @Test func detachesARemoteSessionBySession() async throws {
    let user = ITerm2API.TmuxConnection(connectionID: "user", owningSessionID: "user-tab")
    let harness = Self.harness(existingAttachments: true) { script in
      script.listTmuxConnections = .init(
        .success([]), queued: Array(repeating: .success([user]), count: 4))
    }
    harness.iTerm2.setAnswers([.success(Self.remoteIdentity)], for: "user")
    let result = await harness.coordinator.detach(session: Self.session.key, on: Self.remoteHost)
    #expect(result.outcome == .detached)
    #expect(result.counts == .init(mapped: 1))
    #expect(result.detaches.map(\.connectionID) == ["user"])
    #expect(result.detaches.first?.gatewaySessionID == "user-tab")
    #expect(result.detaches.first?.connectionClosed == true)
    #expect(harness.discovery.calls == 1)
    let detach = harness.iTerm2.sent.filter { $0.command == ConnectionIdentity.detachCommand }
    #expect(detach.map(\.connectionID) == ["user"] && detach.map(\.at) == [.seconds(10)])
    #expect(
      harness.iTerm2.sent.map(\.command) == [
        ConnectionIdentity.command, ConnectionIdentity.command, ConnectionIdentity.detachCommand,
      ])
  } // End of func detachesARemoteSessionBySession()

  /// For the remote host, a connection that answers this Mac's node name is not the remote
  /// session: nothing is attached and nothing is sent but the identity command.
  @Test func detachIgnoresAnotherMacsSession() async throws {
    let other = ITerm2API.TmuxConnection(connectionID: "other", owningSessionID: "other-tab")
    let harness = Self.harness(existingAttachments: true) { script in
      script.listTmuxConnections = .init(.success([other]))
    }
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: Self.session.key))], for: "other")
    let result = await harness.coordinator.detach(session: Self.session.key, on: Self.remoteHost)
    #expect(result.outcome == .nothingAttached)
    #expect(result.counts == .init(unknown: 1))
    #expect(harness.iTerm2.sent.map(\.command) == [ConnectionIdentity.command])
  } // End of func detachIgnoresAnotherMacsSession()
}

/// `AttachmentIndex` with remote hosts (PLAN.md D16, D17): a connection maps to the remote
/// host whose discovery node name equals its `#{host}`, also when this Mac's server has the
/// same socket path; an unconfigured Mac is `unknown`; two SSH entries for one Mac are
/// `ambiguous`; a remote connection that never answers is `stale` after 3 s.
@Suite("Attachment index: remote hosts")
struct RemoteAttachmentIndexTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// This Mac as the index matches it.
  static let local = Support.indexHost
  /// A remote server with the same socket path as this Mac's (the default socket is the same
  /// path on every Mac with the same user id), another pid and start time.
  static let remoteServer = ServerIdentity(
    socketPath: Support.server.socketPath, pid: 777, startTime: 1_792_500_000)
  /// The remote host.
  static let remote = AttachmentIndex.Host(
    hostID: UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!,
    nodeName: "Fixture-Remote.local", servers: [remoteServer])
  /// The same remote Mac configured a second time (another destination for it).
  static let remoteAgain = AttachmentIndex.Host(
    hostID: UUID(uuidString: "00000000-0000-4000-8000-0000000000c3")!,
    nodeName: "Fixture-Remote.local", servers: [remoteServer])

  /// The identity answer for `sessionID` on `server` of the Mac named `host`.
  static func answer(host: String, server: ServerIdentity, sessionID: String = "$5") -> String {
    Support.identityLine(
      host: host, pid: "\(server.pid)", startTime: "\(server.startTime)",
      socketPath: server.socketPath, sessionID: sessionID) + "\n"
  }

  /// A fake iTerm2 listing `ids` (each owned by `<id>-tab`), with per-connection answers.
  static func iTerm2(
    _ ids: [String],
    clock: GatedAttachClock,
    hanging: Set<String> = []
  ) -> InstrumentedITerm2 {
    var script = FakeITerm2Integration.Script()
    script.listTmuxConnections = .init(
      .success(ids.map { .init(connectionID: $0, owningSessionID: $0 + "-tab") }))
    let fake = FakeITerm2Integration(script: script)
    return InstrumentedITerm2(fake, clock: clock, hanging: hanging)
  } // End of func iTerm2(_:clock:hanging:)

  /// Remote and local connections each map to their own host by node name (the remote one
  /// with the remote host's id and server), and a Mac nobody configured stays unknown.
  @Test func mapsRemoteConnectionsByNodeName() async throws {
    let clock = GatedAttachClock()
    let iTerm2 = Self.iTerm2(["remote", "local", "sirio"], clock: clock)
    iTerm2.setAnswers(
      [.success(Self.answer(host: "Fixture-Remote.local", server: Self.remoteServer))],
      for: "remote")
    iTerm2.setAnswers(
      [.success(Self.answer(host: Support.nodeName, server: Support.server, sessionID: "$3"))],
      for: "local")
    iTerm2.setAnswers(
      [.success(Self.answer(host: "Fixture-Sirio.local", server: Self.remoteServer))],
      for: "sirio")
    let index = AttachmentIndex(iTerm2: iTerm2, clock: clock)
    let snapshot = try await index.snapshot(of: [Self.local, Self.remote])
    let remoteKey = SessionKey(
      hostID: Self.remote.hostID, server: Self.remoteServer, sessionID: TmuxSessionID("$5")!)
    #expect(
      snapshot.attachments == [
        .init(key: remoteKey, connectionID: "remote", owningSessionID: "remote-tab"),
        .init(key: Support.session().key, connectionID: "local", owningSessionID: "local-tab"),
      ])
    #expect(snapshot.unmapped.map(\.connectionID) == ["sirio"])
    #expect(snapshot.unmapped.first?.kind == .unknown)
    #expect(snapshot.counts == .init(mapped: 2, unknown: 1))
  } // End of func mapsRemoteConnectionsByNodeName()

  /// A remote answer whose server only this Mac has (same socket path, this Mac's pid and
  /// start time) is not mapped to either host: the node name and the server must match the
  /// same host.
  @Test func needsTheNodeNameAndServerOfOneHost() async throws {
    let clock = GatedAttachClock()
    let iTerm2 = Self.iTerm2(["mixed"], clock: clock)
    iTerm2.setAnswers(
      [.success(Self.answer(host: "Fixture-Remote.local", server: Support.server))], for: "mixed")
    let snapshot = try await AttachmentIndex(iTerm2: iTerm2, clock: clock).snapshot(
      of: [Self.local, Self.remote])
    #expect(snapshot.attachments.isEmpty)
    #expect(snapshot.counts == .init(unknown: 1))
  } // End of func needsTheNodeNameAndServerOfOneHost()

  /// The same remote Mac configured twice (two SSH destinations reaching it) makes its
  /// connection ambiguous, counted with both candidates and never guessed.
  @Test func twoEntriesForOneRemoteMacAreAmbiguous() async throws {
    let clock = GatedAttachClock()
    let iTerm2 = Self.iTerm2(["remote"], clock: clock)
    iTerm2.setAnswers(
      [.success(Self.answer(host: "Fixture-Remote.local", server: Self.remoteServer))],
      for: "remote")
    let snapshot = try await AttachmentIndex(iTerm2: iTerm2, clock: clock).snapshot(
      of: [Self.local, Self.remote, Self.remoteAgain])
    #expect(snapshot.attachments.isEmpty)
    #expect(snapshot.unmapped.first?.kind == .ambiguous)
    #expect(snapshot.unmapped.first?.candidateCount == 2)
    #expect(snapshot.counts == .init(ambiguous: 1))
  } // End of func twoEntriesForOneRemoteMacAreAmbiguous()

  /// A remote connection that never answers (its ssh link stalled) is stale after the 3 s
  /// timeout, while the other remote connection maps.
  @Test(.timeLimit(.minutes(1)))
  func aSilentRemoteConnectionIsStale() async throws {
    let clock = GatedAttachClock()
    let iTerm2 = Self.iTerm2(["silent", "remote"], clock: clock, hanging: ["silent"])
    iTerm2.setAnswers(
      [.success(Self.answer(host: "Fixture-Remote.local", server: Self.remoteServer))],
      for: "remote")
    let index = AttachmentIndex(iTerm2: iTerm2, clock: clock)
    let snapshot = Task { try await index.snapshot(of: [Self.local, Self.remote]) }
    try await waitUntil("the silent connection hangs and both timeouts wait") {
      iTerm2.hangingNow == 1 && clock.waiting >= 1
    }
    clock.advance(by: .seconds(3))
    let result = try await snapshot.value
    #expect(result.attachments.map(\.connectionID) == ["remote"])
    #expect(result.unmapped.map(\.connectionID) == ["silent"])
    #expect(result.unmapped.first?.staleReason == .timedOut)
    #expect(result.counts == .init(mapped: 1, stale: 1))
  } // End of func aSilentRemoteConnectionIsStale()
}
