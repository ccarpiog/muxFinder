import Foundation
import Testing
import os

@testable import MuxFinderCore

/// A `SessionCreating` that records every request and answers with a fixed outcome.
final class FakeSessionCreator: SessionCreating {
  /// What every call returns.
  let outcome: Result<CreatedSession, SessionCreationError>
  /// Requests received so far.
  private let received = OSAllocatedUnfairLock<[NewSessionRequest]>(initialState: [])

  /// Creates a fake with `outcome`.
  init(_ outcome: Result<CreatedSession, SessionCreationError>) {
    self.outcome = outcome
  }

  /// The requests received so far.
  var requests: [NewSessionRequest] { received.withLock { $0 } }

  /// Records `request` and returns the outcome.
  func createSession(
    _ request: NewSessionRequest
  ) async throws(SessionCreationError) -> CreatedSession {
    received.withLock { $0.append(request) }
    return try outcome.get()
  }
}

/// `AttachCoordinator.createAndAttach(_:)` against fakes, and the refresh-triggering marker on
/// vanished and changed sessions (PLAN.md D18). Nothing touches tmux, iTerm2 or the launch
/// directory.
@Suite("Create and attach")
struct CreateAndAttachTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The session the fake creator creates: the fixture session `$3`, as `new-session -P`
  /// reports it.
  static let created = CreatedSession(
    server: Support.server, sessionID: TmuxSessionID("$3")!,
    createdAt: Support.session().createdAt, name: "fixture-session")

  /// The request every test sends.
  static let request = NewSessionRequest(
    host: Support.host, name: "fixture-session", workingDirectory: "~/work")

  /// A coordinator whose existing-attachment check is on (an index over `iTerm2`), with the
  /// given creator.
  static func coordinator(
    iTerm2: any ITerm2Integration,
    discovery: FakeDiscovery,
    store: FakeLaunchStore,
    creator: FakeSessionCreator,
    log: UpdateLog
  ) -> AttachCoordinator {
    AttachCoordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, helperPath: Support.helper,
      clock: ManualAttachClock(), existingAttachments: .index(Support.patientIndex(iTerm2)),
      sessionCreator: creator, onUpdate: { log.record($0) })
  } // End of func coordinator(iTerm2:discovery:store:creator:log:)

  /// Creation, then the usual launch and confirmation; the existing-attachment check is
  /// skipped, so no tmux connection is asked anything before the launch tab opens (an
  /// ordinary attach of the same session, whose connection the fake already lists, focuses it
  /// instead).
  @Test func createsThenAttachesWithoutAskingConnections() async throws {
    let session = Support.session()
    let iTerm2 = FakeITerm2Integration(script: Support.successScript(for: session))
    let discovery = FakeDiscovery(.ok([session]))
    let store = FakeLaunchStore()
    let creator = FakeSessionCreator(.success(Self.created))
    let log = UpdateLog()
    let coordinator = Self.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, creator: creator, log: log)
    let result = await coordinator.createAndAttach(Self.request)
    #expect(creator.requests == [Self.request])
    #expect(result.created == Self.created)
    #expect(result.creationFailure == nil)
    let attach = try #require(result.attach)
    #expect(attach.state == .confirmed(connectionID: Support.connection))
    #expect(attach.key == session.key)
    #expect(attach.existingAttachments == nil)
    #expect(log.states.map(\.kind) == ["requested", "launched", "confirmed"])
    #expect(result.isAttached && result.triggersRefresh)
    let calls = await iTerm2.calls
    let createTab = try #require(
      calls.firstIndex { if case .createTab = $0 { true } else { false } })
    #expect(!calls[..<createTab].contains(.listTmuxConnections))
    #expect(
      AttachCoordinatorTests.tmuxCommands(calls) == [ConnectionIdentity.command],
      "only the launch's own identity check")
    let written = try #require(store.snapshot.written.first)
    #expect(written.sessionID == Self.created.sessionID)
    #expect(written.expectedSessionCreated == Self.created.createdAt)
    #expect(written.expectedServerPID == Self.created.server.pid)
    #expect(discovery.calls == 1)

    // The same session through `attach(_:)`: the check runs and finds it attached.
    let focused = await coordinator.attach(AttachTarget(host: Support.host, session: session))
    #expect(focused.isFocused)
  } // End of func createsThenAttachesWithoutAskingConnections()

  /// A collision or another creation failure never discovers, writes, launches or opens
  /// anything.
  @Test(arguments: [
    SessionCreationError.sessionExists(.hasSession),
    .sessionExists(.duplicateSession),
    .directoryMissing,
    .tmuxFailed("create window failed: fork failed"),
    .sshFailed(.authFailed),
    .invalidName(.sessionNameContainsColonOrPeriod),
    .timedOut,
    .connectionLost,
    .scriptFailed(.signaled(9)),
  ])
  func creationFailureNeverAttaches(failure: SessionCreationError) async {
    let session = Support.session()
    let iTerm2 = FakeITerm2Integration(script: Support.successScript(for: session))
    let discovery = FakeDiscovery(.ok([session]))
    let store = FakeLaunchStore()
    let log = UpdateLog()
    let coordinator = Self.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: store,
      creator: FakeSessionCreator(.failure(failure)), log: log)
    let result = await coordinator.createAndAttach(Self.request)
    #expect(result.creationFailure == failure)
    #expect(result.created == nil && result.attach == nil && !result.isAttached)
    #expect(result.triggersRefresh == failure.triggersRefresh)
    #expect(discovery.calls == 0)
    #expect(store.snapshot.written.isEmpty)
    #expect(await iTerm2.calls.isEmpty)
    #expect(log.states.isEmpty)
  } // End of func creationFailureNeverAttaches(failure:)

  /// A created session that is gone by the time it is revalidated ends `sessionGone`, marked
  /// refresh-triggering, with no tab and no request.
  @Test(arguments: [HostStatus.noServer, .ok([])])
  func vanishedCreatedSessionIsGone(status: HostStatus) async {
    let iTerm2 = FakeITerm2Integration(script: Support.successScript(for: Support.session()))
    let store = FakeLaunchStore()
    let coordinator = Self.coordinator(
      iTerm2: iTerm2, discovery: FakeDiscovery(status), store: store,
      creator: FakeSessionCreator(.success(Self.created)), log: UpdateLog())
    let result = await coordinator.createAndAttach(Self.request)
    #expect(result.attach?.failure == .sessionGone)
    #expect(result.attach?.triggersRefresh == true)
    #expect(result.triggersRefresh)
    #expect(store.snapshot.written.isEmpty)
    #expect(await iTerm2.calls.isEmpty)
  } // End of func vanishedCreatedSessionIsGone(status:)

  /// An ordinary attach of a session killed after discovery ends `sessionGone` (revalidation)
  /// with nothing written or opened; a guard refusal (exit 64 or 65) ends the same way after
  /// the tab opened. Both are refresh-triggering.
  @Test func vanishedSessionTriggersRefresh() async {
    let gone = AttachCoordinatorTests.harness(status: .ok([]))
    let result = await gone.coordinator.attach(gone.target)
    #expect(result.failure == .sessionGone && result.triggersRefresh)
    #expect(gone.store.snapshot.written.isEmpty)
    #expect(await gone.iTerm2.calls.isEmpty)
    for launchFailure in [LaunchFailure.sessionGone, .sessionChanged] {
      let refused = AttachCoordinatorTests.harness()
      refused.store.update { state in
        state.makeResult = { Support.result(for: $0, failure: launchFailure) }
      }
      let outcome = await refused.coordinator.attach(refused.target)
      #expect(outcome.failure == AttachFailure.from(launchFailure))
      #expect(outcome.triggersRefresh)
    } // End of loop over the guard's refusals
  } // End of func vanishedSessionTriggersRefresh()

  /// Exactly the vanished and changed cases are refresh-triggering.
  @Test func marksVanishedAndChangedSessions() {
    let triggering: [AttachFailure] = [.sessionGone, .sessionChanged, .identityMismatch]
    let others: [AttachFailure] = [
      .invalidDestination(.sshDestinationEmpty), .tmuxMissing, .discoveryFailed("unreachable"),
      .launchStore(.directoryMissing), .iTerm2(.timedOut), .helperFailed(.checkTimedOut),
      .helperEnded, .timedOut, .waitLimitReached, .identityCheckFailed(nil), .cancelled,
      .attachmentCheckFailed(.timedOut), .attachmentChanged,
    ]
    #expect(triggering.allSatisfy { $0.triggersRefresh })
    #expect(!others.contains { $0.triggersRefresh })
    #expect(
      LaunchFailure.sessionGone.triggersRefresh && LaunchFailure.sessionChanged.triggersRefresh)
    let launchOthers: [LaunchFailure] = [
      .tmuxMissing, .tmuxCheckFailed, .guardUsage, .sshFailed(.authFailed), .usage,
      .requestMissing, .requestExpired, .requestUnreadable, .launchDirectoryUnusable,
      .spawnFailed(errno: 2), .checkTimedOut, .interrupted(1), .childSignaled(9),
      .childExited(1),
    ]
    #expect(!launchOthers.contains { $0.triggersRefresh })
    #expect(launchOthers.allSatisfy { !AttachFailure.from($0).triggersRefresh })
  } // End of func marksVanishedAndChangedSessions()
}
