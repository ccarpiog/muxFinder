import Carbon.HIToolbox
import Foundation

@testable import MuxFinderCore
@testable import MuxFinderUI

/// Fakes for the session switcher shortcut's tests (PLAN.md D32): a registrar that records
/// registrations, fires presses and fails unregistrations when told, Carbon calls for
/// `CarbonHotkeyRegistrar` that never reach Carbon, a Spanish-like keyboard layout, a
/// preferences store that answers as told, and a private folder for a real `PreferencesStore`.
/// Nothing here registers a real hotkey or touches a file outside that folder.
enum ShortcutTestSupport {
  /// ⌃⌥Space.
  static let controlOptionSpace = GlobalShortcut(
    keyCode: GlobalShortcut.KeyCode.space, modifiers: [.control, .option])
  /// ⌃⌥K.
  static let controlOptionK = GlobalShortcut(keyCode: 0x28, modifiers: [.control, .option])
  /// ⌘K.
  static let commandK = GlobalShortcut(keyCode: 0x28, modifiers: .command)
  /// ⌥J.
  static let optionJ = GlobalShortcut(keyCode: GlobalShortcut.KeyCode.letterJ, modifiers: .option)

  /// Part of the Spanish (ISO) layout: Ñ where US has ";", Ç where US has "\", the grave
  /// accent dead key where US has "[", "+" where US has "]", and K.
  static let spanishLayout = StaticKeyboardLayout(characters: [
    0x29: "ñ", 0x2A: "ç", 0x21: "`", 0x1E: "+", 0x28: "k", 0x26: "j",
  ])

  /// A model over the fakes, with `store`'s preferences.
  @MainActor
  static func model(
    store: any PreferencesStoring = InMemoryPreferencesStore(),
    registrar: FakeHotkeyRegistrar = FakeHotkeyRegistrar(),
    diagnostics: DiagnosticsLog? = nil
  ) -> GlobalShortcutModel {
    GlobalShortcutModel(
      environment: GlobalShortcutEnvironment(
        store: store, registrar: registrar, layout: spanishLayout),
      diagnostics: diagnostics)
  }

  /// A private folder from `mktemp -d` for a real `PreferencesStore` (the caller removes
  /// `base`): the store's file is `<base>/muxFinder/preferences.json`, its folder created 0700.
  static func privatePreferencesFolder() throws -> (base: URL, file: URL) {
    let base = try makeTemporaryDirectory()
    let directory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    return (base, directory.appending(path: PreferencesStore.fileName))
  }

  /// A fresh private directory under the per-user temporary folder (`mkdtemp`, 0700).
  static func makeTemporaryDirectory() throws -> URL {
    let template = FileManager.default.temporaryDirectory.appending(path: "mfx-shortcut-XXXXXX")
    var bytes = Array(template.path.utf8CString)
    guard let path = mkdtemp(&bytes) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
  }

  /// Writes `text` as a private file (0600) at `file`, replacing what is there.
  static func writePrivateFile(_ text: String, to file: URL) throws {
    guard FileManager.default.createFile(atPath: file.path, contents: Data(text.utf8)),
      chmod(file.path, 0o600) == 0
    else { throw POSIXError(.EIO) }
  }

  /// `shortcut` as `preferences.json` holds it (schema 1).
  static func preferencesText(_ shortcut: GlobalShortcut) -> String {
    let modifiers = shortcut.modifiers.names.map { "\"\($0)\"" }.joined(separator: ", ")
    return "{\"globalShortcut\": {\"keyCode\": \(shortcut.keyCode), \"modifiers\": "
      + "[\(modifiers)]}, \"schemaVersion\": 1}\n"
  }
}

/// A hotkey registrar that keeps registrations in memory, refuses the combinations it is told
/// are taken, records every call, and fires a registered combination's press on request.
@MainActor
final class FakeHotkeyRegistrar: HotkeyRegistering {
  /// One call.
  enum Call: Equatable {
    /// `register` of this shortcut.
    case register(GlobalShortcut)
    /// `unregister` of this shortcut.
    case unregister(GlobalShortcut)
  }

  /// Called with a pressed hotkey's token.
  var onPress: (@MainActor (HotkeyToken) -> Void)?
  /// What is registered now, by token.
  private(set) var registrations: [HotkeyToken: GlobalShortcut] = [:]
  /// Every call, in order.
  private(set) var calls: [Call] = []
  /// Combinations another app holds: registering them fails with `taken`.
  var taken: Set<GlobalShortcut> = []
  /// When set, every unregistration fails with this error and keeps the registration, as
  /// `CarbonHotkeyRegistrar` does when Carbon refuses.
  var unregisterFailure: HotkeyRegistrationError?
  /// The last token number.
  private var lastID: UInt32 = 0

  /// A registrar with nothing registered.
  init() {}

  /// What is registered now.
  var registered: Set<GlobalShortcut> { Set(registrations.values) }

  /// Registers `shortcut` unless it is taken or registered already.
  func register(_ shortcut: GlobalShortcut) throws(HotkeyRegistrationError) -> HotkeyToken {
    calls.append(.register(shortcut))
    if taken.contains(shortcut) || registered.contains(shortcut) { throw .taken }
    lastID += 1
    let token = HotkeyToken(id: lastID)
    registrations[token] = shortcut
    return token
  }

  /// Unregisters `token`, unless `unregisterFailure` is set: then the registration stays.
  func unregister(_ token: HotkeyToken) throws(HotkeyRegistrationError) {
    guard let shortcut = registrations[token] else { throw .unknownToken }
    if let unregisterFailure { throw unregisterFailure }
    registrations[token] = nil
    calls.append(.unregister(shortcut))
  }

  /// Presses `shortcut`, as Carbon would deliver it: only a registered one reaches `onPress`.
  /// Returns whether it was registered.
  @discardableResult
  func press(_ shortcut: GlobalShortcut) -> Bool {
    guard let token = registrations.first(where: { $0.value == shortcut })?.key else {
      return false
    }
    onPress?(token)
    return true
  }
}

/// Carbon calls for `CarbonHotkeyRegistrar` that never reach Carbon: a registration gets a
/// made-up reference (never dereferenced), an unregistration answers the status it is told for
/// that key code (`noErr` otherwise), and the handler is only counted.
@MainActor
final class FakeCarbonCalls {
  /// The key code each made-up reference was registered for.
  private(set) var keyCodes: [OpaquePointer: UInt32] = [:]
  /// Key codes whose unregistration fails, with the status it answers.
  var failingUnregistrations: [UInt32: OSStatus] = [:]
  /// The key code of every unregistration asked for, in order.
  private(set) var unregistered: [UInt32] = []
  /// How many times the handler was installed.
  private(set) var handlersInstalled = 0
  /// How many times the handler was removed.
  private(set) var handlersRemoved = 0
  /// The last made-up reference number.
  private var lastReference = 0x1000

  /// A fake with nothing registered.
  init() {}

  /// The calls, for `CarbonHotkeyRegistrar(calls:)`.
  var calls: CarbonHotkeyCalls {
    CarbonHotkeyCalls(
      register: { keyCode, _, _ in
        self.lastReference += 0x10
        let reference = OpaquePointer(bitPattern: self.lastReference)
        if let reference { self.keyCodes[reference] = keyCode }
        return (noErr, reference)
      },
      unregister: { reference in
        let keyCode = self.keyCodes[reference] ?? UInt32.max
        self.unregistered.append(keyCode)
        return self.failingUnregistrations[keyCode] ?? noErr
      },
      installHandler: { _ in
        self.handlersInstalled += 1
        return (noErr, OpaquePointer(bitPattern: 0x10))
      },
      removeHandler: { _ in self.handlersRemoved += 1 })
  } // End of var calls
}

/// A preferences store that loads a fixed result (or fails) and records what it was asked to
/// keep.
actor ScriptedPreferencesStore: PreferencesStoring {
  /// What `load()` gives.
  let loadResult: Result<PreferencesLoadResult, PreferencesStoreError>
  /// What every change throws, if anything.
  let changeFailure: PreferencesStoreError?
  /// The changes asked for, in order.
  private(set) var changes: [GlobalShortcut?] = []

  /// A store loading `result` whose changes fail with `changeFailure` (none: they succeed).
  init(
    _ result: Result<PreferencesLoadResult, PreferencesStoreError>,
    changeFailure: PreferencesStoreError? = nil
  ) {
    loadResult = result
    self.changeFailure = changeFailure
  }

  /// The fixed result.
  func load() throws(PreferencesStoreError) -> PreferencesLoadResult {
    try loadResult.get()
  }

  /// Records the change, then fails or succeeds as told.
  func setGlobalShortcut(
    _ shortcut: GlobalShortcut?
  ) throws(PreferencesStoreError) -> PreferencesChangeResult {
    changes.append(shortcut)
    if let changeFailure { throw changeFailure }
    return PreferencesChangeResult(preferences: Preferences(globalShortcut: shortcut), wrote: true)
  }
}
