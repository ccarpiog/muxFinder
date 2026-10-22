import Foundation
import Testing

@testable import MuxFinderCore

/// The coordinator with its existing-attachment check (PLAN.md D16): focusing a session that is
/// already attached in this Mac's iTerm2, the check's failure behavior, and
/// `detach(session:on:)`. Fakes for iTerm2, discovery, the launch store and the clocks; the
/// index's clock is never advanced, so only answers decide its outcomes.
@Suite("Attach coordinator: existing attachments")
struct AttachFocusTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The fakes of one test.
  struct Harness {
    /// The session.
    let session: DiscoveredSession
    /// iTerm2's fake (every call is logged here).
    let fake: FakeITerm2Integration
    /// The wrapper the coordinator talks to (per-connection answers, sent-command times).
    let iTerm2: InstrumentedITerm2
    /// Discovery.
    let discovery: FakeDiscovery
    /// The launch store.
    let store: FakeLaunchStore
    /// The coordinator's clock.
    let clock: ManualAttachClock
    /// The updates.
    let log: UpdateLog
    /// The coordinator.
    let coordinator: AttachCoordinator

    /// The attach target.
    var target: AttachTarget { AttachTarget(host: Support.host, session: session) }
    /// The session key.
    var key: SessionKey { session.key }
  }

  /// A harness whose iTerm2 starts from a successful launch script changed by `script`, with
  /// the index over the same wrapper.
  static func harness(
    holdsSleeps: Bool = false,
    status: HostStatus? = nil,
    script: ((inout FakeITerm2Integration.Script) -> Void)? = nil
  ) -> Harness {
    let session = Support.session()
    var fakeScript = Support.successScript(for: session)
    script?(&fakeScript)
    let fake = FakeITerm2Integration(script: fakeScript)
    let clock = ManualAttachClock(holdsSleeps: holdsSleeps)
    let iTerm2 = InstrumentedITerm2(fake, clock: clock)
    let discovery = FakeDiscovery(status ?? .ok([session]))
    let store = FakeLaunchStore()
    let log = UpdateLog()
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, clock: clock,
      existingAttachments: .index(Support.patientIndex(iTerm2)), log: log)
    return Harness(
      session: session, fake: fake, iTerm2: iTerm2, discovery: discovery, store: store,
      clock: clock, log: log, coordinator: coordinator)
  } // End of func harness(holdsSleeps:status:script:)

  /// A connection `id` owned by `owner`.
  static func connection(_ id: String, _ owner: String) -> ITerm2API.TmuxConnection {
    ITerm2API.TmuxConnection(connectionID: id, owningSessionID: owner)
  }

  /// The user's own attachment of the session: connection `user` in the user's tab.
  static let userConnection = connection("user", "user-tab")

  /// iTerm2's windows while `user` shows the session: a tab of it in window `w5`.
  static let userSessions = ITerm2API.ListSessionsResponse(windows: [
    .init(windowID: "w1", tabs: [.init(tabID: "t1", root: Support.leaves(1), tmuxWindowID: "-1")]),
    .init(
      windowID: "w5",
      tabs: [
        .init(tabID: "t5", root: Support.leaves(2), tmuxWindowID: "0", tmuxConnectionID: "user")
      ]
    ),
  ])

  /// The tmux commands sent, in order.
  static func commands(_ iTerm2: InstrumentedITerm2) -> [String] {
    iTerm2.sent.map(\.command)
  }

  /// The calls of a kind.
  static func count(
    _ calls: [FakeITerm2Integration.Call], _ match: (FakeITerm2Integration.Call) -> Bool
  )
    -> Int
  {
    calls.filter(match).count
  }

  /// Whether `call` is a `createTab`.
  static func isCreateTab(_ call: FakeITerm2Integration.Call) -> Bool {
    if case .createTab = call { return true }
    return false
  }

  // MARK: - Focus

  /// The session is attached already (by the user's own tab): the attach activates that
  /// connection's first tab and opens nothing: no request, no `ensureRunning`, no `CreateTab`.
  @Test func focusesAnExistingAttachment() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(.success([Self.userConnection]))
      script.listSessions = .init(.success(Self.userSessions))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .focused(connectionID: "user"))
    #expect(result.isFocused && result.isAttached && !result.isConfirmed)
    #expect(result.connectionID == "user")
    #expect(result.gatewaySessionID == "user-tab")
    #expect(result.activation == .activated(tabID: "t5"))
    #expect(result.existingAttachments == .init(mapped: 1))
    #expect(result.timings.checked != nil && result.timings.activated != nil)
    #expect(harness.log.states == [.requested, .focused(connectionID: "user")])
    #expect(await harness.coordinator.state(of: harness.key) == .focused(connectionID: "user"))
    let calls = await harness.fake.calls
    #expect(!calls.contains(.ensureRunning))
    #expect(Self.count(calls, Self.isCreateTab) == 0)
    #expect(
      calls.contains(
        .activate(
          .init(
            target: .tab("t5"), orderWindowFront: true, selectTab: true, selectSession: false,
            activateApp: .init(ignoringOtherApps: true)))))
    #expect(Self.commands(harness.iTerm2) == [ConnectionIdentity.command])
    #expect(harness.store.snapshot.written.isEmpty)
    #expect(harness.store.snapshot.discarded.isEmpty)
    #expect(harness.discovery.calls == 1)
  } // End of func focusesAnExistingAttachment()

  /// A focused attachment whose tab never appears is still focused (`noTab`), and still opens
  /// no tab: the index answered "attached", so a duplicate is never opened.
  @Test func focusWithoutATabOpensNothing() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(.success([Self.userConnection]))
      script.listSessions = .init(.success(.init()))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .focused(connectionID: "user"))
    #expect(result.activation == .noTab)
    let calls = await harness.fake.calls
    #expect(Self.count(calls, Self.isCreateTab) == 0)
    #expect(harness.store.snapshot.written.isEmpty)
  } // End of func focusWithoutATabOpensNothing()

  /// The review's finding: between the index's answer and the activation, the user's connection
  /// closed and iTerm2 gave its short id to another tab's connection. The focus is bound to the
  /// owner the index saw, so that tab is not activated, and nothing is opened either (the
  /// session may be attached elsewhere): the attach fails with `attachmentChanged`.
  @Test func focusRefusesAReusedConnectionID() async throws {
    let harness = Self.harness { script in
      // The index's listing and its identity check see the user's tab; then the id is
      // another tab's.
      script.listTmuxConnections = .init(
        .success([Self.connection("user", "someone-else")]),
        queued: [.success([Self.userConnection]), .success([Self.userConnection])])
      script.listSessions = .init(.success(Self.userSessions))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .attachmentChanged)
    #expect(result.activation == nil)
    #expect(result.connectionID == nil && result.gatewaySessionID == nil)
    #expect(result.existingAttachments == .init(mapped: 1))
    #expect(harness.log.states == [.requested, .failed(.attachmentChanged)])
    let calls = await harness.fake.calls
    #expect(
      calls.contains(.activateOwnedTmuxTab(connectionID: "user", owningSessionID: "user-tab")))
    #expect(!calls.contains { if case .activate = $0 { return true } else { return false } })
    #expect(!calls.contains(.ensureRunning))
    #expect(Self.count(calls, Self.isCreateTab) == 0)
    #expect(harness.store.snapshot.written.isEmpty)
  } // End of func focusRefusesAReusedConnectionID()

  /// With two attachments of the session, one whose id was reused before the activation is
  /// skipped and the other one is focused.
  @Test func focusSkipsAnAttachmentWhoseIDWasReused() async throws {
    let second = Self.connection("user-2", "user-tab-2")
    let sessions = ITerm2API.ListSessionsResponse(windows: [
      .init(
        windowID: "w5",
        tabs: [
          .init(tabID: "t5", root: Support.leaves(1), tmuxWindowID: "0", tmuxConnectionID: "user")
        ]),
      .init(
        windowID: "w6",
        tabs: [
          .init(tabID: "t6", root: Support.leaves(1), tmuxWindowID: "0", tmuxConnectionID: "user-2")
        ]),
    ])
    let harness = Self.harness { script in
      // The index's listing and both identity checks see both; then `user` is another tab's.
      script.listTmuxConnections = .init(
        .success([Self.connection("user", "someone-else"), second]),
        queued: Array(repeating: .success([Self.userConnection, second]), count: 3))
      script.listSessions = .init(.success(sessions))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user-2")
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .focused(connectionID: "user-2"))
    #expect(result.gatewaySessionID == "user-tab-2")
    #expect(result.activation == .activated(tabID: "t6"))
    #expect(result.existingAttachments == .init(mapped: 2))
    #expect(harness.log.states == [.requested, .focused(connectionID: "user-2")])
    let calls = await harness.fake.calls
    let activated = calls.compactMap { call -> ITerm2API.ActivateRequest.Target? in
      if case .activate(let request) = call { return request.target }
      return nil
    }
    #expect(activated == [.tab("t6")])
    #expect(Self.count(calls, Self.isCreateTab) == 0)
  } // End of func focusSkipsAnAttachmentWhoseIDWasReused()

  /// Two concurrent attaches of an attached session share one check and one focus.
  @Test func concurrentAttachesShareOneFocus() async throws {
    let session = Support.session()
    var script = Support.successScript(for: session)
    script.listTmuxConnections = .init(.success([Self.userConnection]))
    script.listSessions = .init(.success(Self.userSessions))
    let fake = FakeITerm2Integration(script: script)
    let clock = ManualAttachClock()
    let iTerm2 = InstrumentedITerm2(fake, clock: clock)
    iTerm2.setAnswers([.success(Support.identityOutput(for: session.key))], for: "user")
    let discovery = FakeDiscovery(.ok([session]), gated: true)
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: FakeLaunchStore(), clock: clock,
      existingAttachments: .index(Support.patientIndex(iTerm2)))
    let target = AttachTarget(host: Support.host, session: session)
    let first = Task { await coordinator.attach(target) }
    let second = Task { await coordinator.attach(target) }
    try await waitUntil("both callers joined") {
      await coordinator.waiterCount(for: target.key) == 2
    }
    discovery.release()
    let results = await [first.value, second.value]
    #expect(results[0] == results[1])
    #expect(results[0].isFocused)
    #expect(Self.commands(iTerm2) == [ConnectionIdentity.command])
    #expect(Self.count(await fake.calls, Self.isCreateTab) == 0)
  } // End of func concurrentAttachesShareOneFocus()

  /// Connections of other sessions, unknown servers and stale answers do not block the
  /// attach: it launches as before and reports what the check found.
  @Test func launchesWhenTheSessionIsNotAttached() async throws {
    let others = [
      Self.connection("other", "tab-a"), Self.connection("foreign", "tab-b"),
      Self.connection("broken", "tab-c"),
    ]
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)]),
        queued: Array(repeating: .success(others), count: 4))
    }
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: Support.session(id: "$4").key))], for: "other")
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: harness.key, host: "Elsewhere.local"))], for: "foreign")
    harness.iTerm2.setAnswers([.success("garbage")], for: "broken")
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.existingAttachments == .init(mapped: 1, unknown: 1, stale: 1))
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .confirmed(connectionID: Support.connection),
      ])
    let calls = await harness.fake.calls
    #expect(Self.count(calls, Self.isCreateTab) == 1)
    #expect(harness.store.snapshot.written.count == 1)
    #expect(Self.commands(harness.iTerm2).filter { $0 != ConnectionIdentity.command }.isEmpty)
  } // End of func launchesWhenTheSessionIsNotAttached()

  /// When iTerm2's connections cannot be listed, the attach fails before anything is written
  /// or opened; it never risks a duplicate.
  @Test(arguments: [ITerm2Error.timedOut, .notSent(.disconnected), .apiDisabled])
  func checkFailureFailsTheAttach(_ error: ITerm2Error) async throws {
    let harness = Self.harness { script in script.listTmuxConnections = .init(.failure(error)) }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .attachmentCheckFailed(error))
    #expect(result.failure?.detail == error.kind)
    #expect(harness.log.states == [.requested, .failed(.attachmentCheckFailed(error))])
    let calls = await harness.fake.calls
    #expect(calls == [.listTmuxConnections])
    #expect(harness.store.snapshot.written.isEmpty)
  } // End of func checkFailureFailsTheAttach(_:)

  /// iTerm2 not running means nothing can be attached: the attach goes on, launches iTerm2
  /// (`ensureRunning`) and attaches.
  @Test func iTerm2NotRunningProceeds() async throws {
    let harness = Self.harness { script in script.isRunning = false }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.existingAttachments == .init())
    let calls = await harness.fake.calls
    #expect(Array(calls.prefix(2)) == [.listTmuxConnections, .ensureRunning])
  } // End of func iTerm2NotRunningProceeds()

  /// The coordinator's default checks for an existing attachment before launching.
  @Test func theDefaultChecksBeforeLaunching() async throws {
    let session = Support.session()
    var script = Support.successScript(for: session)
    script.listTmuxConnections = .init(
      .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)]),
      queued: [.success([])])
    let fake = FakeITerm2Integration(script: script)
    let coordinator = AttachCoordinator(
      iTerm2: fake, discovery: FakeDiscovery(.ok([session])), store: FakeLaunchStore(),
      helperPath: Support.helper, clock: ManualAttachClock())
    let result = await coordinator.attach(AttachTarget(host: Support.host, session: session))
    #expect(result.isConfirmed)
    #expect(result.existingAttachments == .init())
    #expect(Array(await fake.calls.prefix(2)) == [.listTmuxConnections, .ensureRunning])
  } // End of func theDefaultChecksBeforeLaunching()

  /// A discovery result without a report cannot be matched: the attach fails rather than
  /// launch blind.
  @Test func discoveryWithoutAReportFails() async throws {
    let session = Support.session()
    let fake = FakeITerm2Integration(script: Support.successScript(for: session))
    let coordinator = Support.coordinator(
      iTerm2: fake, discovery: FakeDiscovery(.ok([session]), nodeName: nil),
      store: FakeLaunchStore(), existingAttachments: .index(Support.patientIndex(fake)))
    let result = await coordinator.attach(AttachTarget(host: Support.host, session: session))
    #expect(result.failure == .discoveryFailed("noReport"))
    #expect(await fake.calls.isEmpty)
  } // End of func discoveryWithoutAReportFails()

  // MARK: - detach(session:on:)

  /// A launch this coordinator opened: `detach(session:on:)` waits until its launch tab is
  /// 10 s old (from the launch), checks the identity again, sends `detach-client` bound to the
  /// launch tab, waits for the close and takes the helper's result.
  @Test func detachesAnAttachmentItOpened() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([.init(connectionID: Support.connection, owningSessionID: Support.gateway)]),
        queued: [.success([])])
    }
    let attached = await harness.coordinator.attach(harness.target)
    #expect(attached.isConfirmed)
    let request = try #require(harness.store.snapshot.written.first)
    harness.store.update { $0.results[request.id] = Support.result(for: request, failure: nil) }
    let gateway = [
      ITerm2API.TmuxConnection(
        connectionID: Support.connection, owningSessionID: Support.gateway)
    ]
    await harness.fake.updateScript { script in
      script.listTmuxConnections = .init(
        .success([]), queued: Array(repeating: .success(gateway), count: 4))
    }
    try await harness.clock.sleep(for: .seconds(3))
    let result = await harness.coordinator.detach(session: harness.key, on: Support.host)
    #expect(result.outcome == .detached)
    #expect(result.counts == .init(mapped: 1))
    let detach = try #require(result.detaches.first)
    #expect(result.detaches.count == 1)
    #expect(detach.connectionID == Support.connection)
    #expect(detach.gatewaySessionID == Support.gateway)
    #expect(detach.connectionClosed && detach.isClean)
    #expect(!detach.identityChanged && detach.identityCheckFailure == nil)
    let detachClient = harness.iTerm2.sent.filter { $0.command == ConnectionIdentity.detachCommand }
    #expect(
      detachClient == [
        .init(
          command: ConnectionIdentity.detachCommand, connectionID: Support.connection,
          at: .seconds(10))
      ])
    // Attach check (no connection then), attach identity, index, re-check, detach.
    #expect(
      Self.commands(harness.iTerm2) == [
        ConnectionIdentity.command, ConnectionIdentity.command, ConnectionIdentity.command,
        ConnectionIdentity.detachCommand,
      ])
    let owners = await harness.fake.calls.compactMap { call -> String? in
      if case .sendOwnedTmuxCommand(_, _, let owner) = call { return owner }
      return nil
    }
    #expect(owners.allSatisfy { $0 == Support.gateway })
  } // End of func detachesAnAttachmentItOpened()

  /// Attachments this coordinator did not open (the user's tabs) count their age from the index's
  /// snapshot (here at the call's start, since nothing takes virtual time): both are detached
  /// 10 s after it, in listing order, each bound to its own tab.
  @Test func detachesAttachmentsItDidNotOpen() async throws {
    let second = Self.connection("user-2", "user-tab-2")
    let both = [Self.userConnection, second]
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([]),
        queued: Array(repeating: .success(both), count: 5)
          + Array(repeating: .success([second]), count: 3))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user-2")
    let result = await harness.coordinator.detach(session: harness.key, on: Support.host)
    #expect(result.outcome == .detached)
    #expect(result.detaches.map(\.connectionID) == ["user", "user-2"])
    #expect(result.detaches.map(\.gatewaySessionID) == ["user-tab", "user-tab-2"])
    #expect(result.detaches.allSatisfy { $0.connectionClosed && $0.helperResult == nil })
    let detachClient = harness.iTerm2.sent.filter { $0.command == ConnectionIdentity.detachCommand }
    #expect(detachClient.map(\.connectionID) == ["user", "user-2"])
    #expect(detachClient.map(\.at) == [.seconds(10), .seconds(10)])
    let calls = await harness.fake.calls
    #expect(Self.count(calls, Self.isCreateTab) == 0)
    #expect(!calls.contains { if case .close = $0 { return true } else { return false } })
  } // End of func detachesAttachmentsItDidNotOpen()

  /// The review's finding: a tab this coordinator did not open counts its age from when the
  /// index's snapshot that revealed its connection completed, not from the call. Discovery
  /// takes 4 s and the connection listing 3 s, and the user's connection first appears in that
  /// listing (its tab may have opened meanwhile), so the re-check and `detach-client` go out
  /// 10 s after the snapshot, at 17 s, not 10 s after the call.
  @Test func detachCountsAnUnknownTabFromItsObservation() async throws {
    let session = Support.session()
    var script = Support.successScript(for: session)
    // The index's listing, its identity check, the re-check and `detach-client` see the
    // connection; the close poll does not.
    script.listTmuxConnections = .init(
      .success([]), queued: Array(repeating: .success([Self.userConnection]), count: 4))
    let fake = FakeITerm2Integration(script: script)
    let clock = ManualAttachClock()
    let iTerm2 = InstrumentedITerm2(fake, clock: clock)
    iTerm2.setListingDelay(.seconds(3))
    iTerm2.setAnswers([.success(Support.identityOutput(for: session.key))], for: "user")
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: FakeDiscovery(.ok([session]), takes: .seconds(4), on: clock),
      store: FakeLaunchStore(), clock: clock,
      existingAttachments: .index(Support.patientIndex(iTerm2)))
    let result = await coordinator.detach(session: session.key, on: Support.host)
    #expect(result.outcome == .detached)
    #expect(
      iTerm2.sent == [
        .init(command: ConnectionIdentity.command, connectionID: "user", at: .seconds(7)),
        .init(command: ConnectionIdentity.command, connectionID: "user", at: .seconds(17)),
        .init(command: ConnectionIdentity.detachCommand, connectionID: "user", at: .seconds(17)),
      ])
  } // End of func detachCountsAnUnknownTabFromItsObservation()

  /// When the connection changed owner during the wait, nothing is sent (`notSent`): refused by
  /// the re-check, or by `detach-client`'s own binding check.
  @Test(arguments: [2, 3])
  func ownerChangeIsNotSent(_ ownedListings: Int) async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([Self.connection("user", "someone-else")]),
        queued: Array(repeating: .success([Self.userConnection]), count: ownedListings))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    let result = await harness.coordinator.detach(session: harness.key, on: Support.host)
    #expect(result.outcome == .notSent)
    let detach = try #require(result.detaches.first)
    #expect(detach.certainlyNotSent)
    #expect(!detach.connectionClosed)
    if ownedListings == 2 {
      #expect(detach.identityCheckFailure == .requestFailed(.tmuxConnectionNotOwned))
      #expect(detach.commandError == nil)
    } else {
      #expect(detach.identityCheckFailure == nil)
      #expect(detach.commandError == .tmuxConnectionNotOwned)
    }
    #expect(!Self.commands(harness.iTerm2).contains(ConnectionIdentity.detachCommand))
  } // End of func ownerChangeIsNotSent(_:)

  /// When the connection shows another session by the time of the re-check (the user
  /// reattached that tab elsewhere), nothing is sent (`identityChanged`).
  @Test func identityChangeIsNotSent() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(.success([Self.userConnection]))
    }
    harness.iTerm2.setAnswers(
      [
        .success(Support.identityOutput(for: harness.key)),
        .success(Support.identityOutput(for: Support.session(id: "$7").key)),
      ], for: "user")
    let result = await harness.coordinator.detach(session: harness.key, on: Support.host)
    #expect(result.outcome == .notSent)
    #expect(result.detaches.first?.identityChanged == true)
    #expect(
      Self.commands(harness.iTerm2) == [ConnectionIdentity.command, ConnectionIdentity.command])
  } // End of func identityChangeIsNotSent()

  /// When the re-check is answered through a tmux client not in UTF-8 mode in a way that may
  /// have lost bytes (the user reattached that tab without `-u`), it no longer verifiably shows
  /// the session: nothing is sent (`identityChanged`).
  @Test func nonUTF8RecheckIsNotSent() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(.success([Self.userConnection]))
    }
    harness.iTerm2.setAnswers(
      [
        .success(Support.identityOutput(for: harness.key)),
        .success(
          Support.identityLine(socketPath: "/private/tmp/tmux_501/default", utf8: false) + "\n"),
      ], for: "user")
    let result = await harness.coordinator.detach(session: harness.key, on: Support.host)
    #expect(result.outcome == .notSent)
    #expect(result.detaches.first?.identityChanged == true)
    #expect(
      Self.commands(harness.iTerm2) == [ConnectionIdentity.command, ConnectionIdentity.command])
  } // End of func nonUTF8RecheckIsNotSent()

  /// Nothing attached: no connection for the session (another session's, or none), no server,
  /// or iTerm2 not running. Nothing is sent and nothing is waited for.
  @Test func nothingAttached() async throws {
    let other = Self.harness { script in
      script.listTmuxConnections = .init(.success([Self.userConnection]))
    }
    other.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: Support.session(id: "$4").key))], for: "user")
    let elsewhere = await other.coordinator.detach(session: other.key, on: Support.host)
    #expect(elsewhere.outcome == .nothingAttached)
    #expect(elsewhere.counts == .init(mapped: 1))
    #expect(elsewhere.detaches.isEmpty)
    #expect(other.clock.elapsed == .zero)
    #expect(Self.commands(other.iTerm2) == [ConnectionIdentity.command])

    let idle = Self.harness(status: .noServer)
    let noServer = await idle.coordinator.detach(session: idle.key, on: Support.host)
    #expect(noServer.outcome == .nothingAttached)
    #expect(await idle.fake.calls.isEmpty)

    let stopped = Self.harness { script in script.isRunning = false }
    let notRunning = await stopped.coordinator.detach(session: stopped.key, on: Support.host)
    #expect(notRunning.outcome == .nothingAttached)
    #expect(await stopped.fake.calls == [.listTmuxConnections])
  } // End of func nothingAttached()

  /// A caller cancelled during the age wait sends nothing (`cancelled`).
  @Test func cancelledDuringTheWaitSendsNothing() async throws {
    let harness = Self.harness(holdsSleeps: true) { script in
      script.listTmuxConnections = .init(.success([Self.userConnection]))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    let coordinator = harness.coordinator
    let key = harness.key
    let detach = Task { await coordinator.detach(session: key, on: Support.host) }
    try await waitUntil("the detach is waiting") { harness.clock.heldSleeps > 0 }
    detach.cancel()
    let result = await detach.value
    #expect(result.outcome == .cancelled)
    #expect(result.detaches.first?.cancelled == true)
    #expect(Self.commands(harness.iTerm2) == [ConnectionIdentity.command])
  } // End of func cancelledDuringTheWaitSendsNothing()

  /// The attachments cannot be listed: discovery fails, iTerm2's listing fails, or the host is
  /// not this Mac. Nothing is sent.
  @Test func checkFailures() async throws {
    let broken = Self.harness { script in script.listTmuxConnections = .init(.failure(.timedOut)) }
    let listing = await broken.coordinator.detach(session: broken.key, on: Support.host)
    #expect(listing.outcome == .checkFailed)
    #expect(listing.checkFailure == .attachmentCheckFailed(.timedOut))

    let probe = Self.harness(status: .probeError("fixture"))
    let discovery = await probe.coordinator.detach(session: probe.key, on: Support.host)
    #expect(discovery.outcome == .checkFailed)
    #expect(discovery.checkFailure == .discoveryFailed("probeError"))
    #expect(await probe.fake.calls.isEmpty)

    let remote = Self.harness()
    let ssh = HostConfig(displayName: "Remote", mode: .ssh, sshDestination: "fixture-host")
    let unsupported = await remote.coordinator.detach(session: remote.key, on: ssh)
    #expect(unsupported.checkFailure == .unsupportedHost)
    #expect(remote.discovery.calls == 0)
  } // End of func checkFailures()
}
