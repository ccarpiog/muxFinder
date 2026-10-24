import AppKit
import Foundation
import MuxFinderCore
import Observation

/// What the session switcher shortcut runs on (PLAN.md D32): the preferences file, the hotkey
/// registrar and the keyboard layout. Only the menu bar app in normal mode has one
/// (`AppEnvironment.production(rewritesProfilesAtLaunch:usesGlobalShortcut:)`); the
/// self-tests, the preview modes, every `--report-*` flag and `--remove-persistent-profiles`
/// have none, so they never read `preferences.json` or register a hotkey.
public struct GlobalShortcutEnvironment: Sendable {
  /// The preferences file (`PreferencesStore` in the app).
  public var store: any PreferencesStoring
  /// The hotkey registrar (`CarbonHotkeyRegistrar` in the app).
  public var registrar: any HotkeyRegistering
  /// The keyboard layout labels are read from (`SystemKeyboardLayout` in the app).
  public var layout: any KeyboardLayoutNaming

  /// An environment from its parts.
  public init(
    store: any PreferencesStoring, registrar: any HotkeyRegistering,
    layout: any KeyboardLayoutNaming
  ) {
    self.store = store
    self.registrar = registrar
    self.layout = layout
  }
}

/// One fixed recorder state for previews and the Settings gallery (PLAN.md D32).
public struct GlobalShortcutFixture: Sendable, Hashable {
  /// The saved shortcut.
  public var shortcut: GlobalShortcut?
  /// Its registration.
  public var registration = GlobalShortcutModel.Registration.off
  /// The recorder.
  public var recorder = GlobalShortcutModel.Recorder.idle
  /// The message beside the recorder.
  public var issue: String?
  /// How the preferences file loaded.
  public var fileStatus = GlobalShortcutModel.FileStatus.usable

  /// A fixture from its parts.
  public init(
    shortcut: GlobalShortcut? = nil,
    registration: GlobalShortcutModel.Registration = .off,
    recorder: GlobalShortcutModel.Recorder = .idle,
    issue: String? = nil,
    fileStatus: GlobalShortcutModel.FileStatus = .usable
  ) {
    self.shortcut = shortcut
    self.registration = registration
    self.recorder = recorder
    self.issue = issue
    self.fileStatus = fileStatus
  } // End of init(shortcut:registration:recorder:issue:fileStatus:)
}

/// The session switcher shortcut (PLAN.md D32): its value in `preferences.json`, its hotkey
/// registration and the recorder in Settings › General.
///
/// - **Lifecycle (normal mode only):** `start()` (from `AppModel.start()`, once launching has
///   finished) loads the preferences, which never writes, and registers a saved shortcut;
///   a missing, unusable or unsafe file leaves the hotkey off and the file as it is. A change
///   registers the new shortcut; clearing unregisters it; `shutdown()` (quitting) unregisters
///   it.
/// - **Recording applies at once** (like the launch-at-login toggle, D23; no Save): clicking
///   the recorder suspends the current hotkey (unregistered, so pressing it records it), and
///   the next key combination is checked (`GlobalShortcut.check`): a refusal is shown and the
///   recorder keeps listening; ⌘ with one key, or only ⌥ or ⌥⇧, asks first (`confirming`); a
///   usable one is
///   registered, then saved. A registration that fails (`taken`, …) is shown beside the
///   recorder, never in an alert, and the recorder keeps listening; a save that fails undoes
///   the registration and brings the previous shortcut back, except when it found the file
///   unusable: then the hotkey is off as at launch (nothing registered, the file left as it
///   is, its notice and "Try again", which reloads it once it is fixed or moved away). Esc
///   cancels (the previous shortcut is registered again), Delete (or "Clear") clears.
/// - **Unregistering** forgets the token only once the registrar succeeded. A failure leaves
///   the hotkey registered (it still works, and `registration` says so), is shown beside the
///   recorder and kept for diagnostics (`unregistrationFailure`), and what needed it
///   (recording, clearing, "Try again") does not go on; the next attempt tries again.
/// - **The press** reaches `onPress` (`AppModel.globalShortcutPressed()`), only for the
///   current registration and never while recording.
/// - **Diagnostics** record kinds only (`registration.code`, store error codes), never the
///   combination.
/// - **Fixtures:** `init(fixture:)` shows a fixed state on `StaticKeyboardLayout.previews` and
///   runs nothing.
@MainActor
@Observable
public final class GlobalShortcutModel {
  /// The hotkey's state.
  public enum Registration: Sendable, Hashable {
    /// No shortcut: nothing registered.
    case off
    /// The shortcut is registered.
    case registered
    /// The shortcut is unregistered while the recorder listens.
    case suspended
    /// The saved shortcut could not be registered.
    case failed(HotkeyRegistrationError)

    /// "off", "registered", "suspended", "failed.taken", …: the kind only.
    public var code: String {
      switch self {
      case .off: return "off"
      case .registered: return "registered"
      case .suspended: return "suspended"
      case .failed(let error): return "failed.\(error.code)"
      }
    }
  }

  /// The recorder's state.
  public enum Recorder: Sendable, Hashable {
    /// Not listening.
    case idle
    /// Listening for a key combination.
    case recording
    /// Asking before taking this shortcut (⌘ with one key); still listening.
    case confirming(GlobalShortcut)
  }

  /// How the preferences file loaded.
  public enum FileStatus: Sendable, Hashable {
    /// Not loaded yet.
    case notLoaded
    /// A usable file, or none yet.
    case usable
    /// A usable file whose shortcut was not usable and was left out.
    case shortcutDropped
    /// A file that cannot be used, left as it is: nothing is recorded until it is fixed.
    case notUsable(PreferencesFileProblem)
    /// muxFinder's folder could not be read (the message).
    case unreadable(String)
  }

  /// The saved shortcut, or `nil` when the hotkey is off.
  public private(set) var shortcut: GlobalShortcut?
  /// The hotkey's state.
  public private(set) var registration = Registration.off
  /// The recorder's state.
  public private(set) var recorder = Recorder.idle
  /// The message beside the recorder: a refusal, a failed registration or a failed save.
  public private(set) var issue: String?
  /// How the preferences file loaded.
  public private(set) var fileStatus = FileStatus.notLoaded
  /// Why the hotkey that is still registered could not be unregistered (its token is kept);
  /// `nil` once an unregistration succeeds.
  public private(set) var unregistrationFailure: HotkeyRegistrationError?
  /// Whether a save runs.
  public private(set) var isSaving = false
  /// Whether this model renders a fixture.
  public let isPreview: Bool

  /// Called when the shortcut is pressed (`AppModel` wires its entry point).
  @ObservationIgnored public var onPress: (@MainActor () -> Void)?
  /// The dependencies; `nil` for a fixture and for every mode but normal mode.
  @ObservationIgnored let environment: GlobalShortcutEnvironment?
  /// The operation log, if any.
  @ObservationIgnored let diagnostics: DiagnosticsLog?
  /// Labels come from this layout.
  @ObservationIgnored let layout: any KeyboardLayoutNaming
  /// The current registration's token.
  @ObservationIgnored private(set) var token: HotkeyToken?
  /// The save in progress.
  @ObservationIgnored private var saveTask: Task<Void, Never>?
  /// Whether `start()` ran.
  @ObservationIgnored private var hasStarted = false
  /// Whether `shutdown()` ran: nothing registers or saves any more.
  @ObservationIgnored private(set) var isShutDown = false

  /// A model over `environment` (`nil`: inert, nothing read or registered). Nothing runs until
  /// `start()`.
  public init(environment: GlobalShortcutEnvironment?, diagnostics: DiagnosticsLog? = nil) {
    self.environment = environment
    self.diagnostics = diagnostics
    layout = environment?.layout ?? StaticKeyboardLayout.previews
    isPreview = false
  }

  /// A model that shows `fixture` and never runs anything.
  public init(fixture: GlobalShortcutFixture) {
    environment = nil
    diagnostics = nil
    layout = StaticKeyboardLayout.previews
    isPreview = true
    shortcut = fixture.shortcut
    registration = fixture.registration
    recorder = fixture.recorder
    issue = fixture.issue
    fileStatus = fixture.fileStatus
  }

  // MARK: - Content

  /// The saved shortcut's label.
  public var label: GlobalShortcutLabel? {
    shortcut.map { GlobalShortcutLabel($0, layout: layout) }
  }

  /// `shortcut`'s label on this model's layout.
  public func label(for shortcut: GlobalShortcut) -> GlobalShortcutLabel {
    GlobalShortcutLabel(shortcut, layout: layout)
  }

  /// Whether the recorder listens (recording or confirming).
  public var isRecording: Bool { recorder != .idle }

  /// Whether a shortcut can be recorded or cleared now: a usable file (or none), no save
  /// running; a fixture shows the recorder as it would be.
  public var isEditable: Bool {
    guard environment != nil || isPreview, !isShutDown, !isSaving else { return false }
    switch fileStatus {
    case .usable, .shortcutDropped: return true
    case .notLoaded, .notUsable, .unreadable: return false
    }
  }

  /// The warning shown before taking ⌘ with one key, or only ⌥ or ⌥⇧ with a key, while
  /// confirming.
  public var warning: String? {
    guard case .confirming(let candidate) = recorder else { return nil }
    let text = label(for: candidate).text
    switch candidate.check {
    case .warning(.optionOnly):
      return "macOS may not pass shortcuts with only ⌥ or ⌥⇧ to apps, so \(text) might do "
        + "nothing. Use it anyway?"
    default:
      return "\(text) would stop working in every app while muxFinder uses it. Use it anyway?"
    }
  } // End of var warning

  /// What the preferences file's state means for the shortcut, if anything is wrong with it.
  public var fileNotice: String? {
    switch fileStatus {
    case .notLoaded, .usable:
      return nil
    case .shortcutDropped:
      return "The saved shortcut wasn't usable, so the session switcher shortcut is off. "
        + "Record a new one."
    case .notUsable(let problem) where registration == .registered:
      // Only after a save whose registration could not be undone: the shortcut still works.
      return problem.message + " muxFinder left it as it is, and nothing is saved until it is "
        + "fixed or moved away."
    case .notUsable(let problem):
      return problem.message + " muxFinder left it as it is, and the shortcut is off until it "
        + "is fixed or moved away."
    case .unreadable(let message):
      return "muxFinder couldn't read its settings folder, so the shortcut is off. " + message
    }
  } // End of var fileNotice

  /// Whether "Try again" is offered (the file or the folder could not be used).
  public var canRetryLoading: Bool {
    switch fileStatus {
    case .notUsable, .unreadable: return environment != nil || isPreview
    case .notLoaded, .usable, .shortcutDropped: return false
    }
  }

  /// The state by kind for "Copy diagnostics": the registration, a failed unregistration and
  /// the file's problem if any; never the combination. "not used" without an environment
  /// (every mode but normal mode).
  public var diagnosticsCode: String {
    guard environment != nil || isPreview else { return "not used" }
    var code = registration.code
    if let unregistrationFailure {
      code += "; unregistration failed (\(unregistrationFailure.code))"
    }
    switch fileStatus {
    case .notLoaded: code += "; preferences not loaded"
    case .usable: break
    case .shortcutDropped: code += "; saved shortcut not usable"
    case .notUsable(let problem): code += "; preferences file unusable (\(problem.code))"
    case .unreadable: code += "; settings folder unreadable"
    }
    return code
  } // End of var diagnosticsCode

  // MARK: - Lifecycle

  /// Loads the preferences (never writing) and registers a saved shortcut. Does nothing
  /// without an environment, a second time, or after `shutdown()`.
  public func start() async {
    guard let environment, !hasStarted, !isShutDown else { return }
    hasStarted = true
    environment.registrar.onPress = { [weak self] token in self?.hotkeyPressed(token) }
    await load(environment)
    await record(
      registration == .registered || registration == .off ? .info : .failure,
      "session switcher shortcut at launch: \(diagnosticsCode)")
  }

  /// "Try again" after an unusable file or folder: loads again and registers what it holds. A
  /// hotkey still registered (a save's registration that could not be undone) is unregistered
  /// first; should that fail again, nothing is loaded and the message says so.
  public func retryLoading() async {
    guard let environment, canRetryLoading, !isRecording, !isShutDown else { return }
    if let failure = unregisterCurrent() {
      issue = failure.unregistrationMessage + " Try again."
      await record(.failure, "session switcher shortcut not unregistered: \(failure.code)")
      return
    }
    await load(environment)
    await record(.info, "session switcher shortcut reloaded: \(diagnosticsCode)")
  } // End of func retryLoading()

  /// Reads the preferences and registers the shortcut they hold.
  private func load(_ environment: GlobalShortcutEnvironment) async {
    let loaded: Result<PreferencesLoadResult, PreferencesStoreError>
    do {
      loaded = .success(try await environment.store.load())
    } catch {
      loaded = .failure(error)
    }
    guard !isShutDown else { return }
    switch loaded {
    case .success(let result):
      shortcut = result.preferences.globalShortcut
      switch result.state {
      case .saved, .notSavedYet: fileStatus = result.droppedShortcut ? .shortcutDropped : .usable
      case .invalid(let problem): fileStatus = .notUsable(problem)
      }
    case .failure(let error):
      shortcut = nil
      fileStatus = .unreadable(error.errorDescription ?? "The folder is not usable.")
    }
    resume()
    issue = registrationIssue
  } // End of func load(_:)

  /// Quitting: stops recording, waits for a save in progress, unregisters the hotkey (a
  /// failure is logged by kind; the system unregisters it when the process exits) and stops
  /// listening for presses. Later calls do nothing.
  public func shutdown() async {
    guard !isShutDown else { return }
    isShutDown = true
    recorder = .idle
    await saveTask?.value
    if let failure = unregisterCurrent() {
      await record(.failure, "session switcher shortcut not unregistered at quit: \(failure.code)")
    }
    environment?.registrar.onPress = nil
  } // End of func shutdown()

  /// Returns once the save in progress, if any, has ended (tests).
  func savesFinished() async {
    await saveTask?.value
  }

  // MARK: - Recording

  /// Clicking the recorder: suspends the current hotkey (so pressing it records it) and
  /// listens. Does nothing while the shortcut cannot be edited or for a fixture. A hotkey that
  /// cannot be unregistered stays registered and the recorder does not listen; the message
  /// says so.
  public func startRecording() {
    guard environment != nil, isEditable, recorder == .idle else { return }
    if let failure = unregisterCurrent() {
      issue = failure.unregistrationMessage + " Click the field to try again."
      recordInBackground(.failure, "session switcher shortcut not unregistered: \(failure.code)")
      return
    }
    registration = shortcut == nil ? .off : .suspended
    recorder = .recording
    issue = nil
  } // End of func startRecording()

  /// Esc, a click on the recorder while listening, the window closing or losing the focus,
  /// another Settings tab, the recorder going away: stops listening and registers the saved
  /// shortcut again. Does nothing for a fixture.
  public func cancelRecording() {
    guard environment != nil, recorder != .idle else { return }
    recorder = .idle
    resume()
    issue = registrationIssue
  }

  /// A key pressed while the recorder listens: Esc cancels, Delete or forward delete clears,
  /// Return confirms a warning; any other combination is checked and taken, refused or asked
  /// about. Returns whether the key was the recorder's (always, while listening).
  @discardableResult
  public func handleRecorderKey(keyCode: UInt16, modifiers: GlobalShortcut.Modifiers) -> Bool {
    guard recorder != .idle else { return false }
    if modifiers.isEmpty {
      switch keyCode {
      case GlobalShortcut.KeyCode.escape:
        cancelRecording()
        return true
      case GlobalShortcut.KeyCode.delete, GlobalShortcut.KeyCode.forwardDelete:
        clear()
        return true
      case GlobalShortcut.KeyCode.returnKey:
        if case .confirming = recorder {
          confirmWarning()
          return true
        }
      default:
        break
      }
    } // End of the keys without a modifier
    let candidate = GlobalShortcut(keyCode: keyCode, modifiers: modifiers)
    switch candidate.check {
    case .refused(let refusal):
      recorder = .recording
      issue = refusal.message
    case .warning:
      recorder = .confirming(candidate)
      issue = nil
    case .usable:
      take(candidate)
    }
    return true
  } // End of func handleRecorderKey(keyCode:modifiers:)

  /// "Use it anyway": takes the shortcut the warning was about.
  public func confirmWarning() {
    guard case .confirming(let candidate) = recorder else { return }
    take(candidate)
  }

  /// "Choose another": drops the shortcut the warning was about and keeps listening.
  public func chooseAnother() {
    guard case .confirming = recorder else { return }
    recorder = .recording
  }

  /// "Clear" (or Delete while listening): stops listening, unregisters the hotkey and saves
  /// that there is none. A failed save brings the shortcut back (not when it found the file
  /// unusable: the hotkey is off then). A hotkey that cannot be unregistered stays registered
  /// and saved, and the message says so.
  public func clear() {
    guard environment != nil, isEditable else { return }
    if let failure = unregisterCurrent() {
      issue = failure.unregistrationMessage + " Try again."
      recordInBackground(.failure, "session switcher shortcut not unregistered: \(failure.code)")
      return
    }
    recorder = .idle
    let previous = shortcut
    shortcut = nil
    registration = .off
    issue = nil
    guard previous != nil || fileStatus == .shortcutDropped else { return }
    save(nil, previous: previous)
  } // End of func clear()

  /// Registers `candidate` (the current hotkey is suspended), then saves it. A registration
  /// that fails keeps the recorder listening, with the reason beside it.
  private func take(_ candidate: GlobalShortcut) {
    guard let environment, !isShutDown else { return }
    let newToken: HotkeyToken
    do {
      newToken = try environment.registrar.register(candidate)
    } catch {
      recorder = .recording
      issue = error.message
      recordInBackground(.failure, "session switcher shortcut not registered: \(error.code)")
      return
    }
    recorder = .idle
    let previous = shortcut
    token = newToken
    shortcut = candidate
    registration = .registered
    issue = nil
    save(candidate, previous: previous)
  } // End of func take(_:)

  /// Saves `value` (a recorded shortcut, or `nil` for a clear) in the background. A failure
  /// unregisters what the change registered and says why beside the recorder (`saved`).
  private func save(_ value: GlobalShortcut?, previous: GlobalShortcut?) {
    guard let environment else { return }
    isSaving = true
    saveTask = Task { [weak self] in
      let outcome: PreferencesStoreError?
      do throws(PreferencesStoreError) {
        _ = try await environment.store.setGlobalShortcut(value)
        outcome = nil
      } catch {
        outcome = error
      }
      await self?.saved(value, previous: previous, failure: outcome)
    }
  } // End of func save(_:previous:)

  /// The end of a save. A failure unregisters what the change registered, then:
  /// - the file found unusable (another program broke or replaced it after it loaded): the
  ///   hotkey is off, as a launch with that file leaves it, the file is left as it is (D31's
  ///   refusal rule), and its notice offers "Try again", which reloads it once it is fixed or
  ///   moved away (PLAN.md D32);
  /// - any other failure: `previous` comes back and is registered again;
  /// - the unregistration failing too: the new shortcut stays registered and shown (it is what
  ///   works), unsaved, and the message says so.
  private func saved(
    _ value: GlobalShortcut?, previous: GlobalShortcut?, failure: PreferencesStoreError?
  ) async {
    isSaving = false
    let verb = value == nil ? "cleared" : "recorded"
    guard let failure else {
      fileStatus = .usable
      await record(.success, "session switcher shortcut \(verb)")
      return
    }
    var unusable = false
    if case .fileNotUsable(let problem) = failure {
      fileStatus = .notUsable(problem)
      unusable = true
    }
    // The notice below the recorder explains an unusable file, with "Try again".
    let reason =
      unusable
      ? " Its preferences file can't be used." : failure.errorDescription.map { " " + $0 } ?? ""
    if let stuck = unregisterCurrent() {
      registration = .registered
      issue = "muxFinder couldn't save the shortcut." + reason + " " + stuck.unregistrationMessage
      await record(.failure, "session switcher shortcut not \(verb): \(failure.code)")
      await record(.failure, "session switcher shortcut not unregistered: \(stuck.code)")
      return
    }
    if unusable {
      shortcut = nil
      registration = .off
      issue =
        value == nil
        ? "The shortcut is off, but muxFinder couldn't save that: its preferences file can't be "
          + "used."
        : "muxFinder couldn't save the shortcut: its preferences file can't be used, so the "
          + "shortcut is off."
    } else {
      shortcut = previous
      resume()
      let summary =
        value == nil
        ? "muxFinder couldn't turn off the shortcut, so it stays."
        : "muxFinder couldn't save the shortcut."
      issue = summary + reason
    }
    await record(.failure, "session switcher shortcut not \(verb): \(failure.code)")
  } // End of func saved(_:previous:failure:)

  // MARK: - Registration

  /// Registers the saved shortcut when it is not registered (and the recorder is not
  /// listening): `registered`, `failed` or `off`.
  private func resume() {
    guard let environment, let shortcut, !isShutDown else {
      if shortcut == nil { registration = .off }
      return
    }
    guard token == nil, recorder == .idle else { return }
    do {
      token = try environment.registrar.register(shortcut)
      registration = .registered
    } catch {
      registration = .failed(error)
    }
  } // End of func resume()

  /// Unregisters the current hotkey, if any, and returns why it could not be. The token is
  /// dropped only once the registrar unregistered it (or holds nothing for it, so nothing is
  /// left to undo); after a failure it is kept, so the next attempt can still undo it, the
  /// hotkey still works, and `unregistrationFailure` says why until an attempt succeeds.
  private func unregisterCurrent() -> HotkeyRegistrationError? {
    guard let token, let environment else { return nil }
    do throws(HotkeyRegistrationError) {
      try environment.registrar.unregister(token)
    } catch .unknownToken {
      // The registrar holds no such registration: there is nothing left to undo.
    } catch {
      unregistrationFailure = error
      return error
    }
    self.token = nil
    unregistrationFailure = nil
    return nil
  } // End of func unregisterCurrent()

  /// The failed registration's message, if the saved shortcut is not registered.
  private var registrationIssue: String? {
    if case .failed(let error) = registration { return error.message }
    return nil
  }

  /// A hotkey was pressed: only the current registration's press reaches `onPress`.
  func hotkeyPressed(_ pressed: HotkeyToken) {
    guard pressed == token, recorder == .idle, !isShutDown else { return }
    onPress?()
  }

  /// Records a settings event: kinds only, never the combination.
  private func record(_ outcome: DiagnosticOutcome, _ detail: String) async {
    await diagnostics?.record(.settings, outcome: outcome, detail: detail)
  }

  /// Records a settings event from a synchronous action, in the background.
  private func recordInBackground(_ outcome: DiagnosticOutcome, _ detail: String) {
    Task { await record(outcome, detail) }
  }
}

extension GlobalShortcut.Modifiers {
  /// The modifiers among an event's flags (⌃, ⌥, ⇧, ⌘; Caps Lock, Fn and the keypad flag are
  /// ignored).
  public init(eventFlags: NSEvent.ModifierFlags) {
    self.init()
    let flags = eventFlags.intersection(.deviceIndependentFlagsMask)
    if flags.contains(.control) { insert(.control) }
    if flags.contains(.option) { insert(.option) }
    if flags.contains(.shift) { insert(.shift) }
    if flags.contains(.command) { insert(.command) }
  }
}
