import Foundation
import MuxFinderCore

/// One fixed Settings window state for previews, the `--preview-gallery settings` window and
/// tests (PLAN.md D23). Built from synthetic data only.
public struct SettingsFixture: Sendable, Identifiable {
  /// A short, stable name.
  public var id: String
  /// The caption shown above the state in the preview window.
  public var title: String
  /// The tab shown.
  public var tab: SettingsModel.Tab = .hosts
  /// How the host list loaded.
  public var hostListStatus: HostListStatus? = .saved
  /// The host list.
  public var hosts: HostList
  /// Whether replacing an unusable file was confirmed.
  public var hasReplaceConsent = false
  /// What the editor shows.
  public var selection: SettingsModel.Selection?
  /// The editor's working copy.
  public var draft: HostDraft?
  /// The draft as saved.
  public var savedDraft: HostDraft?
  /// A save's error.
  public var saveError: String?
  /// A save's notice.
  public var saveNotice: String?
  /// Why the host could not be turned on.
  public var enableRefusal: String?
  /// "Test connection".
  public var connectionTest = ConnectionTestState.idle
  /// "Detect".
  public var detection = DetectionState.idle
  /// The profile picker's choices.
  public var profileChoices = ProfileChoices.available(SettingsFixtures.profileNames)
  /// SSH destination suggestions.
  public var suggestions = SettingsFixtures.suggestionNames
  /// The login item status.
  public var loginItemStatus: LoginItemStatus? = .notRegistered
  /// A launch-at-login error.
  public var loginItemError: String?
  /// The operation log.
  public var diagnosticEvents: [DiagnosticEvent] = []
  /// "Copy diagnostics"'s notice.
  public var copyNotice: String?
  /// The refresh engine's state.
  public var refreshState: RefreshState?
  /// The explaining fix-it whose text is shown.
  public var shownExplanation: FixIt?

  /// A fixture of `hosts` with `configure` applied.
  public init(
    id: String, title: String, hosts: HostList,
    configure: (inout SettingsFixture) -> Void = { _ in }
  ) {
    self.id = id
    self.title = title
    self.hosts = hosts
    configure(&self)
  }

  /// Selects `host` with its saved draft.
  mutating func select(_ host: HostConfig) {
    selection = .host(host.id)
    draft = HostDraft(host)
    savedDraft = HostDraft(host)
  }
}

/// Every Settings state, from synthetic data only: the popover fixtures' hosts (`*.example`
/// destinations), invented profile and suggestion names, a fixed log. Building them runs
/// nothing.
public enum SettingsFixtures {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// The synthetic iTerm2 profile names.
  public static let profileNames = ["Default", "Presentation", "Work"]
  /// The synthetic SSH configuration suggestions.
  public static let suggestionNames = ["build-box.example", "lab-mac.example", "saturno.example"]

  /// Vega: an SSH host not set up yet, turned off.
  public static let vega = HostConfig(
    id: Fixtures.fixtureID(4), displayName: "Vega", mode: .ssh, isEnabled: false)

  /// Neptuno (This Mac), Saturno, Sirio and Vega.
  public static let hostList = try! HostList([
    Fixtures.neptuno, Fixtures.saturno, Fixtures.sirio, vega,
  ])

  /// The examples with fixed ids, as the onboarding defaults look.
  static let examples = try! HostList(
    ["Saturno", "Neptuno", "Sirio"].enumerated().map { index, name in
      HostConfig(
        id: Fixtures.fixtureID(10 + index), displayName: name, mode: .ssh, isEnabled: false)
    })

  /// The engine's state for `hostList`: This Mac and Saturno answered, Sirio is unreachable.
  static let refreshState = Fixtures.state(Fixtures.overviewHosts)

  /// An inert, empty model state (the popover fixtures' Settings model).
  public static let blank = SettingsFixture(id: "blank", title: "Blank", hosts: HostList()) {
    $0.hostListStatus = nil
    $0.loginItemStatus = nil
    $0.profileChoices = .notLoaded
    $0.suggestions = []
  }

  // MARK: - Hosts tab

  /// The host list with Saturno in the editor, its profile picked from iTerm2's, and a
  /// successful connection test.
  public static let hosts = SettingsFixture(
    id: "hosts", title: "Hosts and the host editor", hosts: hostList
  ) {
    var saturno = Fixtures.saturno
    saturno.iTermProfileName = "Work"
    $0.hosts = try! HostList([Fixtures.neptuno, saturno, Fixtures.sirio, vega])
    $0.select(saturno)
    $0.refreshState = refreshState
    $0.connectionTest = .finished(
      ConnectionTestResult(status: .reachable, detail: "2 sessions · tmux 3.8"))
  }

  /// Sirio edited into several validation errors: no name, a destination with a space, a
  /// relative tmux path, turned on without a valid destination.
  public static let validation = SettingsFixture(
    id: "validation", title: "Editor with validation errors", hosts: hostList
  ) {
    $0.select(Fixtures.sirio)
    $0.draft?.displayName = ""
    $0.draft?.sshDestination = "sirio .example"
    $0.draft?.tmuxPath = "bin/tmux"
    $0.refreshState = refreshState
  }

  /// Saturno being made This Mac (Neptuno would go back to SSH, turned off), after "Detect"
  /// found tmux.
  public static let thisMac = SettingsFixture(
    id: "this-mac", title: "Choosing This Mac", hosts: hostList
  ) {
    $0.select(Fixtures.saturno)
    $0.draft?.mode = .local
    $0.draft?.tmuxPath = "/opt/homebrew/bin/tmux"
    $0.detection = .found(path: "/opt/homebrew/bin/tmux", version: "tmux 3.8")
    $0.refreshState = refreshState
  }

  /// Sirio's connection test asking for a sign-in, and the profile list refused by macOS
  /// (Automation), with its fix-it.
  public static let testFailed = SettingsFixture(
    id: "test-failed", title: "Test connection and a fix-it", hosts: hostList
  ) {
    $0.select(Fixtures.sirio)
    $0.connectionTest = .finished(
      ConnectionTestResult(
        status: .signInNeeded, explanation: HostProblemText.explanation(for: .authFailed)))
    $0.profileChoices = .failed(.automationDenied)
    $0.refreshState = refreshState
  }

  /// An unusable host list file: left as it is, shown with its problem, nothing editable.
  public static let invalidFile = SettingsFixture(
    id: "invalid-file", title: "Unusable host list file", hosts: examples
  ) {
    $0.hostListStatus = .invalid(.notJSON)
    $0.select(examples.hosts[0])
    $0.profileChoices = .iTermNotRunning
  }

  /// The examples before anything is saved, a new host being added, iTerm2 not running.
  public static let newHost = SettingsFixture(
    id: "new-host", title: "Examples and a new host", hosts: examples
  ) {
    $0.hostListStatus = .notSavedYet
    $0.selection = .newHost
    var draft = HostDraft.newHost(id: Fixtures.fixtureID(20))
    draft.displayName = "Lab Mac"
    draft.sshDestination = "lab-mac.example"
    draft.isEnabled = true
    $0.draft = draft
    $0.profileChoices = .iTermNotRunning
  }

  // MARK: - General tab

  /// A General tab fixture for `status`, with `error` if given.
  static func general(
    _ id: String, _ title: String, _ status: LoginItemStatus, error: String? = nil
  ) -> SettingsFixture {
    SettingsFixture(id: id, title: title, hosts: hostList) {
      $0.tab = .general
      $0.loginItemStatus = status
      $0.loginItemError = error
    }
  }

  /// Launch at login on.
  public static let loginEnabled = general("login-enabled", "Launch at login: on", .enabled)

  /// Launch at login off, after a failed attempt to turn it on.
  public static let loginNotRegistered = general(
    "login-off", "Launch at login: off, with an error", .notRegistered,
    error: "muxFinder couldn't turn on launch at login. The operation couldn’t be completed.")

  /// Waiting for the user's approval, with the fix-it.
  public static let loginRequiresApproval = general(
    "login-approval", "Launch at login: needs approval", .requiresApproval)

  /// Not found (not an installed app bundle).
  public static let loginNotFound = general(
    "login-not-found", "Launch at login: not found", .notFound)

  // MARK: - Diagnostics tab

  /// The log, newest first, with the iTerm2 check's problem and its explanation shown.
  public static let diagnostics = SettingsFixture(
    id: "diagnostics", title: "Diagnostics", hosts: hostList
  ) {
    $0.tab = .diagnostics
    $0.refreshState = Fixtures.state(
      Fixtures.overviewHosts, attachmentCheck: .failed(at: Fixtures.now, error: .apiDisabled))
    $0.shownExplanation = .explainPythonAPI
    $0.diagnosticEvents = events
    $0.copyNotice = "Copied to the clipboard."
  }

  /// A synthetic log (no destinations, paths or names; host ids only).
  static let events: [DiagnosticEvent] = [
    event(-600, .settings, .info, nil, 0, "host list at launch: saved, 3 of 4 hosts turned on"),
    event(-420, .iTerm2, .failure, nil, 12, "iTerm2 API connection failed: apiDisabled"),
    event(-300, .settings, .success, Fixtures.saturno.id, 1_480, "connection test: ok"),
    event(-240, .settings, .failure, Fixtures.sirio.id, 5_012, "connection test: authFailed"),
    event(-120, .settings, .success, Fixtures.saturno.id, 0, "host saved"),
    event(-30, .settings, .success, nil, 0, "launch at login turned on"),
  ]

  /// One log entry `secondsAgo` before the fixtures' `now`.
  static func event(
    _ secondsAgo: TimeInterval, _ category: DiagnosticCategory, _ outcome: DiagnosticOutcome,
    _ host: UUID?, _ milliseconds: Int, _ detail: String
  ) -> DiagnosticEvent {
    DiagnosticEvent(
      time: Fixtures.now.addingTimeInterval(secondsAgo), category: category,
      hostID: host?.uuidString, outcome: outcome, durationMs: milliseconds, detail: detail)
  }

  /// Every fixture, in the preview window's order.
  public static let all = [
    hosts, validation, thisMac, testFailed, invalidFile, newHost, diagnostics, loginEnabled,
    loginNotRegistered, loginRequiresApproval, loginNotFound,
  ]
}
