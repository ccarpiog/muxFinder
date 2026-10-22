import Foundation

/// Attaches tmux sessions in iTerm2 through a launch tab and confirms the attachment, or
/// focuses an attachment that exists already (PLAN.md Architecture, Phase 4, D15, D16, D17),
/// for sessions on this Mac and on remote Macs reached with ssh from the launch tab.
///
/// One attach runs these steps:
/// 1. Revalidate the session through discovery (same key, same `session_created`; for an SSH
///    host, a valid destination first).
///    Then check for an existing attachment (`AttachmentIndex`, PLAN.md D16): when this Mac's
///    iTerm2 already shows the session, the attach becomes a focus: it activates that
///    connection's first tab (as in step 9, bound to the connection's owner), opens nothing
///    and ends `focused(connectionID)`; when every such connection closed or changed owner
///    first, it activates nothing and fails (`attachmentChanged`). When iTerm2 is not running
///    nothing can be attached, so the launch goes on; when its connections cannot be listed,
///    the attach fails (`attachmentCheckFailed`) rather than risk a duplicate.
/// 2. Write the launch request file (D2, D14), with the host kind: local, or ssh and its
///    destination (D17).
/// 3. `ensureRunning()`: the only call that may launch iTerm2.
/// 4. `CreateTab` in a new window, using the host's iTerm2 profile when one is set, whose
///    command is `<helper> attach <launch id>` and whose session closes when the helper exits.
/// 5. The state becomes `launched(sessionID)`.
/// 6. Poll `ListConnections` until a connection's `owning_session_id` is the launch tab's
///    session, or the helper's result file reports how it ended, within the confirmation budget
///    (15 s locally, 20 s for a remote host). A remote attach whose launch tab is still open
///    past its budget (ssh waiting for a password in the tab, for example) publishes
///    `stillWaiting`, never a success, and keeps watching until it confirms, fails, or reaches
///    its wait limit (D17).
/// 7. Check identity through that connection (`ConnectionIdentity.command`) against the
///    revalidated key and the host's node name (`uname -n`).
/// 8. The state becomes `confirmed(connectionID)`.
/// 9. `Activate` the first tab carrying that `tmux_connection_id`, while the launch tab still
///    owns the connection.
///
/// Concurrent attaches for the same `SessionKey` coalesce into one launch and share its
/// result. No request is retried automatically (D13): a failed `CreateTab`, identity check or
/// activation ends that step. Every failure before a connection was found withdraws the request
/// file, so a launch tab that starts late cannot attach; once the tab exists its session id is
/// in the result, so the caller can find it. Detaching sends `detach-client` on the connection
/// and never closes tmux tabs: `detach(connectionID:gatewaySessionID:launchID:)` for one known
/// connection, `detach(session:on:)` for every attachment of a session in this Mac's iTerm2,
/// whoever opened it.
///
/// `createAndAttach(_:)` creates a session first (`SessionCreating`, `TmuxCommands` in
/// production: detached, never replacing an existing one) and then attaches it through the
/// same steps, minus the existing-attachment check: a session created a moment ago cannot be
/// attached anywhere yet, so the user's tmux connections are not asked (PLAN.md D18). A
/// creation that fails never opens a tab.
///
/// `moveHere(_:confirmation:)` (PLAN.md D21) runs the same steps, but the launch request asks
/// for `attach-session -d`, so tmux detaches every other client of the session (on any Mac) as
/// the launch tab attaches it. It needs an explicit `MoveHereConfirmation` naming the session.
/// Its existing-attachment check always runs: when this Mac's iTerm2 shows the session already,
/// it runs nothing and fails `alreadyAttachedHere` (`-d` would detach that attachment too), and
/// when a connection there cannot be ruled out as showing it (no usable answer, for example),
/// `possiblyAttachedHere`. `attach(_:)` and `createAndAttach(_:)` never ask for `-d`. A call
/// never joins a launch of the other kind, and never starts while a conflicting launch of the
/// session (a move here, for an attach; any launch, for a move here) may still attach it: it
/// waits until that launch ended and is settled (its helper's result, its connection or the
/// end of its launch tab seen, or its request withdrawn before a helper took it), within a
/// bounded time (`earlierLaunchPending`), then starts its own.
///
/// Ending a connection ends its launch tab, and iTerm2 blocks its whole API behind a modal
/// warning when a session ends within 3 s of starting (PLAN.md *Verified facts*, Phase 4).
/// So the coordinator never sends `detach-client` (after a failed identity check, or for
/// `detach`) before the launch tab is `Configuration.minimumLaunchTabAge` old, and every
/// command for a connection goes through `ITerm2Integration.sendTmuxCommand(_:connectionID:ownedBy:)`
/// (every activation through `activateFirstTab(ofTmuxConnection:ownedBy:options:)`), bound to
/// the tab that owns it, because connection ids are short names iTerm2 reuses.
///
/// Diagnostics record step outcomes, kinds and durations only: no paths, names or terminal
/// content.
public actor AttachCoordinator {
  /// Whether and how an attach checks for an existing attachment of the session first.
  public enum ExistingAttachmentCheck: Sendable {
    /// An `AttachmentIndex` over the coordinator's own iTerm2 integration and clock, with the
    /// default configuration. What the app uses.
    case standard
    /// This index (a filtered one, as in `e2e-local`, or one with its own clock in tests).
    case index(AttachmentIndex)
    /// No check: every attach launches. Only for tests of the launch path itself;
    /// `detach(session:on:)` and `moveHere(_:confirmation:)` (which never skips its check) then
    /// use the standard index.
    case off
  }

  /// Budgets and options. The defaults are PLAN.md's values.
  public struct Configuration: Sendable {
    /// How long after `launched` a connection (or a helper result) may take to appear, locally.
    public var confirmationBudget: Duration
    /// The same for a remote host (PLAN.md Phase 5, D17): ssh connects and authenticates first.
    /// When it runs out with the launch tab still open, the attach reports `stillWaiting`.
    public var remoteConfirmationBudget: Duration
    /// The pause between two polls while a remote attach is `stillWaiting`.
    public var stillWaitingPollInterval: Duration
    /// How long after `launched` a remote attach keeps watching a launch tab that is still
    /// waiting, before it ends `waitLimitReached`.
    public var remoteWaitLimit: Duration
    /// The pause between two polls.
    public var pollInterval: Duration
    /// How long after `confirmed` the connection's first tab may take to appear.
    public var tabBudget: Duration
    /// How long a detached connection may take to disappear.
    public var detachBudget: Duration
    /// How long after the connection closed the helper's result may take to appear.
    public var resultBudget: Duration
    /// How long the helper's result may take to appear after a remote attach found its launch
    /// tab closed. iTerm2 drops a closed tab from its listing at once but ends its processes
    /// later: a forced close of a tab whose ssh waited for a password ended ssh about 5 s
    /// after the close (PLAN.md *Verified facts*, Phase 5b).
    public var closedTabResultBudget: Duration
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
      remoteConfirmationBudget: Duration = .seconds(20),
      stillWaitingPollInterval: Duration = .seconds(1),
      remoteWaitLimit: Duration = .seconds(300),
      pollInterval: Duration = .milliseconds(200),
      tabBudget: Duration = .seconds(5),
      detachBudget: Duration = .seconds(10),
      resultBudget: Duration = .seconds(5),
      closedTabResultBudget: Duration = .seconds(10),
      minimumLaunchTabAge: Duration = .seconds(10),
      activatesApp: Bool = true
    ) {
      self.confirmationBudget = confirmationBudget
      self.remoteConfirmationBudget = remoteConfirmationBudget
      self.stillWaitingPollInterval = stillWaitingPollInterval
      self.remoteWaitLimit = remoteWaitLimit
      self.pollInterval = pollInterval
      self.tabBudget = tabBudget
      self.detachBudget = detachBudget
      self.resultBudget = resultBudget
      self.closedTabResultBudget = closedTabResultBudget
      self.minimumLaunchTabAge = minimumLaunchTabAge
      self.activatesApp = activatesApp
    } // End of init(confirmationBudget:remoteConfirmationBudget:stillWaitingPollInterval:…)
  }

  /// Receives every state change of every launch, in order, on the coordinator's executor.
  /// Keep it short. An update whose `isCurrent` is `false` comes from a launch a newer one for
  /// the same session replaced; observers of the session's state ignore it.
  public typealias UpdateHandler = @Sendable (AttachUpdate) -> Void

  /// How many launch tabs the coordinator remembers the opening time (and launch id) of. A tab
  /// it forgot is treated like one it did not open, which only makes a detach wait longer.
  static let rememberedLaunches = 64

  /// A launch tab this coordinator opened.
  private struct Launch {
    /// When iTerm2 reported it open.
    let openedAt: ContinuousClock.Instant
    /// The launch running in it, whose helper result a detach can wait for.
    let launchID: LaunchToken
  }

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
    /// Whether it is a move here (`attach-session -d`); only callers of the same kind join it.
    let detachesOtherClients: Bool

    /// Whether callers still wait for it (it is not winding down after all were cancelled).
    var isLive: Bool { cancelledWaiters < waiters }
  }

  /// A launch that may still attach its session in this Mac's iTerm2 (PLAN.md D21): its run
  /// goes on (live or winding down), or it ended without proof that its helper ended or can
  /// never start. A conflicting call waits these out.
  private struct PendingLaunch {
    /// The flight that runs (or ran) it.
    let flightID: UInt64
    /// Its launch id: the names of its request and result files.
    let launchID: LaunchToken
    /// Whether its request asks for `attach-session -d`.
    let detachesOtherClients: Bool
    /// Whether its host is reached with ssh (it then gets the remote confirmation budget).
    let remote: Bool
    /// Whether its run goes on.
    var running = true
    /// Its launch tab, once `CreateTab` reported one.
    var gatewaySessionID: String?
    /// When its launch tab was first seen gone from iTerm2.
    var tabGoneAt: ContinuousClock.Instant?
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
  /// The index an attach checks before launching; `nil` when the check is off.
  private let attachCheckIndex: AttachmentIndex?
  /// The index `detach(session:on:)` and `moveHere(_:confirmation:)` use (the attach check's, or
  /// the standard one).
  private let detachIndex: AttachmentIndex
  /// Creates sessions for `createAndAttach(_:)`.
  private let sessionCreator: any SessionCreating
  /// Launches in progress, by session.
  private var flights: [SessionKey: Flight] = [:]
  /// The id of the most recent launch.
  private var lastFlightID: UInt64 = 0
  /// The id of each session's latest launch; only that launch changes `states`.
  private var latestFlightIDs: [SessionKey: UInt64] = [:]
  /// The launches of each session that may still attach it, oldest first.
  private var pendingLaunches: [SessionKey: [PendingLaunch]] = [:]
  /// The latest state of every session attached so far.
  private var states: [SessionKey: AttachState] = [:]
  /// The launch tabs this coordinator opened, by their session id.
  private var launches: [String: Launch] = [:]

  /// Creates a coordinator from its parts. Tests pass fakes for every seam.
  public init(
    iTerm2: any ITerm2Integration,
    discovery: any HostDiscovering,
    store: any LaunchRequestStore,
    helperPath: LaunchHelperPath,
    clock: any AttachClock = SystemAttachClock(),
    configuration: Configuration = Configuration(),
    existingAttachments: ExistingAttachmentCheck = .standard,
    sessionCreator: any SessionCreating = TmuxCommands(),
    diagnostics: DiagnosticsLog? = nil,
    onUpdate: UpdateHandler? = nil
  ) {
    self.iTerm2 = iTerm2
    self.sessionCreator = sessionCreator
    self.discovery = discovery
    self.store = store
    self.helperPath = helperPath
    self.clock = clock
    self.configuration = configuration
    self.diagnostics = diagnostics
    self.onUpdate = onUpdate
    let standard = AttachmentIndex(iTerm2: iTerm2, clock: clock)
    switch existingAttachments {
    case .standard:
      attachCheckIndex = standard
      detachIndex = standard
    case .index(let index):
      attachCheckIndex = index
      detachIndex = index
    case .off:
      attachCheckIndex = nil
      detachIndex = standard
    }
  } // End of init(iTerm2:discovery:store:helperPath:clock:configuration:existingAttachments:…)

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

  /// How many launches of `key` ended but may still attach it (PLAN.md D21). For tests.
  func unsettledLaunchCount(for key: SessionKey) -> Int {
    pendingLaunches[key]?.filter { !$0.running }.count ?? 0
  }

  // MARK: - Attach

  /// Attaches `target`'s session and returns how it ended: `confirmed`, `focused` (it was
  /// attached in this Mac's iTerm2 already, and its tab was brought forward without opening
  /// anything) or `failed`. A call for a session whose launch is in progress joins it instead
  /// of starting another (and shares its check and focus). When
  /// every caller waiting for a launch is cancelled, the launch stops at its next step and
  /// fails with `cancelled` (a `CreateTab` already sent still completes, so its session id is
  /// reported); a call arriving after that starts a new launch, and from then on only the new
  /// launch changes `state(of:)`. An attach never asks tmux to detach other clients; a call
  /// while a move here of the session is in progress, or after one that may still attach it,
  /// waits until that launch ended and is settled, then attaches (and so focuses the moved
  /// attachment, if it attached); when it does not settle within the confirmation budget, the
  /// call fails `earlierLaunchPending` and runs nothing (PLAN.md D21).
  public func attach(_ target: AttachTarget) async -> AttachResult {
    await attach(target, checksExistingAttachments: true, detachesOtherClients: false)
  }

  /// Moves `target`'s session here (PLAN.md D21): attaches it through a launch tab exactly as
  /// `attach(_:)` does (revalidation, request, launch tab, confirmation by connection, identity
  /// check, activation, the same budgets and typed failures, locally or over ssh), except that
  /// the helper runs `attach-session -d`, so tmux detaches every other client of the session,
  /// on this Mac or any other, as it attaches.
  ///
  /// It runs only with `confirmation` naming this session
  /// (`.detachOtherClients(of: target.key)`); any other confirmation fails
  /// `moveHereNotConfirmed` before anything runs. Its existing-attachment check always runs
  /// (with the standard index when the coordinator's check is off): when this Mac's iTerm2
  /// shows the session already, it fails `alreadyAttachedHere` with that connection and runs,
  /// writes and opens nothing, because `-d` would detach that attachment too; when a connection
  /// there cannot be ruled out as showing the session
  /// (`AttachmentSnapshot.unresolvedConnections(for:)`), it fails `possiblyAttachedHere` the
  /// same way. Concurrent move here calls for the session share one launch; a call while
  /// another launch of the session is in progress (an attach, or a move here whose callers
  /// were all cancelled), or after one that may still attach it, waits until that launch ended
  /// and is settled, then starts (and so finds that attachment, if it attached). A launch that
  /// does not settle within the confirmation budget fails the call `earlierLaunchPending`; a
  /// caller cancelled during the wait gets `cancelled`; either way nothing started.
  public func moveHere(
    _ target: AttachTarget,
    confirmation: MoveHereConfirmation
  ) async -> AttachResult {
    guard confirmation.key == target.key else {
      let result = AttachResult(
        key: target.key, launchID: LaunchToken(), state: .failed(.moveHereNotConfirmed))
      await record(result, hostID: target.host.id, detachesOtherClients: true)
      return result
    }
    return await attach(target, checksExistingAttachments: true, detachesOtherClients: true)
  } // End of func moveHere(_:confirmation:)

  /// Creates the session `request` describes and attaches it (PLAN.md D18). Creation runs
  /// first, through the coordinator's `SessionCreating` (noninteractive, bounded, never
  /// replacing an existing session); when it fails, the result carries the failure and nothing
  /// was attached, written or opened. The created session is then attached as `attach(_:)`
  /// does (revalidation, request, launch tab, confirmation, identity check, activation), except
  /// that the existing-attachment check is skipped: a session created a moment ago cannot be
  /// attached in iTerm2 yet, so no tmux connection of the user's is asked anything.
  ///
  /// `onCreated`, when given, is called with the created session once creation succeeded and
  /// before its attach publishes anything (on the coordinator's executor: keep it short), so a
  /// caller can follow that attach's updates, whose key is the created session's, from its
  /// first state on (PLAN.md D25). It is not called when creation fails.
  public func createAndAttach(
    _ request: NewSessionRequest,
    onCreated: (@Sendable (CreatedSession) -> Void)? = nil
  ) async -> CreateAndAttachResult {
    let start = clock.now()
    let created: CreatedSession
    do throws(SessionCreationError) {
      created = try await sessionCreator.createSession(request)
    } catch {
      let detail = error.detail.map { " (\($0))" } ?? ""
      await diagnostics?.record(
        .attach, outcome: error == .timedOut ? .timedOut : .failure,
        hostID: request.host.id.uuidString,
        durationMs: Self.milliseconds(clock.now() - start),
        detail: "new session failed: \(error.kind)\(detail)")
      return CreateAndAttachResult(creationFailure: error)
    }
    onCreated?(created)
    await diagnostics?.record(
      .attach, outcome: .success, hostID: request.host.id.uuidString,
      durationMs: Self.milliseconds(clock.now() - start), detail: "new session created")
    let result = await attach(
      created.attachTarget(on: request.host), checksExistingAttachments: false,
      detachesOtherClients: false)
    return CreateAndAttachResult(created: created, attach: result)
  } // End of func createAndAttach(_:onCreated:)

  /// The session named exactly `name` on `host` as discovery reports it now, as an attach
  /// target (PLAN.md D25: "Open existing" after a New session collision resolves the name
  /// against a fresh listing of the host, never a cached one, since the session tmux reported
  /// may be another one than the list showed). No session with exactly that name (none listed,
  /// or no server) is `sessionGone`; tmux missing `tmuxMissing`; any other discovery failure
  /// `discoveryFailed`; a cancelled caller `cancelled`. Read-only: nothing is written, opened or
  /// asked of iTerm2.
  public func currentSession(
    named name: String,
    on host: HostConfig
  ) async -> Result<AttachTarget, AttachFailure> {
    let result: DiscoveryResult
    do {
      result = try await discovery.discover(host)
    } catch {
      return .failure(.cancelled)
    }
    switch result.status {
    case .ok(let sessions):
      guard let session = sessions.first(where: { $0.name == name }) else {
        return .failure(.sessionGone)
      }
      return .success(AttachTarget(host: host, session: session))
    case .noServer:
      return .failure(.sessionGone)
    case .tmuxNotFound:
      return .failure(.tmuxMissing)
    default:
      return .failure(.discoveryFailed(result.status.kind))
    }
  } // End of func currentSession(named:on:)

  /// `attach(_:)` and `moveHere(_:confirmation:)`: the existing-attachment check (step 1b) runs
  /// when `checksExistingAttachments` is set and the coordinator has an index, and always for a
  /// move here (`detachesOtherClients`, whose request asks for `attach-session -d`). A caller
  /// joins a live launch of the same kind; conflicting launches (`conflictingLaunches(of:…)`)
  /// are waited out first, and the wait for an ended one is bounded (`earlierLaunchPending`).
  private func attach(
    _ target: AttachTarget,
    checksExistingAttachments: Bool,
    detachesOtherClients: Bool
  ) async -> AttachResult {
    let key = target.key
    // Never join a launch of the other kind (an attach must not end up detaching other
    // clients, a move here must not end up not doing so), and never start while a conflicting
    // launch may still attach the session: its `-d`, or this one's, would detach the other's
    // attachment in this Mac's iTerm2. A running launch ends within its own budgets; one that
    // ended unsettled gets the confirmation budget from the moment this caller first saw it.
    // The last check and the start below run without a suspension in between.
    var unsettledSince: [UInt64: ContinuousClock.Instant] = [:]
    while true {
      let conflicting = conflictingLaunches(of: key, detachesOtherClients: detachesOtherClients)
      if conflicting.isEmpty { break }
      let ended = conflicting.filter { !$0.running }
      if !ended.isEmpty {
        for launch in ended where unsettledSince[launch.flightID] == nil {
          unsettledSince[launch.flightID] = clock.now()
        }
        if await settle(ended.map(\.flightID), of: key) { continue }
        let now = clock.now()
        let overdue = (pendingLaunches[key] ?? []).contains { launch in
          guard !launch.running, let since = unsettledSince[launch.flightID] else { return false }
          return now >= since + confirmationBudget(remote: launch.remote)
        }
        if overdue {
          return await refuseBeforeLaunch(
            target, .earlierLaunchPending, detachesOtherClients: detachesOtherClients)
        }
      }
      do {
        try await clock.sleep(for: configuration.pollInterval)
      } catch {
        return await refuseBeforeLaunch(
          target, .cancelled, detachesOtherClients: detachesOtherClients)
      }
    } // End of loop waiting out conflicting launches
    let flight: Flight
    // A launch whose callers were all cancelled is winding down; a new caller of the same kind
    // starts afresh (only an attach gets here while one runs: it does not conflict with an
    // attach).
    if var current = flights[key], current.isLive {
      current.waiters += 1
      flights[key] = current
      flight = current
    } else {
      lastFlightID += 1
      let flightID = lastFlightID
      let launchID = LaunchToken()
      pendingLaunches[key, default: []].append(
        PendingLaunch(
          flightID: flightID, launchID: launchID, detachesOtherClients: detachesOtherClients,
          remote: target.host.mode == .ssh))
      let task = Task {
        await self.run(
          target, launchID: launchID, flightID: flightID,
          checksExistingAttachments: checksExistingAttachments,
          detachesOtherClients: detachesOtherClients)
      }
      flight = Flight(
        id: flightID, task: task, waiters: 1, cancelledWaiters: 0,
        detachesOtherClients: detachesOtherClients)
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
  } // End of func attach(_:checksExistingAttachments:detachesOtherClients:)

  /// Counts a cancelled caller and cancels the launch once every caller was cancelled.
  private func waiterCancelled(key: SessionKey, flightID: UInt64) {
    guard var flight = flights[key], flight.id == flightID else { return }
    flight.cancelledWaiters += 1
    flights[key] = flight
    if flight.cancelledWaiters >= flight.waiters { flight.task.cancel() }
  }

  /// The launches of `key` a new caller must wait out before it joins or starts one (PLAN.md
  /// D21): none when a live launch of its own kind runs (it joins that one, which waited out
  /// every conflict before it started); otherwise every pending launch it conflicts with,
  /// running or ended: for a move here (`detachesOtherClients`), every one, since its `-d`
  /// would detach their attachments and theirs its own; for an attach, every move here. An
  /// attach never waits for another attach (PLAN.md D15).
  private func conflictingLaunches(
    of key: SessionKey,
    detachesOtherClients: Bool
  ) -> [PendingLaunch] {
    if let current = flights[key], current.isLive,
      current.detachesOtherClients == detachesOtherClients
    {
      return []
    }
    return (pendingLaunches[key] ?? []).filter { detachesOtherClients || $0.detachesOtherClients }
  } // End of func conflictingLaunches(of:detachesOtherClients:)

  /// Looks for proof that the ended launches `flightIDs` of `key` can no longer attach the
  /// session in this Mac's iTerm2, forgets every one that has it, and returns whether any did.
  /// Proof is the helper's result (the helper ended), a tmux connection owned by the launch tab
  /// (it attached: its `-d`, if any, ran, and the existing-attachment check now sees it), or the
  /// launch tab gone from iTerm2 (or iTerm2 not running) for `closedTabResultBudget` without a
  /// result: the tab closes when the helper ends, the helper writes its result first, and a
  /// helper may end some seconds after its tab left the listing (D17). A listing that fails
  /// proves nothing.
  private func settle(_ flightIDs: [UInt64], of key: SessionKey) async -> Bool {
    let candidates = (pendingLaunches[key] ?? []).filter {
      !$0.running && flightIDs.contains($0.flightID)
    }
    var settled: Set<UInt64> = []
    for launch in candidates {
      // Taking the result deletes it; nothing else waits for the result of an ended launch.
      if (try? store.takeResult(launch.launchID)) != nil { settled.insert(launch.flightID) }
    }
    var tabsGone: Set<UInt64> = []
    let watched = candidates.filter {
      !settled.contains($0.flightID) && $0.gatewaySessionID != nil
    }
    if !watched.isEmpty {
      let owners: Set<String>?
      do {
        owners = Set(
          try await iTerm2.listTmuxConnections().compactMap { connection in
            connection.connectionID?.isEmpty == false ? connection.owningSessionID : nil
          })
      } catch ITerm2Error.notRunning {
        owners = []
      } catch {
        owners = nil
      }
      let attached = watched.filter { owners?.contains($0.gatewaySessionID ?? "") == true }
      settled.formUnion(attached.map(\.flightID))
      if attached.count < watched.count {
        let open: Set<String>?
        do {
          open = try await iTerm2.listSessions().allSessionIDs
        } catch ITerm2Error.notRunning {
          open = []
        } catch {
          open = nil
        }
        for launch in watched where !settled.contains(launch.flightID) {
          if let open, !open.contains(launch.gatewaySessionID ?? "") {
            tabsGone.insert(launch.flightID)
          }
        }
      }
    } // End of the look at the launch tabs
    // The state may have changed during the requests; apply the findings to it as it is now.
    let now = clock.now()
    var pending = pendingLaunches[key] ?? []
    for index in pending.indices where tabsGone.contains(pending[index].flightID) {
      let since = pending[index].tabGoneAt ?? now
      pending[index].tabGoneAt = since
      if now >= since + configuration.closedTabResultBudget {
        settled.insert(pending[index].flightID)
      }
    }
    pending.removeAll { settled.contains($0.flightID) }
    pendingLaunches[key] = pending.isEmpty ? nil : pending
    return !settled.isEmpty
  } // End of func settle(_:of:)

  /// Ends a call that started no launch with `failure` (`cancelled` or `earlierLaunchPending`):
  /// records it and returns its result, with a launch id nothing used and no state published.
  private func refuseBeforeLaunch(
    _ target: AttachTarget,
    _ failure: AttachFailure,
    detachesOtherClients: Bool
  ) async -> AttachResult {
    let result = AttachResult(key: target.key, launchID: LaunchToken(), state: .failed(failure))
    await record(result, hostID: target.host.id, detachesOtherClients: detachesOtherClients)
    return result
  }

  /// How long a connection (or a helper result) may take to appear after `launched`: the remote
  /// budget for a host reached with ssh, the local one otherwise.
  private func confirmationBudget(remote: Bool) -> Duration {
    remote ? configuration.remoteConfirmationBudget : configuration.confirmationBudget
  }

  /// Records how the launch of `progress` ended: forgotten when it can no longer attach
  /// (`Run.mayStillAttach`), otherwise kept as ended with its launch tab, for the conflicting
  /// calls that wait it out.
  private func endLaunch(_ progress: Run) {
    let key = progress.target.key
    guard var pending = pendingLaunches[key],
      let index = pending.firstIndex(where: { $0.flightID == progress.flightID })
    else { return }
    if progress.mayStillAttach {
      pending[index].running = false
      pending[index].gatewaySessionID = progress.gatewaySessionID
    } else {
      pending.remove(at: index)
    }
    pendingLaunches[key] = pending.isEmpty ? nil : pending
  } // End of func endLaunch(_:)

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
    /// Whether step 1b (the existing-attachment check) runs.
    let checksExistingAttachments: Bool
    /// Whether this is a move here: the request asks for `attach-session -d`, and step 1b
    /// always runs and refuses (`alreadyAttachedHere`) instead of focusing.
    let detachesOtherClients: Bool
    /// The launch tab's session, once created.
    var gatewaySessionID: String?
    /// The connection, once found.
    var connectionID: String?
    /// The activation outcome, once confirmed or focused.
    var activation: ActivationOutcome?
    /// What the existing-attachment check found, once it ran.
    var existingAttachments: AttachmentSnapshot.Counts?
    /// Step timings.
    var timings = AttachTimings()
    /// Whether `CreateTab` was sent, so a launch tab may run the helper with this launch's id.
    var tabRequested = false
    /// Whether the request was withdrawn before a helper took it (`discardRequest` removed the
    /// file, and the first unlink wins, D14), so no helper can ever use it.
    var requestWithdrawn = false
    /// Whether the helper's result was taken: the helper ended.
    var helperEnded = false

    /// Whether the launch may still attach the session after its run ended: a launch tab was
    /// asked for, and neither its connection, nor the helper's result, nor a withdrawal before
    /// a helper took the request settled it (PLAN.md D21).
    var mayStillAttach: Bool {
      tabRequested && connectionID == nil && !helperEnded && !requestWithdrawn
    }
  }

  /// Runs one launch (the flight's task), publishes its states and removes the flight.
  private func run(
    _ target: AttachTarget,
    launchID: LaunchToken,
    flightID: UInt64,
    checksExistingAttachments: Bool,
    detachesOtherClients: Bool
  ) async -> AttachResult {
    var progress = Run(
      target: target, launchID: launchID, flightID: flightID, start: clock.now(),
      checksExistingAttachments: checksExistingAttachments,
      detachesOtherClients: detachesOtherClients)
    publish(.requested, for: progress)
    let finalState = await perform(&progress)
    progress.timings.finished = clock.now() - progress.start
    if case .failed = finalState { publish(finalState, for: progress) }
    if flights[target.key]?.id == flightID { flights[target.key] = nil }
    endLaunch(progress)
    let result = AttachResult(
      key: target.key, launchID: launchID, state: finalState,
      gatewaySessionID: progress.gatewaySessionID, connectionID: progress.connectionID,
      activation: progress.activation, existingAttachments: progress.existingAttachments,
      timings: progress.timings)
    await record(result, hostID: target.host.id, detachesOtherClients: detachesOtherClients)
    return result
  } // End of func run(_:launchID:flightID:checksExistingAttachments:detachesOtherClients:)

  /// Steps 1–9. Returns the final state (`confirmed`, `focused` or `failed`); `launched`,
  /// `stillWaiting`, `confirmed` and `focused` are published on the way (a failure is published
  /// by the caller).
  private func perform(_ progress: inout Run) async -> AttachState {
    let target = progress.target
    let launchHost: LaunchHost
    switch Self.launchHost(for: target.host) {
    case .success(let value): launchHost = value
    case .failure(let failure): return .failed(failure)
    }
    // 1. Revalidate.
    let session: DiscoveredSession
    let host: AttachmentIndex.Host?
    switch await revalidate(target) {
    case .success(let fresh): (session, host) = fresh
    case .failure(let failure): return .failed(failure)
    }
    progress.timings.revalidated = clock.now() - progress.start
    // 1b. Already attached in this Mac's iTerm2? Then focus it and open nothing; a move here
    // runs nothing at all (`-d` would detach that attachment too), nor when a connection there
    // cannot be ruled out as showing the session. Skipped for a session `createAndAttach(_:)`
    // just created, which nothing can have attached yet; never skipped for a move here.
    let checkIndex =
      progress.detachesOtherClients
      ? attachCheckIndex ?? detachIndex
      : progress.checksExistingAttachments ? attachCheckIndex : nil
    if let checkIndex {
      switch await existingAttachments(of: session.key, host: host, index: checkIndex) {
      case .failure(let failure):
        return .failed(failure)
      case .success(let check):
        progress.existingAttachments = check.counts
        progress.timings.checked = clock.now() - progress.start
        if progress.detachesOtherClients {
          if let first = check.attachments.first {
            return .failed(
              .alreadyAttachedHere(
                connectionID: first.connectionID, owningSessionID: first.owningSessionID))
          }
          if check.unresolved > 0 {
            return .failed(.possiblyAttachedHere(unresolved: check.unresolved))
          }
        }
        if !check.attachments.isEmpty { return await focus(check.attachments, &progress) }
      }
    } // End of the existing-attachment check
    // 2. Write the request (asking for `attach-session -d` only for a move here).
    _ = try? store.sweep()
    var request = LaunchRequest(
      id: progress.launchID, createdAt: clock.date(), host: launchHost,
      tmuxPathOverride: target.host.tmuxPathOverride, session: session)
    if progress.detachesOtherClients { request.detachOtherClients = true }
    do throws(LaunchStoreError) {
      try store.writeRequest(request)
    } catch {
      return .failed(.launchStore(error))
    }
    guard !Task.isCancelled else { return withdraw(&progress, .cancelled) }
    // 3. iTerm2 must run.
    do {
      try await iTerm2.ensureRunning()
    } catch {
      return withdraw(&progress, Self.failure(for: error))
    }
    guard !Task.isCancelled else { return withdraw(&progress, .cancelled) }
    // 4. Open the launch tab (`LaunchTab`, shared with ssh setup). The request runs in a task
    // of its own, so cancelling the attach never leaves a tab whose session id is unknown.
    let tab = LaunchTab.request(
      commandLine: helperPath.attachCommandLine(for: progress.launchID),
      profileName: target.host.iTermProfileName)
    progress.tabRequested = true
    let gatewaySessionID: String
    switch await LaunchTab.open(tab, on: iTerm2) {
    case .failure(let error):
      return withdraw(&progress, Self.failure(for: error))
    case .success(let sessionID):
      gatewaySessionID = sessionID
    }
    // 5. Launched.
    let launchedAt = rememberLaunch(of: gatewaySessionID, launchID: progress.launchID)
    progress.gatewaySessionID = gatewaySessionID
    progress.timings.launched = clock.now() - progress.start
    publish(.launched(sessionID: gatewaySessionID), for: progress)
    // 6. Wait for the connection or the helper's result (a remote attach may report
    // `stillWaiting` on the way).
    let connectionID: String
    switch await waitForConnection(&progress, gatewaySessionID: gatewaySessionID) {
    case .success(let found): connectionID = found
    case .failure(let failure): return .failed(failure)
    }
    progress.connectionID = connectionID
    progress.timings.connected = clock.now() - progress.start
    // 7. Identity.
    if let failure = await checkIdentity(
      connectionID: connectionID, gatewaySessionID: gatewaySessionID, launchedAt: launchedAt,
      key: session.key, host: host)
    {
      return .failed(failure)
    }
    // 8. Confirmed.
    progress.timings.confirmed = clock.now() - progress.start
    publish(.confirmed(connectionID: connectionID), for: progress)
    // 9. Bring it forward, only while the launch tab still owns the connection.
    progress.activation = await activateFirstTab(of: connectionID, ownedBy: gatewaySessionID)
    progress.timings.activated = clock.now() - progress.start
    return .confirmed(connectionID: connectionID)
  } // End of func perform(_:)

  /// The launch host for `host`: local, or ssh with its destination once it passes
  /// `Validation.sshDestination(_:)` (PLAN.md D17); otherwise `invalidDestination`.
  static func launchHost(for host: HostConfig) -> Result<LaunchHost, AttachFailure> {
    switch host.mode {
    case .local:
      return .success(.local)
    case .ssh:
      do throws(ValidationError) {
        return .success(.ssh(destination: try Validation.sshDestination(host.sshDestination)))
      } catch {
        return .failure(.invalidDestination(error))
      }
    }
  } // End of func launchHost(for:)

  /// Step 1: discovers the host again and returns the session as it is now, if it is still the
  /// one `target` names, with the host as the attachment index matches it (`nil` when the
  /// discovery result carries no report).
  private func revalidate(
    _ target: AttachTarget
  ) async -> Result<(DiscoveredSession, AttachmentIndex.Host?), AttachFailure> {
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
        return .success((fresh, AttachmentIndex.Host(result)))
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

  /// What step 1b found for one session.
  private struct ExistingCheck {
    /// The index's counts.
    var counts = AttachmentSnapshot.Counts()
    /// The session's attachments, in listing order (none when it is not attached).
    var attachments: [AttachmentSnapshot.Attachment] = []
    /// How many unmapped connections cannot be ruled out as showing the session
    /// (`AttachmentSnapshot.unresolvedConnections(for:)`); only a move here acts on it.
    var unresolved = 0
  }

  /// Step 1b: asks `index` which sessions this Mac's iTerm2 shows and returns its counts, the
  /// attachments of `key` and how many connections cannot be ruled out as showing it. iTerm2
  /// not running means nothing is attached (empty counts); any other listing failure fails the
  /// attach, so a tab is never opened without knowing whether one exists. Unmapped connections
  /// do not block an attach; a move here refuses unresolved ones (`perform(_:)`).
  private func existingAttachments(
    of key: SessionKey,
    host: AttachmentIndex.Host?,
    index: AttachmentIndex
  ) async -> Result<ExistingCheck, AttachFailure> {
    // A `.ok` discovery result always carries its report; without one nothing could match.
    guard let host else { return .failure(.discoveryFailed("noReport")) }
    do {
      let snapshot = try await index.snapshot(of: [host])
      return .success(
        ExistingCheck(
          counts: snapshot.counts, attachments: snapshot.attachments(of: key),
          unresolved: snapshot.unresolvedConnections(for: key).count))
    } catch ITerm2Error.notRunning {
      return .success(ExistingCheck())
    } catch let error as ITerm2Error {
      return .failure(.attachmentCheckFailed(error))
    } catch {
      return .failure(.cancelled)
    }
  } // End of func existingAttachments(of:host:index:)

  /// Step 1b's focus: brings forward the first of `attachments` (the session's, in listing
  /// order) whose connection is still owned by the tab the index found it under, and ends
  /// `focused` on it, whatever the activation's outcome (no tab, or a refused `Activate`): the
  /// session is attached, so nothing is opened. An attachment whose connection closed, or whose
  /// short id now names another tab's connection, is skipped without activating anything; when
  /// that happened to every one, the attach fails with `attachmentChanged` and opens nothing,
  /// since the session may be attached again elsewhere. `focused` is published once the focus
  /// is decided, after the activation.
  private func focus(
    _ attachments: [AttachmentSnapshot.Attachment],
    _ progress: inout Run
  ) async -> AttachState {
    for attachment in attachments {
      let activation = await activateFirstTab(
        of: attachment.connectionID, ownedBy: attachment.owningSessionID)
      if activation == .failed(.tmuxConnectionNotOwned) { continue }
      progress.connectionID = attachment.connectionID
      progress.gatewaySessionID = attachment.owningSessionID
      progress.activation = activation
      progress.timings.confirmed = progress.timings.checked
      progress.timings.activated = clock.now() - progress.start
      publish(.focused(connectionID: attachment.connectionID), for: progress)
      return .focused(connectionID: attachment.connectionID)
    } // End of loop over the session's attachments
    return .failed(.attachmentChanged)
  } // End of func focus(_:_:)

  /// Step 6: polls the helper's result and iTerm2's tmux connections until the launch tab owns
  /// a connection, the helper reports how it ended, or the budget runs out (15 s locally).
  /// Every failure but a helper result withdraws the request.
  ///
  /// A remote attach has `remoteConfirmationBudget` (20 s, PLAN.md D17). Once that runs out,
  /// every round also asks whether the launch tab is still open, since it closes when its
  /// helper exits: when it is, the helper still runs (ssh waiting for a password or a host-key
  /// answer in the tab, for example), so the attach publishes `stillWaiting` once and goes on
  /// polling every `stillWaitingPollInterval`: a connection that appears later is confirmed as
  /// usual, a helper result fails the attach. A launch tab that closed can no longer attach;
  /// the helper's result (written before it exits) is waited for within
  /// `closedTabResultBudget`, and none is `timedOut`. After
  /// `remoteWaitLimit` from the start of this step the attach ends `waitLimitReached`.
  private func waitForConnection(
    _ progress: inout Run,
    gatewaySessionID: String
  ) async -> Result<String, AttachFailure> {
    let remote = progress.target.host.mode == .ssh
    let start = clock.now()
    let budget = remote ? configuration.remoteConfirmationBudget : configuration.confirmationBudget
    var waiting = false
    while true {
      do throws(LaunchStoreError) {
        if let result = try store.takeResult(progress.launchID) {
          progress.helperEnded = true
          return .failure(Self.failure(forHelperResult: result))
        }
      } catch {
        return .failure(withdrawFailure(&progress, .launchStore(error)))
      }
      do {
        let connections = try await iTerm2.listTmuxConnections()
        if let match = connections.first(where: { $0.owningSessionID == gatewaySessionID }),
          let connectionID = match.connectionID, !connectionID.isEmpty
        {
          return .success(connectionID)
        }
      } catch {
        return .failure(withdrawFailure(&progress, Self.failure(for: error)))
      }
      if waiting || clock.now() >= start + budget {
        guard remote else { return .failure(withdrawFailure(&progress, .timedOut)) }
        let tabOpen: Bool
        do {
          tabOpen = try await iTerm2.listSessions().allSessionIDs.contains(gatewaySessionID)
        } catch {
          return .failure(withdrawFailure(&progress, Self.failure(for: error)))
        }
        guard tabOpen else {
          // The tab is gone, so nothing can attach any more; the helper writes its result
          // before it exits, which may be some seconds after the tab left iTerm2's listing.
          guard
            let result = await waitForResult(
              progress.launchID, within: configuration.closedTabResultBudget)
          else {
            return .failure(withdrawFailure(&progress, .timedOut))
          }
          progress.helperEnded = true
          return .failure(Self.failure(forHelperResult: result))
        }
        if !waiting {
          waiting = true
          progress.timings.stillWaiting = clock.now() - progress.start
          publish(.stillWaiting(sessionID: gatewaySessionID), for: progress)
        } else if clock.now() >= start + configuration.remoteWaitLimit {
          return .failure(withdrawFailure(&progress, .waitLimitReached))
        }
      }
      do {
        try await clock.sleep(
          for: waiting ? configuration.stillWaitingPollInterval : configuration.pollInterval)
      } catch {
        return .failure(withdrawFailure(&progress, .cancelled))
      }
    } // End of loop polling for the connection
  } // End of func waitForConnection(_:gatewaySessionID:)

  /// The failure an attach reports for the helper's result before a connection was confirmed:
  /// its failure (D14), or `helperEnded` when tmux ended normally.
  static func failure(forHelperResult result: LaunchResult) -> AttachFailure {
    result.failure.map(AttachFailure.from) ?? .helperEnded
  }

  /// Step 7: asks tmux through the connection (still owned by the launch tab) which host, server
  /// and session it reached: the server and session must be `key`'s, and the host name the
  /// revalidated host's node name (`uname -n`) when discovery reported one, so an SSH
  /// destination that reached another Mac never confirms. A request failure is reported as is;
  /// an unreadable or different answer detaches the connection once the launch tab, opened at
  /// `launchedAt`, is old enough.
  private func checkIdentity(
    connectionID: String,
    gatewaySessionID: String,
    launchedAt: ContinuousClock.Instant,
    key: SessionKey,
    host: AttachmentIndex.Host?
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
      if reported.matches(key), host.map({ reported.host == $0.nodeName }) ?? true { return nil }
      failure = .identityMismatch
    } else {
      failure = .identityCheckFailed(nil)
    }
    await retire(
      connectionID: connectionID, gatewaySessionID: gatewaySessionID, launchedAt: launchedAt)
    return failure
  } // End of func checkIdentity(connectionID:gatewaySessionID:launchedAt:key:host:)

  /// Step 9 and the focus: waits (within the tab budget) for the first tab of the connection
  /// `connectionID` and activates it. Every attempt is bound to `owningSessionID`
  /// (`ITerm2Integration.activateFirstTab(ofTmuxConnection:ownedBy:options:)`), so once the
  /// connection closed or its short id names another tab's connection nothing is activated:
  /// `failed(tmuxConnectionNotOwned)`.
  private func activateFirstTab(
    of connectionID: String,
    ownedBy owningSessionID: String
  ) async -> ActivationOutcome {
    // iTerm2 3.7.6 answers INVALID_OPTION when a tab target comes with `select_session`; a tab
    // target with the app options in the same request is accepted.
    let options = ITerm2API.ActivateRequest(
      target: nil, orderWindowFront: true, selectTab: true, selectSession: false,
      activateApp: configuration.activatesApp ? .init(ignoringOtherApps: true) : nil)
    let deadline = clock.now() + configuration.tabBudget
    while true {
      do {
        if let tabID = try await iTerm2.activateFirstTab(
          ofTmuxConnection: connectionID, ownedBy: owningSessionID, options: options)
        {
          return .activated(tabID: tabID)
        }
      } catch {
        return .failed(error as? ITerm2Error ?? .disconnected)
      }
      guard clock.now() < deadline else { return .noTab }
      do {
        try await clock.sleep(for: configuration.pollInterval)
      } catch {
        return .noTab
      }
    } // End of loop waiting for the connection's first tab
  } // End of func activateFirstTab(of:ownedBy:)

  // MARK: - Show tab

  /// Brings forward the launch tab `sessionID` ("Show tab" next to "Still connecting — check
  /// the iTerm2 tab", PLAN.md D25), only when it is a launch tab this coordinator opened and
  /// still remembers: any other id (a tab of the user's, or one this coordinator forgot) is
  /// `notOpenedHere` and nothing is sent. The tab is activated by its iTerm2 session id with
  /// `select_session`, `select_tab` and `order_window_front` (the Python module's
  /// `Session.async_activate`) and the app options, once (D13). Session ids are UUIDs iTerm2
  /// never hands out again, unlike tmux connection ids, so no binding check is needed. A tab
  /// that closed meanwhile makes iTerm2 refuse (`failed`). Nothing is closed or typed.
  public func showLaunchTab(_ sessionID: String) async -> LaunchTabShowResult {
    guard !sessionID.isEmpty, launches[sessionID] != nil else { return .notOpenedHere }
    let request = ITerm2API.ActivateRequest(
      target: .session(sessionID), orderWindowFront: true, selectTab: true, selectSession: true,
      activateApp: configuration.activatesApp ? .init(ignoringOtherApps: true) : nil)
    let start = clock.now()
    let result: LaunchTabShowResult
    do {
      try await iTerm2.activate(request)
      result = .shown
    } catch let error as ITerm2Error {
      result = .failed(error)
    } catch {
      result = .failed(.disconnected)
    }
    var detail = "show launch tab: \(result.kind)"
    if case .failed(let error) = result { detail += " (\(error.kind))" }
    await diagnostics?.record(
      .attach, outcome: result == .shown ? .success : .failure,
      durationMs: Self.milliseconds(clock.now() - start), detail: detail)
    return result
  } // End of func showLaunchTab(_:)

  // MARK: - Detach

  /// Detaches the tmux connection `connectionID` of the launch tab `gatewaySessionID` with
  /// `detach-client` (never by closing its tabs), waits for the connection to disappear and,
  /// when `launchID` names the launch that created it, for the helper's result.
  ///
  /// It first waits until the launch tab is `Configuration.minimumLaunchTabAge` old: counted
  /// from when this coordinator opened it, or from the call for a tab it did not open (another
  /// process's, or one it no longer remembers): the caller saw the connection before calling,
  /// so the tab is at least that old once the time has passed. Cancelling the caller during
  /// that wait sends nothing (`cancelled`). The command is then sent only if
  /// iTerm2 still lists the connection as owned by `gatewaySessionID` (otherwise
  /// `commandError` is `tmuxConnectionNotOwned`), and only once (D13); when it certainly was
  /// not sent, nothing is waited for.
  public func detach(
    connectionID: String,
    gatewaySessionID: String,
    launchID: LaunchToken? = nil
  ) async -> DetachResult {
    var result = DetachResult(connectionID: connectionID, gatewaySessionID: gatewaySessionID)
    let start = clock.now()
    let remaining = remainingAge(of: gatewaySessionID, unknownSince: start)
    if remaining > .zero {
      do {
        try await clock.sleep(for: remaining)
      } catch {
        result.cancelled = true
        return await recordDetach(result, since: start)
      }
    }
    await sendDetach(&result, launchID: launchID)
    return await recordDetach(result, since: start)
  } // End of func detach(connectionID:gatewaySessionID:launchID:)

  /// Detaches every attachment of the session `key` in this Mac's iTerm2, whoever opened it
  /// (PLAN.md D16), with `detach-client` (never by closing tabs). The session may live on this
  /// Mac or on a remote host (D17): the index matches remote connections by the remote node
  /// name discovery reports.
  ///
  /// It discovers `host` (for its `uname -n` and current server), asks the attachment index
  /// which connections show `key`, then handles them one at a time, earliest first. Each one
  /// waits until its owning tab is `Configuration.minimumLaunchTabAge` old (from when this
  /// coordinator opened it; for a tab it did not open, from when the index's snapshot that
  /// revealed the connection completed, since a tab opened during discovery or the listing did
  /// not exist at the call, D15), checks right
  /// then, through the binding rule, that the connection still shows `key` (another session or
  /// server: `identityChanged`, nothing sent), and sends `detach-client` bound to the owning
  /// session from the index's listing, once (D13). It then waits for the connection to close,
  /// and for the helper's result when this coordinator launched it.
  ///
  /// Cancelling the caller during a wait sends nothing more (`cancelled`). No server, iTerm2
  /// not running, or no connection showing the session is `nothingAttached`, with nothing
  /// sent. An SSH host whose destination is not valid is `checkFailed` (`invalidDestination`).
  public func detach(session key: SessionKey, on host: HostConfig) async -> SessionDetachResult {
    let start = clock.now()
    let outcome = await detachAttachments(of: key, on: host)
    var detail = "detach session: \(outcome.outcome.rawValue)"
    if !outcome.detaches.isEmpty { detail += ", \(outcome.detaches.count) attachment(s)" }
    if let failure = outcome.checkFailure { detail += " (\(failure.kind))" }
    await diagnostics?.record(
      .attach,
      outcome: outcome.outcome == .detached || outcome.outcome == .nothingAttached
        ? .success : .failure,
      hostID: host.id.uuidString, durationMs: Self.milliseconds(clock.now() - start),
      detail: detail)
    return outcome
  } // End of func detach(session:on:)

  /// The work of `detach(session:on:)`, without the diagnostics record.
  private func detachAttachments(
    of key: SessionKey,
    on host: HostConfig
  ) async -> SessionDetachResult {
    if case .failure(let failure) = Self.launchHost(for: host) {
      return SessionDetachResult(key: key, outcome: .checkFailed, checkFailure: failure)
    }
    let indexHost: AttachmentIndex.Host
    switch await currentHost(host) {
    case .success(let found?): indexHost = found
    case .success(nil): return SessionDetachResult(key: key, outcome: .nothingAttached)
    case .failure(.cancelled): return SessionDetachResult(key: key, outcome: .cancelled)
    case .failure(let failure):
      return SessionDetachResult(key: key, outcome: .checkFailed, checkFailure: failure)
    }
    let snapshot: AttachmentSnapshot
    do {
      snapshot = try await detachIndex.snapshot(of: [indexHost])
    } catch ITerm2Error.notRunning {
      return SessionDetachResult(key: key, outcome: .nothingAttached)
    } catch let error as ITerm2Error {
      return SessionDetachResult(
        key: key, outcome: .checkFailed, checkFailure: .attachmentCheckFailed(error))
    } catch {
      return SessionDetachResult(key: key, outcome: .cancelled)
    }
    let counts = snapshot.counts
    // Each tab's end may come only once it is old enough: counted from its opening for launch
    // tabs this coordinator opened, and for any other tab from now, when the snapshot that
    // revealed its connection has completed (the tab may have opened during discovery or the
    // listing, so the call's start is too early). Earliest first; equal times keep the listing
    // order.
    let observedAt = clock.now()
    let planned = snapshot.attachments(of: key).enumerated().map { offset, attachment in
      let opened = launches[attachment.owningSessionID]?.openedAt ?? observedAt
      return (offset, attachment, opened + configuration.minimumLaunchTabAge)
    }.sorted { ($0.2, $0.0) < ($1.2, $1.0) }.map { ($0.1, $0.2) }
    guard !planned.isEmpty else {
      return SessionDetachResult(key: key, outcome: .nothingAttached, counts: counts)
    }
    var detaches: [DetachResult] = []
    var cancelled = false
    for (attachment, notBefore) in planned {
      var one = DetachResult(
        connectionID: attachment.connectionID, gatewaySessionID: attachment.owningSessionID)
      if !cancelled {
        cancelled = !(await detachOne(&one, key: key, host: indexHost, notBefore: notBefore))
      } else {
        one.cancelled = true
      }
      detaches.append(one)
    } // End of loop over the session's attachments
    let outcome: SessionDetachResult.Outcome
    if detaches.contains(where: \.cancelled) {
      outcome = .cancelled
    } else if detaches.contains(where: \.certainlyNotSent) {
      outcome = .notSent
    } else if detaches.contains(where: { !$0.connectionClosed }) {
      outcome = .notClosed
    } else {
      outcome = .detached
    }
    return SessionDetachResult(key: key, outcome: outcome, detaches: detaches, counts: counts)
  } // End of func detachAttachments(of:on:)

  /// Discovers `host` and returns it as the attachment index matches it; `nil` when no server
  /// runs (then nothing can be attached).
  private func currentHost(_ host: HostConfig) async -> Result<AttachmentIndex.Host?, AttachFailure>
  {
    let result: DiscoveryResult
    do {
      result = try await discovery.discover(host)
    } catch {
      return .failure(.cancelled)
    }
    switch result.status {
    case .ok:
      guard let found = AttachmentIndex.Host(result) else {
        return .failure(.discoveryFailed("noReport"))
      }
      return .success(found)
    case .noServer:
      return .success(nil)
    case .tmuxNotFound:
      return .failure(.tmuxMissing)
    default:
      return .failure(.discoveryFailed(result.status.kind))
    }
  } // End of func currentHost(_:)

  /// One attachment of `detach(session:on:)`: waits until `notBefore`, checks the connection
  /// still shows `key`, then sends `detach-client` and waits for the close. Returns `false` when
  /// the caller was cancelled before anything was sent (`result.cancelled` is set).
  private func detachOne(
    _ result: inout DetachResult,
    key: SessionKey,
    host: AttachmentIndex.Host,
    notBefore: ContinuousClock.Instant
  ) async -> Bool {
    let owner = result.gatewaySessionID ?? ""
    let remaining = notBefore - clock.now()
    if remaining > .zero {
      do {
        try await clock.sleep(for: remaining)
      } catch {
        result.cancelled = true
        return false
      }
    }
    do {
      switch try await detachIndex.identify(
        connectionID: result.connectionID, owningSessionID: owner)
      {
      case .reported(let reported):
        guard AttachmentIndex.map(reported, among: [host]) == .mapped(key) else {
          result.identityChanged = true
          return true
        }
      case .nonUTF8:
        result.identityChanged = true
        return true
      case .stale(let reason):
        result.identityCheckFailure = reason
        return true
      }
    } catch {
      result.cancelled = true
      return false
    }
    await sendDetach(&result, launchID: launches[owner]?.launchID)
    return true
  } // End of func detachOne(_:key:host:notBefore:)

  /// Sends `detach-client` on `result`'s connection, bound to its owning session, once (D13),
  /// then waits (within the detach budget) for the connection to close and, given `launchID`,
  /// for the helper's result. A command that certainly was not sent is not waited for.
  private func sendDetach(_ result: inout DetachResult, launchID: LaunchToken?) async {
    let connectionID = result.connectionID
    let gatewaySessionID = result.gatewaySessionID ?? ""
    do {
      _ = try await iTerm2.sendTmuxCommand(
        ConnectionIdentity.detachCommand, connectionID: connectionID, ownedBy: gatewaySessionID)
    } catch let error as ITerm2Error {
      result.commandError = error
      if error.isNotSent { return }
    } catch {
      result.commandError = .disconnected
    }
    let deadline = clock.now() + configuration.detachBudget
    while !result.connectionClosed {
      do {
        let connections = try await iTerm2.listTmuxConnections()
        result.connectionClosed = !connections.contains {
          $0.connectionID == connectionID && $0.owningSessionID == gatewaySessionID
        }
      } catch {
        result.pollError = error as? ITerm2Error ?? .disconnected
        break
      }
      if result.connectionClosed { break }
      guard clock.now() < deadline else { break }
      guard (try? await clock.sleep(for: configuration.pollInterval)) != nil else { break }
    } // End of loop waiting for the connection to close
    if result.connectionClosed {
      launches[gatewaySessionID] = nil
      if let launchID {
        result.helperResult = await waitForResult(launchID, within: configuration.resultBudget)
      }
    }
  } // End of func sendDetach(_:launchID:)

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

  /// Waits (within `budget`) for the helper's result of `launchID`.
  private func waitForResult(_ launchID: LaunchToken, within budget: Duration) async
    -> LaunchResult?
  {
    let deadline = clock.now() + budget
    while true {
      if let result = try? store.takeResult(launchID) { return result }
      guard clock.now() < deadline,
        (try? await clock.sleep(for: configuration.pollInterval)) != nil
      else { return nil }
    }
  }

  /// After a failed identity check: sends `detach-client` once (ignoring the outcome) when the
  /// launch tab, opened at `launchedAt` (the `CreateTab` answer, so it does not depend on the
  /// coordinator still remembering the launch), is old enough. The wait and the command run in
  /// a task of their own that the attach waits for, so cancelling the attach can neither skip
  /// the wait nor end the tab early; if the wait fails anyway, nothing is sent.
  private func retire(
    connectionID: String,
    gatewaySessionID: String,
    launchedAt: ContinuousClock.Instant
  ) async {
    let remaining = launchedAt + configuration.minimumLaunchTabAge - clock.now()
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
  } // End of func retire(connectionID:gatewaySessionID:launchedAt:)

  /// How long until the launch tab `gatewaySessionID` is `minimumLaunchTabAge` old: counted
  /// from when this coordinator opened it, or, for a tab it did not open or no longer
  /// remembers, from `observedAt`, a moment the tab is known to have existed by (it is then at
  /// least that old once the time has passed).
  private func remainingAge(
    of gatewaySessionID: String,
    unknownSince observedAt: ContinuousClock.Instant
  ) -> Duration {
    let opened = launches[gatewaySessionID]?.openedAt ?? observedAt
    return opened + configuration.minimumLaunchTabAge - clock.now()
  }

  /// Remembers when the launch tab `gatewaySessionID` was reported open (now, which it
  /// returns) and which launch runs in it, forgetting the oldest one beyond
  /// `rememberedLaunches`.
  private func rememberLaunch(
    of gatewaySessionID: String,
    launchID: LaunchToken
  ) -> ContinuousClock.Instant {
    let openedAt = clock.now()
    launches[gatewaySessionID] = Launch(openedAt: openedAt, launchID: launchID)
    if launches.count > Self.rememberedLaunches,
      let oldest = launches.min(by: { $0.value.openedAt < $1.value.openedAt })?.key
    {
      launches[oldest] = nil
    }
    return openedAt
  } // End of func rememberLaunch(of:launchID:)

  // MARK: - Helpers

  /// Withdraws the request (so a launch tab that starts late cannot attach) and returns the
  /// failed state.
  private func withdraw(_ progress: inout Run, _ failure: AttachFailure) -> AttachState {
    .failed(withdrawFailure(&progress, failure))
  }

  /// Withdraws the request, noting in `progress` whether that removed it before a helper took
  /// it, and returns `failure`.
  private func withdrawFailure(_ progress: inout Run, _ failure: AttachFailure) -> AttachFailure {
    if (try? store.discardRequest(progress.launchID)) == true { progress.requestWithdrawn = true }
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

  /// Records the outcome of an attach or a move here (`detachesOtherClients`): its state and
  /// failure kinds and its duration only.
  private func record(_ result: AttachResult, hostID: UUID, detachesOtherClients: Bool) async {
    guard let diagnostics else { return }
    let duration = Self.milliseconds(result.timings.finished ?? .zero)
    let operation = detachesOtherClients ? "move here" : "attach"
    if let failure = result.failure {
      let detail = failure.detail.map { " (\($0))" } ?? ""
      await diagnostics.record(
        .attach, outcome: failure == .timedOut ? .timedOut : .failure,
        hostID: hostID.uuidString, durationMs: duration,
        detail: "\(operation) failed: \(failure.kind)\(detail)")
    } else {
      await diagnostics.record(
        .attach, outcome: .success, hostID: hostID.uuidString, durationMs: duration,
        detail: result.isFocused
          ? "\(operation) focused an existing attachment" : "\(operation) confirmed")
    }
  } // End of func record(_:hostID:detachesOtherClients:)

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
