import Foundation
import os

@testable import MuxFinderCore

/// A manual `AttachClock`: `sleep(for:)` only advances virtual time (then yields), so budgets
/// run out at once. With `holdsSleeps`, a sleep instead waits until its task is cancelled.
final class ManualAttachClock: AttachClock {
  /// Mutable state.
  private struct State {
    /// Virtual time since `base`.
    var offset: Duration = .zero
    /// Whether sleeps wait for cancellation instead of advancing time.
    var holdsSleeps = false
    /// How many sleeps started while held.
    var heldSleeps = 0
  }

  /// The real instant virtual time starts from.
  private let base = ContinuousClock.now
  /// The wall-clock time virtual time starts from (whole seconds).
  static let baseDate = Date(timeIntervalSince1970: 1_792_600_100)
  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a clock; `holdsSleeps` makes every sleep wait for cancellation.
  init(holdsSleeps: Bool = false) {
    state.withLock { $0.holdsSleeps = holdsSleeps }
  }

  /// `base` plus the virtual time.
  func now() -> ContinuousClock.Instant { base + state.withLock { $0.offset } }

  /// `baseDate` plus the virtual time.
  func date() -> Date {
    let offset = state.withLock { $0.offset }
    return Self.baseDate.addingTimeInterval(Double(offset / .milliseconds(1)) / 1000)
  }

  /// Advances virtual time by `duration`, or (held) waits until cancelled.
  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    let held = state.withLock { state -> Bool in
      if state.holdsSleeps {
        state.heldSleeps += 1
      } else {
        state.offset += duration
      }
      return state.holdsSleeps
    }
    if held {
      try await Task.sleep(for: .seconds(3600))
    } else {
      await Task.yield()
    }
  } // End of func sleep(for:)

  /// Virtual time elapsed so far.
  var elapsed: Duration { state.withLock { $0.offset } }

  /// How many sleeps started while held.
  var heldSleeps: Int { state.withLock { $0.heldSleeps } }
}

/// A scripted `HostDiscovering`: answers with `status`, counts calls, and can hold every call
/// until `release()`.
final class FakeDiscovery: HostDiscovering {
  /// Mutable state.
  private struct State {
    /// The status every call reports.
    var status: HostStatus
    /// Calls so far.
    var calls = 0
    /// Whether calls wait for `release()`.
    var gated: Bool
    /// Calls waiting for `release()`.
    var waiting: [CheckedContinuation<Void, Never>] = []
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// Creates a discovery reporting `status`; `gated` holds calls until `release()`.
  init(_ status: HostStatus, gated: Bool = false) {
    state = OSAllocatedUnfairLock(initialState: State(status: status, gated: gated))
  }

  /// Reports the scripted status for `host`, after `release()` when gated.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    let gated = state.withLock { state -> Bool in
      state.calls += 1
      return state.gated
    }
    if gated {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeNow = state.withLock { state -> Bool in
          guard state.gated else { return true }
          state.waiting.append(continuation)
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }
    let status = state.withLock { $0.status }
    return DiscoveryResult(hostID: host.id, status: status, report: nil, duration: .milliseconds(5))
  } // End of func discover(_:)

  /// Lets every held call (and every later one) continue.
  func release() {
    let waiting = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.gated = false
      defer { state.waiting.removeAll() }
      return state.waiting
    }
    for continuation in waiting { continuation.resume() }
  }

  /// Calls so far.
  var calls: Int { state.withLock { $0.calls } }
}

/// An in-memory `LaunchRequestStore` that records every call. A result appears for the written
/// request once `takeResult` has been called `resultAfterTakes` times, if `makeResult` is set.
final class FakeLaunchStore: LaunchRequestStore {
  /// Mutable state.
  struct State {
    /// Written requests, in order.
    var written: [LaunchRequest] = []
    /// Discarded ids, in order.
    var discarded: [LaunchToken] = []
    /// `sweep()` calls.
    var sweeps = 0
    /// `takeResult(_:)` calls.
    var takes = 0
    /// Results waiting to be taken, by id.
    var results: [LaunchToken: LaunchResult] = [:]
    /// Makes the helper's result for a written request.
    var makeResult: (@Sendable (LaunchRequest) -> LaunchResult)?
    /// How many takes return nothing before `makeResult` is used.
    var resultAfterTakes = 0
    /// The error `writeRequest(_:)` throws, if any.
    var writeError: LaunchStoreError?
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Changes the state.
  func update(_ change: @Sendable (inout State) -> Void) {
    state.withLock { change(&$0) }
  }

  /// A copy of the state.
  var snapshot: State { state.withLock { $0 } }

  /// Records the request, or throws `writeError`.
  func writeRequest(_ request: LaunchRequest) throws(LaunchStoreError) {
    let error = state.withLock { state -> LaunchStoreError? in
      if let error = state.writeError { return error }
      state.written.append(request)
      return nil
    }
    if let error { throw error }
  }

  /// Records the discard.
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    state.withLock { state in
      state.discarded.append(id)
      return true
    }
  }

  /// Returns a stored result, or the made one once enough takes happened.
  func takeResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult? {
    state.withLock { state -> LaunchResult? in
      state.takes += 1
      if let result = state.results.removeValue(forKey: id) { return result }
      guard state.takes > state.resultAfterTakes, let make = state.makeResult,
        let request = state.written.first(where: { $0.id == id })
      else { return nil }
      state.makeResult = nil
      return make(request)
    }
  } // End of func takeResult(_:)

  /// Counts the sweep.
  func sweep() throws(LaunchStoreError) -> Int {
    state.withLock { $0.sweeps += 1 }
    return 0
  }
}

/// Collects the coordinator's updates.
final class UpdateLog: Sendable {
  /// The updates, oldest first.
  private let updates = OSAllocatedUnfairLock(initialState: [AttachUpdate]())

  /// Records one update.
  func record(_ update: AttachUpdate) {
    updates.withLock { $0.append(update) }
  }

  /// The recorded states, oldest first.
  var states: [AttachState] { updates.withLock { $0.map(\.state) } }

  /// The recorded updates, oldest first.
  var all: [AttachUpdate] { updates.withLock { $0 } }
}

/// Wraps a `FakeITerm2Integration` for attach tests: records the virtual time of every tmux
/// command that reached "iTerm2" (did not fail as not sent), and can hold the answer of the
/// first `createTab` call until `releaseCreateTab()`.
final class InstrumentedITerm2: ITerm2Integration {
  /// A tmux command that was sent, and the virtual time it was sent at.
  struct SentCommand: Sendable, Hashable {
    /// The command.
    let command: String
    /// The clock's virtual time when it was sent.
    let at: Duration
  }

  /// Mutable state.
  private struct State {
    /// Commands sent so far.
    var sent: [SentCommand] = []
    /// Whether the first `createTab` answer is held.
    var holdsFirstCreateTab: Bool
    /// `createTab` calls so far.
    var createTabCalls = 0
    /// The held `createTab` call, while it waits.
    var held: CheckedContinuation<Void, Never>?
    /// Whether `releaseCreateTab()` ran.
    var released = false
  }

  /// The fake every call goes to.
  let fake: FakeITerm2Integration
  /// The clock whose virtual time is recorded.
  let clock: ManualAttachClock
  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// Wraps `fake`; `holdsFirstCreateTab` holds the first `createTab` answer (the fake has
  /// already produced it) until `releaseCreateTab()`.
  init(
    _ fake: FakeITerm2Integration,
    clock: ManualAttachClock,
    holdsFirstCreateTab: Bool = false
  ) {
    self.fake = fake
    self.clock = clock
    state = OSAllocatedUnfairLock(initialState: State(holdsFirstCreateTab: holdsFirstCreateTab))
  }

  /// The tmux commands sent so far, oldest first.
  var sent: [SentCommand] { state.withLock { $0.sent } }

  /// Whether the first `createTab` call is being held.
  var isHoldingCreateTab: Bool { state.withLock { $0.held != nil } }

  /// Lets the held `createTab` call (and every later one) answer.
  func releaseCreateTab() {
    let held = state.withLock { state -> CheckedContinuation<Void, Never>? in
      state.released = true
      defer { state.held = nil }
      return state.held
    }
    held?.resume()
  }

  /// Records `command` as sent now.
  private func recordSent(_ command: String) {
    let at = clock.elapsed
    state.withLock { $0.sent.append(SentCommand(command: command, at: at)) }
  }

  /// Forwards to the fake.
  func isRunning() async -> Bool { await fake.isRunning() }

  /// Forwards to the fake.
  func status() async -> ITerm2Status { await fake.status() }

  /// Forwards to the fake.
  func ensureRunning() async throws { try await fake.ensureRunning() }

  /// Forwards to the fake.
  func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    try await fake.listSessions()
  }

  /// Forwards to the fake, then holds the answer if it is the first call and holding is on.
  func createTab(_ request: ITerm2API.CreateTabRequest) async throws
    -> ITerm2API.CreateTabResponse
  {
    let result: Result<ITerm2API.CreateTabResponse, any Error>
    do {
      result = .success(try await fake.createTab(request))
    } catch {
      result = .failure(error)
    }
    let holds = state.withLock { state -> Bool in
      state.createTabCalls += 1
      return state.holdsFirstCreateTab && state.createTabCalls == 1 && !state.released
    }
    if holds {
      await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        let resumeNow = state.withLock { state -> Bool in
          guard !state.released else { return true }
          state.held = continuation
          return false
        }
        if resumeNow { continuation.resume() }
      }
    }
    return try result.get()
  } // End of func createTab(_:)

  /// Forwards to the fake.
  func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] {
    try await fake.listTmuxConnections()
  }

  /// Forwards to the fake and records the command unless it certainly was not sent.
  func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    do {
      let output = try await fake.sendTmuxCommand(command, connectionID: connectionID)
      recordSent(command)
      return output
    } catch let error as ITerm2Error {
      if !error.isNotSent { recordSent(command) }
      throw error
    }
  }

  /// Forwards to the fake and records the command unless it certainly was not sent.
  func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String {
    do {
      let output = try await fake.sendTmuxCommand(
        command, connectionID: connectionID, ownedBy: owningSessionID)
      recordSent(command)
      return output
    } catch let error as ITerm2Error {
      if !error.isNotSent { recordSent(command) }
      throw error
    }
  } // End of func sendTmuxCommand(_:connectionID:ownedBy:)

  /// Forwards to the fake.
  func activate(_ request: ITerm2API.ActivateRequest) async throws {
    try await fake.activate(request)
  }

  /// Forwards to the fake.
  func listProfiles(properties: [String], guids: [String]) async throws -> [ITerm2API.Profile] {
    try await fake.listProfiles(properties: properties, guids: guids)
  }

  /// Forwards to the fake.
  func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse {
    try await fake.close(request)
  }

  /// Forwards to the fake.
  func disconnect() async { await fake.disconnect() }
}

/// Synthetic values and builders for the attach tests.
enum AttachTestSupport {
  /// This Mac.
  static let host = HostConfig(
    id: UUID(uuidString: "00000000-0000-4000-8000-0000000000c1")!, displayName: "This Mac",
    mode: .local)
  /// The tmux server.
  static let server = ServerIdentity(
    socketPath: "/private/tmp/tmux-501/default", pid: 4242, startTime: 1_792_599_999)
  /// The launch tab's iTerm2 session.
  static let gateway = "00000000-0000-4000-8000-000000000001"
  /// The tmux connection.
  static let connection = "fixture-connection-1"
  /// The helper.
  static let helper = try! LaunchHelperPath(
    validating: "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")

  /// The session `$3`, as discovery reports it.
  static func session(
    id: String = "$3",
    server: ServerIdentity = server,
    createdAt: Int64 = 1_792_600_001
  ) -> DiscoveredSession {
    DiscoveredSession(
      key: SessionKey(hostID: host.id, server: server, sessionID: TmuxSessionID(id)!),
      name: "fixture-session", createdAt: createdAt, windowCount: 2, attachedClientCount: 0,
      lastActivityAt: 1_792_600_050, clients: [])
  } // End of func session(id:server:createdAt:)

  /// What the identity check prints for `key`'s server and session.
  static func identityOutput(for key: SessionKey) -> String {
    "\(key.server.pid)\t\(key.server.startTime)\t\(key.server.socketPath)\t\(key.sessionID)\n"
  }

  /// A list-sessions response: an ordinary window, then the connection's two tabs (`t3` with a
  /// two-pane split, `t4`), plus a tab of another connection first.
  static let sessions = ITerm2API.ListSessionsResponse(windows: [
    .init(
      windowID: "w1",
      tabs: [
        .init(tabID: "t1", root: leaves(1), tmuxWindowID: "-1"),
        .init(tabID: "t2", root: leaves(1), tmuxWindowID: "0", tmuxConnectionID: "other"),
      ]),
    .init(
      windowID: "w2",
      tabs: [.init(tabID: "t3", root: leaves(2), tmuxWindowID: "0", tmuxConnectionID: connection)]),
    .init(
      windowID: "w3",
      tabs: [.init(tabID: "t4", root: leaves(1), tmuxWindowID: "1", tmuxConnectionID: connection)]),
  ])

  /// A split tree with `count` session leaves.
  static func leaves(_ count: Int) -> ITerm2API.SplitTreeNode {
    ITerm2API.SplitTreeNode(
      vertical: false,
      links: (0..<count).map { .session(.init(uniqueIdentifier: "leaf-\($0)")) })
  }

  /// An iTerm2 script for a successful attach of `session`: the tab opens as `gateway`, the
  /// connection appears on the first poll, identity matches, tabs are listed.
  static func successScript(for session: DiscoveredSession) -> FakeITerm2Integration.Script {
    var script = FakeITerm2Integration.Script()
    script.createTab = .init(
      .success(.init(status: .ok, windowID: "w9", tabID: 9, sessionID: gateway)))
    script.listTmuxConnections = .init(
      .success([.init(connectionID: connection, owningSessionID: gateway)]))
    script.sendTmuxCommand = .init(.success(identityOutput(for: session.key)))
    script.listSessions = .init(.success(sessions))
    return script
  } // End of func successScript(for:)

  /// A helper result for `request` with `failure`.
  static func result(for request: LaunchRequest, failure: LaunchFailure?) -> LaunchResult {
    LaunchResult(
      id: request.id, helperPID: 777, startedAt: ManualAttachClock.baseDate,
      childStartedAt: nil, endedAt: ManualAttachClock.baseDate,
      childTermination: .exited(failure?.exitStatus ?? 0), failure: failure)
  }

  /// A coordinator over the given fakes.
  static func coordinator(
    iTerm2: any ITerm2Integration,
    discovery: FakeDiscovery,
    store: FakeLaunchStore,
    clock: ManualAttachClock = ManualAttachClock(),
    log: UpdateLog = UpdateLog()
  ) -> AttachCoordinator {
    AttachCoordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, helperPath: helper, clock: clock,
      onUpdate: { log.record($0) })
  } // End of func coordinator(iTerm2:discovery:store:clock:log:)
}
