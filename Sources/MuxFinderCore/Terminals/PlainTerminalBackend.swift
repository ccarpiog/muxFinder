import Foundation

/// The plain backend of the terminal seam (PLAN.md D38, Phase I-12c1; requirements 5 and 6 of
/// `autoclaude/processed/110-other-terminal-apps.md`): attaches tmux sessions in one terminal
/// app other than iTerm2 (Terminal, Ghostty or a user definition) with a plain tmux client, one
/// backend per loaded definition. Nothing in the app, the self-tests, the probe or the refresh
/// engine calls it yet (I-12c3 moves them onto the seam).
///
/// One attach runs, in D15's order where it applies:
/// 1. Revalidate the session through discovery (`AttachSharedSteps.revalidate`, the
///    coordinator's step and failures; an SSH host's destination validated first).
/// 2. The existing-attachment check is the backend's own record of the session (it opened and
///    confirmed it, in memory only): while its client still holds the session (no helper result
///    yet, and the read-only bound check `PlainClientPresence` answers present), the attach
///    brings its window forward and ends `plainFocused`, opening nothing; a stale record is
///    dropped; a check that cannot run fails the attach (`clientCheckFailed`), opening nothing.
///    A move here with a live record runs nothing (`alreadyOpenInTerminal`).
///    Then, for an attach on This Mac with a local client attributor (Phase I-12c2), open on
///    this Mac: process ancestry is read once for the revalidated session's clients
///    (`LocalClientAttributing`, no D16 index, so iTerm2's control-mode clients count too);
///    when one descends from a terminal app, that running app is brought forward
///    (`TerminalAppActivating`, never a launch or an Apple event) and the attach ends
///    `appFocused(app)` with the activation's outcome, opening nothing, as D16 never opens a
///    duplicate. Unmapped clients and a table that cannot be read never block the attach. A
///    move here and a create-and-attach skip it.
/// 3. Write a plain request (`terminal` the definition's id, `keepsMinimumLifetime` the
///    definition's, the session's four identity values, `detachOtherClients` only for a move
///    here).
/// 4. Open a window through the window layer running `<helper> attach-plain <launch id>`; a
///    typed open failure ends the attach `terminalWindow(error)`, the request withdrawn,
///    nothing retried (D13). The state becomes `plainLaunched(window)`.
/// 5. Confirm, only from evidence (requirement 5): poll the helper's result (`peekResult`, a
///    result first ends the attach with the coordinator's mapping) and its early report
///    (`peekReport`, never taken; malformed or oversized is `launchStore`, never a
///    confirmation). The first report read is kept for the whole wait, its file swept or not;
///    a later file that differs from it is `launchStore(fileMalformed)`. A reading that
///    confirms counts only if the helper's result still does not exist once it returns (else
///    the result's mapping). On This Mac, once the report exists, `list-clients` must show
///    exactly one client of the session on the report's terminal whose pid is the report's
///    attach child, still running with the report's kernel start time; a report without a
///    terminal never confirms (`cannotConfirmHere`). On an SSH host,
///    `PlainClientIdentification.remoteScript` over discovery's noninteractive ssh must find
///    exactly one client whose parent shell's arguments end with the launch token. No
///    candidate is "not yet"; two never confirm. Within the coordinator's budgets (15 s locally, else `timedOut`; 20 s remotely, then
///    `plainStillWaiting(window)` once, never a success, watching on until the wait limit).
/// 6. Record the attachment (window, client, launch) and publish `plainConfirmed(client)`.
/// 7. Bring the window forward once by the definition's focus kind; its outcome goes into the
///    result and never fails the attach. No bury, no `Disinter`, nothing restored, and the
///    backend never closes a window by itself.
///
/// Concurrent attaches (or moves here) of one session coalesce into one launch; a call never
/// joins a launch of the other kind, and never starts while an earlier launch of the session
/// may still attach it (one whose window opened and whose helper may have taken the request,
/// with neither a confirmed client nor its result seen): it waits for that launch's result
/// within the confirmation budget, then fails `earlierLaunchPending`, as the coordinator does.
/// Unlike the coordinator, an attach also waits out an earlier attach, since the plain backend
/// has no attachment index that would find what a late helper attached.
///
/// Detach and move here go through tmux only, with D38's bound commands (see
/// `PlainTerminalBackendDetach.swift`): never by closing a window.
///
/// Diagnostics record step outcomes, kinds and durations only: no paths, names or terminal
/// content.
public actor PlainTerminalBackend: TerminalBackend {
  /// `.plain(definitionID:)` of the loaded definition.
  public nonisolated let terminal: LaunchTerminalApp
  /// The loaded definition every window of this backend is opened and focused with.
  public nonisolated let loaded: LoadedTerminalDefinition
  /// Opens and focuses windows (main actor).
  let windows: any PlainTerminalWindowLayer
  /// The helper the windows run.
  let helperPath: LaunchHelperPath
  /// Request, report and result files.
  let store: any PlainLaunchRequestStore
  /// Revalidation and the current session by name.
  let discovery: any HostDiscovering
  /// Creates sessions for `createAndAttach(_:onCreated:)`.
  let sessionCreator: any SessionCreating
  /// The readings and bound commands, locally or over ssh.
  let tmux: PlainTmuxCommands
  /// Budgets, polling and timestamps.
  let clock: any AttachClock
  /// The coordinator's budgets (confirmation, remote budget and wait limit, poll intervals,
  /// the result budget and the 10 s minimum age of D37's age guard).
  let configuration: AttachCoordinator.Configuration
  /// The kernel start time of a process (the local attach child), `nil` when it is gone.
  let processStartTime: @Sendable (Int32) -> ProcessStartTime?
  /// Where outcomes are recorded, if anywhere.
  let diagnostics: DiagnosticsLog?
  /// Traces This Mac's clients to terminal apps (open on this Mac, Phase I-12c2); `nil` skips
  /// that check, as before it.
  let localClients: (any LocalClientAttributing)?
  /// Brings an app forward (open on this Mac, `.app` handles); `nil` uses
  /// `RunningApplicationActivator`.
  let appActivator: (any TerminalAppActivating)?
  /// The state observer.
  private let onUpdate: AttachCoordinator.UpdateHandler?

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
    /// Whether it is a move here; only callers of the same kind join it.
    let detachesOtherClients: Bool

    /// Whether callers still wait for it.
    var isLive: Bool { cancelledWaiters < waiters }
  }

  /// A launch that may still attach its session (PLAN.md D21): its run goes on, or it ended
  /// without its client confirmed, its helper's result seen or its request withdrawn.
  private struct PendingLaunch {
    /// The flight that runs (or ran) it.
    let flightID: UInt64
    /// Its launch id.
    let launchID: LaunchToken
    /// Whether its request asks for `attach-session -d`.
    let detachesOtherClients: Bool
    /// Whether its host is reached with ssh (it then gets the remote confirmation budget).
    let remote: Bool
    /// Whether its run goes on.
    var running = true
  }

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
  /// The attachments this backend opened and confirmed, by session (memory only).
  var attachments: [SessionKey: PlainAttachment] = [:]

  /// A backend for `loaded`'s terminal app. `windows` opens and focuses its windows, `store`
  /// holds the launch files, `discovery` revalidates, `tmux` runs the readings and bound
  /// commands, `sessionCreator` creates sessions, `localClients` traces This Mac's clients to
  /// terminal apps (`nil`: no open-on-this-Mac check) and `appActivator` brings such an app
  /// forward; tests pass fakes for each, a manual clock and a start-time reader of their own.
  public init(
    loaded: LoadedTerminalDefinition,
    windows: any PlainTerminalWindowLayer,
    helperPath: LaunchHelperPath,
    store: any PlainLaunchRequestStore,
    discovery: any HostDiscovering,
    tmux: PlainTmuxCommands = PlainTmuxCommands(),
    sessionCreator: any SessionCreating = TmuxCommands(),
    clock: any AttachClock = SystemAttachClock(),
    configuration: AttachCoordinator.Configuration = AttachCoordinator.Configuration(),
    processStartTime: @escaping @Sendable (Int32) -> ProcessStartTime? = {
      ProcessStartTime.of($0)
    },
    diagnostics: DiagnosticsLog? = nil,
    localClients: (any LocalClientAttributing)? = nil,
    appActivator: (any TerminalAppActivating)? = nil,
    onUpdate: AttachCoordinator.UpdateHandler? = nil
  ) {
    self.loaded = loaded
    terminal = .plain(definitionID: loaded.definition.id)
    self.windows = windows
    self.helperPath = helperPath
    self.store = store
    self.discovery = discovery
    self.tmux = tmux
    self.sessionCreator = sessionCreator
    self.clock = clock
    self.configuration = configuration
    self.processStartTime = processStartTime
    self.diagnostics = diagnostics
    self.localClients = localClients
    self.appActivator = appActivator
    self.onUpdate = onUpdate
  } // End of init(loaded:windows:helperPath:store:discovery:tmux:sessionCreator:clock:…)

  /// The latest state of `key`'s most recent attach, or `nil` if it was never attached.
  public func state(of key: SessionKey) -> AttachState? {
    states[key]
  }

  /// The backend's attachment of `key`, if it holds one (memory only).
  public func attachment(of key: SessionKey) -> PlainAttachment? {
    attachments[key]
  }

  /// How many callers wait for the launch in progress for `key` (0 when none runs). For tests.
  func waiterCount(for key: SessionKey) -> Int {
    flights[key]?.waiters ?? 0
  }

  /// How many launches of `key` ended but may still attach it (PLAN.md D21). For tests.
  func unsettledLaunchCount(for key: SessionKey) -> Int {
    pendingLaunches[key]?.filter { !$0.running }.count ?? 0
  }

  // MARK: - Operations

  /// Attaches `target`'s session in a new window of the backend's terminal app and returns how
  /// it ended: `plainConfirmed`, `plainFocused` (the backend's own attachment still held it, so
  /// its window was brought forward), `appFocused` (a client of the session on This Mac runs
  /// in that app, which was brought forward) or `failed`.
  public func attach(_ target: AttachTarget) async -> AttachResult {
    await attach(target, checksExistingAttachment: true, detachesOtherClients: false)
  }

  /// Moves `target`'s session here (PLAN.md D21, D38): the attach above, with the request
  /// asking the helper for the bound `attach-session -d`. Only with `confirmation` naming the
  /// session (else `moveHereNotConfirmed`, nothing run); with the backend's own attachment of
  /// the session still live it runs nothing (`alreadyOpenInTerminal`).
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
    return await attach(target, checksExistingAttachment: true, detachesOtherClients: true)
  } // End of func moveHere(_:confirmation:)

  /// Creates the session `request` describes (D18's creation, `AttachSharedSteps`), then
  /// attaches it as `attach(_:)` does, without the existing-attachment check (a session
  /// created a moment ago has no attachment yet). A failed creation opens nothing.
  public func createAndAttach(
    _ request: NewSessionRequest,
    onCreated: (@Sendable (CreatedSession) -> Void)?
  ) async -> CreateAndAttachResult {
    let created: CreatedSession
    switch await AttachSharedSteps.createSession(
      request, creator: sessionCreator, clock: clock, diagnostics: diagnostics,
      onCreated: onCreated)
    {
    case .success(let session): created = session
    case .failure(let error): return CreateAndAttachResult(creationFailure: error)
    }
    let result = await attach(
      created.attachTarget(on: request.host), checksExistingAttachment: false,
      detachesOtherClients: false)
    return CreateAndAttachResult(created: created, attach: result)
  } // End of func createAndAttach(_:onCreated:)

  /// The session named exactly `name` on `host` as discovery reports it now
  /// (`AttachSharedSteps.currentSession`, as the coordinator). Read-only.
  public func currentSession(
    named name: String,
    on host: HostConfig
  ) async -> Result<AttachTarget, AttachFailure> {
    await AttachSharedSteps.currentSession(named: name, on: host, discovery: discovery)
  }

  /// A plain window through the window layer with this backend's loaded definition (the layer
  /// refuses another definition's window with nothing sent); an iTerm2 launch tab is
  /// `handleOfAnotherTerminal`, nothing run; an app is activated (`appActivation`), nothing
  /// launched.
  public func focus(_ handle: TerminalAttachmentHandle) async -> TerminalFocusResult {
    switch handle {
    case .iTerm2LaunchTab:
      return .handleOfAnotherTerminal
    case .plainWindow(let window):
      return await focusWindow(window)
    case .app(let app):
      return .appActivation(await RunningApplicationActivator.activate(app, with: appActivator))
    }
  }

  // MARK: - Attach

  /// `attach(_:)`, `moveHere(_:confirmation:)` and `createAndAttach(_:onCreated:)`: the record
  /// check runs when `checksExistingAttachment` is set, and always for a move here. A caller
  /// joins a live launch of the same kind; every earlier launch that may still attach the
  /// session is waited out first, within the confirmation budget (`earlierLaunchPending`).
  private func attach(
    _ target: AttachTarget,
    checksExistingAttachment: Bool,
    detachesOtherClients: Bool
  ) async -> AttachResult {
    let key = target.key
    pruneEndedAttachments()
    var unsettledSince: [UInt64: ContinuousClock.Instant] = [:]
    while true {
      let conflicting = conflictingLaunches(of: key, detachesOtherClients: detachesOtherClients)
      if conflicting.isEmpty { break }
      let ended = conflicting.filter { !$0.running }
      if !ended.isEmpty {
        for launch in ended where unsettledSince[launch.flightID] == nil {
          unsettledSince[launch.flightID] = clock.now()
        }
        if settle(ended.map(\.flightID), of: key) { continue }
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
    } // End of loop waiting out earlier launches
    let flight: Flight
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
          checksExistingAttachment: checksExistingAttachment,
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
  } // End of func attach(_:checksExistingAttachment:detachesOtherClients:)

  /// Counts a cancelled caller and cancels the launch once every caller was cancelled.
  private func waiterCancelled(key: SessionKey, flightID: UInt64) {
    guard var flight = flights[key], flight.id == flightID else { return }
    flight.cancelledWaiters += 1
    flights[key] = flight
    if flight.cancelledWaiters >= flight.waiters { flight.task.cancel() }
  }

  /// The launches of `key` a new caller must wait out before it joins or starts one: none when
  /// a live launch of its own kind runs (it joins it); otherwise every launch that may still
  /// attach the session, of either kind (the plain backend has no attachment index that would
  /// find what a late helper attached, so an attach waits out an earlier attach too).
  private func conflictingLaunches(
    of key: SessionKey,
    detachesOtherClients: Bool
  ) -> [PendingLaunch] {
    if let current = flights[key], current.isLive,
      current.detachesOtherClients == detachesOtherClients
    {
      return []
    }
    return pendingLaunches[key] ?? []
  } // End of func conflictingLaunches(of:detachesOtherClients:)

  /// Forgets every ended launch among `flightIDs` of `key` whose helper's result exists (its
  /// helper ended, so it can no longer attach; peeked, never taken), and returns whether any
  /// was.
  private func settle(_ flightIDs: [UInt64], of key: SessionKey) -> Bool {
    var pending = pendingLaunches[key] ?? []
    let before = pending.count
    pending.removeAll { launch in
      !launch.running && flightIDs.contains(launch.flightID)
        && (try? store.peekResult(launch.launchID)) != nil
    }
    pendingLaunches[key] = pending.isEmpty ? nil : pending
    return pending.count < before
  } // End of func settle(_:of:)

  /// Ends a call that started no launch with `failure`: records it and returns its result, with
  /// a launch id nothing used and no state published.
  private func refuseBeforeLaunch(
    _ target: AttachTarget,
    _ failure: AttachFailure,
    detachesOtherClients: Bool
  ) async -> AttachResult {
    let result = AttachResult(key: target.key, launchID: LaunchToken(), state: .failed(failure))
    await record(result, hostID: target.host.id, detachesOtherClients: detachesOtherClients)
    return result
  }

  /// The confirmation budget: the remote one for a host reached with ssh, else the local one.
  private func confirmationBudget(remote: Bool) -> Duration {
    remote ? configuration.remoteConfirmationBudget : configuration.confirmationBudget
  }

  /// Records how the launch of `progress` ended: kept as ended while it may still attach,
  /// otherwise forgotten.
  private func endLaunch(_ progress: Run) {
    let key = progress.target.key
    guard var pending = pendingLaunches[key],
      let index = pending.firstIndex(where: { $0.flightID == progress.flightID })
    else { return }
    if progress.mayStillAttach {
      pending[index].running = false
    } else {
      pending.remove(at: index)
    }
    pendingLaunches[key] = pending.isEmpty ? nil : pending
  } // End of func endLaunch(_:)

  /// The progress of one launch, collected into its result.
  private struct Run {
    /// The target.
    let target: AttachTarget
    /// The launch id (request file name and the helper's argument; remotely the token).
    let launchID: LaunchToken
    /// The flight running the launch.
    let flightID: UInt64
    /// When the attach started.
    let start: ContinuousClock.Instant
    /// Whether the record check runs.
    let checksExistingAttachment: Bool
    /// Whether this is a move here.
    let detachesOtherClients: Bool
    /// The window, once opened (or the existing attachment's, for a focus).
    var window: PlainTerminalWindow?
    /// The client, once confirmed (or the existing attachment's, for a focus).
    var client: PlainClientRecord?
    /// How the focus of the window went.
    var windowFocus: TerminalFocusResult?
    /// The client on This Mac traced to an app, for an `appFocused` attach.
    var localAttachment: LocalAttachment?
    /// How bringing that app forward went.
    var appActivation: TerminalAppActivation?
    /// Step timings.
    var timings = AttachTimings()
    /// Whether the window was asked for, so a helper may run with this launch's id.
    var windowRequested = false
    /// Whether the request was withdrawn before a helper took it.
    var requestWithdrawn = false
    /// Whether the helper's result was seen: the helper ended.
    var helperEnded = false

    /// Whether the launch may still attach the session after its run ended.
    var mayStillAttach: Bool {
      windowRequested && client == nil && !helperEnded && !requestWithdrawn
    }
  } // End of struct Run

  /// Runs one launch (the flight's task), publishes its states and removes the flight.
  private func run(
    _ target: AttachTarget,
    launchID: LaunchToken,
    flightID: UInt64,
    checksExistingAttachment: Bool,
    detachesOtherClients: Bool
  ) async -> AttachResult {
    var progress = Run(
      target: target, launchID: launchID, flightID: flightID, start: clock.now(),
      checksExistingAttachment: checksExistingAttachment,
      detachesOtherClients: detachesOtherClients)
    publish(.requested, for: progress)
    let finalState = await perform(&progress)
    progress.timings.finished = clock.now() - progress.start
    if case .failed = finalState { publish(finalState, for: progress) }
    if flights[target.key]?.id == flightID { flights[target.key] = nil }
    endLaunch(progress)
    let result = AttachResult(
      key: target.key, launchID: launchID, state: finalState, timings: progress.timings,
      plainWindow: progress.window, plainClient: progress.client,
      plainWindowFocus: progress.windowFocus, localAttachment: progress.localAttachment,
      appActivation: progress.appActivation)
    await record(result, hostID: target.host.id, detachesOtherClients: detachesOtherClients)
    return result
  } // End of func run(_:launchID:flightID:checksExistingAttachment:detachesOtherClients:)

  /// Steps 1–7. Returns the final state (`plainConfirmed`, `plainFocused`, `appFocused` or
  /// `failed`); `plainLaunched`, `plainStillWaiting`, `plainConfirmed`, `plainFocused` and
  /// `appFocused` are published on the way (a failure is published by the caller).
  private func perform(_ progress: inout Run) async -> AttachState {
    let target = progress.target
    let launchHost: LaunchHost
    switch AttachCoordinator.launchHost(for: target.host) {
    case .success(let value): launchHost = value
    case .failure(let failure): return .failed(failure)
    }
    // 1. Revalidate.
    let session: DiscoveredSession
    switch await AttachSharedSteps.revalidate(target, discovery: discovery) {
    case .success(let fresh): session = fresh.0
    case .failure(let failure): return .failed(failure)
    }
    progress.timings.revalidated = clock.now() - progress.start
    // 2. The backend's own attachment: focus it while its client holds the session; a move
    // here runs nothing then (`-d` would detach it too).
    if progress.checksExistingAttachment || progress.detachesOtherClients,
      let attachment = attachments[target.key]
    {
      switch await isLive(attachment, key: target.key) {
      case .failure(let failure):
        return .failed(failure)
      case .success(let live):
        progress.timings.checked = clock.now() - progress.start
        if live {
          if progress.detachesOtherClients {
            return .failed(.alreadyOpenInTerminal(window: attachment.window))
          }
          return await focusExisting(attachment, &progress)
        }
      }
    } // End of the existing-attachment check
    // 2b. Open on this Mac: a client of the session traced to a terminal app (one reading of
    // the process table; unmapped clients never block). Not for a move here (it attaches with
    // `-d` whatever is attached) or a session created a moment ago.
    if progress.checksExistingAttachment, !progress.detachesOtherClients,
      target.host.mode == .local, let localClients
    {
      let found = await Self.localAttachments(of: session, on: target.host, with: localClients)
      progress.timings.checked = clock.now() - progress.start
      if let first = found.first { return await focusApp(first, &progress) }
    }
    // 3. Write the plain request.
    _ = try? store.sweep()
    var request = LaunchRequest(
      id: progress.launchID, createdAt: clock.date(), host: launchHost,
      tmuxPathOverride: target.host.tmuxPathOverride, session: session)
    request.terminal = terminal
    request.keepsMinimumLifetime = loaded.definition.keepsMinimumLifetime
    if progress.detachesOtherClients { request.detachOtherClients = true }
    do throws(LaunchStoreError) {
      try store.writeRequest(request)
    } catch {
      return .failed(.launchStore(error))
    }
    guard !Task.isCancelled else { return withdraw(&progress, .cancelled) }
    // 4. Open the window.
    progress.windowRequested = true
    let window: PlainTerminalWindow
    switch await openWindow(token: progress.launchID) {
    case .failure(let error): return withdraw(&progress, .terminalWindow(error))
    case .success(let opened): window = opened
    }
    progress.window = window
    progress.timings.launched = clock.now() - progress.start
    publish(.plainLaunched(window: window), for: progress)
    // 5. Confirm from evidence only.
    let commandTarget = PlainTmuxCommands.Target(
      host: launchHost, tmuxPathOverride: target.host.tmuxPathOverride)
    let confirmed: (client: OtherClient, report: PlainLaunchReport)
    switch await waitForClient(&progress, session: session, at: commandTarget) {
    case .success(let found): confirmed = found
    case .failure(let failure): return .failed(failure)
    }
    // 6. Record the attachment.
    let client = PlainClientRecord(
      session: PlainClientRecord.identity(of: session), client: confirmed.client,
      launchID: progress.launchID, token: launchHost.isRemote ? progress.launchID : nil,
      terminalPath: launchHost.isRemote ? nil : confirmed.report.terminalPath)
    attachments[target.key] = PlainAttachment(
      loaded: loaded, window: window, client: client, target: commandTarget)
    progress.client = client
    progress.timings.confirmed = clock.now() - progress.start
    publish(.plainConfirmed(client: client), for: progress)
    // 7. Bring the window forward once.
    progress.windowFocus = await focusWindow(window)
    progress.timings.activated = clock.now() - progress.start
    return .plainConfirmed(client: client)
  } // End of func perform(_:)

  /// Step 2's focus: brings the attachment's window forward and ends `plainFocused`, whatever
  /// the focus's outcome (the session is attached, so nothing is opened).
  private func focusExisting(
    _ attachment: PlainAttachment,
    _ progress: inout Run
  ) async -> AttachState {
    progress.window = attachment.window
    progress.client = attachment.client
    progress.windowFocus = await focusWindow(attachment.window)
    progress.timings.confirmed = progress.timings.checked
    progress.timings.activated = clock.now() - progress.start
    publish(.plainFocused(client: attachment.client), for: progress)
    return .plainFocused(client: attachment.client)
  } // End of func focusExisting(_:_:)

  /// Step 2b's reading, off the actor: `session`'s local attachments with no D16 index (the
  /// plain backend runs only when iTerm2 is not the chosen terminal), in client order.
  private static func localAttachments(
    of session: DiscoveredSession,
    on host: HostConfig,
    with attributor: any LocalClientAttributing
  ) async -> [LocalAttachment] {
    await Task.detached {
      attributor.localAttachments(of: [session], on: host, indexInUse: false)[session.key] ?? []
    }.value
  }

  /// Step 2b's focus: brings `attachment`'s app forward and ends `appFocused`, whatever the
  /// activation's outcome (the session is open there, so nothing is opened; an app that is not
  /// running is not launched).
  private func focusApp(_ attachment: LocalAttachment, _ progress: inout Run) async -> AttachState {
    progress.localAttachment = attachment
    progress.appActivation = await RunningApplicationActivator.activate(
      attachment.app, with: appActivator)
    progress.timings.confirmed = progress.timings.checked
    progress.timings.activated = clock.now() - progress.start
    publish(.appFocused(app: attachment.app), for: progress)
    return .appFocused(app: attachment.app)
  } // End of func focusApp(_:_:)

  /// Step 5: polls the helper's result and its early report until exactly one client of the
  /// session carries the launch's evidence, the helper reports how it ended, or the budget runs
  /// out. Every failure but a helper result withdraws the request.
  ///
  /// Review fixes of I-12c1: the first report read is kept for the whole wait
  /// (`retainedReport(_:_:)`), since the sweep may remove its file before a remote
  /// confirmation ends; and a reading that confirms counts only when the helper's result still
  /// does not exist once it returns (the helper may have ended while it ran).
  private func waitForClient(
    _ progress: inout Run,
    session: DiscoveredSession,
    at target: PlainTmuxCommands.Target
  ) async -> Result<(client: OtherClient, report: PlainLaunchReport), AttachFailure> {
    let remote = target.host.isRemote
    let start = clock.now()
    let budget = confirmationBudget(remote: remote)
    var waiting = false
    var retained: PlainLaunchReport?
    while true {
      if let ended = helperEnded(&progress) { return .failure(ended) }
      let report: PlainLaunchReport?
      do throws(LaunchStoreError) {
        report = try retainedReport(progress.launchID, &retained)
      } catch {
        return .failure(withdrawFailure(&progress, .launchStore(error)))
      }
      if let report {
        if progress.timings.connected == nil {
          progress.timings.connected = clock.now() - progress.start
        }
        switch await read(report, session: session, launchID: progress.launchID, at: target) {
        case .confirmed(let client):
          // The helper may have ended while the reading ran: its result says how.
          if let ended = helperEnded(&progress) { return .failure(ended) }
          return .success((client, report))
        case .notYet:
          break
        case .cannotConfirm:
          return .failure(withdrawFailure(&progress, .cannotConfirmHere))
        case .failed(let failure):
          // The helper's own result, when it ended meanwhile, says more than the reading.
          if let ended = helperEnded(&progress) { return .failure(ended) }
          let attachFailure: AttachFailure =
            failure == .cancelled ? .cancelled : .clientCheckFailed(failure)
          return .failure(withdrawFailure(&progress, attachFailure))
        }
      } // End of the reading after the report
      if waiting || clock.now() >= start + budget {
        guard remote else { return .failure(withdrawFailure(&progress, .timedOut)) }
        if !waiting {
          waiting = true
          progress.timings.stillWaiting = clock.now() - progress.start
          if let window = progress.window {
            publish(.plainStillWaiting(window: window), for: progress)
          }
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
    } // End of loop polling for the client
  } // End of func waitForClient(_:session:at:)

  /// The launch's early report for one poll (peeked, never taken): the first one read is kept
  /// in `retained` and used from then on, even once its file is gone (the sweep, or another
  /// attach's, removes reports after `LaunchStore.defaultTimeToLive`, while a remote
  /// confirmation may go on until the wait limit). A report never changes once the helper
  /// wrote it, so a file that differs from the kept one is `fileMalformed`, never a
  /// confirmation; a file that cannot be read is its own failure. `nil` while none was read.
  private func retainedReport(
    _ launchID: LaunchToken,
    _ retained: inout PlainLaunchReport?
  ) throws(LaunchStoreError) -> PlainLaunchReport? {
    guard let peeked = try store.peekReport(launchID) else { return retained }
    if let retained, retained != peeked { throw .fileMalformed }
    retained = peeked
    return peeked
  } // End of func retainedReport(_:_:)

  /// What one confirmation reading found.
  private enum Reading {
    /// Exactly one client carries the launch's evidence.
    case confirmed(OtherClient)
    /// None does, two or more do, or the report's attach child is not that client any more.
    case notYet
    /// The report names no terminal (This Mac): nothing can ever be confirmed.
    case cannotConfirm
    /// The reading failed.
    case failed(PlainTmuxCommandFailure)
  }

  /// One reading for the launch whose early report is `report`. This Mac: the session's
  /// clients on the report's terminal; exactly one, whose pid is the report's attach child,
  /// still running with the report's start time. An SSH host: the clients whose parent shell's
  /// arguments end with the token `launchID`; exactly one.
  private func read(
    _ report: PlainLaunchReport,
    session: DiscoveredSession,
    launchID: LaunchToken,
    at target: PlainTmuxCommands.Target
  ) async -> Reading {
    let sessionID = session.key.sessionID
    guard target.host.isRemote else {
      guard let terminal = report.terminalPath else { return .cannotConfirm }
      switch await tmux.localReading(of: sessionID, terminal: terminal, at: target) {
      case .failure(let failure):
        return .failed(failure)
      case .success(let reading):
        guard case .confirmed(let client) = reading.outcome,
          client.processID == report.attachChildPID,
          processStartTime(client.processID) == report.attachChildStartTime
        else { return .notYet }
        return .confirmed(client)
      }
    }
    switch await tmux.remoteReading(of: sessionID, token: launchID, at: target) {
    case .failure(let failure):
      return .failed(failure)
    case .success(let reading):
      guard case .confirmed(let client) = reading.outcome else { return .notYet }
      return .confirmed(client)
    }
  } // End of func read(_:session:launchID:at:)

  /// The helper's result, peeked (never taken): when it exists the helper ended, and the
  /// attach fails with the coordinator's mapping (`helperEnded` for a clean end); a result
  /// that cannot be read fails it `launchStore`, the request withdrawn. `nil` while none.
  private func helperEnded(_ progress: inout Run) -> AttachFailure? {
    do throws(LaunchStoreError) {
      guard let result = try store.peekResult(progress.launchID) else { return nil }
      progress.helperEnded = true
      return AttachCoordinator.failure(forHelperResult: result)
    } catch {
      return withdrawFailure(&progress, .launchStore(error))
    }
  } // End of func helperEnded(_:)

  // MARK: - Attachments

  /// Whether `attachment`'s client still holds its session: not once its helper's result
  /// exists (peeked), nor once the read-only bound check finds the client gone (both drop the
  /// attachment); a check that cannot run is `clientCheckFailed` (`cancelled` for a cancelled
  /// caller).
  private func isLive(
    _ attachment: PlainAttachment,
    key: SessionKey
  ) async -> Result<Bool, AttachFailure> {
    if (try? store.peekResult(attachment.launchID)) != nil {
      dropAttachment(key, launchID: attachment.launchID)
      return .success(false)
    }
    switch await tmux.presence(
      of: attachment.client.client, in: attachment.client.session, at: attachment.target)
    {
    case .success(.present):
      return .success(true)
    case .success:
      dropAttachment(key, launchID: attachment.launchID)
      return .success(false)
    case .failure(.cancelled):
      return .failure(.cancelled)
    case .failure(let failure):
      return .failure(.clientCheckFailed(failure))
    }
  } // End of func isLive(_:key:)

  /// Drops every attachment whose helper's result exists (a file-only peek; the result is left
  /// for whoever takes it, or the sweep).
  func pruneEndedAttachments() {
    for (key, attachment) in attachments
    where (try? store.peekResult(attachment.launchID)) != nil {
      dropAttachment(key, launchID: attachment.launchID)
    }
  }

  /// Drops `key`'s attachment when it is still the one of `launchID`.
  func dropAttachment(_ key: SessionKey, launchID: LaunchToken) {
    if attachments[key]?.launchID == launchID { attachments[key] = nil }
  }

  // MARK: - Windows

  /// Opens a window running the helper for `token`, on the main actor.
  private func openWindow(
    token: LaunchToken
  ) async -> Result<PlainTerminalWindow, PlainTerminalWindowError> {
    let windows = self.windows
    let loaded = self.loaded
    let helper = helperPath.path
    return await MainActor.run { () -> Result<PlainTerminalWindow, PlainTerminalWindowError> in
      do throws(PlainTerminalWindowError) {
        return .success(try windows.open(loaded, helperPath: helper, token: token))
      } catch {
        return .failure(error)
      }
    }
  } // End of func openWindow(token:)

  /// Brings `window` forward through the window layer with this backend's loaded definition,
  /// on the main actor.
  func focusWindow(_ window: PlainTerminalWindow) async -> TerminalFocusResult {
    let windows = self.windows
    let loaded = self.loaded
    return await MainActor.run { () -> TerminalFocusResult in
      do throws(PlainTerminalWindowError) {
        try windows.focus(window, of: loaded)
        return .plainWindowFocused
      } catch {
        return .plainWindowFailed(error)
      }
    }
  } // End of func focusWindow(_:)

  // MARK: - Helpers

  /// Withdraws the request and returns the failed state.
  private func withdraw(_ progress: inout Run, _ failure: AttachFailure) -> AttachState {
    .failed(withdrawFailure(&progress, failure))
  }

  /// Withdraws the request (so a helper that starts late cannot attach), noting whether that
  /// removed it before a helper took it, and returns `failure`.
  private func withdrawFailure(_ progress: inout Run, _ failure: AttachFailure) -> AttachFailure {
    if (try? store.discardRequest(progress.launchID)) == true { progress.requestWithdrawn = true }
    return failure
  }

  /// Hands `state` to the observer, and records it as the session's state only while the launch
  /// is the session's latest one.
  private func publish(_ state: AttachState, for progress: Run) {
    let key = progress.target.key
    let isCurrent = latestFlightIDs[key] == progress.flightID
    if isCurrent { states[key] = state }
    onUpdate?(
      AttachUpdate(key: key, launchID: progress.launchID, state: state, isCurrent: isCurrent))
  }

  /// Records the outcome of an attach or a move here: its state and failure kinds and its
  /// duration only.
  private func record(_ result: AttachResult, hostID: UUID, detachesOtherClients: Bool) async {
    guard let diagnostics else { return }
    let duration = AttachCoordinator.milliseconds(result.timings.finished ?? .zero)
    let operation = detachesOtherClients ? "plain move here" : "plain attach"
    if let failure = result.failure {
      let detail = failure.detail.map { " (\($0))" } ?? ""
      await diagnostics.record(
        .attach, outcome: failure == .timedOut ? .timedOut : .failure,
        hostID: hostID.uuidString, durationMs: duration,
        detail: "\(operation) failed: \(failure.kind)\(detail)")
    } else {
      var detail =
        result.isFocused ? "\(operation) focused its window" : "\(operation) confirmed"
      if case .appFocused = result.state {
        detail = "\(operation) focused the app the session is open in on this Mac"
      }
      if let focus = result.plainWindowFocus { detail += "; window focus \(focus.kind)" }
      if let activation = result.appActivation { detail += "; app \(activation.rawValue)" }
      await diagnostics.record(
        .attach, outcome: .success, hostID: hostID.uuidString, durationMs: duration,
        detail: detail)
    }
  } // End of func record(_:hostID:detachesOtherClients:)
} // End of actor PlainTerminalBackend
