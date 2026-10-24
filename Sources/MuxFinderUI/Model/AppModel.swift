import Foundation
import MuxFinderCore
import Observation
import os

/// The popover's model (PLAN.md Phase 8, D22): it owns the refresh engine, mirrors its
/// published state on the main actor, and turns the popover's clicks and keys into engine
/// requests.
///
/// - **Start:** `start()` loads the host list (never writing it), builds the engine for it,
///   subscribes to `RefreshCoordinator.updates()`, starts the sleep/wake/network adapter and
///   then the engine's cadence. Nothing contacts iTerm2 at start. With
///   `AppEnvironment.rewritesProfilesAtLaunch` (normal mode only) and a list loaded as `saved`,
///   Settings brings an installed, out-of-date persistent profile file up to date in the
///   background (`SettingsModel.keepProfilesCurrentAtLaunch(_:)`, PLAN.md D26).
/// - **Popover:** `popoverDidOpen()` / `popoverDidClose()` tell the engine, which refreshes at
///   once and every 15 s while the popover is visible and runs attachment checks only then
///   (D20); those checks are the only reason the popover contacts iTerm2, and requests its
///   cookie, on its own (a click on "Set up SSH in iTerm2 first" does too, D24). Closing
///   cancels the check in progress, so no iTerm2 contact starts once the popover has closed.
/// - **Requests in order:** every engine request goes through one queue read by one task, so
///   an open followed by a close is never applied the other way round. Once `shutdown()` has
///   begun, requests still queued are dropped.
/// - **Quit:** `shutdown()` cancels the session actions and, at the same time, stops Settings'
///   work (its probes' process groups are killed), the adapter and the engine (which kills any
///   probe's process group), and nothing else: no tmux client is detached and no session is
///   touched. It waits for the cancelled session actions for a bounded time
///   (`sessionActionShutdownBudget`) and reports those still running.
/// - **Settings** (PLAN.md D23): `openSettings()` (the footer's button and ⌘,) shows the
///   Settings window for `settings` through `AppEnvironment.presentSettings`. A list saved there
///   becomes the engine's list (`RefreshCoordinator.setHosts(_:)`, through the same queue) and
///   the popover's load status turns `saved`.
/// - **Onboarding** (PLAN.md D24): when the list loads as `notSavedYet` at launch (never when
///   `saved`; an unusable file keeps Settings' banner), `start()` prepares `onboarding` from
///   that load and shows its window through `AppEnvironment.presentOnboarding`. A list saved
///   there is handled like one saved in Settings. Showing it contacts nothing.
/// - **Set up SSH in iTerm2…** (PLAN.md D24): a host whose last check needed a sign-in or had a
///   host key problem offers it in the popover (`setUpSSH(hostID:)`), through `sshSetup`.
/// - **Fix-its:** an error with a fix-it (`FixIt`) shows its button; `perform(_:)` opens the
///   System Settings pane through `AppEnvironment.openURL` or shows the explanation.
/// - **Session actions** (PLAN.md D25, `AppModelSessions.swift`): Open (a click or Return),
///   "Move here…" (after the user confirms the dialog), "Detach from this Mac", New session and
///   "Show tab" run on one `AttachCoordinator` that `AppEnvironment.makeAttachCoordinator`
///   builds at the first action. Each session has at most one action at a time: clicks while
///   one is pending are ignored (a New session's attach is its session's action from the moment
///   the session was created). The coordinator's updates and each action's result reach the
///   model through one ordered stream, so the row's activity follows the core's states and
///   "Confirmed" appears only once the core confirmed the attachment. A session that vanished or
///   changed meanwhile gets a banner and its host is refreshed.
/// - **Session switcher shortcut** (PLAN.md D32): `shortcut` loads `preferences.json` and
///   registers the saved hotkey at the start of `start()` (normal mode only: without
///   `AppEnvironment.globalShortcut` nothing is read or registered), and `shutdown()`
///   unregisters it. Its press reaches one entry point, `globalShortcutPressed()`, which until
///   the session switcher exists (Phase I-3b) toggles the popover through `togglePopover`
///   (`PopoverController.shortcutPressed()`, set by `MenuBarPopover`).
/// - **Fixtures:** `init(fixture:)` renders a fixed state for previews and screenshots; it
///   never starts an engine, reads the host list or contacts iTerm2.
@MainActor
@Observable
public final class AppModel {
  /// Where the model is in its life.
  enum Lifecycle: Sendable, Hashable {
    /// Created; `start()` not called.
    case idle
    /// `start()` runs.
    case starting
    /// The engine runs.
    case running
    /// `shutdown()` was called.
    case stopped
  }

  /// One request for the engine.
  enum EngineCommand: Sendable {
    /// The popover opened.
    case popoverOpened
    /// The popover closed.
    case popoverClosed
    /// Refresh every host ("Refresh").
    case refreshAll
    /// Refresh one host ("Retry").
    case refresh(UUID)
    /// Settings saved a new host list.
    case setHosts(HostList)
    /// Resumes the continuation once every earlier request was handled (tests).
    case barrier(CheckedContinuation<Void, Never>)
  }

  /// An action on a session (PLAN.md D25).
  enum ActionKind: Sendable, Hashable {
    /// Open: attach, or focus an attachment that exists already.
    case open
    /// A confirmed move here.
    case moveHere
    /// Detach from this Mac.
    case detach

    /// Its name in the log and in `ShutdownReport`.
    var name: String {
      switch self {
      case .open: return "open"
      case .moveHere: return "move here"
      case .detach: return "detach"
      }
    }
  }

  /// One action in progress on a session.
  struct RunningAction {
    /// What it does.
    let kind: ActionKind
    /// The session as the popover listed it, on its host (`nil` for a detach of a session not
    /// listed yet).
    let target: AttachTarget?
    /// The task awaiting the coordinator.
    let task: Task<Void, Never>
  }

  /// What reaches the model from the coordinator and the actions, in order.
  enum ActionEvent: Sendable {
    /// A state update of a launch (published by the coordinator).
    case update(AttachUpdate)
    /// An open, move here or detach ended.
    case finished(SessionKey, SessionActionRecord.Outcome)
    /// New session number `id` created its session on `host` in `directory` (as checked; `nil`
    /// for the home folder); its attach starts now (before the coordinator publishes any state
    /// of it).
    case sessionCreated(id: Int, CreatedSession, host: HostConfig, directory: String?)
    /// New session number `id` on `host` ended (creation, then the attach of the new session).
    case created(id: Int, CreateAndAttachResult, host: HostConfig)
    /// "Open existing" number `id` listed `host` afresh for the session named `name`.
    case existingFound(id: Int, Result<AttachTarget, AttachFailure>, name: String, host: HostConfig)
    /// Resumes the continuation once every earlier event was handled (tests).
    case barrier(CheckedContinuation<Void, Never>)
  }

  /// A New session whose session is being created (once created, its attach is the new
  /// session's action in `runningActions`).
  struct PendingCreation {
    /// Tells creations apart.
    let id: Int
    /// The task awaiting `AttachCoordinator.createAndAttach(_:onCreated:)`.
    let task: Task<Void, Never>
  }

  /// How many finished actions `finishedActions` keeps.
  static let finishedActionLimit = 32
  /// How many banners are shown at most (the newest first).
  static let bannerLimit = 3
  /// How long `shutdown()` waits for the session actions it cancelled to end (PLAN.md D22,
  /// D25). A cancelled attach whose `CreateTab` was already sent waits for iTerm2's answer
  /// (`LaunchTab`, D15; the API client's request timeout is 10 s) and then withdraws its
  /// request; one whose identity check failed detaches its connection only once the launch tab
  /// is 10 s old. Actions still running after this are reported, not waited for.
  public nonisolated static let sessionActionShutdownBudget: Duration = .seconds(12)
  /// How long quitting waits for `shutdown()` before the app exits anyway: the session actions'
  /// budget plus a margin for the rest, which stops at the same time (PLAN.md D22).
  public nonisolated static let terminationDeadline: Duration =
    sessionActionShutdownBudget + .seconds(3)

  /// The engine's last published state; `nil` until the host list is loaded.
  public private(set) var refreshState: RefreshState?
  /// How the host list loaded; `nil` until it did.
  public private(set) var hostListStatus: HostListStatus?
  /// The search field's text.
  public var searchText = ""
  /// The keyboard selection.
  public var selection: SessionKey?
  /// Work in progress, or how the last action ended, per session (PLAN.md D25).
  public internal(set) var activities: [SessionKey: SessionActivity] = [:]
  /// A note under a session's activity, such as why "Show tab" did nothing.
  public internal(set) var notes: [SessionKey: String] = [:]
  /// Banners for sessions that vanished or changed between the listing and an action, newest
  /// first.
  public internal(set) var banners: [SessionBanner] = []
  /// The Move here confirmation or the New session sheet, while shown.
  public internal(set) var panel: PopoverPanel?
  /// The New session sheet's fields and state. Any change to the Directory field's text (byte
  /// for byte: typing, pasting, a pick) drops the directory list's highlight
  /// (`directoryFieldChanged(from:)`), so Return then creates from what the field holds.
  public var newSessionDraft = NewSessionDraft() {
    didSet { directoryFieldChanged(from: oldValue.directory) }
  }
  /// New session's directory lists as last loaded or changed (PLAN.md D31); empty until the
  /// sheet first opens.
  public internal(set) var directoryLists = DirectoryLists()
  /// How the directory lists last loaded.
  public internal(set) var directoryStatus = DirectoryListStatus.notLoaded
  /// New session's directory list: open or closed, the highlighted row, the last problem.
  public internal(set) var directoryPicker = DirectoryPickerState()
  /// Attachments in this Mac's iTerm2 that muxFinder made or found, by session.
  public internal(set) var attachedHere: [SessionKey: AttachmentRecord] = [:]
  /// The latest actions that ended, oldest first (at most `finishedActionLimit`).
  public internal(set) var finishedActions: [SessionActionRecord] = []
  /// The time relative times are measured against: updated with every engine state and when
  /// the popover opens.
  public private(set) var now: Date
  /// Whether the popover is open.
  public private(set) var isPopoverVisible = false
  /// Increases whenever the search field should take the keyboard focus (⌘F).
  public private(set) var searchFocusRequests = 0
  /// The explaining fix-it whose text the popover shows.
  public private(set) var shownExplanation: FixIt?
  /// Whether this model renders a fixture.
  public let isPreview: Bool
  /// The Settings window's model (inert for a fixture or without settings seams).
  public let settings: SettingsModel
  /// The onboarding window's model (inert for a fixture or without settings seams).
  public let onboarding: OnboardingModel
  /// The popover's "Set up SSH in iTerm2…" (no action for a fixture or without settings seams).
  public let sshSetup: SSHSetupActions
  /// The session switcher shortcut (PLAN.md D32; inert without
  /// `AppEnvironment.globalShortcut`). Settings › General shows the same model.
  public let shortcut: GlobalShortcutModel
  /// What the session switcher shortcut does until the switcher exists: toggles the popover
  /// (`MenuBarPopover` sets it to `PopoverController.shortcutPressed()`); `nil` does nothing.
  @ObservationIgnored public var togglePopover: (@MainActor () -> Void)?

  /// The dependencies; `nil` for a fixture.
  @ObservationIgnored let environment: AppEnvironment?
  /// Where the model is in its life.
  @ObservationIgnored private(set) var lifecycle = Lifecycle.idle
  /// The refresh engine, once built.
  @ObservationIgnored private(set) var engine: RefreshCoordinator?
  /// The sleep, wake and network adapter, once built.
  @ObservationIgnored private var systemEvents: RefreshSystemEvents?
  /// Runs `performStart(_:)`.
  @ObservationIgnored private var startTask: Task<Void, Never>?
  /// Reads the engine's updates.
  @ObservationIgnored private var updatesTask: Task<Void, Never>?
  /// Hands queued requests to the engine, in order.
  @ObservationIgnored private var commandTask: Task<Void, Never>?
  /// The queue of engine requests (buffered until the engine runs).
  @ObservationIgnored private let commands: AsyncStream<EngineCommand>
  /// Feeds `commands`.
  @ObservationIgnored private let commandSink: AsyncStream<EngineCommand>.Continuation
  /// The attach coordinator, once the first action built it.
  @ObservationIgnored var attacher: AttachCoordinator?
  /// Why the attach coordinator could not be built, once that failed.
  @ObservationIgnored var attacherProblem: String?
  /// The action in progress per session.
  @ObservationIgnored var runningActions: [SessionKey: RunningAction] = [:]
  /// The New session whose session is being created.
  @ObservationIgnored var creation: PendingCreation?
  /// "Open existing" lookups (`AttachCoordinator.currentSession(named:on:)`) that have not
  /// ended, by number; a cancelled one stays until it ended, so quitting waits for its probe.
  @ObservationIgnored var lookups: [Int: Task<Void, Never>] = [:]
  /// The lookup the New session sheet waits for, if any.
  @ObservationIgnored var currentLookupID: Int?
  /// Numbers New sessions and "Open existing" lookups.
  @ObservationIgnored var nextPanelActionID = 0
  /// "Show tab" requests in progress.
  @ObservationIgnored var showTabTasks: [Int: Task<Void, Never>] = [:]
  /// Numbers the "Show tab" requests.
  @ObservationIgnored var nextShowTabID = 0
  /// The last action per session, which "Try again" repeats.
  @ObservationIgnored var lastActions: [SessionKey: ActionKind] = [:]
  /// The ordered stream of coordinator updates and action results.
  @ObservationIgnored let actionEvents: AsyncStream<ActionEvent>
  /// Feeds `actionEvents`.
  @ObservationIgnored let actionSink: AsyncStream<ActionEvent>.Continuation
  /// Reads `actionEvents`, once the coordinator exists.
  @ObservationIgnored var actionReader: Task<Void, Never>?
  /// The next banner's id.
  @ObservationIgnored var nextBannerID = 0
  /// The ids of every host in the host list, as loaded as `saved` at launch or saved since
  /// (Settings, onboarding): a recording of a recent directory forgets the recents of other
  /// hosts in the same write (PLAN.md D31). `nil` while the list is not known to be saved, so
  /// nothing is forgotten on the strength of onboarding defaults or an unusable file.
  @ObservationIgnored var knownHostIDs: Set<UUID>?
  /// The latest directory store operation (a load, a recording of a recent directory, a save
  /// or a clear from New session's list); the next one waits for it, so they keep their order
  /// (`enqueueDirectoryOperation(_:)`).
  @ObservationIgnored var directoryOperation: Task<Void, Never>?
  /// Records what the session actions did (kinds only: no names or other user data).
  @ObservationIgnored let logger = Logger(subsystem: "cc.carpio.muxfinder", category: "app")

  /// A model over `environment`. Nothing runs until `start()`.
  public init(environment: AppEnvironment) {
    self.environment = environment
    isPreview = false
    now = environment.now()
    settings =
      environment.settings.map { SettingsModel(environment: $0) }
      ?? SettingsModel(fixture: SettingsFixtures.blank)
    onboarding =
      environment.settings.map {
        OnboardingModel(
          environment: OnboardingEnvironment(
            store: $0.store, sshSetup: $0.sshSetup, diagnostics: $0.diagnostics))
      } ?? OnboardingModel(fixture: OnboardingFixtures.blank)
    sshSetup = SSHSetupActions(opener: environment.settings?.sshSetup)
    shortcut = GlobalShortcutModel(
      environment: environment.globalShortcut, diagnostics: environment.diagnostics)
    (commands, commandSink) = AsyncStream.makeStream(of: EngineCommand.self)
    (actionEvents, actionSink) = AsyncStream.makeStream(of: ActionEvent.self)
    settings.globalShortcut = shortcut
    shortcut.onPress = { [weak self] in self?.globalShortcutPressed() }
    settings.onHostListSaved = { [weak self] list in self?.hostListSaved(list) }
    settings.onDirectoriesSaved = { [weak self] lists in
      self?.directoriesChanged(lists, tellingSettings: false)
    }
    onboarding.onHostListSaved = { [weak self] list in self?.hostListSaved(list) }
    onboarding.onOpenSettings = { [weak self] in self?.openSettings() }
  } // End of init(environment:)

  /// A model that renders `fixture` and never runs anything.
  public init(fixture: PreviewFixture) {
    environment = nil
    isPreview = true
    now = fixture.now
    refreshState = fixture.state
    hostListStatus = fixture.hostList
    searchText = fixture.searchText
    selection = fixture.selection
    activities = fixture.activities
    notes = fixture.notes
    banners = fixture.banners
    panel = fixture.panel
    newSessionDraft = fixture.newSessionDraft
    directoryLists = fixture.directoryLists
    directoryStatus = fixture.directoryStatus
    directoryPicker = fixture.directoryPicker
    attachedHere = fixture.attachedHere
    shownExplanation = fixture.shownExplanation
    settings = SettingsModel(fixture: SettingsFixtures.blank)
    onboarding = OnboardingModel(fixture: OnboardingFixtures.blank)
    sshSetup = SSHSetupActions(opener: nil, states: fixture.sshSetupStates)
    shortcut = GlobalShortcutModel(fixture: GlobalShortcutFixture())
    (commands, commandSink) = AsyncStream.makeStream(of: EngineCommand.self)
    commandSink.finish()
    (actionEvents, actionSink) = AsyncStream.makeStream(of: ActionEvent.self)
    actionSink.finish()
  } // End of init(fixture:)

  // MARK: - Content

  /// What the popover shows now.
  public var content: PopoverContent {
    PopoverContent(
      state: refreshState,
      hostList: hostListStatus,
      query: searchText,
      activities: activities,
      selection: selection,
      now: now,
      sshSetupStates: sshSetup.states,
      notes: notes,
      banners: banners,
      attachedHere: Set(attachedHere.keys))
  } // End of var content

  // MARK: - Lifecycle

  /// Loads the host list, builds and starts the engine and the system events adapter, and
  /// returns once the engine runs. Does nothing for a fixture, a second time, or after
  /// `shutdown()`.
  public func start() async {
    guard lifecycle == .idle, let environment else { return }
    lifecycle = .starting
    let task = Task { await self.performStart(environment) }
    startTask = task
    await task.value
  }

  /// The body of `start()`. Stops building as soon as `shutdown()` was called; whatever it
  /// built by then, `shutdown()` stops once this returns. The session switcher shortcut is
  /// loaded and registered first (PLAN.md D32; nothing without `AppEnvironment.globalShortcut`).
  /// A list loaded as `notSavedYet` shows the onboarding window first
  /// (`OnboardingModel.prepare(_:)` decides; it reads nothing).
  private func performStart(_ environment: AppEnvironment) async {
    await shortcut.start()
    guard lifecycle == .starting else { return }
    let (hosts, loaded) = await loadHostList(environment)
    guard lifecycle == .starting else { return }
    if environment.rewritesProfilesAtLaunch, loaded?.state == .saved {
      settings.keepProfilesCurrentAtLaunch(hosts)
    }
    if let loaded, onboarding.prepare(loaded) {
      environment.presentOnboarding(onboarding)
    }
    let engine = environment.makeEngine(hosts)
    self.engine = engine
    let updates = await engine.updates()
    updatesTask = Task { [weak self] in
      for await state in updates { self?.apply(state) }
    }
    guard lifecycle == .starting else { return }
    let events = environment.makeSystemEvents(engine)
    systemEvents = events
    events?.start()
    await engine.start()
    let commands = self.commands
    commandTask = Task { [weak self] in
      for await command in commands { await self?.perform(command, on: engine) }
    }
    if lifecycle == .starting { lifecycle = .running }
  } // End of func performStart(_:)

  /// Loads the host list and records how it went (in the model and the operation log); returns
  /// the list and the load result (none when the folder was unusable, which gives an empty
  /// list).
  private func loadHostList(
    _ environment: AppEnvironment
  ) async -> (list: HostList, loaded: HostStoreLoadResult?) {
    let list: HostList
    let status: HostListStatus
    var loaded: HostStoreLoadResult?
    do {
      let result = try await environment.loadHosts()
      switch result.state {
      case .saved: status = .saved
      case .notSavedYet: status = .notSavedYet
      case .invalid(let problem): status = .invalid(problem)
      }
      list = result.hosts
      loaded = result
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "The folder is not usable."
      status = .unreadable(message: message)
      list = HostList()
    }
    hostListStatus = status
    knownHostIDs = status == .saved ? Set(list.hosts.map(\.id)) : nil
    await environment.diagnostics?.record(
      .settings, outcome: status == .saved || status == .notSavedYet ? .info : .failure,
      detail: "host list at launch: \(SettingsModel.statusCode(status)), "
        + "\(list.enabledHosts.count) of \(list.hosts.count) hosts turned on")
    return (list, loaded)
  } // End of func loadHostList(_:)

  /// Hands one request to the engine. Once `shutdown()` has begun, a request still queued is
  /// dropped instead, so the engine it is about to stop starts nothing more (a popover opening
  /// queued just before quitting starts no probe and no attachment check). Barriers are
  /// answered either way.
  private func perform(_ command: EngineCommand, on engine: RefreshCoordinator) async {
    if case .barrier(let continuation) = command {
      continuation.resume()
      return
    }
    guard lifecycle != .stopped else { return }
    switch command {
    case .popoverOpened: await engine.popoverDidOpen()
    case .popoverClosed: await engine.popoverDidClose()
    case .refreshAll: await engine.retryAll()
    case .refresh(let hostID): await engine.retry(hostID)
    case .setHosts(let list): await engine.setHosts(list)
    case .barrier: break
    }
  } // End of func perform(_:on:)

  /// Takes a state the engine published (Settings shows its statuses too).
  private func apply(_ state: RefreshState) {
    refreshState = state
    settings.refreshState = state
    if let environment { now = environment.now() }
  }

  /// Settings saved `list`: the popover's load status is `saved`, the engine runs with the new
  /// list (queued like every engine request), and the next recording of a recent directory
  /// forgets the recents of hosts the list no longer has (PLAN.md D31).
  func hostListSaved(_ list: HostList) {
    hostListStatus = .saved
    knownHostIDs = Set(list.hosts.map(\.id))
    send(.setHosts(list))
  }

  /// Asks the engine to refresh one host now (queued like every engine request).
  func refreshHost(_ hostID: UUID) {
    send(.refresh(hostID))
  }

  /// Stops everything `start()`, Settings and the session actions started, all at once, and
  /// returns once it has ended (PLAN.md D22, D25):
  /// - The session actions in progress are cancelled (an attach stops at its next step and
  ///   withdraws its request, a detach waiting for its tab's age sends nothing) and awaited for
  ///   at most `AppEnvironment.sessionActionShutdownBudget`. Any still running then are logged
  ///   (kinds only) and listed in the report; they go on until they end or the process exits.
  /// - At the same time, waiting for none of them: Settings' work (`SettingsModel.shutdown()`:
  ///   no new work, its probes and window opening cancelled and awaited, so their process groups
  ///   are gone), onboarding's and the popover's "Set up SSH in iTerm2…" requests (cancelled and
  ///   awaited), and, in this order, the request queue (requests still queued are dropped), the
  ///   system events adapter and the engine, whose `stop()` cancels any attachment check and
  ///   kills any running probe's process group.
  /// - Then a directory store operation still running (a recording of a recent directory, a
  ///   load, a save or a clear, PLAN.md D31) is awaited for at most the same budget.
  ///
  /// Quitting muxFinder never detaches a tmux client, ends a session or closes an iTerm2 tab.
  /// Later calls do nothing and report nothing.
  @discardableResult
  public func shutdown() async -> ShutdownReport {
    guard lifecycle != .stopped else { return ShutdownReport() }
    lifecycle = .stopped
    let budget = environment?.sessionActionShutdownBudget ?? Self.sessionActionShutdownBudget
    async let unfinished = cancelSessionActions(within: budget)
    async let subsystemsStopped: Void = stopSubsystems()
    let report = ShutdownReport(unfinishedActions: await unfinished)
    await subsystemsStopped
    actionSink.finish()
    await actionReader?.value
    if let operation = directoryOperation { _ = await Self.ends(operation, within: budget) }
    if !report.isComplete { await reportUnfinished(report, budget: budget) }
    return report
  } // End of func shutdown()

  /// The part of `shutdown()` that never waits for a session action: Settings, onboarding,
  /// the popover's "Set up SSH in iTerm2…" requests and the session switcher shortcut (its
  /// save in progress awaited, its hotkey unregistered, PLAN.md D32) stop concurrently with the
  /// engine's chain (the start in progress, the request queue, the system events adapter, the
  /// engine and its updates).
  private func stopSubsystems() async {
    async let settingsStopped: Void = settings.shutdown()
    async let onboardingStopped: Void = onboarding.shutdown()
    async let sshSetupStopped: Void = sshSetup.shutdown()
    async let shortcutStopped: Void = shortcut.shutdown()
    await startTask?.value
    commandSink.finish()
    await commandTask?.value
    await systemEvents?.stop()
    await engine?.stop()
    await updatesTask?.value
    _ = await (settingsStopped, onboardingStopped, sshSetupStopped, shortcutStopped)
  } // End of func stopSubsystems()

  /// Records the session actions `shutdown()` stopped waiting for, kinds only, in the system
  /// log and the operation log.
  private func reportUnfinished(_ report: ShutdownReport, budget: Duration) async {
    let detail =
      "quit: \(report.unfinishedActions.count) session action(s) still running after "
      + "\(Int(budget / .milliseconds(1))) ms (\(report.unfinishedActions.joined(separator: ", "))); "
      + "not waited for"
    logger.error("\(detail, privacy: .public)")
    await environment?.diagnostics?.record(.attach, outcome: .timedOut, detail: detail)
  }

  /// Returns once every engine request queued so far was handed to the engine (tests). Returns
  /// at once while the engine does not run.
  func engineRequestsHandled() async {
    guard lifecycle == .running, commandTask != nil else { return }
    await withCheckedContinuation { continuation in
      if case .terminated = commandSink.yield(.barrier(continuation)) { continuation.resume() }
    }
  }

  /// Queues an engine request; dropped for a fixture and after `shutdown()`.
  private func send(_ command: EngineCommand) {
    guard environment != nil, lifecycle != .stopped else { return }
    commandSink.yield(command)
  }

  // MARK: - Popover

  /// The popover window became visible or hidden.
  public func popoverVisibilityChanged(_ isVisible: Bool) {
    if isVisible { popoverDidOpen() } else { popoverDidClose() }
  }

  /// The popover opened: the engine refreshes every host now and every 15 s, with attachment
  /// checks. Activities of actions that succeeded ("Confirmed", "Detached…") were for the
  /// previous opening and are cleared; failures stay until retried. A repeated call while open
  /// does nothing.
  public func popoverDidOpen() {
    guard !isPopoverVisible else { return }
    isPopoverVisible = true
    if let environment { now = environment.now() }
    for (key, activity) in activities where activity.isDone {
      activities[key] = nil
      notes[key] = nil
    }
    send(.popoverOpened)
  }

  /// The popover closed: back to the background cadence, no attachment checks. The engine
  /// cancels the check in progress: whatever part of it has not reached iTerm2 yet (the cookie
  /// request, the connection, a connection's identity question) never does, and its result is
  /// discarded.
  public func popoverDidClose() {
    guard isPopoverVisible else { return }
    isPopoverVisible = false
    send(.popoverClosed)
  }

  // MARK: - Intents

  /// "Refresh" (⌘R): every host now, whatever its backoff.
  public func refresh() {
    send(.refreshAll)
  }

  /// "Retry" on a host's problem: that host now, whatever its backoff. Its "Set up SSH in
  /// iTerm2…" line is forgotten.
  public func retry(hostID: UUID) {
    sshSetup.clear(hostID)
    send(.refresh(hostID))
  }

  /// "Set up SSH in iTerm2 first" on a host whose last check needed a sign-in or had a host key
  /// problem (PLAN.md D24): opens a tab running ssh to the host's destination, as the engine
  /// has it. Does nothing for a fixture, a host the engine does not list, or one the action is
  /// not offered for.
  public func setUpSSH(hostID: UUID) {
    guard let host = refreshState?.hosts.first(where: { $0.host.id == hostID })?.host else {
      return
    }
    sshSetup.open(host)
  }

  /// Return: opens the selected session when it is listed.
  public func openSelection() {
    guard let selection, content.selectableKeys.contains(selection) else { return }
    open(selection)
  }

  /// "Settings" (⌘,): shows the Settings window, or brings it to the front. Does nothing for a
  /// fixture.
  public func openSettings() {
    environment?.presentSettings(settings)
  }

  /// Performs a fix-it shown with an error: opens its System Settings pane through
  /// `AppEnvironment.openURL`, or shows its explanation (again: hides it).
  public func perform(_ fixIt: FixIt) {
    switch fixIt.action {
    case .openURL(let url):
      environment?.openURL(url)
    case .explain:
      shownExplanation = shownExplanation == fixIt ? nil : fixIt
    case .openLoginItems:
      settings.perform(fixIt)
    }
  }

  /// The session switcher shortcut was pressed (PLAN.md D32): the one entry point of the
  /// hotkey's action. Until the session switcher exists (Phase I-3b) it toggles the popover
  /// through `togglePopover`. Does nothing for a fixture or after `shutdown()`.
  public func globalShortcutPressed() {
    guard environment != nil, lifecycle != .stopped else { return }
    togglePopover?()
  }

  /// "Quit": ends the app through `AppEnvironment.terminate`, whose shutdown stops the engine
  /// and leaves every session, client and iTerm2 tab running. Does nothing for a fixture.
  public func quit() {
    environment?.terminate()
  }

  /// ⌘F: asks the search field to take the focus.
  public func focusSearch() {
    searchFocusRequests += 1
  }

  /// Sets or clears what a session row shows (the attach state machine's own changes go
  /// through its events; tests and fixtures use this).
  func setActivity(_ activity: SessionActivity?, for key: SessionKey) {
    activities[key] = activity
  }

  // MARK: - Keyboard

  /// Moves the selection one listed row down (`down`) or up, staying at the ends. With no
  /// listed selection, ↓ selects the first row and ↑ the last.
  public func moveSelection(down: Bool) {
    let keys = content.selectableKeys
    guard !keys.isEmpty else {
      selection = nil
      return
    }
    guard let current = selection, let position = keys.firstIndex(of: current) else {
      selection = down ? keys.first : keys.last
      return
    }
    selection = keys[down ? min(position + 1, keys.count - 1) : max(position - 1, 0)]
  } // End of func moveSelection(down:)

  /// Carries out a popover key and says whether the popover should close. While a panel
  /// shows (Move here, New session), Return confirms it, Esc closes it, and the arrows, ⌘F and
  /// ⌘N do nothing. In New session, ⌥↓ opens the directory list; while it is open, ↑/↓ move
  /// through it, Return picks the highlighted row (with none, it closes the list and creates)
  /// and Esc closes the list, not the panel (`handleDirectoryListKey(_:)`, PLAN.md D31). ⌥↓
  /// anywhere else is left to the focused view (`ignored`).
  public func handle(_ key: PopoverKey) -> PopoverKeyResult {
    if let panel {
      if case .newSession = panel, let result = handleDirectoryListKey(key) { return result }
      switch (key, panel) {
      case (.open, .moveHere): confirmMoveHere()
      case (.open, .newSession): createSession()
      case (.openList, .newSession): openDirectoryList(highlightingFirst: true)
      case (.openList, .moveHere): return .ignored
      case (.close, _): cancelPanel()
      case (.refresh, _): refresh()
      case (.settings, _): openSettings()
      case (.up, _), (.down, _), (.find, _), (.newSession, _): break
      }
      return .handled
    }
    switch key {
    case .up: moveSelection(down: false)
    case .down: moveSelection(down: true)
    case .open: openSelection()
    case .close: return .closePopover
    case .find: focusSearch()
    case .refresh: refresh()
    case .newSession: newSession()
    case .settings: openSettings()
    case .openList: return .ignored
    }
    return .handled
  } // End of func handle(_:)
}

/// What `AppModel.shutdown()` stopped waiting for (PLAN.md D22, D25).
public struct ShutdownReport: Sendable, Hashable {
  /// The session actions still running when the budget ran out, by kind ("open", "move here",
  /// "detach", "new session", "open existing", "show tab").
  public var unfinishedActions: [String]

  /// Creates a report.
  public init(unfinishedActions: [String] = []) {
    self.unfinishedActions = unfinishedActions
  }

  /// Whether every session action ended in time.
  public var isComplete: Bool { unfinishedActions.isEmpty }
}
