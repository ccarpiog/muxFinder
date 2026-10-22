import Foundation
import os

@testable import MuxFinderCore

/// A scripted `HostDiscovering` for the refresh tests. A host with an automatic answer gets it
/// at once. Any other call waits until the test answers it; cancelling its task makes it throw
/// `CancellationError`, unless the prober ignores cancellation: then the call keeps waiting for
/// its answer, like a probe whose process ended just as it was cancelled. Counts calls, calls
/// running at once and cancellations.
final class ScriptedProber: HostDiscovering {
  /// One `discover(_:)` call.
  struct Call: Sendable {
    /// 1 for the first call, then counting up.
    let number: Int
    /// The host it was for.
    let host: HostConfig
  }

  /// A call waiting for its answer.
  private struct Waiting {
    /// The call.
    let call: Call
    /// Resumes it: a status, or `nil` for cancelled.
    let continuation: CheckedContinuation<HostStatus?, Never>
  }

  /// Mutable state.
  private struct State {
    /// Every call, in order.
    var calls: [Call] = []
    /// Calls waiting for an answer, by number.
    var waiting: [Int: Waiting] = [:]
    /// Calls cancelled before they started waiting.
    var cancelledEarly: Set<Int> = []
    /// Automatic answers, by host.
    var automatic: [UUID: HostStatus] = [:]
    /// Calls in progress.
    var running = 0
    /// The most calls ever in progress at once.
    var maxRunning = 0
    /// Calls in progress, by host.
    var runningByHost: [UUID: Int] = [:]
    /// The most calls ever in progress at once for one host, by host.
    var maxRunningByHost: [UUID: Int] = [:]
    /// Calls that ended cancelled.
    var cancelled = 0
  }

  /// Whether waiting calls ignore cancellation.
  let ignoresCancellation: Bool
  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a prober with no automatic answers.
  init(ignoresCancellation: Bool = false) {
    self.ignoresCancellation = ignoresCancellation
  }

  /// Answers every later call for `hostID` with `status` at once (`nil`: wait again).
  func setAnswer(_ status: HostStatus?, for hostID: UUID) {
    state.withLock { $0.automatic[hostID] = status }
  }

  /// Records the call, then answers it automatically or waits for the test.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    let (number, automatic) = state.withLock { state -> (Int, HostStatus?) in
      let number = state.calls.count + 1
      state.calls.append(Call(number: number, host: host))
      state.running += 1
      state.maxRunning = max(state.maxRunning, state.running)
      let hostRunning = state.runningByHost[host.id, default: 0] + 1
      state.runningByHost[host.id] = hostRunning
      state.maxRunningByHost[host.id] = max(state.maxRunningByHost[host.id] ?? 0, hostRunning)
      return (number, state.automatic[host.id])
    }
    defer {
      state.withLock { state in
        state.running -= 1
        state.runningByHost[host.id, default: 0] -= 1
      }
    }
    let status: HostStatus?
    if let automatic {
      status = automatic
    } else {
      status = await wait(for: Call(number: number, host: host))
    }
    guard let status else {
      state.withLock { $0.cancelled += 1 }
      throw CancellationError()
    }
    let report: ProbeReport? =
      switch status {
      case .ok, .noServer: ProbeReport(nodeName: RefreshTestSupport.nodeName(of: host))
      default: nil
      }
    return DiscoveryResult(
      hostID: host.id, status: status, report: report, duration: .milliseconds(5))
  } // End of func discover(_:)

  /// Waits until `call` is answered (its status) or cancelled (`nil`).
  private func wait(for call: Call) async -> HostStatus? {
    let ignores = ignoresCancellation
    let number = call.number
    return await withTaskCancellationHandler {
      await withCheckedContinuation { (continuation: CheckedContinuation<HostStatus?, Never>) in
        let cancelled = state.withLock { state -> Bool in
          if !ignores, state.cancelledEarly.remove(number) != nil { return true }
          state.waiting[number] = Waiting(call: call, continuation: continuation)
          return false
        }
        if cancelled { continuation.resume(returning: nil) }
      }
    } onCancel: {
      guard !ignores else { return }
      let waiting = state.withLock { state -> Waiting? in
        guard let waiting = state.waiting.removeValue(forKey: number) else {
          state.cancelledEarly.insert(number)
          return nil
        }
        return waiting
      }
      waiting?.continuation.resume(returning: nil)
    }
  } // End of func wait(for:)

  /// Answers the waiting call `number` with `status`; returns whether it was waiting.
  @discardableResult
  func answer(_ number: Int, with status: HostStatus) -> Bool {
    let waiting = state.withLock { $0.waiting.removeValue(forKey: number) }
    waiting?.continuation.resume(returning: status)
    return waiting != nil
  }

  /// Answers the oldest waiting call for `hostID`; returns whether there was one.
  @discardableResult
  func answerNext(_ hostID: UUID, with status: HostStatus) -> Bool {
    guard let number = waitingCalls(of: hostID).first else { return false }
    return answer(number, with: status)
  }

  /// The numbers of the calls for `hostID` waiting for an answer, oldest first.
  func waitingCalls(of hostID: UUID) -> [Int] {
    state.withLock { state in
      state.waiting.values.filter { $0.call.host.id == hostID }.map(\.call.number).sorted()
    }
  }

  /// Every call so far.
  var calls: [Call] { state.withLock { $0.calls } }

  /// How many calls there were for `hostID`.
  func callCount(of hostID: UUID) -> Int {
    state.withLock { state in state.calls.filter { $0.host.id == hostID }.count }
  }

  /// Calls in progress.
  var running: Int { state.withLock { $0.running } }

  /// The most calls ever in progress at once.
  var maxRunning: Int { state.withLock { $0.maxRunning } }

  /// The most calls for `hostID` ever in progress at once.
  func maxRunning(of hostID: UUID) -> Int {
    state.withLock { $0.maxRunningByHost[hostID] ?? 0 }
  }

  /// Calls that ended cancelled.
  var cancelled: Int { state.withLock { $0.cancelled } }
}

/// A private notification center that counts the observers registered and not removed yet,
/// and can run a hook inside the first `addObserver(forName:object:queue:using:)` call (to put
/// something in the middle of `RefreshSystemEvents.start()`).
final class CountingNotificationCenter: NotificationCenter, @unchecked Sendable {
  /// Mutable state.
  private struct State {
    /// The registered observers not removed yet.
    var live: Set<ObjectIdentifier> = []
    /// Runs inside the next registration, then is cleared.
    var hook: (@Sendable () -> Void)?
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  /// Runs `hook` inside the next registration, on the registering thread, before it returns.
  func runInsideNextRegistration(_ hook: @escaping @Sendable () -> Void) {
    state.withLock { $0.hook = hook }
  }

  /// Registers the observer, counts it, and runs the hook if one is set.
  override func addObserver(
    forName name: NSNotification.Name?,
    object obj: Any?,
    queue: OperationQueue?,
    using block: @escaping @Sendable (Notification) -> Void
  ) -> any NSObjectProtocol {
    let token = super.addObserver(forName: name, object: obj, queue: queue, using: block)
    let id = ObjectIdentifier(token)
    let hook = state.withLock { state -> (@Sendable () -> Void)? in
      state.live.insert(id)
      defer { state.hook = nil }
      return state.hook
    }
    hook?()
    return token
  } // End of func addObserver(forName:object:queue:using:)

  /// Removes the observer and stops counting it.
  override func removeObserver(_ observer: Any) {
    super.removeObserver(observer)
    let id = ObjectIdentifier(observer as AnyObject)
    state.withLock { _ = $0.live.remove(id) }
  }

  /// Observers registered and not removed yet.
  var liveObservers: Int { state.withLock { $0.live.count } }
}

/// A scripted attachment index: answers, fails or hangs until cancelled, and records the hosts
/// of every call. Never contacts iTerm2.
final class FakeAttachmentIndex: AttachmentIndexing {
  /// What `snapshot(of:)` does.
  enum Behavior: Sendable {
    /// Returns this snapshot.
    case answer(AttachmentSnapshot)
    /// Throws this error.
    case fail(ITerm2Error)
    /// Waits until cancelled, then throws `CancellationError`.
    case hang
  }

  /// Mutable state.
  private struct State {
    /// The current behavior.
    var behavior: Behavior
    /// The hosts of every call, in order.
    var calls: [[AttachmentIndex.Host]] = []
    /// Hanging calls, by number.
    var hanging: [Int: CheckedContinuation<Void, Never>] = [:]
    /// Hanging calls cancelled before they started waiting.
    var cancelledEarly: Set<Int> = []
    /// Calls that ended cancelled.
    var cancelled = 0
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// Creates an index with `behavior`.
  init(_ behavior: Behavior) {
    state = OSAllocatedUnfairLock(initialState: State(behavior: behavior))
  }

  /// Changes what later calls do.
  func setBehavior(_ behavior: Behavior) {
    state.withLock { $0.behavior = behavior }
  }

  /// Records `hosts` and plays the behavior.
  func snapshot(of hosts: [AttachmentIndex.Host]) async throws -> AttachmentSnapshot {
    let (number, behavior) = state.withLock { state -> (Int, Behavior) in
      state.calls.append(hosts)
      return (state.calls.count, state.behavior)
    }
    switch behavior {
    case .answer(let snapshot):
      return snapshot
    case .fail(let error):
      throw error
    case .hang:
      await withTaskCancellationHandler {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
          let cancelled = state.withLock { state -> Bool in
            if state.cancelledEarly.remove(number) != nil { return true }
            state.hanging[number] = continuation
            return false
          }
          if cancelled { continuation.resume() }
        }
      } onCancel: {
        let hanging = state.withLock { state -> CheckedContinuation<Void, Never>? in
          guard let hanging = state.hanging.removeValue(forKey: number) else {
            state.cancelledEarly.insert(number)
            return nil
          }
          return hanging
        }
        hanging?.resume()
      }
      state.withLock { $0.cancelled += 1 }
      throw CancellationError()
    }
  } // End of func snapshot(of:)

  /// The hosts of every call, in order.
  var calls: [[AttachmentIndex.Host]] { state.withLock { $0.calls } }

  /// Calls that ended cancelled.
  var cancelled: Int { state.withLock { $0.cancelled } }
}

/// Collects every state a coordinator publishes until its stream ends.
final class StateRecorder: Sendable {
  /// The states so far.
  private let states: OSAllocatedUnfairLock<[RefreshState]>
  /// Reads the stream.
  private let reader: Task<Void, Never>

  /// Starts reading `stream`.
  init(_ stream: AsyncStream<RefreshState>) {
    let states = OSAllocatedUnfairLock<[RefreshState]>(initialState: [])
    self.states = states
    reader = Task {
      for await state in stream { states.withLock { $0.append(state) } }
    }
  }

  /// Every state received so far.
  var all: [RefreshState] { states.withLock { $0 } }

  /// Waits until the stream has ended (after `stop()`).
  func finished() async {
    await reader.value
  }
}

/// Synthetic hosts, sessions and helpers for the refresh tests. Every name and address is
/// made up (`.example`).
enum RefreshTestSupport {
  /// The default tmux server every synthetic session lives in unless told otherwise.
  static let server = ServerIdentity(
    socketPath: "/private/tmp/tmux-501/default", pid: 4242, startTime: 1_792_599_999)

  /// An enabled SSH host named `name` whose destination is `destination` (by default
  /// `<name>.example`).
  static func sshHost(_ name: String, destination: String? = nil) -> HostConfig {
    HostConfig(displayName: name, mode: .ssh, sshDestination: destination ?? "\(name).example")
  }

  /// This Mac.
  static func thisMac() -> HostConfig {
    HostConfig(displayName: "This Mac", mode: .local)
  }

  /// The host list of `hosts`, which must be valid.
  static func list(_ hosts: [HostConfig]) -> HostList {
    try! HostList(hosts)
  }

  /// The node name the scripted prober reports for `host`.
  static func nodeName(of host: HostConfig) -> String {
    "node-\(host.displayName.lowercased()).example"
  }

  /// A session `id` named `name` on `host`'s `server`.
  static func session(
    on host: HostConfig,
    id: String = "$1",
    name: String = "work",
    server: ServerIdentity = server
  ) -> DiscoveredSession {
    DiscoveredSession(
      key: SessionKey(hostID: host.id, server: server, sessionID: TmuxSessionID(id)!),
      name: name, createdAt: 1_792_600_001, windowCount: 2, attachedClientCount: 0,
      lastActivityAt: 1_792_600_050, clients: [])
  } // End of func session(on:id:name:server:)

  /// A coordinator over `hosts` with the given fakes.
  static func coordinator(
    _ hosts: [HostConfig],
    prober: ScriptedProber,
    index: FakeAttachmentIndex? = nil,
    clock: GatedAttachClock
  ) -> RefreshCoordinator {
    RefreshCoordinator(
      hosts: list(hosts), discovery: prober, attachmentIndex: index, clock: clock)
  }

  /// Polls `condition` every 5 ms until it holds or `limit` passes; returns the final value.
  /// Only for waiting on something the code under test does asynchronously, never to order
  /// steps by time.
  static func waitUntil(
    within limit: Duration = .seconds(10),
    _ condition: () async -> Bool
  ) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + limit
    while clock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
  } // End of func waitUntil(within:_:)
}
