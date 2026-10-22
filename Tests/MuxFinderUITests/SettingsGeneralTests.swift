import Foundation
import ServiceManagement
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// Launch at login on a fake login item, "Copy diagnostics", the fix-its, the Settings
/// fixtures, and the app model's side of Settings. No login item, pasteboard, System Settings
/// pane or window is touched.
@Suite("Settings: general, diagnostics and fix-its")
@MainActor
struct SettingsGeneralTests {
  /// Shorthand.
  typealias Support = SettingsTestSupport

  // MARK: - Launch at login

  /// Every `SMAppService.Status` maps to a status, and every status to what the General tab
  /// shows: on/off, the explanation, the fix-it for approval, the honest "not found" message.
  @Test func launchAtLoginStatusMapping() {
    #expect(LoginItemStatus(SMAppService.Status.enabled) == .enabled)
    #expect(LoginItemStatus(SMAppService.Status.notRegistered) == .notRegistered)
    #expect(LoginItemStatus(SMAppService.Status.requiresApproval) == .requiresApproval)
    #expect(LoginItemStatus(SMAppService.Status.notFound) == .notFound)
    #expect(LoginItemStatus(SMAppService.Status(rawValue: 99)!) == .unknown(99))
    let enabled = LaunchAtLoginContent(status: .enabled)
    #expect(enabled.isOn && enabled.fixIt == nil)
    #expect(enabled.message == "muxFinder opens when you log in.")
    let off = LaunchAtLoginContent(status: .notRegistered)
    #expect(!off.isOn && off.fixIt == nil)
    let approval = LaunchAtLoginContent(status: .requiresApproval)
    #expect(approval.isOn)
    #expect(approval.fixIt == .openLoginItemsSettings)
    #expect(approval.message.contains("System Settings › General › Login Items"))
    let notFound = LaunchAtLoginContent(status: .notFound)
    #expect(!notFound.isOn && notFound.fixIt == nil)
    #expect(notFound.message.contains("/Applications"))
    #expect(LaunchAtLoginContent(status: .unknown(7)).message.contains("(7)"))
    #expect(
      [LoginItemStatus.enabled, .notRegistered, .requiresApproval, .notFound, .unknown(3)]
        .map(\.code) == ["enabled", "notRegistered", "requiresApproval", "notFound", "unknown(3)"])
  } // End of func launchAtLoginStatusMapping()

  /// The toggle round-trips on the fake: on registers, off unregisters, each re-reading the
  /// status; approval shows its fix-it, which opens Login Items through the seam; an error is
  /// shown and the status read again.
  @Test func launchAtLoginRoundTrip() async {
    let item = FakeLoginItem(.notRegistered)
    let (model, _) = await Support.openModel([], loginItem: item)
    #expect(model.loginItemStatus == .notRegistered)
    #expect(model.launchAtLogin?.isOn == false)
    model.setLaunchAtLogin(true)
    #expect(item.registerCalls == 1)
    #expect(model.loginItemStatus == .enabled)
    #expect(model.launchAtLogin?.isOn == true)
    model.setLaunchAtLogin(false)
    #expect(item.unregisterCalls == 1)
    #expect(model.loginItemStatus == .notRegistered)
    item.statusAfterRegister = .requiresApproval
    model.setLaunchAtLogin(true)
    #expect(model.loginItemStatus == .requiresApproval)
    #expect(model.loginItemError == nil)
    let fixIt = model.launchAtLogin?.fixIt
    #expect(fixIt == .openLoginItemsSettings)
    if let fixIt { model.perform(fixIt) }
    #expect(item.openSettingsCalls == 1)
    item.currentStatus = .notFound
    item.error = FakeLoginItemError()
    let reads = item.statusReads
    model.setLaunchAtLogin(true)
    #expect(
      model.loginItemError
        == "muxFinder couldn't turn on launch at login. Operation not permitted.")
    #expect(item.statusReads == reads + 1)
    #expect(model.loginItemStatus == .notFound)
    #expect(model.launchAtLogin?.message.contains("/Applications") == true)
    model.setLaunchAtLogin(false)
    #expect(model.loginItemError?.hasPrefix("muxFinder couldn't turn off launch at login.") == true)
    item.error = nil
    model.setLaunchAtLogin(true)
    #expect(model.loginItemError == nil)
  } // End of func launchAtLoginRoundTrip()

  // MARK: - Diagnostics

  /// "Copy diagnostics" puts plain text on the pasteboard: versions, launch at login, the host
  /// list, the iTerm2 check, each host by name and id with its status, and the log. It never
  /// holds a destination, tmux path, profile name, session name or a probe's message.
  @Test func copyDiagnosticsShapeAndContent() async throws {
    var saturno = Support.sshHost("Saturno")
    saturno.sshDestination = "secret-dest.example"
    saturno.tmuxPathOverride = "/Users/someone/bin/tmux"
    saturno.iTermProfileName = "Secret Profile"
    let local = HostConfig(displayName: "Neptuno", mode: .local)
    let seams = SeamRecorder()
    let diagnostics = DiagnosticsLog(writesToSystemLog: false, now: { UITestSupport.now })
    await diagnostics.record(
      .settings, outcome: .success, hostID: saturno.id.uuidString, durationMs: 1_480,
      detail: "connection test: ok")
    await diagnostics.record(.iTerm2, outcome: .failure, hostID: "not-an-id", detail: "x")
    let store = FakeHostListStore(Support.loaded([saturno, local]))
    let model = SettingsModel(
      environment: Support.environment(
        store: store, loginItem: FakeLoginItem(.enabled), seams: seams,
        diagnostics: diagnostics))
    await model.windowDidOpen()
    var failed = PreviewFixtures.snapshot(
      saturno,
      outcome: .failed(.probeError("ssh failed: connect to host secret-dest.example port 22")),
      sessions: [PreviewFixtures.session("secret-session", id: 1, on: saturno, windows: 1)],
      lastSuccessAgo: 60, lastAttemptAgo: 5)
    failed.consecutiveFailures = 3
    model.refreshState = PreviewFixtures.state(
      [failed, PreviewFixtures.snapshot(local, outcome: .noServer, lastSuccessAgo: 5)],
      attachmentCheck: .failed(at: UITestSupport.now, error: .apiDisabled))
    await model.copyDiagnostics()
    #expect(model.copyNotice == "Copied to the clipboard.")
    let text = try #require(seams.copied.first)
    #expect(seams.copied.count == 1)
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines[0] == "muxFinder diagnostics")
    #expect(lines[1].hasPrefix("Generated: 2027-01-15T"))
    #expect(lines[2] == "muxFinder: 1.2.3 (45)")
    #expect(lines[3] == "macOS: Version 27.2 (Build 27C00)")
    #expect(lines[4] == "Launch at login: enabled")
    #expect(lines[5] == "Host list: saved; 2 hosts, 2 turned on")
    #expect(lines[6].hasPrefix("iTerm2 check: failed ") && lines[6].hasSuffix("(apiDisabled)"))
    #expect(lines.contains("Hosts (2):"))
    #expect(
      lines.contains(
        "- Saturno (\(saturno.id.uuidString)): SSH, turned on, tmux path set, iTerm2 profile set"))
    let status = try #require(lines.first { $0.hasPrefix("  Status: Check failed (probeError)") })
    #expect(status.contains("1 session (stale)"))
    #expect(status.contains("failures in a row: 3"))
    #expect(lines.contains { $0.hasPrefix("  Status: This Mac;") })
    #expect(lines.contains("Log (\(model.diagnosticEvents.count) entries, oldest first):"))
    #expect(
      lines.contains { $0.hasSuffix("settings success host Saturno 1480 ms: connection test: ok") })
    #expect(lines.contains { $0.hasSuffix("iterm2 failure host unknown: x") })
    #expect(text.hasSuffix(DiagnosticsReport.exclusionNote + "\n"))
    for forbidden in [
      "secret-dest", "/Users/someone", "Secret Profile", "secret-session", "connect to host",
      "neptuno.fixture", "not-an-id",
    ] {
      #expect(!text.contains(forbidden), "the report holds \(forbidden)")
    }
  } // End of func copyDiagnosticsShapeAndContent()

  /// The Diagnostics tab lists the log newest first, with host names; a failed iTerm2 check is
  /// shown with its fix-it.
  @Test func diagnosticsTab() async {
    let model = SettingsModel(fixture: SettingsFixtures.diagnostics)
    let rows = model.diagnosticRows
    #expect(rows.count == SettingsFixtures.events.count)
    #expect(rows.first?.detail == "launch at login turned on")
    #expect(rows.last?.detail.hasPrefix("host list at launch") == true)
    #expect(rows.contains { $0.host == "Saturno" && $0.duration == "1480 ms" })
    let problem = model.iTermProblem
    #expect(problem?.fixIt == .explainPythonAPI)
    #expect(problem?.text.contains("Enable Python API") == true)
  } // End of func diagnosticsTab()

  // MARK: - Fix-its

  /// Automation-denied errors open the Automation pane; API-disabled errors explain the iTerm2
  /// setting; other errors have none. `notSent` is looked through, and attach failures carrying
  /// an iTerm2 error get the same fix-it.
  @Test func fixItSelection() {
    #expect(FixIt(error: .automationDenied) == .openAutomationSettings)
    #expect(FixIt(error: .apiDisabled) == .explainPythonAPI)
    #expect(FixIt(error: .notSent(.automationDenied)) == .openAutomationSettings)
    #expect(FixIt(error: .notSent(.apiDisabled)) == .explainPythonAPI)
    for error: ITerm2Error? in [
      nil, .notRunning, .timedOut, .authRejected, .cookieUnavailable(appleScriptError: -1),
      .notSent(.timedOut), .requestFailed("x"),
    ] {
      #expect(FixIt(error: error) == nil)
    }
    #expect(FixIt(failure: .iTerm2(.automationDenied)) == .openAutomationSettings)
    #expect(FixIt(failure: .attachmentCheckFailed(.apiDisabled)) == .explainPythonAPI)
    #expect(FixIt(failure: .identityCheckFailed(.notSent(.apiDisabled))) == .explainPythonAPI)
    #expect(FixIt(failure: .identityCheckFailed(nil)) == nil)
    #expect(FixIt(failure: .timedOut) == nil)
    #expect(
      FixIt.openAutomationSettings.action
        == .openURL(
          URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!
        ))
    #expect(FixIt.explainPythonAPI.action == .explain)
    let explanation = FixIt.explainPythonAPI.explanation ?? ""
    #expect(explanation.contains("General › Magic") && explanation.contains("Enable Python API"))
    #expect(FixIt.openLoginItemsSettings.action == .openLoginItems)
    #expect(FixIt.openAutomationSettings.explanation == nil)
    #expect(FixIt.allCases.map(\.buttonTitle).allSatisfy { $0.first?.isUppercase == true })
  } // End of func fixItSelection()

  /// Performing a fix-it goes through the seams: the Automation URL to `openURL`, the
  /// explanation shown and hidden (no URL), Login Items to the login item.
  @Test func fixItsGoThroughSeams() async {
    let seams = SeamRecorder()
    let item = FakeLoginItem(.requiresApproval)
    let (model, _) = await Support.openModel([], loginItem: item, seams: seams)
    model.perform(.openAutomationSettings)
    #expect(seams.openedURLs == [FixIt.automationSettingsURL])
    model.perform(.explainPythonAPI)
    #expect(model.shownExplanation == .explainPythonAPI)
    model.perform(.explainPythonAPI)
    #expect(model.shownExplanation == nil)
    #expect(seams.openedURLs.count == 1)
    model.perform(.openLoginItemsSettings)
    #expect(item.openSettingsCalls == 1)
  } // End of func fixItsGoThroughSeams()

  /// The popover shows fix-its too: on a failed iTerm2 check's notice and on a session's
  /// iTerm2 failure; the app model performs them through its own `openURL`.
  @Test func popoverFixIts() {
    let seams = SeamRecorder()
    let environment = AppEnvironment(
      loadHosts: { Support.loaded([]) },
      makeEngine: { RefreshCoordinator(hosts: $0, discovery: FakeDiscovery()) },
      makeSystemEvents: { _ in nil },
      terminate: {},
      openURL: { seams.openedURLs.append($0) })
    let model = AppModel(environment: environment)
    model.perform(.openAutomationSettings)
    #expect(seams.openedURLs == [FixIt.automationSettingsURL])
    model.perform(.explainPythonAPI)
    #expect(model.shownExplanation == .explainPythonAPI)
    let notice = PopoverContent(
      state: PreviewFixtures.iTermCheckFailed.state, hostList: .saved, query: "", activities: [:],
      selection: nil, now: PreviewFixtures.now
    ).notices.first
    #expect(notice?.fixIt == .explainPythonAPI)
    let activity = SessionActivity(.failed(.iTerm2(.automationDenied)))
    #expect(activity.problem?.message == ITerm2Error.automationDenied.errorDescription)
    #expect(activity.problem?.fixIt == .openAutomationSettings)
    #expect(SessionActivity(.failed(.timedOut)).problem?.fixIt == nil)
  } // End of func popoverFixIts()

  // MARK: - The app model and Settings

  /// ⌘, and the footer's button present the Settings window for the model's settings.
  @Test func openSettingsPresentsTheWindow() {
    let seams = SeamRecorder()
    let environment = AppEnvironment(
      loadHosts: { Support.loaded([]) },
      makeEngine: { RefreshCoordinator(hosts: $0, discovery: FakeDiscovery()) },
      makeSystemEvents: { _ in nil },
      terminate: {},
      presentSettings: { seams.presented.append(ObjectIdentifier($0)) })
    let model = AppModel(environment: environment)
    #expect(model.handle(.settings) == .handled)
    model.openSettings()
    let settings = ObjectIdentifier(model.settings)
    #expect(seams.presented == [settings, settings])
    #expect(model.finishedActions.isEmpty)
  } // End of func openSettingsPresentsTheWindow()

  /// A list saved in Settings becomes the engine's list: the new host is discovered and listed,
  /// and the popover's notice about the examples goes away.
  @Test func savedListReachesTheEngine() async throws {
    let discovery = FakeDiscovery()
    let store = FakeHostListStore(
      HostStoreLoadResult(hosts: .onboardingDefaults(), state: .notSavedYet))
    let environment = AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: {
        RefreshCoordinator(
          hosts: $0, discovery: discovery, configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: Support.environment(store: store))
    let model = AppModel(environment: environment)
    await model.start()
    #expect(model.hostListStatus == .notSavedYet)
    await model.settings.windowDidOpen()
    let first = try #require(model.settings.draft)
    model.settings.setDestination("saturno.example")
    #expect(model.settings.setEnabled(true))
    #expect(await model.settings.save())
    #expect(model.hostListStatus == .saved)
    await model.engineRequestsHandled()
    #expect(await UITestSupport.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    #expect(model.refreshState?.hosts.map(\.host.id) == [first.id])
    #expect(model.settings.refreshState?.hosts.count == 1)
    #expect(model.settings.hostRows.first?.status == .reachable)
    #expect(discovery.calls(of: first.id) >= 1)
    await model.shutdown()
  } // End of func savedListReachesTheEngine()

  /// Quitting stops Settings' probes too (PLAN.md D22, D23): `AppModel.shutdown()` cancels a
  /// running Test connection and Detect and returns only once both have ended (the real probe
  /// ends only after its process group was killed and reaped); afterwards neither starts again.
  @Test func shutdownStopsSettingsProbes() async {
    let discovery = ScriptedDiscovery()
    let store = FakeHostListStore(Support.loaded([Support.sshHost("Saturno")]))
    let environment = AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: {
        RefreshCoordinator(
          hosts: $0, discovery: FakeDiscovery(), configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: Support.environment(store: store, discovery: discovery))
    let model = AppModel(environment: environment)
    await model.start()
    await model.settings.windowDidOpen()
    discovery.hold(cancellable: true)
    model.settings.testConnection()
    model.settings.detectTmux()
    await discovery.waitForCalls(2)
    await model.shutdown()
    #expect(discovery.cancellations == 2)
    #expect(discovery.finishedCalls == 2)
    model.settings.testConnection()
    model.settings.detectTmux()
    #expect(discovery.calls.count == 2)
    #expect(model.settings.connectionTest == .idle)
    #expect(model.settings.detection == .idle)
    discovery.release()
  } // End of func shutdownStopsSettingsProbes()

  // MARK: - Fixtures and flags

  /// The Settings fixtures cover the host list, a validation error, This Mac, a connection
  /// test, every launch-at-login status with an error, the log, and fix-its; synthetic data
  /// only.
  @Test func settingsFixturesCoverEveryState() {
    let all = SettingsFixtures.all
    #expect(Set(all.map(\.id)).count == all.count)
    let models = all.map { SettingsModel(fixture: $0) }
    let allPreviews = models.allSatisfy { $0.isPreview }
    #expect(allPreviews)
    let validation = SettingsModel(fixture: SettingsFixtures.validation).issues
    #expect(validation?.displayName != nil && validation?.destination != nil)
    #expect(validation?.tmuxPath != nil && validation?.enabled != nil)
    #expect(SettingsModel(fixture: SettingsFixtures.thisMac).thisMacNotice != nil)
    #expect(models.contains { if case .finished = $0.connectionTest { true } else { false } })
    let statuses = Set(all.filter { $0.tab == .general }.compactMap(\.loginItemStatus))
    #expect(statuses == [.enabled, .notRegistered, .requiresApproval, .notFound])
    #expect(all.contains { $0.loginItemError != nil })
    #expect(all.contains { !$0.diagnosticEvents.isEmpty })
    #expect(all.contains { $0.profileChoices.fixIt == .openAutomationSettings })
    #expect(all.contains { $0.hostListStatus == .invalid(.notJSON) })
    #expect(SettingsModel(fixture: SettingsFixtures.invalidFile).isEditable == false)
    let destinations =
      all.flatMap(\.hosts.hosts).map(\.sshDestination)
      + all.compactMap(\.draft?.sshDestination)
    #expect(destinations.allSatisfy { $0.isEmpty || $0.hasSuffix(".example") })
    #expect(all.flatMap(\.suggestions).allSatisfy { $0.hasSuffix(".example") })
    #expect(
      PreviewFixtures.all.contains { fixture in
        fixture.activities.values.contains { $0.problem?.fixIt != nil }
      })
  } // End of func settingsFixturesCoverEveryState()

  /// The new command-line flags.
  @Test func launchOptions() {
    #expect(AppLaunchOptions(arguments: []).previewGallery == .popover)
    let settings = AppLaunchOptions(arguments: [
      "--preview-fixtures", "--preview-gallery", "settings",
    ])
    #expect(settings.previewGallery == .settings)
    #expect(AppLaunchOptions(arguments: ["--preview-gallery=SETTINGS"]).previewGallery == .settings)
    #expect(AppLaunchOptions(arguments: ["--preview-gallery", "x"]).previewGallery == .popover)
    #expect(AppLaunchOptions(arguments: ["--report-login-item-status"]).reportsLoginItemStatus)
    #expect(!AppLaunchOptions(arguments: ["--report-menu-bar-item"]).reportsLoginItemStatus)
  }
}
