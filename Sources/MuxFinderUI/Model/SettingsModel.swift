import Foundation
import MuxFinderCore
import Observation

/// The Settings window's model (PLAN.md Phase 9a, D23): the Hosts tab's list and host editor,
/// the Directories tab's saved directories (D31, `SettingsModelDirectories.swift`), the General
/// tab's launch at login, the Diagnostics tab's log and "Copy diagnostics", and the fix-its
/// shown with their errors.
///
/// - **Saving:** only through `SettingsEnvironment.store` (`HostStore`), only on "Save", on a
///   confirmed removal, and only while the list is editable. Every save expects the file's
///   revision as loaded or last saved, so a file another program changed meanwhile is never
///   replaced: the store refuses, the draft stays, and the list is not editable until the user
///   reloads or chooses to replace that file (`changedFile`). A list loaded as `invalid` is
///   shown with its problem and is not editable until the user explicitly chooses to replace
///   the file. Replacing (`confirmReplaceFile()`) writes nothing by itself; the store keeps
///   the replaced file as a backup at the save (D19). A folder that could not be read is not
///   editable either.
/// - **The editor** works on a `HostDraft`; inline errors come from `HostDraftIssues`. Choosing
///   This Mac follows D19's switch: on save, `HostList.makeThisMac(id:)` turns the previous This
///   Mac back into an SSH host, turned off. An SSH host without a valid destination cannot be
///   turned on (`setEnabled(_:)` refuses). Selecting another host with unsaved changes asks
///   first (`pendingSelection`); removing asks first (`pendingRemoval`), and a removal moves
///   the editor on only if it still shows the removed host when the save ends.
/// - **Probes:** "Detect" and "Test connection" run discovery through
///   `SettingsEnvironment.discovery`; a newer request, another host or a changed mode,
///   destination or tmux path cancels the one running and drops its result.
/// - **Set up SSH in iTerm2…** (PLAN.md D24): for an SSH draft with a valid destination, opens a
///   tab running ssh to it as typed (`sshSetup`, through `SettingsEnvironment.sshSetup`), also
///   offered next to a connection test that needed a sign-in or had a host key problem.
///   Closing the window cancels a request still running.
/// - **Window and quitting:** the window's opening runs in a task the model owns; closing the
///   window cancels it (and the profile request inside it) and drops late results by window
///   generation. `shutdown()` (from `AppModel.shutdown()`) refuses new work, cancels every
///   probe and the opening, and returns once they have ended.
/// - **iTerm2:** profiles are listed only while iTerm2 runs (`ITerm2ProfileSource`); otherwise
///   the profile field is free text.
/// - **Persistent profiles** (PLAN.md D26, `SettingsModelProfiles.swift`): the Persistent
///   profiles tab shows the status of `DynamicProfiles/muxFinder.json` for the saved host list,
///   installs and removes it, a save while muxFinder's file is installed updates it, and the app
///   asks for the rewrite at launch; all through `SettingsEnvironment.persistentProfiles`, one
///   operation at a time.
/// - **Fixtures:** `init(fixture:)` shows a fixed state for previews and screenshots and never
///   runs anything.
@MainActor
@Observable
public final class SettingsModel {
  /// The window's tabs.
  public enum Tab: String, Sendable, Hashable, CaseIterable {
    /// The host list and editor.
    case hosts
    /// muxFinder's persistent profile file in iTerm2 (PLAN.md D26).
    case profiles
    /// New session's saved directories (PLAN.md D31).
    case directories
    /// Launch at login.
    case general
    /// The operation log.
    case diagnostics

    /// The tab's title.
    public var title: String {
      switch self {
      case .hosts: return "Hosts"
      case .profiles: return "Persistent profiles"
      case .directories: return "Directories"
      case .general: return "General"
      case .diagnostics: return "Diagnostics"
      }
    }
  }

  /// What the editor shows.
  public enum Selection: Sendable, Hashable {
    /// A saved host.
    case host(UUID)
    /// A host being added, not saved yet.
    case newHost
  }

  /// A selection change waiting for the user to discard unsaved changes.
  public struct PendingSelection: Sendable, Hashable {
    /// Where the selection goes once the changes are discarded (`nil`: nothing selected).
    public var target: Selection?
  }

  /// How far the host list got.
  public enum LoadState: Sendable, Hashable {
    /// Not asked yet.
    case notLoaded
    /// Loading.
    case loading
    /// Loaded, with how it went.
    case loaded(HostListStatus)
  }

  /// The banner above the Hosts tab, if any.
  public enum HostListBanner: Sendable, Hashable {
    /// No file yet: the examples are shown.
    case examples
    /// The file cannot be used and is left as it is; `consented` once the user chose to
    /// replace it.
    case invalidFile(HostFileProblem, consented: Bool)
    /// A save found that the file changed after it was loaded and left it as it is;
    /// `consented` once the user chose to replace it.
    case fileChanged(consented: Bool)
    /// muxFinder's folder could not be read.
    case unreadable(String)

    /// The banner's text.
    public var text: String {
      switch self {
      case .examples:
        return "These are examples, all turned off. Nothing is saved until you change something."
      case .invalidFile(let problem, consented: false):
        return "muxFinder couldn't use its host list file and left it as it is. "
          + problem.message + " To start a new host list, choose Replace; the current file is "
          + "kept as a backup when you first save."
      case .invalidFile(_, consented: true):
        return "You chose to replace the unusable host list file. It is kept as a backup in "
          + "muxFinder's settings folder when you first save."
      case .fileChanged(consented: false):
        return "The host list file changed after muxFinder loaded it, so nothing was saved and "
          + "the file was left as it is. Choose Reload to show it (changes made here are "
          + "lost), or Replace to save this list over it; the file is then kept as a backup."
      case .fileChanged(consented: true):
        return "You chose to replace the changed host list file. It is kept as a backup in "
          + "muxFinder's settings folder when you save."
      case .unreadable(let message):
        return "muxFinder couldn't read its settings folder. " + message
      }
    } // End of var text
  } // End of enum HostListBanner

  /// One row of the host list.
  public struct HostRow: Sendable, Hashable, Identifiable {
    /// The selection the row stands for.
    public var id: Selection
    /// The display name.
    public var name: String
    /// "This Mac", "SSH", "SSH · Turned off", "Not saved yet".
    public var detail: String
    /// The host's status in the popover, for a turned-on host the engine has checked.
    public var status: HostStatusLabel?
    /// Whether the row is selected.
    public var isSelected: Bool
  }

  /// The message shown when a save is refused because the unusable file was not replaced.
  public static let replaceFirstMessage =
    "The host list file can't be used. Choose Replace before saving, or move the file away."
  /// The message shown when a save is refused because the file changed after it was loaded.
  public static let fileChangedMessage =
    "The host list file changed after muxFinder loaded it, so nothing was saved. Choose Reload "
    + "or Replace."

  // MARK: - State

  /// The selected tab. Any tab but General stops the shortcut recorder, so its key monitor goes
  /// and the saved hotkey is registered again (PLAN.md D32).
  public var selectedTab: Tab = .hosts {
    didSet { if selectedTab != .general { globalShortcut.cancelRecording() } }
  }
  /// How far the host list got.
  public private(set) var loadState = LoadState.notLoaded
  /// The saved host list (or the examples).
  public private(set) var hosts = HostList()
  /// Whether the user chose to replace an unusable or changed host list file.
  public private(set) var hasReplaceConsent = false
  /// What a refused save found at the file's name after it changed since it was loaded or last
  /// saved; `nil` while no save was refused so. Replacing expects this revision.
  public private(set) var changedFile: HostFileRevision?
  /// What the editor shows.
  public private(set) var selection: Selection?
  /// The editor's working copy.
  public private(set) var draft: HostDraft?
  /// The draft as last saved (`nil` for a new host).
  public private(set) var savedDraft: HostDraft?
  /// A selection change waiting for "Discard changes".
  public private(set) var pendingSelection: PendingSelection?
  /// The host waiting for "Remove".
  public private(set) var pendingRemoval: UUID?
  /// Whether a save runs.
  public private(set) var isSaving = false
  /// Why the last save failed.
  public private(set) var saveError: String?
  /// What the last save did ("Saved.").
  public private(set) var saveNotice: String?
  /// Why the host could not be turned on.
  public private(set) var enableRefusal: String?
  /// "Test connection".
  public private(set) var connectionTest = ConnectionTestState.idle
  /// "Detect".
  public private(set) var detection = DetectionState.idle
  /// The profile picker's choices.
  public private(set) var profileChoices = ProfileChoices.notLoaded
  /// SSH destination suggestions from `~/.ssh/config`.
  public private(set) var suggestions: [String] = []
  /// The login item status, last read.
  public private(set) var loginItemStatus: LoginItemStatus?
  /// Why the last launch-at-login change failed.
  public private(set) var loginItemError: String?
  /// The operation log, oldest first.
  public private(set) var diagnosticEvents: [DiagnosticEvent] = []
  /// What "Copy diagnostics" did.
  public private(set) var copyNotice: String?
  /// The refresh engine's last state (set by `AppModel`), for statuses and diagnostics.
  public var refreshState: RefreshState?
  /// The explaining fix-it whose text is shown.
  public private(set) var shownExplanation: FixIt?
  /// How `DynamicProfiles/muxFinder.json` compares with the saved hosts' profiles, last
  /// checked; `nil` before the first check.
  public internal(set) var profileStatus: PersistentProfileStatus?
  /// What the last install, removal or automatic update did.
  public internal(set) var profileResult: PersistentProfileResult?
  /// Profile operations queued or running (they run one at a time).
  public internal(set) var profileOperations = 0
  /// How New session's directory lists loaded for the Directories tab (PLAN.md D31).
  public internal(set) var directoryStatus = DirectoryListStatus.notLoaded
  /// The saved directories as loaded, last saved or last changed from New session's list
  /// (what "Revert" brings back).
  public internal(set) var savedDirectories: [String] = []
  /// The Directories tab's working copy of the saved list, in the user's order.
  public internal(set) var directoryDraft: [String] = []
  /// The saved list the working copy's edits started from: what "Save" merges them against
  /// (`DirectoryListChange.mergeSaved(base:edited:)`), so changes made elsewhere since are kept.
  @ObservationIgnored var directoryDraftBase: [String] = []
  /// The Directories tab's "Add" field, as typed.
  public var newDirectory = ""
  /// Whether a save of the saved directories runs.
  public internal(set) var isSavingDirectories = false
  /// Why the last save of the saved directories failed.
  public internal(set) var directorySaveError: String?
  /// What the last save of the saved directories did ("Saved.").
  public internal(set) var directorySaveNotice: String?
  /// Whether the window is open.
  public private(set) var isWindowOpen = false
  /// Whether this model renders a fixture.
  public let isPreview: Bool
  /// "Set up SSH in iTerm2…" for the hosts edited here.
  public let sshSetup: SSHSetupActions
  /// The General tab's session switcher shortcut (PLAN.md D32): `AppModel`'s model in the app,
  /// a fixture's in previews, an inert one otherwise.
  public internal(set) var globalShortcut: GlobalShortcutModel

  /// Called after every successful save with the list now on disk (`AppModel` hands it to the
  /// engine).
  @ObservationIgnored public var onHostListSaved: (@MainActor (HostList) -> Void)?
  /// Called after every successful save of the saved directories with the lists now kept
  /// (`AppModel` shows them in New session's list).
  @ObservationIgnored public var onDirectoriesSaved: (@MainActor (DirectoryLists) -> Void)?
  /// The dependencies; `nil` for a fixture.
  @ObservationIgnored let environment: SettingsEnvironment?
  /// The last profile operation queued; the next one waits for it (`SettingsModelProfiles`).
  @ObservationIgnored var lastProfileOperation: Task<Void, Never>?
  /// The file's revision as loaded or last saved, which saves expect; `nil` before a load and
  /// for a folder that could not be read.
  @ObservationIgnored private var revision: HostFileRevision?
  /// The running "Test connection".
  @ObservationIgnored private var testTask: Task<Void, Never>?
  /// The running "Detect".
  @ObservationIgnored private var detectTask: Task<Void, Never>?
  /// The window's opening (list, then profiles, suggestions and log), while it runs.
  @ObservationIgnored private var openTask: Task<Void, Never>?
  /// Every probe and opening still running, by number, so `shutdown()` can wait for them all
  /// (a replaced probe may still be ending).
  @ObservationIgnored private var runningTasks: [Int: Task<Void, Never>] = [:]
  /// The last number given to a task in `runningTasks`.
  @ObservationIgnored private var lastTaskNumber = 0
  /// Increases whenever running probes must be ignored.
  @ObservationIgnored private var probeGeneration = 0
  /// Increases when the window opens or closes; work started for an earlier opening drops its
  /// results and starts nothing more.
  @ObservationIgnored private(set) var windowGeneration = 0
  /// Whether `shutdown()` ran: nothing new starts.
  @ObservationIgnored private(set) var isShutDown = false

  /// A model over `environment`. Nothing runs until `windowDidOpen()`.
  public init(environment: SettingsEnvironment) {
    self.environment = environment
    isPreview = false
    sshSetup = SSHSetupActions(opener: environment.sshSetup)
    globalShortcut = GlobalShortcutModel(environment: nil)
  }

  /// A model that shows `fixture` and never runs anything.
  public init(fixture: SettingsFixture) {
    environment = nil
    isPreview = true
    selectedTab = fixture.tab
    loadState = fixture.hostListStatus.map(LoadState.loaded) ?? .notLoaded
    hosts = fixture.hosts
    hasReplaceConsent = fixture.hasReplaceConsent
    selection = fixture.selection
    draft = fixture.draft
    savedDraft = fixture.savedDraft
    saveError = fixture.saveError
    saveNotice = fixture.saveNotice
    enableRefusal = fixture.enableRefusal
    connectionTest = fixture.connectionTest
    detection = fixture.detection
    profileChoices = fixture.profileChoices
    suggestions = fixture.suggestions
    loginItemStatus = fixture.loginItemStatus
    loginItemError = fixture.loginItemError
    diagnosticEvents = fixture.diagnosticEvents
    copyNotice = fixture.copyNotice
    refreshState = fixture.refreshState
    shownExplanation = fixture.shownExplanation
    profileStatus = fixture.profileStatus
    profileResult = fixture.profileResult
    profileOperations = fixture.isProfileOperationRunning ? 1 : 0
    directoryStatus = fixture.directoryStatus
    savedDirectories = fixture.savedDirectories
    directoryDraft = fixture.directoryDraft ?? fixture.savedDirectories
    directoryDraftBase = fixture.savedDirectories
    newDirectory = fixture.newDirectory
    directorySaveError = fixture.directorySaveError
    directorySaveNotice = fixture.directorySaveNotice
    sshSetup = SSHSetupActions(opener: nil, states: fixture.sshSetupStates)
    globalShortcut = GlobalShortcutModel(fixture: fixture.globalShortcut)
  } // End of init(fixture:)

  // MARK: - Window

  /// The window opened: reads the login item status, loads the host list, then the profiles,
  /// the SSH suggestions, the log, the persistent profile file's status and the saved
  /// directories, in a task the model owns (`windowDidClose()` cancels it), and returns once that task has ended. Does nothing
  /// for a fixture, while already open, or after `shutdown()`.
  public func windowDidOpen() async {
    guard environment != nil, !isWindowOpen, !isShutDown else { return }
    isWindowOpen = true
    windowGeneration += 1
    let generation = windowGeneration
    let task = track { [weak self] in await self?.open(generation: generation) }
    openTask = task
    await task.value
  }

  /// The opening's work. Each step after the host list starts only while the window opened as
  /// `generation` is still open and the opening not cancelled, so a window closed meanwhile
  /// asks iTerm2 nothing.
  private func open(generation: Int) async {
    refreshLoginItemStatus()
    await reloadHosts()
    guard isCurrentWindow(generation) else { return }
    async let profiles: Void = loadProfiles()
    async let names: Void = loadSuggestions()
    async let log: Void = refreshDiagnostics()
    async let files: Void = checkProfiles()
    async let directories: Void = loadDirectories()
    _ = await (profiles, names, log, files, directories)
  }

  /// Whether work started for the window opened as `generation` may go on: that window is
  /// still open, the calling task is not cancelled and `shutdown()` has not run.
  private func isCurrentWindow(_ generation: Int) -> Bool {
    isWindowOpen && windowGeneration == generation && !Task.isCancelled && !isShutDown
  }

  /// The window closed: cancels its opening (a profile request in progress with it) and the
  /// probes, drops their late results, forgets dialogs and unsaved changes (the next opening
  /// reloads the list), and stops the shortcut recorder (the saved hotkey is registered again,
  /// PLAN.md D32).
  public func windowDidClose() {
    globalShortcut.cancelRecording()
    guard isWindowOpen else { return }
    isWindowOpen = false
    windowGeneration += 1
    openTask?.cancel()
    openTask = nil
    cancelProbes()
    sshSetup.cancelAll()
    if profileChoices == .loading { profileChoices = .notLoaded }
    pendingSelection = nil
    pendingRemoval = nil
    shownExplanation = nil
    copyNotice = nil
  } // End of func windowDidClose()

  /// The window stopped being the key window: the shortcut recorder stops listening and the
  /// saved hotkey is registered again (PLAN.md D32), so it is never left suspended.
  public func windowDidResignKey() {
    globalShortcut.cancelRecording()
  }

  /// Quitting (`AppModel.shutdown()`): refuses new work from now on (no opening, load, profile
  /// request, probe, ssh tab or save), cancels the window's opening, every probe and any ssh
  /// tab request, and returns once all of them have ended. A discovery probe ends only after
  /// its process group was killed and reaped. Later calls only wait again.
  public func shutdown() async {
    isShutDown = true
    windowGeneration += 1
    openTask?.cancel()
    openTask = nil
    cancelProbes()
    let tasks = Array(runningTasks.values)
    for task in tasks {
      task.cancel()
      await task.value
    }
    await sshSetup.shutdown()
  } // End of func shutdown()

  /// Starts `work` as a task kept in `runningTasks` until it ends, and returns it.
  func track(
    _ work: @escaping @MainActor @Sendable () async -> Void
  ) -> Task<Void, Never> {
    lastTaskNumber += 1
    let number = lastTaskNumber
    let task = Task { [weak self] in
      await work()
      self?.runningTasks[number] = nil
    }
    runningTasks[number] = task
    return task
  } // End of func track(_:)

  // MARK: - Host list

  /// How the host list loaded, once it did.
  public var hostListStatus: HostListStatus? {
    if case .loaded(let status) = loadState { return status }
    return nil
  }

  /// Whether the list may be changed and saved: a saved list or the examples, unless a save
  /// found the file changed; an unusable or changed file only once the user chose to replace
  /// it; never an unreadable folder.
  public var isEditable: Bool {
    switch hostListStatus {
    case .saved, .notSavedYet: return changedFile == nil || hasReplaceConsent
    case .invalid: return hasReplaceConsent
    case .unreadable, nil: return false
    }
  }

  /// The banner above the Hosts tab.
  public var banner: HostListBanner? {
    if changedFile != nil { return .fileChanged(consented: hasReplaceConsent) }
    switch hostListStatus {
    case .notSavedYet: return .examples
    case .invalid(let problem): return .invalidFile(problem, consented: hasReplaceConsent)
    case .unreadable(let message): return .unreadable(message)
    case .saved, nil: return nil
    }
  }

  /// Loads the list through the store (which never writes when loading), remembers the file's
  /// revision for the next save, and selects the host shown before, or the first one. "Reload"
  /// and "Try again". The result is dropped when the window closed or reopened meanwhile.
  public func reloadHosts() async {
    guard let environment, !isShutDown else { return }
    let generation = windowGeneration
    loadState = .loading
    let loaded: Result<HostStoreLoadResult, HostStoreError>
    do {
      loaded = .success(try await environment.store.load())
    } catch {
      loaded = .failure(error)
    }
    guard windowGeneration == generation else { return }
    let status: HostListStatus
    switch loaded {
    case .success(let result):
      hosts = result.hosts
      revision = result.revision
      switch result.state {
      case .saved: status = .saved
      case .notSavedYet: status = .notSavedYet
      case .invalid(let problem): status = .invalid(problem)
      }
    case .failure(let error):
      hosts = HostList()
      revision = nil
      status = .unreadable(message: error.errorDescription ?? "The folder is not usable.")
    }
    loadState = .loaded(status)
    changedFile = nil
    hasReplaceConsent = false
    saveError = nil
    saveNotice = nil
    pendingSelection = nil
    pendingRemoval = nil
    if case .host(let id) = selection, hosts.host(withID: id) != nil {
      apply(.host(id))
    } else {
      apply(hosts.hosts.first.map { .host($0.id) })
    }
    if case .failure(let error) = loaded {
      await record(.failure, detail: "host list load failed: \(Self.caseName(of: error))")
    } else {
      await record(.info, detail: "host list loaded: \(Self.statusCode(status))")
    }
  } // End of func reloadHosts()

  /// The user confirmed replacing the host list file: an unusable one (the list shown is the
  /// examples) or one a save found changed (the list shown is the one edited here, the draft
  /// kept). The list becomes editable. Nothing is written until a save, which still refuses a
  /// file that changes again and keeps the replaced file as a backup (D19).
  public func confirmReplaceFile() {
    guard !hasReplaceConsent else { return }
    let kind: String
    if changedFile != nil {
      kind = "changed"
    } else if case .invalid = hostListStatus {
      kind = "unusable"
    } else {
      return
    }
    hasReplaceConsent = true
    Task { await record(.info, detail: "replacing the \(kind) host list file was confirmed") }
  } // End of func confirmReplaceFile()

  /// The host list's rows, with a new host's row last.
  public var hostRows: [HostRow] {
    var rows = hosts.hosts.map { host -> HostRow in
      let snapshot = refreshState?.hosts.first { $0.host.id == host.id }
      var detail = host.isThisMac ? "This Mac" : "SSH"
      if !host.isEnabled { detail += " · Turned off" }
      return HostRow(
        id: .host(host.id), name: host.displayName, detail: detail,
        status: host.isEnabled ? snapshot.map(HostStatusLabel.init) : nil,
        isSelected: selection == .host(host.id))
    }
    if selection == .newHost, let draft {
      let name = draft.trimmedName.isEmpty ? "New host" : draft.trimmedName
      rows.append(
        HostRow(id: .newHost, name: name, detail: "Not saved yet", status: nil, isSelected: true))
    }
    return rows
  } // End of var hostRows

  // MARK: - Selection

  /// Whether the editor holds unsaved changes (a new host always does).
  public var isDirty: Bool {
    guard let draft else { return false }
    guard let savedDraft else { return true }
    return draft != savedDraft
  }

  /// Shows `selection` in the editor, or asks first (`pendingSelection`) when the draft has
  /// unsaved changes.
  public func select(_ selection: Selection?) {
    guard selection != self.selection else { return }
    if isDirty {
      pendingSelection = PendingSelection(target: selection)
      return
    }
    apply(selection)
  }

  /// "Add host": a new SSH host, turned off, in the editor (asking first about unsaved
  /// changes). Only while the list is editable.
  public func addHost() {
    guard isEditable else { return }
    select(.newHost)
  }

  /// "Discard changes": carries out the waiting selection.
  public func confirmDiscard() {
    guard let pendingSelection else { return }
    self.pendingSelection = nil
    apply(pendingSelection.target)
  }

  /// Keeps editing; the waiting selection is dropped.
  public func cancelDiscard() {
    pendingSelection = nil
  }

  /// "Revert": back to the saved host; a new host is dropped.
  public func revert() {
    guard let draft else { return }
    if draft.isNew {
      apply(hosts.hosts.first.map { .host($0.id) })
    } else {
      apply(.host(draft.id))
    }
  }

  /// Makes `selection` current and resets the editor to it.
  private func apply(_ selection: Selection?) {
    cancelProbes()
    self.selection = selection
    switch selection {
    case .host(let id):
      if let host = hosts.host(withID: id) {
        draft = HostDraft(host)
        savedDraft = draft
      } else {
        self.selection = nil
        draft = nil
        savedDraft = nil
      }
    case .newHost:
      draft = .newHost()
      savedDraft = nil
    case nil:
      draft = nil
      savedDraft = nil
    }
    enableRefusal = nil
    saveError = nil
    pendingSelection = nil
  } // End of func apply(_:)

  // MARK: - Editing

  /// The draft's inline errors.
  public var issues: HostDraftIssues? {
    guard let draft else { return nil }
    return HostDraftIssues(draft: draft, otherHosts: hosts.hosts.filter { $0.id != draft.id })
  }

  /// Whether "Save" is available: an editable list, unsaved changes, no inline error, no save
  /// running.
  public var canSave: Bool {
    isEditable && isDirty && !isSaving && issues?.isValid == true
  }

  /// Sets the display name.
  public func setDisplayName(_ name: String) {
    edit { $0.displayName = name }
  }

  /// Sets the mode. Choosing This Mac turns the host on, as `HostList.makeThisMac(id:)` does.
  public func setMode(_ mode: HostConfig.ConnectionMode) {
    edit { draft in
      draft.mode = mode
      if mode == .local { draft.isEnabled = true }
    }
  }

  /// Sets the SSH destination.
  public func setDestination(_ destination: String) {
    edit { $0.sshDestination = destination }
  }

  /// Sets the tmux path (empty: automatic).
  public func setTmuxPath(_ path: String) {
    edit { $0.tmuxPath = path }
  }

  /// Sets the iTerm2 profile (empty: iTerm2's default).
  public func setProfileName(_ name: String) {
    edit { $0.profileName = name }
  }

  /// Turns the host's persistent profile on or off (PLAN.md D26).
  public func setPersistentProfileEnabled(_ isEnabled: Bool) {
    edit { $0.persistentProfile.isEnabled = isEnabled }
  }

  /// Sets the persistent profile's default session name (empty: `main`).
  public func setDefaultSessionName(_ name: String) {
    edit { $0.persistentProfile.defaultSessionName = name }
  }

  /// Sets the persistent profile's parent profile (empty: none, so iTerm2's default profile).
  public func setParentProfileName(_ name: String) {
    edit { $0.persistentProfile.parentProfileName = name }
  }

  /// Turns the host on or off. Turning on an SSH host without a valid destination is refused
  /// (PLAN.md D19): nothing changes, `enableRefusal` says why, and the result is `false`.
  @discardableResult
  public func setEnabled(_ isEnabled: Bool) -> Bool {
    guard isEditable, let draft else { return false }
    if isEnabled, !draft.canTurnOn {
      enableRefusal = HostDraftIssues.destinationNeededToTurnOn
      return false
    }
    edit { $0.isEnabled = isEnabled }
    return true
  }

  /// Applies `change` to the draft while the list is editable. A change of mode, destination
  /// or tmux path stops the probes and clears their results, and a change of mode or
  /// destination forgets the "Set up SSH in iTerm2…" line: all were about the old values.
  private func edit(_ change: (inout HostDraft) -> Void) {
    guard isEditable, var updated = draft else { return }
    let before = updated
    change(&updated)
    draft = updated
    saveNotice = nil
    if updated.canTurnOn { enableRefusal = nil }
    if updated.discoveryDiffers(from: before) { cancelProbes() }
    if updated.mode != before.mode || updated.trimmedDestination != before.trimmedDestination {
      sshSetup.clear(updated.id)
    }
  } // End of func edit(_:)

  /// Whether "Set up SSH in iTerm2…" is offered for the draft: an SSH host with a valid
  /// destination (saved or not), while no request for it runs and the window may work.
  public var canSetUpSSH: Bool {
    guard let draft, !isShutDown else { return false }
    return SSHSetupActions.isOffered(for: draft.config) && !sshSetup.isOpening(draft.id)
  }

  /// "Set up SSH in iTerm2…": opens a tab running ssh to the draft's destination as typed.
  public func setUpSSH() {
    guard canSetUpSSH, let draft else { return }
    sshSetup.open(draft.config)
  }

  /// Whether the connection test's result offers "Set up SSH in iTerm2 first": it needed a
  /// sign-in or had a host key problem.
  public var connectionTestOffersSSHSetup: Bool {
    guard case .finished(let result) = connectionTest else { return false }
    return result.status == .signInNeeded || result.status == .hostKeyProblem
  }

  /// The note shown when choosing This Mac turns another host back into an SSH host.
  public var thisMacNotice: String? {
    guard let draft, draft.mode == .local, let current = hosts.thisMac, current.id != draft.id
    else { return nil }
    return "Saving makes “\(current.displayName)” an SSH host again and turns it off: only one "
      + "host can be This Mac."
  }

  /// A warning (not an error) when the profile is not among iTerm2's profiles.
  public var profileWarning: String? {
    guard let draft, case .available(let names) = profileChoices else { return nil }
    let name = draft.trimmedProfileName
    guard !name.isEmpty, !names.contains(name) else { return nil }
    return "iTerm2 has no profile with this name right now."
  }

  /// A warning (not an error) when the persistent profile's parent is not among iTerm2's
  /// profiles: iTerm2 then bases the profile on its default profile.
  public var parentProfileWarning: String? {
    guard let draft, case .available(let names) = profileChoices,
      let name = draft.persistentProfile.storedParentName, !names.contains(name)
    else { return nil }
    return "iTerm2 has no profile with this name right now, so it would use its default profile "
      + "as the parent."
  }

  // MARK: - Saving

  /// "Save": applies the draft to the list (adding a new host, making it This Mac with D19's
  /// switch) and saves through the store. Returns whether it was saved.
  @discardableResult
  public func save() async -> Bool {
    guard let draft, canSave else {
      if draft != nil, !isEditable { saveError = refusalMessage }
      return false
    }
    let config = draft.config
    var list = hosts
    do throws(HostListError) {
      if draft.isNew {
        try list.add(
          HostConfig(
            id: config.id, displayName: config.displayName, mode: .ssh,
            sshDestination: config.sshDestination, isEnabled: false))
      }
      if config.mode == .local, list.host(withID: config.id)?.isThisMac == false {
        try list.makeThisMac(id: config.id)
      }
      try list.update(config)
    } catch {
      saveError = error.message
      return false
    }
    guard await write(list, detail: "host saved", hostID: config.id) else { return false }
    guard let stored = list.host(withID: config.id), self.draft?.id == stored.id else {
      return true
    }
    // Edits made while the save ran stay in the draft, unsaved.
    let saved = HostDraft(stored)
    if self.draft == draft {
      self.draft = saved
    } else {
      self.draft?.isNew = false
    }
    selection = .host(saved.id)
    savedDraft = saved
    return true
  } // End of func save()

  /// "Remove…": asks for confirmation (`pendingRemoval`). Not for a new host (Revert drops it).
  public func requestRemoval() {
    guard isEditable, let draft, !draft.isNew else { return }
    pendingRemoval = draft.id
  }

  /// The name of the host waiting for "Remove".
  public var pendingRemovalName: String? {
    pendingRemoval.flatMap { hosts.host(withID: $0)?.displayName }
  }

  /// Keeps the host.
  public func cancelRemoval() {
    pendingRemoval = nil
  }

  /// "Remove": removes the confirmed host and saves. If the editor still shows the removed
  /// host when the save ends, the next host is selected; a host selected or edited while the
  /// save ran keeps its selection and draft. Returns whether it was removed.
  @discardableResult
  public func confirmRemoval() async -> Bool {
    guard let id = pendingRemoval else { return false }
    pendingRemoval = nil
    let position = hosts.hosts.firstIndex { $0.id == id } ?? 0
    var list = hosts
    do throws(HostListError) {
      try list.remove(id: id)
    } catch {
      saveError = error.message
      return false
    }
    guard await write(list, detail: "host removed", hostID: id) else { return false }
    guard selection == .host(id) else { return true }
    let next = list.hosts.isEmpty ? nil : list.hosts[min(position, list.hosts.count - 1)]
    apply(next.map { .host($0.id) })
    return true
  } // End of func confirmRemoval()

  /// Why a save is refused while the list is not editable.
  private var refusalMessage: String {
    changedFile == nil ? Self.replaceFirstMessage : Self.fileChangedMessage
  }

  /// Saves `list` through the store, expecting the file as loaded or last saved (or, once the
  /// user chose to replace a changed file, as the refused save found it), and makes it the
  /// model's list. A file changed since is left as it is: the save is refused, `changedFile`
  /// holds what is there, and nothing else changes (the draft stays). A save that put the list
  /// in place but could not keep the displaced file (`displacedFileError`) counts as saved,
  /// with its error shown. Refused, with nothing written, while the list is not editable. Once
  /// saved, an installed persistent profile file is brought up to date with the list just
  /// written (`updateProfilesAfterSave(_:)`, PLAN.md D26).
  private func write(_ list: HostList, detail: String, hostID: UUID) async -> Bool {
    guard let environment, !isShutDown else { return false }
    guard isEditable else {
      saveError = refusalMessage
      return false
    }
    guard let expected = changedFile ?? revision, !isSaving else { return false }
    isSaving = true
    defer { isSaving = false }
    saveError = nil
    saveNotice = nil
    let result: HostStoreSaveResult
    do {
      result = try await environment.store.save(list, expecting: expected)
    } catch .fileChanged(let current) {
      changedFile = current
      hasReplaceConsent = false
      saveError = Self.fileChangedMessage
      await record(.failure, hostID: hostID, detail: detail + " refused: the file changed")
      return false
    } catch {
      saveError = error.errorDescription ?? "muxFinder couldn't save the host list."
      await record(.failure, hostID: hostID, detail: "save failed: \(Self.caseName(of: error))")
      return false
    }
    hosts = list
    revision = result.revision
    changedFile = nil
    loadState = .loaded(.saved)
    hasReplaceConsent = false
    onHostListSaved?(list)
    updateProfilesAfterSave(list)
    if let error = result.displacedFileError {
      saveError = error.errorDescription
      await record(.failure, hostID: hostID, detail: detail + ", displaced file not kept")
    } else {
      saveNotice =
        result.backup.map {
          "Saved. The file it replaced was kept as \($0.lastPathComponent) in muxFinder's "
            + "settings folder."
        } ?? "Saved."
      let kept = result.backup == nil ? "" : ", backup kept"
      await record(.success, hostID: hostID, detail: detail + kept)
    }
    return true
  } // End of func write(_:detail:hostID:)

  // MARK: - Probes

  /// "Test connection": discovers the draft's host as it stands (the saved file is not
  /// involved) and shows the classified status.
  public func testConnection() {
    guard let environment, let draft, draft.canTest, !isShutDown else { return }
    testTask?.cancel()
    let generation = probeGeneration
    let host = draft.probeConfig(detecting: false)
    connectionTest = .running
    testTask = track { [weak self] in
      guard let result = try? await environment.discovery.discover(host) else { return }
      guard let self, self.probeGeneration == generation else { return }
      self.connectionTest = .finished(ConnectionTestResult(result, mode: host.mode))
      await self.record(
        Self.outcome(of: result.status), hostID: host.id, duration: result.duration,
        detail: "connection test: \(result.status.kind)")
    }
  } // End of func testConnection()

  /// "Detect": discovers the draft's host without its tmux path; a tmux found goes into the
  /// field.
  public func detectTmux() {
    guard let environment, let draft, draft.canDetect, !isShutDown else { return }
    detectTask?.cancel()
    let generation = probeGeneration
    let host = draft.probeConfig(detecting: true)
    detection = .running
    detectTask = track { [weak self] in
      guard let result = try? await environment.discovery.discover(host) else { return }
      guard let self, self.probeGeneration == generation else { return }
      let state = DetectionState(result)
      if case .found(let path, _) = state, var updated = self.draft, updated.id == host.id {
        updated.tmuxPath = path
        self.draft = updated
        self.testTask?.cancel()
        self.connectionTest = .idle
      }
      self.detection = state
      await self.record(
        Self.outcome(of: result.status), hostID: host.id, duration: result.duration,
        detail: "tmux detection: \(result.report?.tmuxPath == nil ? result.status.kind : "found")")
    }
  } // End of func detectTmux()

  /// Stops the probes, ignores their results and clears what they showed. The tasks stay in
  /// `runningTasks` until they end, so `probesFinished()` and `shutdown()` still wait for them.
  private func cancelProbes() {
    probeGeneration += 1
    testTask?.cancel()
    detectTask?.cancel()
    connectionTest = .idle
    detection = .idle
  }

  /// Returns once every running probe and opening has ended (tests).
  func probesFinished() async {
    while let task = runningTasks.values.first {
      await task.value
    }
  }

  // MARK: - iTerm2 profiles and SSH suggestions

  /// Asks for iTerm2's profiles (only while iTerm2 runs; never launching it). The answer is
  /// dropped when the window closed meanwhile or the calling task was cancelled.
  public func loadProfiles() async {
    guard let environment, !isShutDown else { return }
    let generation = windowGeneration
    profileChoices = .loading
    let result = await environment.profiles.profileNames()
    guard windowGeneration == generation, !Task.isCancelled else { return }
    profileChoices = ProfileChoices(result)
  }

  /// Reads the SSH destination suggestions (dropped like the profiles).
  func loadSuggestions() async {
    guard let environment, !isShutDown else { return }
    let generation = windowGeneration
    let names = await environment.sshSuggestions()
    guard windowGeneration == generation, !Task.isCancelled else { return }
    suggestions = names
  }

  // MARK: - Launch at login

  /// What the General tab shows.
  public var launchAtLogin: LaunchAtLoginContent? {
    loginItemStatus.map(LaunchAtLoginContent.init(status:))
  }

  /// Reads the login item status afresh (reading registers nothing).
  public func refreshLoginItemStatus() {
    guard let environment else { return }
    loginItemStatus = environment.loginItem.status
  }

  /// The toggle: registers or unregisters muxFinder, shows any error, then reads the status
  /// again.
  public func setLaunchAtLogin(_ isOn: Bool) {
    guard let environment else { return }
    let item = environment.loginItem
    loginItemError = nil
    let verb = isOn ? "on" : "off"
    do {
      if isOn { try item.register() } else { try item.unregister() }
      Task { await record(.success, detail: "launch at login turned \(verb)") }
    } catch {
      loginItemError =
        "muxFinder couldn't turn \(verb) launch at login. " + error.localizedDescription
      Task { await record(.failure, detail: "launch at login could not be turned \(verb)") }
    }
    loginItemStatus = item.status
  } // End of func setLaunchAtLogin(_:)

  // MARK: - Diagnostics

  /// One entry of the Diagnostics tab's log.
  public struct DiagnosticRow: Sendable, Hashable, Identifiable {
    /// The entry's position in the log.
    public var id: Int
    /// When it was recorded.
    public var time: Date
    /// Its category ("settings", "iterm2", …).
    public var category: String
    /// How the operation ended.
    public var outcome: DiagnosticOutcome
    /// The host's display name (its id when no host has it any more).
    public var host: String?
    /// "1480 ms", when the operation took time.
    public var duration: String?
    /// What happened.
    public var detail: String
  }

  /// The log, newest first.
  public var diagnosticRows: [DiagnosticRow] {
    diagnosticEvents.enumerated().reversed().map { index, event in
      DiagnosticRow(
        id: index, time: event.time, category: event.category.rawValue, outcome: event.outcome,
        host: DiagnosticsReport.hostName(for: event.hostID, in: hosts),
        duration: event.durationMs > 0 ? "\(event.durationMs) ms" : nil, detail: event.detail)
    }
  }

  /// Reads the log.
  public func refreshDiagnostics() async {
    guard let environment else { return }
    diagnosticEvents = await environment.diagnostics.events()
  }

  /// The text "Copy diagnostics" copies (see `DiagnosticsReport`).
  public func diagnosticsReport() async -> String {
    await refreshDiagnostics()
    return DiagnosticsReport.text(
      DiagnosticsReport.Input(
        appVersion: environment?.appVersion ?? "preview",
        systemVersion: environment?.systemVersion ?? "preview",
        generatedAt: environment?.now() ?? Date(timeIntervalSince1970: 0),
        hosts: hosts,
        hostListStatus: hostListStatus,
        refreshState: refreshState,
        loginItem: loginItemStatus,
        events: diagnosticEvents,
        globalShortcut: globalShortcut.diagnosticsCode))
  } // End of func diagnosticsReport()

  /// "Copy diagnostics": puts the report on the pasteboard.
  public func copyDiagnostics() async {
    guard let environment else { return }
    refreshLoginItemStatus()
    let text = await diagnosticsReport()
    environment.copyText(text)
    copyNotice = "Copied to the clipboard."
  }

  /// The last iTerm2 check's problem for the Diagnostics tab, with its fix-it.
  public var iTermProblem: (text: String, fixIt: FixIt?)? {
    guard case .failed(_, let error) = refreshState?.attachmentCheck else { return nil }
    var text = "muxFinder couldn't check which sessions are open in iTerm2."
    if let description = error?.errorDescription { text += " " + description }
    return (text, FixIt(error: error))
  }

  // MARK: - Fix-its

  /// Performs a fix-it: opens its System Settings pane (through the seams) or shows its
  /// explanation (again: hides it).
  public func perform(_ fixIt: FixIt) {
    switch fixIt.action {
    case .openURL(let url):
      environment?.openURL(url)
    case .explain:
      shownExplanation = shownExplanation == fixIt ? nil : fixIt
    case .openLoginItems:
      environment?.loginItem.openSystemSettingsLoginItems()
    }
  }

  // MARK: - Helpers

  /// Records a settings event (or one of `category`); the detail never holds a destination,
  /// path or profile name.
  func record(
    _ outcome: DiagnosticOutcome, category: DiagnosticCategory = .settings, hostID: UUID? = nil,
    duration: Duration = .zero, detail: String
  ) async {
    guard let environment else { return }
    let milliseconds =
      Int(duration.components.seconds * 1_000)
      + Int(duration.components.attoseconds / 1_000_000_000_000_000)
    await environment.diagnostics.record(
      category, outcome: outcome, hostID: hostID?.uuidString, durationMs: milliseconds,
      detail: detail)
  } // End of func record(_:category:hostID:duration:detail:)

  /// `success` for a host that answered, `failure` otherwise.
  static func outcome(of status: HostStatus) -> DiagnosticOutcome {
    switch status {
    case .ok, .noServer: return .success
    default: return .failure
    }
  }

  /// "saved", "notSavedYet", "invalid.notJSON", "unreadable".
  static func statusCode(_ status: HostListStatus) -> String {
    switch status {
    case .saved: return "saved"
    case .notSavedYet: return "notSavedYet"
    case .invalid(let problem): return "invalid.\(problem.code)"
    case .unreadable: return "unreadable"
    }
  }

  /// The name of an enum case without its values (no paths or names reach the log).
  static func caseName(of value: Any) -> String {
    Mirror(reflecting: value).children.first?.label ?? String(describing: value)
  }
}
