import AppKit
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The session switcher shortcut (PLAN.md D32): its label on a fake layout, and
/// `GlobalShortcutModel` over a fake registrar and an in-memory or scripted store: registered at
/// launch with a saved shortcut and not without, again on a change, unregistered on clear and at
/// quit, a taken combination's message, suspended while recording, refusals and warnings, a
/// failed save undone, an unusable file left alone (also when a save finds it, over a real
/// `PreferencesStore` on a private folder), a failed unregistration kept; and
/// `CarbonHotkeyRegistrar` over fake Carbon calls. No real hotkey or window is involved, and no
/// file outside a test's own `mkdtemp` folder.
@Suite("Global shortcut model")
@MainActor
struct GlobalShortcutModelTests {
  /// Shorthand.
  typealias Support = ShortcutTestSupport

  // MARK: - Label

  /// Typing keys show what the layout prints (uppercased), after the modifiers in macOS order
  /// whatever order they were given in; VoiceOver reads names joined by dashes.
  @Test func labelUsesTheLayoutAndMacOSOrder() {
    let layout = Support.spanishLayout
    let ene = GlobalShortcut(keyCode: 0x29, modifiers: [.command, .option, .control, .shift])
    let label = GlobalShortcutLabel(ene, layout: layout)
    #expect(label.text == "⌃⌥⇧⌘Ñ")
    #expect(label.spokenText == "Control-Option-Shift-Command-Ñ")
    #expect(
      GlobalShortcutLabel(GlobalShortcut(keyCode: 0x2A, modifiers: .control), layout: layout).text
        == "⌃Ç")
    #expect(
      GlobalShortcutLabel(GlobalShortcut(keyCode: 0x21, modifiers: .option), layout: layout).text
        == "⌥`")
    #expect(
      GlobalShortcutLabel(GlobalShortcut(keyCode: 0x1E, modifiers: .command), layout: layout).text
        == "⌘+")
    let us = StaticKeyboardLayout(characters: [0x29: ";"])
    #expect(
      GlobalShortcutLabel(GlobalShortcut(keyCode: 0x29, modifiers: .control), layout: us).text
        == "⌃;")
  } // End of func labelUsesTheLayoutAndMacOSOrder()

  /// F-keys, Space, Return, Tab, Delete, Esc and the arrows get fixed names whatever the
  /// layout; a key the layout types nothing (or a blank) for falls back to its key code.
  @Test func labelNamesSpecialKeys() {
    let layout = StaticKeyboardLayout(characters: [0x31: " ", 0x24: "\r", 0x32: "\u{1B}"])
    /// The label of `keyCode` with `modifiers` on the test's layout.
    func text(_ keyCode: UInt16, _ modifiers: GlobalShortcut.Modifiers = .control) -> String {
      GlobalShortcutLabel(GlobalShortcut(keyCode: keyCode, modifiers: modifiers), layout: layout)
        .text
    }
    #expect(text(GlobalShortcut.KeyCode.f19, []) == "F19")
    #expect(text(0x7A, .shift) == "⇧F1")
    #expect(text(0x5A, []) == "F20")
    #expect(text(GlobalShortcut.KeyCode.space, [.control, .option]) == "⌃⌥Space")
    #expect(text(GlobalShortcut.KeyCode.returnKey) == "⌃↩")
    #expect(text(GlobalShortcut.KeyCode.tab) == "⌃⇥")
    #expect(text(GlobalShortcut.KeyCode.delete) == "⌃⌫")
    #expect(text(GlobalShortcut.KeyCode.escape) == "⌃⎋")
    #expect(text(0x7B) == "⌃←" && text(0x7C) == "⌃→" && text(0x7D) == "⌃↓" && text(0x7E) == "⌃↑")
    #expect(text(0x32) == "⌃Key 50")
    #expect(text(0x33 + 0x10) == "⌃Key 67")
    let spoken = GlobalShortcutLabel(
      GlobalShortcut(keyCode: 0x7E, modifiers: [.command, .shift]), layout: layout
    ).spokenText
    #expect(spoken == "Shift-Command-Up arrow")
  } // End of func labelNamesSpecialKeys()

  /// The real layout reads something for K on this Mac's layout, whatever it is (a smoke test of
  /// `TISCopyCurrentKeyboardLayoutInputSource` and `UCKeyTranslate`; nothing is changed).
  @Test func systemLayoutReadsALetter() {
    let character = SystemKeyboardLayout().character(forKeyCode: 0x28)
    #expect(character?.isEmpty == false)
  }

  /// An event's flags become the four modifiers; Caps Lock, Fn and the keypad flag are left out.
  @Test func modifiersFromEventFlags() {
    let flags: NSEvent.ModifierFlags = [.control, .option, .capsLock, .function, .numericPad]
    #expect(GlobalShortcut.Modifiers(eventFlags: flags) == [.control, .option])
    #expect(
      GlobalShortcut.Modifiers(eventFlags: [.shift, .command]) == [.shift, .command])
    #expect(GlobalShortcut.Modifiers(eventFlags: []) == [])
  }

  // MARK: - Lifecycle

  /// A saved shortcut is registered at launch; the press reaches `onPress`.
  @Test func registersASavedShortcutAtLaunch() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar)
    var presses = 0
    model.onPress = { presses += 1 }
    #expect(registrar.calls.isEmpty)
    await model.start()
    #expect(registrar.registered == [Support.controlOptionSpace])
    #expect(model.registration == .registered && model.shortcut == Support.controlOptionSpace)
    #expect(model.fileStatus == .usable && model.issue == nil)
    #expect(model.label?.text == "⌃⌥Space")
    #expect(registrar.press(Support.controlOptionSpace))
    #expect(presses == 1)
    await model.start()
    #expect(registrar.calls.count == 1)
    #expect(await store.changeCount == 0)
  } // End of func registersASavedShortcutAtLaunch()

  /// Without a saved shortcut nothing is registered; nothing is written either.
  @Test func registersNothingWithoutAShortcut() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore()
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    #expect(registrar.calls.isEmpty)
    #expect(model.registration == .off && model.shortcut == nil && model.label == nil)
    #expect(await store.changeCount == 0)
    #expect(model.diagnosticsCode == "off")
  }

  /// Recording another shortcut unregisters the old one (suspended), registers the new one and
  /// saves it.
  @Test func registersAgainOnAChange() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    model.startRecording()
    #expect(model.isRecording && model.registration == .suspended)
    #expect(registrar.registered.isEmpty)
    #expect(model.handleRecorderKey(keyCode: 0x28, modifiers: [.control, .option]))
    await model.savesFinished()
    #expect(!model.isRecording)
    #expect(registrar.registered == [Support.controlOptionK])
    #expect(model.shortcut == Support.controlOptionK && model.registration == .registered)
    #expect(await store.preferences.globalShortcut == Support.controlOptionK)
    #expect(
      registrar.calls == [
        .register(Support.controlOptionSpace), .unregister(Support.controlOptionSpace),
        .register(Support.controlOptionK),
      ])
  } // End of func registersAgainOnAChange()

  /// "Clear" unregisters the hotkey and saves that there is none; Delete while recording does
  /// the same.
  @Test func unregistersOnClear() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    model.clear()
    await model.savesFinished()
    #expect(registrar.registered.isEmpty)
    #expect(model.shortcut == nil && model.registration == .off)
    #expect(await store.preferences.globalShortcut == nil)

    let second = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionK))
    let other = FakeHotkeyRegistrar()
    let recording = Support.model(store: second, registrar: other)
    await recording.start()
    recording.startRecording()
    recording.handleRecorderKey(keyCode: GlobalShortcut.KeyCode.delete, modifiers: [])
    await recording.savesFinished()
    #expect(!recording.isRecording && recording.shortcut == nil)
    #expect(other.registered.isEmpty)
    #expect(await second.preferences.globalShortcut == nil)
  } // End of func unregistersOnClear()

  /// Quitting unregisters the hotkey and stops listening for presses; nothing registers again.
  @Test func unregistersAtQuit() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    await model.shutdown()
    #expect(registrar.registered.isEmpty)
    #expect(registrar.onPress == nil)
    model.startRecording()
    model.cancelRecording()
    #expect(registrar.registered.isEmpty)
    #expect(!model.isEditable)
    await model.shutdown()
    #expect(await store.changeCount == 0)
  } // End of func unregistersAtQuit()

  /// A saved shortcut another app holds shows the message beside the recorder at launch; a
  /// taken one recorded keeps the recorder listening with the message, and Esc brings the
  /// saved one back.
  @Test func aTakenShortcutShowsItsMessage() async {
    let registrar = FakeHotkeyRegistrar()
    registrar.taken = [Support.controlOptionK]
    let saved = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionK))
    let atLaunch = Support.model(store: saved, registrar: registrar)
    await atLaunch.start()
    #expect(atLaunch.registration == .failed(.taken))
    #expect(atLaunch.issue == "Another app uses this shortcut. Choose another.")
    #expect(atLaunch.diagnosticsCode == "failed.taken")

    let other = FakeHotkeyRegistrar()
    other.taken = [Support.controlOptionK]
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: other)
    await model.start()
    model.startRecording()
    model.handleRecorderKey(keyCode: 0x28, modifiers: [.control, .option])
    #expect(model.isRecording)
    #expect(model.issue == HotkeyRegistrationError.taken.message)
    #expect(model.shortcut == Support.controlOptionSpace)
    #expect(other.registered.isEmpty)
    model.handleRecorderKey(keyCode: GlobalShortcut.KeyCode.escape, modifiers: [])
    #expect(!model.isRecording && model.issue == nil)
    #expect(other.registered == [Support.controlOptionSpace])
    #expect(await store.changeCount == 0)
  } // End of func aTakenShortcutShowsItsMessage()

  /// While recording the hotkey is unregistered, so pressing it never reaches `onPress` (it
  /// would reach the recorder instead); cancelling registers it again.
  @Test func suspendedWhileRecording() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar)
    var presses = 0
    model.onPress = { presses += 1 }
    await model.start()
    model.startRecording()
    #expect(!registrar.press(Support.controlOptionSpace))
    #expect(presses == 0)
    model.cancelRecording()
    #expect(registrar.press(Support.controlOptionSpace))
    #expect(presses == 1)
    model.startRecording()
    model.handleRecorderKey(
      keyCode: GlobalShortcut.KeyCode.space, modifiers: [.control, .option])
    await model.savesFinished()
    #expect(registrar.registered == [Support.controlOptionSpace])
    #expect(registrar.press(Support.controlOptionSpace))
    #expect(presses == 2)
  } // End of func suspendedWhileRecording()

  /// A refused combination shows why and keeps listening; nothing is registered or saved.
  @Test func refusalsKeepListening() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore()
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    model.startRecording()
    model.handleRecorderKey(keyCode: 0x28, modifiers: .shift)
    #expect(model.isRecording && model.issue == GlobalShortcutRefusal.needsModifier.message)
    model.handleRecorderKey(keyCode: GlobalShortcut.KeyCode.space, modifiers: .command)
    #expect(model.issue == GlobalShortcutRefusal.systemShortcut.message)
    #expect(registrar.calls.isEmpty)
    model.handleRecorderKey(keyCode: GlobalShortcut.KeyCode.f19, modifiers: [])
    await model.savesFinished()
    #expect(!model.isRecording && model.issue == nil)
    #expect(
      registrar.registered == [GlobalShortcut(keyCode: GlobalShortcut.KeyCode.f19, modifiers: [])])
    #expect(await store.changeCount == 1)
  } // End of func refusalsKeepListening()

  /// ⌘ with one key, and only ⌥ with a key, ask first: nothing is registered until "Use it
  /// anyway" (or Return); "Choose another" keeps listening.
  @Test func warnsBeforeTaking() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore()
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    model.startRecording()
    model.handleRecorderKey(keyCode: 0x28, modifiers: .command)
    #expect(model.recorder == .confirming(Support.commandK))
    #expect(
      model.warning == "⌘K would stop working in every app while muxFinder uses it. Use it anyway?")
    #expect(registrar.calls.isEmpty)
    model.chooseAnother()
    #expect(model.recorder == .recording && model.warning == nil)
    model.handleRecorderKey(keyCode: GlobalShortcut.KeyCode.letterJ, modifiers: .option)
    #expect(model.recorder == .confirming(Support.optionJ))
    #expect(model.warning?.contains("only ⌥ or ⌥⇧") == true)
    #expect(model.warning?.contains("⌥J") == true)
    model.handleRecorderKey(keyCode: GlobalShortcut.KeyCode.returnKey, modifiers: [])
    await model.savesFinished()
    #expect(registrar.registered == [Support.optionJ])
    #expect(model.shortcut == Support.optionJ && !model.isRecording)

    model.startRecording()
    model.handleRecorderKey(keyCode: 0x28, modifiers: .command)
    model.confirmWarning()
    await model.savesFinished()
    #expect(registrar.registered == [Support.commandK])
    #expect(await store.preferences.globalShortcut == Support.commandK)
  } // End of func warnsBeforeTaking()

  /// A save that fails undoes the registration and brings the previous shortcut back, with the
  /// reason beside the recorder; a failed clear keeps the shortcut registered.
  @Test func aFailedSaveBringsThePreviousShortcutBack() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    await store.setFailure(.busy)
    model.startRecording()
    model.handleRecorderKey(keyCode: 0x28, modifiers: [.control, .option])
    #expect(model.isSaving && !model.isEditable)
    model.startRecording()
    #expect(!model.isRecording)
    await model.savesFinished()
    #expect(model.shortcut == Support.controlOptionSpace)
    #expect(registrar.registered == [Support.controlOptionSpace])
    #expect(model.issue?.hasPrefix("muxFinder couldn't save the shortcut.") == true)
    #expect(model.issue?.contains("Another muxFinder") == true)
    model.clear()
    await model.savesFinished()
    #expect(model.shortcut == Support.controlOptionSpace)
    #expect(registrar.registered == [Support.controlOptionSpace])
    #expect(model.issue?.hasPrefix("muxFinder couldn't turn off the shortcut") == true)
  } // End of func aFailedSaveBringsThePreviousShortcutBack()

  /// An unusable preferences file leaves the hotkey off and the recorder disabled, with its
  /// notice and "Try again"; nothing is registered or asked of the store but the load.
  @Test func anUnusableFileLeavesTheHotkeyOff() async {
    let registrar = FakeHotkeyRegistrar()
    let store = ScriptedPreferencesStore(
      .success(PreferencesLoadResult(preferences: Preferences(), state: .invalid(.notJSON))))
    let model = Support.model(store: store, registrar: registrar)
    await model.start()
    #expect(model.fileStatus == .notUsable(.notJSON))
    #expect(!model.isEditable && model.canRetryLoading)
    #expect(model.fileNotice?.hasPrefix("The preferences file isn't valid JSON.") == true)
    #expect(model.diagnosticsCode == "off; preferences file unusable (notJSON)")
    model.startRecording()
    model.clear()
    #expect(!model.isRecording)
    #expect(registrar.calls.isEmpty)
    #expect(await store.changes.isEmpty)

    let folder = ScriptedPreferencesStore(.failure(.directoryIsSymbolicLink))
    let unreadable = Support.model(store: folder, registrar: registrar)
    await unreadable.start()
    #expect(unreadable.diagnosticsCode == "off; settings folder unreadable")
    #expect(unreadable.fileNotice?.contains("symbolic link") == true)
    #expect(!unreadable.isEditable)

    let dropped = ScriptedPreferencesStore(
      .success(
        PreferencesLoadResult(preferences: Preferences(), state: .saved, droppedShortcut: true)))
    let fresh = Support.model(store: dropped, registrar: registrar)
    await fresh.start()
    #expect(fresh.isEditable && fresh.fileNotice?.contains("Record a new one") == true)
    fresh.clear()
    await fresh.savesFinished()
    #expect(await dropped.changes == [nil])
    #expect(fresh.fileNotice == nil)
  } // End of func anUnusableFileLeavesTheHotkeyOff()

  /// A save that finds `preferences.json` unusable (it broke after it loaded) leaves the file
  /// byte for byte as it is and the hotkey off, as a launch with that file would, with the
  /// notice and "Try again"; "Try again" on the still broken file changes nothing, and once the
  /// file is fixed it loads and registers what the file holds. The same for "Clear". A real
  /// `PreferencesStore` on a private folder from `mkdtemp`.
  @Test func anUnusableFileFoundBySavingCanBeRetried() async throws {
    let folder = try Support.privatePreferencesFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    try Support.writePrivateFile(
      Support.preferencesText(Support.controlOptionSpace), to: folder.file)
    let registrar = FakeHotkeyRegistrar()
    let model = Support.model(store: PreferencesStore(fileURL: folder.file), registrar: registrar)
    await model.start()
    #expect(
      model.registration == .registered && registrar.registered == [Support.controlOptionSpace])
    let broken = "{ not json"
    try Support.writePrivateFile(broken, to: folder.file)
    model.startRecording()
    model.handleRecorderKey(keyCode: 0x28, modifiers: [.control, .option])
    await model.savesFinished()
    #expect(model.fileStatus == .notUsable(.notJSON))
    #expect(registrar.registered.isEmpty)
    #expect(model.registration == .off && model.shortcut == nil && !model.isRecording)
    #expect(
      model.issue
        == "muxFinder couldn't save the shortcut: its preferences file can't be used, so the "
        + "shortcut is off.")
    #expect(
      model.fileNotice?.hasSuffix("the shortcut is off until it is fixed or moved away.") == true)
    #expect(!model.isEditable && model.canRetryLoading)
    #expect(try String(contentsOf: folder.file, encoding: .utf8) == broken)
    await model.retryLoading()
    #expect(model.fileStatus == .notUsable(.notJSON) && registrar.registered.isEmpty)
    try Support.writePrivateFile(Support.preferencesText(Support.controlOptionK), to: folder.file)
    await model.retryLoading()
    #expect(model.fileStatus == .usable && model.isEditable && model.fileNotice == nil)
    #expect(model.shortcut == Support.controlOptionK && model.registration == .registered)
    #expect(registrar.registered == [Support.controlOptionK])

    try Support.writePrivateFile(broken, to: folder.file)
    model.clear()
    await model.savesFinished()
    #expect(model.fileStatus == .notUsable(.notJSON) && registrar.registered.isEmpty)
    #expect(model.registration == .off && model.shortcut == nil)
    #expect(model.issue?.hasPrefix("The shortcut is off, but muxFinder couldn't save that") == true)
    #expect(try String(contentsOf: folder.file, encoding: .utf8) == broken)
    try FileManager.default.removeItem(at: folder.file)
    await model.retryLoading()
    #expect(model.fileStatus == .usable && model.isEditable && model.registration == .off)
    #expect(
      try FileManager.default.contentsOfDirectory(
        atPath: folder.file.deletingLastPathComponent().path
      ).isEmpty)
  } // End of func anUnusableFileFoundBySavingCanBeRetried()

  /// An unregistration the registrar refuses keeps the token and the hotkey (it still works):
  /// recording does not start and "Clear" keeps the shortcut, saving nothing, each saying why
  /// beside the recorder and in diagnostics by kind; once the registrar recovers, the next
  /// attempt unregisters it. A failed save whose registration cannot be undone keeps the new
  /// shortcut registered and shown.
  @Test func aFailedUnregistrationKeepsTheHotkey() async {
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar)
    var presses = 0
    model.onPress = { presses += 1 }
    await model.start()
    registrar.unregisterFailure = .failed(-108)
    model.startRecording()
    #expect(!model.isRecording && model.registration == .registered)
    #expect(registrar.registered == [Support.controlOptionSpace])
    #expect(
      model.issue
        == "macOS couldn't turn off the shortcut (error -108), so it still works. Click the "
        + "field to try again.")
    #expect(model.unregistrationFailure == .failed(-108))
    #expect(model.diagnosticsCode == "registered; unregistration failed (failed(-108))")
    #expect(registrar.press(Support.controlOptionSpace) && presses == 1)
    model.clear()
    #expect(model.shortcut == Support.controlOptionSpace && model.registration == .registered)
    #expect(
      model.issue
        == "macOS couldn't turn off the shortcut (error -108), so it still works. Try again.")
    #expect(await store.changeCount == 0)
    registrar.unregisterFailure = nil
    model.clear()
    await model.savesFinished()
    #expect(registrar.registered.isEmpty && model.registration == .off && model.shortcut == nil)
    #expect(model.unregistrationFailure == nil && model.diagnosticsCode == "off")
    #expect(await store.preferences.globalShortcut == nil)

    let diagnostics = DiagnosticsLog()
    let other = FakeHotkeyRegistrar()
    let busy = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let saving = Support.model(store: busy, registrar: other, diagnostics: diagnostics)
    await saving.start()
    await busy.setFailure(.busy)
    saving.startRecording()
    other.unregisterFailure = .failed(-108)
    saving.handleRecorderKey(keyCode: 0x28, modifiers: [.control, .option])
    await saving.savesFinished()
    #expect(saving.shortcut == Support.controlOptionK && saving.registration == .registered)
    #expect(other.registered == [Support.controlOptionK])
    #expect(
      saving.issue?.hasPrefix("muxFinder couldn't save the shortcut. Another muxFinder") == true)
    #expect(saving.issue?.hasSuffix("(error -108), so it still works.") == true)
    await saving.shutdown()
    #expect(other.registered == [Support.controlOptionK])
    #expect(saving.unregistrationFailure == .failed(-108))
    let details = await diagnostics.events().map(\.detail)
    #expect(details.contains("session switcher shortcut not unregistered: failed(-108)"))
    #expect(details.contains("session switcher shortcut not unregistered at quit: failed(-108)"))
  } // End of func aFailedUnregistrationKeepsTheHotkey()

  /// `CarbonHotkeyRegistrar` over fake Carbon calls (nothing reaches Carbon): an
  /// unregistration Carbon refuses keeps the registration, whose token still names it and whose
  /// press still arrives, and a later attempt undoes it; `unregisterAll()` keeps and counts the
  /// ones that fail and removes the handler only once nothing is registered.
  @Test func carbonRegistrarKeepsAFailedUnregistration() throws {
    let carbon = FakeCarbonCalls()
    let registrar = CarbonHotkeyRegistrar(calls: carbon.calls)
    var pressed: [HotkeyToken] = []
    registrar.onPress = { pressed.append($0) }
    let space = try registrar.register(Support.controlOptionSpace)
    let other = try registrar.register(Support.controlOptionK)
    #expect(registrar.registeredCount == 2 && carbon.handlersInstalled == 1)
    carbon.failingUnregistrations = [UInt32(GlobalShortcut.KeyCode.space): -108]
    #expect(throws: HotkeyRegistrationError.failed(-108)) { try registrar.unregister(space) }
    #expect(registrar.registeredCount == 2)
    registrar.pressed(space)
    #expect(pressed == [space])
    #expect(registrar.unregisterAll() == 1)
    #expect(registrar.registeredCount == 1)
    #expect(registrar.isHandlerInstalled && carbon.handlersRemoved == 0)
    #expect(throws: HotkeyRegistrationError.unknownToken) { try registrar.unregister(other) }
    carbon.failingUnregistrations = [:]
    try registrar.unregister(space)
    #expect(registrar.registeredCount == 0 && registrar.isHandlerInstalled)
    registrar.pressed(space)
    #expect(pressed == [space])
    #expect(registrar.unregisterAll() == 0)
    #expect(!registrar.isHandlerInstalled && carbon.handlersRemoved == 1)
    #expect(carbon.unregistered.count == 4)
  } // End of func carbonRegistrarKeepsAFailedUnregistration()

  /// A model without an environment (every mode but normal mode) and a fixture model do
  /// nothing: no load, no registration, no save.
  @Test func inertModelsDoNothing() async {
    let inert = GlobalShortcutModel(environment: nil)
    await inert.start()
    inert.startRecording()
    inert.clear()
    #expect(!inert.isRecording && inert.fileStatus == .notLoaded)
    #expect(inert.diagnosticsCode == "not used")
    let fixture = GlobalShortcutModel(
      fixture: GlobalShortcutFixture(
        shortcut: Support.controlOptionSpace, registration: .registered))
    #expect(fixture.isPreview && fixture.isEditable)
    fixture.startRecording()
    fixture.clear()
    #expect(!fixture.isRecording && fixture.shortcut == Support.controlOptionSpace)
    #expect(!fixture.handleRecorderKey(keyCode: 0x28, modifiers: .control))
    #expect(fixture.label?.text == "⌃⌥Space")
  } // End of func inertModelsDoNothing()

  /// The operation log records kinds only, never the combination.
  @Test func diagnosticsRecordKindsOnly() async {
    let diagnostics = DiagnosticsLog()
    let registrar = FakeHotkeyRegistrar()
    let store = InMemoryPreferencesStore(Preferences(globalShortcut: Support.controlOptionSpace))
    let model = Support.model(store: store, registrar: registrar, diagnostics: diagnostics)
    await model.start()
    model.startRecording()
    model.handleRecorderKey(keyCode: 0x28, modifiers: [.control, .option])
    await model.savesFinished()
    let details = await diagnostics.events().map(\.detail)
    #expect(details.contains("session switcher shortcut at launch: registered"))
    #expect(details.contains("session switcher shortcut recorded"))
    for detail in details {
      #expect(!detail.contains("⌃") && !detail.contains("keyCode") && !detail.contains("Space"))
    }
  } // End of func diagnosticsRecordKindsOnly()
}
