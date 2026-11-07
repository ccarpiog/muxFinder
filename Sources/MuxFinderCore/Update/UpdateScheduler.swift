import Foundation

/// The time source of the update scheduler: the wall clock, which the persisted dates are on,
/// and a sleep. Tests pass a manual clock whose sleeps end only when the test moves it on.
public protocol UpdateClock: Sendable {
  /// The current wall-clock time.
  func date() -> Date

  /// Waits for `duration`. Throws `CancellationError` when the calling task is cancelled.
  func sleep(for duration: Duration) async throws
}

/// The real clock: `Date()` and `Task.sleep(for:)` (on the continuous clock, which keeps
/// counting while the Mac sleeps).
public struct SystemUpdateClock: UpdateClock {
  /// Creates the system clock.
  public init() {}

  /// `Date()`.
  public func date() -> Date { Date() }

  /// `Task.sleep(for:)`.
  public func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: duration)
  }
}

/// A check's outcome with when it ended and whether the user asked for it.
public struct UpdateCheckRecord: Sendable, Hashable {
  /// What the check came to.
  public var outcome: UpdateCheckOutcome
  /// When it ended.
  public var date: Date
  /// Whether it was a manual check ("Check for updates…").
  public var manual: Bool

  /// Creates a record.
  public init(outcome: UpdateCheckOutcome, date: Date, manual: Bool) {
    self.outcome = outcome
    self.date = date
    self.manual = manual
  }
}

/// What the scheduler publishes (PLAN.md D39), for Settings' status line and the popover's
/// notice (Phase I-13c).
public struct UpdateCheckStatus: Sendable, Hashable {
  /// Whether a request is in flight.
  public enum Activity: Sendable, Hashable {
    /// No request is in flight.
    case idle
    /// A request is in flight; `manual` when the user asked for it.
    case checking(manual: Bool)
  }

  /// Whether a request is in flight.
  public var activity: Activity
  /// The last check's outcome, with its time; `nil` before the first since launch.
  public var lastCheck: UpdateCheckRecord?
  /// What the kept release offers the running app (recomputed at every publication); `nil`
  /// when no release is kept.
  public var offer: UpdateOffer?
  /// When a check last succeeded, from the state file or this run.
  public var lastSuccessfulCheck: Date?
  /// The version whose notice the user has seen (`UpdateState.noticeSeenVersion`, for the menu
  /// bar icon's dot, Phase I-13c1); `nil` when none is recorded.
  public var noticeSeenVersion: UpdateVersion?

  /// Creates a status.
  public init(
    activity: Activity = .idle, lastCheck: UpdateCheckRecord? = nil, offer: UpdateOffer? = nil,
    lastSuccessfulCheck: Date? = nil, noticeSeenVersion: UpdateVersion? = nil
  ) {
    self.activity = activity
    self.lastCheck = lastCheck
    self.offer = offer
    self.lastSuccessfulCheck = lastSuccessfulCheck
    self.noticeSeenVersion = noticeSeenVersion
  }
}

/// Decides when the update check runs and runs it (PLAN.md D39), over an injected transport,
/// state store and clock. Nothing happens until `start(automaticChecks:)`; construction sends
/// nothing and reads nothing.
///
/// - **Automatic checks** run only while automatic checks are on and the scheduler is started:
///   when never checked, or 24 hours after the last successful check (a last check in the
///   future, after the clock went back, counts as due); never sooner than an hour after the
///   last attempt, nor before the rate limit's date; and the first never sooner than 5 seconds
///   after `start`, which never blocks. None is armed or started before the state has loaded,
///   however late the load ends: a wake or a toggle that arrives meanwhile is worked out when
///   it ends. Between events the scheduler sleeps until the next due time; `woke()` (the Mac
///   woke, or the system clock changed) and `setAutomaticChecks(_:)` work it out again.
/// - **A manual check** (`checkNow()`) waits for the state's load, then runs whether automatic
///   checks are on or off, joins a check already in flight, and during a rate limit (the
///   loaded one included) answers `rateLimited` without sending.
/// - At most one request is in flight. The attempt is saved before the request is sent and the
///   result after it; a state that cannot be saved is still used in memory.
/// - Saves of the state run one at a time, in the order they were asked for, each writing the
///   state as it is when its turn comes, so a check's save and a seen mark's
///   (`markNoticeSeen(_:)`) never lose each other's fields.
/// - Background failures are silent: their outcome is only published, for Settings' status
///   line; a manual check's outcome is its result.
public actor UpdateScheduler {
  /// Timing.
  public struct Configuration: Sendable, Hashable {
    /// How long after `start` the first automatic check may run.
    public var launchDelay: TimeInterval
    /// How long after a successful check the next automatic one is due.
    public var successInterval: TimeInterval
    /// The shortest time between two automatic attempts.
    public var retryInterval: TimeInterval

    /// The app's timing: 5 s, 24 h and 1 h.
    public init(
      launchDelay: TimeInterval = 5, successInterval: TimeInterval = 24 * 60 * 60,
      retryInterval: TimeInterval = 60 * 60
    ) {
      self.launchDelay = launchDelay
      self.successInterval = successInterval
      self.retryInterval = retryInterval
    }
  }

  /// Whether the scheduler runs.
  enum Lifecycle: Sendable, Equatable {
    /// Not started yet: only manual checks run.
    case idle
    /// Started.
    case running
    /// Stopped: nothing runs any more.
    case stopped
  }

  /// A timer waiting for the next automatic check.
  struct Timer {
    /// Identifies this timer; a fire whose token is not the current timer's is ignored.
    let token: Int
    /// When it fires, on the wall clock.
    let due: Date
    /// The sleeping task.
    let task: Task<Void, Never>
  }

  /// The timing.
  public nonisolated let configuration: Configuration
  /// The running app's `CFBundleShortVersionString`, or `nil`.
  public nonisolated let runningVersion: String?
  /// Sends the request.
  private let transport: any UpdateCheckTransport
  /// Keeps the state.
  private let stateStore: any UpdateStateStoring
  /// The time source.
  private let clock: any UpdateClock

  /// Whether the scheduler runs.
  private(set) var lifecycle = Lifecycle.idle
  /// Whether automatic checks are on (`checkForUpdatesAutomatically`).
  private(set) var automaticChecks = false
  /// The state, loaded once.
  private var state = UpdateState()
  /// The load of the state, started by the first event that needs it.
  private var loading: Task<UpdateState, Never>?
  /// Whether `state` holds the loaded state.
  private var loaded = false
  /// No automatic check runs before this date (`start` plus the launch delay); `nil` once it
  /// has passed.
  private var launchGate: Date?
  /// The timer waiting for the next automatic check.
  private var timer: Timer?
  /// The last timer token handed out.
  private var lastToken = 0
  /// The check in flight.
  private var inFlight: Task<UpdateCheckOutcome, Never>?
  /// Whether the check in flight is manual.
  private var inFlightIsManual = false
  /// The last check's record.
  private var lastCheck: UpdateCheckRecord?
  /// Subscribers of `updates()`.
  private var subscribers: [Int: AsyncStream<UpdateCheckStatus>.Continuation] = [:]
  /// The last subscriber number handed out.
  private var lastSubscriberID = 0
  /// Whether a save of the state holds the turn (saves run one at a time).
  private var isSaving = false
  /// Saves waiting for their turn, in the order they asked.
  private var saveWaiters: [CheckedContinuation<Void, Never>] = []

  /// Requests sent (diagnostics and tests).
  private(set) var requestsSent = 0
  /// Saves of the state that failed (diagnostics and tests).
  private(set) var failedSaves = 0
  /// Manual checks that joined a check in flight (diagnostics and tests).
  private(set) var joinedChecks = 0
  /// Saves of the state waiting for another one to end (diagnostics and tests).
  var savesWaiting: Int { saveWaiters.count }

  /// A scheduler that sends through `transport`, keeps its state in `stateStore` and runs on
  /// `clock`, for an app running `runningVersion`. Nothing runs until `start`.
  public init(
    transport: any UpdateCheckTransport,
    stateStore: any UpdateStateStoring,
    runningVersion: String?,
    clock: any UpdateClock = SystemUpdateClock(),
    configuration: Configuration = Configuration()
  ) {
    self.transport = transport
    self.stateStore = stateStore
    self.runningVersion = runningVersion
    self.clock = clock
    self.configuration = configuration
  } // End of init(transport:stateStore:runningVersion:clock:configuration:)

  /// Cancels the timer and the check in flight if the scheduler goes away without `stop()`.
  deinit {
    timer?.task.cancel()
    inFlight?.cancel()
    for continuation in subscribers.values { continuation.finish() }
  }

  // MARK: - Reading

  /// The current status.
  public var status: UpdateCheckStatus {
    UpdateCheckStatus(
      activity: inFlight == nil ? .idle : .checking(manual: inFlightIsManual),
      lastCheck: lastCheck,
      offer: UpdateCheck.offer(state, runningVersion: runningVersion),
      lastSuccessfulCheck: state.lastSuccessfulCheck,
      noticeSeenVersion: state.noticeSeenVersion)
  }

  /// A stream of statuses: the current one at once, then one after every change, until
  /// `stop()`. A slow reader only gets the newest.
  public func updates() -> AsyncStream<UpdateCheckStatus> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: UpdateCheckStatus.self, bufferingPolicy: .bufferingNewest(1))
    continuation.yield(status)
    if lifecycle == .stopped {
      continuation.finish()
    } else {
      lastSubscriberID += 1
      subscribers[lastSubscriberID] = continuation
    }
    return stream
  } // End of func updates()

  /// When the next automatic check is due by the rules, or `nil` when none is (automatic
  /// checks off, not started, the state not loaded yet, or stopped). Diagnostics and tests.
  public func nextAutomaticCheck() -> Date? {
    automaticDue(now: clock.date())
  }

  // MARK: - Events

  /// Starts the scheduler: loads the state and, once it has loaded, with automatic checks on
  /// (as `automaticChecks` or a `setAutomaticChecks(_:)` during the load left them), arms the
  /// first automatic check, never sooner than the launch delay. Calling it again does nothing.
  public func start(automaticChecks: Bool) async {
    guard lifecycle == .idle else { return }
    lifecycle = .running
    self.automaticChecks = automaticChecks
    launchGate = clock.date().addingTimeInterval(configuration.launchDelay)
    await loadState()
    rearm()
    publish()
  }

  /// The Mac woke, or the system clock changed: works out the next automatic check again (one
  /// already due runs now; before the state has loaded, nothing: the load's end does it).
  public func woke() {
    rearm()
  }

  /// Automatic checks were turned on or off (`checkForUpdatesAutomatically`). Off cancels the
  /// timer (a check in flight still ends); on arms it by the rules (once the state has loaded).
  public func setAutomaticChecks(_ on: Bool) {
    automaticChecks = on
    rearm()
  }

  /// A manual check: waits for the state's load (so a persisted rate limit holds it as well);
  /// joins the check in flight; during a rate limit answers `rateLimited` without sending;
  /// otherwise sends one request, whether automatic checks are on or off.
  public func checkNow() async -> UpdateCheckOutcome {
    guard lifecycle != .stopped else { return .failed(.cancelled) }
    await loadState()
    if let inFlight {
      joinedChecks += 1
      return await inFlight.value
    }
    guard lifecycle != .stopped else { return .failed(.cancelled) }
    let now = clock.date()
    if let until = UpdateCheck.activeRateLimit(state, now: now) {
      let outcome = UpdateCheckOutcome.rateLimited(until: until)
      lastCheck = UpdateCheckRecord(outcome: outcome, date: now, manual: true)
      publish()
      return outcome
    }
    return await beginCheck(manual: true).value
  } // End of func checkNow()

  /// The popover showed the notice of `version` (PLAN.md D39 *The notice (I-13c1)*): waits for
  /// the state's load and its turn among the saves, then, when `version` is greater than the
  /// recorded one, saves the state with it as `noticeSeenVersion` (the store's rules: atomic,
  /// private) and, only once that save succeeded, records it in the state `status` reads and
  /// publishes the change. Returns whether it was recorded: a version not greater than the
  /// recorded one writes nothing; a save that fails changes and publishes nothing (so the dot
  /// stays) and is counted. Nothing after `stop()`.
  @discardableResult
  public func markNoticeSeen(_ version: UpdateVersion) async -> Bool {
    guard lifecycle != .stopped else { return false }
    await loadState()
    if let seen = state.noticeSeenVersion, version <= seen { return false }
    await beginSaveTurn()
    defer { endSaveTurn() }
    // Worked out again with the turn: an earlier save may have recorded it, or `stop()` come.
    guard lifecycle != .stopped else { return false }
    if let seen = state.noticeSeenVersion, version <= seen { return false }
    var marked = state
    marked.noticeSeenVersion = version
    do {
      try await stateStore.save(marked)
    } catch {
      failedSaves += 1
      return false
    }
    // The check's own changes made meanwhile wait for this turn, so they are saved with it.
    state.noticeSeenVersion = version
    publish()
    return true
  } // End of func markNoticeSeen(_:)

  /// Stops the scheduler: cancels the timer and the check in flight, ends every `updates()`
  /// stream. Nothing runs afterwards.
  public func stop() {
    guard lifecycle != .stopped else { return }
    lifecycle = .stopped
    timer?.task.cancel()
    timer = nil
    inFlight?.cancel()
    for continuation in subscribers.values { continuation.finish() }
    subscribers = [:]
  }

  // MARK: - Scheduling

  /// When the next automatic check is due at `now` (see the type), or `nil`. Always `nil`
  /// until the state has loaded: the persisted throttling (last success, last attempt, rate
  /// limit) is not known before, so nothing is armed or started on the empty state; an event
  /// that arrives meanwhile is worked out by `start`'s `rearm()` once the load ends.
  func automaticDue(now: Date) -> Date? {
    guard lifecycle == .running, automaticChecks, loaded else { return nil }
    var due = now
    if let gate = launchGate {
      // A gate further ahead than the delay means the clock went back since `start`.
      due = max(due, min(gate, now.addingTimeInterval(configuration.launchDelay)))
    }
    if let success = state.lastSuccessfulCheck, success <= now {
      due = max(due, success.addingTimeInterval(configuration.successInterval))
    }
    if let attempt = state.lastAttempt, attempt <= now {
      due = max(due, attempt.addingTimeInterval(configuration.retryInterval))
    }
    if let until = UpdateCheck.activeRateLimit(state, now: now) {
      due = max(due, until)
    }
    return due
  } // End of func automaticDue(now:)

  /// Cancels the timer and arms a new one for the next automatic check, unless a check is in
  /// flight (its end arms it).
  private func rearm() {
    timer?.task.cancel()
    timer = nil
    let now = clock.date()
    settleLaunchGate(now: now)
    guard inFlight == nil, let due = automaticDue(now: now) else { return }
    lastToken += 1
    let token = lastToken
    let clock = self.clock
    let task = Task { [weak self] in
      let wait = due.timeIntervalSince(clock.date())
      if wait > 0 {
        do {
          // Rounded up to the millisecond, so the fire never comes before `due`.
          try await clock.sleep(for: .milliseconds(Int64((wait * 1000).rounded(.up))))
        } catch {
          return
        }
      }
      await self?.timerFired(token)
    }
    timer = Timer(token: token, due: due, task: task)
  } // End of func rearm()

  /// Drops the launch gate once `now` has reached it, and brings it back to at most the launch
  /// delay ahead when the clock went back since `start` (else every timer would find it still
  /// ahead and the first check would never come).
  private func settleLaunchGate(now: Date) {
    guard let gate = launchGate else { return }
    if gate <= now {
      launchGate = nil
    } else if gate.timeIntervalSince(now) > configuration.launchDelay {
      launchGate = now.addingTimeInterval(configuration.launchDelay)
    }
  }

  /// The timer fired: runs the automatic check when it is still due, else arms again.
  private func timerFired(_ token: Int) {
    guard timer?.token == token else { return }
    timer = nil
    let now = clock.date()
    settleLaunchGate(now: now)
    guard inFlight == nil, let due = automaticDue(now: now) else { return }
    guard due <= now else {
      rearm()
      return
    }
    _ = beginCheck(manual: false)
  } // End of func timerFired(_:)

  // MARK: - Checking

  /// Loads the state once; later calls wait for the same load.
  private func loadState() async {
    if loaded { return }
    let store = stateStore
    let task = loading ?? Task { await store.load().state }
    loading = task
    let found = await task.value
    if !loaded {
      state = found
      loaded = true
    }
  } // End of func loadState()

  /// Starts a check and returns its task (the one in flight, if any).
  private func beginCheck(manual: Bool) -> Task<UpdateCheckOutcome, Never> {
    if let inFlight { return inFlight }
    timer?.task.cancel()
    timer = nil
    let task = Task { [self] in await self.runCheck(manual: manual) }
    inFlight = task
    inFlightIsManual = manual
    publish()
    return task
  }

  /// Runs one check: saves the attempt, sends the request, applies the answer, saves the
  /// result, publishes it and arms the next automatic check.
  private func runCheck(manual: Bool) async -> UpdateCheckOutcome {
    state.lastAttempt = clock.date()
    await persist()
    let outcome: UpdateCheckOutcome
    if Task.isCancelled || lifecycle == .stopped {
      // Stopped while the attempt was being saved: nothing is sent.
      outcome = .failed(.cancelled)
    } else {
      requestsSent += 1
      let response = await transport.latestRelease(etag: state.etag)
      if Task.isCancelled || lifecycle == .stopped {
        outcome = .failed(.cancelled)
      } else {
        outcome = UpdateCheck.apply(
          response, to: &state, runningVersion: runningVersion, now: clock.date())
        await persist()
      }
    }
    let now = clock.date()
    lastCheck = UpdateCheckRecord(outcome: outcome, date: now, manual: manual)
    inFlight = nil
    inFlightIsManual = false
    rearm()
    publish()
    return outcome
  } // End of func runCheck(manual:)

  /// Saves the state as it is once its turn comes; a failure is counted and otherwise ignored
  /// (the state stays in memory).
  private func persist() async {
    await beginSaveTurn()
    defer { endSaveTurn() }
    do {
      try await stateStore.save(state)
    } catch {
      failedSaves += 1
    }
  }

  /// Waits until no other save of the state holds the turn, then holds it until
  /// `endSaveTurn()`: saves run one at a time, in the order they asked.
  private func beginSaveTurn() async {
    guard isSaving else {
      isSaving = true
      return
    }
    await withCheckedContinuation { saveWaiters.append($0) }
  }

  /// Hands the turn to the next waiting save (it keeps `isSaving`), or frees it.
  private func endSaveTurn() {
    if saveWaiters.isEmpty {
      isSaving = false
    } else {
      saveWaiters.removeFirst().resume()
    }
  }

  /// Sends the current status to every subscriber.
  private func publish() {
    guard !subscribers.isEmpty else { return }
    let current = status
    for (id, continuation) in subscribers {
      if case .terminated = continuation.yield(current) { subscribers[id] = nil }
    }
  }
}
