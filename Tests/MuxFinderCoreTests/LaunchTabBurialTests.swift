import Foundation
import Testing

@testable import MuxFinderCore

/// The coordinator's part of hiding the launch tab once attached (PLAN.md D29): the bury after
/// a confirmed and activated attach (once per launch, never otherwise), the race with the
/// helper's restore closed by order, the watch over buried tabs (the file-only peek, its timer
/// and triggers, the restore, the close of a dead tab), and "Show tab" around a pending bury.
/// Fakes for iTerm2 (with buried state), discovery, the launch store and the clocks; nothing
/// touches iTerm2, tmux or the launch directory.
@Suite("Attach coordinator: launch tab bury")
struct LaunchTabBurialTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The fakes of one test.
  struct Harness {
    /// The session attached first.
    let session: DiscoveredSession
    /// iTerm2's fake (every call is logged here).
    let fake: FakeITerm2Integration
    /// The wrapper the coordinator talks to.
    let iTerm2: InstrumentedITerm2
    /// Discovery.
    let discovery: FakeDiscovery
    /// The launch store.
    let store: FakeLaunchStore
    /// The coordinator's clock.
    let clock: ManualAttachClock
    /// The updates.
    let log: UpdateLog
    /// Diagnostics.
    let diagnostics: DiagnosticsLog
    /// The coordinator.
    let coordinator: AttachCoordinator

    /// The attach target.
    var target: AttachTarget { AttachTarget(host: Support.host, session: session) }
  }

  /// A harness whose iTerm2 follows a successful launch script changed by `script`, whose
  /// discovery reports `sessions` (the fixture session by default; held until released when
  /// `gated`), with the existing-attachment check on when `checksAttachments`, the buried-tab
  /// timer `timer` (off by default) and session creation through `creator`.
  static func harness(
    sessions: [DiscoveredSession] = [Support.session()],
    gated: Bool = false,
    checksAttachments: Bool = false,
    timer: BuriedTabTimer = .off,
    creator: (any SessionCreating)? = nil,
    script: ((inout FakeITerm2Integration.Script) -> Void)? = nil
  ) -> Harness {
    let session = sessions[0]
    var fakeScript = Support.successScript(for: session)
    fakeScript.listSessions = .init(.success(Self.sessionsWithLaunchTab))
    fakeScript.close = .init(.success(.init(statuses: [.ok])))
    script?(&fakeScript)
    let fake = FakeITerm2Integration(script: fakeScript)
    let clock = ManualAttachClock()
    let iTerm2 = InstrumentedITerm2(fake, clock: clock)
    let discovery = FakeDiscovery(.ok(sessions), gated: gated)
    let store = FakeLaunchStore()
    let log = UpdateLog()
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let coordinator = AttachCoordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, helperPath: Support.helper,
      clock: clock,
      existingAttachments: checksAttachments ? .index(Support.patientIndex(iTerm2)) : .off,
      sessionCreator: creator ?? (TmuxCommands() as any SessionCreating), buriedTabTimer: timer,
      diagnostics: diagnostics, onUpdate: { log.record($0) })
    return Harness(
      session: session, fake: fake, iTerm2: iTerm2, discovery: discovery, store: store,
      clock: clock, log: log, diagnostics: diagnostics, coordinator: coordinator)
  } // End of func harness(sessions:gated:checksAttachments:timer:creator:script:)

  /// A window `windowID` holding only the launch tab `gateway`.
  static func launchWindow(_ gateway: String, _ windowID: String) -> ITerm2API.Window {
    ITerm2API.Window(
      windowID: windowID,
      tabs: [
        .init(
          tabID: "\(windowID)-tab",
          root: .init(links: [.session(.init(uniqueIdentifier: gateway))]),
          tmuxWindowID: ITerm2API.Tab.noTmuxWindowID)
      ])
  } // End of static func launchWindow(_:_:)

  /// The fixture's windows plus the launch tab's own window, as iTerm2 lists them right after
  /// `CreateTab`.
  static let sessionsWithLaunchTab = ITerm2API.ListSessionsResponse(
    windows: Support.sessions.windows + [launchWindow(Support.gateway, "w9")])

  /// The launch tab's connection.
  static let launchConnection = ITerm2API.TmuxConnection(
    connectionID: Support.connection, owningSessionID: Support.gateway)

  /// The session ids of the bound buries, in order.
  static func buries(_ calls: [FakeITerm2Integration.Call]) -> [String] {
    calls.compactMap { call in
      if case .buryLaunchTab(let sessionID, _) = call { return sessionID }
      return nil
    }
  }

  /// The session ids of the restores (`setBuried(false, …)`), in order.
  static func restores(_ calls: [FakeITerm2Integration.Call]) -> [String] {
    calls.compactMap { call in
      if case .setBuried(false, let sessionID) = call { return sessionID }
      return nil
    }
  }

  /// The close requests, in order.
  static func closes(_ calls: [FakeITerm2Integration.Call]) -> [ITerm2API.CloseRequest] {
    calls.compactMap { call in
      if case .close(let request) = call { return request }
      return nil
    }
  }

  /// Whether `call` activates the session `sessionID` itself ("Show tab").
  static func activatesSession(_ call: FakeITerm2Integration.Call, _ sessionID: String) -> Bool {
    if case .activate(let request) = call { return request.target == .session(sessionID) }
    return false
  }

  /// The recorded diagnostics details.
  static func details(_ diagnostics: DiagnosticsLog) async -> [String] {
    await diagnostics.events().map(\.detail)
  }

  // MARK: - The bury

  /// A confirmed attach buries its launch tab once, bound to its connection, after the
  /// activation: iTerm2 then lists the tab in `buried_sessions` and in no tab (its window,
  /// which held only it, is gone), the result says `buried`, the coordinator watches the tab,
  /// diagnostics say so without ids, and the helper's result was only peeked at.
  @Test func buriesTheLaunchTabOnceActivated() async throws {
    let harness = Self.harness()
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.activation == .activated(tabID: "t3"))
    #expect(result.burial == .buried)
    #expect(result.timings.buried != nil)
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .confirmed(connectionID: Support.connection),
      ])
    let calls = await harness.fake.calls
    let activation = try #require(
      calls.firstIndex { if case .activate = $0 { true } else { false } })
    let bury = try #require(
      calls.firstIndex(
        of: .buryLaunchTab(sessionID: Support.gateway, connectionID: Support.connection)))
    #expect(activation < bury)
    #expect(Self.buries(calls) == [Support.gateway])
    #expect(Self.restores(calls).isEmpty)
    #expect(await harness.fake.isBuried(Support.gateway))
    let listed = try await harness.fake.listSessions()
    #expect(listed.buriedSessions.map(\.uniqueIdentifier) == [Support.gateway])
    #expect(listed.placement(ofSession: Support.gateway) == nil)
    #expect(!listed.windows.contains { $0.windowID == "w9" })
    #expect(await harness.coordinator.watchedBuriedTabs == [Support.gateway])
    #expect(harness.store.snapshot.peeks == 1)
    let details = await Self.details(harness.diagnostics)
    #expect(details.contains("attach confirmed; launch tab buried"))
    #expect(!details.contains { $0.contains(Support.gateway) || $0.contains(Support.connection) })
  } // End of func buriesTheLaunchTabOnceActivated()

  /// New session and Move here bury their launch tab like an attach.
  @Test func createAndAttachAndMoveHereBury() async throws {
    let creator = FakeSessionCreator(.success(CreateAndAttachTests.created))
    let created = Self.harness(creator: creator)
    let made = await created.coordinator.createAndAttach(CreateAndAttachTests.request)
    #expect(made.attach?.burial == .buried)
    #expect(Self.buries(await created.fake.calls) == [Support.gateway])

    let moving = Self.harness(checksAttachments: true) { script in
      MoveHereCoordinatorTests.launchAfterEmptyCheck(&script)
    }
    let moved = await moving.coordinator.moveHere(
      moving.target, confirmation: .detachOtherClients(of: moving.target.key))
    #expect(moved.isConfirmed)
    #expect(moved.burial == .buried)
    #expect(moving.store.snapshot.written.first?.detachOtherClients == true)
    #expect(Self.buries(await moving.fake.calls) == [Support.gateway])
    #expect(await moving.fake.isBuried(Support.gateway))
  } // End of func createAndAttachAndMoveHereBury()

  /// Concurrent callers share one launch, so exactly one bury goes out and both get its
  /// outcome.
  @Test func coalescedCallersShareOneBury() async throws {
    let harness = Self.harness(gated: true)
    let coordinator = harness.coordinator
    let target = harness.target
    let first = Task { await coordinator.attach(target) }
    let second = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "both callers joined") {
      await coordinator.waiterCount(for: target.key) == 2
    }
    harness.discovery.release()
    let results = await [first.value, second.value]
    #expect(results[0] == results[1])
    #expect(results[0].burial == .buried)
    #expect(Self.buries(await harness.fake.calls).count == 1)
  } // End of func coalescedCallersShareOneBury()

  /// A focus opened no launch tab, so nothing is buried: no bury, no burial outcome.
  @Test func aFocusBuriesNothing() async throws {
    let harness = Self.harness(checksAttachments: true) { script in
      script.listTmuxConnections = .init(.success([AttachFocusTests.userConnection]))
      script.listSessions = .init(.success(AttachFocusTests.userSessions))
    }
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: harness.target.key))], for: "user")
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.state == .focused(connectionID: "user"))
    #expect(result.burial == nil)
    let calls = await harness.fake.calls
    #expect(Self.buries(calls).isEmpty)
    #expect(!calls.contains { if case .setBuried = $0 { true } else { false } })
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
  } // End of func aFocusBuriesNothing()

  /// No tab of the connection within the tab budget (`noTab`) and a failed activation skip the
  /// bury: nothing is sent and nothing is watched; the attach stays confirmed.
  @Test(arguments: [false, true])
  func noTabAndAFailedActivationSkipTheBury(failedActivation: Bool) async throws {
    let harness = Self.harness { script in
      if failedActivation {
        script.activate = .init(.failure(.activateFailed(.invalidOption)))
      } else {
        script.listSessions = .init(.success(.init()))
      }
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.isConfirmed)
    #expect(result.burial == .skipped(failedActivation ? .activationFailed : .noTab))
    #expect(result.timings.buried == nil)
    let calls = await harness.fake.calls
    #expect(Self.buries(calls).isEmpty)
    #expect(!calls.contains { if case .setBuried = $0 { true } else { false } })
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
  } // End of func noTabAndAFailedActivationSkipTheBury(failedActivation:)

  /// A failed attach (no connection within the budget) is never buried.
  @Test func aFailedAttachIsNeverBuried() async throws {
    let harness = Self.harness { script in script.listTmuxConnections = .init(.success([])) }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.failure == .timedOut)
    #expect(result.burial == nil)
    #expect(Self.buries(await harness.fake.calls).isEmpty)
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
  }

  /// A bury that went unanswered (a timeout, a lost connection) is `uncertain` and watched like
  /// a buried tab; one certainly not sent, or refused by iTerm2, is `failed` and not watched.
  /// None is retried (D13), and the attach stays confirmed.
  @Test(arguments: [
    (ITerm2Error.timedOut, LaunchTabBurial.uncertain),
    (.disconnected, .uncertain),
    (.notSent(.timedOut), .failed(.notSent(.timedOut))),
    (.setPropertyFailed(.impossible), .failed(.setPropertyFailed(.impossible))),
  ])
  func buryFailures(_ error: ITerm2Error, _ expected: LaunchTabBurial) async throws {
    let harness = Self.harness { script in
      script.setBuried = .init(.success(()), queued: [.failure(error)])
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.isConfirmed)
    #expect(result.burial == expected)
    let calls = await harness.fake.calls
    #expect(Self.buries(calls) == [Support.gateway])
    #expect(Self.restores(calls).isEmpty)
    let watched = await harness.coordinator.watchedBuriedTabs
    #expect(watched == (expected == .uncertain ? [Support.gateway] : []))
    #expect(await harness.diagnostics.events().last?.detail.contains(expected.kind) == true)
  } // End of func buryFailures(_:_:)

  // MARK: - The race, closed by order

  /// The helper ended (its result written, then its restore) before iTerm2 handled the bury,
  /// so the bury hid a tab whose tmux had ended: the peek right after the answer sees the
  /// result and the tab is restored at once (`restoredAfterEnd`), not watched. The result is
  /// still there for a detach to take.
  @Test func aBuryAfterTheHelpersRestoreIsUndone() async throws {
    let harness = Self.harness()
    let store = harness.store
    harness.iTerm2.setOnBuryHandled { store.finishLatestLaunch() }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.isConfirmed)
    #expect(result.burial == .restoredAfterEnd)
    let calls = await harness.fake.calls
    let bury = try #require(
      calls.firstIndex(of: .setBuried(buried: true, sessionID: Support.gateway)))
    let restore = try #require(
      calls.firstIndex(of: .setBuried(buried: false, sessionID: Support.gateway)))
    #expect(bury < restore)
    #expect(!(await harness.fake.isBuried(Support.gateway)))
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
    #expect(store.snapshot.results[result.launchID] != nil)
    #expect(try store.takeResult(result.launchID)?.succeeded == true)
  } // End of func aBuryAfterTheHelpersRestoreIsUndone()

  /// The bury came before the helper's restore: no result at the peek, so the tab stays buried
  /// and watched. Its helper then ends cleanly (its own restore brings the tab back and the tab
  /// closes): the look sees the result but asks iTerm2 nothing until the helper must have
  /// exited, then finds the tab gone and forgets it, restoring and closing nothing.
  @Test func aBuryBeforeTheHelpersRestoreWaitsForTheHelper() async throws {
    let harness = Self.harness()
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.burial == .buried)
    await harness.fake.restoreAsTheHelperWould(Support.gateway)
    harness.store.finishLatestLaunch()
    await harness.fake.updateScript { $0.listSessions = .init(.success(Support.sessions)) }
    await harness.fake.clearCalls()
    await harness.coordinator.checkBuriedLaunchTabs()
    #expect(await harness.fake.calls.isEmpty, "a clean end waits before asking iTerm2")
    #expect(await harness.coordinator.watchedBuriedTabs == [Support.gateway])
    try await harness.clock.sleep(for: .seconds(15))
    await harness.coordinator.checkBuriedLaunchTabs()
    #expect(await harness.fake.calls == [.listSessions])
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
    #expect(
      await Self.details(harness.diagnostics).last
        == "buried launch tab: ended cleanly; it closed by itself")
  } // End of func aBuryBeforeTheHelpersRestoreWaitsForTheHelper()

  /// The launch tab lost its connection right after the bury (tmux ended, its result not
  /// written yet): it is restored at once (`restoredAfterEnd`). When the connection was gone
  /// before the bury, the bound bury sends nothing (`failed(tmuxConnectionNotOwned)`), and
  /// nothing is restored or watched.
  @Test(arguments: [4, 3])
  func aConnectionThatEnded(ownedListings: Int) async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([]),
        queued: Array(repeating: .success([Self.launchConnection]), count: ownedListings))
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.isConfirmed)
    let calls = await harness.fake.calls
    if ownedListings == 4 {
      #expect(result.burial == .restoredAfterEnd)
      #expect(Self.restores(calls) == [Support.gateway])
      #expect(!(await harness.fake.isBuried(Support.gateway)))
    } else {
      #expect(result.burial == .failed(.tmuxConnectionNotOwned))
      #expect(!calls.contains { if case .setBuried = $0 { true } else { false } })
    }
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
  } // End of func aConnectionThatEnded(ownedListings:)

  // MARK: - Show tab

  /// "Show tab" never runs alongside a pending bury of the same tab: it waits until the bury
  /// and its check ended, then restores the tab and activates it; the tab is watched no more.
  @Test func showLaunchTabWaitsForAPendingBury() async throws {
    let harness = Self.harness()
    let coordinator = harness.coordinator
    let target = harness.target
    harness.iTerm2.holdBuries()
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "the bury is held") {
      harness.iTerm2.heldBuryCount == 1
    }
    let show = Task { await coordinator.showLaunchTab(Support.gateway) }
    try await waitUntil(timeout: .seconds(5), "the show waits behind the bury") {
      await coordinator.lastTabOperationID == 2
    }
    let meanwhile = await harness.fake.calls
    #expect(Self.restores(meanwhile).isEmpty)
    #expect(!meanwhile.contains { Self.activatesSession($0, Support.gateway) })
    harness.iTerm2.releaseBuries()
    let result = await attach.value
    #expect(result.burial == .buried)
    #expect(await show.value == .shown)
    let calls = await harness.fake.calls
    let bury = try #require(
      calls.firstIndex(of: .setBuried(buried: true, sessionID: Support.gateway)))
    let restore = try #require(
      calls.firstIndex(of: .setBuried(buried: false, sessionID: Support.gateway)))
    let activation = try #require(calls.firstIndex { Self.activatesSession($0, Support.gateway) })
    #expect(bury < restore && restore < activation)
    #expect(!(await harness.fake.isBuried(Support.gateway)))
    #expect(await coordinator.watchedBuriedTabs.isEmpty)
  } // End of func showLaunchTabWaitsForAPendingBury()

  /// A refused restore ends "Show tab" with nothing activated.
  @Test func showLaunchTabStopsAtARefusedRestore() async throws {
    let harness = Self.harness()
    _ = await harness.coordinator.attach(harness.target)
    await harness.fake.updateScript {
      $0.setBuried = .init(.failure(.setPropertyFailed(.invalidTarget)))
    }
    await harness.fake.clearCalls()
    #expect(
      await harness.coordinator.showLaunchTab(Support.gateway)
        == .failed(.setPropertyFailed(.invalidTarget)))
    let calls = await harness.fake.calls
    #expect(Self.restores(calls) == [Support.gateway])
    #expect(!calls.contains { Self.activatesSession($0, Support.gateway) })
  } // End of func showLaunchTabStopsAtARefusedRestore()

  // MARK: - Recovery

  /// Two buried launch tabs whose helpers' restores never reached iTerm2: one helper failed,
  /// one ended cleanly. The failed one is restored at once and left visible for its
  /// explanation; the clean one, still listed once its helper must have exited (a dead tab,
  /// S4), is restored and closed (forced, by its own session id), its status and absence
  /// checked. Nothing else is closed.
  @Test func recoveryClosesACleanDeadTabAndLeavesAFailedOneVisible() async throws {
    let (harness, other) = Self.twoSessions()
    let (first, second) = (Self.firstGateway, Self.secondGateway)
    let clean = await harness.coordinator.attach(harness.target)
    let failed = await harness.coordinator.attach(AttachTarget(host: Support.host, session: other))
    #expect(clean.burial == .buried && failed.burial == .buried)
    #expect(await harness.coordinator.watchedBuriedTabs == [first, second])
    harness.store.update { state in
      for request in state.written {
        state.results[request.id] = Support.result(
          for: request, failure: request.id == failed.launchID ? .childExited(1) : nil)
      }
    }
    await harness.fake.clearCalls()
    await harness.coordinator.checkBuriedLaunchTabs()
    var calls = await harness.fake.calls
    #expect(Self.restores(calls) == [second])
    #expect(Self.closes(calls).isEmpty)
    #expect(await harness.coordinator.watchedBuriedTabs == [first])
    try await harness.clock.sleep(for: .seconds(15))
    await harness.coordinator.checkBuriedLaunchTabs()
    calls = await harness.fake.calls
    #expect(Self.restores(calls) == [second, first])
    #expect(Self.closes(calls) == [.init(target: .sessions([first]), force: true)])
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
    let listed = try await harness.fake.listSessions()
    #expect(!listed.allSessionIDs.contains(first))
    #expect(listed.placement(ofSession: second) != nil, "the failed tab stays visible")
    let details = await Self.details(harness.diagnostics)
    #expect(details.contains("buried launch tab: helper failed; restored, left visible"))
    #expect(
      details.contains(
        "buried launch tab: ended cleanly but still listed; restored; Close answered OK, gone"))
  } // End of func recoveryClosesACleanDeadTabAndLeavesAFailedOneVisible()

  /// With the timer off, every attach and every detach looks at the buried tabs first: a
  /// helper failure that appeared since is restored once the next attach (of another session)
  /// starts, and the next once a detach (of a connection not even this coordinator's) starts.
  @Test func everyAttachAndDetachLooks() async throws {
    let (harness, other) = Self.twoSessions()
    _ = await harness.coordinator.attach(harness.target)
    harness.store.finishLatestLaunch(failure: .childExited(1))
    #expect(Self.restores(await harness.fake.calls).isEmpty)
    let second = await harness.coordinator.attach(AttachTarget(host: Support.host, session: other))
    #expect(second.burial == .buried)
    try await waitUntil(timeout: .seconds(5), "the attach's look restored the first tab") {
      Self.restores(await harness.fake.calls) == [Self.firstGateway]
    }
    harness.store.finishLatestLaunch(failure: .childExited(1))
    _ = await harness.coordinator.detach(connectionID: "user", gatewaySessionID: "user-tab")
    try await waitUntil(timeout: .seconds(5), "the detach's look restored the second tab") {
      Self.restores(await harness.fake.calls) == [Self.firstGateway, Self.secondGateway]
    }
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
  } // End of func everyAttachAndDetachLooks()

  /// The first launch tab of `twoSessions()`.
  static let firstGateway = "00000000-0000-4000-8000-0000000000a1"
  /// The second launch tab of `twoSessions()`.
  static let secondGateway = "00000000-0000-4000-8000-0000000000a2"

  /// A harness for two sessions, `$3` (the harness's target) and the returned `$4`, whose
  /// launch tabs open as `firstGateway` and `secondGateway`, in windows of their own, with the
  /// connections `conn-a` and `conn-b` and a tmux tab each.
  static func twoSessions() -> (Harness, DiscoveredSession) {
    let other = Support.session(id: "$4")
    let (first, second) = (Self.firstGateway, Self.secondGateway)
    let harness = Self.harness(sessions: [Support.session(), other]) { script in
      script.createTab = .init(
        .success(.init(status: .ok, windowID: "w8", tabID: 8, sessionID: first)),
        queued: [
          .success(.init(status: .ok, windowID: "w8", tabID: 8, sessionID: first)),
          .success(.init(status: .ok, windowID: "w7", tabID: 7, sessionID: second)),
        ])
      script.listTmuxConnections = .init(
        .success([
          .init(connectionID: "conn-a", owningSessionID: first),
          .init(connectionID: "conn-b", owningSessionID: second),
        ]))
      script.listSessions = .init(
        .success(
          .init(windows: [
            .init(
              windowID: "w2",
              tabs: [.init(tabID: "t3", root: Support.leaves(1), tmuxConnectionID: "conn-a")]),
            .init(
              windowID: "w3",
              tabs: [.init(tabID: "t4", root: Support.leaves(1), tmuxConnectionID: "conn-b")]),
            Self.launchWindow(first, "w8"), Self.launchWindow(second, "w7"),
          ])))
    }
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: Support.session().key))], for: "conn-a")
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: other.key))], for: "conn-b")
    return (harness, other)
  } // End of static func twoSessions()

  /// The helper's result a detach took (no peek can see it any more) reaches the watch: once
  /// the helper must have exited, the dead buried tab is closed.
  @Test func aDetachHandsItsResultToTheWatch() async throws {
    let harness = Self.harness()
    _ = await harness.coordinator.attach(harness.target)
    await harness.fake.updateScript { script in
      script.listTmuxConnections = .init(.success([]), queued: [.success([Self.launchConnection])])
    }
    // The result appears only to the detach's take, never to a peek.
    harness.store.update { state in
      state.resultAfterTakes = state.takes
      state.makeResult = { Support.result(for: $0, failure: nil) }
    }
    let launchID = try #require(harness.store.snapshot.written.first?.id)
    let detach = await harness.coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway, launchID: launchID)
    #expect(detach.isClean)
    #expect(harness.store.snapshot.results.isEmpty)
    try await harness.clock.sleep(for: .seconds(15))
    await harness.coordinator.checkBuriedLaunchTabs()
    let calls = await harness.fake.calls
    #expect(Self.closes(calls) == [.init(target: .sessions([Support.gateway]), force: true)])
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
  } // End of func aDetachHandsItsResultToTheWatch()

  /// A buried tab whose result the sweep removed (older than D14's 120 s) owns no connection:
  /// the next attachment check (here a detach by session) sees that, and the tab is restored
  /// and left visible, never closed.
  @Test func aSweptResultIsRestoredAndLeftVisible() async throws {
    let harness = Self.harness()
    _ = await harness.coordinator.attach(harness.target)
    await harness.fake.updateScript { $0.listTmuxConnections = .init(.success([])) }
    await harness.fake.clearCalls()
    let detach = await harness.coordinator.detach(
      session: harness.target.key, on: Support.host)
    #expect(detach.outcome == .nothingAttached)
    await harness.coordinator.checkBuriedLaunchTabs()
    let calls = await harness.fake.calls
    #expect(Self.restores(calls) == [Support.gateway])
    #expect(Self.closes(calls).isEmpty)
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
    #expect(try await harness.fake.listSessions().placement(ofSession: Support.gateway) != nil)
    #expect(
      await Self.details(harness.diagnostics).contains(
        "buried launch tab: no helper result; restored, left visible"))
  } // End of func aSweptResultIsRestoredAndLeftVisible()

  /// A detach takes the helper's result while the bury still awaits its answer (no peek can see
  /// it any more), and the restore the check after the bury sends is refused. The result the
  /// detach handed over is kept for the watch, so the tab is not stranded buried: after a
  /// helper failure it is restored at once and left visible; after a clean end it waits until
  /// the helper must have exited, then the dead tab, still buried, is restored and closed.
  @Test(arguments: [false, true])
  func aResultTakenDuringTheBuryIsKept(helperFailed: Bool) async throws {
    let harness = Self.harness()
    let coordinator = harness.coordinator
    let target = harness.target
    harness.iTerm2.holdBuries()
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "the bury is held") {
      harness.iTerm2.heldBuryCount == 1
    }
    // The detach's bound check still sees the connection, then it is gone; the first restore
    // is refused, later ones succeed.
    await harness.fake.updateScript { script in
      script.listTmuxConnections = .init(.success([]), queued: [.success([Self.launchConnection])])
      script.setBuried = .init(.success(()), queued: [.failure(.setPropertyFailed(.invalidTarget))])
    }
    let launchID = try #require(
      harness.store.finishLatestLaunch(failure: helperFailed ? .childExited(1) : nil))
    let detach = await coordinator.detach(
      connectionID: Support.connection, gatewaySessionID: Support.gateway, launchID: launchID)
    #expect(detach.connectionClosed)
    #expect(detach.helperResult?.succeeded == !helperFailed)
    #expect(harness.store.snapshot.results.isEmpty, "the detach took the result")
    harness.iTerm2.releaseBuries()
    let result = await attach.value
    #expect(result.burial == .buried)
    if !helperFailed {
      await coordinator.checkBuriedLaunchTabs()
      #expect(Self.restores(await harness.fake.calls) == [Support.gateway])
      #expect(await coordinator.watchedBuriedTabs == [Support.gateway])
      try await harness.clock.sleep(for: .seconds(15))
    }
    await coordinator.checkBuriedLaunchTabs()
    let calls = await harness.fake.calls
    #expect(Self.restores(calls) == [Support.gateway, Support.gateway])
    #expect(
      Self.closes(calls)
        == (helperFailed ? [] : [.init(target: .sessions([Support.gateway]), force: true)]))
    #expect(await coordinator.watchedBuriedTabs.isEmpty)
    let listed = try await harness.fake.listSessions()
    if helperFailed {
      #expect(listed.placement(ofSession: Support.gateway) != nil, "left visible")
    } else {
      #expect(!listed.allSessionIDs.contains(Support.gateway))
    }
  } // End of func aResultTakenDuringTheBuryIsKept(helperFailed:)

  /// The check after the bury sees the tab no longer owning its connection (no result yet) and
  /// its restore is refused: the watch keeps that connection loss, so the tab is restored at
  /// once and left visible instead of waiting, buried, for a result.
  @Test func aConnectionLossSeenAfterTheBuryIsKept() async throws {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(
        .success([]), queued: Array(repeating: .success([Self.launchConnection]), count: 4))
      script.setBuried = .init(
        .success(()), queued: [.success(()), .failure(.setPropertyFailed(.invalidTarget))])
    }
    let result = await harness.coordinator.attach(harness.target)
    #expect(result.burial == .buried)
    await harness.coordinator.checkBuriedLaunchTabs()
    let calls = await harness.fake.calls
    #expect(Self.restores(calls) == [Support.gateway, Support.gateway])
    #expect(Self.closes(calls).isEmpty)
    #expect(await harness.coordinator.watchedBuriedTabs.isEmpty)
    #expect(try await harness.fake.listSessions().placement(ofSession: Support.gateway) != nil)
    #expect(
      await Self.details(harness.diagnostics).contains(
        "buried launch tab: no helper result; restored, left visible"))
  } // End of func aConnectionLossSeenAfterTheBuryIsKept()

  /// An attachment check judges only the tabs watched before it started: its listing (no
  /// connection) was taken before an attach opened and buried its launch tab, and answered
  /// after, so it cannot name that tab's connection, and the tab stays buried and watched.
  @Test func aCheckStartedBeforeABuryLeavesThatTabBuried() async throws {
    let harness = Self.harness()
    let coordinator = harness.coordinator
    let target = harness.target
    await harness.fake.updateScript { script in
      script.listTmuxConnections = .init(.success([Self.launchConnection]), queued: [.success([])])
    }
    harness.iTerm2.holdListings(1)
    let detach = Task { await coordinator.detach(session: target.key, on: Support.host) }
    try await waitUntil(timeout: .seconds(5), "the check's listing is held") {
      harness.iTerm2.heldListingCount == 1
    }
    let result = await coordinator.attach(target)
    #expect(result.burial == .buried)
    #expect(await coordinator.watchedBuriedTabs == [Support.gateway])
    harness.iTerm2.releaseListings()
    #expect(await detach.value.outcome == .nothingAttached)
    await coordinator.checkBuriedLaunchTabs()
    let calls = await harness.fake.calls
    #expect(Self.restores(calls).isEmpty)
    #expect(await harness.fake.isBuried(Support.gateway))
    #expect(await coordinator.watchedBuriedTabs == [Support.gateway])
  } // End of func aCheckStartedBeforeABuryLeavesThatTabBuried()

  /// The timer: while a buried tab is watched, every interval peeks (file only) at its result
  /// and asks iTerm2 nothing; once the result appeared, the tab is recovered; the first tick
  /// that finds nothing watched stops the timer.
  @Test func theTimerPeeksUntilNothingIsWatched() async throws {
    let timerClock = GatedAttachClock()
    let harness = Self.harness(timer: .clock(timerClock))
    let coordinator = harness.coordinator
    _ = await coordinator.attach(harness.target)
    try await waitUntil(timeout: .seconds(5), "the timer sleeps") { timerClock.waiting == 1 }
    let peeks = harness.store.snapshot.peeks
    let callCount = await harness.fake.calls.count
    timerClock.advance(by: .seconds(2))
    try await waitUntil(timeout: .seconds(5), "the first tick") {
      await coordinator.buriedTabChecks == 1 && timerClock.waiting == 1
    }
    #expect(harness.store.snapshot.peeks == peeks + 1)
    #expect(await harness.fake.calls.count == callCount, "a tick without a result is file only")
    harness.store.finishLatestLaunch(failure: .childExited(1))
    timerClock.advance(by: .seconds(2))
    try await waitUntil(timeout: .seconds(5), "the recovery restored the tab") {
      let restored = Self.restores(await harness.fake.calls) == [Support.gateway]
      let watched = await coordinator.watchedBuriedTabs
      return restored && watched.isEmpty
    }
    try await waitUntil(timeout: .seconds(5), "the timer sleeps again") { timerClock.waiting == 1 }
    timerClock.advance(by: .seconds(2))
    try await waitUntil(timeout: .seconds(5), "the timer stopped") {
      await coordinator.buriedTabTimerTask == nil && timerClock.waiting == 0
    }
  } // End of func theTimerPeeksUntilNothingIsWatched()

  /// The coordinator watches at most the latest 64 buried tabs, like its launches.
  @Test func watchesTheLatest64BuriedTabs() async {
    let harness = Self.harness()
    for number in 0..<65 {
      await harness.coordinator.rememberBuriedTab(
        .init(
          launchID: LaunchToken(), gatewaySessionID: "gateway-\(number)",
          connectionID: "connection-\(number)"))
    }
    let watched = await harness.coordinator.watchedBuriedTabs
    #expect(watched.count == AttachCoordinator.rememberedBuriedTabs)
    #expect(watched.first == "gateway-1")
    #expect(watched.last == "gateway-64")
  } // End of func watchesTheLatest64BuriedTabs()

  // MARK: - The fake's buried state

  /// `FakeITerm2Integration` keeps iTerm2's buried state over its scripted listings: a restore
  /// of a session that is not buried changes nothing (S2); a bury moves it out of its tab, the
  /// window closing with its only tab, into `buried_sessions` (S3), a second bury changes
  /// nothing, a pane buried out of a split leaves the other pane; a restore brings it back in a
  /// new window (S8); a refused bury changes nothing; a closed session is listed nowhere.
  @Test func theFakeKeepsBuriedState() async throws {
    var script = FakeITerm2Integration.Script()
    let listing = ITerm2API.ListSessionsResponse(windows: [
      .init(
        windowID: "w1",
        tabs: [
          .init(
            tabID: "t1",
            root: .init(links: [
              .session(.init(uniqueIdentifier: "a")),
              .node(.init(links: [.session(.init(uniqueIdentifier: "b"))])),
            ]))
        ]),
      Self.launchWindow("gateway", "w2"),
    ])
    script.listSessions = .init(.success(listing))
    script.listTmuxConnections = .init(
      .success([.init(connectionID: "c", owningSessionID: "gateway")]))
    script.close = .init(.success(.init(statuses: [.ok])))
    let fake = FakeITerm2Integration(script: script)
    try await fake.setBuried(false, sessionID: "gateway")
    #expect(try await fake.listSessions() == listing)
    try await fake.buryLaunchTab(sessionID: "gateway", ifOwnsTmuxConnection: "c")
    var listed = try await fake.listSessions()
    #expect(listed.windows.map(\.windowID) == ["w1"])
    #expect(listed.buriedSessions == [.init(uniqueIdentifier: "gateway")])
    try await fake.setBuried(true, sessionID: "gateway")
    #expect(try await fake.listSessions() == listed)
    try await fake.setBuried(true, sessionID: "b")
    listed = try await fake.listSessions()
    #expect(listed.windows.first?.tabs.first?.sessions.map(\.uniqueIdentifier) == ["a"])
    #expect(Set(listed.buriedSessions.compactMap(\.uniqueIdentifier)) == ["gateway", "b"])
    try await fake.setBuried(false, sessionID: "gateway")
    listed = try await fake.listSessions()
    #expect(listed.placement(ofSession: "gateway")?.window.windowID == "fake-restored-window-1")
    #expect(listed.buriedSessions == [.init(uniqueIdentifier: "b")])
    await fake.updateScript { $0.setBuried = .init(.failure(.setPropertyFailed(.invalidTarget))) }
    await #expect(throws: ITerm2Error.setPropertyFailed(.invalidTarget)) {
      try await fake.setBuried(true, sessionID: "a")
    }
    #expect(try await fake.listSessions().placement(ofSession: "a") != nil)
    _ = try await fake.close(.init(target: .sessions(["gateway"]), force: true))
    #expect(!(try await fake.listSessions().allSessionIDs.contains("gateway")))
  } // End of func theFakeKeepsBuriedState()
}
