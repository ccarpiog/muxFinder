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
///   then the engine's cadence. Nothing contacts iTerm2 at start.
/// - **Popover:** `popoverDidOpen()` / `popoverDidClose()` tell the engine, which refreshes at
///   once and every 15 s while the popover is visible and runs attachment checks only then
///   (D20); those checks are the only reason the popover contacts iTerm2, and requests its
///   cookie, on its own (a click on "Set up SSH in iTerm2 first" does too, D24). Closing
///   cancels the check in progress, so no iTerm2 contact starts once the popover has closed.
/// - **Requests in order:** every engine request goes through one queue read by one task, so
///   an open followed by a close is never applied the other way round. Once `shutdown()` has
///   begun, requests still queued are dropped.
/// - **Quit:** `shutdown()` stops Settings' work (its probes' process groups are killed), the
///   adapter and the engine (which kills any probe's process group) and nothing else: no tmux
///   client is detached and no session is touched.
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
/// - **Placeholders:** opening a session and New session belong to Phase 10. Here they only
///   record the request in `deferredIntents`; nothing is attached or launched.
/// - **Fixtures:** `init(fixture:)` renders a fixed state for previews and screenshots; it
///   never starts an engine, reads the host list or contacts iTerm2.
@MainActor
@Observable
public final class AppModel {
  /// A request that a later phase carries out; recorded only.
  public enum DeferredIntent: Sendable, Hashable {
    /// Open a session in iTerm2 (Phase 10).
    case open(SessionKey)
    /// The New session sheet (Phase 10).
    case newSession
  }

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

  /// How many deferred intents are kept.
  static let deferredIntentLimit = 32

  /// The engine's last published state; `nil` until the host list is loaded.
  public private(set) var refreshState: RefreshState?
  /// How the host list loaded; `nil` until it did.
  public private(set) var hostListStatus: HostListStatus?
  /// The search field's text.
  public var searchText = ""
  /// The keyboard selection.
  public var selection: SessionKey?
  /// Work in progress or the last failure per session (set by Phase 10, and by fixtures).
  public private(set) var activities: [SessionKey: SessionActivity] = [:]
  /// The time relative times are measured against: updated with every engine state and when
  /// the popover opens.
  public private(set) var now: Date
  /// Whether the popover is open.
  public private(set) var isPopoverVisible = false
  /// Increases whenever the search field should take the keyboard focus (⌘F).
  public private(set) var searchFocusRequests = 0
  /// The latest requests that later phases carry out (at most `deferredIntentLimit`).
  public private(set) var deferredIntents: [DeferredIntent] = []
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

  /// The dependencies; `nil` for a fixture.
  @ObservationIgnored private let environment: AppEnvironment?
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
  /// Records placeholder requests (no names or other user data).
  @ObservationIgnored private let logger = Logger(subsystem: "cc.carpio.muxfinder", category: "app")

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
    (commands, commandSink) = AsyncStream.makeStream(of: EngineCommand.self)
    settings.onHostListSaved = { [weak self] list in self?.hostListSaved(list) }
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
    shownExplanation = fixture.shownExplanation
    settings = SettingsModel(fixture: SettingsFixtures.blank)
    onboarding = OnboardingModel(fixture: OnboardingFixtures.blank)
    sshSetup = SSHSetupActions(opener: nil, states: fixture.sshSetupStates)
    (commands, commandSink) = AsyncStream.makeStream(of: EngineCommand.self)
    commandSink.finish()
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
      sshSetupStates: sshSetup.states)
  }

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
  /// built by then, `shutdown()` stops once this returns. A list loaded as `notSavedYet` shows
  /// the onboarding window first (`OnboardingModel.prepare(_:)` decides; it reads nothing).
  private func performStart(_ environment: AppEnvironment) async {
    let (hosts, loaded) = await loadHostList(environment)
    guard lifecycle == .starting else { return }
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

  /// Settings saved `list`: the popover's load status is `saved`, and the engine runs with the
  /// new list (queued like every engine request).
  func hostListSaved(_ list: HostList) {
    hostListStatus = .saved
    send(.setHosts(list))
  }

  /// Stops everything `start()` and Settings started and returns once it has ended: Settings'
  /// work (`SettingsModel.shutdown()`: no new work, its probes and window opening cancelled
  /// and awaited, so their process groups are gone), onboarding's and the popover's "Set up
  /// SSH in iTerm2…" requests (cancelled and awaited), the request queue (requests still queued
  /// are dropped), the system events adapter and the engine, whose `stop()` cancels any
  /// attachment check and kills any running probe's process group. Quitting muxFinder never
  /// detaches a tmux client, ends a session or touches iTerm2. Later calls do nothing.
  public func shutdown() async {
    guard lifecycle != .stopped else { return }
    lifecycle = .stopped
    await settings.shutdown()
    await onboarding.shutdown()
    await sshSetup.shutdown()
    await startTask?.value
    commandSink.finish()
    await commandTask?.value
    await systemEvents?.stop()
    await engine?.stop()
    await updatesTask?.value
  } // End of func shutdown()

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
  /// checks. A repeated call while open does nothing.
  public func popoverDidOpen() {
    guard !isPopoverVisible else { return }
    isPopoverVisible = true
    if let environment { now = environment.now() }
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

  /// "Retry" on a session's failure. Placeholder until Phase 10 retries the attach: clears
  /// the failure and refreshes the session's host.
  public func retry(session key: SessionKey) {
    activities[key] = nil
    send(.refresh(key.hostID))
  }

  /// Opens a session in iTerm2. Placeholder for Phase 10: records the request only; nothing
  /// is attached or launched.
  public func open(_ key: SessionKey) {
    selection = key
    recordDeferred(.open(key))
  }

  /// Return: opens the selected session when it is listed.
  public func openSelection() {
    guard let selection, content.selectableKeys.contains(selection) else { return }
    open(selection)
  }

  /// "New session" (⌘N). Placeholder for Phase 10's sheet: records the request only.
  public func newSession() {
    recordDeferred(.newSession)
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

  /// "Quit": ends the app through `AppEnvironment.terminate`, whose shutdown stops the engine
  /// and leaves every session, client and iTerm2 tab running. Does nothing for a fixture.
  public func quit() {
    environment?.terminate()
  }

  /// ⌘F: asks the search field to take the focus.
  public func focusSearch() {
    searchFocusRequests += 1
  }

  /// Sets or clears what a session row shows while muxFinder works on it. Phase 10's attach
  /// state machine is the caller.
  public func setActivity(_ activity: SessionActivity?, for key: SessionKey) {
    activities[key] = activity
  }

  /// Records a request a later phase carries out, keeping the latest few.
  private func recordDeferred(_ intent: DeferredIntent) {
    deferredIntents.append(intent)
    if deferredIntents.count > Self.deferredIntentLimit {
      deferredIntents.removeFirst(deferredIntents.count - Self.deferredIntentLimit)
    }
    let kind: String
    switch intent {
    case .open: kind = "open (Phase 10)"
    case .newSession: kind = "new session (Phase 10)"
    }
    logger.info("Placeholder request recorded: \(kind, privacy: .public)")
  } // End of func recordDeferred(_:)

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

  /// Carries out a popover key and says whether the popover should close.
  public func handle(_ key: PopoverKey) -> PopoverKeyResult {
    switch key {
    case .up: moveSelection(down: false)
    case .down: moveSelection(down: true)
    case .open: openSelection()
    case .close: return .closePopover
    case .find: focusSearch()
    case .refresh: refresh()
    case .newSession: newSession()
    case .settings: openSettings()
    }
    return .handled
  } // End of func handle(_:)
}
