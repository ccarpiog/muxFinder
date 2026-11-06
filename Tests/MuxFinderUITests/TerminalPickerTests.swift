import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// An ssh setup request store in memory: records every request written and withdrawn, never
/// touches a folder.
final class MemorySSHSetupStore: SSHSetupRequestStore {
  /// Lock-protected state.
  private struct State {
    /// Written requests, in order.
    var written: [SSHSetupRequest] = []
    /// Withdrawn ids.
    var discarded: [LaunchToken] = []
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// The written requests.
  var written: [SSHSetupRequest] { state.withLock { $0.written } }
  /// The withdrawn ids.
  var discarded: [LaunchToken] { state.withLock { $0.discarded } }

  /// Records the request.
  func writeRequest(_ request: SSHSetupRequest) throws(LaunchStoreError) {
    state.withLock { $0.written.append(request) }
  }

  /// Records the withdrawal.
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    state.withLock { $0.discarded.append(id) }
    return true
  }

  /// Nothing to sweep.
  func sweep() throws(LaunchStoreError) -> Int { 0 }
} // End of class MemorySSHSetupStore

/// The app with the terminal picker over fakes (PLAN.md D38, Phase I-12d1): Terminal, Ghostty
/// and an `exec` sample loaded; LaunchServices and the Automation permission answered by a fake
/// inspector per app; the setting in memory; iTerm2's seams counted; a plain terminal's "Set up
/// SSH" over the fake window layer and an in-memory request store.
@MainActor
struct PickerHarness {
  /// The helper path the commands and windows use.
  static let helper = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"
  /// Terminal's bundle identifier.
  static let terminalApp = "com.apple.Terminal"
  /// Ghostty's bundle identifier.
  static let ghosttyApp = "com.mitchellh.ghostty"

  /// A loaded definition decoded from `json`, with a placeholder script for AppleScript ones
  /// (nothing ever compiles it).
  static func loaded(_ json: String, file: String, script: String?) -> LoadedTerminalDefinition {
    LoadedTerminalDefinition(
      definition: try! TerminalDefinition.decode(Data(json.utf8)), source: .builtIn,
      fileName: file, script: script.map { TerminalScript(name: $0, source: "-- fixture") })
  }

  /// Terminal, as the built-in defines it.
  static let terminal = loaded(
    #"{"schemaVersion": 1, "id": "terminal", "displayName": "Terminal", "#
      + #""bundleIdentifier": "com.apple.Terminal", "minimumVersion": "2.0", "#
      + #""open": {"kind": "appleScript", "script": "terminal.applescript", "#
      + #""command": "shellText"}, "focus": {"kind": "tty"}}"#,
    file: "terminal.json", script: "terminal.applescript")
  /// Ghostty, as the built-in defines it (1.3 or later).
  static let ghostty = loaded(
    #"{"schemaVersion": 1, "id": "ghostty", "displayName": "Ghostty", "#
      + #""bundleIdentifier": "com.mitchellh.ghostty", "minimumVersion": "1.3", "#
      + #""open": {"kind": "appleScript", "script": "ghostty.applescript", "#
      + #""command": "words"}, "focus": {"kind": "windowID"}}"#,
    file: "ghostty.json", script: "ghostty.applescript")

  /// The model.
  let model: AppModel
  /// iTerm2, counted.
  let iTerm2: CountingITerm2
  /// The terminal setting's store.
  let preferences: InMemoryPreferencesStore
  /// LaunchServices and the permission.
  let inspector: FakeTerminalAppInspector
  /// The plain window layer.
  let windows: FakePlainTerminalWindowLayer
  /// Where plain ssh setups write their requests.
  let sshStore: MemorySSHSetupStore
  /// iTerm2's ssh setup opener.
  let sshSetup: FakeSSHSetupOpener
  /// The URL and pasteboard seams.
  let seams: SeamRecorder
  /// The persistent profile file.
  let files: FakeProfileFiles
  /// This Mac and Saturno.
  let hosts: [HostConfig]

  /// A started model whose stored terminal is `stored`, with iTerm2 installed or not, Ghostty
  /// at `ghosttyVersion`, Terminal 2.15 (not running, permission not asked yet), the sample
  /// `exec` app installed; `problems` from the loader; `backend` replaces the backends.
  static func make(
    stored: String?,
    iTerm2Installed: Bool = true,
    ghosttyVersion: String? = "1.2",
    problems: [TerminalDefinitionFileProblem] = [],
    loadGate: TestGate? = nil,
    backend: (@MainActor @Sendable (ChosenTerminal) -> any TerminalBackend)? = nil
  ) async -> PickerHarness {
    let harness = build(
      stored: stored, iTerm2Installed: iTerm2Installed, ghosttyVersion: ghosttyVersion,
      problems: problems, loadGate: loadGate, backend: backend)
    if loadGate == nil { await harness.model.start() }
    return harness
  } // End of static func make(stored:iTerm2Installed:ghosttyVersion:problems:loadGate:backend:)

  /// `make`'s model, not started.
  static func build(
    stored: String?,
    iTerm2Installed: Bool,
    ghosttyVersion: String?,
    problems: [TerminalDefinitionFileProblem],
    loadGate: TestGate?,
    backend: (@MainActor @Sendable (ChosenTerminal) -> any TerminalBackend)?
  ) -> PickerHarness {
    var saturno = UITestSupport.sshHost("Saturno")
    saturno.persistentProfileEnabled = true
    var neptuno = UITestSupport.localHost()
    neptuno.persistentProfileEnabled = true
    let hosts = [neptuno, saturno]
    let iTerm2 = CountingITerm2()
    let preferences = InMemoryPreferencesStore(Preferences(terminal: stored))
    let inspector = FakeTerminalAppInspector(snapshot: SeamHarness.installedSnapshot)
    let app = URL(fileURLWithPath: "/Applications/Fixture.app")
    inspector.setSnapshot(
      TerminalAppSnapshot(url: iTerm2Installed ? app : nil, version: "3.7.7", running: true),
      for: TerminalChoice.iTerm2BundleIdentifier)
    inspector.setSnapshot(
      TerminalAppSnapshot(url: app, version: "2.15", running: false), for: terminalApp)
    inspector.setStatus(AutomationPermission.notDeterminedStatus, for: terminalApp)
    inspector.setSnapshot(
      TerminalAppSnapshot(
        url: ghosttyVersion == nil ? nil : app, version: ghosttyVersion,
        running: false), for: ghosttyApp)
    inspector.setStatus(AutomationPermission.targetNotRunningStatus, for: ghosttyApp)
    let windows = FakePlainTerminalWindowLayer()
    let sshStore = MemorySSHSetupStore()
    let sshSetup = FakeSSHSetupOpener()
    let seams = SeamRecorder()
    let files = FakeProfileFiles()
    let hostStore = FakeHostListStore(UITestSupport.loaded(hosts))
    let catalog = TerminalDefinitionCatalog(
      definitions: [ghostty, SeamHarness.sample, terminal], problems: problems)
    var settings = SettingsTestSupport.environment(
      store: hostStore, seams: seams, sshSetup: sshSetup, profileFiles: files)
    let helper = try! LaunchHelperPath(validating: Self.helper)
    settings.plainSSHSetup = { loaded in
      PlainSSHSetupLauncher(
        loaded: loaded, windows: windows, store: sshStore, locateHelper: { .success(helper) })
    }
    settings.helperPath = { .success(helper) }
    let setting: any TerminalSettingStoring =
      loadGate.map { LoadGatedTerminalSettingStore(base: preferences, gate: $0) } ?? preferences
    var makeBackend:
      (
        @MainActor @Sendable (ChosenTerminal, @escaping AttachCoordinator.UpdateHandler) throws
          -> any TerminalBackend
      )?
    if let backend { makeBackend = { chosen, _ in backend(chosen) } }
    let environment = AppEnvironment(
      loadHosts: { try await hostStore.load() },
      makeEngine: { hosts in
        RefreshCoordinator(
          hosts: hosts, discovery: FakeDiscovery(),
          configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: settings,
      makeTerminalBackend: makeBackend,
      terminal: TerminalEnvironment(
        preferences: setting, loadDefinitions: { catalog }, inspector: inspector))
    return PickerHarness(
      model: AppModel(environment: environment), iTerm2: iTerm2, preferences: preferences,
      inspector: inspector, windows: windows, sshStore: sshStore, sshSetup: sshSetup,
      seams: seams, files: files, hosts: hosts)
  } // End of static func build(stored:iTerm2Installed:ghosttyVersion:problems:loadGate:backend:)
} // End of struct PickerHarness

/// Settings › General's terminal picker, the strings that follow the choice, "Set up SSH" in a
/// plain terminal, the persistent work commands, Diagnostics and onboarding's steps (PLAN.md
/// D38, Phase I-12d1; requirements 8–11). Hermetic: a fake inspector stands for LaunchServices
/// and the Automation permission, nothing is launched, no Apple event is sent, iTerm2 is never
/// contacted with a plain choice.
@Suite("Terminal picker and the plain UI")
@MainActor
struct TerminalPickerTests {
  /// A reading of every definition of `catalog` through `inspector`, read in place (the
  /// picker's own `TerminalPickerReading.read` reads the permissions off the main actor).
  static func reading(
    _ catalog: TerminalDefinitionCatalog, _ inspector: FakeTerminalAppInspector
  ) -> TerminalPickerReading {
    var facts: [String: TerminalAppFacts] = [:]
    for loaded in catalog.definitions {
      facts[loaded.definition.id] = TerminalAppFacts.read(
        for: loaded.definition, inspector: inspector)
    }
    return TerminalPickerReading(
      iTerm2: inspector.snapshot(bundleIdentifier: TerminalChoice.iTerm2BundleIdentifier),
      facts: facts)
  }

  // MARK: - Rows

  /// The rows come from the installed apps and the loaded definitions: iTerm2 first when
  /// installed, then each definition whose app is installed and meets its minimum, by display
  /// name (Ghostty 1.2 left out), each plain row with its permission label and plain mode's
  /// note; the selected row is the choice.
  @Test func rowsFollowTheInstalledAppsAndDefinitions() async {
    let harness = await PickerHarness.make(stored: nil)
    let picker = harness.model.terminalPicker
    #expect(picker.content.isReading, "nothing read before a window opens")
    #expect(harness.inspector.permissionReads.isEmpty)
    await harness.model.settings.windowDidOpen()
    let content = picker.content
    #expect(!content.isReading)
    #expect(content.rows.map(\.id) == ["iterm2", "sample-exec", "terminal"])
    #expect(content.selectedID == "iterm2")
    #expect(content.rows[0].name == "iTerm2" && content.rows[0].version == "3.7.7")
    #expect(content.rows[0].note == TerminalPickerContent.iTerm2Note)
    #expect(content.rows[0].permission == nil && !content.rows[0].isPlain)
    #expect(content.rows[1].permission == .notNeeded)
    #expect(content.rows[2].permission == .notAskedYet && content.rows[2].version == "2.15")
    #expect(content.rows.dropFirst().allSatisfy { $0.note == TerminalPickerContent.plainNote })
    #expect(
      TerminalPickerContent.plainNote
        == "Plain tmux: windows and panes stay inside one terminal window.")
    #expect(content.rows.allSatisfy { $0.unavailableReason == nil })
    #expect(content.rows[2].offersSystemSettings && !content.rows[1].offersSystemSettings)
    #expect(await harness.iTerm2.calls.isEmpty)
    await harness.model.shutdown()
  } // End of func rowsFollowTheInstalledAppsAndDefinitions()

  /// Ghostty below its minimum is listed when it is the current choice, selected, with its
  /// reason, and never replaced; Ghostty from 1.3 is listed as any other.
  @Test func anOldGhosttyIsListedOnlyAsTheCurrentChoice() async {
    let chosen = await PickerHarness.make(stored: "ghostty")
    #expect(
      chosen.model.terminalChoice
        == .unavailable(
          TerminalChoiceUnavailable(
            terminalID: "ghostty", reason: .versionTooOld(minimum: TerminalVersion("1.3")!))))
    await chosen.model.settings.windowDidOpen()
    let content = chosen.model.terminalPicker.content
    #expect(content.rows.map(\.id) == ["iterm2", "ghostty", "sample-exec", "terminal"])
    #expect(content.selectedID == "ghostty")
    #expect(content.selectedRow?.unavailableReason == "Ghostty 1.2 is older than 1.3.")
    #expect(content.selectedRow?.permission == .checkedWhenRunning)
    await chosen.model.shutdown()

    let recent = await PickerHarness.make(stored: nil, ghosttyVersion: "1.3.1")
    await recent.model.settings.windowDidOpen()
    #expect(
      recent.model.terminalPicker.content.rows.map(\.id)
        == ["iterm2", "ghostty", "sample-exec", "terminal"])
    await recent.model.shutdown()
  } // End of func anOldGhosttyIsListedOnlyAsTheCurrentChoice()

  /// Every permission state has its label, and only "Not allowed" and "Not asked yet" offer
  /// "Allow in System Settings…", which opens Privacy & Security › Automation through the URL
  /// seam (no Apple event).
  @Test func everyPermissionLabel() async {
    let labels: [(TerminalAppFacts.Automation, TerminalPermissionLabel, String)] = [
      (.permission(.granted, status: 0), .allowed, "Allowed"),
      (.permission(.denied, status: -1743), .notAllowed, "Not allowed"),
      (.permission(.notDetermined, status: -1744), .notAskedYet, "Not asked yet"),
      (
        .permission(.targetNotRunning, status: -600), .checkedWhenRunning,
        "Checked when the app is running"
      ),
      (.permission(.other(status: -50), status: -50), .unknown, "Unknown"),
      (.notNeeded, .notNeeded, "Not needed"),
    ]
    for (automation, label, text) in labels {
      #expect(TerminalPermissionLabel(automation) == label)
      #expect(label.text == text)
      #expect(label.offersSystemSettings == (label == .notAllowed || label == .notAskedYet))
    }
    #expect(Set(labels.map(\.1)) == Set(TerminalPermissionLabel.allCases))
    let harness = await PickerHarness.make(stored: "terminal")
    harness.model.terminalPicker.allowInSystemSettings()
    #expect(harness.seams.openedURLs == [FixIt.automationSettingsURL])
    #expect(await harness.iTerm2.calls.isEmpty)
    await harness.model.shutdown()
  } // End of func everyPermissionLabel()

  /// Each unavailable reason of the current choice, with its row: not installed, too old,
  /// unreadable version, no such definition (named by its quoted id), and iTerm2 gone.
  @Test func eachUnavailableReason() {
    let catalog = TerminalDefinitionCatalog(
      definitions: [PickerHarness.ghostty, PickerHarness.terminal], problems: [])
    let inspector = FakeTerminalAppInspector(
      snapshot: TerminalAppSnapshot(url: nil, version: nil, running: false))
    let minimum = TerminalVersion("1.3")!
    let cases: [(TerminalChoiceUnavailable.Reason, String, String)] = [
      (.notInstalled, "ghostty", "Ghostty isn't installed."),
      (.versionTooOld(minimum: minimum), "ghostty", "Ghostty is older than 1.3."),
      (.versionUnknown(minimum: minimum), "ghostty", "Can't read Ghostty's version."),
      (.unknownID, "warp", "No terminal named “warp”."),
      (.notInstalled, "iterm2", "iTerm2 isn't installed."),
    ]
    for (reason, id, text) in cases {
      let content = TerminalPickerContent.make(
        choice: .unavailable(TerminalChoiceUnavailable(terminalID: id, reason: reason)),
        pending: nil, catalog: catalog, reading: Self.reading(catalog, inspector))
      #expect(content.selectedID == id)
      #expect(content.selectedRow?.unavailableReason == text, "\(id) \(reason)")
      #expect(content.rows.filter { $0.unavailableReason != nil }.count == 1)
    }
    let unknown = TerminalPickerContent.make(
      choice: .unavailable(TerminalChoiceUnavailable(terminalID: "warp", reason: .unknownID)),
      pending: nil, catalog: catalog, reading: Self.reading(catalog, inspector))
    #expect(unknown.selectedRow?.name == "“warp”" && unknown.selectedRow?.isPlain == false)
    inspector.setSnapshot(
      TerminalAppSnapshot(
        url: URL(fileURLWithPath: "/Applications/G.app"), version: "1.2.9",
        running: false), for: PickerHarness.ghosttyApp)
    let old = TerminalPickerContent.make(
      choice: .unavailable(
        TerminalChoiceUnavailable(terminalID: "ghostty", reason: .versionTooOld(minimum: minimum))),
      pending: nil, catalog: catalog, reading: Self.reading(catalog, inspector))
    #expect(old.selectedRow?.unavailableReason == "Ghostty 1.2.9 is older than 1.3.")
    #expect(!old.rows.contains { $0.id == "iterm2" }, "no iTerm2 row without iTerm2")
  } // End of func eachUnavailableReason()

  /// The loader's problems are listed by file name and reason only; while the setting is not
  /// read yet the picker shows no row and says so.
  @Test func problemsAndTheReadingState() async {
    let problem = TerminalDefinitionFileProblem(
      folder: .user, fileName: "warp.json", problem: .unknownKey("colors"))
    let gate = TestGate()
    gate.close()
    let harness = await PickerHarness.make(stored: "warp", problems: [problem], loadGate: gate)
    let started = Task { await harness.model.start() }
    await gate.waitForArrivals(1)
    let reading = harness.model.terminalPicker.content
    #expect(reading.isReading && reading.rows.isEmpty && reading.selectedID == nil)
    gate.open()
    await started.value
    await harness.model.settings.windowDidOpen()
    let content = harness.model.terminalPicker.content
    #expect(content.problems.map(\.fileName) == ["warp.json"])
    #expect(
      content.problems.first?.reason == TerminalDefinitionProblem.unknownKey("colors").message)
    #expect(content.selectedRow?.unavailableReason == "No terminal named “warp”.")
    await harness.model.shutdown()
  } // End of func problemsAndTheReadingState()

  // MARK: - Choosing

  /// Choosing saves the setting and applies it; a refused save shows the store's error beside
  /// the picker and keeps the old choice (nothing applied, nothing stored).
  @Test func aRefusedSaveKeepsTheOldChoice() async {
    let harness = await PickerHarness.make(stored: nil)
    let picker = harness.model.terminalPicker
    await harness.model.settings.windowDidOpen()
    await picker.choose("terminal")
    #expect(harness.model.terminalChoice == .plain(PickerHarness.terminal))
    #expect(await harness.preferences.preferences.terminal == "terminal")
    #expect(picker.content.selectedID == "terminal" && picker.content.saveError == nil)
    #expect(harness.model.settings.terminalWording.name == "Terminal")

    let error = PreferencesStoreError.fileNotUsable(.unsafe(.permissionsTooOpen))
    await harness.preferences.setFailure(error)
    await picker.choose("iterm2")
    #expect(picker.content.saveError == error.errorDescription)
    #expect(picker.content.selectedID == "terminal")
    #expect(harness.model.terminalChoice == .plain(PickerHarness.terminal))
    #expect(await harness.preferences.preferences.terminal == "terminal")
    #expect(await harness.iTerm2.calls.isEmpty)
    await harness.model.shutdown()
  } // End of func aRefusedSaveKeepsTheOldChoice()

  /// A change while a session action is pending is selected at once with "Applies when the
  /// current action ends."; the strings keep the applied choice until it ends.
  @Test func aChangeHeldByAPendingActionSaysSo() async {
    let gate = TestGate()
    gate.close()
    let harness = await PickerHarness.make(stored: nil) { chosen in
      ScriptedBackend(terminal: chosen.terminal, gate: gate) { target in
        AttachResult(key: target.key, launchID: LaunchToken(), state: .failed(.timedOut))
      }
    }
    let model = harness.model
    _ = await UITestSupport.waitUntil { model.refreshState?.hosts.count == 2 }
    let key = FakeDiscovery.session(on: harness.hosts[0]).key
    _ = await UITestSupport.waitUntil {
      model.refreshState?.snapshot(of: harness.hosts[0].id)?.sessions.isEmpty == false
    }
    model.open(key)
    await gate.waitForArrivals(1)
    await model.terminalPicker.choose("terminal")
    let pending = model.terminalPicker.content
    #expect(pending.pendingNote == "Applies when the current action ends.")
    #expect(pending.selectedID == "terminal")
    #expect(model.terminalWording == .iTerm2 && model.settings.terminalWording == .iTerm2)
    gate.open()
    #expect(
      await UITestSupport.waitUntil { model.terminalChoice == .plain(PickerHarness.terminal) })
    #expect(model.terminalPicker.content.pendingNote == nil)
    #expect(model.settings.terminalWording.name == "Terminal")
    await model.shutdown()
  } // End of func aChangeHeldByAPendingActionSaysSo()

  /// The apps are read only at a window's opening and on "Check again", never by themselves.
  @Test func readsOnlyAtOpeningAndCheckAgain() async {
    let harness = await PickerHarness.make(stored: "terminal")
    #expect(harness.inspector.permissionReads.isEmpty)
    await harness.model.settings.windowDidOpen()
    let afterOpening = harness.inspector.permissionReads.count
    #expect(afterOpening == 2, "Terminal and Ghostty, the AppleScript definitions")
    try? await Task.sleep(for: .milliseconds(50))
    #expect(harness.inspector.permissionReads.count == afterOpening)
    harness.inspector.setStatus(AutomationPermission.grantedStatus, for: PickerHarness.terminalApp)
    #expect(harness.model.terminalPicker.content.selectedRow?.permission == .notAskedYet)
    harness.model.terminalPicker.refresh()
    await harness.model.terminalPicker.readingFinished()
    #expect(harness.inspector.permissionReads.count == afterOpening * 2)
    #expect(harness.model.terminalPicker.content.selectedRow?.permission == .allowed)
    await harness.model.shutdown()
  } // End of func readsOnlyAtOpeningAndCheckAgain()

  /// "Check again" resolves the stored choice again (the review of Phase I-12d1): Ghostty 1.2
  /// stored (unavailable), upgraded to 1.3.1, is applied with no reason left and nothing saved;
  /// downgraded again it is unavailable again, still selected, never replaced. With iTerm2
  /// chosen nothing changes, even with iTerm2 gone.
  @Test func checkAgainResolvesTheStoredChoiceAgain() async {
    let harness = await PickerHarness.make(stored: "ghostty")
    let model = harness.model
    let picker = model.terminalPicker
    await model.settings.windowDidOpen()
    #expect(picker.content.selectedRow?.unavailableReason == "Ghostty 1.2 is older than 1.3.")
    let saves = await harness.preferences.changeCount
    let app = URL(fileURLWithPath: "/Applications/Fixture.app")
    harness.inspector.setSnapshot(
      TerminalAppSnapshot(url: app, version: "1.3.1", running: false),
      for: PickerHarness.ghosttyApp)
    picker.refresh()
    await picker.readingFinished()
    #expect(model.terminalChoice == .plain(PickerHarness.ghostty))
    #expect(picker.content.selectedID == "ghostty")
    #expect(picker.content.selectedRow?.unavailableReason == nil)
    #expect(model.settings.terminalWording.name == "Ghostty")
    #expect(await harness.preferences.changeCount == saves, "nothing saved again")
    #expect(await harness.preferences.preferences.terminal == "ghostty")

    harness.inspector.setSnapshot(
      TerminalAppSnapshot(url: app, version: "1.2", running: false),
      for: PickerHarness.ghosttyApp)
    picker.refresh()
    await picker.readingFinished()
    #expect(model.terminalChoice.terminalID == "ghostty" && model.terminalChoice.chosen == nil)
    #expect(picker.content.selectedRow?.unavailableReason == "Ghostty 1.2 is older than 1.3.")
    await model.shutdown()

    let iTerm2 = await PickerHarness.make(stored: "iterm2")
    await iTerm2.model.settings.windowDidOpen()
    iTerm2.inspector.setSnapshot(
      TerminalAppSnapshot(url: nil, version: nil, running: false),
      for: TerminalChoice.iTerm2BundleIdentifier)
    iTerm2.model.terminalPicker.refresh()
    await iTerm2.model.terminalPicker.readingFinished()
    #expect(iTerm2.model.terminalChoice == .iTerm2)
    await iTerm2.model.shutdown()
  } // End of func checkAgainResolvesTheStoredChoiceAgain()

  /// A choice resolved again while a session action is pending waits like any change: Ghostty
  /// chosen at 1.2 while an Open is held, then upgraded and checked again, is still waiting
  /// (with its note, the applied choice unchanged) and is applied as Ghostty once the action
  /// ends.
  @Test func aChoiceResolvedAgainWaitsForAPendingAction() async {
    let gate = TestGate()
    gate.close()
    let harness = await PickerHarness.make(stored: nil) { chosen in
      ScriptedBackend(terminal: chosen.terminal, gate: gate) { target in
        AttachResult(key: target.key, launchID: LaunchToken(), state: .failed(.timedOut))
      }
    }
    let model = harness.model
    let picker = model.terminalPicker
    _ = await UITestSupport.waitUntil {
      model.refreshState?.snapshot(of: harness.hosts[0].id)?.sessions.isEmpty == false
    }
    model.open(FakeDiscovery.session(on: harness.hosts[0]).key)
    await gate.waitForArrivals(1)
    await picker.choose("ghostty")
    #expect(model.pendingTerminalChoice?.terminalID == "ghostty")
    #expect(model.pendingTerminalChoice?.chosen == nil, "Ghostty 1.2: unavailable")
    harness.inspector.setSnapshot(
      TerminalAppSnapshot(
        url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: "1.3.1",
        running: false), for: PickerHarness.ghosttyApp)
    picker.refresh()
    await picker.readingFinished()
    #expect(model.pendingTerminalChoice == .plain(PickerHarness.ghostty))
    #expect(model.terminalChoice == .iTerm2)
    #expect(picker.content.pendingNote == TerminalPickerContent.pendingText)
    gate.open()
    #expect(
      await UITestSupport.waitUntil { model.terminalChoice == .plain(PickerHarness.ghostty) })
    #expect(picker.content.pendingNote == nil)
    await model.shutdown()
  } // End of func aChoiceResolvedAgainWaitsForAPendingAction()

  /// A slow permission read never holds the main actor (the review of Phase I-12d1): with the
  /// read held, "Check again" returns at once and the picker still says it is reading while
  /// this test, on the main actor, looks at it; every permission read ran off the main thread;
  /// released, the reading shows.
  @Test func aSlowPermissionReadLeavesTheMainActorFree() async {
    let held = HeldPermissionInspector()
    let picker = TerminalPickerModel(inspector: held, openURL: nil)
    let catalog = TerminalDefinitionCatalog(
      definitions: [PickerHarness.terminal, SeamHarness.sample], problems: [])
    picker.update(choice: .plain(PickerHarness.terminal), pending: nil, catalog: catalog)
    held.setHeld(true)
    picker.refresh()
    #expect(await UITestSupport.waitUntil { held.arrivals == 1 }, "the read is under way")
    #expect(picker.content.isReading && picker.content.rows.isEmpty)
    held.releaseWaiting()
    await picker.readingFinished()
    #expect(!picker.content.isReading)
    #expect(picker.content.selectedRow?.permission == .notAskedYet)
    #expect(held.arrivals == 1, "only Terminal's permission: the exec sample needs none")
    #expect(held.mainThreadReads == 0 && held.timeouts == 0)
  } // End of func aSlowPermissionReadLeavesTheMainActorFree()

  /// A reading that ends after a newer "Check again", or after the last picker window closed,
  /// is dropped: the newer reading stays shown.
  @Test func aStaleReadingIsDropped() async {
    let held = HeldPermissionInspector()
    let picker = TerminalPickerModel(inspector: held, openURL: nil)
    let catalog = TerminalDefinitionCatalog(definitions: [PickerHarness.terminal], problems: [])
    picker.update(choice: .plain(PickerHarness.terminal), pending: nil, catalog: catalog)
    held.setHeld(true)
    picker.windowOpened(.settings)
    #expect(await UITestSupport.waitUntil { held.arrivals == 1 })
    held.setHeld(false)
    held.base.setStatus(AutomationPermission.grantedStatus, for: PickerHarness.terminalApp)
    picker.refresh()
    await picker.readingFinished()
    #expect(picker.content.selectedRow?.permission == .allowed)
    held.releaseWaiting()
    await picker.readingsEnded()
    #expect(picker.content.selectedRow?.permission == .allowed, "the older reading dropped")

    held.setHeld(true)
    picker.refresh()
    #expect(await UITestSupport.waitUntil { held.arrivals == 3 })
    held.base.setStatus(AutomationPermission.deniedStatus, for: PickerHarness.terminalApp)
    picker.windowClosed(.settings)
    await picker.readingFinished()
    held.releaseWaiting()
    await picker.readingsEnded()
    #expect(picker.content.selectedRow?.permission == .allowed, "dropped once the window closed")
    #expect(held.mainThreadReads == 0 && held.timeouts == 0)
  } // End of func aStaleReadingIsDropped()

  // MARK: - Strings

  /// The strings follow the choice; with iTerm2 they are exactly the earlier ones.
  @Test func stringsFollowTheChoice() async {
    let iTerm2 = TerminalWording.iTerm2
    #expect(iTerm2.setUpSSHTitle == "Set up SSH in iTerm2…")
    #expect(iTerm2.setUpSSHFirstTitle == "Set up SSH in iTerm2 first")
    #expect(iTerm2.sshSetupOpening == "Opening a new iTerm2 window…")
    #expect(SSHSetupState.opened.message == SSHSetupState.opened.message(in: iTerm2))
    #expect(
      SSHSetupState.opened.message
        == "iTerm2 opened a new window running ssh to this host. Sign in or answer the host key "
        + "question there, then check the host again.")
    #expect(
      SSHSetupState.failed(.cancelled).message
        == "muxFinder couldn't open ssh in iTerm2. Opening the tab was cancelled.")
    #expect(iTerm2.introduction == OnboardingText.introduction)
    #expect(iTerm2.place == "tab")

    let harness = await PickerHarness.make(stored: "terminal")
    let wording = harness.model.settings.terminalWording
    #expect(wording == TerminalWording(name: "Terminal", kind: .terminalApp))
    #expect(wording.setUpSSHTitle == "Set up SSH in Terminal…")
    #expect(wording.setUpSSHFirstTitle == "Set up SSH in Terminal first")
    #expect(wording.place == "window")
    #expect(harness.model.terminalWording == wording)
    #expect(harness.model.onboarding.terminalWording == wording)
    #expect(ProfileChoices.notUsedWithThisTerminal.note == "Used only with iTerm2.")
    await harness.model.settings.windowDidOpen()
    #expect(harness.model.settings.profileChoices == .notUsedWithThisTerminal)
    #expect(
      TerminalWording(name: "Ghostty", kind: .ghostty).setUpSSHTitle == "Set up SSH in Ghostty…")
    let unknown = TerminalWording(
      .unavailable(TerminalChoiceUnavailable(terminalID: "warp", reason: .unknownID)),
      catalog: nil)
    #expect(unknown.name == TerminalWording.unknownTerminalName && !unknown.isITerm2)
    #expect(TerminalWording(.unresolved, catalog: nil) == .iTerm2)
    await harness.model.shutdown()
  } // End of func stringsFollowTheChoice()

  // MARK: - Set up SSH in a plain terminal

  /// With a plain terminal chosen, every owner's "Set up SSH" writes D24's request and opens
  /// one window of that terminal through the window layer; nothing is sent to iTerm2 and
  /// iTerm2's opener is never asked. The line names the terminal.
  @Test func setUpSSHOpensAWindowOfThePlainTerminal() async {
    let harness = await PickerHarness.make(stored: "terminal")
    let saturno = harness.hosts[1]
    let owners = [
      harness.model.settings.sshSetup, harness.model.sshSetup, harness.model.onboarding.sshSetup,
    ]
    for (index, actions) in owners.enumerated() {
      actions.open(saturno)
      #expect(actions.states[saturno.id] == .opening)
      await actions.requestsFinished()
      #expect(actions.states[saturno.id] == .opened)
      #expect(harness.windows.sshSetupOpens.count == index + 1, "one window per request")
      #expect(
        actions.message(for: saturno.id)
          == "Terminal opened a new window running ssh to this host. Sign in or answer the host "
          + "key question there, then check the host again.")
    } // End of loop over the three owners
    #expect(harness.sshStore.written.count == 3)
    #expect(harness.sshStore.written.allSatisfy { $0.destination == "saturno.example" })
    #expect(
      harness.windows.sshSetupOpens.map(\.token) == harness.sshStore.written.map(\.id))
    #expect(harness.windows.sshSetupOpens.allSatisfy { $0.definitionID == "terminal" })
    #expect(harness.windows.opens.isEmpty)
    #expect(harness.sshStore.discarded.isEmpty)
    #expect(harness.sshSetup.calls.isEmpty)
    #expect(await harness.iTerm2.calls.isEmpty)

    harness.windows.openFailure = .permissionDenied(appName: "Terminal")
    let settings = harness.model.settings.sshSetup
    settings.clear(saturno.id)
    settings.open(saturno)
    await settings.requestsFinished()
    let failed = SSHSetupState.failed(.terminalWindow(.permissionDenied(appName: "Terminal")))
    #expect(settings.states[saturno.id] == failed)
    #expect(failed.fixIt == .openAutomationSettings)
    #expect(
      settings.message(for: saturno.id)?.hasPrefix("muxFinder couldn't open ssh in Terminal.")
        == true)
    #expect(harness.sshStore.discarded == [harness.sshStore.written[3].id], "withdrawn")
    await harness.model.shutdown()
  } // End of func setUpSSHOpensAWindowOfThePlainTerminal()

  /// While the setting is still being read the line keeps today's refusal, reworded; an
  /// unavailable choice refuses with its own line; nothing is asked of any opener.
  @Test func theUnresolvedRefusalWording() async {
    #expect(
      SSHSetupState.failed(.notUsedWithThisTerminal).message
        == "Still reading the terminal setting. Try again in a moment.")
    let gate = TestGate()
    gate.close()
    let harness = await PickerHarness.make(stored: "terminal", loadGate: gate)
    let started = Task { await harness.model.start() }
    await gate.waitForArrivals(1)
    let saturno = harness.hosts[1]
    let actions = harness.model.settings.sshSetup
    actions.open(saturno)
    #expect(actions.states[saturno.id] == .failed(.notUsedWithThisTerminal))
    #expect(
      actions.message(for: saturno.id)
        == "Still reading the terminal setting. Try again in a moment.")
    gate.open()
    await started.value
    #expect(actions.states[saturno.id] == nil, "cleared once the choice is known")
    #expect(harness.windows.sshSetupOpens.isEmpty && harness.sshSetup.calls.isEmpty)
    await harness.model.shutdown()

    let gone = await PickerHarness.make(stored: "ghostty")
    let unavailable = gone.model.sshSetup
    unavailable.open(saturno)
    guard case .failed(.terminalUnavailable) = unavailable.states[saturno.id] else {
      Issue.record("not refused: \(String(describing: unavailable.states[saturno.id]))")
      return
    }
    #expect(
      unavailable.message(for: saturno.id)?.hasPrefix("muxFinder couldn't open ssh in Ghostty.")
        == true)
    #expect(gone.windows.sshSetupOpens.isEmpty && gone.sshSetup.calls.isEmpty)
    await gone.model.shutdown()
  } // End of func theUnresolvedRefusalWording()

  // MARK: - Persistent work

  /// The plain persistent work command: D3's extension, each word POSIX single-quoted, the
  /// host id in canonical lowercase; a helper path a shell could misread is refused.
  @Test func persistentWorkCommandQuoting() throws {
    let id = UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!
    #expect(
      try PersistentWorkContent.command(helperPath: PickerHarness.helper, hostID: id)
        == "exec '/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch' 'profile-plain' "
        + "'6f9619ff-8b86-d011-b42d-00c04fc964ff'")
    #expect(throws: TerminalCommandTextError.helperPathUnsafe) {
      try PersistentWorkContent.command(helperPath: "/Users/o'neil/muxfinder-launch", hostID: id)
    }
  } // End of func persistentWorkCommandQuoting()

  /// One line per saved host whose persistent profile is on, in host-list order; none while
  /// the list is not saved; a missing helper says why; where to paste per terminal; iTerm2's
  /// part in one line with Remove only while muxFinder's file is installed.
  @Test func persistentWorkLinesPerHost() throws {
    var saturno = UITestSupport.sshHost("Saturno")
    saturno.persistentProfileEnabled = true
    let sirio = UITestSupport.sshHost("Sirio")
    var vega = UITestSupport.sshHost("Vega")
    vega.persistentProfileEnabled = true
    let hosts = try HostList([saturno, sirio, vega])
    let helper = try LaunchHelperPath(validating: PickerHarness.helper)
    let terminal = TerminalWording(name: "Terminal", kind: .terminalApp)
    let content = PersistentWorkContent(
      wording: terminal, hosts: hosts, isListSaved: true, helper: .success(helper),
      profileStatus: .current, isRunning: false, result: nil)
    #expect(content.lines.map(\.hostName) == ["Saturno", "Vega"])
    #expect(
      content.lines.first?.command
        == "exec '\(PickerHarness.helper)' 'profile-plain' '\(LaunchToken(uuid: saturno.id).rawValue)'"
    )
    #expect(content.title == "Persistent work in Terminal")
    #expect(content.whereToPaste.contains("Settings › Profiles › Shell › Run command"))
    #expect(content.emptyNote == nil && content.problem == nil)
    #expect(content.canRemoveITerm2Profiles)
    #expect(content.iTerm2Line.hasPrefix("Used only with iTerm2."))

    let ghostty = PersistentWorkContent(
      wording: TerminalWording(name: "Ghostty", kind: .ghostty), hosts: hosts, isListSaved: true,
      helper: .success(helper), profileStatus: .notInstalled, isRunning: false, result: nil)
    #expect(ghostty.whereToPaste.contains("“command = ”"))
    #expect(ghostty.whereToPaste.contains("Ghostty's config file"))
    #expect(!ghostty.canRemoveITerm2Profiles && ghostty.iTerm2Line == "Used only with iTerm2.")
    let other = PersistentWorkContent(
      wording: TerminalWording(name: "WezTerm", kind: .other), hosts: hosts, isListSaved: false,
      helper: .success(helper), profileStatus: nil, isRunning: false, result: nil)
    #expect(other.lines.isEmpty && other.emptyNote == PersistentWorkContent.listNotSavedNote)
    #expect(other.whereToPaste.contains("WezTerm's own setting"))
    let missing = PersistentWorkContent(
      wording: terminal, hosts: hosts, isListSaved: true, helper: .failure(.notFound),
      profileStatus: .notInstalled, isRunning: false, result: nil)
    #expect(missing.lines.isEmpty && missing.problem == LaunchHelperPathError.notFound.message)
    let none = PersistentWorkContent(
      wording: terminal, hosts: try HostList([sirio]), isListSaved: true,
      helper: .success(helper), profileStatus: .notInstalled, isRunning: false, result: nil)
    #expect(none.lines.isEmpty && none.emptyNote == PersistentWorkContent.noHostNote)
  } // End of func persistentWorkLinesPerHost()

  /// In the app with Terminal chosen: the tab shows the commands, Copy puts one on the
  /// pasteboard and nothing else is written; Install is refused, Remove stays the user's.
  @Test func persistentWorkInTheApp() async throws {
    let harness = await PickerHarness.make(stored: "terminal")
    let settings = harness.model.settings
    await settings.windowDidOpen()
    let work = try #require(settings.persistentWorkContent)
    #expect(work.lines.map(\.hostName) == ["Neptuno", "Saturno"])
    settings.copyPersistentWorkCommand(for: harness.hosts[1].id)
    #expect(harness.seams.copied == [work.lines[1].command])
    #expect(settings.persistentWorkNotice == "Copied the command for Saturno.")
    #expect(!settings.persistentProfilesContent.canInstall)
    await settings.installProfiles()
    #expect(harness.files.installCalls.isEmpty && harness.files.writeCalls == 0)
    await harness.model.shutdown()

    let iTerm2 = await PickerHarness.make(stored: "iterm2")
    await iTerm2.model.settings.windowDidOpen()
    #expect(iTerm2.model.settings.persistentWorkContent == nil)
    await iTerm2.model.shutdown()
  } // End of func persistentWorkInTheApp()

  // MARK: - Diagnostics

  /// With Terminal chosen, Diagnostics names it with its version and permission and iTerm2's
  /// check reads "not used with Terminal"; with iTerm2 the report is as before.
  @Test func diagnosticsNameTheChosenTerminal() async throws {
    let harness = await PickerHarness.make(stored: "terminal")
    let settings = harness.model.settings
    await settings.windowDidOpen()
    let rows = try #require(settings.terminalDiagnostics)
    #expect(rows.terminal == "Terminal 2.15; permission: Not asked yet")
    #expect(rows.iTerm2 == "Not used with Terminal")
    let lines = await settings.diagnosticsReport().split(
      separator: "\n", omittingEmptySubsequences: false
    ).map(String.init)
    #expect(lines[6] == "iTerm2 check: not used with Terminal")
    #expect(lines[8] == "Terminal: Terminal 2.15; permission: Not asked yet")
    await harness.model.shutdown()

    let iTerm2 = await PickerHarness.make(stored: "iterm2")
    await iTerm2.model.settings.windowDidOpen()
    #expect(iTerm2.model.settings.terminalDiagnostics == nil)
    let report = await iTerm2.model.settings.diagnosticsReport()
    #expect(!report.contains("Terminal: ") && report.contains("iTerm2 check: not run"))
    await iTerm2.model.shutdown()
  } // End of func diagnosticsNameTheChosenTerminal()

  // MARK: - Onboarding

  /// Onboarding's steps per choice: the Terminal step first; iTerm2's Python API step only with
  /// iTerm2 chosen; otherwise the plain-mode step with the permission line (none for an `exec`
  /// terminal). With no iTerm2 installed the default is Terminal and the picker has no iTerm2
  /// row.
  @Test func onboardingStepsPerChoice() async {
    let noITerm2 = await PickerHarness.make(stored: nil, iTerm2Installed: false)
    let onboarding = noITerm2.model.onboarding
    onboarding.windowDidOpen()
    await onboarding.terminalPicker.readingFinished()
    #expect(noITerm2.model.terminalChoice == .plain(PickerHarness.terminal))
    #expect(onboarding.steps == [.terminal, .hosts, .goodToKnow, .plainMode])
    #expect(onboarding.terminalPicker.content.selectedID == "terminal")
    #expect(!onboarding.terminalPicker.content.rows.contains { $0.id == "iterm2" })
    #expect(
      onboarding.plainModeLines == [
        OnboardingText.plainMode("Terminal"),
        TerminalWording(name: "Terminal", kind: .terminalApp).permissionLine,
      ])
    #expect(
      onboarding.plainModeLines[1].hasPrefix(
        "macOS asks once, the first time muxFinder opens a Terminal window."))
    #expect(onboarding.terminalWording.introduction.hasSuffix("opens them in Terminal."))
    #expect(await noITerm2.iTerm2.calls.isEmpty)
    await noITerm2.model.shutdown()

    let iTerm2 = await PickerHarness.make(stored: nil)
    #expect(iTerm2.model.onboarding.steps == [.terminal, .hosts, .goodToKnow, .iTerm2API])
    #expect(iTerm2.model.onboarding.plainModeLines.isEmpty)
    #expect(iTerm2.model.onboarding.terminalWording.introduction == OnboardingText.introduction)
    await iTerm2.model.shutdown()

    let exec = await PickerHarness.make(stored: "sample-exec")
    exec.model.onboarding.windowDidOpen()
    await exec.model.terminalPicker.readingFinished()
    #expect(exec.model.onboarding.steps.last == .plainMode)
    #expect(exec.model.onboarding.plainModeLines == [OnboardingText.plainMode("Sample terminal")])
    await exec.model.shutdown()

    let fixture = OnboardingModel(fixture: OnboardingFixtures.noITerm2)
    #expect(fixture.steps.last == .plainMode)
    #expect(!fixture.terminalPicker.content.rows.contains { $0.id == "iterm2" })
    #expect(OnboardingModel(fixture: OnboardingFixtures.examplesShown).steps.last == .iTerm2API)
  } // End of func onboardingStepsPerChoice()
} // End of struct TerminalPickerTests

/// An inspector whose permission reads can be held (the review of Phase I-12d1): snapshots and
/// answers come from `base` (Terminal installed, its permission not asked yet); each permission
/// read is counted, with whether it ran on the main thread, and while held waits (at most 1 s,
/// then counted as timed out) until `releaseWaiting()`. Its answer is read before the wait.
final class HeldPermissionInspector: TerminalAppInspecting {
  /// Lock-protected state.
  private struct State {
    /// Whether new permission reads wait.
    var held = false
    /// Reads waiting now.
    var waiting = 0
    /// Every permission read so far.
    var arrivals = 0
    /// Permission reads that ran on the main thread.
    var mainThreadReads = 0
    /// Held reads that were never released within 1 s.
    var timeouts = 0
  }

  /// The answers.
  let base: FakeTerminalAppInspector
  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())
  /// What held reads wait on.
  private let gate = DispatchSemaphore(value: 0)

  /// An inspector over Terminal 2.15 (permission not asked yet) and the sample `exec` app.
  init() {
    base = FakeTerminalAppInspector(
      snapshot: TerminalAppSnapshot(
        url: URL(fileURLWithPath: "/Applications/Fixture.app"), version: "2.15",
        running: false))
    base.setStatus(AutomationPermission.notDeterminedStatus, for: "com.apple.Terminal")
  }

  /// Every permission read so far.
  var arrivals: Int { state.withLock { $0.arrivals } }
  /// Permission reads that ran on the main thread.
  var mainThreadReads: Int { state.withLock { $0.mainThreadReads } }
  /// Held reads never released within 1 s.
  var timeouts: Int { state.withLock { $0.timeouts } }

  /// Whether new permission reads wait.
  func setHeld(_ held: Bool) {
    state.withLock { $0.held = held }
  }

  /// Lets every read waiting now go on.
  func releaseWaiting() {
    let waiting = state.withLock { $0.waiting }
    for _ in 0..<waiting { gate.signal() }
  }

  /// `base`'s snapshot.
  @MainActor
  func snapshot(bundleIdentifier: String) -> TerminalAppSnapshot {
    base.snapshot(bundleIdentifier: bundleIdentifier)
  }

  /// `base`'s answer, read first; then, while held, waits for `releaseWaiting()` (at most 1 s).
  func automationStatus(bundleIdentifier: String) -> Int32 {
    let answer = base.automationStatus(bundleIdentifier: bundleIdentifier)
    let onMain = Thread.isMainThread
    let held = state.withLock { state in
      state.arrivals += 1
      if onMain { state.mainThreadReads += 1 }
      if state.held { state.waiting += 1 }
      return state.held
    }
    guard held else { return answer }
    let timedOut = gate.wait(timeout: .now() + 1) == .timedOut
    state.withLock { state in
      state.waiting -= 1
      if timedOut { state.timeouts += 1 }
    }
    return answer
  } // End of func automationStatus(bundleIdentifier:)
} // End of class HeldPermissionInspector
