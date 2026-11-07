import Foundation
import MuxFinderCore
import Observation
import os

/// The popover's model (PLAN.md Phase 8, D22): it owns the refresh engine, mirrors its
/// published state on the main actor, and turns the popover's clicks and keys into engine
/// requests.
///
/// - **Start:** `start()` resolves the terminal setting (PLAN.md D38, `AppModelTerminal.swift`),
///   loads the host list (never writing it), builds the engine for it (its attachment checks
///   off unless iTerm2 is the chosen terminal), subscribes to `RefreshCoordinator.updates()`,
///   starts the sleep/wake/network adapter and then the engine's cadence. Nothing contacts
///   iTerm2 at start. With `AppEnvironment.rewritesProfilesAtLaunch` (normal mode only), a list
///   loaded as `saved` and iTerm2 chosen, Settings brings an installed, out-of-date persistent
///   profile file up to date in the background (`SettingsModel.keepProfilesCurrentAtLaunch(_:)`,
///   PLAN.md D26).
/// - **Popover and switcher:** `popoverDidOpen()` / `popoverDidClose()` and the session
///   switcher's `switcherDidOpen()` / `switcherDidClose()` tell the engine, which refreshes at
///   once and every 15 s while either one is visible and runs attachment checks only then
///   (D20, D22). The two visibilities are combined: `.popoverOpened` and `.popoverClosed` are
///   each sent once whenever "either one is visible" changes, and opening one closes the other
///   (`closeSwitcher`, `closePopover`). Those checks are the only reason the popover or the
///   switcher contacts iTerm2, and requests its cookie, on its own (a click on "Set up SSH in
///   iTerm2 first" does too, D24). Closing the last one cancels the check in progress, so no
///   iTerm2 contact starts once neither shows.
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
/// - **Session actions** (PLAN.md D25, D37, D38, `AppModelSessions.swift`): Open (a click or
///   Return), "Move here…" and "Detach other clients…" (each after the user confirms its
///   dialog), "Detach from this Mac", New session and "Show tab" run on the chosen terminal's
///   `TerminalBackend`, which `AppEnvironment.makeTerminalBackend` builds at the first action
///   and the model keeps per terminal id (iTerm2's is `ITerm2TerminalBackend` over the attach
///   coordinator, so with iTerm2 chosen every behaviour is as before). An unavailable choice
///   ends every action in its own failure, nothing written, launched or sent
///   (`SessionProblem.terminalUnavailable(_:)`). Each session has at most one action at a time:
///   clicks while
///   one is pending are ignored (a New session's attach is its session's action from the moment
///   the session was created). The backends' updates and each action's result reach the
///   model through one ordered stream, so the row's activity follows the core's states and
///   "Confirmed" appears only once the core confirmed the attachment. A session that vanished or
///   changed meanwhile gets a banner and its host is refreshed.
/// - **Terminal setting** (PLAN.md D38, Phase I-12c3a; `AppModelTerminal.swift`): resolved at
///   launch and through one setter (`setTerminal(_:)`); a change while a session action is
///   pending is applied once none is. Every iTerm2 contact follows the choice: the engine's
///   attachment checks, Settings' profile list and iTerm2 problem, "Set up SSH in iTerm2…" (the
///   popover's, Settings' and onboarding's) and D26's rewrite run only while iTerm2 is chosen.
/// - **Session switcher shortcut** (PLAN.md D32): `shortcut` loads `preferences.json` and
///   registers the saved hotkey at the start of `start()` (normal mode only: without
///   `AppEnvironment.globalShortcut` nothing is read or registered), and `shutdown()`
///   unregisters it. Its press reaches one entry point, `globalShortcutPressed()`, which
///   toggles the session switcher through `toggleSwitcher` (`SwitcherController.toggle()`, set
///   by `SessionSwitcher`).
/// - **Session switcher** (PLAN.md D32, Phase I-3b; `AppModelSwitcher.swift`): its search text,
///   selection and content (`switcherContent`), its keys (`handleSwitcherKey(_:)`), the Open
///   actions it started and the creations of New session drafts it made (it closes when one
///   succeeds while it shows, and a failure that arrives once it closed shows at the top of its
///   next opening and on the popover row).
/// - **New session window** (PLAN.md D34; `AppModelNewSession.swift`): its draft, whether it
///   shows and the latest request to show it (`newSessionWindow`, which the app shell's
///   `NewSessionWindowController` follows), its keys (`handleNewSessionKey(_:)`), the creation
///   and "Open existing". The popover and the switcher open it and close as it opens; opening
///   and closing them never touches it.
/// - **Folder search** (PLAN.md D36, Phase I-10b; `AppModelFolderSearch.swift`): the directory
///   list's "Folders on <host>" section runs on one `FolderSearchChannel` per window and host,
///   owned here, closed with the window, a host change, a quiet minute and quitting.
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
    /// The popover or the session switcher became visible while neither was.
    case popoverOpened
    /// The last visible one of the popover and the session switcher closed.
    case popoverClosed
    /// Refresh every host ("Refresh").
    case refreshAll
    /// Refresh one host ("Retry").
    case refresh(UUID)
    /// Settings saved a new host list.
    case setHosts(HostList)
    /// The terminal choice changed: D16's attachment checks on (iTerm2 chosen) or off (PLAN.md
    /// D38, Phase I-12c3a).
    case setAttachmentChecks(Bool)
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
    /// A confirmed "Detach other clients…" (PLAN.md D37).
    case detachOtherClients
    /// "Detach (opened in <terminal>)": a detach through the backend of the terminal id, which
    /// was not the chosen one when it was offered; "Try again" repeats it there even once that
    /// terminal is the chosen one (PLAN.md D38 *The UI (I-12d2)*).
    case detachOpenedIn(String)

    /// Its name in the log and in `ShutdownReport`.
    var name: String {
      switch self {
      case .open: return "open"
      case .moveHere: return "move here"
      case .detach, .detachOpenedIn: return "detach"
      case .detachOtherClients: return "detach other clients"
      }
    }

    /// Whether the coordinator publishes launch states for it (an open or a move here); the
    /// detaches publish none, so an update never changes their rows.
    var followsLaunchStates: Bool { self == .open || self == .moveHere }

    /// Whether repeating it ("Try again") shows a confirmation first, which only the popover
    /// draws (a move here or a "Detach other clients…"; PLAN.md D25, D32, D37).
    var confirmsInPopover: Bool { self == .moveHere || self == .detachOtherClients }
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
    /// The terminal id of the backend it runs on (`ChosenTerminal.id`): whose records its
    /// result changes (PLAN.md D38, Phase I-12c3a review fix).
    var terminalID: String?
  }

  /// What reaches the model from the coordinator and the actions, in order.
  enum ActionEvent: Sendable {
    /// A state update of a launch (published by the coordinator).
    case update(AttachUpdate)
    /// An open, move here, detach or "Detach other clients…" ended; `heldBy` is the terminal
    /// id of another backend whose launch refused an open or a move here
    /// (`earlierLaunchPending`, PLAN.md D38 *The UI (I-12d2)*).
    case finished(SessionKey, SessionActionRecord.Outcome, heldBy: String? = nil)
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
    /// The task awaiting the backend's `createAndAttach(_:onCreated:)`.
    let task: Task<Void, Never>
    /// The terminal id of the backend it runs on (`ChosenTerminal.id`).
    var terminalID: String?
  }

  /// How many finished actions `finishedActions` keeps.
  static let finishedActionLimit = 32
  /// How many banners are shown at most (the newest first).
  static let bannerLimit = 3
  /// How many visibility changes `engineVisibilityChanges` keeps.
  static let visibilityLogLimit = 32
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
  /// The popover's Move here or Detach other clients confirmation, while shown (New session
  /// has its own window, `newSessionWindow`, PLAN.md D34). While one shows, the popover shows
  /// no update notice (`updateNoticeVisibility()`).
  public internal(set) var panel: PopoverPanel? {
    didSet { updateNoticeVisibility() }
  }
  /// The New session window as the model has it (PLAN.md D34): whether it shows and the latest
  /// request to show it or bring it forward. Each change reaches `newSessionWindowChanged`; the
  /// window's closing, whatever closed it, also ends its folder search (`newSessionWindowClosed()`).
  public internal(set) var newSessionWindow = NewSessionWindowState() {
    didSet {
      if oldValue.isShown, !newSessionWindow.isShown { newSessionWindowClosed() }
      newSessionWindowChanged?()
    }
  }
  /// The New session form's fields and state. Any change to the Directory field's text (byte
  /// for byte: typing, pasting, a pick) drops the directory list's highlight, so Return then
  /// creates from what the field holds; a user edit (not a pick, a host change or a reset) also
  /// opens or closes the list as its filter matches (`directoryFieldChanged(from:)`, PLAN.md
  /// D31). A host change ends the folder search on the old host (`newSessionHostChanged()`).
  /// While an update installs (`isInstallingUpdate`, PLAN.md D39) a change of the host, name
  /// or directory is refused: the draft keeps its value.
  public var newSessionDraft = NewSessionDraft() {
    didSet {
      guard !isRefusingDraftEdit else { return }
      if isInstallingUpdate, newSessionDraft.editedFields(differFrom: oldValue) {
        isRefusingDraftEdit = true
        newSessionDraft = oldValue
        isRefusingDraftEdit = false
        return
      }
      directoryFieldChanged(from: oldValue.directory)
      if oldValue.hostID != newSessionDraft.hostID { newSessionHostChanged() }
    }
  }
  /// Whether `newSessionDraft`'s observer is putting refused fields back (no other reaction).
  @ObservationIgnored private var isRefusingDraftEdit = false
  /// Increases whenever the New session window's Name field should take the keyboard focus
  /// (each fresh opening, PLAN.md D34).
  public internal(set) var newSessionFocusRequests = 0
  /// New session's directory lists as last loaded or changed (PLAN.md D31); empty until the
  /// window first opens.
  public internal(set) var directoryLists = DirectoryLists()
  /// How the directory lists last loaded.
  public internal(set) var directoryStatus = DirectoryListStatus.notLoaded
  /// New session's directory list: open or closed and how it was opened, the highlighted row,
  /// the last problem.
  public internal(set) var directoryPicker = DirectoryPickerState()
  /// Whether a drag that would fill the Directory field (one folder from Finder) hovers over
  /// its row, so the field shows the drop highlight (PLAN.md D34, Phase I-9b).
  public internal(set) var isDirectoryDropTargeted = false
  /// The latest state the New session window's folder search channel published (PLAN.md D36,
  /// Phase I-10b); `nil` while the window has none. In memory only.
  public internal(set) var folderSearchState: FolderSearchState?
  /// The latest folder search answer of the window's channel, kept while a newer text is
  /// searched; in memory only.
  public internal(set) var folderSearchPrevious: FolderSearchPreviousAnswer?
  /// Whether the folders section shows its "Missing a folder?" explanation.
  public internal(set) var isFolderSearchHelpShown = false
  /// Attachments in this Mac's iTerm2 that muxFinder made or found, by session.
  public internal(set) var attachedHere: [SessionKey: AttachmentRecord] = [:]
  /// The latest actions that ended, oldest first (at most `finishedActionLimit`).
  public internal(set) var finishedActions: [SessionActionRecord] = []
  /// The time relative times are measured against: updated with every engine state and when
  /// the popover opens.
  public private(set) var now: Date
  /// Whether the popover is open.
  public private(set) var isPopoverVisible = false
  /// Whether the session switcher is open (PLAN.md D32).
  public internal(set) var isSwitcherVisible = false
  /// The session switcher's search text: emptied at each opening; typing selects the first row
  /// again, as Spotlight does, and remembers it (`rememberSwitcherSelection()`).
  public var switcherSearchText = "" {
    didSet {
      guard switcherSearchText != oldValue else { return }
      switcherSelection = nil
      rememberSwitcherSelection()
    }
  }
  /// The session switcher's keyboard selection; `nil`, or an item no longer listed, means the
  /// first row (`SwitcherContent`). The row selected is remembered here at each opening, each
  /// change of the filter text and before each engine update while the switcher shows, so a
  /// refresh keeps it on its session.
  public var switcherSelection: SwitcherContent.Item?
  /// Increases whenever the switcher's search field should take the keyboard focus (each
  /// opening, ⌘F).
  public internal(set) var switcherFocusRequests = 0
  /// The Open attaches the switcher started and the attaches of sessions created from New
  /// session drafts it made or opened from them with "Open existing", by session: running, or
  /// failed while it showed
  /// (`SwitcherActionState`). Their sessions are pinned at the top while the engine does not
  /// list them.
  public internal(set) var switcherActions: [SessionKey: SwitcherActionState] = [:]
  /// Sessions whose switcher action failed after the switcher closed, newest first: shown at the
  /// top of its next opening, then forgotten when it closes (the popover row keeps the failure).
  public internal(set) var switcherCarriedFailures: [SessionKey] = []
  /// The sessions of the switcher's actions as listed when they started (or as created), for
  /// the rows of sessions the engine does not list.
  public internal(set) var switcherTargets: [SessionKey: AttachTarget] = [:]
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
  /// The terminal picker Settings › General and onboarding's Terminal step share (PLAN.md D38,
  /// Phase I-12d1): kept current by `setTerminalGates(_:)`, choosing through `setTerminal(_:)`;
  /// inert for a fixture or without `AppEnvironment.terminal`.
  public let terminalPicker: TerminalPickerModel
  /// The session switcher shortcut (PLAN.md D32; inert without
  /// `AppEnvironment.globalShortcut`). Settings › General shows the same model.
  public let shortcut: GlobalShortcutModel
  /// The update check's notice, dot and Settings section (PLAN.md D39 *The notice (I-13c1)*):
  /// live over `AppEnvironment.update` (normal mode only), a fixture's in the galleries, inert
  /// otherwise (nothing shown, nothing run).
  public let update: UpdateModel
  /// What the session switcher shortcut does: toggles the switcher (`SwitcherController.make`
  /// sets it to `SwitcherController.toggle()`); `nil` does nothing.
  @ObservationIgnored public var toggleSwitcher: (@MainActor () -> Void)?
  /// Closes the switcher for a reason (the popover opened, an action it started succeeded);
  /// set by `SwitcherController.make`.
  @ObservationIgnored public var closeSwitcher:
    (@MainActor (SwitcherController.CloseReason) -> Void)?
  /// Holds the switcher's panel through a click's double-click interval
  /// (`SwitcherController.holdForClick()`), called by `clickSwitcherItem(_:)` before the row
  /// acts; set by `SwitcherController.make`.
  @ObservationIgnored public var holdSwitcherForClick: (@MainActor () -> Void)?
  /// Closes the popover for a reason (the switcher opened, the New session window opened); set
  /// by `MenuBarPopover`.
  @ObservationIgnored public var closePopover: (@MainActor (PopoverController.CloseReason) -> Void)?
  /// Where the open popover is, for placing the New session window it opens (PLAN.md D34); set
  /// by `MenuBarPopover` (`PopoverController.newSessionSource`). `nil` answers none.
  @ObservationIgnored public var popoverSource: (@MainActor () -> NewSessionWindowSource?)?
  /// Where the open switcher is, for placing the New session window it opens (PLAN.md D34);
  /// set by `SwitcherController.make` (`SwitcherController.newSessionSource`).
  @ObservationIgnored public var switcherSource: (@MainActor () -> NewSessionWindowSource?)?
  /// Told after each change of `newSessionWindow`; set by `NewSessionWindowController.make` (the
  /// app shell's window). `nil` (the self-tests, previews, tests of the model) shows nothing.
  @ObservationIgnored public var newSessionWindowChanged: (@MainActor () -> Void)?
  /// Whether a mouse press on muxFinder's status item button is in progress now; set by
  /// `MenuBarPopover` (`PopoverController.isButtonPressHeld`). The switcher leaves a close from
  /// outside made by that press to the popover the press opens, so the handoff keeps one of
  /// the two visible for the engine (PLAN.md D22, D32). `nil` answers no.
  @ObservationIgnored public var isStatusItemPressHeld: (@MainActor () -> Bool)?
  /// The creation of a New session draft the switcher made, while its session is being created.
  @ObservationIgnored var switcherCreation: SwitcherCreation?
  /// Which entry point made the New session draft (PLAN.md D34): a creation from a draft the
  /// switcher made is the switcher's to follow (`switcherCreationStarted(_:)`), as is the attach
  /// its "Open existing" starts (`switcherExistingOpened(_:target:)`).
  @ObservationIgnored var newSessionOrigin: NewSessionOrigin?
  /// Numbers the New session window's requests (`showNewSessionWindow(_:)`).
  @ObservationIgnored var nextNewSessionWindowRequest = 0
  /// The rest of the click sequence whose click activated a switcher row, which the switcher's
  /// panel lets through to no view (`clickSwitcherItem(_:)`, `switcherPasses(_:)`).
  @ObservationIgnored var switcherClicks = SwitcherClickSequence()
  /// The rest of the click sequence in progress when the New session window was last opened
  /// (a double click on the switcher's New session row or the popover's button, say), which
  /// the window lets through to no view (`newSessionWindowPasses(_:)`, PLAN.md D34).
  @ObservationIgnored var newSessionClicks = SwitcherClickSequence()
  /// The visibility changes handed to the engine's queue, oldest first (the latest
  /// `visibilityLogLimit`; tests read them).
  @ObservationIgnored private(set) var engineVisibilityChanges: [Bool] = []

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
  /// The terminal setting as last resolved (PLAN.md D38, Phase I-12c3a): `unresolved` until
  /// `start()` resolves it (so nothing contacts iTerm2 before the stored choice is known), and
  /// always iTerm2 without `AppEnvironment.terminal` (a fixture's is its own, PLAN.md D38 *The
  /// UI (I-12d2)*).
  public internal(set) var terminalChoice = TerminalChoiceResolution.iTerm2
  /// A resolved change of the setting waiting for the pending session actions to end
  /// (`setTerminal(_:)`); `nil` when none waits.
  public internal(set) var pendingTerminalChoice: TerminalChoiceResolution?
  /// The terminal definitions as loaded at launch, with their problems (the picker shows them;
  /// their names word the rows); `nil` before, and without `AppEnvironment.terminal` (a
  /// fixture's are its own).
  public internal(set) var terminalDefinitions: TerminalDefinitionCatalog?
  /// The stored terminal setting as last read or set (`nil`: absent, so the default).
  @ObservationIgnored var storedTerminal: String?
  /// The terminal backends built so far, by terminal id (`ChosenTerminal.id`); each is built
  /// at the first action that needs it and kept for the model's life.
  @ObservationIgnored var backends: [String: any TerminalBackend] = [:]
  /// Why the last session action could not get a backend (the choice is unavailable, or the
  /// backend could not be built); `nil` when it got one or none was asked for.
  @ObservationIgnored var backendProblem: SessionProblem?
  /// Each backend's records, by terminal id (`ChosenTerminal.id`) and session (PLAN.md D38,
  /// Phase I-12c3a review fix): a plain backend's attachment (its window, confirmed or brought
  /// forward) or the app a session was found open in on this Mac. Only plain results set it; a
  /// result changes only the records of the backend it ran on, so a backend's records stay its
  /// own across a change of terminal (reachable again once it is chosen again).
  public internal(set) var terminalAttachmentsByTerminal:
    [String: [SessionKey: TerminalAttachmentHandle]] = [:]
  /// The host list as last loaded as `saved` or saved since: what D26's rewrite uses when
  /// iTerm2 becomes the chosen terminal again (`nil` while the list is not known to be saved).
  @ObservationIgnored var savedHosts: HostList?
  /// The action in progress per session.
  @ObservationIgnored var runningActions: [SessionKey: RunningAction] = [:]
  /// The New session whose session is being created.
  @ObservationIgnored var creation: PendingCreation?
  /// "Open existing" lookups (the backend's `currentSession(named:on:)`) that have not
  /// ended, by number; a cancelled one stays until it ended, so quitting waits for its probe.
  @ObservationIgnored var lookups: [Int: Task<Void, Never>] = [:]
  /// The lookup the New session window waits for, if any.
  @ObservationIgnored var currentLookupID: Int?
  /// Numbers New sessions and "Open existing" lookups.
  @ObservationIgnored var nextPanelActionID = 0
  /// "Show tab" requests in progress.
  @ObservationIgnored var showTabTasks: [Int: Task<Void, Never>] = [:]
  /// Numbers the "Show tab" requests.
  @ObservationIgnored var nextShowTabID = 0
  /// The last action per session, which "Try again" repeats.
  @ObservationIgnored var lastActions: [SessionKey: ActionKind] = [:]
  /// The terminal id of the backend that ran each session's last "Detach from this Mac", so its
  /// "Try again" repeats it there once another terminal is chosen (PLAN.md D38 *The UI
  /// (I-12d2)*, review fix).
  @ObservationIgnored var lastDetachTerminalIDs: [SessionKey: String] = [:]
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
  /// This Mac's home folder for the directory list's `~` rule (PLAN.md D31): the environment's
  /// (`AppEnvironment.homeDirectory`) or the fixture's; `nil` matches entries only as stored.
  let thisMacHome: String?
  /// Speaks a VoiceOver announcement (the directory list's match count, PLAN.md D31; the
  /// update notice's failure and ask, D39, through `UpdateModel.announce`):
  /// `AppEnvironment.announce`, `nil` (nothing said) for a fixture; tests record through it.
  @ObservationIgnored var announce: (@MainActor @Sendable (String) -> Void)?
  /// Whether the model itself is filling the Directory field (a pick), so the change is not
  /// taken for the user's edit (`fillDirectoryField(_:)`).
  @ObservationIgnored var isFillingDirectoryField = false
  /// Whether this fixture shows a folders section (`PreviewFixture.folderSearch`).
  @ObservationIgnored let showsFolderSearchFixture: Bool
  /// The New session window's folder search on its host, while it has one (PLAN.md D36, Phase
  /// I-10b).
  @ObservationIgnored var folderSearchSession: FolderSearchSession?
  /// Numbers the folder search sessions.
  @ObservationIgnored var nextFolderSearchSessionID = 0
  /// The text the current session was last asked to search, as typed; `nil` once told to stop.
  @ObservationIgnored var folderSearchAsked: String?
  /// Closings of folder search sessions still running, by session number; quitting waits for
  /// them.
  @ObservationIgnored var folderSearchClosings: [Int: Task<Void, Never>] = [:]
  /// What VoiceOver last heard of the folders section.
  @ObservationIgnored var lastFolderAnnouncement = FolderSearchAnnouncement.hidden

  /// A model over `environment`. Nothing runs until `start()`.
  public init(environment: AppEnvironment) {
    self.environment = environment
    isPreview = false
    now = environment.now()
    thisMacHome = environment.homeDirectory
    announce = environment.announce
    showsFolderSearchFixture = false
    settings =
      environment.settings.map { SettingsModel(environment: $0) }
      ?? SettingsModel(fixture: SettingsFixtures.blank)
    onboarding =
      environment.settings.map {
        OnboardingModel(
          environment: OnboardingEnvironment(
            store: $0.store, sshSetup: $0.sshSetup, plainSSHSetup: $0.plainSSHSetup,
            diagnostics: $0.diagnostics))
      } ?? OnboardingModel(fixture: OnboardingFixtures.blank)
    sshSetup = SSHSetupActions(
      opener: environment.settings?.sshSetup, plainOpener: environment.settings?.plainSSHSetup)
    terminalPicker =
      environment.terminal.map { terminal in
        TerminalPickerModel(
          inspector: terminal.inspector,
          openURL: environment.settings?.openURL ?? environment.openURL)
      } ?? .inert()
    shortcut = GlobalShortcutModel(
      environment: environment.globalShortcut, diagnostics: environment.diagnostics)
    update = environment.update.map { UpdateModel(environment: $0) } ?? .inert()
    (commands, commandSink) = AsyncStream.makeStream(of: EngineCommand.self)
    (actionEvents, actionSink) = AsyncStream.makeStream(of: ActionEvent.self)
    settings.globalShortcut = shortcut
    settings.update = update
    update.flow.unsavedWork = { [weak self] in self?.unsavedWorkForUpdate() ?? .none }
    update.announce = { [weak self] text in self?.announce?(text) }
    shortcut.onPress = { [weak self] in self?.globalShortcutPressed() }
    settings.onHostListSaved = { [weak self] list in self?.hostListSaved(list) }
    settings.onDirectoriesSaved = { [weak self] lists in
      self?.directoriesChanged(lists, tellingSettings: false)
    }
    onboarding.onHostListSaved = { [weak self] list in self?.hostListSaved(list) }
    onboarding.onOpenSettings = { [weak self] in self?.openSettings() }
    settings.terminalPicker = terminalPicker
    onboarding.terminalPicker = terminalPicker
    terminalPicker.setter = { [weak self] id in await self?.setTerminal(id) }
    terminalPicker.didRead = { [weak self] in self?.resolveTerminalAgain() }
    // Not resolved until `start()` has read the setting: Settings (the menu shows it before the
    // model starts), onboarding and "Set up SSH in iTerm2…" contact no iTerm2 meanwhile.
    if environment.terminal != nil { setTerminalGates(.unresolved) }
  } // End of init(environment:)

  /// A model that renders `fixture` and never runs anything.
  public init(fixture: PreviewFixture) {
    environment = nil
    isPreview = true
    now = fixture.now
    thisMacHome = fixture.homeDirectory
    refreshState = fixture.state
    hostListStatus = fixture.hostList
    searchText = fixture.searchText
    selection = fixture.selection
    activities = fixture.activities
    notes = fixture.notes
    banners = fixture.banners
    panel = fixture.panel
    newSessionWindow = NewSessionWindowState(isShown: fixture.showsNewSession)
    newSessionDraft = fixture.newSessionDraft
    directoryLists = fixture.directoryLists
    directoryStatus = fixture.directoryStatus
    directoryPicker = fixture.directoryPicker
    isDirectoryDropTargeted = fixture.directoryDropTargeted
    showsFolderSearchFixture = fixture.folderSearch != nil
    folderSearchState = fixture.folderSearch?.state
    folderSearchPrevious = fixture.folderSearch?.previous
    isFolderSearchHelpShown = fixture.folderSearchHelpShown
    attachedHere = fixture.attachedHere
    terminalChoice = fixture.terminal
    terminalDefinitions = fixture.terminalDefinitions
    terminalAttachmentsByTerminal = fixture.terminalAttachments
    shownExplanation = fixture.shownExplanation
    switcherSearchText = fixture.switcherSearchText
    switcherSelection = fixture.switcherSelection
    switcherCarriedFailures = fixture.switcherCarriedFailures
    settings = SettingsModel(fixture: SettingsFixtures.blank)
    onboarding = OnboardingModel(fixture: OnboardingFixtures.blank)
    sshSetup = SSHSetupActions(opener: nil, states: fixture.sshSetupStates)
    terminalPicker = .inert()
    shortcut = GlobalShortcutModel(fixture: GlobalShortcutFixture())
    update = fixture.update.map { UpdateModel(fixture: $0) } ?? .inert()
    (commands, commandSink) = AsyncStream.makeStream(of: EngineCommand.self)
    commandSink.finish()
    (actionEvents, actionSink) = AsyncStream.makeStream(of: ActionEvent.self)
    actionSink.finish()
  } // End of init(fixture:)

  // MARK: - Content

  /// What the popover shows now: with the chosen plain terminal's windows, the apps of local
  /// attachments named from the loaded definitions, other terminals' records and the chosen
  /// terminal's wording (PLAN.md D38 *The UI (I-12d2)*; all empty or iTerm2's with iTerm2
  /// chosen and no other backend's records).
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
      attachedHere: Set(selectedAttachedHere.keys),
      pending: Set(runningActions.keys),
      windowsHere: windowsHere,
      catalog: terminalDefinitions,
      otherTerminalDetaches: otherTerminalDetaches,
      wording: terminalWording)
  } // End of var content

  // MARK: - Lifecycle

  /// Loads the host list, builds and starts the engine and the system events adapter, and
  /// returns once the engine runs; first starts the update check, which never waits (normal
  /// mode only: nothing without `AppEnvironment.update`). Does nothing for a fixture, a second
  /// time, or after `shutdown()`.
  public func start() async {
    guard lifecycle == .idle, let environment else { return }
    lifecycle = .starting
    update.start()
    let task = Task { await self.performStart(environment) }
    startTask = task
    await task.value
  }

  /// The body of `start()`. Stops building as soon as `shutdown()` was called; whatever it
  /// built by then, `shutdown()` stops once this returns. The session switcher shortcut is
  /// loaded and registered first (PLAN.md D32; nothing without `AppEnvironment.globalShortcut`),
  /// then the terminal setting is resolved (PLAN.md D38; nothing read without
  /// `AppEnvironment.terminal`).
  /// A list loaded as `notSavedYet` shows the onboarding window first
  /// (`OnboardingModel.prepare(_:)` decides; it reads nothing).
  private func performStart(_ environment: AppEnvironment) async {
    await shortcut.start()
    guard lifecycle == .starting else { return }
    await resolveTerminalAtLaunch(environment)
    guard lifecycle == .starting else { return }
    let (hosts, loaded) = await loadHostList(environment)
    guard lifecycle == .starting else { return }
    if environment.rewritesProfilesAtLaunch, loaded?.state == .saved, terminalChoice.usesITerm2 {
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
    // Before the cadence starts, so no check runs while iTerm2 is not the chosen terminal.
    await engine.setAttachmentChecksEnabled(terminalChoice.usesITerm2)
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
    savedHosts = status == .saved ? list : nil
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
    case .setAttachmentChecks(let enabled): await engine.setAttachmentChecksEnabled(enabled)
    case .barrier: break
    }
  } // End of func perform(_:on:)

  /// Takes a state the engine published (Settings shows its statuses too). While the switcher
  /// shows, the row it selects is remembered first, so the new state keeps it selected while it
  /// is listed (PLAN.md D32).
  private func apply(_ state: RefreshState) {
    if isSwitcherVisible { rememberSwitcherSelection() }
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
    savedHosts = list
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
  ///   awaited), New session's folder search (its channel closed and its processes reaped,
  ///   PLAN.md D36; each closing awaited for at most the budget), and, in this order, the
  ///   request queue (requests still queued are dropped), the system events adapter and the
  ///   engine, whose `stop()` cancels any attachment check and kills any running probe's
  ///   process group.
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

  /// The part of `shutdown()` that never waits for a session action: the terminal picker's
  /// reading under way is dropped first (Settings' opening may wait for it); then Settings,
  /// onboarding, the popover's "Set up SSH in iTerm2…" requests, the session switcher shortcut
  /// (its save in progress awaited, its hotkey unregistered, PLAN.md D32) and New session's
  /// folder search (its channel closed and its processes reaped, D36) stop concurrently with
  /// the engine's chain (the start in progress, the request queue, the system events adapter,
  /// the engine and its updates).
  private func stopSubsystems() async {
    terminalPicker.shutdown()
    async let settingsStopped: Void = settings.shutdown()
    async let onboardingStopped: Void = onboarding.shutdown()
    async let sshSetupStopped: Void = sshSetup.shutdown()
    async let shortcutStopped: Void = shortcut.shutdown()
    async let folderSearchStopped: Void = stopFolderSearch()
    async let updateStopped: Void = update.stop()
    await startTask?.value
    commandSink.finish()
    await commandTask?.value
    await systemEvents?.stop()
    await engine?.stop()
    await updatesTask?.value
    _ = await (
      settingsStopped, onboardingStopped, sshSetupStopped, shortcutStopped, folderSearchStopped,
      updateStopped
    )
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

  /// Queues an engine request; dropped for a fixture and after `shutdown()`. A visibility
  /// change is also kept in `engineVisibilityChanges`.
  func send(_ command: EngineCommand) {
    guard environment != nil, lifecycle != .stopped else { return }
    switch command {
    case .popoverOpened: logVisibility(true)
    case .popoverClosed: logVisibility(false)
    default: break
    }
    commandSink.yield(command)
  }

  /// Keeps one visibility change handed to the engine (the latest `visibilityLogLimit`).
  private func logVisibility(_ isVisible: Bool) {
    engineVisibilityChanges.append(isVisible)
    if engineVisibilityChanges.count > Self.visibilityLogLimit {
      engineVisibilityChanges.removeFirst(engineVisibilityChanges.count - Self.visibilityLogLimit)
    }
  }

  // MARK: - Popover

  /// Whether the popover or the session switcher shows: what the engine is told (PLAN.md D22).
  public var isSessionListVisible: Bool { isPopoverVisible || isSwitcherVisible }

  /// The popover window became visible or hidden (the update notice counts as seen while it
  /// shows, PLAN.md D39 *The notice (I-13c1)*).
  public func popoverVisibilityChanged(_ isVisible: Bool) {
    if isVisible { popoverDidOpen() } else { popoverDidClose() }
    updateNoticeVisibility()
  }

  /// Tells the update model whether the popover shows its main layout, where the update
  /// notice is: visible, with no Move here or Detach other clients confirmation over it.
  func updateNoticeVisibility() {
    update.popoverVisibilityChanged(isPopoverVisible && panel == nil)
  }

  /// The popover opened: unless the switcher showed already, the engine refreshes every host
  /// now and every 15 s, with attachment checks. Activities of actions that succeeded
  /// ("Confirmed", "Detached…") were for the previous opening and are cleared; failures stay
  /// until retried. An open switcher is closed (only one of the two shows). A repeated call
  /// while open does nothing.
  public func popoverDidOpen() {
    guard !isPopoverVisible else { return }
    let wasListVisible = isSessionListVisible
    isPopoverVisible = true
    openedSessionList()
    if isSwitcherVisible { closeSwitcher?(.popoverOpened) }
    if !wasListVisible { send(.popoverOpened) }
  }

  /// The popover closed: unless the switcher shows, back to the background cadence, no
  /// attachment checks. The engine cancels the check in progress: whatever part of it has not
  /// reached iTerm2 yet (the cookie request, the connection, a connection's identity question)
  /// never does, and its result is discarded.
  public func popoverDidClose() {
    guard isPopoverVisible else { return }
    isPopoverVisible = false
    if !isSessionListVisible { send(.popoverClosed) }
  }

  /// What every opening of the popover or the switcher does: relative times from now, and the
  /// activities of actions that succeeded cleared (failures stay until retried).
  func openedSessionList() {
    if let environment { now = environment.now() }
    for (key, activity) in activities where activity.isDone {
      activities[key] = nil
      notes[key] = nil
    }
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
  /// hotkey's action. It toggles the session switcher through `toggleSwitcher` (opening it
  /// closes the popover). Does nothing for a fixture or after `shutdown()`.
  public func globalShortcutPressed() {
    guard environment != nil, lifecycle != .stopped else { return }
    toggleSwitcher?()
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

  /// Carries out a popover key and says whether the popover should close. While the Move here
  /// or Detach other clients confirmation shows, Return confirms it (`confirmPanel()`), Esc
  /// closes it, ⌘R and ⌘, act as in the list, the arrows, ⌘F and ⌘N do nothing and ⌥↓ is left
  /// to the focused view (`ignored`). In the list,
  /// ⌘N opens the New session window (`newSession()`, PLAN.md D34) and ⌥↓ is left to the
  /// focused view. While a menu tracks the panel's key monitor hands no key here
  /// (`PanelKeyRoute`, PLAN.md Phase I-8). The New session window's keys are
  /// `handleNewSessionKey(_:)`.
  public func handle(_ key: PopoverKey) -> PopoverKeyResult {
    if panel != nil {
      switch key {
      case .open: confirmPanel()
      case .openList: return .ignored
      case .close: cancelPanel()
      case .refresh: refresh()
      case .settings: openSettings()
      case .up, .down, .find, .newSession: break
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
  /// "detach", "detach other clients", "new session", "open existing", "show tab").
  public var unfinishedActions: [String]

  /// Creates a report.
  public init(unfinishedActions: [String] = []) {
    self.unfinishedActions = unfinishedActions
  }

  /// Whether every session action ended in time.
  public var isComplete: Bool { unfinishedActions.isEmpty }
}
