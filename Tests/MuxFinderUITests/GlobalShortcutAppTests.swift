import CoreGraphics
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The session switcher shortcut in the app (PLAN.md D32): `AppModel` loads and registers it at
/// start (normal mode only) and unregisters it at quit, its press reaches the one entry point
/// (`globalShortcutPressed()`), which toggles the session switcher through
/// `SwitcherController` (Phase I-3b); Settings shares the model and stops recording when its
/// window closes or
/// loses the focus or another tab is chosen; which modes get a shortcut at all; the flag's
/// options; the gallery's recorder states; the diagnostics line.
@Suite("Global shortcut in the app")
@MainActor
struct GlobalShortcutAppTests {
  /// Shorthand.
  typealias Support = ShortcutTestSupport

  /// An app model over fakes with a shortcut environment over `registrar` and `store`.
  static func appModel(
    registrar: FakeHotkeyRegistrar,
    store: any PreferencesStoring
  ) -> AppModel {
    var environment = UITestSupport.environment(load: {
      UITestSupport.loaded([UITestSupport.localHost()])
    })
    environment.globalShortcut = GlobalShortcutEnvironment(
      store: store, registrar: registrar, layout: Support.spanishLayout)
    return AppModel(environment: environment)
  }

  /// A saved shortcut is registered by `start()`; its press reaches `globalShortcutPressed()`,
  /// which toggles the session switcher through `toggleSwitcher`; `shutdown()` unregisters it
  /// and later presses do nothing.
  @Test func thePressReachesTheEntryPoint() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Self.appModel(registrar: registrar, store: store)
    var toggles = 0
    model.toggleSwitcher = { toggles += 1 }
    #expect(registrar.registered.isEmpty)
    await model.start()
    #expect(registrar.registered == [Support.controlOptionSpace])
    #expect(model.settings.globalShortcut === model.shortcut)
    registrar.press(Support.controlOptionSpace)
    registrar.press(Support.controlOptionSpace)
    #expect(toggles == 2)
    await model.shutdown()
    #expect(registrar.registered.isEmpty)
    model.globalShortcutPressed()
    #expect(toggles == 2)
  } // End of func thePressReachesTheEntryPoint()

  /// Without a shortcut environment (self-tests, previews, the `--report-*` flags) `start()`
  /// reads no preferences and registers nothing; the entry point still does nothing harmful.
  @Test func noEnvironmentRegistersNothing() async {
    let model = AppModel(
      environment: UITestSupport.environment(load: { UITestSupport.loaded([]) }))
    await model.start()
    #expect(model.shortcut.registration == .off)
    #expect(model.shortcut.fileStatus == .notLoaded)
    #expect(model.shortcut.diagnosticsCode == "not used")
    await model.shutdown()
    let fixture = AppModel(fixture: PreviewFixtures.all[0])
    var toggles = 0
    fixture.toggleSwitcher = { toggles += 1 }
    fixture.globalShortcutPressed()
    #expect(toggles == 0)
  } // End of func noEnvironmentRegistersNothing()

  /// Closing the Settings window or its losing the focus stops the recorder and registers the
  /// saved shortcut again, so it is never left suspended.
  @Test func settingsStopsRecordingWhenTheWindowGoes() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionK))
    let model = Self.appModel(registrar: registrar, store: store)
    await model.start()
    model.settings.globalShortcut.startRecording()
    #expect(registrar.registered.isEmpty)
    model.settings.windowDidResignKey()
    #expect(!model.shortcut.isRecording && registrar.registered == [Support.controlOptionK])
    model.settings.globalShortcut.startRecording()
    model.settings.windowDidClose()
    #expect(!model.shortcut.isRecording && registrar.registered == [Support.controlOptionK])
    await model.shutdown()
  } // End of func settingsStopsRecordingWhenTheWindowGoes()

  /// Choosing another Settings tab while the recorder listens on General stops it (its key
  /// monitor goes with `isRecording`) and registers the saved shortcut again; coming back to
  /// General starts nothing by itself.
  @Test func settingsStopsRecordingOnAnotherTab() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionK))
    let model = Self.appModel(registrar: registrar, store: store)
    await model.start()
    for tab in SettingsModel.Tab.allCases where tab != .general {
      model.settings.selectedTab = .general
      model.settings.globalShortcut.startRecording()
      #expect(model.shortcut.isRecording && registrar.registered.isEmpty)
      model.settings.selectedTab = tab
      #expect(!model.shortcut.isRecording, "\(tab)")
      #expect(registrar.registered == [Support.controlOptionK], "\(tab)")
      #expect(model.shortcut.registration == .registered)
    } // End of loop over the tabs other than General
    model.settings.selectedTab = .general
    #expect(!model.shortcut.isRecording && registrar.registered == [Support.controlOptionK])
    #expect(await store.changeCount == 0)
    await model.shutdown()
  } // End of func settingsStopsRecordingOnAnotherTab()

  /// The shortcut's action (Phase I-3b replaced the interim popover toggle): it opens the
  /// session switcher centered on the display with the keyboard focus, in its upper part, and
  /// closes it when open; visibility is reported once per change.
  @Test func theShortcutTogglesTheSwitcher() {
    let harness = SwitcherControllerTests.Harness()
    harness.controller.toggle()
    #expect(harness.controller.isOpen)
    #expect(harness.panel.shownFrames == [SwitcherControllerTests.onSecondDisplay])
    #expect(harness.visibility == [true] && harness.opens == 1)
    harness.controller.toggle()
    #expect(!harness.controller.isOpen)
    #expect(harness.controller.lastCloseReason == .shortcut)
    #expect(harness.visibility == [true, false])
    harness.controller.toggle()
    #expect(harness.controller.isOpen && harness.visibility == [true, false, true])
    harness.controller.toggle()
    #expect(!harness.controller.isOpen && harness.panel.hideCount == 2)
  } // End of func theShortcutTogglesTheSwitcher()

  /// Which modes get the shortcut: only normal mode (`--appearance` alone keeps it); the flag
  /// alone is a mode of its own; combined with another mode it is a usage error.
  @Test func launchOptions() {
    #expect(AppLaunchOptions(arguments: []).registersGlobalShortcut)
    #expect(AppLaunchOptions(arguments: ["--appearance", "dark"]).registersGlobalShortcut)
    for other in [
      ["--report-menu-bar-item"], ["--report-popover-placement"], ["--report-login-item-status"],
      ["--preview-fixtures"], ["--selftest", "attach-local"], ["--remove-persistent-profiles"],
      ["--report-hotkey-registration"], ["--selftest"],
    ] {
      #expect(!AppLaunchOptions(arguments: other).registersGlobalShortcut, "\(other)")
    }
    let flag = AppLaunchOptions(arguments: ["--report-hotkey-registration"])
    #expect(flag.reportsHotkeyRegistration && flag.usageError == nil)
    #expect(!flag.rewritesProfilesAtLaunch)
    for other in [
      ["--preview-fixtures"], ["--report-menu-bar-item"], ["--report-login-item-status"],
      ["--selftest", "attach-local"], ["--remove-persistent-profiles"],
      ["--report-popover-placement"],
    ] {
      let combined = AppLaunchOptions(arguments: ["--report-hotkey-registration"] + other)
      #expect(combined.usageError != nil, "\(other)")
      let reversed = AppLaunchOptions(arguments: other + ["--report-hotkey-registration"])
      #expect(reversed.usageError != nil, "\(other)")
      #expect(!reversed.registersGlobalShortcut)
    }
    #expect(AppLaunchOptions.usage.contains(AppLaunchOptions.hotkeyRegistrationUsage))
  } // End of func launchOptions()

  /// Each mode's environment: the app with the shortcut gets the real `preferences.json`, the
  /// Carbon registrar and the system layout (building it reads and registers nothing); the app
  /// without it, the placement diagnostic and the self-tests get none.
  @Test func eachModeGetsItsOwnShortcut() async {
    let withShortcut = AppEnvironment.production(
      rewritesProfilesAtLaunch: false, usesGlobalShortcut: true)
    let store = withShortcut.globalShortcut?.store as? PreferencesStore
    #expect(store?.fileURL.lastPathComponent == "preferences.json")
    #expect(store?.fileURL == PreferencesStore().fileURL)
    let registrar = withShortcut.globalShortcut?.registrar as? CarbonHotkeyRegistrar
    #expect(registrar?.registeredCount == 0)
    #expect(withShortcut.globalShortcut?.layout is SystemKeyboardLayout)
    #expect(AppEnvironment.production(rewritesProfilesAtLaunch: false).globalShortcut == nil)
    #expect(AppEnvironment.placementDiagnostic().globalShortcut == nil)
    let run = await SelfTestDriverTests.run(SelfTestRequest(kind: .attachLocal))
    #expect(run.driver.makeEnvironment().globalShortcut == nil)
  } // End of func eachModeGetsItsOwnShortcut()

  /// The Settings gallery shows the recorder empty, recording with a refusal, warning, set and
  /// taken, all on the General tab; their models run nothing.
  @Test func galleryCoversTheRecorderStates() async {
    let general = SettingsFixtures.all.filter { $0.tab == .general }
    let states = general.map(\.globalShortcut)
    #expect(states.contains { $0.shortcut == nil && $0.registration == .off })
    #expect(states.contains { $0.recorder == .recording && $0.issue != nil })
    #expect(states.contains { if case .confirming = $0.recorder { true } else { false } })
    #expect(states.contains { $0.registration == .registered && $0.shortcut != nil })
    #expect(states.contains { $0.registration == .failed(.taken) && $0.issue != nil })
    for fixture in general {
      let model = SettingsModel(fixture: fixture).globalShortcut
      #expect(model.isPreview && model.environment == nil)
      await model.start()
      model.startRecording()
      model.clear()
      #expect(model.shortcut == fixture.globalShortcut.shortcut)
      #expect(model.recorder == fixture.globalShortcut.recorder)
    }
    let taken = SettingsModel(fixture: SettingsFixtures.shortcutTaken).globalShortcut
    #expect(taken.label?.text == "⌃⌥K")
    let warning = SettingsModel(fixture: SettingsFixtures.shortcutWarning).globalShortcut
    #expect(warning.warning?.hasPrefix("⌘K would stop working") == true)
  } // End of func galleryCoversTheRecorderStates()

  /// "Copy diagnostics" names the shortcut's state by kind, never the combination.
  @Test func diagnosticsReportTheStateByKind() {
    let text = DiagnosticsReport.text(
      DiagnosticsReport.Input(
        appVersion: "1", systemVersion: "27", generatedAt: UITestSupport.now, hosts: HostList(),
        hostListStatus: .saved, refreshState: nil, loginItem: .enabled, events: [],
        globalShortcut: "failed.taken"))
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    #expect(lines[7] == "Session switcher shortcut: failed.taken")
    let fixture = SettingsModel(fixture: SettingsFixtures.shortcutSet)
    #expect(fixture.globalShortcut.diagnosticsCode == "registered")
  }
}
