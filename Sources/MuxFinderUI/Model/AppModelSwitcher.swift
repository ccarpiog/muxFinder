import Foundation
import MuxFinderCore

/// Where an Open or New session attach the session switcher started is (PLAN.md D32).
public enum SwitcherActionState: Sendable, Hashable {
  /// It runs. `closesOnSuccess` holds while the switcher has stayed open since it started:
  /// then its success closes the switcher.
  case running(closesOnSuccess: Bool)
  /// It failed while the switcher showed: its row shows the failure (pinned when the engine
  /// does not list the session) until the switcher closes.
  case failedWhileShown
}

/// The rest of a click sequence whose click activated a session switcher row (PLAN.md D32,
/// Phase I-5). A click activates a row at once, so a quick double click's second click lands
/// on what the first one showed: the New session form (its directory list button, Cancel or
/// Create may sit under the pointer) or the row now opening. The switcher's panel lets the rest
/// of that sequence (presses whose click count is above 1, with their drags and releases)
/// through to no view; the next press starting a sequence of its own (click count 1) ends it.
/// A pure value over the left mouse button's events; `SwitcherWindowTrackingView` applies it
/// to those in the switcher's window (`AppModel.switcherPasses(_:)`).
public struct SwitcherClickSequence: Sendable, Hashable {
  /// A left mouse button event in the switcher's window.
  public enum Event: Sendable, Hashable {
    /// The button went down, the `clickCount`th click of its sequence.
    case press(clickCount: Int)
    /// The pointer moved with the button down.
    case drag
    /// The button went up.
    case release
  }

  /// Whether the rest of the current click sequence is ignored (a click in it activated a row).
  public private(set) var ignoresRest = false
  /// Whether the button is down after an ignored press, so its drags and release are ignored.
  private var holdsIgnoredPress = false

  /// No sequence ignored.
  public init() {}

  /// A click activated a row: the rest of its sequence is ignored.
  public mutating func rowActivated() {
    ignoresRest = true
  }

  /// Whether `event` goes on to the switcher's views, and its effect on the sequence: a press
  /// with a click count of 1 starts a new sequence (passed); a later press of an ignored
  /// sequence is ignored with its drags and its release. Events of a press that was passed
  /// always pass (a row activated by a press keeps its own release).
  public mutating func passes(_ event: Event) -> Bool {
    switch event {
    case .press(let clickCount):
      if clickCount <= 1 { ignoresRest = false }
      holdsIgnoredPress = ignoresRest
      return !ignoresRest
    case .drag:
      return !holdsIgnoredPress
    case .release:
      defer { holdsIgnoredPress = false }
      return !holdsIgnoredPress
    }
  } // End of func passes(_:)
}

/// A New session the switcher started, while its session is being created.
struct SwitcherCreation: Sendable, Hashable {
  /// The creation's number (`AppModel.PendingCreation.id`).
  let id: Int
  /// Whether the switcher has stayed open since it started.
  var closesOnSuccess: Bool
}

/// The session switcher (PLAN.md D32, Phase I-3b): its content, its visibility combined with
/// the popover's for the engine, its keys, and what follows the Open and New session actions it
/// starts.
///
/// - **Opening** (`switcherDidOpen()`): the search field is emptied and focused, the first row
///   selected; an idle New session form goes back to the list (one creating, or showing a
///   failure, stays so its outcome shows); the popover closes; the engine hears of it only when
///   the popover did not show.
/// - **Selection:** the selected row is remembered at each opening, at each change of the
///   filter text and before each engine update while the switcher shows, so a refresh never
///   moves it, or Return's target, to another session (`rememberSwitcherSelection()`).
/// - **Keys** (`handleSwitcherKey(_:)`, `PopoverKey`): in the list, ↑/↓ move without wrapping,
///   Return opens the selected session (the popover's Open, PLAN.md D25) or shows the New
///   session form, ⌘N shows the form, ⌘F focuses the search field, ⌘R refreshes, ⌘, opens
///   Settings and Esc closes the switcher; in the form, the popover's panel keys (Return
///   creates, ⌥↓ opens the directory list, Esc closes the list, then goes back to the list;
///   with the Host picker focused, ↑, ↓ and ⌥↓ are the picker's, `PanelKeyRoute`, Phase I-8).
///   A click activates a row as Return does, as in the popover (`clickSwitcherItem(_:)`), and
///   the rest of that click's sequence is ignored (`SwitcherClickSequence`), the panel held
///   through the double-click interval so that rest lands on it
///   (`SwitcherController.holdForClick()`). Move here and Detach stay in the popover.
/// - **Its actions:** an Open (a New session's attach included) started while the switcher
///   shows is the switcher's (`switcherActions`). Its success closes the switcher if it stayed
///   open since; a failure while it shows stays on its row with the popover row's text and
///   recoveries; a failure once it closed is carried to the top of its next opening
///   (`switcherCarriedFailures`) and stays on the popover row. A pinned row the engine does not
///   list opens (Return, "Try again", "Bring forward") through its retained target on its host
///   as enabled now, or shows that its host is no longer turned on. A New session's creation
///   failure stays in the form, which is put back if the user had left it (once a Move here
///   confirmation outside the switcher ends, or at the switcher's next opening).
extension AppModel {
  // MARK: - Content

  /// What the switcher shows now.
  public var switcherContent: SwitcherContent {
    SwitcherContent(
      state: refreshState,
      hostList: hostListStatus,
      query: switcherSearchText,
      selection: switcherSelection,
      activities: activities,
      now: now,
      notes: notes,
      banners: banners,
      attachedHere: Set(attachedHere.keys),
      carried: switcherCarriedFailures,
      actionKeys: switcherActions.keys.sorted { $0.sessionID.rawValue < $1.sessionID.rawValue },
      targets: switcherTargets)
  } // End of var switcherContent

  /// Whether the switcher shows the New session form (the shared `panel`, PLAN.md D25).
  public var switcherShowsNewSession: Bool {
    if case .newSession? = panel { return true }
    return false
  }

  // MARK: - Visibility

  /// The switcher's panel became visible or hidden (`SwitcherController`).
  public func switcherVisibilityChanged(_ isVisible: Bool) {
    if isVisible { switcherDidOpen() } else { switcherDidClose() }
  }

  /// The switcher opened: the search field is emptied, an idle New session form leaves (one
  /// creating or showing its failure stays), a creation failure a Move here confirmation held
  /// back shows in the form (`showDeferredCreationFailure()`), carried failures that are no
  /// longer failures are forgotten, the first row is selected and remembered, the popover
  /// closes, and unless it showed the engine refreshes now and every 15 s with attachment
  /// checks (PLAN.md D22). No click sequence is ignored. A repeated call while open does
  /// nothing.
  public func switcherDidOpen() {
    guard !isSwitcherVisible else { return }
    let wasListVisible = isSessionListVisible
    isSwitcherVisible = true
    openedSessionList()
    switcherSearchText = ""
    switcherSelection = nil
    switcherClicks = SwitcherClickSequence()
    if switcherShowsNewSession, !newSessionDraft.isBusy, newSessionDraft.state == .editing,
      creation == nil
    {
      cancelPanel()
    }
    showDeferredCreationFailure()
    switcherCarriedFailures.removeAll { activities[$0]?.problem == nil }
    rememberSwitcherSelection()
    if isPopoverVisible { closePopover?() }
    if !wasListVisible { send(.popoverOpened) }
  } // End of func switcherDidOpen()

  /// The switcher closed: its running actions no longer close it on success, the failures it
  /// showed are let go (their rows keep them in the popover), an idle New session form leaves
  /// (so the popover does not open on it), the click sequence followed is forgotten, and unless
  /// the popover shows the engine goes back to the background cadence with no attachment
  /// checks.
  public func switcherDidClose() {
    guard isSwitcherVisible else { return }
    isSwitcherVisible = false
    switcherClicks = SwitcherClickSequence()
    for (key, state) in switcherActions {
      switch state {
      case .running: switcherActions[key] = .running(closesOnSuccess: false)
      case .failedWhileShown: switcherActions[key] = nil
      }
    }
    switcherCreation?.closesOnSuccess = false
    switcherCarriedFailures = []
    forgetUnusedSwitcherTargets()
    if switcherShowsNewSession, !newSessionDraft.isBusy, newSessionDraft.state == .editing,
      creation == nil
    {
      cancelPanel()
    }
    if !isSessionListVisible { send(.popoverClosed) }
  } // End of func switcherDidClose()

  /// ⌘F, each opening, and leaving the form: asks the switcher's search field to take the
  /// focus.
  public func focusSwitcherSearch() {
    switcherFocusRequests += 1
  }

  // MARK: - Keys and intents

  /// Carries out a key in the switcher and says what its window does next (PLAN.md D32). In
  /// the New session form the popover's panel keys apply (`handle(_:)`): Return creates, ⌥↓ and
  /// the directory list's keys as there, Esc closes the directory list, else goes back to the
  /// list (the search field takes the focus again). In the list: ↑/↓ move without wrapping,
  /// Return activates the selected row, Esc closes the switcher, ⌘F focuses the search field,
  /// ⌘R refreshes, ⌘N shows the form, ⌘, opens Settings; ⌥↓ goes on to the focused view.
  public func handleSwitcherKey(_ key: PopoverKey) -> PopoverKeyResult {
    if switcherShowsNewSession {
      let result = handle(key)
      if key == .close, !switcherShowsNewSession { focusSwitcherSearch() }
      return result
    }
    switch key {
    case .up: moveSwitcherSelection(down: false)
    case .down: moveSwitcherSelection(down: true)
    case .open: activateSwitcherItem(switcherContent.selection)
    case .close: return .closePopover
    case .find: focusSwitcherSearch()
    case .refresh: refresh()
    case .newSession: newSessionFromSwitcher()
    case .settings: openSettings()
    case .openList: return .ignored
    }
    return .handled
  } // End of func handleSwitcherKey(_:)

  /// ↓ (`down`) or ↑: the next or previous row, staying at the ends (no wrapping).
  public func moveSwitcherSelection(down: Bool) {
    switcherSelection = switcherContent.item(movingDown: down)
  }

  /// Remembers the row the switcher selects now (`SwitcherContent.selection`: the remembered
  /// item while it is listed, else the first row), so a refresh that inserts or removes
  /// sessions leaves the selection, and Return's target, on that row (PLAN.md D32). Called at
  /// each opening, at each change of the filter text and, while the switcher shows, before
  /// each engine update is applied.
  func rememberSwitcherSelection() {
    switcherSelection = switcherContent.selection
  }

  /// A click on a row (PLAN.md D32, as a click on a popover row): first holds the panel
  /// through the double-click interval (`holdSwitcherForClick`: no shorter than it is now, a
  /// success close waiting), then activates the row at once (`activateSwitcherItem(_:)`, which
  /// selects it first, so the row showing "Opening…" is the one clicked) and ignores the rest
  /// of that click's sequence (`SwitcherClickSequence`), so a quick double click's second click
  /// acts neither on the New session form the first one showed, nor on the row it started
  /// opening, nor on the window behind the panel.
  public func clickSwitcherItem(_ item: SwitcherContent.Item) {
    holdSwitcherForClick?()
    activateSwitcherItem(item)
    switcherClicks.rowActivated()
  }

  /// Whether a left mouse button event in the switcher's window goes on to its views: not
  /// while it belongs to the rest of a click sequence whose click activated a row
  /// (`SwitcherClickSequence.passes(_:)`).
  public func switcherPasses(_ event: SwitcherClickSequence.Event) -> Bool {
    switcherClicks.passes(event)
  }

  /// Return, a click or the accessibility action on a row: it is selected, then a session
  /// opens as from the popover (focused when open in iTerm2 here, else attached, PLAN.md D25;
  /// ignored while an action on it is pending, so a second activation of a row opening starts
  /// nothing) and the New session row shows the form (`newSessionFromSwitcher()`; nothing new
  /// while it shows). Does nothing for `nil`.
  public func activateSwitcherItem(_ item: SwitcherContent.Item?) {
    switch item {
    case .session(let key)?:
      switcherSelection = item
      open(key)
    case .newSession?:
      switcherSelection = item
      newSessionFromSwitcher()
    case nil:
      break
    }
  } // End of func activateSwitcherItem(_:)

  /// The New session row or ⌘N: shows the New session form (`newSession()`: This Mac by
  /// default, the directory list loaded), its name filled in from the filter text when the New
  /// session row offers it. A creation in progress keeps its own draft. Does nothing while the
  /// form shows, so its draft stays as the user left it.
  public func newSessionFromSwitcher() {
    guard !switcherShowsNewSession else { return }
    let prefill = switcherContent.newSession?.prefill
    let wasCreating = creation != nil
    newSession()
    guard switcherShowsNewSession, !wasCreating, let prefill else { return }
    newSessionDraft.name = prefill
  }

  // MARK: - Following the switcher's actions

  /// An open of `key` (`target` as listed) started: the switcher's while it shows.
  func switcherActionStarted(_ key: SessionKey, target: AttachTarget) {
    guard isSwitcherVisible else { return }
    switcherActions[key] = .running(closesOnSuccess: true)
    switcherTargets[key] = target
    switcherCarriedFailures.removeAll { $0 == key }
  }

  /// New session number `id` started creating its session: the switcher's while it shows.
  func switcherCreationStarted(_ id: Int) {
    guard isSwitcherVisible else { return }
    switcherCreation = SwitcherCreation(id: id, closesOnSuccess: true)
  }

  /// New session number `id` created `target`'s session (`key`), whose attach starts now: when
  /// the creation was the switcher's, the attach is too.
  func switcherSessionCreated(_ id: Int, key: SessionKey, target: AttachTarget) {
    guard let pending = switcherCreation, pending.id == id else { return }
    switcherCreation = nil
    switcherActions[key] = .running(closesOnSuccess: pending.closesOnSuccess)
    switcherTargets[key] = target
    switcherCarriedFailures.removeAll { $0 == key }
  }

  /// New session number `id` ended without a session (a collision or a creation failure, in
  /// the draft): when it was the switcher's and the form is no longer shown, the form comes
  /// back with it (`showDeferredCreationFailure()`; held back while the popover shows Move
  /// here), so the failure is never silent.
  func switcherCreationFailed(_ id: Int) {
    guard let pending = switcherCreation, pending.id == id else { return }
    switcherCreation = nil
    if case .newSession? = panel { return }
    switcherCreationFailureDeferred = true
    showDeferredCreationFailure()
  }

  /// Shows the switcher's creation failure the form is not showing yet: the New session form
  /// comes back with it (the draft holds it) when no panel shows, or when the switcher shows
  /// (a Move here confirmation, the popover's, then closes unconfirmed: it runs nothing). A
  /// Move here confirmation outside the switcher holds it back until it ends
  /// (`confirmMoveHere()`, `cancelPanel()`) or the switcher opens next.
  func showDeferredCreationFailure() {
    guard switcherCreationFailureDeferred else { return }
    if case .moveHere? = panel, !isSwitcherVisible { return }
    switcherCreationFailureDeferred = false
    if case .newSession? = panel { return }
    panel = .newSession
  }

  /// The session `key` of a switcher row the engine does not list (a session just created on
  /// a host that has not listed it, say) as an attach target: its retained target
  /// (`switcherTargets`) on its host as the engine has it now, which the coordinator revalidates
  /// before anything opens (PLAN.md D25). `nil` when the switcher retains no target for it;
  /// when its host is no longer turned on, the row shows that failure
  /// (`SessionProblem.hostNotTurnedOn`) and the result is `nil` too, so opening it never does
  /// nothing.
  func pinnedSwitcherTarget(for key: SessionKey) -> AttachTarget? {
    guard let retained = switcherTargets[key] else { return nil }
    guard let host = host(withID: key.hostID) else {
      activities[key] = .failed(.hostNotTurnedOn)
      notes[key] = nil
      return nil
    }
    return AttachTarget(host: host, session: retained.session)
  }

  /// The attach of `key` ended (an Open, or a New session's attach), its outcome in
  /// `activities`: for the switcher's, a success closes the switcher if it stayed open since;
  /// a failure stays on its row while the switcher shows, or is carried to the top of its next
  /// opening once it closed; a session that vanished or changed has its banner; anything else
  /// is left to the row.
  func switcherActionEnded(_ key: SessionKey) {
    guard case .running(let closesOnSuccess)? = switcherActions[key] else { return }
    switch activities[key] {
    case .confirmed?, .focused?:
      forgetSwitcherAction(key)
      if closesOnSuccess, isSwitcherVisible { closeSwitcher?(.actionSucceeded) }
    case .failed?:
      if isSwitcherVisible {
        switcherActions[key] = .failedWhileShown
      } else {
        switcherActions[key] = nil
        switcherCarriedFailures.removeAll { $0 == key }
        switcherCarriedFailures.insert(key, at: 0)
      }
    default:
      forgetSwitcherAction(key)
    }
  } // End of func switcherActionEnded(_:)

  /// Stops following the switcher's action on `key` (its target goes unless it is carried).
  func forgetSwitcherAction(_ key: SessionKey) {
    switcherActions[key] = nil
    if !switcherCarriedFailures.contains(key) { switcherTargets[key] = nil }
  }

  /// Forgets the targets of sessions neither followed nor carried.
  func forgetUnusedSwitcherTargets() {
    for key in switcherTargets.keys
    where switcherActions[key] == nil && !switcherCarriedFailures.contains(key) {
      switcherTargets[key] = nil
    }
  }
}
