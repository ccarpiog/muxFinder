import Foundation
import MuxFinderCore
import os

/// The session actions of the popover (PLAN.md D25): Open, "Move here…", "Detach from this
/// Mac", New session, "Show tab", the recoveries a failure offers, and the banners.
///
/// - **One action per session:** `runningActions` holds the action in progress for each
///   session; a click, Return or menu item for a session with one pending is ignored, so a burst
///   of clicks starts one launch. A New session's attach becomes its session's action as soon
///   as the session was created, so its row follows it like an Open's.
/// - **Ordered events:** the coordinator's update handler and every action's result feed one
///   `AsyncStream` read by one main-actor task. The coordinator publishes a launch's states
///   before its call returns, and the action yields its result after that, so the row never
///   goes back to "Waiting for iTerm2…" after "Confirmed". "Confirmed" comes only from the
///   core's `confirmed` state (after its identity check) or result; "Already open here —
///   brought its tab forward" only from a focus whose activation brought the tab forward.
/// - **Seams:** the coordinator comes from `AppEnvironment.makeAttachCoordinator` at the first
///   action; tests build it over a fake iTerm2 integration, the self-tests over the real one
///   with an attachment index that asks only their own launch tabs' connections.
extension AppModel {
  // MARK: - Lookups

  /// The session `key` as the engine lists it, on its host, as an attach target.
  func target(for key: SessionKey) -> AttachTarget? {
    guard let snapshot = refreshState?.snapshot(of: key.hostID),
      let session = snapshot.sessions.first(where: { $0.key == key })
    else { return nil }
    return AttachTarget(host: snapshot.host, session: session.discovered)
  }

  /// The enabled host `hostID` as the engine has it.
  func host(withID hostID: UUID) -> HostConfig? {
    refreshState?.snapshot(of: hostID)?.host
  }

  /// Whether an action on `key` is in progress; clicks for it are ignored meanwhile.
  public func isPending(_ key: SessionKey) -> Bool {
    runningActions[key] != nil
  }

  /// Whether "Detach from this Mac" is offered for `key`: only for an attachment in this Mac's
  /// iTerm2, as the attachment index reports it (the "Open in iTerm2 here" badge) or as
  /// muxFinder made or found it itself (`attachedHere`).
  public func canDetach(_ key: SessionKey) -> Bool {
    if attachedHere[key] != nil { return true }
    let session = refreshState?.snapshot(of: key.hostID)?.sessions.first { $0.key == key }
    return session?.isOpenInITerm2Here == true
  }

  /// The hosts New session offers: the enabled hosts, in list order.
  public var newSessionHosts: [HostConfig] {
    refreshState?.hosts.map(\.host) ?? []
  }

  // MARK: - Open and move here

  /// Opens a session in iTerm2 (a click or Return): attaches it through a launch tab, or, when
  /// this Mac's iTerm2 shows it already, brings that tab forward without launching anything
  /// (the coordinator's existing-attachment check, PLAN.md D16). Ignored while an action on the
  /// session is pending, for a fixture, and after `shutdown()`.
  public func open(_ key: SessionKey) {
    selection = key
    startAttach(key, kind: .open, target: nil)
  }

  /// "Move here…": shows the confirmation for `key`, which explains that every other client is
  /// disconnected, including other Macs. Nothing runs until `confirmMoveHere()`.
  public func requestMoveHere(_ key: SessionKey) {
    guard environment != nil, lifecycle != .stopped, runningActions[key] == nil,
      let target = target(for: key)
    else { return }
    panel = .moveHere(MoveHereRequest(target: target))
  }

  /// The confirmation's "Move here": the only call that reaches
  /// `AttachCoordinator.moveHere(_:confirmation:)`, with the confirmation naming that session.
  public func confirmMoveHere() {
    guard case .moveHere(let request) = panel else { return }
    panel = nil
    startAttach(request.target.key, kind: .moveHere, target: request.target)
  }

  /// Closes the panel (Cancel, or Esc): a Move here confirmation runs nothing; a New session
  /// being created goes on (its result shows on its row) and "Open existing" stops looking (its
  /// lookup is cancelled and opens nothing). New session's directory list closes with it.
  public func cancelPanel() {
    panel = nil
    closeDirectoryList()
    if let id = currentLookupID { lookups[id]?.cancel() }
    currentLookupID = nil
    if newSessionDraft.state == .findingExisting { newSessionDraft.state = .collision }
  }

  /// Starts an open or a confirmed move here of `key` (`given`, or the listed session).
  func startAttach(_ key: SessionKey, kind: ActionKind, target given: AttachTarget?) {
    guard lifecycle != .stopped, runningActions[key] == nil,
      let target = given ?? target(for: key)
    else { return }
    guard let coordinator = coordinator() else {
      if let attacherProblem { activities[key] = .failed(.unavailable(attacherProblem)) }
      return
    }
    lastActions[key] = kind
    activities[key] = kind == .moveHere ? .movingHere : .opening
    notes[key] = nil
    let sink = actionSink
    let task = Task {
      let outcome: SessionActionRecord.Outcome
      if kind == .moveHere {
        outcome = .moveHere(
          await coordinator.moveHere(target, confirmation: .detachOtherClients(of: key)))
      } else {
        outcome = .attach(await coordinator.attach(target))
      }
      sink.yield(.finished(key, outcome))
    }
    runningActions[key] = RunningAction(kind: kind, target: target, task: task)
    logger.info("Session action started: \(kind.name, privacy: .public)")
  } // End of func startAttach(_:kind:target:)

  // MARK: - Detach

  /// "Detach from this Mac": detaches every attachment of `key` in this Mac's iTerm2 with
  /// `detach-client` through the core (`AttachCoordinator.detach(session:on:)`, which waits
  /// until each tab is old enough and never closes a tab). The session keeps running. Offered
  /// and run only when `canDetach(_:)`; ignored while an action on the session is pending.
  public func detach(_ key: SessionKey) {
    guard lifecycle != .stopped, runningActions[key] == nil, canDetach(key),
      let host = host(withID: key.hostID)
    else { return }
    guard let coordinator = coordinator() else {
      if let attacherProblem { activities[key] = .failed(.unavailable(attacherProblem)) }
      return
    }
    lastActions[key] = .detach
    activities[key] = .detaching
    notes[key] = nil
    let sink = actionSink
    let task = Task {
      let result = await coordinator.detach(session: key, on: host)
      sink.yield(.finished(key, .detached(result)))
    }
    runningActions[key] = RunningAction(kind: .detach, target: target(for: key), task: task)
    logger.info("Session action started: detach")
  } // End of func detach(_:)

  // MARK: - Show tab and recoveries

  /// "Show tab": brings forward the launch tab of `key`'s activity (a still-connecting attach,
  /// or a failure whose tab explains more), through `AttachCoordinator.showLaunchTab(_:)`,
  /// which refuses any tab it did not open. The id only ever comes from the coordinator's own
  /// updates and results. A failure leaves a note under the activity.
  public func showTab(for key: SessionKey) {
    guard let id = activities[key]?.launchTabID, let coordinator = attacher else { return }
    notes[key] = nil
    nextShowTabID += 1
    let number = nextShowTabID
    showTabTasks[number] = Task { [weak self] in
      let result = await coordinator.showLaunchTab(id)
      self?.showTabEnded(number, key: key, result: result)
    }
  }

  /// One "Show tab" ended.
  func showTabEnded(_ number: Int, key: SessionKey, result: LaunchTabShowResult) {
    showTabTasks[number] = nil
    notes[key] = SessionProblem.showTabNote(result)
  }

  /// Performs a button a failure offers.
  public func perform(_ recovery: SessionProblem.Recovery, for key: SessionKey) {
    switch recovery {
    case .retry:
      retry(session: key)
    case .refresh:
      activities[key] = nil
      notes[key] = nil
      refreshHost(key.hostID)
    case .showTab:
      showTab(for: key)
    case .bringForward:
      open(key)
    case .detachHere:
      detach(key)
    case .openSettings:
      openSettings()
    }
  } // End of func perform(_:for:)

  /// "Try again" on a session's failure: repeats its last action (a move here shows its
  /// confirmation again); with none, clears the failure and refreshes the session's host.
  public func retry(session key: SessionKey) {
    guard runningActions[key] == nil else { return }
    let last = lastActions[key]
    activities[key] = nil
    notes[key] = nil
    switch last {
    case .open?: open(key)
    case .moveHere?: requestMoveHere(key)
    case .detach?: detach(key)
    case nil: refreshHost(key.hostID)
    }
  } // End of func retry(session:)

  /// Removes a banner.
  public func dismissBanner(_ id: Int) {
    banners.removeAll { $0.id == id }
  }

  // MARK: - New session

  /// "New session" (⌘N): shows the sheet with a fresh draft for This Mac (or the first enabled
  /// host), or the draft being created, with its directory list closed, and reads the
  /// directory lists afresh in the background (`loadDirectoryLists()`, PLAN.md D31). Does
  /// nothing for a fixture or after `shutdown()`.
  public func newSession() {
    guard environment != nil, lifecycle != .stopped else { return }
    if case .newSession = panel { return }
    if creation == nil {
      let hosts = newSessionHosts
      newSessionDraft = NewSessionDraft(
        hostID: (hosts.first(where: \.isThisMac) ?? hosts.first)?.id)
    }
    directoryPicker = DirectoryPickerState()
    panel = .newSession
    loadDirectoryLists()
  }

  /// The sheet's "Create": checks the fields (the issues show inline), then creates the
  /// session and attaches it (`AttachCoordinator.createAndAttach(_:onCreated:)`). A collision
  /// offers "Open existing"; any other creation failure is shown in the sheet. Once the session
  /// was created, the sheet closes and the attach is the new session's action
  /// (`sessionCreated(_:_:on:)`), shown on its row from its first state on.
  public func createSession() {
    guard case .newSession = panel, creation == nil, !newSessionDraft.isBusy,
      let environment, lifecycle != .stopped
    else { return }
    newSessionDraft.showsIssues = true
    guard newSessionDraft.nameIssue == nil, newSessionDraft.directoryIssue == nil,
      let request = newSessionDraft.request(
        hosts: newSessionHosts, command: environment.newSessionCommand)
    else { return }
    guard let coordinator = coordinator() else {
      newSessionDraft.state = .failed(
        attacherProblem ?? "muxFinder could not prepare opening sessions in iTerm2.")
      return
    }
    newSessionDraft.state = .creating
    nextPanelActionID += 1
    let id = nextPanelActionID
    let sink = actionSink
    let host = request.host
    let directory = request.workingDirectory
    let task = Task {
      let result = await coordinator.createAndAttach(request) { created in
        sink.yield(.sessionCreated(id: id, created, host: host, directory: directory))
      }
      sink.yield(.created(id: id, result, host: host))
    }
    creation = PendingCreation(id: id, task: task)
    logger.info("Session action started: new session")
  } // End of func createSession()

  /// New session `id` created its session on `host` in `directory`, and its attach starts now
  /// (this comes before any of the attach's states). The directory is recorded as one of the
  /// host's recent directories (`recordRecentDirectory(_:for:)`), whatever the attach does
  /// next. From here on the attach is the new session's action, like an Open: its row follows
  /// the coordinator's states ("Opening…", "Waiting for iTerm2…", "Still connecting — check the
  /// iTerm2 tab" with "Show tab") and then the result, clicks on it are ignored while it is
  /// pending, and quitting cancels it. The sheet closes, so the row shows, and the host is
  /// refreshed, so it is listed; another New session can start.
  func sessionCreated(
    _ id: Int, _ created: CreatedSession, on host: HostConfig, directory: String?
  ) {
    recordRecentDirectory(directory, for: host.id)
    guard let pending = creation, pending.id == id else { return }
    creation = nil
    let target = created.attachTarget(on: host)
    let key = target.key
    runningActions[key] = RunningAction(kind: .open, target: target, task: pending.task)
    lastActions[key] = .open
    activities[key] = .opening
    notes[key] = nil
    if newSessionDraft.state == .creating { newSessionDraft.state = .editing }
    if case .newSession = panel {
      panel = nil
      closeDirectoryList()
    }
    refreshHost(host.id)
  } // End of func sessionCreated(_:_:on:directory:)

  /// "Open existing" after a collision: lists the draft's host afresh through the attach
  /// coordinator (`currentSession(named:on:)`), never trusting the popover's list, since the
  /// session tmux reported may be another one than the list shows (the listed one renamed, and
  /// another one given its name), and opens the session with exactly the draft's name in that
  /// listing (`existingFound(_:_:name:on:)`). When none has that name, or the host cannot be
  /// listed, the sheet says so and nothing is opened.
  public func openExisting() {
    guard case .newSession = panel, newSessionDraft.state == .collision, lifecycle != .stopped,
      let hostID = newSessionDraft.hostID, let host = host(withID: hostID),
      let name = try? Validation.sessionName(newSessionDraft.name)
    else { return }
    guard let coordinator = coordinator() else {
      newSessionDraft.state = .failed(
        attacherProblem ?? "muxFinder could not prepare opening sessions in iTerm2.")
      return
    }
    newSessionDraft.state = .findingExisting
    nextPanelActionID += 1
    let id = nextPanelActionID
    let sink = actionSink
    lookups[id] = Task {
      let found = await coordinator.currentSession(named: name, on: host)
      sink.yield(.existingFound(id: id, found, name: name, host: host))
    }
    currentLookupID = id
    logger.info("Session action started: open existing")
  } // End of func openExisting()

  /// "Open existing" number `id` listed `host` afresh: the session named exactly `name` there
  /// is opened (the sheet closes and its row shows the attach, which revalidates it once more);
  /// otherwise the sheet says why nothing was opened: no session has that name any more (it
  /// ended or was renamed; the host is refreshed), or the host could not be listed. A lookup
  /// the sheet no longer waits for (cancelled, or another draft) changes nothing.
  func existingFound(
    _ id: Int,
    _ found: Result<AttachTarget, AttachFailure>,
    name: String,
    on host: HostConfig
  ) {
    lookups[id] = nil
    guard currentLookupID == id else { return }
    currentLookupID = nil
    guard newSessionDraft.state == .findingExisting, case .newSession = panel else { return }
    guard newSessionDraft.hostID == host.id,
      (try? Validation.sessionName(newSessionDraft.name)) == name
    else {
      newSessionDraft.state = .editing
      return
    }
    switch found {
    case .success(let target):
      newSessionDraft.state = .editing
      panel = nil
      selection = target.key
      startAttach(target.key, kind: .open, target: target)
      refreshHost(host.id)
    case .failure(.sessionGone):
      newSessionDraft.state = .failed(NewSessionDraft.existingGone)
      refreshHost(host.id)
    case .failure(let failure):
      newSessionDraft.state = .failed(NewSessionDraft.existingNotListed(failure.message))
    }
  } // End of func existingFound(_:_:name:on:)

  // MARK: - The coordinator and its events

  /// The attach coordinator, built at the first action through
  /// `AppEnvironment.makeAttachCoordinator` (its update handler feeds `actionEvents`). `nil`
  /// for a fixture, without the seam, after `shutdown()`, or when it cannot be built
  /// (`attacherProblem` says why).
  func coordinator() -> AttachCoordinator? {
    if let attacher { return attacher }
    guard lifecycle != .stopped, let factory = environment?.makeAttachCoordinator else {
      return nil
    }
    let sink = actionSink
    do {
      let made = try factory { update in sink.yield(.update(update)) }
      attacher = made
      attacherProblem = nil
      startActionReader()
      return made
    } catch {
      attacherProblem =
        (error as? LocalizedError)?.errorDescription
        ?? "muxFinder could not prepare opening sessions in iTerm2."
      return nil
    }
  } // End of func coordinator()

  /// Starts the one task that reads `actionEvents`, in order.
  func startActionReader() {
    guard actionReader == nil else { return }
    let events = actionEvents
    actionReader = Task { [weak self] in
      for await event in events { self?.handle(event) }
    }
  }

  /// Handles one event from the coordinator or an action.
  func handle(_ event: ActionEvent) {
    switch event {
    case .update(let update): apply(update)
    case .finished(let key, let outcome): finish(key, outcome)
    case .sessionCreated(let id, let created, let host, let directory):
      sessionCreated(id, created, on: host, directory: directory)
    case .created(let id, let result, let host): finishCreation(id, result, on: host)
    case .existingFound(let id, let found, let name, let host):
      existingFound(id, found, name: name, on: host)
    case .barrier(let continuation): continuation.resume()
    }
  } // End of func handle(_:)

  /// A launch's state: the row of a session whose open, move here or New session attach is
  /// pending follows it, except for a failure, which the result shows with its recoveries, and
  /// a focus, which the result shows with how its activation went. Updates of a launch that was
  /// replaced (`isCurrent == false`) and of launches no pending action of this model started
  /// change nothing.
  func apply(_ update: AttachUpdate) {
    guard update.isCurrent, let running = runningActions[update.key], running.kind != .detach
    else { return }
    switch update.state {
    case .failed, .focused: return
    default: break
    }
    activities[update.key] = SessionActivity(update.state, movingHere: running.kind == .moveHere)
  }

  /// An open, move here or detach of `key` ended; a note from "Show tab" goes with it.
  func finish(_ key: SessionKey, _ outcome: SessionActionRecord.Outcome) {
    let running = runningActions.removeValue(forKey: key)
    notes[key] = nil
    record(SessionActionRecord(key: key, outcome: outcome))
    switch outcome {
    case .attach(let result), .moveHere(let result):
      finishAttach(result, target: running?.target)
    case .detached(let result):
      finishDetach(result)
    case .created:
      break
    }
  } // End of func finish(_:_:)

  /// Shows how an attach or a move here of `target` ended. "Confirmed" and "focused" record
  /// the attachment (so Detach is offered); a focus whose activation did not bring the tab
  /// forward shows that problem instead of "Already open here — brought its tab forward"; a
  /// session that vanished or changed gets a banner and its host is refreshed; any other
  /// failure shows its problem and recoveries.
  func finishAttach(_ result: AttachResult, target: AttachTarget?) {
    let key = result.key
    switch result.state {
    case .confirmed(let connectionID), .focused(let connectionID):
      if result.isFocused, let problem = Self.focusProblem(result.activation) {
        activities[key] = .failed(problem)
      } else {
        activities[key] = result.isFocused ? .focused : .confirmed
      }
      if let gateway = result.gatewaySessionID {
        attachedHere[key] = AttachmentRecord(
          connectionID: connectionID, gatewaySessionID: gateway,
          launchID: result.isConfirmed ? result.launchID : nil)
      }
    case .failed(let failure):
      if case .alreadyAttachedHere(let connectionID, let owner) = failure {
        attachedHere[key] = AttachmentRecord(
          connectionID: connectionID, gatewaySessionID: owner, launchID: nil)
      }
      if let kind = SessionBanner.kind(for: failure) {
        activities[key] = nil
        addBanner(kind, key: key, target: target)
        refreshHost(key.hostID)
      } else {
        activities[key] = .failed(.attach(failure, launchTab: result.gatewaySessionID))
      }
    case .requested, .launched, .stillWaiting:
      activities[key] = SessionActivity(result.state)
    }
  } // End of func finishAttach(_:target:)

  /// The problem of a focus whose activation did not bring the tab forward (no tab appeared, or
  /// iTerm2 refused); `nil` when it did.
  static func focusProblem(_ activation: ActivationOutcome?) -> SessionProblem? {
    switch activation {
    case .activated?: return nil
    case .failed(let error)?: return .notBroughtForward(error)
    case .noTab?, nil: return .notBroughtForward(nil)
    }
  }

  /// Shows how a detach ended: "Detached" (the record goes, and the host is refreshed so the
  /// badge follows), or its problem.
  func finishDetach(_ result: SessionDetachResult) {
    let key = result.key
    if result.outcome == .detached || result.outcome == .nothingAttached {
      attachedHere[key] = nil
    }
    if let problem = SessionProblem.detach(result) {
      activities[key] = .failed(problem)
    } else {
      activities[key] = .detached
      refreshHost(key.hostID)
    }
  } // End of func finishDetach(_:)

  /// New session number `id` on `host` ended: a creation failure stays in the sheet (a
  /// collision offers "Open existing"); a created session's attach (its session's action since
  /// `sessionCreated(_:_:on:)`) ends like an Open, on its row.
  func finishCreation(_ id: Int, _ result: CreateAndAttachResult, on host: HostConfig) {
    if creation?.id == id { creation = nil }
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
      return
    }
    guard let created = result.created, let attach = result.attach else { return }
    let running = runningActions.removeValue(forKey: attach.key)
    notes[attach.key] = nil
    lastActions[attach.key] = .open
    finishAttach(attach, target: running?.target ?? created.attachTarget(on: host))
  } // End of func finishCreation(_:_:on:)

  /// Keeps `record` among the latest finished actions and logs its kind (no ids or names).
  func record(_ record: SessionActionRecord) {
    finishedActions.append(record)
    if finishedActions.count > Self.finishedActionLimit {
      finishedActions.removeFirst(finishedActions.count - Self.finishedActionLimit)
    }
    let kind: String
    switch record.outcome {
    case .attach(let result): kind = "open \(result.failure?.kind ?? result.state.kind)"
    case .moveHere(let result): kind = "move here \(result.failure?.kind ?? result.state.kind)"
    case .created(let result):
      kind = "new session \(result.creationFailure?.kind ?? result.attach?.state.kind ?? "?")"
    case .detached(let result): kind = "detach \(result.outcome.rawValue)"
    }
    logger.info("Session action ended: \(kind, privacy: .public)")
  } // End of func record(_:)

  /// Adds a banner for `key` (named as `target` listed it), newest first, keeping
  /// `bannerLimit`.
  func addBanner(_ kind: SessionBanner.Kind, key: SessionKey, target: AttachTarget?) {
    let listed = target ?? self.target(for: key)
    nextBannerID += 1
    banners.insert(
      SessionBanner(
        id: nextBannerID, kind: kind, sessionName: listed?.session.name ?? "A session",
        hostName: listed?.host.displayName ?? host(withID: key.hostID)?.displayName
          ?? "its host"),
      at: 0)
    if banners.count > Self.bannerLimit { banners.removeLast(banners.count - Self.bannerLimit) }
  } // End of func addBanner(_:key:target:)

  /// Cancels every session action in progress (opens, moves, detaches, New session attaches, a
  /// New session being created, "Open existing" lookups, "Show tab" requests) and returns once
  /// each has ended and its result was handled, or once `budget` (if given) has passed: then
  /// it returns the kinds (`ShutdownReport.unfinishedActions`) of the actions still running,
  /// which go on until they end. An attach stops at its next step and withdraws its request (a
  /// `CreateTab` already sent is answered first, D15); a detach waiting for its tab's age sends
  /// nothing. Used by `shutdown()` and the self-tests' cleanup.
  @discardableResult
  public func cancelSessionActions(within budget: Duration? = nil) async -> [String] {
    var pending = runningActions.values.map { (kind: $0.kind.name, task: $0.task) }
    if let creation { pending.append((kind: "new session", task: creation.task)) }
    pending += lookups.values.map { (kind: "open existing", task: $0) }
    pending += showTabTasks.values.map { (kind: "show tab", task: $0) }
    currentLookupID = nil
    for entry in pending { entry.task.cancel() }
    let unfinished = await Self.waitForEnd(of: pending, within: budget)
    await sessionEventsHandled()
    return unfinished
  } // End of func cancelSessionActions(within:)

  /// Waits until every task of `pending` ended, or until `budget` passed; returns the kinds of
  /// those still running then (none without a budget, which waits for all of them).
  static func waitForEnd(
    of pending: [(kind: String, task: Task<Void, Never>)],
    within budget: Duration?
  ) async -> [String] {
    guard let budget else {
      for entry in pending { await entry.task.value }
      return []
    }
    let ended = OSAllocatedUnfairLock(initialState: Set<Int>())
    let all = Task {
      await withTaskGroup(of: Void.self) { group in
        for (index, entry) in pending.enumerated() {
          group.addTask {
            await entry.task.value
            ended.withLock { _ = $0.insert(index) }
          }
        }
      }
    }
    _ = await Self.ends(all, within: budget)
    let done = ended.withLock { $0 }
    return pending.indices.filter { !done.contains($0) }.map { pending[$0].kind }
  } // End of static func waitForEnd(of:within:)

  /// Whether `task` ends within `budget`. It is not cancelled either way.
  static func ends(_ task: Task<Void, Never>, within budget: Duration) async -> Bool {
    await withCheckedContinuation { continuation in
      let once = OSAllocatedUnfairLock<CheckedContinuation<Bool, Never>?>(
        initialState: continuation)
      let resume: @Sendable (Bool) -> Void = { ended in
        once.withLock { pending in
          defer { pending = nil }
          return pending
        }?.resume(returning: ended)
      }
      let timer = Task {
        try? await Task.sleep(for: budget)
        resume(false)
      }
      Task {
        await task.value
        resume(true)
        timer.cancel()
      }
    }
  } // End of static func ends(_:within:)

  /// Returns once every event yielded so far was handled; at once while no reader runs.
  public func sessionEventsHandled() async {
    guard actionReader != nil else { return }
    let sink = actionSink
    await withCheckedContinuation { continuation in
      if case .terminated = sink.yield(.barrier(continuation)) { continuation.resume() }
    }
  }
}
