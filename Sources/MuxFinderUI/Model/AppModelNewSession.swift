import Foundation
import MuxFinderCore

/// New session in its own window (PLAN.md D34, D25, D31): opening and ending the window, its
/// keys, the creation and "Open existing".
///
/// - **One window, model state:** `newSessionWindow` says whether the window shows and holds
///   the latest request to show it (`NewSessionWindowRequest`); the app shell's
///   `NewSessionWindowController` follows it. The model never needs the window: the self-tests
///   and the tests drive it with none.
/// - **Opening** (`newSession()` from the popover, `newSessionFromSwitcher()` from the
///   switcher): a fresh opening starts a fresh draft (This Mac by default, the switcher's name
///   prefilled), unless a creation runs, whose draft then shows busy; an opening while the
///   window shows only brings it forward, its draft untouched. The popover or the switcher
///   closes as it opens; opening and closing them never touches the window or its draft.
/// - **Ending:** Cancel, Esc (the directory list closed), ⌘W and the close button close it as
///   `closeNewSession()` (the draft is dropped, a creation in progress goes on with its draft);
///   a success closes it and the attach goes on on its row; a collision or a failure stays in
///   it, and one that ends after the window was closed brings it back, not key
///   (`newSessionCreationFailed()`), whichever entry point started it.
/// - **Not the popover's panel:** a Move here confirmation in the popover and the window can
///   show at the same time.
extension AppModel {
  // MARK: - The window

  /// Whether the New session window shows (PLAN.md D34).
  public var isNewSessionShown: Bool { newSessionWindow.isShown }

  /// What quitting would lose, for the update flow's ask (PLAN.md D39 *The update flow
  /// (I-13c2a)*): a New session window whose draft has text (name or directory), and Settings'
  /// unsaved edits (the host editor's draft, `SettingsModel.isDirty`, or the directory list's,
  /// `isDirectoryListDirty`). Attached tmux sessions are never part of it.
  func unsavedWorkForUpdate() -> UpdateUnsavedWork {
    let hasText: (String) -> Bool = { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    let draft =
      isNewSessionShown && (hasText(newSessionDraft.name) || hasText(newSessionDraft.directory))
    return UpdateUnsavedWork(
      newSessionDraft: draft,
      settingsEdits: settings.isDirty || settings.isDirectoryListDirty)
  }

  /// Whether an update is being installed (PLAN.md D39 *The update flow (I-13c2a)*): from the
  /// final unsaved-work decision through the install and the quit, the New session draft's
  /// fields and Settings' host editor and directory list refuse changes, and no New session
  /// window opens; `false` again when the install fails.
  public var isInstallingUpdate: Bool { update.flow.locksEditing }

  /// "New session" in the popover (⌘N, the footer's button): opens the New session window
  /// placed from the popover's frame, or brings it forward (`openNewSession(from:source:
  /// prefill:)`), and closes the popover. Does nothing for a fixture or after `shutdown()`.
  public func newSession() {
    openNewSession(from: .popover, source: popoverSource?(), prefill: nil)
  }

  /// Opens the New session window, or brings it forward when it shows (PLAN.md D34). A fresh
  /// opening (the window closed) starts a fresh draft for This Mac (or the first enabled host)
  /// named `prefill` when given, from `origin`, unless a creation runs, whose draft then shows
  /// busy, as before; it closes the directory list, asks for the Name field's focus and reads
  /// the directory lists afresh in the background (`loadDirectoryLists()`, PLAN.md D31). An
  /// opening while the window shows leaves its draft, its directory list and its frame as they
  /// are. Either way the rest of a click sequence in progress is let through to no view of the
  /// window (`newSessionWindowPasses(_:)`), the popover and the switcher close
  /// (`CloseReason.newSessionOpened`; a switcher held through a click's double-click interval
  /// closes at its end), and the window is asked to show, key, placed from `source` for a fresh
  /// opening. Does nothing for a fixture or after `shutdown()`.
  func openNewSession(
    from origin: NewSessionOrigin, source: NewSessionWindowSource?, prefill: String?
  ) {
    guard environment != nil, lifecycle != .stopped, !isInstallingUpdate else { return }
    if !isNewSessionShown {
      if creation == nil {
        let hosts = newSessionHosts
        newSessionDraft = NewSessionDraft(
          hostID: (hosts.first(where: \.isThisMac) ?? hosts.first)?.id, name: prefill ?? "")
        newSessionOrigin = origin
      }
      directoryPicker = DirectoryPickerState()
      newSessionFocusRequests += 1
      loadDirectoryLists()
    }
    newSessionClicks = SwitcherClickSequence()
    newSessionClicks.rowActivated()
    if isPopoverVisible { closePopover?(.newSessionOpened) }
    if isSwitcherVisible { closeSwitcher?(.newSessionOpened) }
    showNewSessionWindow(.open(source: source))
  } // End of func openNewSession(from:source:prefill:)

  /// Asks the window to show (or come forward) for `kind`, with a request of its own.
  func showNewSessionWindow(_ kind: NewSessionWindowRequest.Kind) {
    nextNewSessionWindowRequest += 1
    newSessionWindow = NewSessionWindowState(
      isShown: true,
      request: NewSessionWindowRequest(number: nextNewSessionWindowRequest, kind: kind))
  }

  /// Cancel, Esc (once the directory list is closed), ⌘W and the window's close button (PLAN.md
  /// D34): the window closes with its directory list and its drop highlight (Phase I-9b),
  /// "Open existing" stops looking (its lookup
  /// is cancelled and opens nothing), and a creation in progress goes on, keeping its draft for
  /// its outcome (a collision or a failure brings the window back with it,
  /// `newSessionCreationFailed()`; a success shows on its row). Otherwise the draft is dropped:
  /// the next opening starts a fresh one. Does nothing while the window is closed.
  public func closeNewSession() {
    guard isNewSessionShown else { return }
    closeDirectoryList()
    directoryDragEnded()
    if let id = currentLookupID { lookups[id]?.cancel() }
    currentLookupID = nil
    if newSessionDraft.state == .findingExisting { newSessionDraft.state = .collision }
    newSessionWindow.isShown = false
  }

  /// Carries out a key in the New session window and says what the window does next (PLAN.md
  /// D34, the form's keys as they were in the panels): with the directory list open, its keys
  /// first (`handleDirectoryListKey(_:)`: ↑/↓/⌥↓ move, Return picks or creates, Esc closes the
  /// list); otherwise Return creates, ⌥↓ opens the list on its first row, Esc closes the window
  /// (`closeNewSession()`), ⌘, opens Settings (the window stays), and ↑, ↓ and ⌘N do nothing.
  /// ⌘R and ⌘F are not the window's (it lists no sessions): they go on to the focused view
  /// (`ignored`). With a pop-up button focused (the Host picker) the window's key monitor never
  /// hands ↑, ↓ or ⌥↓ here, and while a menu tracks or an input method composes, no key at all
  /// (`PanelKeyRoute`, PLAN.md Phase I-8). Every key is `ignored` while the window is closed.
  public func handleNewSessionKey(_ key: PopoverKey) -> PopoverKeyResult {
    guard isNewSessionShown else { return .ignored }
    if let result = handleDirectoryListKey(key) { return result }
    switch key {
    case .open: createSession()
    case .openList: openDirectoryList(highlightingFirst: true)
    case .close: closeNewSession()
    case .settings: openSettings()
    case .up, .down, .newSession: break
    case .find, .refresh: return .ignored
    }
    return .handled
  } // End of func handleNewSessionKey(_:)

  /// Whether a left mouse button event in the New session window goes on to its views: not
  /// while it belongs to the rest of the click sequence in progress when the window was last
  /// opened (a double click's second click on the switcher's New session row, say, landing on
  /// the window that row opened; `SwitcherClickSequence`, PLAN.md D32's rule for the switcher's
  /// form).
  public func newSessionWindowPasses(_ event: SwitcherClickSequence.Event) -> Bool {
    newSessionClicks.passes(event)
  }

  // MARK: - Creating

  /// The form's "Create" (Return): checks the fields (the issues show inline), then creates
  /// the session and attaches it in the chosen terminal (the backend's
  /// `createAndAttach(_:onCreated:)`; an unavailable choice creates nothing and says why). A
  /// collision offers "Open existing"; any other creation failure is shown in the window. Once
  /// the session was created, the window closes and the attach is the new session's action
  /// (`sessionCreated(_:_:on:directory:)`), shown on its row from its first state on. A
  /// creation from a draft the switcher made is the switcher's to follow
  /// (`switcherCreationStarted(_:)`). Only while the window shows.
  public func createSession() {
    guard isNewSessionShown, creation == nil, !newSessionDraft.isBusy,
      let environment, lifecycle != .stopped
    else { return }
    newSessionDraft.showsIssues = true
    guard newSessionDraft.nameIssue == nil, newSessionDraft.directoryIssue == nil,
      let request = newSessionDraft.request(
        hosts: newSessionHosts, command: environment.newSessionCommand)
    else { return }
    guard let terminalBackend = backend() else {
      newSessionDraft.state = .failed(
        backendProblem?.message ?? "muxFinder could not prepare opening sessions in iTerm2.")
      return
    }
    newSessionDraft.state = .creating
    nextPanelActionID += 1
    let id = nextPanelActionID
    let sink = actionSink
    let host = request.host
    let directory = request.workingDirectory
    let task = Task {
      let result = await terminalBackend.createAndAttach(request) { created in
        sink.yield(.sessionCreated(id: id, created, host: host, directory: directory))
      }
      sink.yield(.created(id: id, result, host: host))
    }
    creation = PendingCreation(id: id, task: task, terminalID: terminalChoice.chosen?.id)
    switcherCreationStarted(id)
    logger.info("Session action started: new session")
  } // End of func createSession()

  /// New session `id` created its session on `host` in `directory`, and its attach starts now
  /// (this comes before any of the attach's states). The directory is recorded as one of the
  /// host's recent directories (`recordRecentDirectory(_:for:)`), whatever the attach does
  /// next. From here on the attach is the new session's action, like an Open: its row follows
  /// the coordinator's states ("Opening…", "Waiting for iTerm2…", "Still connecting — check the
  /// iTerm2 tab" with "Show tab") and then the result, clicks on it are ignored while it is
  /// pending, and quitting cancels it. The window closes, so the row shows, and the host is
  /// refreshed, so it is listed; another New session can start.
  func sessionCreated(
    _ id: Int, _ created: CreatedSession, on host: HostConfig, directory: String?
  ) {
    recordRecentDirectory(directory, for: host.id)
    guard let pending = creation, pending.id == id else { return }
    creation = nil
    let target = created.attachTarget(on: host)
    let key = target.key
    runningActions[key] = RunningAction(
      kind: .open, target: target, task: pending.task, terminalID: pending.terminalID)
    switcherSessionCreated(id, key: key, target: target)
    lastActions[key] = .open
    activities[key] = .opening
    notes[key] = nil
    if newSessionDraft.state == .creating { newSessionDraft.state = .editing }
    if isNewSessionShown {
      closeDirectoryList()
      newSessionWindow.isShown = false
    }
    refreshHost(host.id)
  } // End of func sessionCreated(_:_:on:directory:)

  /// New session number `id` on `host` ended: a creation failure stays in the window (a
  /// collision offers "Open existing"), which comes back if it was closed meanwhile
  /// (`newSessionCreationFailed()`); a created session's attach (its session's action since
  /// `sessionCreated(_:_:on:directory:)`) ends like an Open, on its row.
  func finishCreation(_ id: Int, _ result: CreateAndAttachResult, on host: HostConfig) {
    if creation?.id == id { creation = nil }
    defer { applyPendingTerminalChoiceIfIdle() }
    let createdKey = result.created.map {
      SessionKey(hostID: host.id, server: $0.server, sessionID: $0.sessionID)
    }
    record(SessionActionRecord(key: createdKey, outcome: .created(result)))
    if let failure = result.creationFailure {
      if case .sessionExists = failure {
        newSessionDraft.state = .collision
      } else {
        newSessionDraft.state = .failed(failure.message)
      }
      if failure.triggersRefresh { refreshHost(host.id) }
      if switcherCreation?.id == id { switcherCreation = nil }
      newSessionCreationFailed()
      return
    }
    guard let created = result.created, let attach = result.attach else {
      if let createdKey { forgetSwitcherAction(createdKey) }
      return
    }
    let running = runningActions.removeValue(forKey: attach.key)
    notes[attach.key] = nil
    lastActions[attach.key] = .open
    finishAttach(
      attach, target: running?.target ?? created.attachTarget(on: host),
      terminalID: running?.terminalID ?? terminalChoice.chosen?.id)
  } // End of func finishCreation(_:_:on:)

  /// A creation ended in a collision or a failure, which the draft now holds (PLAN.md D34): when
  /// its window was closed meanwhile, it comes back with the draft as submitted and that
  /// outcome, in front at its last frame and not key (`NewSessionWindowRequest.Kind.outcome`),
  /// so the failure is never silent and never takes typing from the app in front, whichever
  /// entry point started it. A Move here confirmation in the popover does not hold it back.
  /// Nothing comes back once `shutdown()` has begun.
  func newSessionCreationFailed() {
    guard !isNewSessionShown, lifecycle != .stopped else { return }
    showNewSessionWindow(.outcome)
  }

  // MARK: - Open existing

  /// "Open existing" after a collision: lists the draft's host afresh through the chosen
  /// terminal's backend (`currentSession(named:on:)`), never trusting the popover's list, since the
  /// session tmux reported may be another one than the list shows (the listed one renamed, and
  /// another one given its name), and opens the session with exactly the draft's name in that
  /// listing (`existingFound(_:_:name:on:)`). When none has that name, or the host cannot be
  /// listed, the window says so and nothing is opened.
  public func openExisting() {
    guard isNewSessionShown, newSessionDraft.state == .collision, lifecycle != .stopped,
      let hostID = newSessionDraft.hostID, let host = host(withID: hostID),
      let name = try? Validation.sessionName(newSessionDraft.name)
    else { return }
    guard let terminalBackend = backend() else {
      newSessionDraft.state = .failed(
        backendProblem?.message ?? "muxFinder could not prepare opening sessions in iTerm2.")
      return
    }
    newSessionDraft.state = .findingExisting
    nextPanelActionID += 1
    let id = nextPanelActionID
    let sink = actionSink
    lookups[id] = Task {
      let found = await terminalBackend.currentSession(named: name, on: host)
      sink.yield(.existingFound(id: id, found, name: name, host: host))
    }
    currentLookupID = id
    logger.info("Session action started: open existing")
  } // End of func openExisting()

  /// "Open existing" number `id` listed `host` afresh: the session named exactly `name` there
  /// is opened (the window closes and its row shows the attach, which revalidates it once
  /// more; once it started, it is the switcher's to follow when the switcher made the draft,
  /// `switcherExistingOpened(_:target:)`); otherwise the window says why nothing was opened: no
  /// session has that name any more (it ended or was renamed; the host is refreshed), or the
  /// host could not be listed. A lookup the window no longer waits for (cancelled by its
  /// closing, or another draft) changes nothing.
  func existingFound(
    _ id: Int,
    _ found: Result<AttachTarget, AttachFailure>,
    name: String,
    on host: HostConfig
  ) {
    lookups[id] = nil
    defer { applyPendingTerminalChoiceIfIdle() }
    guard currentLookupID == id else { return }
    currentLookupID = nil
    guard newSessionDraft.state == .findingExisting, isNewSessionShown else { return }
    guard newSessionDraft.hostID == host.id,
      (try? Validation.sessionName(newSessionDraft.name)) == name
    else {
      newSessionDraft.state = .editing
      return
    }
    switch found {
    case .success(let target):
      newSessionDraft.state = .editing
      closeDirectoryList()
      newSessionWindow.isShown = false
      selection = target.key
      if startAttach(target.key, kind: .open, target: target) {
        switcherExistingOpened(target.key, target: target)
      }
      refreshHost(host.id)
    case .failure(.sessionGone):
      newSessionDraft.state = .failed(NewSessionDraft.existingGone)
      refreshHost(host.id)
    case .failure(let failure):
      newSessionDraft.state = .failed(NewSessionDraft.existingNotListed(failure.message))
    }
  } // End of func existingFound(_:_:name:on:)
}
