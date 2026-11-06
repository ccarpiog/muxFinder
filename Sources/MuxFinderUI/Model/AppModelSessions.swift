import Foundation
import MuxFinderCore
import os

/// The session actions of the popover (PLAN.md D25, D37): Open, "Move here…", "Detach from
/// this Mac", "Detach other clients…", "Show tab", the recoveries a failure offers, and the
/// banners (New session, in its own window, is `AppModelNewSession.swift`, PLAN.md D34).
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
    showPanel(.moveHere(MoveHereRequest(target: target)))
  }

  /// Shows a confirmation in place of the host list and has VoiceOver say its title.
  func showPanel(_ shown: PopoverPanel) {
    panel = shown
    announce?(shown.title)
  }

  /// Return on a confirmation: confirms the one that shows (`confirmMoveHere()` or
  /// `confirmDetachOtherClients()`).
  func confirmPanel() {
    switch panel {
    case .moveHere?: confirmMoveHere()
    case .detachOtherClients?: confirmDetachOtherClients()
    case nil: break
    }
  }

  /// The confirmation's "Move here": the only call that reaches
  /// `AttachCoordinator.moveHere(_:confirmation:)`, with the confirmation naming that session.
  public func confirmMoveHere() {
    guard case .moveHere(let request) = panel else { return }
    panel = nil
    startAttach(request.target.key, kind: .moveHere, target: request.target)
  }

  /// Closes the Move here or Detach other clients confirmation (Cancel, or Esc): it runs
  /// nothing. The New session
  /// window is not the popover's panel and is left as it is (its own Cancel is
  /// `closeNewSession()`, PLAN.md D34).
  public func cancelPanel() {
    panel = nil
  }

  /// Starts an open or a confirmed move here of `key` (`given`, or the listed session, or for
  /// a session switcher row the engine does not list its retained target on its host as
  /// enabled now, `pinnedSwitcherTarget(for:)`). Returns whether it started: not after
  /// `shutdown()`, while an action on `key` is pending, with no target, or with no coordinator
  /// (that problem then shows on the row).
  @discardableResult
  func startAttach(_ key: SessionKey, kind: ActionKind, target given: AttachTarget?) -> Bool {
    guard lifecycle != .stopped, runningActions[key] == nil,
      let target = given ?? target(for: key) ?? pinnedSwitcherTarget(for: key)
    else { return false }
    guard let coordinator = coordinator() else {
      if let attacherProblem { activities[key] = .failed(.unavailable(attacherProblem)) }
      return false
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
    if kind == .open { switcherActionStarted(key, target: target) }
    logger.info("Session action started: \(kind.name, privacy: .public)")
    return true
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

  // MARK: - Detach other clients

  /// The confirmation "Detach other clients…" would show for `key` now, or `nil` when it is not
  /// offered (PLAN.md D37, `SessionRow.offersDetachOtherClients(isLive:clientCount:…)`): the
  /// session listed on its host's live snapshot, shown in this Mac's iTerm2 (the index's
  /// attachments, at least 1 for one in `attachedHere`), with more clients than that. The
  /// counts are the listing's at this time.
  func detachOtherClientsRequest(for key: SessionKey) -> DetachOtherClientsRequest? {
    guard let snapshot = refreshState?.snapshot(of: key.hostID),
      let session = snapshot.sessions.first(where: { $0.key == key })
    else { return nil }
    let here = max(session.attachments.count, attachedHere[key] == nil ? 0 : 1)
    let clients = session.discovered.attachedClientCount
    guard
      SessionRow.offersDetachOtherClients(
        isLive: snapshot.isLive, clientCount: clients, attachmentsHere: here)
    else { return nil }
    return DetachOtherClientsRequest(
      target: AttachTarget(host: snapshot.host, session: session.discovered),
      otherClients: clients - 1, otherClientsHere: here - 1)
  } // End of func detachOtherClientsRequest(for:)

  /// "Detach other clients…": shows the confirmation for `key` (what is detached, that they
  /// may be on other Macs, that the session keeps running, the window-size reason). Nothing
  /// runs until `confirmDetachOtherClients()`. Ignored while an action on the session is
  /// pending, when the offer rule does not hold, for a fixture and after `shutdown()`. Returns
  /// whether it showed.
  @discardableResult
  public func requestDetachOtherClients(_ key: SessionKey) -> Bool {
    guard environment != nil, lifecycle != .stopped, runningActions[key] == nil,
      let request = detachOtherClientsRequest(for: key)
    else { return false }
    showPanel(.detachOtherClients(request))
    return true
  }

  /// The confirmation's "Detach other clients" (or Return): the only call that reaches
  /// `AttachCoordinator.detachOtherClients(of:confirmation:)`, with the confirmation naming the
  /// session the panel names and that session as the target. The row shows "Detaching other
  /// clients…" meanwhile (the call can wait about 20 s for young tabs and clients, D37); clicks
  /// on it are ignored, and `shutdown()` cancels it.
  public func confirmDetachOtherClients() {
    guard case .detachOtherClients(let request) = panel else { return }
    panel = nil
    let target = request.target
    let key = target.key
    guard lifecycle != .stopped, runningActions[key] == nil else { return }
    guard let coordinator = coordinator() else {
      if let attacherProblem { activities[key] = .failed(.unavailable(attacherProblem)) }
      return
    }
    lastActions[key] = .detachOtherClients
    activities[key] = .detachingOtherClients
    notes[key] = nil
    let sink = actionSink
    let task = Task {
      let result = await coordinator.detachOtherClients(
        of: target, confirmation: .detachOtherClients(of: key))
      sink.yield(.finished(key, .detachedOtherClients(result)))
    }
    runningActions[key] = RunningAction(kind: .detachOtherClients, target: target, task: task)
    logger.info("Session action started: detach other clients")
  } // End of func confirmDetachOtherClients()

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

  /// The sessions whose "Try again" would show a confirmation that only the popover draws:
  /// their last action was a move here or a "Detach other clients…" (PLAN.md D25, D32, D37).
  /// The session switcher offers their failures' other recoveries only (`SwitcherContent`).
  var retriesConfirmedInPopover: Set<SessionKey> {
    Set(lastActions.compactMap { $0.value.confirmsInPopover ? $0.key : nil })
  }

  /// Whether the popover is the one showing (open, and the session switcher not), so a
  /// confirmation it draws is seen.
  var isPopoverShowing: Bool { isPopoverVisible && !isSwitcherVisible }

  /// "Try again" on a session's failure: repeats its last action (a move here and a "Detach
  /// other clients…" show their confirmation again; one no longer offered refreshes the host);
  /// with none, clears the failure and refreshes the session's host. Those two confirmations
  /// are drawn only in the popover (PLAN.md D25, D32, D37), so while the popover is not the one
  /// showing their retry changes nothing (the failure stays, no confirmation is set to wait
  /// hidden); the switcher does not offer it for them.
  public func retry(session key: SessionKey) {
    guard runningActions[key] == nil else { return }
    let last = lastActions[key]
    if last?.confirmsInPopover == true, !isPopoverShowing { return }
    activities[key] = nil
    notes[key] = nil
    switch last {
    case .open?: open(key)
    case .moveHere?: requestMoveHere(key)
    case .detach?: detach(key)
    case .detachOtherClients?:
      // Its confirmation again; the host's listing decides whether it is still offered.
      if !requestDetachOtherClients(key) { refreshHost(key.hostID) }
    case nil: refreshHost(key.hostID)
    }
  } // End of func retry(session:)

  /// Removes a banner.
  public func dismissBanner(_ id: Int) {
    banners.removeAll { $0.id == id }
  }

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
    guard update.isCurrent, let running = runningActions[update.key],
      running.kind.followsLaunchStates
    else { return }
    switch update.state {
    case .failed, .focused: return
    default: break
    }
    activities[update.key] = SessionActivity(update.state, movingHere: running.kind == .moveHere)
  }

  /// An open, move here, detach or "Detach other clients…" of `key` ended; a note from "Show
  /// tab" goes with it.
  func finish(_ key: SessionKey, _ outcome: SessionActionRecord.Outcome) {
    let running = runningActions.removeValue(forKey: key)
    notes[key] = nil
    record(SessionActionRecord(key: key, outcome: outcome))
    switch outcome {
    case .attach(let result), .moveHere(let result):
      finishAttach(result, target: running?.target)
    case .detached(let result):
      finishDetach(result)
    case .detachedOtherClients(let result):
      finishDetachOtherClients(result)
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
    case .requested, .launched, .stillWaiting, .plainLaunched, .plainStillWaiting:
      activities[key] = SessionActivity(result.state)
    case .plainConfirmed, .plainFocused:
      // The plain backend (PLAN.md D38), as its iTerm2 counterpart until Phase I-12c3 records
      // its attachment here.
      activities[key] = result.isFocused ? .focused : .confirmed
    }
    switcherActionEnded(key)
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

  /// What the row shows after a "Detach other clients…" that ended `result` (PLAN.md D37):
  /// "Detached <n> other client(s) — the session keeps running" (with how many had already
  /// left), "No other clients to detach — they had already left", or the problem
  /// (`SessionProblem.detachOtherClients(_:)`); `nil` for a cancelled one, which shows nothing.
  static func activity(after result: DetachOtherClientsResult) -> SessionActivity? {
    switch result.outcome {
    case .detached(let count):
      return .detachedOtherClients(count: count, alreadyLeft: result.goneBeforeDetach)
    case .nothingToDetach:
      return .noOtherClientsLeft
    case .cancelled:
      return nil
    default:
      return SessionProblem.detachOtherClients(result).map(SessionActivity.failed)
    }
  } // End of static func activity(after:)

  /// Shows how a "Detach other clients…" ended (`activity(after:)`) and refreshes its host
  /// afterwards, so `clientCount` and the offer follow, for every outcome but `cancelled` and
  /// `notConfirmed`. "Not attached here" also forgets the attachment muxFinder recorded.
  func finishDetachOtherClients(_ result: DetachOtherClientsResult) {
    let key = result.key
    activities[key] = Self.activity(after: result)
    switch result.outcome {
    case .cancelled, .notConfirmed:
      return
    case .notAttachedHere:
      attachedHere[key] = nil
    default:
      break
    }
    refreshHost(key.hostID)
  } // End of func finishDetachOtherClients(_:)

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
    case .detachedOtherClients(let result): kind = "detach other clients \(result.outcome.kind)"
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

  /// Cancels every session action in progress (opens, moves, detaches, "Detach other clients…"
  /// calls, New session attaches, a New session being created, "Open existing" lookups, "Show
  /// tab" requests) and returns once each has ended and its result was handled, or once
  /// `budget` (if given) has passed: then it returns the kinds
  /// (`ShutdownReport.unfinishedActions`) of the actions still running, which go on until they
  /// end. An attach stops at its next step and withdraws its request (a `CreateTab` already
  /// sent is answered first, D15); a detach waiting for its tab's age, and a "Detach other
  /// clients…" waiting for young tabs or clients, send nothing. Used by `shutdown()` and the
  /// self-tests' cleanup.
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
