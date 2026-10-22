import Foundation
import Network
import os

/// Forwards system sleep, wake and network path changes to a `RefreshCoordinator` (PLAN.md
/// D20), in the order they happen. The app creates one and calls `start()` (Phase 8).
///
/// - Sleep and wake come from the notification center the app passes in,
///   `NSWorkspace.shared.notificationCenter`. MuxFinderCore does not link AppKit (the launch
///   helper links this library), so the two notification names are spelled out here.
/// - Network path changes come from an `NWPathMonitor`. Its first update only reports the
///   current path and is not forwarded; neither is an update equal to the previous one.
/// - Every event goes through one ordered stream read by one task, so a wake never overtakes
///   the sleep before it, and the sleep's cancellation (which waits for the probes to end)
///   finishes before the wake is handled. macOS does not wait for that cancellation before
///   sleeping; a probe frozen by sleep is killed when the system wakes.
/// - `start()` and `stop()` may be called from any thread, even at the same time. Each start
///   and each stop opens a new lifecycle generation. A start claims its generation together
///   with the stream and its reader, then registers its observers and monitor and installs
///   them only if its generation is still the current one; if a `stop()` (or a stop and a
///   newer start) came in between, it removes them itself before returning. Events are
///   forwarded only from the current generation's observers and monitor.
public final class RefreshSystemEvents: Sendable {
  /// `NSWorkspace.willSleepNotification`.
  public static let willSleepNotification = Notification.Name("NSWorkspaceWillSleepNotification")
  /// `NSWorkspace.didWakeNotification`.
  public static let didWakeNotification = Notification.Name("NSWorkspaceDidWakeNotification")

  /// One forwarded event.
  enum Event: Sendable, Hashable {
    /// The system is about to sleep.
    case willSleep
    /// The system woke.
    case didWake
    /// The network path changed.
    case networkPathChanged
  }

  /// A notification observer token. `NotificationCenter.removeObserver(_:)` may be called
  /// from any thread, which is all the token is used for.
  private struct Observer: @unchecked Sendable {
    /// The token `addObserver(forName:object:queue:using:)` returned.
    let token: any NSObjectProtocol
  }

  /// Mutable state.
  private struct State {
    /// The notification observers.
    var observers: [Observer] = []
    /// The path monitor.
    var monitor: NWPathMonitor?
    /// Feeds the event stream while started.
    var continuation: AsyncStream<Event>.Continuation?
    /// Reads the event stream.
    var consumer: Task<Void, Never>?
    /// Decides which path updates are changes.
    var paths = ChangeFilter<NWPath>()
    /// Increases with every `start()` that starts and every `stop()`.
    var generation = 0
  }

  /// The engine the events go to.
  private let coordinator: RefreshCoordinator
  /// Where sleep and wake notifications are posted.
  private let notificationCenter: NotificationCenter
  /// Whether to watch the network path.
  private let watchesNetworkPath: Bool
  /// The state.
  private let state = OSAllocatedUnfairLock(uncheckedState: State())

  /// Creates an adapter for `coordinator` listening on `notificationCenter` (the app passes
  /// `NSWorkspace.shared.notificationCenter`). Nothing is observed until `start()`.
  public init(
    coordinator: RefreshCoordinator,
    notificationCenter: NotificationCenter,
    watchesNetworkPath: Bool = true
  ) {
    self.coordinator = coordinator
    self.notificationCenter = notificationCenter
    self.watchesNetworkPath = watchesNetworkPath
  }

  /// Starts observing. A second call while started does nothing. A `stop()` that runs before
  /// this returns wins: whatever this call registered is removed before it returns.
  public func start() {
    let (stream, continuation) = AsyncStream.makeStream(of: Event.self)
    let coordinator = self.coordinator
    let consumer = Task.detached {
      for await event in stream {
        switch event {
        case .willSleep: await coordinator.systemWillSleep()
        case .didWake: await coordinator.systemDidWake()
        case .networkPathChanged: await coordinator.networkPathChanged()
        }
      }
    }
    // Claims a generation with the stream and its reader, so a `stop()` from now on finishes
    // that stream and waits for that reader.
    let claimed = state.withLock { state -> Int? in
      guard state.continuation == nil else { return nil }
      state.generation += 1
      state.continuation = continuation
      state.consumer = consumer
      state.paths = ChangeFilter()
      return state.generation
    }
    guard let generation = claimed else {
      continuation.finish()
      return
    }
    let events = [
      (Self.willSleepNotification, Event.willSleep), (Self.didWakeNotification, Event.didWake),
    ]
    let observers = events.map { name, event in
      Observer(
        token: notificationCenter.addObserver(forName: name, object: nil, queue: nil) {
          [weak self] _ in self?.deliver(event, from: generation)
        })
    }
    let monitor = watchesNetworkPath ? NWPathMonitor() : nil
    monitor?.pathUpdateHandler = { [weak self] path in
      self?.pathUpdated(path, from: generation)
    }
    monitor?.start(queue: DispatchQueue(label: "cc.carpio.muxfinder.network-path"))
    let installed = state.withLock { state -> Bool in
      guard state.generation == generation else { return false }
      state.observers = observers
      state.monitor = monitor
      return true
    }
    guard !installed else { return }
    // A stop came in between: it finished this call's stream and waits for its reader, but
    // what this call registered after the claim is this call's to remove.
    for observer in observers { notificationCenter.removeObserver(observer.token) }
    monitor?.cancel()
  } // End of func start()

  /// Stops observing and returns once every event already received has been handled.
  public func stop() async {
    let (observers, monitor, continuation, consumer) = state.withLock { state in
      defer {
        state.observers = []
        state.monitor = nil
        state.continuation = nil
        state.consumer = nil
        state.generation += 1
      }
      return (state.observers, state.monitor, state.continuation, state.consumer)
    }
    for observer in observers { notificationCenter.removeObserver(observer.token) }
    monitor?.cancel()
    continuation?.finish()
    await consumer?.value
  } // End of func stop()

  /// Queues `event` for the coordinator, if started (tests call this directly).
  func deliver(_ event: Event) {
    _ = state.withLock { $0.continuation }?.yield(event)
  }

  /// Queues `event` from an observer of start `generation`, unless that start has ended.
  private func deliver(_ event: Event, from generation: Int) {
    let continuation = state.withLock { state in
      state.generation == generation ? state.continuation : nil
    }
    _ = continuation?.yield(event)
  }

  /// Forwards a path update from the monitor of start `generation` that changes the path,
  /// unless that start has ended.
  private func pathUpdated(_ path: NWPath, from generation: Int) {
    let isChange = state.withLock { state in
      state.generation == generation && state.paths.isChange(path)
    }
    if isChange { deliver(.networkPathChanged, from: generation) }
  }
}

/// Tells changes from repeats in a series of values: the first value is the baseline and no
/// change; after it, a value is a change when it differs from the one before.
struct ChangeFilter<Value: Equatable> {
  /// The previous value.
  private var last: Value?

  /// Records `value` and returns whether it changes the previous one.
  mutating func isChange(_ value: Value) -> Bool {
    defer { last = value }
    guard let last else { return false }
    return last != value
  }
}
