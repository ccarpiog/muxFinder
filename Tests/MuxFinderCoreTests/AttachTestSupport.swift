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

/// A clock for timeouts: `sleep(for:)` waits until `advance(by:)` moves virtual time past its
/// deadline (or its task is cancelled), so a test decides exactly when a timeout fires.
final class GatedAttachClock: AttachClock {
  /// One waiting sleep.
  private struct Waiter {
    /// When it ends, in virtual time.
    let deadline: Duration
    /// Resumes the sleep.
    let continuation: CheckedContinuation<Void, any Error>
  }

  /// Mutable state.
  private struct State {
    /// Virtual time since `base`.
    var offset: Duration = .zero
    /// Waiting sleeps, by id.
    var waiters: [Int: Waiter] = [:]
    /// Ids of sleeps cancelled before they registered.
    var cancelledEarly: Set<Int> = []
    /// The next sleep's id.
    var nextID = 0
    /// How many sleeps ever started.
    var started = 0
    /// How many sleeps cancellation ended or prevented.
    var cancelled = 0
  }

  /// The real instant virtual time starts from.
  private let base = ContinuousClock.now
  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// `base` plus the virtual time.
  func now() -> ContinuousClock.Instant { base + state.withLock { $0.offset } }

  /// `ManualAttachClock.baseDate` plus the virtual time.
  func date() -> Date {
    let offset = state.withLock { $0.offset }
    return ManualAttachClock.baseDate.addingTimeInterval(Double(offset / .milliseconds(1)) / 1000)
  }

  /// Waits until virtual time reaches now + `duration`, or throws when cancelled. Counts as
  /// started even when its task is cancelled already.
  func sleep(for duration: Duration) async throws {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      state.started += 1
      return state.nextID
    }
    if Task.isCancelled {
      state.withLock { $0.cancelled += 1 }
      throw CancellationError()
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let immediate = state.withLock { state -> Result<Void, any Error>? in
          if state.cancelledEarly.remove(id) != nil {
            state.cancelled += 1
            return .failure(CancellationError())
          }
          guard duration > .zero else { return .success(()) }
          state.waiters[id] = Waiter(deadline: state.offset + duration, continuation: continuation)
          return nil
        }
        if let immediate { continuation.resume(with: immediate) }
      }
    } onCancel: {
      let waiter = state.withLock { state -> Waiter? in
        guard let waiter = state.waiters.removeValue(forKey: id) else {
          state.cancelledEarly.insert(id)
          return nil
        }
        state.cancelled += 1
        return waiter
      }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  } // End of func sleep(for:)

  /// Moves virtual time forward and ends every sleep whose deadline it reaches.
  func advance(by duration: Duration) {
    let due = state.withLock { state -> [Waiter] in
      state.offset += duration
      let due = state.waiters.filter { $0.value.deadline <= state.offset }
      for id in due.keys { state.waiters[id] = nil }
      return Array(due.values)
    }
    for waiter in due { waiter.continuation.resume() }
  } // End of func advance(by:)

  /// How many sleeps wait now.
  var waiting: Int { state.withLock { $0.waiters.count } }

  /// How many sleeps ever started.
  var started: Int { state.withLock { $0.started } }

  /// How many sleeps cancellation ended or prevented (a sleep that ended on its deadline first
  /// is not counted).
  var cancelled: Int { state.withLock { $0.cancelled } }

  /// Virtual time elapsed so far.
  var elapsed: Duration { state.withLock { $0.offset } }
}

/// A scripted `HostDiscovering`: answers with `status` (and a report naming `nodeName`), counts
/// calls, can hold every call until `release()`, and can take a while on a test clock.
final class FakeDiscovery: HostDiscovering {
  /// Mutable state.
  private struct State {
    /// The status every call reports.
    var status: HostStatus
    /// The node name of the report every call carries; `nil` for no report.
    var nodeName: String?
    /// Calls so far.
    var calls = 0
    /// Whether calls wait for `release()`.
    var gated: Bool
    /// Calls waiting for `release()`.
    var waiting: [CheckedContinuation<Void, Never>] = []
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>
  /// How long every call takes on `clock`.
  private let delay: Duration
  /// The clock `delay` passes on; `nil` for no delay.
  private let clock: (any AttachClock)?

  /// Creates a discovery reporting `status` with a report naming `nodeName` (none when `nil`);
  /// `gated` holds calls until `release()`; every call takes `delay` on `clock`, if given.
  init(
    _ status: HostStatus,
    nodeName: String? = AttachTestSupport.nodeName,
    gated: Bool = false,
    takes delay: Duration = .zero,
    on clock: (any AttachClock)? = nil
  ) {
    state = OSAllocatedUnfairLock(
      initialState: State(status: status, nodeName: nodeName, gated: gated))
    self.delay = delay
    self.clock = clock
  } // End of init(_:nodeName:gated:takes:on:)

  /// Changes the status later calls report.
  func setStatus(_ status: HostStatus) {
    state.withLock { $0.status = status }
  }

  /// Reports the scripted status for `host`, after `release()` when gated and after the delay.
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
    if let clock, delay > .zero { try await clock.sleep(for: delay) }
    let (status, nodeName) = state.withLock { ($0.status, $0.nodeName) }
    return DiscoveryResult(
      hostID: host.id, status: status, report: nodeName.map { ProbeReport(nodeName: $0) },
      duration: .milliseconds(5))
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
    /// Whether a helper took every written request first, so `discardRequest(_:)` finds none
    /// to remove (`false`) and the request is not withdrawn in time.
    var helperTakesRequests = false
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

  /// Records the discard; returns whether a file was removed (not when a helper took it).
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    state.withLock { state in
      state.discarded.append(id)
      return !state.helperTakesRequests
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
/// command that reached "iTerm2" (did not fail as not sent), can hold the answer of the first
/// `createTab` call until `releaseCreateTab()`, can make the bound commands of some
/// connections hang (sent, never answered) until their task is cancelled, and can make every
/// plain connection listing take a while on the clock.
final class InstrumentedITerm2: ITerm2Integration {
  /// A tmux command that was sent, and the virtual time it was sent at.
  struct SentCommand: Sendable, Hashable {
    /// The command.
    let command: String
    /// The connection it was sent to.
    let connectionID: String
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
    /// Connections whose bound commands hang.
    var hanging: Set<String>
    /// Bound commands hanging now.
    var hangingNow = 0
    /// Answers to bound commands by connection, used instead of the fake's own answer once
    /// its ownership check passed: first one next, the last one repeats.
    var answers: [String: [Result<String, ITerm2Error>]] = [:]
    /// How long every `listTmuxConnections()` call takes on the clock.
    var listingDelay: Duration = .zero
  }

  /// The fake every call goes to.
  let fake: FakeITerm2Integration
  /// The clock whose virtual time is recorded.
  let clock: any VirtualTimeClock
  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// Wraps `fake`; `holdsFirstCreateTab` holds the first `createTab` answer (the fake has
  /// already produced it) until `releaseCreateTab()`; bound commands to `hanging` connections
  /// are sent (the fake answers them) but their answer never arrives.
  init(
    _ fake: FakeITerm2Integration,
    clock: any VirtualTimeClock,
    holdsFirstCreateTab: Bool = false,
    hanging: Set<String> = []
  ) {
    self.fake = fake
    self.clock = clock
    state = OSAllocatedUnfairLock(
      initialState: State(holdsFirstCreateTab: holdsFirstCreateTab, hanging: hanging))
  }

  /// The tmux commands sent so far, oldest first.
  var sent: [SentCommand] { state.withLock { $0.sent } }

  /// How many bound commands hang now.
  var hangingNow: Int { state.withLock { $0.hangingNow } }

  /// Makes every `listTmuxConnections()` call take `delay` on the clock first.
  func setListingDelay(_ delay: Duration) {
    state.withLock { $0.listingDelay = delay }
  }

  /// Sets the answers bound commands to `connectionID` get, in order (the last one repeats).
  func setAnswers(_ answers: [Result<String, ITerm2Error>], for connectionID: String) {
    state.withLock { $0.answers[connectionID] = answers }
  }

  /// The next scripted answer for `connectionID`, if it has any.
  private func nextAnswer(for connectionID: String) -> Result<String, ITerm2Error>? {
    state.withLock { state -> Result<String, ITerm2Error>? in
      guard var queue = state.answers[connectionID], let first = queue.first else { return nil }
      if queue.count > 1 {
        queue.removeFirst()
        state.answers[connectionID] = queue
      }
      return first
    }
  } // End of func nextAnswer(for:)

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

  /// Records `command` as sent to `connectionID` now.
  private func recordSent(_ command: String, to connectionID: String) {
    let at = clock.elapsed
    state.withLock {
      $0.sent.append(SentCommand(command: command, connectionID: connectionID, at: at))
    }
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

  /// Waits for the listing delay, if any, then forwards to the fake.
  func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] {
    let delay = state.withLock { $0.listingDelay }
    if delay > .zero { try await clock.sleep(for: delay) }
    return try await fake.listTmuxConnections()
  }

  /// Forwards to the fake and records the command unless it certainly was not sent.
  func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    do {
      let output = try await fake.sendTmuxCommand(command, connectionID: connectionID)
      recordSent(command, to: connectionID)
      return output
    } catch let error as ITerm2Error {
      if !error.isNotSent { recordSent(command, to: connectionID) }
      throw error
    }
  }

  /// Forwards to the fake and records the command unless it certainly was not sent; a
  /// connection with scripted answers then gets its next one instead of the fake's. For a
  /// hanging connection it then waits until the task is cancelled and throws
  /// `CancellationError` (sent, never answered).
  func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String {
    let output: String
    do {
      output = try await fake.sendTmuxCommand(
        command, connectionID: connectionID, ownedBy: owningSessionID)
      recordSent(command, to: connectionID)
    } catch let error as ITerm2Error {
      if !error.isNotSent { recordSent(command, to: connectionID) }
      throw error
    }
    let hangs = state.withLock { state -> Bool in
      guard state.hanging.contains(connectionID) else { return false }
      state.hangingNow += 1
      return true
    }
    guard hangs else { return try nextAnswer(for: connectionID)?.get() ?? output }
    defer { state.withLock { $0.hangingNow -= 1 } }
    try await Task.sleep(for: .seconds(3600))
    throw CancellationError()
  } // End of func sendTmuxCommand(_:connectionID:ownedBy:)

  /// Forwards to the fake.
  func activate(_ request: ITerm2API.ActivateRequest) async throws {
    try await fake.activate(request)
  }

  /// Forwards to the fake.
  func activateFirstTab(
    ofTmuxConnection connectionID: String,
    ownedBy owningSessionID: String,
    options: ITerm2API.ActivateRequest
  ) async throws -> String? {
    try await fake.activateFirstTab(
      ofTmuxConnection: connectionID, ownedBy: owningSessionID, options: options)
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
  /// This Mac's `uname -n`, as the fake discovery reports it.
  static let nodeName = "fixture-node.local"
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

  /// What the identity check prints for `key`'s server and session on the host `host`, through
  /// a client in UTF-8 mode unless `utf8` is `false`.
  static func identityOutput(
    for key: SessionKey,
    host: String = nodeName,
    utf8: Bool = true
  ) -> String {
    identityLine(
      host: host, pid: "\(key.server.pid)", startTime: "\(key.server.startTime)",
      socketPath: key.server.socketPath, sessionID: key.sessionID.rawValue, utf8: utf8) + "\n"
  } // End of func identityOutput(for:host:utf8:)

  /// One line in `ConnectionIdentity.command`'s format, as tmux prints it: the UTF-8 flag, the
  /// host name and socket path each after its length in bytes (or the given lengths, for
  /// answers whose fields tmux shortened), the pid, start time and session id. Every value is
  /// synthetic; the defaults are the fixture server's session `$3` on `nodeName`.
  static func identityLine(
    host: String = nodeName,
    pid: String = "4242",
    startTime: String = "1792599999",
    socketPath: String = server.socketPath,
    sessionID: String = "$3",
    utf8: Bool = true,
    hostLength: Int? = nil,
    socketLength: Int? = nil
  ) -> String {
    "\(utf8 ? 1 : 0):\(hostLength ?? host.utf8.count):\(host):\(pid):\(startTime):"
      + "\(socketLength ?? socketPath.utf8.count):\(socketPath):\(sessionID)"
  } // End of func identityLine(host:pid:startTime:socketPath:sessionID:utf8:hostLength:…)

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

  /// A coordinator over the given fakes. The existing-attachment check is off unless asked
  /// for, so the launch-path tests see only the launch's calls.
  static func coordinator(
    iTerm2: any ITerm2Integration,
    discovery: FakeDiscovery,
    store: FakeLaunchStore,
    clock: any AttachClock = ManualAttachClock(),
    existingAttachments: AttachCoordinator.ExistingAttachmentCheck = .off,
    log: UpdateLog = UpdateLog()
  ) -> AttachCoordinator {
    AttachCoordinator(
      iTerm2: iTerm2, discovery: discovery, store: store, helperPath: helper, clock: clock,
      existingAttachments: existingAttachments, onUpdate: { log.record($0) })
  } // End of func coordinator(iTerm2:discovery:store:clock:existingAttachments:log:)

  /// An attachment index over `iTerm2` whose timeouts never fire (its clock is never
  /// advanced), so answers decide every outcome.
  static func patientIndex(
    _ iTerm2: any ITerm2Integration,
    includes: (@Sendable (ITerm2API.TmuxConnection) -> Bool)? = nil
  ) -> AttachmentIndex {
    AttachmentIndex(
      iTerm2: iTerm2, clock: GatedAttachClock(), configuration: .init(includes: includes))
  }

  /// This Mac as the index matches it: `nodeName` and the fixture server.
  static let indexHost = AttachmentIndex.Host(
    hostID: host.id, nodeName: nodeName, servers: [server])
}

/// A test clock that reports how much virtual time has passed.
protocol VirtualTimeClock: AttachClock {
  /// Virtual time elapsed so far.
  var elapsed: Duration { get }
}

extension ManualAttachClock: VirtualTimeClock {}

extension GatedAttachClock: VirtualTimeClock {}
