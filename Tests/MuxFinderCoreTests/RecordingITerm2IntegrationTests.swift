import Foundation
import Testing

@testable import MuxFinderCore

/// `RecordingITerm2Integration`, the wrapper the e2e harness gives its coordinators so a step
/// can prove that a launch tab left iTerm2 by itself (PLAN.md D29): it forwards every call,
/// records each bury, restore and `Close` before forwarding it (also when it fails), and tells
/// which recorded requests may have restored or closed one session. Over the scripted fake
/// only; nothing touches iTerm2.
@Suite("Recording iTerm2 integration")
struct RecordingITerm2IntegrationTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// Every call reaches the fake unchanged, with its answer or error; buries, restores and
  /// `Close`s are recorded in order, a refused restore and a bury that was not sent included,
  /// and nothing else is. `restoresAndCloses(of:)` keeps a session's restores, the `Close`s
  /// naming it and every `Close` of tabs or windows, never its buries or another session's
  /// requests.
  @Test func forwardsEveryCallAndRecordsBuriesRestoresAndCloses() async throws {
    var script = FakeITerm2Integration.Script()
    script.listSessions = .init(.success(Support.sessions))
    script.listTmuxConnections = .init(.success([]))
    script.setBuried = .init(.success(()), queued: [.success(()), .failure(.timedOut)])
    script.close = .init(.success(.init(statuses: [.ok])))
    let fake = FakeITerm2Integration(script: script)
    let recorder = RecordingITerm2Integration(base: fake)
    #expect(try await recorder.listSessions() == Support.sessions)
    try await recorder.setBuried(true, sessionID: "a")
    await #expect(throws: ITerm2Error.timedOut) {
      try await recorder.setBuried(false, sessionID: "a")
    }
    await #expect(throws: ITerm2Error.tmuxConnectionNotOwned) {
      try await recorder.buryLaunchTab(sessionID: "g", ifOwnsTmuxConnection: "c")
    }
    let closed = try await recorder.close(.init(target: .sessions(["g"]), force: true))
    #expect(closed.statuses == [.ok])
    _ = try await recorder.close(.init(target: .tabs(["t1"]), force: false))
    try await recorder.setBuried(false, sessionID: "b")
    #expect(try await recorder.listTmuxConnections().isEmpty)
    #expect(
      await fake.calls == [
        .listSessions, .setBuried(buried: true, sessionID: "a"),
        .setBuried(buried: false, sessionID: "a"),
        .buryLaunchTab(sessionID: "g", connectionID: "c"),
        .close(.init(target: .sessions(["g"]), force: true)),
        .close(.init(target: .tabs(["t1"]), force: false)),
        .setBuried(buried: false, sessionID: "b"), .listTmuxConnections,
      ])
    #expect(
      await recorder.requests == [
        .setBuried(buried: true, sessionID: "a"), .setBuried(buried: false, sessionID: "a"),
        .buryLaunchTab(sessionID: "g"), .close(.init(target: .sessions(["g"]), force: true)),
        .close(.init(target: .tabs(["t1"]), force: false)),
        .setBuried(buried: false, sessionID: "b"),
      ])
    #expect(
      await recorder.restoresAndCloses(of: "a") == [
        .setBuried(buried: false, sessionID: "a"),
        .close(.init(target: .tabs(["t1"]), force: false)),
      ])
    #expect(
      await recorder.restoresAndCloses(of: "g") == [
        .close(.init(target: .sessions(["g"]), force: true)),
        .close(.init(target: .tabs(["t1"]), force: false)),
      ])
  } // End of func forwardsEveryCallAndRecordsBuriesRestoresAndCloses()

  /// Through a coordinator, as in the e2e harness: when the helper brought its buried launch
  /// tab back and the tab closed by itself, the recorder holds no restore or `Close` of it once
  /// the recovery looked (only the bury); when the helper's restores never reached iTerm2, the
  /// recovery's restore and forced `Close` of the dead tab are recorded, so a step that saw
  /// the tab gone can tell that the coordinator, not the helper, removed it.
  @Test(arguments: [true, false])
  func recordsTheCoordinatorsRecoveryOfADeadTab(helperRestored: Bool) async throws {
    let session = Support.session()
    var script = Support.successScript(for: session)
    script.listSessions = .init(.success(LaunchTabBurialTests.sessionsWithLaunchTab))
    script.close = .init(.success(.init(statuses: [.ok])))
    let fake = FakeITerm2Integration(script: script)
    let recorder = RecordingITerm2Integration(base: fake)
    let store = FakeLaunchStore()
    let clock = ManualAttachClock()
    let coordinator = Support.coordinator(
      iTerm2: recorder, discovery: FakeDiscovery(.ok([session])), store: store, clock: clock)
    let result = await coordinator.attach(AttachTarget(host: Support.host, session: session))
    #expect(result.burial == .buried)
    if helperRestored {
      await fake.restoreAsTheHelperWould(Support.gateway)
      await fake.updateScript { $0.listSessions = .init(.success(Support.sessions)) }
    }
    store.finishLatestLaunch()
    await coordinator.checkBuriedLaunchTabs()
    try await clock.sleep(for: .seconds(15))
    await coordinator.checkBuriedLaunchTabs()
    #expect(await coordinator.watchedBuriedTabs.isEmpty)
    let touched = await recorder.restoresAndCloses(of: Support.gateway)
    if helperRestored {
      #expect(touched.isEmpty)
      #expect(await recorder.requests == [.buryLaunchTab(sessionID: Support.gateway)])
    } else {
      #expect(
        touched == [
          .setBuried(buried: false, sessionID: Support.gateway),
          .close(.init(target: .sessions([Support.gateway]), force: true)),
        ])
    }
  } // End of func recordsTheCoordinatorsRecoveryOfADeadTab(helperRestored:)
}
