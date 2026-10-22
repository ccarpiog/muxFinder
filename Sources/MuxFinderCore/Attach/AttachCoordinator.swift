import Foundation

/// Attaches tmux sessions in iTerm2 through a launch tab and confirms the attachment (PLAN.md
/// Architecture, Phase 4; local hosts only until Phase 5).
///
/// One attach runs these steps:
/// 1. Revalidate the session through discovery (same key, same `session_created`).
/// 2. Write the launch request file (D2, D14).
/// 3. `ensureRunning()`: the only call that may launch iTerm2.
/// 4. `CreateTab` in a new window, using the host's iTerm2 profile when one is set, whose
///    command is `<helper> attach <launch id>` and whose session closes when the helper exits.
/// 5. The state becomes `launched(sessionID)`.
/// 6. Poll `ListConnections` until a connection's `owning_session_id` is the launch tab's
///    session, or the helper's result file reports how it ended, within the confirmation budget
///    (15 s).
/// 7. Check identity through that connection (`ConnectionIdentity.command`) against the
///    revalidated key.
/// 8. The state becomes `confirmed(connectionID)`.
/// 9. `Activate` the first tab carrying that `tmux_connection_id`.
///
/// Concurrent attaches for the same `SessionKey` coalesce into one launch and share its
/// result. No request is retried automatically (D13): a failed `CreateTab`, identity check or
/// activation ends that step. Every failure before a connection was found withdraws the request
/// file, so a launch tab that starts late cannot attach; once the tab exists its session id is
/// in the result, so the caller can find it. Detaching sends `detach-client` on the connection
/// and never closes tmux tabs.
///
/// Ending a connection ends its launch tab, and iTerm2 blocks its whole API behind a modal
/// warning when a session ends within 3 s of starting (PLAN.md *Verified facts*, Phase 4).
/// So the coordinator never sends `detach-client` (after a failed identity check, or for
/// `detach`) before the launch tab is `Configuration.minimumLaunchTabAge` old, and every
/// command for a connection goes through `ITerm2Integration.sendTmuxCommand(_:connectionID:ownedBy:)`,
/// bound to the launch tab that owns it, because connection ids are short names iTerm2 reuses.
///
/// Diagnostics record step outcomes, kinds and durations only: no paths, names or terminal
/// content.
public actor AttachCoordinator {
  /// Budgets and options. The defaults are PLAN.md's local values.
  public struct Configuration: Sendable {
    /// How long after `launched` a connection (or a helper result) may take to appear.
    public var confirmationBudget: Duration
    /// The pause between two polls.
    public var pollInterval: Duration
    /// How long after `confirmed` the connection's first tab may take to appear.
    public var tabBudget: Duration
    /// How long a detached connection may take to disappear.
    public var detachBudget: Duration
    /// How long after the connection closed the helper's result may take to appear.
    public var resultBudget: Duration
    /// How old a launch tab must be before the coordinator ends its connection. iTerm2 3.7.6
    /// shows its blocking short-lived-session warning for a session that ends within 3 s of
    /// starting (its `shortLivedSessionDuration` default; seen after an end at about 1.5 s);
    /// 10 s keeps a wide margin, and is what `e2e-local` uses for the ends it causes itself and
    /// the helper's own minimum lifetime (PLAN.md D14, D15).
    public var minimumLaunchTabAge: Duration
    /// Whether activation also activates iTerm2 itself (the app is in the background when the
    /// user clicks the menu bar).
    public var activatesApp: Bool

    /// Creates a configuration.
    public init(
      confirmationBudget: Duration = .seconds(15),
      pollInterval: Duration = .milliseconds(200),
      tabBudget: Duration = .seconds(5),
      detachBudget: Duration = .seconds(10),
      resultBudget: Duration = .seconds(5),
      minimumLaunchTabAge: Duration = .seconds(10),
      activatesApp: Bool = true
    ) {
      self.confirmationBudget = confirmationBudget
      self.pollInterval = pollInterval
      self.tabBudget = tabBudget
      self.detachBudget = detachBudget
      self.resultBudget = resultBudget
      self.minimumLaunchTabAge = minimumLaunchTabAge
      self.activatesApp = activatesApp
    } // End of init(confirmationBudget:pollInterval:tabBudget:detachBudget:resultBudget:…)
  }

  /// Receives every state change of every launch, in order, on the coordinator's executor.
  /// Keep it short. An update whose `isCurrent` is `false` comes from a launch a newer one for
  /// the same session replaced; observers of the session's state ignore it.
  public typealias UpdateHandler = @Sendable (AttachUpdate) -> Void

  /// How many launch tabs the coordinator remembers the opening time of. A tab it forgot is
  /// treated like one it did not open, which only makes a detach wait longer.
  static let rememberedLaunches = 64

  /// One launch in progress and the callers waiting for it.
  private struct Flight {
    /// Tells this launch apart from earlier and later ones for the same key.
    let id: UInt64
    /// The launch.
    let task: Task<AttachResult, Never>
    /// How many callers wait for it.
    var waiters: Int
    /// How many of them were cancelled; when all were, the launch is cancelled.
    var cancelledWaiters: Int
  }

  /// The iTerm2 backend.
  private let iTerm2: any ITerm2Integration
  /// Revalidation.
  private let discovery: any HostDiscovering
  /// Request and result files.
  private let store: any LaunchRequestStore
  /// Budgets, polling and timestamps.
  private let clock: any AttachClock
  /// The helper iTerm2 runs in the launch tab.
  private let helperPath: LaunchHelperPath
  /// Budgets and options.
  private let configuration: Configuration
  /// Where outcomes are recorded, if anywhere.
  private let diagnostics: DiagnosticsLog?
  /// The state observer.
  private let onUpdate: UpdateHandler?
  /// Launches in progress, by session.
  private var flights: [SessionKey: Flight] = [:]
  /// The id of the most recent launch.
  private var lastFlightID: UInt64 = 0
  /// The id of each session's latest launch; only that launch changes `states`.
  private var latestFlightIDs: [SessionKey: UInt64] = [:]
  /// The latest state of every session attached so far.
  private var states: [SessionKey: AttachState] = [:]
  /// When each launch tab this coordinator opened was reported, by its session id.
  private var launchedAt: [String: ContinuousClock.Instant] = [:]

  /// Creates a coordinator from its parts. Tests pass fakes for every seam.
  public init(
    iTerm2: any ITerm2Integration,
    discovery: any HostDiscovering,
    store: any LaunchRequestStore,
    helperPath: LaunchHelperPath,
    clock: any AttachClock = SystemAttachClock(),
    configuration: Configuration = Configuration(),
    diagnostics: DiagnosticsLog? = nil,
    onUpdate: UpdateHandler? = nil
  ) {
    self.iTerm2 = iTerm2
    self.discovery = discovery
    self.store = store
    self.helperPath = helperPath
    self.clock = clock
    self.configuration = configuration
    self.diagnostics = diagnostics
    self.onUpdate = onUpdate
  } // End of init(iTerm2:discovery:store:helperPath:clock:configuration:diagnostics:onUpdate:)

  /// The latest state of `key`'s most recent attach, or `nil` if it was never attached.
  public func state(of key: SessionKey) -> AttachState? {
    states[key]
  }

  /// How many callers wait for the launch in progress for `key` (0 when none runs). For tests.
  func waiterCount(for key: SessionKey) -> Int {
    flights[key]?.waiters ?? 0
  }

  /// How many callers of the launch in progress for `key` were cancelled. For tests.
  func cancelledWaiterCount(for key: SessionKey) -> Int {
    flights[key]?.cancelledWaiters ?? 0
  }

  // MARK: - Attach

  /// Attaches `target`'s session and returns how it ended (`confirmed` or `failed`). A call
  /// for a session whose launch is in progress joins it instead of starting another. When
  /// every caller waiting for a launch is cancelled, the launch stops at its next step and
  /// fails with `cancelled` (a `CreateTab` already sent still completes, so its session id is
  /// reported); a call arriving after that starts a new launch, and from then on only the new
  /// launch changes `state(of:)`.
  public func attach(_ target: AttachTarget) async -> AttachResult {
    let key = target.key
    let flight: Flight
    // A launch whose callers were all cancelled is winding down; a new caller starts afresh.
    if var current = flights[key], current.cancelledWaiters < current.waiters {
      current.waiters += 1
      flights[key] = current
      flight = current
    } else {
      lastFlightID += 1
      let flightID = lastFlightID
      let launchID = LaunchToken()
      let task = Task { await self.run(target, launchID: launchID, flightID: flightID) }
      flight = Flight(id: flightID, task: task, waiters: 1, cancelledWaiters: 0)
      flights[key] = flight
      latestFlightIDs[key] = flightID
    }
    let flightID = flight.id
    let task = flight.task
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      Task { await self.waiterCancelled(key: key, flightID: flightID) }
    }
  } // End of func attach(_:)

  /// Counts a cancelled caller and cancels the launch once every caller was cancelled.
  private func waiterCancelled(key: SessionKey, flightID: UInt64) {
    guard var flight = flights[key], flight.id == flightID else { return }
    flight.cancelledWaiters += 1
    flights[key] = flight
    if flight.cancelledWaiters >= flight.waiters { flight.task.cancel() }
  }

  /// The progress of one launch, collected into its result.
  private struct Run {
    /// The target.
    let target: AttachTarget
    /// The launch id.
    let launchID: LaunchToken
    /// The flight running the launch.
    let flightID: UInt64
    /// When the attach started.
    let start: ContinuousClock.Instant
    /// The launch tab's session, once created.
    var gatewaySessionID: String?
    /// The connection, once found.
    var connectionID: String?
    /// The activation outcome, once confirmed.
    var activation: ActivationOutcome?
    /// Step timings.
    var timings = AttachTimings()
  }

  /// Runs one launch (the flight's task), publishes its states and removes the flight.
  private func run(
    _ target: AttachTarget,
    launchID: LaunchToken,
    flightID: UInt64
  ) async -> AttachResult {
    var progress = Run(target: target, launchID: launchID, flightID: flightID, start: clock.now())
    publish(.requested, for: progress)
    let finalState = await perform(&progress)
    progress.timings.finished = clock.now() - progress.start
    if case .failed = finalState { publish(finalState, for: progress) }
    if flights[target.key]?.id == flightID { flights[target.key] = nil }
    let result = AttachResult(
      key: target.key, launchID: launchID, state: finalState,
      gatewaySessionID: progress.gatewaySessionID, connectionID: progress.connectionID,
      activation: progress.activation, timings: progress.timings)
    await record(result, hostID: target.host.id)
    return result
  } // End of func run(_:launchID:flightID:)

  /// Steps 1–9. Returns the final state (`confirmed` or `failed`); `launched` and `confirmed`
  /// are published on the way (a failure is published by the caller).
  private func perform(_ progress: inout Run) async -> AttachState {
    let target = progress.target
    guard target.host.mode == .local else { return .failed(.unsupportedHost) }
    // 1. Revalidate.
    let session: DiscoveredSession
    switch await revalidate(target) {
    case .success(let fresh): session = fresh
    case .failure(let failure): return .failed(failure)
    }
    progress.timings.revalidated = clock.now() - progress.start
    // 2. Write the request.
    _ = try? store.sweep()
    let request = LaunchRequest(
      id: progress.launchID, createdAt: clock.date(), host: .local,
      tmuxPathOverride: target.host.tmuxPathOverride, session: session)
    do throws(LaunchStoreError) {
      try store.writeRequest(request)
    } catch {
      return .failed(.launchStore(error))
    }
    guard !Task.isCancelled else { return withdraw(progress, .cancelled) }
    // 3. iTerm2 must run.
    do {
      try await iTerm2.ensureRunning()
    } catch {
      return withdraw(progress, Self.failure(for: error))
    }
    guard !Task.isCancelled else { return withdraw(progress, .cancelled) }
    // 4. Open the launch tab. The request runs in a task of its own, so cancelling the attach
    // never leaves a tab whose session id is unknown.
    let tab = ITerm2API.CreateTabRequest(
      profileName: target.host.iTermProfileName,
      customProfileProperties: ITerm2API.ProfileProperty.customCommand(
        helperPath.attachCommandLine(for: progress.launchID))
        + [ITerm2API.ProfileProperty.closeSessionsOnEnd(true)])
    let iTerm2 = self.iTerm2
    let created = await Task { () -> Result<ITerm2API.CreateTabResponse, any Error> in
      do {
        return .success(try await iTerm2.createTab(tab))
      } catch {
        return .failure(error)
      }
    }.value
    let gatewaySessionID: String
    switch created {
    case .failure(let error):
      return withdraw(progress, Self.failure(for: error))
    case .success(let response):
      guard let sessionID = response.sessionID, !sessionID.isEmpty else {
        return withdraw(progress, .iTerm2(.protocolError("the new tab has no session id")))
      }
      gatewaySessionID = sessionID
    }
    // 5. Launched.
    rememberLaunch(of: gatewaySessionID)
    progress.gatewaySessionID = gatewaySessionID
    progress.timings.launched = clock.now() - progress.start
    publish(.launched(sessionID: gatewaySessionID), for: progress)
    // 6. Wait for the connection or the helper's result.
    let connectionID: String
    switch await waitForConnection(progress, gatewaySessionID: gatewaySessionID) {
    case .success(let found): connectionID = found
    case .failure(let failure): return .failed(failure)
    }
    progress.connectionID = connectionID
    progress.timings.connected = clock.now() - progress.start
    // 7. Identity.
    if let failure = await checkIdentity(
      connectionID: connectionID, gatewaySessionID: gatewaySessionID, key: session.key)
    {
      return .failed(failure)
    }
    // 8. Confirmed.
    progress.timings.confirmed = clock.now() - progress.start
    publish(.confirmed(connectionID: connectionID), for: progress)
    // 9. Bring it forward.
    progress.activation = await activateFirstTab(of: connectionID)
    progress.timings.activated = clock.now() - progress.start
    return .confirmed(connectionID: connectionID)
  } // End of func perform(_:)

  /// Step 1: discovers the host again and returns the session as it is now, if it is still the
  /// one `target` names.
  private func revalidate(_ target: AttachTarget) async -> Result<DiscoveredSession, AttachFailure>
  {
    let result: DiscoveryResult
    do {
      result = try await discovery.discover(target.host)
    } catch {
      return .failure(.cancelled)
    }
    switch result.status {
    case .ok(let sessions):
      if let fresh = sessions.first(where: { $0.key == target.key }) {
        guard fresh.createdAt == target.session.createdAt else { return .failure(.sessionChanged) }
        return .success(fresh)
      }
      let reused = sessions.contains { $0.key.sessionID == target.key.sessionID }
      return .failure(reused ? .sessionChanged : .sessionGone)
    case .noServer:
      return .failure(.sessionGone)
    case .tmuxNotFound:
      return .failure(.tmuxMissing)
    default:
      return .failure(.discoveryFailed(result.status.kind))
    }
  } // End of func revalidate(_:)

  /// Step 6: polls the helper's result and iTerm2's tmux connections until the launch tab owns
  /// a connection, the helper reports how it ended, or the budget runs out. Every failure
  /// withdraws the request.
  private func waitForConnection(
    _ progress: Run,
    gatewaySessionID: String
  ) async -> Result<String, AttachFailure> {
    let deadline = clock.now() + configuration.confirmationBudget
    while true {
      do throws(LaunchStoreError) {
        if let result = try store.takeResult(progress.launchID) {
          return .failure(result.failure.map(AttachFailure.from) ?? .helperEnded)
        }
      } catch {
        return .failure(withdrawFailure(progress, .launchStore(error)))
      }
      do {
        let connections = try await iTerm2.listTmuxConnections()
        if let match = connections.first(where: { $0.owningSessionID == gatewaySessionID }),
          let connectionID = match.connectionID, !connectionID.isEmpty
        {
          return .success(connectionID)
        }
      } catch {
        return .failure(withdrawFailure(progress, Self.failure(for: error)))
      }
      guard clock.now() < deadline else {
        return .failure(withdrawFailure(progress, .timedOut))
      }
      do {
        try await clock.sleep(for: configuration.pollInterval)
      } catch {
        return .failure(withdrawFailure(progress, .cancelled))
      }
    } // End of loop polling for the connection
  } // End of func waitForConnection(_:gatewaySessionID:)

  /// Step 7: asks tmux through the connection (still owned by the launch tab) which server and
  /// session it reached. A request failure is reported as is; an unreadable or different answer
  /// detaches the connection once the launch tab is old enough.
  private func checkIdentity(
    connectionID: String,
    gatewaySessionID: String,
    key: SessionKey
  ) async -> AttachFailure? {
    let output: String
    do {
      output = try await iTerm2.sendTmuxCommand(
        ConnectionIdentity.command, connectionID: connectionID, ownedBy: gatewaySessionID)
    } catch let error as ITerm2Error {
      return .identityCheckFailed(error)
    } catch {
      return .cancelled
    }
    let failure: AttachFailure
    if let reported = ConnectionIdentity.parse(output) {
      if reported.matches(key) { return nil }
      failure = .identityMismatch
    } else {
      failure = .identityCheckFailed(nil)
    }
    await retire(connectionID: connectionID, gatewaySessionID: gatewaySessionID)
    return failure
  } // End of func checkIdentity(connectionID:gatewaySessionID:key:)

  /// Step 9: waits (within the tab budget) for the connection's first tab and activates it.
  private func activateFirstTab(of connectionID: String) async -> ActivationOutcome {
    let deadline = clock.now() + configuration.tabBudget
    while true {
      let sessions: ITerm2API.ListSessionsResponse
      do {
        sessions = try await iTerm2.listSessions()
      } catch {
        return .failed(error as? ITerm2Error ?? .disconnected)
      }
      if let tabID = sessions.tabs(ofTmuxConnection: connectionID).lazy.compactMap(\.tabID)
        .first(where: { !$0.isEmpty })
      {
        // iTerm2 3.7.6 answers INVALID_OPTION when a tab target comes with `select_session`;
        // a tab target with the app options in the same request is accepted.
        let request = ITerm2API.ActivateRequest(
          target: .tab(tabID), orderWindowFront: true, selectTab: true, selectSession: false,
          activateApp: configuration.activatesApp ? .init(ignoringOtherApps: true) : nil)
        do {
          try await iTerm2.activate(request)
          return .activated(tabID: tabID)
        } catch {
          return .failed(error as? ITerm2Error ?? .disconnected)
        }
      }
      guard clock.now() < deadline else { return .noTab }
      do {
        try await clock.sleep(for: configuration.pollInterval)
      } catch {
        return .noTab
      }
    } // End of loop waiting for the connection's first tab
  } // End of func activateFirstTab(of:)

  // MARK: - Detach

  /// Detaches the tmux connection `connectionID` of the launch tab `gatewaySessionID` with
  /// `detach-client` (never by closing its tabs), waits for the connection to disappear and,
  /// when `launchID` names the launch that created it, for the helper's result.
  ///
  /// It first waits until the launch tab is `Configuration.minimumLaunchTabAge` old: counted
  /// from when this coordinator opened it, or from now for a tab it did not open (another
  /// process's, or one it no longer remembers), since such a tab exists already. Cancelling the
  /// caller during that wait sends nothing (`cancelled`). The command is then sent only if
  /// iTerm2 still lists the connection as owned by `gatewaySessionID` (otherwise
  /// `commandError` is `tmuxConnectionNotOwned`), and only once (D13); when it certainly was
  /// not sent, nothing is waited for.
  public func detach(
    connectionID: String,
    gatewaySessionID: String,
    launchID: LaunchToken? = nil
  ) async -> DetachResult {
    var result = DetachResult(connectionID: connectionID)
    let start = clock.now()
    let remaining = remainingAge(of: gatewaySessionID)
    if remaining > .zero {
      do {
        try await clock.sleep(for: remaining)
      } catch {
        result.cancelled = true
        return await recordDetach(result, since: start)
      }
    }
    do {
      _ = try await iTerm2.sendTmuxCommand(
        ConnectionIdentity.detachCommand, connectionID: connectionID, ownedBy: gatewaySessionID)
    } catch let error as ITerm2Error {
      result.commandError = error
      if error.isNotSent { return await recordDetach(result, since: start) }
    } catch {
      result.commandError = .disconnected
    }
    let deadline = clock.now() + configuration.detachBudget
    while !result.connectionClosed {
      do {
        let connections = try await iTerm2.listTmuxConnections()
        result.connectionClosed = !connections.contains { $0.connectionID == connectionID }
      } catch {
        result.pollError = error as? ITerm2Error ?? .disconnected
        break
      }
      if result.connectionClosed { break }
      guard clock.now() < deadline else { break }
      guard (try? await clock.sleep(for: configuration.pollInterval)) != nil else { break }
    } // End of loop waiting for the connection to close
    if result.connectionClosed {
      launchedAt[gatewaySessionID] = nil
      if let launchID { result.helperResult = await waitForResult(launchID) }
    }
    return await recordDetach(result, since: start)
  } // End of func detach(connectionID:gatewaySessionID:launchID:)

  /// Records how a detach ended (no ids) and returns `result`.
  private func recordDetach(
    _ result: DetachResult,
    since start: ContinuousClock.Instant
  ) async -> DetachResult {
    let detail: String
    if result.cancelled {
      detail = "detach: cancelled before sending"
    } else if result.commandError == .tmuxConnectionNotOwned {
      detail = "detach: not sent, the connection is not the launch tab's"
    } else if result.commandError?.isNotSent == true {
      detail = "detach: not sent"
    } else {
      detail =
        result.connectionClosed ? "detach: connection closed" : "detach: connection still open"
    }
    await diagnostics?.record(
      .attach, outcome: result.connectionClosed ? .success : .failure,
      durationMs: Self.milliseconds(clock.now() - start), detail: detail)
    return result
  } // End of func recordDetach(_:since:)

  /// Waits (within the result budget) for the helper's result of `launchID`.
  private func waitForResult(_ launchID: LaunchToken) async -> LaunchResult? {
    let deadline = clock.now() + configuration.resultBudget
    while true {
      if let result = try? store.takeResult(launchID) { return result }
      guard clock.now() < deadline,
        (try? await clock.sleep(for: configuration.pollInterval)) != nil
      else { return nil }
    }
  }

  /// After a failed identity check: sends `detach-client` once (ignoring the outcome) when the
  /// launch tab is old enough. The wait and the command run in a task of their own that the
  /// attach waits for, so cancelling the attach can neither skip the wait nor end the tab
  /// early; if the wait fails anyway, nothing is sent.
  private func retire(connectionID: String, gatewaySessionID: String) async {
    let remaining = remainingAge(of: gatewaySessionID)
    let clock = self.clock
    let iTerm2 = self.iTerm2
    await Task {
      if remaining > .zero {
        do {
          try await clock.sleep(for: remaining)
        } catch {
          return
        }
      }
      _ = try? await iTerm2.sendTmuxCommand(
        ConnectionIdentity.detachCommand, connectionID: connectionID, ownedBy: gatewaySessionID)
    }.value
  } // End of func retire(connectionID:gatewaySessionID:)

  /// How long until the launch tab `gatewaySessionID` is `minimumLaunchTabAge` old: counted
  /// from when this coordinator opened it, or from now for a tab it did not open or no longer
  /// remembers (it exists already, so it is at least that old once the time has passed).
  private func remainingAge(of gatewaySessionID: String) -> Duration {
    let now = clock.now()
    let opened = launchedAt[gatewaySessionID] ?? now
    return opened + configuration.minimumLaunchTabAge - now
  }

  /// Remembers when the launch tab `gatewaySessionID` was reported open, forgetting the oldest
  /// one beyond `rememberedLaunches`.
  private func rememberLaunch(of gatewaySessionID: String) {
    launchedAt[gatewaySessionID] = clock.now()
    if launchedAt.count > Self.rememberedLaunches,
      let oldest = launchedAt.min(by: { $0.value < $1.value })?.key
    {
      launchedAt[oldest] = nil
    }
  }

  // MARK: - Helpers

  /// Withdraws the request (so a launch tab that starts late cannot attach) and returns the
  /// failed state.
  private func withdraw(_ progress: Run, _ failure: AttachFailure) -> AttachState {
    .failed(withdrawFailure(progress, failure))
  }

  /// Withdraws the request and returns `failure`.
  private func withdrawFailure(_ progress: Run, _ failure: AttachFailure) -> AttachFailure {
    _ = try? store.discardRequest(progress.launchID)
    return failure
  }

  /// Hands `state` to the observer, and records it as the session's state only while the launch
  /// is the session's latest one (an all-cancelled launch winding down must not overwrite the
  /// state of the launch that replaced it).
  private func publish(_ state: AttachState, for progress: Run) {
    let key = progress.target.key
    let isCurrent = latestFlightIDs[key] == progress.flightID
    if isCurrent { states[key] = state }
    onUpdate?(
      AttachUpdate(key: key, launchID: progress.launchID, state: state, isCurrent: isCurrent))
  }

  /// Records the outcome of an attach: its state and failure kinds and its duration only.
  private func record(_ result: AttachResult, hostID: UUID) async {
    guard let diagnostics else { return }
    let duration = Self.milliseconds(result.timings.finished ?? .zero)
    if let failure = result.failure {
      let detail = failure.detail.map { " (\($0))" } ?? ""
      await diagnostics.record(
        .attach, outcome: failure == .timedOut ? .timedOut : .failure,
        hostID: hostID.uuidString, durationMs: duration,
        detail: "attach failed: \(failure.kind)\(detail)")
    } else {
      await diagnostics.record(
        .attach, outcome: .success, hostID: hostID.uuidString, durationMs: duration,
        detail: "attach confirmed")
    }
  } // End of func record(_:hostID:)

  /// The failure for an error thrown by an iTerm2 request.
  static func failure(for error: any Error) -> AttachFailure {
    if let error = error as? ITerm2Error { return .iTerm2(error) }
    return .cancelled
  }

  /// Whole milliseconds of `duration`.
  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }
}
