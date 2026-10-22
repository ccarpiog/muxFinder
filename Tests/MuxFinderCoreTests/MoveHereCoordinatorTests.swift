import Foundation
import Testing

@testable import MuxFinderCore

/// `AttachCoordinator.moveHere(_:confirmation:)` against fakes (PLAN.md D21): the confirmation
/// it requires, the `-d` request it writes (and that an attach never writes), the outcome when
/// the session is attached in this Mac's iTerm2 already, failures typed like an attach's, and
/// single flight within a kind and across kinds. Nothing touches tmux, iTerm2 or the launch
/// directory.
@Suite("Move here: coordinator")
struct MoveHereCoordinatorTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The fakes of one test.
  struct Harness {
    /// The session.
    let session: DiscoveredSession
    /// iTerm2's fake (every call is logged here).
    let fake: FakeITerm2Integration
    /// The wrapper the coordinator and its index talk to.
    let iTerm2: InstrumentedITerm2
    /// Discovery.
    let discovery: FakeDiscovery
    /// The launch store.
    let store: FakeLaunchStore
    /// The coordinator's clock.
    let clock: any VirtualTimeClock
    /// The updates.
    let log: UpdateLog
    /// The coordinator.
    let coordinator: AttachCoordinator

    /// The target.
    var target: AttachTarget { AttachTarget(host: Support.host, session: session) }
    /// The session key.
    var key: SessionKey { session.key }
    /// The confirmation for this session.
    var confirmation: MoveHereConfirmation { .detachOtherClients(of: session.key) }
  }

  /// A harness whose iTerm2 follows a successful launch script changed by `script`, whose
  /// discovery reports `status` (by default the session, held until `release()` when `gated`)
  /// and whose coordinator checks existing attachments with a patient index over the same
  /// iTerm2 (never asking the connections whose ids are in `leftOut`), or (`checkOff`) has its
  /// check off.
  /// The coordinator runs on a gated clock when `checkOff` or `gatedClock` is set, otherwise on
  /// a manual one. `holdsFirstCreateTab` holds the first `CreateTab` answer until released;
  /// bound commands to `hanging` connections never answer, and the index then times out at
  /// once.
  static func harness(
    status: HostStatus? = nil,
    gated: Bool = false,
    checkOff: Bool = false,
    gatedClock: Bool = false,
    holdsFirstCreateTab: Bool = false,
    hanging: Set<String> = [],
    leftOut: Set<String> = [],
    script: ((inout FakeITerm2Integration.Script) -> Void)? = nil
  ) -> Harness {
    let session = Support.session()
    var fakeScript = Support.successScript(for: session)
    script?(&fakeScript)
    let fake = FakeITerm2Integration(script: fakeScript)
    let clock: any VirtualTimeClock =
      checkOff || gatedClock ? GatedAttachClock() : ManualAttachClock()
    let iTerm2 = InstrumentedITerm2(
      fake, clock: clock, holdsFirstCreateTab: holdsFirstCreateTab, hanging: hanging)
    let discovery = FakeDiscovery(status ?? .ok([session]), gated: gated)
    let store = FakeLaunchStore()
    let log = UpdateLog()
    var includes: (@Sendable (ITerm2API.TmuxConnection) -> Bool)?
    if !leftOut.isEmpty {
      includes = { connection in !leftOut.contains(connection.connectionID ?? "") }
    }
    let index =
      hanging.isEmpty
      ? Support.patientIndex(iTerm2, includes: includes)
      : AttachmentIndex(
        iTerm2: iTerm2, clock: ManualAttachClock(), configuration: .init(includes: includes))
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, clock: clock,
      existingAttachments: checkOff ? .off : .index(index), log: log)
    return Harness(
      session: session, fake: fake, iTerm2: iTerm2, discovery: discovery, store: store,
      clock: clock, log: log, coordinator: coordinator)
  } // End of func harness(status:gated:checkOff:gatedClock:holdsFirstCreateTab:hanging:…)

  /// The launch connection, owned by the launch tab.
  static let launchConnection = ITerm2API.TmuxConnection(
    connectionID: Support.connection, owningSessionID: Support.gateway)

  /// A script where the existing-attachment check finds nothing (its listing comes first) and
  /// the launch tab's connection appears afterwards.
  static func launchAfterEmptyCheck(_ script: inout FakeITerm2Integration.Script) {
    script.listTmuxConnections = .init(.success([launchConnection]), queued: [.success([])])
  }

  /// The tab requests sent to iTerm2.
  static func createTabCount(_ calls: [FakeITerm2Integration.Call]) -> Int {
    calls.filter { if case .createTab = $0 { return true } else { return false } }.count
  }

  /// `task`'s value, or `nil` with an issue recorded when it takes more than 5 s; the task is
  /// then cancelled, so a regression fails the test instead of hanging it.
  static func boundedValue(_ task: Task<AttachResult, Never>) async -> AttachResult? {
    await withTaskGroup(of: AttachResult?.self) { group in
      group.addTask { await task.value }
      group.addTask {
        try? await Task.sleep(for: .seconds(5))
        return nil
      }
      let first = await group.next() ?? nil
      if first == nil {
        Issue.record("the call did not end within 5 s")
        task.cancel()
      }
      group.cancelAll()
      return first
    }
  } // End of static func boundedValue(_:)

  // MARK: - Confirmation

  /// A confirmation for any other key (another host entry, another session, another server)
  /// fails `moveHereNotConfirmed` before anything runs: no discovery, no iTerm2 call, no
  /// request, no state.
  @Test(arguments: 0..<3)
  func refusesAConfirmationForAnotherSession(variant: Int) async {
    let harness = Self.harness(script: Self.launchAfterEmptyCheck)
    let key = harness.key
    let other: SessionKey
    switch variant {
    case 0: other = SessionKey(hostID: UUID(), server: key.server, sessionID: key.sessionID)
    case 1:
      other = SessionKey(hostID: key.hostID, server: key.server, sessionID: TmuxSessionID("$4")!)
    default:
      other = SessionKey(
        hostID: key.hostID,
        server: ServerIdentity(
          socketPath: key.server.socketPath, pid: 4243, startTime: key.server.startTime),
        sessionID: key.sessionID)
    }
    let result = await harness.coordinator.moveHere(
      harness.target, confirmation: .detachOtherClients(of: other))
    #expect(result.failure == .moveHereNotConfirmed)
    #expect(result.failure?.triggersRefresh == false)
    #expect(result.gatewaySessionID == nil && result.connectionID == nil)
    #expect(harness.discovery.calls == 0)
    #expect(await harness.fake.calls.isEmpty)
    #expect(harness.store.snapshot.written.isEmpty && harness.store.snapshot.sweeps == 0)
    #expect(harness.log.states.isEmpty)
    #expect(await harness.coordinator.state(of: key) == nil)
  } // End of func refusesAConfirmationForAnotherSession(variant:)

  /// The confirmation type has exactly one case, which names the session it is for.
  @Test func confirmationNamesItsSession() {
    let key = Support.session().key
    let confirmation = MoveHereConfirmation.detachOtherClients(of: key)
    #expect(confirmation.key == key)
    switch confirmation {
    case .detachOtherClients(let named): #expect(named == key)
    }
  }

  // MARK: - The launch

  /// A confirmed move here runs the attach steps with a request that asks for
  /// `attach-session -d`: requested → launched → confirmed, the identity check through the
  /// launch tab's connection, the connection's first tab activated, the check finding nothing.
  @Test func moveHereWritesADetachingRequest() async throws {
    let harness = Self.harness(script: Self.launchAfterEmptyCheck)
    let result = await harness.coordinator.moveHere(
      harness.target, confirmation: harness.confirmation)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.gatewaySessionID == Support.gateway)
    #expect(result.activation == .activated(tabID: "t3"))
    #expect(result.existingAttachments == AttachmentSnapshot.Counts())
    #expect(
      harness.log.states == [
        .requested, .launched(sessionID: Support.gateway),
        .confirmed(connectionID: Support.connection),
      ])
    let store = harness.store.snapshot
    let request = try #require(store.written.first)
    #expect(store.written.count == 1 && store.discarded.isEmpty)
    #expect(request.id == result.launchID)
    #expect(request.detachOtherClients == true && request.detachesOtherClients)
    #expect(
      LaunchGuard.attachArguments(for: request) == [
        "-u", "-CC", "attach-session", "-d", "-t", "$3",
      ])
    #expect(request.sessionID == harness.key.sessionID && request.host == .local)
    let calls = await harness.fake.calls
    #expect(Self.createTabCount(calls) == 1)
    #expect(
      calls.contains(
        .createTab(
          ITerm2API.CreateTabRequest(
            customProfileProperties: ITerm2API.ProfileProperty.customCommand(
              Support.helper.attachCommandLine(for: result.launchID))
              + [ITerm2API.ProfileProperty.closeSessionsOnEnd(true)]))))
    #expect(harness.iTerm2.sent.map(\.command) == [ConnectionIdentity.command])
  } // End of func moveHereWritesADetachingRequest()

  /// An SSH host's move here writes the same choice with the ssh host kind, so the helper runs
  /// the move-here remote script.
  @Test func remoteMoveHereWritesADetachingRequest() async throws {
    var host = Support.host
    host.mode = .ssh
    host.sshDestination = "fixture-remote"
    let harness = Self.harness(script: Self.launchAfterEmptyCheck)
    let result = await harness.coordinator.moveHere(
      AttachTarget(host: host, session: harness.session), confirmation: harness.confirmation)
    #expect(result.isConfirmed)
    let request = try #require(harness.store.snapshot.written.first)
    #expect(request.host == .ssh(destination: "fixture-remote") && request.detachesOtherClients)
    #expect(RemoteLaunch.remoteScript(for: request) == RemoteLaunch.moveHereScript)
  } // End of func remoteMoveHereWritesADetachingRequest()

  /// `attach(_:)` and `createAndAttach(_:)` never ask for `-d`: their requests have no field
  /// (written as earlier builds wrote them) and their argv has no `-d`.
  @Test func attachNeverAsksForDetach() async throws {
    let harness = Self.harness(script: Self.launchAfterEmptyCheck)
    let attached = await harness.coordinator.attach(harness.target)
    #expect(attached.isConfirmed)
    let request = try #require(harness.store.snapshot.written.first)
    #expect(request.detachOtherClients == nil && !request.detachesOtherClients)
    #expect(!LaunchGuard.attachArguments(for: request).contains("-d"))
    #expect(
      !String(decoding: try LaunchCoding.encoder().encode(request), as: UTF8.self)
        .contains("detachOtherClients"))

    let session = Support.session()
    let iTerm2 = FakeITerm2Integration(script: Support.successScript(for: session))
    let store = FakeLaunchStore()
    let coordinator = CreateAndAttachTests.coordinator(
      iTerm2: iTerm2, discovery: FakeDiscovery(.ok([session])), store: store,
      creator: FakeSessionCreator(.success(CreateAndAttachTests.created)), log: UpdateLog())
    let created = await coordinator.createAndAttach(CreateAndAttachTests.request)
    #expect(created.isAttached)
    let createdRequest = try #require(store.snapshot.written.first)
    #expect(createdRequest.detachOtherClients == nil)
  } // End of func attachNeverAsksForDetach()

  // MARK: - Already attached in this Mac's iTerm2

  /// The session is attached in this Mac's iTerm2 (the user's tab): the move here fails
  /// `alreadyAttachedHere` with that connection and its owner, and runs nothing else: no
  /// activation, request, `ensureRunning` or `CreateTab`; the only tmux command is the index's
  /// identity check.
  @Test func refusesWhenAttachedHereAlready() async {
    let harness = Self.harness { script in
      script.listTmuxConnections = .init(.success([AttachFocusTests.userConnection]))
      script.listSessions = .init(.success(AttachFocusTests.userSessions))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    let result = await harness.coordinator.moveHere(
      harness.target, confirmation: harness.confirmation)
    let expected = AttachFailure.alreadyAttachedHere(
      connectionID: "user", owningSessionID: "user-tab")
    #expect(result.failure == expected)
    #expect(result.failure?.triggersRefresh == false)
    #expect(result.failure?.kind == "alreadyAttachedHere")
    #expect(result.existingAttachments == AttachmentSnapshot.Counts(mapped: 1))
    #expect(result.activation == nil && result.gatewaySessionID == nil)
    #expect(harness.log.states == [.requested, .failed(expected)])
    let calls = await harness.fake.calls
    #expect(!calls.contains(.ensureRunning))
    #expect(Self.createTabCount(calls) == 0)
    #expect(!calls.contains { if case .activate = $0 { return true } else { return false } })
    #expect(
      !calls.contains { if case .activateOwnedTmuxTab = $0 { return true } else { return false } })
    #expect(harness.iTerm2.sent.map(\.command) == [ConnectionIdentity.command])
    #expect(harness.store.snapshot.written.isEmpty && harness.store.snapshot.discarded.isEmpty)
  } // End of func refusesWhenAttachedHereAlready()

  /// With the coordinator's check off, a move here still checks (with the standard index), so
  /// it never detaches this Mac's own attachment.
  @Test func checksEvenWithTheCheckOff() async {
    let harness = Self.harness(checkOff: true) { script in
      script.listTmuxConnections = .init(.success([AttachFocusTests.userConnection]))
    }
    harness.iTerm2.setAnswers([.success(Support.identityOutput(for: harness.key))], for: "user")
    let result = await harness.coordinator.moveHere(
      harness.target, confirmation: harness.confirmation)
    #expect(
      result.failure == .alreadyAttachedHere(connectionID: "user", owningSessionID: "user-tab"))
    #expect(Self.createTabCount(await harness.fake.calls) == 0)
    #expect(harness.store.snapshot.written.isEmpty)
  } // End of func checksEvenWithTheCheckOff()

  /// iTerm2 not running means nothing is attached here, so the move here launches (and
  /// `ensureRunning` starts iTerm2), like an attach.
  @Test func launchesWhenITerm2DoesNotRun() async throws {
    let harness = Self.harness { script in
      script.isRunning = false
      script.socketPresent = false
    }
    let result = await harness.coordinator.moveHere(
      harness.target, confirmation: harness.confirmation)
    #expect(result.isConfirmed)
    #expect(result.existingAttachments == AttachmentSnapshot.Counts())
    #expect(try #require(harness.store.snapshot.written.first).detachesOtherClients)
    #expect(await harness.fake.calls.contains(.ensureRunning))
  } // End of func launchesWhenITerm2DoesNotRun()

  // MARK: - Connections that cannot be ruled out

  /// One connection in this Mac's iTerm2 that cannot be ruled out as showing the session.
  enum Unresolved: String, CaseIterable, Sendable {
    /// Its answer is not in the identity command's format: `stale(unreadable)`.
    case unreadable
    /// Its identity request fails: `stale(requestFailed)`.
    case requestFailed
    /// It never answers within the index's timeout: `stale(timedOut)`.
    case timedOut
    /// The listing gives it no owning session: `stale(incompleteListing)`, nothing asked.
    case incompleteListing
    /// Its client is not in UTF-8 mode and its answer may have lost bytes: `nonUTF8`.
    case nonUTF8
    /// An exact answer naming the session's server and session, from a host name no host
    /// has: `unknown`.
    case unknownHost
  }

  /// A harness whose iTerm2 lists one connection `user` of the `kind` that cannot be ruled out
  /// (first for the check and its identity request, then next to the launch tab's connection).
  static func unresolvedHarness(_ kind: Unresolved) -> Harness {
    let user = ITerm2API.TmuxConnection(
      connectionID: "user", owningSessionID: kind == .incompleteListing ? nil : "user-tab")
    let harness = Self.harness(hanging: kind == .timedOut ? ["user"] : []) { script in
      script.listTmuxConnections = .init(
        .success([launchConnection, user]), queued: [.success([user]), .success([user])])
    }
    let key = harness.key
    switch kind {
    case .unreadable: harness.iTerm2.setAnswers([.success("garbage")], for: "user")
    case .requestFailed: harness.iTerm2.setAnswers([.failure(.timedOut)], for: "user")
    case .timedOut, .incompleteListing: break
    case .nonUTF8:
      harness.iTerm2.setAnswers(
        [.success(Support.identityOutput(for: key, host: "fixture_node.local", utf8: false))],
        for: "user")
    case .unknownHost:
      harness.iTerm2.setAnswers(
        [.success(Support.identityOutput(for: key, host: "Elsewhere.local"))], for: "user")
    }
    return harness
  } // End of static func unresolvedHarness(_:)

  /// The review's first blocker: a connection the index could not map, whatever the reason,
  /// may show the session, and `-d` would detach it. A move here fails `possiblyAttachedHere`
  /// and runs, writes and opens nothing (no `ensureRunning`, no `CreateTab`, no request, no
  /// command but the index's read-only identity check), while an attach with the same
  /// connections launches as before (D16's policy unchanged).
  @Test(arguments: Unresolved.allCases)
  func refusesAConnectionThatCannotBeRuledOut(_ kind: Unresolved) async throws {
    let moving = Self.unresolvedHarness(kind)
    let result = await moving.coordinator.moveHere(
      moving.target, confirmation: moving.confirmation)
    let expected = AttachFailure.possiblyAttachedHere(unresolved: 1)
    #expect(result.failure == expected)
    #expect(result.failure?.kind == "possiblyAttachedHere")
    #expect(result.failure?.triggersRefresh == false)
    #expect(result.failure?.message.hasSuffix(".") == true)
    let counts = try #require(result.existingAttachments)
    #expect(counts.mapped == 0 && counts.unmapped == 1)
    #expect(counts.nonUTF8 == (kind == .nonUTF8 ? 1 : 0))
    #expect(counts.unknown == (kind == .unknownHost ? 1 : 0))
    #expect(moving.log.states == [.requested, .failed(expected)])
    let calls = await moving.fake.calls
    #expect(!calls.contains(.ensureRunning))
    #expect(Self.createTabCount(calls) == 0)
    #expect(moving.store.snapshot.written.isEmpty && moving.store.snapshot.discarded.isEmpty)
    #expect(moving.iTerm2.sent.allSatisfy { $0.command == ConnectionIdentity.command })

    let attaching = Self.unresolvedHarness(kind)
    let attached = await attaching.coordinator.attach(attaching.target)
    #expect(attached.state == .confirmed(connectionID: Support.connection))
    #expect(attached.existingAttachments == counts)
    #expect(Self.createTabCount(await attaching.fake.calls) == 1)
    #expect(attaching.store.snapshot.written.count == 1)
  } // End of func refusesAConnectionThatCannotBeRuledOut(_:)

  /// Connections ruled out do not block a move here: an exact answer naming another session
  /// (mapped elsewhere) or another server (unknown, from another host), and a connection the
  /// index's filter leaves out (never asked). The move here launches with `-d`.
  @Test func launchesPastConnectionsRuledOut() async throws {
    let others = [
      ITerm2API.TmuxConnection(connectionID: "other", owningSessionID: "tab-a"),
      ITerm2API.TmuxConnection(connectionID: "foreign", owningSessionID: "tab-b"),
      ITerm2API.TmuxConnection(connectionID: "left-out", owningSessionID: "tab-c"),
    ]
    let harness = Self.harness(leftOut: ["left-out"]) { script in
      script.listTmuxConnections = .init(
        .success([Self.launchConnection] + others),
        queued: Array(repeating: .success(others), count: 3))
    }
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: Support.session(id: "$4").key))], for: "other")
    harness.iTerm2.setAnswers(
      [.success(Support.identityLine(host: "Elsewhere.local", pid: "9999") + "\n")],
      for: "foreign")
    let result = await harness.coordinator.moveHere(
      harness.target, confirmation: harness.confirmation)
    #expect(result.state == .confirmed(connectionID: Support.connection))
    #expect(result.existingAttachments == .init(mapped: 1, unknown: 1, excluded: 1))
    let request = try #require(harness.store.snapshot.written.first)
    #expect(request.detachesOtherClients)
    #expect(!harness.iTerm2.sent.contains { $0.connectionID == "left-out" })
  } // End of func launchesPastConnectionsRuledOut()

  /// `AttachmentSnapshot.unresolvedConnections(for:)`: every stale and non-UTF-8 entry, and
  /// every unknown or ambiguous one whose exact answer names the key's server and session; not
  /// those naming another server or session.
  @Test func unresolvedConnectionsOfASnapshot() {
    let key = Support.session().key
    let otherServer = ServerIdentity(
      socketPath: key.server.socketPath, pid: 9999, startTime: key.server.startTime)
    /// An entry for connection `id` of `kind`, reporting `server` and `session` when given.
    func entry(
      _ id: String, _ kind: AttachmentSnapshot.UnmappedKind, server: ServerIdentity? = nil,
      session: String = "$3"
    ) -> AttachmentSnapshot.Unmapped {
      AttachmentSnapshot.Unmapped(
        connection: .init(connectionID: id, owningSessionID: "tab-\(id)"), kind: kind,
        staleReason: kind == .stale ? .timedOut : nil,
        reported: server.map {
          ConnectionIdentity.Reported(
            host: "Elsewhere.local", pid: $0.pid, startTime: $0.startTime,
            socketPath: $0.socketPath, sessionID: TmuxSessionID(session)!)
        })
    } // End of func entry(_:_:server:session:)
    let snapshot = AttachmentSnapshot(
      unmapped: [
        entry("stale", .stale), entry("non-utf8", .nonUTF8),
        entry("unknown-same", .unknown, server: key.server),
        entry("unknown-server", .unknown, server: otherServer),
        entry("unknown-session", .unknown, server: key.server, session: "$4"),
        entry("ambiguous-same", .ambiguous, server: key.server),
        entry("ambiguous-server", .ambiguous, server: otherServer),
      ], excludedCount: 2)
    #expect(
      snapshot.unresolvedConnections(for: key).compactMap(\.connectionID) == [
        "stale", "non-utf8", "unknown-same", "ambiguous-same",
      ])
    #expect(AttachmentSnapshot(excludedCount: 3).unresolvedConnections(for: key).isEmpty)
  } // End of func unresolvedConnectionsOfASnapshot()

  // MARK: - Failures

  /// One way a launch fails, set up identically for an attach and a move here.
  enum Failure: String, CaseIterable, Sendable {
    /// No tmux server: `sessionGone` at revalidation.
    case gone
    /// Another creation time: `sessionChanged` at revalidation.
    case changed
    /// No tmux: `tmuxMissing` at revalidation.
    case tmuxMissing
    /// iTerm2's connections cannot be listed: `attachmentCheckFailed`.
    case checkFails
    /// iTerm2 refuses the tab: `iTerm2`, the request withdrawn.
    case tabRefused
    /// The helper's guard reports the session gone: `sessionGone` from the result.
    case guardRefused
    /// No connection and no result within the budget: `timedOut`, the request withdrawn.
    case noConnection
  }

  /// Runs `failure`'s setup through `attach(_:)` (`moving: false`) or a confirmed move here.
  static func run(
    _ failure: Failure,
    moving: Bool
  ) async -> (result: AttachResult, store: FakeLaunchStore.State, states: [String]) {
    let session = Support.session()
    var status: HostStatus = .ok([session])
    switch failure {
    case .gone: status = .noServer
    case .changed: status = .ok([Support.session(createdAt: session.createdAt + 1)])
    case .tmuxMissing: status = .tmuxNotFound
    default: break
    }
    let harness = Self.harness(status: status) { script in
      switch failure {
      case .checkFails: script.listTmuxConnections = .init(.failure(.timedOut))
      case .tabRefused:
        script.listTmuxConnections = .init(.success([]))
        script.createTab = .init(.failure(.timedOut))
      case .guardRefused, .noConnection: script.listTmuxConnections = .init(.success([]))
      default: break
      }
    }
    if failure == .guardRefused {
      harness.store.update { state in
        state.makeResult = { Support.result(for: $0, failure: .sessionGone) }
      }
    }
    let result =
      moving
      ? await harness.coordinator.moveHere(harness.target, confirmation: harness.confirmation)
      : await harness.coordinator.attach(harness.target)
    return (result, harness.store.snapshot, harness.log.states.map(\.kind))
  } // End of static func run(_:moving:)

  /// Every failure of a move here is the attach's, with the same states and the same request
  /// handling (written or not, withdrawn or not); only the written request differs, by `-d`.
  @Test(arguments: Failure.allCases)
  func failsLikeAnAttach(failure: Failure) async {
    let attach = await Self.run(failure, moving: false)
    let move = await Self.run(failure, moving: true)
    let expected: AttachFailure
    switch failure {
    case .gone, .guardRefused: expected = .sessionGone
    case .changed: expected = .sessionChanged
    case .tmuxMissing: expected = .tmuxMissing
    case .checkFails: expected = .attachmentCheckFailed(.timedOut)
    case .tabRefused: expected = .iTerm2(.timedOut)
    case .noConnection: expected = .timedOut
    }
    #expect(attach.result.failure == expected)
    #expect(move.result.failure == expected)
    #expect(move.result.triggersRefresh == attach.result.triggersRefresh)
    #expect(move.states == attach.states)
    #expect(move.store.written.count == attach.store.written.count)
    #expect(move.store.discarded.count == attach.store.discarded.count)
    #expect(move.store.written.allSatisfy { $0.detachesOtherClients })
    #expect(!attach.store.written.contains { $0.detachesOtherClients })
  } // End of func failsLikeAnAttach(failure:)

  // MARK: - Single flight

  /// Concurrent move here calls for the session share one launch and one result.
  @Test func concurrentMoveHereCallsCoalesce() async throws {
    let harness = Self.harness(gated: true, script: Self.launchAfterEmptyCheck)
    let coordinator = harness.coordinator
    let (target, confirmation) = (harness.target, harness.confirmation)
    let first = Task { await coordinator.moveHere(target, confirmation: confirmation) }
    let second = Task { await coordinator.moveHere(target, confirmation: confirmation) }
    try await waitUntil(timeout: .seconds(5), "both callers joined") {
      await coordinator.waiterCount(for: target.key) == 2
    }
    harness.discovery.release()
    let results = await [first.value, second.value]
    #expect(results[0] == results[1] && results[0].isConfirmed)
    #expect(Self.createTabCount(await harness.fake.calls) == 1)
    #expect(harness.store.snapshot.written.count == 1)
    #expect(harness.discovery.calls == 1)
  } // End of func concurrentMoveHereCallsCoalesce()

  /// A move here never joins an attach in progress: it waits until the attach ended, then
  /// checks afresh and finds the attachment that attach made here (`alreadyAttachedHere`), so
  /// only the attach's request (without `-d`) was written and one tab opened.
  @Test func moveHereWaitsOutAnAttach() async throws {
    let harness = Self.harness(gated: true, script: Self.launchAfterEmptyCheck)
    let coordinator = harness.coordinator
    let (target, confirmation) = (harness.target, harness.confirmation)
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "the attach started") {
      harness.discovery.calls == 1
    }
    let move = Task { await coordinator.moveHere(target, confirmation: confirmation) }
    try await waitUntil(timeout: .seconds(5), "the move here waits") {
      harness.clock.elapsed > .zero
    }
    #expect(await coordinator.waiterCount(for: target.key) == 1)
    harness.discovery.release()
    let attached = await attach.value
    let moved = await move.value
    #expect(attached.isConfirmed)
    #expect(
      moved.failure
        == .alreadyAttachedHere(connectionID: Support.connection, owningSessionID: Support.gateway))
    #expect(moved.launchID != attached.launchID)
    #expect(Self.createTabCount(await harness.fake.calls) == 1)
    let written = harness.store.snapshot.written
    #expect(written.count == 1 && written.first?.detachOtherClients == nil)
  } // End of func moveHereWaitsOutAnAttach()

  /// An attach never joins a move here in progress: it waits until the move here ended, then
  /// finds the moved attachment and focuses it; only the move here's request (with `-d`) was
  /// written.
  @Test func attachWaitsOutAMoveHere() async throws {
    let harness = Self.harness(gated: true, script: Self.launchAfterEmptyCheck)
    let coordinator = harness.coordinator
    let (target, confirmation) = (harness.target, harness.confirmation)
    let move = Task { await coordinator.moveHere(target, confirmation: confirmation) }
    try await waitUntil(timeout: .seconds(5), "the move here started") {
      harness.discovery.calls == 1
    }
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "the attach waits") {
      harness.clock.elapsed > .zero
    }
    #expect(await coordinator.waiterCount(for: target.key) == 1)
    harness.discovery.release()
    let moved = await move.value
    let attached = await attach.value
    #expect(moved.isConfirmed)
    #expect(attached.state == .focused(connectionID: Support.connection))
    #expect(Self.createTabCount(await harness.fake.calls) == 1)
    let written = harness.store.snapshot.written
    #expect(written.count == 1 && written.first?.detachesOtherClients == true)
  } // End of func attachWaitsOutAMoveHere()

  /// A move here cancelled while it waits out an attach ends `cancelled` and starts nothing.
  @Test func cancelledWhileWaitingStartsNothing() async throws {
    let harness = Self.harness(gated: true, script: Self.launchAfterEmptyCheck)
    let coordinator = harness.coordinator
    let (target, confirmation) = (harness.target, harness.confirmation)
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil(timeout: .seconds(5), "the attach started") {
      harness.discovery.calls == 1
    }
    let move = Task { await coordinator.moveHere(target, confirmation: confirmation) }
    try await waitUntil(timeout: .seconds(5), "the move here waits") {
      harness.clock.elapsed > .zero
    }
    move.cancel()
    let moved = await move.value
    #expect(moved.failure == .cancelled)
    harness.discovery.release()
    #expect(await attach.value.isConfirmed)
    #expect(harness.discovery.calls == 1)
    #expect(harness.store.snapshot.written.count == 1)
    #expect(!harness.store.snapshot.written.contains { $0.detachesOtherClients })
  } // End of func cancelledWhileWaitingStartsNothing()

  // MARK: - Conflicting launches that may still attach

  /// The launch tab of the earlier, cancelled launch.
  static let oldGateway = "old-gateway"
  /// That tab's connection, once its helper attached.
  static let oldConnection = ITerm2API.TmuxConnection(
    connectionID: "old-connection", owningSessionID: oldGateway)

  /// What shows, after a launch was cancelled during its `CreateTab`, that it can no longer
  /// attach the session.
  enum Settlement: String, CaseIterable, Sendable {
    /// Its request was withdrawn before a helper took it: settled when its run ends.
    case withdrawn
    /// The helper took the request; then its result appears.
    case helperResult
    /// The helper took the request; then the launch tab's connection appears.
    case connection
    /// The helper took the request; then the launch tab is gone from iTerm2, for 10 s.
    case tabGone
    /// The helper took the request; then nothing, for the whole confirmation budget.
    case nothing
  }

  /// A harness on a gated clock whose first `CreateTab` (the earlier launch's) is held and
  /// answers `oldGateway`; later ones answer the usual launch tab. The connection listings: the
  /// earlier launch's check and its one poll see nothing; then, for `settlement`, what the
  /// waiting call's looks find (`connection`: the old connection, also for its own check), and
  /// then the later launch's check and the usual launch connection.
  static func settlementHarness(_ settlement: Settlement) -> Harness {
    let harness = Self.harness(gatedClock: true, holdsFirstCreateTab: true) { script in
      script.createTab = .init(
        .success(.init(status: .ok, windowID: "w9", tabID: 9, sessionID: Support.gateway)),
        queued: [.success(.init(status: .ok, windowID: "w8", tabID: 8, sessionID: oldGateway))])
      let tabWithOldGateway = ITerm2API.ListSessionsResponse(
        windows: Support.sessions.windows + [
          .init(
            windowID: "w8",
            tabs: [
              .init(
                tabID: "t8", root: Support.leaves(1), tmuxWindowID: "0",
                tmuxConnectionID: oldConnection.connectionID)
            ])
        ],
        buriedSessions: [.init(uniqueIdentifier: oldGateway)])
      switch settlement {
      case .withdrawn, .helperResult:
        script.listTmuxConnections = .init(
          .success([launchConnection]), queued: Array(repeating: .success([]), count: 3))
      case .connection:
        script.listTmuxConnections = .init(
          .success([oldConnection]), queued: Array(repeating: .success([]), count: 2))
        script.listSessions = .init(.success(tabWithOldGateway))
      case .tabGone:
        script.listTmuxConnections = .init(
          .success([launchConnection]), queued: Array(repeating: .success([]), count: 5))
      case .nothing:
        script.listTmuxConnections = .init(.success([]))
        script.listSessions = .init(.success(tabWithOldGateway))
      }
    } // End of the script
    harness.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: harness.key))], for: "old-connection")
    if settlement != .withdrawn { harness.store.update { $0.helperTakesRequests = true } }
    return harness
  } // End of static func settlementHarness(_:)

  /// The review's second blocker, in both directions and for a move here after a move here: a
  /// launch whose callers were all cancelled still sends its `CreateTab`, and its helper may
  /// take the request before the withdrawal. A conflicting call (`laterMoves`: a move here,
  /// otherwise an attach, after a move here; a move here after an attach is
  /// `moveHereWaitsOutACancelledAttach`) neither revalidates, writes nor opens anything while
  /// that launch runs, then waits until it is settled: its request withdrawn in time, its
  /// helper's result, its connection (then the later call finds that attachment: an attach
  /// focuses it, a move here ends `alreadyAttachedHere`), or its tab gone for 10 s. With no
  /// proof within the 15 s confirmation budget the call fails `earlierLaunchPending` and runs
  /// nothing, and the launch stays pending for the next call.
  @Test(arguments: Settlement.allCases, [false, true])
  func laterCallWaitsOutACancelledMoveHere(
    _ settlement: Settlement,
    laterMoves: Bool
  ) async throws {
    let harness = Self.settlementHarness(settlement)
    let coordinator = harness.coordinator
    let (target, confirmation) = (harness.target, harness.confirmation)
    let clock = try #require(harness.clock as? GatedAttachClock)
    let move = Task { await coordinator.moveHere(target, confirmation: confirmation) }
    try await waitUntil("the move here's CreateTab is held") { harness.iTerm2.isHoldingCreateTab }
    move.cancel()
    try await waitUntil("the move here winds down") {
      await coordinator.cancelledWaiterCount(for: target.key) == 1
    }
    let later = Task {
      laterMoves
        ? await coordinator.moveHere(target, confirmation: confirmation)
        : await coordinator.attach(target)
    }
    try await waitUntil("the later call waits") { clock.waiting == 1 }
    #expect(harness.discovery.calls == 1)
    #expect(harness.store.snapshot.written.count == 1)
    harness.iTerm2.releaseCreateTab()
    let moved = await move.value
    #expect(moved.failure == .cancelled && moved.gatewaySessionID == Self.oldGateway)
    #expect(harness.store.snapshot.discarded == [moved.launchID])
    #expect(
      await coordinator.unsettledLaunchCount(for: target.key) == (settlement == .withdrawn ? 0 : 1))
    if settlement == .helperResult {
      let request = try #require(harness.store.snapshot.written.first)
      harness.store.update {
        $0.results[moved.launchID] = Support.result(for: request, failure: .sessionGone)
      }
    }
    clock.advance(by: .milliseconds(200))
    if settlement == .tabGone || settlement == .nothing {
      try await waitUntil("the later call looked and waits again") { clock.waiting == 1 }
      #expect(harness.discovery.calls == 1)
      #expect(await coordinator.unsettledLaunchCount(for: target.key) == 1)
      clock.advance(by: settlement == .tabGone ? .seconds(10) : .seconds(15))
    }
    let result = try #require(await Self.boundedValue(later))
    let written = harness.store.snapshot.written
    let tabs = Self.createTabCount(await harness.fake.calls)
    switch settlement {
    case .withdrawn, .helperResult, .tabGone:
      #expect(result.state == .confirmed(connectionID: Support.connection))
      #expect(written.count == 2 && written.last?.detachesOtherClients == laterMoves)
      #expect(tabs == 2)
    case .connection:
      #expect(
        result.state
          == (laterMoves
            ? .failed(
              .alreadyAttachedHere(
                connectionID: "old-connection", owningSessionID: Self.oldGateway))
            : .focused(connectionID: "old-connection")))
      #expect(written.count == 1 && tabs == 1)
    case .nothing:
      #expect(result.failure == .earlierLaunchPending)
      #expect(result.failure?.kind == "earlierLaunchPending")
      #expect(result.failure?.triggersRefresh == false)
      #expect(written.count == 1 && tabs == 1)
      #expect(harness.discovery.calls == 1)
      #expect(clock.elapsed >= .seconds(15))
    }
    #expect(
      await coordinator.unsettledLaunchCount(for: target.key) == (settlement == .nothing ? 1 : 0))
  } // End of func laterCallWaitsOutACancelledMoveHere(_:laterMoves:)

  /// The other direction: a move here after an attach whose callers were all cancelled during
  /// its `CreateTab`, and whose helper took the request, waits until that launch is settled;
  /// once its connection appears, the move here finds that attachment and ends
  /// `alreadyAttachedHere`: no `-d` request was ever written, so `-d` never detached it.
  @Test func moveHereWaitsOutACancelledAttach() async throws {
    let harness = Self.settlementHarness(.connection)
    let coordinator = harness.coordinator
    let (target, confirmation) = (harness.target, harness.confirmation)
    let clock = try #require(harness.clock as? GatedAttachClock)
    let attach = Task { await coordinator.attach(target) }
    try await waitUntil("the attach's CreateTab is held") { harness.iTerm2.isHoldingCreateTab }
    attach.cancel()
    try await waitUntil("the attach winds down") {
      await coordinator.cancelledWaiterCount(for: target.key) == 1
    }
    let move = Task { await coordinator.moveHere(target, confirmation: confirmation) }
    try await waitUntil("the move here waits") { clock.waiting == 1 }
    #expect(harness.discovery.calls == 1)
    #expect(harness.store.snapshot.written.count == 1)
    harness.iTerm2.releaseCreateTab()
    let attached = await attach.value
    #expect(attached.failure == .cancelled && attached.gatewaySessionID == Self.oldGateway)
    #expect(await coordinator.unsettledLaunchCount(for: target.key) == 1)
    clock.advance(by: .milliseconds(200))
    let moved = try #require(await Self.boundedValue(move))
    #expect(
      moved.failure
        == .alreadyAttachedHere(connectionID: "old-connection", owningSessionID: Self.oldGateway))
    let written = harness.store.snapshot.written
    #expect(written.count == 1 && !written.contains { $0.detachesOtherClients })
    #expect(Self.createTabCount(await harness.fake.calls) == 1)
    #expect(await coordinator.unsettledLaunchCount(for: target.key) == 0)
  } // End of func moveHereWaitsOutACancelledAttach()

  /// An attach never waits for another attach (PLAN.md D15 unchanged): one arriving while a
  /// cancelled attach still waits for its `CreateTab`, whose helper took the request, starts
  /// its own launch at once, and the older one stays pending only for later move here calls.
  @Test func attachDoesNotWaitForACancelledAttach() async throws {
    let harness = Self.settlementHarness(.nothing)
    await harness.fake.updateScript { script in
      script.listTmuxConnections = .init(
        .success([Self.launchConnection]), queued: Array(repeating: .success([]), count: 2))
      script.listSessions = .init(.success(Support.sessions))
    }
    let coordinator = harness.coordinator
    let target = harness.target
    let older = Task { await coordinator.attach(target) }
    try await waitUntil("the first CreateTab is held") { harness.iTerm2.isHoldingCreateTab }
    older.cancel()
    try await waitUntil("the first attach winds down") {
      await coordinator.cancelledWaiterCount(for: target.key) == 1
    }
    let newer = try #require(await Self.boundedValue(Task { await coordinator.attach(target) }))
    #expect(newer.state == .confirmed(connectionID: Support.connection))
    #expect(harness.discovery.calls == 2)
    harness.iTerm2.releaseCreateTab()
    #expect(await older.value.failure == .cancelled)
    #expect(await coordinator.unsettledLaunchCount(for: target.key) == 1)
  } // End of func attachDoesNotWaitForACancelledAttach()
}
