import Foundation

/// Discovers one host's tmux sessions. `DiscoveryProbe` is the production implementation; tests
/// pass scripted fakes, so the attach coordinator never runs a real probe in `swift test`.
public protocol HostDiscovering: Sendable {
  /// Discovers `host`; see `DiscoveryProbe.discover(_:)`. Throws only `CancellationError`.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult
}

extension DiscoveryProbe: HostDiscovering {}

/// The launch files the attach coordinator writes and reads (PLAN.md D2, D14). `LaunchStore` is
/// the production implementation; tests pass an in-memory fake.
public protocol LaunchRequestStore: Sendable {
  /// Writes a new request file; see `LaunchStore.writeRequest(_:)`.
  func writeRequest(_ request: LaunchRequest) throws(LaunchStoreError)

  /// Deletes a request that is still there; see `LaunchStore.discardRequest(_:)`.
  @discardableResult
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool

  /// Takes the helper's result for `id`, or `nil` while there is none; see
  /// `LaunchStore.takeResult(_:)`.
  func takeResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult?

  /// Reads the helper's result for `id` without taking it, or `nil` while there is none; see
  /// `LaunchStore.peekResult(_:)` (PLAN.md D29: the coordinator's look at a buried launch tab's
  /// helper, after which `detach` still takes the result).
  func peekResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult?

  /// Removes stale launch files; see `LaunchStore.sweep()`.
  @discardableResult
  func sweep() throws(LaunchStoreError) -> Int
}

extension LaunchStore: LaunchRequestStore {}

/// The time source of the attach coordinator: a monotonic clock for budgets and polling, and
/// the wall clock for request timestamps. Tests pass a manual clock whose `sleep(for:)` only
/// advances virtual time, so a 15 s budget runs out at once.
public protocol AttachClock: Sendable {
  /// The current monotonic instant.
  func now() -> ContinuousClock.Instant

  /// Waits for `duration`. Throws `CancellationError` when the calling task is cancelled.
  func sleep(for duration: Duration) async throws

  /// The current wall-clock time (a request's `createdAt`).
  func date() -> Date
}

/// What paces the attach coordinator's look at the launch tabs it buried, besides the
/// attaches, detaches and attachment checks that look too (PLAN.md D29, *Recovery while the app
/// runs*). The timer runs only while the coordinator remembers a buried tab, and each tick is a
/// file-only peek at their helpers' results.
public enum BuriedTabTimer: Sendable {
  /// Every `AttachCoordinator.Configuration.buriedTabCheckInterval` of real time
  /// (`SystemAttachClock`): the app, the probe and the self-tests.
  case system
  /// The same interval on `clock`. Tests pass one whose sleeps end only when the test moves it
  /// on, so each tick happens exactly when the test says.
  case clock(any AttachClock)
  /// No timer: only attaches, detaches and attachment checks look. For tests of other paths,
  /// whose virtual clocks would otherwise turn a timer into a busy loop.
  case off
}

/// The real clocks: `ContinuousClock` and `Date()`.
public struct SystemAttachClock: AttachClock {
  /// Creates the system clock.
  public init() {}

  /// `ContinuousClock.now`.
  public func now() -> ContinuousClock.Instant { .now }

  /// `Task.sleep(for:)`.
  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }

  /// `Date()`.
  public func date() -> Date { Date() }
}
