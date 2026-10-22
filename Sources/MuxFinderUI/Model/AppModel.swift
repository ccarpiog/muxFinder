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
///   (D20); those checks are the only reason iTerm2 is contacted, and its cookie requested,
///   in this phase. Closing cancels the check in progress, so no iTerm2 contact starts once
///   the popover has closed.
/// - **Requests in order:** every engine request goes through one queue read by one task, so
///   an open followed by a close is never applied the other way round. Once `shutdown()` has
///   begun, requests still queued are dropped.
/// - **Quit:** `shutdown()` stops the adapter and the engine (which kills any probe's process
///   group) and nothing else: no tmux client is detached and no session is touched.
/// - **Placeholders:** opening a session, New session and Settings belong to Phases 10 and 9.
///   Here they only record the request in `deferredIntents`; nothing is attached, launched or
///   saved.
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
    /// The Settings window (Phase 9).
    case openSettings
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
  /// Whether this model renders a fixture.
  public let isPreview: Bool

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
    (commands, commandSink) = AsyncStream.makeStream(of: EngineCommand.self)
  }

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
      now: now)
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
  /// built by then, `shutdown()` stops once this returns.
  private func performStart(_ environment: AppEnvironment) async {
    let hosts = await loadHostList(environment)
    guard lifecycle == .starting else { return }
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

  /// Loads the host list and records how it went; an unusable folder gives an empty list.
  private func loadHostList(_ environment: AppEnvironment) async -> HostList {
    do {
      let result = try await environment.loadHosts()
      switch result.state {
      case .saved: hostListStatus = .saved
      case .notSavedYet: hostListStatus = .notSavedYet
      case .invalid(let problem): hostListStatus = .invalid(problem)
      }
      return result.hosts
    } catch {
      let message = (error as? LocalizedError)?.errorDescription ?? "The folder is not usable."
      hostListStatus = .unreadable(message: message)
      return HostList()
    }
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
    case .barrier: break
    }
  } // End of func perform(_:on:)

  /// Takes a state the engine published.
  private func apply(_ state: RefreshState) {
    refreshState = state
    if let environment { now = environment.now() }
  }

  /// Stops everything `start()` started and returns once it has ended: the request queue
  /// (requests still queued are dropped), the system events adapter and the engine, whose
  /// `stop()` cancels any attachment check and kills any running probe's process group.
  /// Quitting muxFinder never detaches a tmux client, ends a session or touches iTerm2. Later
  /// calls do nothing.
  public func shutdown() async {
    guard lifecycle != .stopped else { return }
    lifecycle = .stopped
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

  /// "Retry" on a host's problem: that host now, whatever its backoff.
  public func retry(hostID: UUID) {
    send(.refresh(hostID))
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

  /// "Settings" (⌘,). Placeholder for Phase 9's window: records the request only.
  public func openSettings() {
    recordDeferred(.openSettings)
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
    case .openSettings: kind = "settings (Phase 9)"
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
