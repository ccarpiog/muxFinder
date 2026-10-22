import Foundation
import MuxFinderCore
import Observation

/// What the onboarding window runs on (PLAN.md D24): the same `HostStore` the app loads with
/// (so the save keeps D19's rules), "Set up SSH in iTerm2…" and the operation log. Tests pass
/// fakes, so `swift test` never saves the real `hosts.json`, opens a tab or contacts iTerm2.
public struct OnboardingEnvironment: Sendable {
  /// The host list file.
  public var store: any HostListPersisting
  /// Opens "Set up SSH in iTerm2…" tabs; `nil` offers no action.
  public var sshSetup: (any SSHSetupOpening)?
  /// The operation log, if any.
  public var diagnostics: DiagnosticsLog?

  /// Creates an environment from its parts.
  public init(
    store: any HostListPersisting,
    sshSetup: (any SSHSetupOpening)? = nil,
    diagnostics: DiagnosticsLog? = nil
  ) {
    self.store = store
    self.sshSetup = sshSetup
    self.diagnostics = diagnostics
  }
}

/// The fixed text of the onboarding window (PLAN.md Phase 9 *Onboarding*): the brief's four
/// expectations, one line each, the scope line and the iTerm2 requirements. English, sentence
/// case.
public enum OnboardingText {
  /// The window's title.
  public static let title = "Welcome to muxFinder"
  /// The line under the title.
  public static let introduction =
    "muxFinder finds the tmux sessions on your Macs and opens them in iTerm2."
  /// The note above the hosts.
  public static let hostsNote =
    "Saturno, Neptuno and Sirio are examples, all turned off. Rename them, choose which one is "
    + "this Mac, and give each Mac you want to reach an SSH destination. Nothing is saved until "
    + "you choose Save hosts; you can change everything later in Settings."
  /// The brief's four expectations, one line each.
  public static let expectations = [
    "The Mac a session runs on must stay on and reachable.",
    "Closing a tab or losing the connection doesn't end the session.",
    "Restarting a Mac ends the programs running in its sessions.",
    "muxFinder doesn't sync files or move running programs between Macs.",
  ]
  /// The scope line.
  public static let scope =
    "muxFinder shows each Mac's default tmux server only, not servers started with tmux -L or -S."
  /// The iTerm2 requirements.
  public static let iTermRequirements = [
    "iTerm2's Python API must be on: in iTerm2, choose Settings › General › Magic and turn on "
      + "Enable Python API.",
    "The first time muxFinder talks to iTerm2, macOS asks whether muxFinder may control iTerm2. "
      + "Allow it once; you can change it later in System Settings › Privacy & Security › "
      + "Automation.",
  ]
}

/// The onboarding window's model (PLAN.md Phase 9b, D24): the onboarding examples (D19's
/// `notSavedYet` defaults: Saturno, Neptuno and Sirio, SSH, no destination, turned off) as
/// editable drafts, the explicit "This Mac" choice, "Set up SSH in iTerm2…" for SSH hosts, and
/// one save.
///
/// - **When:** the app prepares it from the load result at launch and shows the window only
///   while the host list is `notSavedYet` (`prepare(_:)`); a saved list never shows it, and an
///   unusable one keeps Settings' banner (D23).
/// - **Editing** reuses the Settings editor's `HostDraft` and `HostDraftIssues` rules (name
///   required and unique, a valid destination to turn an SSH host on). This Mac is exclusive:
///   choosing a host makes it local and turned on and turns the previous This Mac back into an
///   SSH host, turned off (D19's switch).
/// - **Saving** goes only through the store's `save(_:expecting:)` with the revision the list
///   was loaded with, so a file that appeared since (Settings saved, say) is never replaced:
///   the save is refused and the window says so. Closing the window, or "Not now", writes
///   nothing; onboarding then shows again at the next launch.
/// - **Nothing runs by itself:** preparing or opening the window reads nothing, contacts no
///   iTerm2 and runs no ssh or tmux; only "Set up SSH in iTerm2…" opens a tab, when clicked.
@MainActor
@Observable
public final class OnboardingModel {
  /// The message shown when the save found the host list file changed since launch.
  nonisolated public static let fileChangedMessage =
    "The host list file changed after muxFinder loaded it (for example, it was saved in "
    + "Settings), so nothing was saved here. Open Settings to see the host list as it is now."

  /// The hosts being edited, in display order.
  public private(set) var drafts: [HostDraft] = []
  /// Whether `prepare(_:)` took a `notSavedYet` list (or a fixture is shown).
  public private(set) var isPrepared = false
  /// Whether a save runs.
  public private(set) var isSaving = false
  /// Why the last save failed.
  public private(set) var saveError: String?
  /// Whether the save was refused because the file changed since it was loaded.
  public private(set) var fileChanged = false
  /// Whether the list was saved.
  public private(set) var didSave = false
  /// Why a host could not be turned on, by host id.
  public private(set) var enableRefusals: [UUID: String] = [:]
  /// Whether the window is open.
  public private(set) var isWindowOpen = false
  /// "Set up SSH in iTerm2…" for the drafts.
  public let sshSetup: SSHSetupActions
  /// Whether this model renders a fixture.
  public let isPreview: Bool

  /// Called after the save with the list now on disk (`AppModel` hands it to the engine).
  @ObservationIgnored public var onHostListSaved: (@MainActor (HostList) -> Void)?
  /// Opens the Settings window ("Open Settings" after a refused save).
  @ObservationIgnored public var onOpenSettings: (@MainActor () -> Void)?
  /// Closes the window (set by the window's controller).
  @ObservationIgnored public var closeWindow: (@MainActor () -> Void)?
  /// The dependencies; `nil` for a fixture.
  @ObservationIgnored private let environment: OnboardingEnvironment?
  /// The file's revision as loaded, which the save expects.
  @ObservationIgnored private var revision: HostFileRevision?
  /// Whether `shutdown()` ran: nothing new starts.
  @ObservationIgnored private var isShutDown = false

  /// A model over `environment`. Nothing runs, and nothing is shown, until `prepare(_:)`.
  public init(environment: OnboardingEnvironment) {
    self.environment = environment
    isPreview = false
    sshSetup = SSHSetupActions(opener: environment.sshSetup)
  }

  /// A model that shows `fixture` and never runs anything.
  public init(fixture: OnboardingFixture) {
    environment = nil
    isPreview = true
    drafts = fixture.drafts
    isPrepared = !fixture.drafts.isEmpty
    isSaving = fixture.isSaving
    saveError = fixture.saveError
    fileChanged = fixture.fileChanged
    enableRefusals = fixture.enableRefusals
    sshSetup = SSHSetupActions(opener: nil, states: fixture.sshSetupStates)
  }

  // MARK: - Showing

  /// Whether onboarding is shown for a list loaded as `state`: only `notSavedYet` (no file
  /// yet). A saved list never shows it; an unusable file keeps Settings' banner instead.
  public static func isShown(for state: HostStoreLoadResult.State) -> Bool {
    state == .notSavedYet
  }

  /// Takes the launch's load result: for a `notSavedYet` list, its examples become the drafts
  /// and its revision the one the save expects, and the result is `true` (show the window).
  /// Any other state, a fixture, a second call or a call after `shutdown()` changes nothing and
  /// gives `false` (a second call while prepared gives `true` again). Reads nothing itself.
  @discardableResult
  public func prepare(_ result: HostStoreLoadResult) -> Bool {
    guard environment != nil, !isShutDown, Self.isShown(for: result.state) else { return false }
    guard !isPrepared else { return !didSave }
    drafts = result.hosts.hosts.map(HostDraft.init)
    revision = result.revision
    isPrepared = true
    return true
  } // End of func prepare(_:)

  /// The window opened.
  public func windowDidOpen() {
    isWindowOpen = true
  }

  /// The window closed: requests for ssh tabs still running are cancelled and their lines
  /// forgotten. Nothing is written; without a save, onboarding shows again at the next launch.
  public func windowDidClose() {
    guard isWindowOpen else { return }
    isWindowOpen = false
    sshSetup.cancelAll()
    if !didSave, environment != nil {
      Task { await record(.info, detail: "onboarding closed without saving") }
    }
  }

  /// "Not now": closes the window, writing nothing.
  public func notNow() {
    closeWindow?()
  }

  /// "Open Settings" (after a refused save).
  public func openSettings() {
    onOpenSettings?()
  }

  /// Quitting (`AppModel.shutdown()`): nothing new starts, and running ssh tab requests are
  /// cancelled and awaited.
  public func shutdown() async {
    isShutDown = true
    await sshSetup.shutdown()
  }

  // MARK: - Editing

  /// Whether the drafts may be changed and saved: prepared, not saving, not saved yet, and no
  /// save refused because the file changed.
  public var isEditable: Bool {
    isPrepared && !isSaving && !didSave && !fileChanged && !isShutDown
  }

  /// The draft with `id`, if any.
  public func draft(_ id: UUID) -> HostDraft? {
    drafts.first { $0.id == id }
  }

  /// The host chosen as This Mac, if any.
  public var thisMacID: UUID? {
    drafts.first { $0.mode == .local }?.id
  }

  /// `id`'s inline errors, checked against the other drafts (`HostDraftIssues`).
  public func issues(for id: UUID) -> HostDraftIssues? {
    guard let draft = draft(id) else { return nil }
    return HostDraftIssues(
      draft: draft, otherHosts: drafts.filter { $0.id != id }.map(\.config))
  }

  /// Whether every draft is free of inline errors.
  public var isValid: Bool {
    drafts.allSatisfy { issues(for: $0.id)?.isValid == true }
  }

  /// Whether "Save hosts" is available.
  public var canSave: Bool {
    isEditable && isValid && environment != nil
  }

  /// Sets `id`'s display name.
  public func setDisplayName(_ name: String, for id: UUID) {
    edit(id) { $0.displayName = name }
  }

  /// Sets `id`'s SSH destination; a ssh setup line about the old value is forgotten.
  public func setDestination(_ destination: String, for id: UUID) {
    guard draft(id)?.sshDestination != destination else { return }
    edit(id) { $0.sshDestination = destination }
    sshSetup.clear(id)
  }

  /// Turns `id` on or off. Turning on an SSH host without a valid destination is refused
  /// (PLAN.md D19): nothing changes, `enableRefusals` says why, and the result is `false`.
  @discardableResult
  public func setEnabled(_ isEnabled: Bool, for id: UUID) -> Bool {
    guard isEditable, let draft = draft(id) else { return false }
    if isEnabled, !draft.canTurnOn {
      enableRefusals[id] = HostDraftIssues.destinationNeededToTurnOn
      return false
    }
    edit(id) { $0.isEnabled = isEnabled }
    return true
  }

  /// The "This Mac" choice (`nil`: none). The chosen host becomes local and turned on; the
  /// previous This Mac, if another, goes back to SSH, turned off, its destination kept (D19's
  /// switch), so at most one host is ever This Mac.
  public func chooseThisMac(_ id: UUID?) {
    guard isEditable, id != thisMacID else { return }
    if let id, draft(id) == nil { return }
    for index in drafts.indices {
      if drafts[index].id == id {
        drafts[index].mode = .local
        drafts[index].isEnabled = true
        enableRefusals[drafts[index].id] = nil
        sshSetup.clear(drafts[index].id)
      } else if drafts[index].mode == .local {
        drafts[index].mode = .ssh
        drafts[index].isEnabled = false
      }
    } // End of loop over the drafts
    saveError = nil
  } // End of func chooseThisMac(_:)

  /// Applies `change` to `id`'s draft while editable.
  private func edit(_ id: UUID, _ change: (inout HostDraft) -> Void) {
    guard isEditable, let index = drafts.firstIndex(where: { $0.id == id }) else { return }
    change(&drafts[index])
    saveError = nil
    if drafts[index].canTurnOn { enableRefusals[id] = nil }
  }

  // MARK: - SSH setup

  /// Whether "Set up SSH in iTerm2…" is offered for `id`: an SSH host with a valid
  /// destination, while editable and no request for it runs.
  public func canSetUpSSH(_ id: UUID) -> Bool {
    guard isEditable, let draft = draft(id) else { return false }
    return SSHSetupActions.isOffered(for: draft.config) && !sshSetup.isOpening(id)
  }

  /// "Set up SSH in iTerm2…": opens a tab running ssh to `id`'s destination as typed (nothing
  /// is saved for it).
  public func setUpSSH(for id: UUID) {
    guard canSetUpSSH(id), let draft = draft(id) else { return }
    sshSetup.open(draft.config)
  }

  // MARK: - Saving

  /// "Save hosts": saves the drafts as the host list through the store, expecting the file as
  /// it was at launch (none). On success the app runs with the list and the window closes; a
  /// file that changed meanwhile is left as it is (`fileChanged`), and any other failure is
  /// shown. Returns whether it was saved.
  @discardableResult
  public func save() async -> Bool {
    guard let environment, canSave, let revision else { return false }
    let list: HostList
    do throws(HostListError) {
      list = try HostList(drafts.map(\.config))
    } catch {
      saveError = error.message
      return false
    }
    isSaving = true
    defer { isSaving = false }
    saveError = nil
    let result: HostStoreSaveResult
    do {
      result = try await environment.store.save(list, expecting: revision)
    } catch .fileChanged {
      fileChanged = true
      saveError = Self.fileChangedMessage
      await record(.failure, detail: "onboarding save refused: the file changed")
      return false
    } catch {
      saveError = error.errorDescription ?? "muxFinder couldn't save the host list."
      await record(.failure, detail: "onboarding save failed: \(SettingsModel.caseName(of: error))")
      return false
    }
    didSave = true
    self.revision = result.revision
    onHostListSaved?(list)
    let kept = result.displacedFileError == nil ? "" : ", displaced file not kept"
    await record(
      .success,
      detail: "onboarding saved: \(list.enabledHosts.count) of \(list.hosts.count) hosts turned "
        + "on, This Mac \(list.thisMac == nil ? "not chosen" : "chosen")\(kept)")
    closeWindow?()
    return true
  } // End of func save()

  /// Records an onboarding event (no names, destinations or paths).
  private func record(_ outcome: DiagnosticOutcome, detail: String) async {
    await environment?.diagnostics?.record(.settings, outcome: outcome, detail: detail)
  }
}
