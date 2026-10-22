import Foundation

/// The refresh engine (PLAN.md Phase 7, D20): discovers every enabled host on a schedule,
/// keeps one `HostSnapshot` per host and publishes a `RefreshState` after every change.
///
/// - **Off the main actor.** All state lives in this actor; probes and attachment checks run in
///   detached tasks. Phase 8 reads `updates()` on the main actor.
/// - **Slots and single flight.** At most `Configuration.concurrencyLimit` (3) probes run at
///   once, first come, first served; a slow host holds only its own slot. A host has at most one
///   probe running, a retired one (below) included: a host whose retired probe has not ended
///   waits in the queue, without holding up the hosts behind it, and starts when that probe
///   ends. A request made while the host's attempt runs marks one follow-up attempt that starts
///   when it ends (any number of requests during one attempt make one follow-up); a request
///   while the host waits for a slot joins that queued attempt. So every request is answered by
///   an attempt that started after it, and overlapping requests cost at most two.
/// - **Generations and revisions.** Attempts are numbered by a global generation counter, and
///   each records the configuration revision of its host. Cancelling an attempt (sleep, a
///   configuration change, `stop()`) retires it: whatever it returns later is discarded, and it
///   keeps its slot and its host's single flight until its task has ended. A result is applied
///   only from the host's current attempt, under the host's current revision, and only when its
///   generation is newer than the last one applied.
/// - **Cadence.** `start()` refreshes every host at once, then each host every 5 minutes after
///   its last attempt ended; while the popover is visible, every 15 seconds. In the background a
///   host whose last attempt failed waits the backoff step for its consecutive failures (30 s,
///   1 min, 2 min, 5 min, then 15 min) instead; a success resets it. The popover cadence and
///   every explicit request (popover opening, `retry`, wake, network change) ignore backoff.
/// - **Sleep and wake.** `systemWillSleep()` cancels every probe, timer and attachment check
///   and returns once they have ended (the process runner kills each probe's process group
///   before its run returns); nothing scheduled runs until `systemDidWake()`, which refreshes
///   every host 5 seconds later. Sleep and `stop()` also end a `refreshOnce` round in progress:
///   it submits nothing more. `networkPathChanged()` refreshes the hosts whose last attempt
///   failed.
/// - **Attachments.** With an index configured, an attachment check (PLAN.md D16) runs after
///   each applied result while the popover is visible (one at a time, at most one follow-up),
///   or once at the end of `refreshOnce(includeAttachments: true)`; never in the background, so
///   iTerm2 is not contacted while the popover is closed.
/// - **`stop()`** cancels everything and returns once every task it started has ended.
public actor RefreshCoordinator {
  /// Timing and concurrency (PLAN.md D20).
  public struct Configuration: Sendable, Hashable {
    /// At most this many probes run at once.
    public static let defaultConcurrencyLimit = 3
    /// The cadence while the popover is visible.
    public static let defaultVisibleInterval: Duration = .seconds(15)
    /// The background cadence of a host whose last attempt succeeded.
    public static let defaultBackgroundInterval: Duration = .seconds(300)
    /// The background backoff after 1, 2, 3, 4 and 5 or more consecutive failures.
    public static let defaultBackoffSteps: [Duration] = [
      .seconds(30), .seconds(60), .seconds(120), .seconds(300), .seconds(900),
    ]
    /// How long after waking every host is refreshed.
    public static let defaultWakeDelay: Duration = .seconds(5)

    /// At most this many probes run at once (at least 1).
    public var concurrencyLimit: Int
    /// The cadence while the popover is visible.
    public var visibleInterval: Duration
    /// The background cadence of a host whose last attempt succeeded.
    public var backgroundInterval: Duration
    /// The background delay after n consecutive failures is `backoffSteps[n - 1]`, the last
    /// step for every n past the end.
    public var backoffSteps: [Duration]
    /// How long after waking every host is refreshed.
    public var wakeDelay: Duration

    /// Creates a configuration; the defaults are PLAN.md's.
    public init(
      concurrencyLimit: Int = Configuration.defaultConcurrencyLimit,
      visibleInterval: Duration = Configuration.defaultVisibleInterval,
      backgroundInterval: Duration = Configuration.defaultBackgroundInterval,
      backoffSteps: [Duration] = Configuration.defaultBackoffSteps,
      wakeDelay: Duration = Configuration.defaultWakeDelay
    ) {
      self.concurrencyLimit = max(1, concurrencyLimit)
      self.visibleInterval = visibleInterval
      self.backgroundInterval = backgroundInterval
      self.backoffSteps = backoffSteps
      self.wakeDelay = wakeDelay
    } // End of init(concurrencyLimit:visibleInterval:backgroundInterval:backoffSteps:wakeDelay:)

    /// The background delay after the last attempt of a host with `failures` consecutive
    /// failures: the background cadence when there are none, else the backoff step.
    public func backgroundDelay(afterFailures failures: Int) -> Duration {
      guard failures > 0, let last = backoffSteps.last else { return backgroundInterval }
      return failures <= backoffSteps.count ? backoffSteps[failures - 1] : last
    }
  } // End of struct Configuration

  /// Whether the engine schedules work.
  enum Lifecycle: Sendable {
    /// Created: explicit requests run, nothing is scheduled (the probe's `refresh --once`).
    case idle
    /// Started: hosts are refreshed on their cadence.
    case running
    /// Stopped for good: nothing runs.
    case stopped
  }

  /// How a probe task ended.
  private enum AttemptOutcome: Sendable {
    /// Discovery returned a result.
    case finished(DiscoveryResult)
    /// Discovery was cancelled.
    case cancelled
  }

  /// How an attachment check ended.
  private enum IndexOutcome: Sendable {
    /// The index answered.
    case snapshot(AttachmentSnapshot)
    /// iTerm2 is not running: nothing is attached in it.
    case notRunning
    /// The connection listing failed.
    case failed(ITerm2Error?)
    /// The check was cancelled.
    case cancelled
  }

  /// A scheduled wake-up: a task sleeping until `due`, recognized by `token` when it fires.
  private struct ScheduledTask {
    /// Identifies this timer among replaced ones.
    let token: Int
    /// When it fires, on the coordinator's clock.
    let due: ContinuousClock.Instant
    /// The sleeping task.
    let task: Task<Void, Never>
  }

  /// One host's bookkeeping.
  private struct HostEntry {
    /// The published part.
    var snapshot: HostSnapshot
    /// When the last applied attempt ended, on the coordinator's clock.
    var lastAttemptEndedAt: ContinuousClock.Instant?
    /// The generation of the host's current attempt (running, not retired).
    var flight: Int?
    /// Whether the host waits in `queue` for a slot.
    var isQueued = false
    /// Whether a request arrived while `flight` runs.
    var followUp = false
    /// The generation of the last applied result.
    var appliedGeneration = 0
    /// Callers waiting for the host's next attempt to end.
    var waiters: [CheckedContinuation<Void, Never>] = []
    /// The next scheduled attempt.
    var timer: ScheduledTask?
  }

  /// One probe task.
  private struct Attempt {
    /// The host it probes; while the task runs, retired or not, no other attempt of this host
    /// starts.
    let hostID: UUID
    /// The host's configuration revision when it started.
    let revision: Int
    /// The probing task.
    let task: Task<Void, Never>
    /// Set when it was cancelled; its result is then discarded.
    var retired = false
    /// Callers waiting for it to end.
    var waiters: [CheckedContinuation<Void, Never>]
  }

  /// One attachment check.
  private struct IndexPass {
    /// Its number.
    let id: Int
    /// The checking task.
    let task: Task<Void, Never>
    /// Callers waiting for it to end.
    var waiters: [CheckedContinuation<Void, Never>]
  }

  /// Timing and concurrency.
  public nonisolated let configuration: Configuration
  /// Discovers one host (`DiscoveryProbe` in production).
  private let discovery: any HostDiscovering
  /// Which sessions are attached in iTerm2; `nil` never checks.
  private let attachmentIndex: (any AttachmentIndexing)?
  /// The time source of every schedule and timestamp.
  private let clock: any AttachClock

  /// Whether the engine schedules work.
  private(set) var lifecycle = Lifecycle.idle
  /// The enabled hosts, in host-list order.
  private var hostOrder: [UUID]
  /// The enabled hosts' bookkeeping.
  private var hosts: [UUID: HostEntry]
  /// Increases with every host added, removed or changed in a way that changes discovery.
  private var configRevision: Int
  /// Whether the popover is open.
  private var isPopoverVisible = false
  /// Whether the system sleeps.
  private var isAsleep = false
  /// Increases whenever sleep or `stop()` cancels all work. A `refreshOnce` round records it
  /// when it begins and, once it has changed, submits nothing more.
  private var workEpoch = 0
  /// Hosts waiting for a slot or for their previous probe to end, first come first served.
  private var queue: [UUID] = []
  /// Every probe task that has not ended, retired ones included, by generation. Its size is
  /// what the concurrency limit counts.
  private var attempts: [Int: Attempt] = [:]
  /// The last generation handed out.
  private var lastGeneration = 0
  /// The last timer token handed out.
  private var lastToken = 0
  /// The refresh scheduled after waking.
  private var wakeTimer: ScheduledTask?
  /// The running attachment check.
  private var indexPass: IndexPass?
  /// The last attachment check number handed out.
  private var lastIndexPassID = 0
  /// Whether an attachment check was asked for while one runs.
  private var indexFollowUp = false
  /// Callers waiting for the next attachment check to end.
  private var indexWaiters: [CheckedContinuation<Void, Never>] = []
  /// The last successful attachment snapshot; `nil` when there is none or the last check
  /// did not succeed.
  private var lastIndexSnapshot: AttachmentSnapshot?
  /// The last attachment check.
  private var attachmentCheck = AttachmentCheck.notChecked
  /// Every task this coordinator started that has not ended, by number.
  private var tasks: [Int: Task<Void, Never>] = [:]
  /// The last task number handed out.
  private var lastTaskID = 0
  /// Subscribers of `updates()`.
  private var subscribers: [Int: AsyncStream<RefreshState>.Continuation] = [:]
  /// The last subscriber number handed out.
  private var lastSubscriberID = 0
  /// The state last sent to subscribers.
  private var lastPublished: RefreshState?

  /// Attempts started per host (diagnostics and tests).
  private(set) var attemptsStarted: [UUID: Int] = [:]
  /// Finished results that were discarded: retired, from an old revision or generation.
  private(set) var discardedResults = 0
  /// Attachment checks started.
  private(set) var indexPassesStarted = 0

  /// Creates an engine for the enabled hosts of `hosts`. Nothing runs until `start()`, a
  /// request or `refreshOnce(includeAttachments:)`. Tests pass a fake discovery, index and clock.
  public init(
    hosts list: HostList,
    discovery: any HostDiscovering = DiscoveryProbe(),
    attachmentIndex: (any AttachmentIndexing)? = nil,
    clock: any AttachClock = SystemAttachClock(),
    configuration: Configuration = Configuration()
  ) {
    self.discovery = discovery
    self.attachmentIndex = attachmentIndex
    self.clock = clock
    self.configuration = configuration
    let enabled = list.enabledHosts
    var entries: [UUID: HostEntry] = [:]
    for host in enabled {
      entries[host.id] = HostEntry(snapshot: HostSnapshot(host: host, configRevision: 1))
    }
    hosts = entries
    hostOrder = enabled.map(\.id)
    configRevision = 1
  } // End of init(hosts:discovery:attachmentIndex:clock:configuration:)

  /// Cancels whatever is still running if the engine goes away without `stop()`.
  deinit {
    for task in tasks.values { task.cancel() }
    for continuation in subscribers.values { continuation.finish() }
  }

  // MARK: - Reading

  /// The current state.
  public var state: RefreshState { currentState() }

  /// A stream of states: the current one at once, then one after every change, until `stop()`.
  /// By default a slow reader only gets the newest state.
  public func updates(
    bufferingPolicy: AsyncStream<RefreshState>.Continuation.BufferingPolicy = .bufferingNewest(1)
  ) -> AsyncStream<RefreshState> {
    let (stream, continuation) = AsyncStream.makeStream(
      of: RefreshState.self, bufferingPolicy: bufferingPolicy)
    continuation.yield(currentState())
    if lifecycle == .stopped {
      continuation.finish()
    } else {
      lastSubscriberID += 1
      subscribers[lastSubscriberID] = continuation
    }
    return stream
  } // End of func updates(bufferingPolicy:)

  // MARK: - Entry points

  /// Starts the cadence: every host is refreshed now, then on its schedule.
  public func start() {
    guard lifecycle == .idle else { return }
    lifecycle = .running
    for id in hostOrder { request(id) }
    publish()
  }

  /// The popover opened: every host is refreshed now, then every 15 seconds, and attachment
  /// checks run after the results.
  public func popoverDidOpen() {
    guard lifecycle != .stopped else { return }
    isPopoverVisible = true
    for id in hostOrder { request(id) }
    publish()
  }

  /// The popover closed: back to the background cadence and backoff.
  public func popoverDidClose() {
    guard lifecycle != .stopped, isPopoverVisible else { return }
    isPopoverVisible = false
    for id in hostOrder { reschedule(id) }
    publish()
  }

  /// Refreshes the host `hostID` now, whatever its backoff ("Retry").
  public func retry(_ hostID: UUID) {
    request(hostID)
    publish()
  }

  /// Refreshes every host now, whatever its backoff ("Refresh").
  public func retryAll() {
    for id in hostOrder { request(id) }
    publish()
  }

  /// Refreshes every host once, waits until each of those attempts has ended (applied or
  /// discarded), then, with `includeAttachments` and an index, runs one attachment check and
  /// waits for it. Returns the state then. Used by `muxfinder-probe refresh --once`.
  ///
  /// Sleep or `stop()` during the round ends it: their cancellation resumes it, and from then
  /// on it submits nothing (no host request not made yet, no attachment check) and returns the
  /// state at once. A round begun while asleep runs, like any explicit request.
  public func refreshOnce(includeAttachments: Bool = false) async -> RefreshState {
    let epoch = workEpoch
    let ids = hostOrder
    await withTaskGroup(of: Void.self) { group in
      for id in ids {
        group.addTask { await self.refreshAndWait(id, epoch: epoch) }
      }
    }
    if includeAttachments {
      await withCheckedContinuation { continuation in
        guard epoch == workEpoch else {
          continuation.resume()
          return
        }
        requestIndexPass(waiter: continuation)
      }
    }
    return currentState()
  } // End of func refreshOnce(includeAttachments:)

  /// Replaces the host list. A host removed or disabled is dropped with its in-flight attempt
  /// retired. A host whose mode, destination or tmux override changed starts over under a new
  /// revision (its in-flight attempt retired, its snapshot reset) and, once started, is
  /// refreshed at once, or as soon as its retired probe has ended; so is a new host. A change
  /// of the name or profile alone keeps the snapshot and any attempt in flight, since discovery
  /// is the same.
  public func setHosts(_ list: HostList) {
    guard lifecycle != .stopped else { return }
    let enabled = list.enabledHosts
    let enabledIDs = Set(enabled.map(\.id))
    var released: [CheckedContinuation<Void, Never>] = []
    for id in hostOrder where !enabledIDs.contains(id) {
      guard let entry = hosts.removeValue(forKey: id) else { continue }
      configRevision += 1
      released += retire(entry)
      released += entry.waiters
    } // End of loop over removed hosts
    hostOrder = enabled.map(\.id)
    for host in enabled {
      if let entry = hosts[host.id], !Self.discoveryChanged(from: entry.snapshot.host, to: host) {
        hosts[host.id]?.snapshot.host = host
        continue
      }
      configRevision += 1
      var fresh = HostEntry(snapshot: HostSnapshot(host: host, configRevision: configRevision))
      if let entry = hosts[host.id] {
        released += retire(entry)
        fresh.waiters = entry.waiters
      }
      hosts[host.id] = fresh
      if lifecycle == .running || !fresh.waiters.isEmpty { request(host.id) }
    } // End of loop over enabled hosts
    publish()
    for waiter in released { waiter.resume() }
  } // End of func setHosts(_:)

  /// The system is about to sleep: cancels every probe, timer and attachment check, and returns
  /// once all of them have ended, each probe's process group killed by the process runner.
  /// Nothing scheduled runs until `systemDidWake()`.
  public func systemWillSleep() async {
    guard lifecycle != .stopped, !isAsleep else { return }
    isAsleep = true
    let released = cancelAllWork()
    publish()
    for waiter in released { waiter.resume() }
    let running = Array(tasks.values)
    for task in running { await task.value }
  } // End of func systemWillSleep()

  /// The system woke: once started, every host is refreshed after `Configuration.wakeDelay`.
  public func systemDidWake() {
    guard lifecycle != .stopped, isAsleep else { return }
    isAsleep = false
    if lifecycle == .running {
      wakeTimer = arm(due: clock.now() + configuration.wakeDelay) { coordinator, token in
        await coordinator?.wakeTimerFired(token)
      }
    }
    publish()
  } // End of func systemDidWake()

  /// The network path changed: refreshes every host whose last attempt failed. Ignored while
  /// asleep and while the refresh after waking is pending (it covers every host).
  public func networkPathChanged() {
    guard lifecycle != .stopped, !isAsleep, wakeTimer == nil else { return }
    for id in hostOrder where (hosts[id]?.snapshot.consecutiveFailures ?? 0) > 0 {
      request(id)
    }
    publish()
  }

  /// Cancels everything and returns once every task this engine started has ended (each
  /// probe's process group killed). The update streams finish; later calls do nothing.
  public func stop() async {
    if lifecycle != .stopped {
      lifecycle = .stopped
      let released = cancelAllWork()
      let final = currentState()
      for continuation in subscribers.values {
        continuation.yield(final)
        continuation.finish()
      }
      subscribers = [:]
      for waiter in released { waiter.resume() }
    }
    while let (id, task) = tasks.first {
      await task.value
      tasks[id] = nil
    }
  } // End of func stop()

  // MARK: - Requests and attempts

  /// Asks for an attempt of host `id` (see the type's *Slots and single flight*); `waiter` is
  /// resumed when the attempt that serves the request ends, or at once when none will.
  private func request(_ id: UUID, waiter: CheckedContinuation<Void, Never>? = nil) {
    guard lifecycle != .stopped, var entry = hosts[id] else {
      waiter?.resume()
      return
    }
    if let waiter { entry.waiters.append(waiter) }
    entry.timer?.task.cancel()
    entry.timer = nil
    if entry.flight != nil {
      entry.followUp = true
    } else if !entry.isQueued {
      entry.isQueued = true
      queue.append(id)
    }
    hosts[id] = entry
    startQueuedAttempts()
  } // End of func request(_:waiter:)

  /// `request(_:waiter:)` for one host of the `refreshOnce` round begun in `epoch`, waiting
  /// until the attempt that serves it has ended. Requests nothing once sleep or `stop()` has
  /// ended the round (the epoch changed).
  private func refreshAndWait(_ id: UUID, epoch: Int) async {
    await withCheckedContinuation { continuation in
      guard epoch == workEpoch else {
        continuation.resume()
        return
      }
      request(id, waiter: continuation)
      publish()
    }
  } // End of func refreshAndWait(_:epoch:)

  /// Whether a probe of host `id`, retired or not, has not ended yet.
  private func hasUnfinishedProbe(_ id: UUID) -> Bool {
    attempts.values.contains { $0.hostID == id }
  }

  /// Starts queued hosts, first come first served, while slots are free. A host whose previous
  /// probe (retired, so not its `flight`) has not ended stays queued without holding up the
  /// hosts behind it; `attemptEnded(_:_:)` calls this again when that probe ends.
  private func startQueuedAttempts() {
    guard lifecycle != .stopped else { return }
    var position = 0
    while attempts.count < configuration.concurrencyLimit, position < queue.count {
      let id = queue[position]
      guard var entry = hosts[id], entry.isQueued, entry.flight == nil else {
        queue.remove(at: position)
        continue
      }
      guard !hasUnfinishedProbe(id) else {
        position += 1
        continue
      }
      queue.remove(at: position)
      lastGeneration += 1
      let generation = lastGeneration
      let host = entry.snapshot.host
      let discovery = self.discovery
      let task = spawn { coordinator in
        let outcome = await Self.probe(host, with: discovery)
        await coordinator?.attemptEnded(generation, outcome)
      }
      attempts[generation] = Attempt(
        hostID: id, revision: entry.snapshot.configRevision, task: task, waiters: entry.waiters)
      entry.waiters = []
      entry.isQueued = false
      entry.flight = generation
      hosts[id] = entry
      attemptsStarted[id, default: 0] += 1
    } // End of loop over the queue while slots are free
  } // End of func startQueuedAttempts()

  /// Runs discovery for `host`. `discover` throws only when cancelled.
  private nonisolated static func probe(
    _ host: HostConfig,
    with discovery: any HostDiscovering
  ) async -> AttemptOutcome {
    do {
      return .finished(try await discovery.discover(host))
    } catch {
      return .cancelled
    }
  }

  /// Handles the end of attempt `generation`: applies its result if it is still the host's
  /// current attempt under the same revision and newer than the last applied one, starts the
  /// follow-up or schedules the next attempt, frees the slot and the host's single flight (so a
  /// host queued behind its retired probe starts now) and resumes its waiters.
  private func attemptEnded(_ generation: Int, _ outcome: AttemptOutcome) {
    guard let attempt = attempts.removeValue(forKey: generation) else { return }
    var applied = false
    if !attempt.retired, var entry = hosts[attempt.hostID], entry.flight == generation {
      entry.flight = nil
      if case .finished(let result) = outcome, entry.snapshot.configRevision == attempt.revision,
        generation > entry.appliedGeneration
      {
        entry.appliedGeneration = generation
        entry.lastAttemptEndedAt = clock.now()
        entry.snapshot.record(result, at: clock.date(), index: lastIndexSnapshot)
        applied = true
      }
      if entry.followUp {
        entry.followUp = false
        entry.isQueued = true
        queue.append(attempt.hostID)
      }
      hosts[attempt.hostID] = entry
      reschedule(attempt.hostID)
    } // End of handling for the host's current attempt
    if !applied, case .finished = outcome { discardedResults += 1 }
    startQueuedAttempts()
    if applied, wantsAutomaticIndexPass { requestIndexPass(waiter: nil) }
    publish()
    for waiter in attempt.waiters { waiter.resume() }
  } // End of func attemptEnded(_:_:)

  /// Retires `entry`'s attempt and timer and takes it out of the queue; returns the attempt's
  /// waiters (the entry's own are left to the caller).
  private func retire(_ entry: HostEntry) -> [CheckedContinuation<Void, Never>] {
    entry.timer?.task.cancel()
    let id = entry.snapshot.host.id
    queue.removeAll { $0 == id }
    guard let generation = entry.flight else { return [] }
    return retireAttempt(generation)
  }

  /// Cancels attempt `generation` and marks it retired; returns its waiters.
  private func retireAttempt(_ generation: Int) -> [CheckedContinuation<Void, Never>] {
    guard var attempt = attempts[generation] else { return [] }
    attempt.retired = true
    attempt.task.cancel()
    let waiters = attempt.waiters
    attempt.waiters = []
    attempts[generation] = attempt
    return waiters
  }

  /// Cancels every timer, attempt and attachment check, clears every queue and ends every
  /// `refreshOnce` round in progress (a new work epoch); returns the waiters to resume.
  private func cancelAllWork() -> [CheckedContinuation<Void, Never>] {
    var released: [CheckedContinuation<Void, Never>] = []
    workEpoch += 1
    wakeTimer?.task.cancel()
    wakeTimer = nil
    for id in hostOrder {
      guard var entry = hosts[id] else { continue }
      released += retire(entry)
      released += entry.waiters
      entry.timer = nil
      entry.flight = nil
      entry.isQueued = false
      entry.followUp = false
      entry.waiters = []
      hosts[id] = entry
    } // End of loop over hosts
    queue.removeAll()
    if let pass = indexPass {
      pass.task.cancel()
      released += pass.waiters
      indexPass = nil
    }
    indexFollowUp = false
    released += indexWaiters
    indexWaiters = []
    return released
  } // End of func cancelAllWork()

  /// Whether `new` discovers differently from `old`: another mode, destination or override.
  static func discoveryChanged(from old: HostConfig, to new: HostConfig) -> Bool {
    old.mode != new.mode || old.sshDestination != new.sshDestination
      || old.tmuxPathOverride != new.tmuxPathOverride
  }

  // MARK: - Scheduling

  /// Arms, moves or cancels host `id`'s timer: once started and awake with no attempt pending,
  /// the next attempt is due one cadence step after the last one ended (now if none ended).
  private func reschedule(_ id: UUID) {
    guard var entry = hosts[id] else { return }
    var due: ContinuousClock.Instant?
    if lifecycle == .running, !isAsleep, wakeTimer == nil, entry.flight == nil, !entry.isQueued {
      let delay =
        isPopoverVisible
        ? configuration.visibleInterval
        : configuration.backgroundDelay(afterFailures: entry.snapshot.consecutiveFailures)
      due = entry.lastAttemptEndedAt.map { $0 + delay } ?? clock.now()
    }
    guard entry.timer?.due != due else { return }
    entry.timer?.task.cancel()
    entry.timer = due.map { due in
      arm(due: due) { coordinator, token in await coordinator?.hostTimerFired(id, token: token) }
    }
    hosts[id] = entry
  } // End of func reschedule(_:)

  /// Starts a task that sleeps until `due` on the clock and then calls `fire` with its token.
  private func arm(
    due: ContinuousClock.Instant,
    fire: @escaping @Sendable (RefreshCoordinator?, Int) async -> Void
  ) -> ScheduledTask {
    lastToken += 1
    let token = lastToken
    let clock = self.clock
    let task = spawn { coordinator in
      let wait = clock.now().duration(to: due)
      if wait > .zero {
        do {
          try await clock.sleep(for: wait)
        } catch {
          return
        }
      }
      await fire(coordinator, token)
    }
    return ScheduledTask(token: token, due: due, task: task)
  } // End of func arm(due:fire:)

  /// Host `id`'s timer fired: refreshes it unless the timer was replaced meanwhile.
  private func hostTimerFired(_ id: UUID, token: Int) {
    guard hosts[id]?.timer?.token == token else { return }
    hosts[id]?.timer = nil
    request(id)
    publish()
  }

  /// The wake timer fired: refreshes every host unless it was replaced meanwhile.
  private func wakeTimerFired(_ token: Int) {
    guard wakeTimer?.token == token else { return }
    wakeTimer = nil
    for id in hostOrder { request(id) }
    publish()
  }

  /// Starts `operation` in a detached task, passing it this engine (weakly held), and keeps
  /// the task until it ends so `stop()` can wait for it.
  private func spawn(
    _ operation: @escaping @Sendable (RefreshCoordinator?) async -> Void
  ) -> Task<Void, Never> {
    lastTaskID += 1
    let id = lastTaskID
    let task = Task.detached { [weak self] in
      await operation(self)
      await self?.taskEnded(id)
    }
    tasks[id] = task
    return task
  } // End of func spawn(_:)

  /// Forgets task `id`, which has ended.
  private func taskEnded(_ id: Int) {
    tasks[id] = nil
  }

  // MARK: - Attachments

  /// Whether results trigger attachment checks: an index exists, the popover is visible and
  /// the system is awake.
  private var wantsAutomaticIndexPass: Bool {
    attachmentIndex != nil && isPopoverVisible && !isAsleep && lifecycle != .stopped
  }

  /// Asks for an attachment check: started now, or marked as a follow-up of the running one.
  /// `waiter` is resumed when the check that serves it ends, or at once when none will.
  private func requestIndexPass(waiter: CheckedContinuation<Void, Never>?) {
    guard lifecycle != .stopped, let index = attachmentIndex else {
      waiter?.resume()
      return
    }
    if let waiter { indexWaiters.append(waiter) }
    if indexPass != nil {
      indexFollowUp = true
    } else {
      startIndexPass(index)
    }
  } // End of func requestIndexPass(waiter:)

  /// Starts an attachment check over the hosts' last successful discoveries.
  private func startIndexPass(_ index: any AttachmentIndexing) {
    lastIndexPassID += 1
    let id = lastIndexPassID
    let indexHosts = hostOrder.compactMap { hosts[$0]?.snapshot.indexHost }
    let task = spawn { coordinator in
      let outcome = await Self.check(index, hosts: indexHosts)
      await coordinator?.indexPassEnded(id, outcome)
    }
    indexPass = IndexPass(id: id, task: task, waiters: indexWaiters)
    indexWaiters = []
    indexPassesStarted += 1
  } // End of func startIndexPass(_:)

  /// Runs the index and classifies its outcome (PLAN.md D16 *When the index fails*).
  private nonisolated static func check(
    _ index: any AttachmentIndexing,
    hosts: [AttachmentIndex.Host]
  ) async -> IndexOutcome {
    do {
      return .snapshot(try await index.snapshot(of: hosts))
    } catch ITerm2Error.notRunning {
      return .notRunning
    } catch let error as ITerm2Error {
      return .failed(error)
    } catch is CancellationError {
      return .cancelled
    } catch {
      return .failed(nil)
    }
  } // End of func check(_:hosts:)

  /// Handles the end of attachment check `id`: records the outcome, merges it into every
  /// snapshot, resumes its waiters and starts the follow-up if one is still wanted.
  private func indexPassEnded(_ id: Int, _ outcome: IndexOutcome) {
    guard let pass = indexPass, pass.id == id else { return }
    indexPass = nil
    let date = clock.date()
    switch outcome {
    case .snapshot(let snapshot):
      attachmentCheck = .checked(at: date, counts: snapshot.counts)
      lastIndexSnapshot = snapshot
    case .notRunning:
      attachmentCheck = .iTermNotRunning(at: date)
      lastIndexSnapshot = nil
    case .failed(let error):
      attachmentCheck = .failed(at: date, error: error)
      lastIndexSnapshot = nil
    case .cancelled:
      break
    }
    for hostID in hostOrder {
      hosts[hostID]?.snapshot.mergeAttachments(lastIndexSnapshot)
    }
    if indexFollowUp {
      indexFollowUp = false
      if let index = attachmentIndex, wantsAutomaticIndexPass || !indexWaiters.isEmpty {
        startIndexPass(index)
      }
    }
    publish()
    for waiter in pass.waiters { waiter.resume() }
  } // End of func indexPassEnded(_:_:)

  // MARK: - Publishing

  /// The state as published.
  private func currentState() -> RefreshState {
    RefreshState(
      hosts: hostOrder.compactMap { id in
        guard let entry = hosts[id] else { return nil }
        var snapshot = entry.snapshot
        snapshot.isRefreshing = entry.flight != nil || entry.isQueued
        snapshot.nextRefreshAt = entry.timer?.due
        return snapshot
      },
      attachmentCheck: attachmentCheck,
      configRevision: configRevision,
      isPopoverVisible: isPopoverVisible,
      isAsleep: isAsleep
    )
  } // End of func currentState()

  /// Sends the state to every subscriber if it changed since the last time.
  private func publish() {
    guard !subscribers.isEmpty else { return }
    let state = currentState()
    guard state != lastPublished else { return }
    lastPublished = state
    for (id, continuation) in subscribers {
      if case .terminated = continuation.yield(state) { subscribers[id] = nil }
    }
  } // End of func publish()

  // MARK: - Diagnostics

  /// Tasks started and not yet ended (probes, timers, attachment checks).
  var liveTaskCount: Int { tasks.count }

  /// Probe tasks that have not ended, retired ones included.
  var runningAttemptCount: Int { attempts.count }

  /// Hosts waiting for a slot.
  var queuedHostCount: Int { queue.count }

  /// Hosts with a scheduled attempt.
  var armedTimerCount: Int { hosts.values.filter { $0.timer != nil }.count }

  /// Whether the refresh after waking is pending.
  var isWakeRefreshPending: Bool { wakeTimer != nil }
}
