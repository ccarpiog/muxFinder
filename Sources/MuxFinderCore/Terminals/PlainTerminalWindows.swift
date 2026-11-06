import Foundation

/// A window the plain window layer opened in a terminal app (PLAN.md D38, Phase I-12b3): the
/// loaded definition that opened it and what the app reported, each value `nil` when the app did
/// not report it. An `exec` definition's window has neither (the schema ties `tty` and
/// `windowID` focus to `appleScript`).
///
/// The window is bound to the exact `LoadedTerminalDefinition` that opened it (its definition,
/// source, file name and script, compared whole): its id and terminal device mean something only
/// to that definition's app and script. A focus or close through any other loaded definition,
/// also one with the same id (a user override of a built-in, or the definition loaded again with
/// another bundle identifier or script), is refused with nothing sent (`definitionChanged`).
public struct PlainTerminalWindow: Sendable, Hashable {
  /// The loaded definition whose open made this window.
  public let openedBy: LoadedTerminalDefinition
  /// The window's id, as `muxfinder_open` answered it (Terminal: an integer; Ghostty: its
  /// "Stable ID").
  public let windowID: String?
  /// The terminal device of the window's tab, such as `/dev/ttys004`.
  public let tty: String?

  /// A window `openedBy` opened, with these values.
  public init(openedBy: LoadedTerminalDefinition, windowID: String?, tty: String?) {
    self.openedBy = openedBy
    self.windowID = windowID
    self.tty = tty
  }

  /// The id of the terminal definition that opened it.
  public var definitionID: String { openedBy.definition.id }
} // End of struct PlainTerminalWindow

/// The plain window layer (PLAN.md D38, Phase I-12b3): opens, focuses and closes the windows of
/// a terminal app described by a `LoadedTerminalDefinition`, each running the launch helper in
/// plain mode (`LaunchHelperMode.attachPlain`). It is the plain backend's window half
/// (`PlainTerminalWindowLayer`; `PlainTerminalBackend`, Phase I-12c1, confirms, detaches and
/// moves here through tmux). The app makes one layer for its plain backends (Phase I-12c3a).
///
/// - **The facts first.** Before any Apple event, compile or spawn, the app's facts are read
///   (`TerminalAppFacts`, no event sent): an app LaunchServices does not find, one older than
///   the definition's minimum, one whose version cannot be read, and an Automation permission
///   read as `denied` are typed failures with nothing sent. `notDetermined` and
///   `targetNotRunning` go ahead for an open (a person asked for the window and can answer the
///   prompt; launching the app is the open's purpose). A focus or close sends nothing to an app
///   that is not running (an Apple event would launch it): `appNotRunning`.
/// - **The opener.** A focus or close takes only a window the given loaded definition itself
///   opened: another definition id's window is `windowOfAnotherTerminal`, a window another
///   loaded definition with the same id opened (an override, or a reload with other contents)
///   is `definitionChanged`; both before anything is read, compiled or sent.
/// - **Open.** The launch command from `TerminalLaunchCommand` for the helper path, the mode
///   word `LaunchHelperMode.attachPlain` and the token, checked before anything else happens.
///   `appleScript`: the script compiled once per loaded definition for this layer's lifetime
///   (a failed compile is not kept, so a later request compiles again), then `muxfinder_open`
///   through `TerminalScriptCalls`, its reply read strictly. `exec`: the argv
///   `TerminalLaunchCommand.execArgv(_:inApp:)` builds, the executable inside the app
///   LaunchServices found, started through `TerminalProcessSpawning` without a shell, never
///   waited for and never ended (`DetachedTerminalProcessSpawner`).
/// - **Focus** by the definition's focus kind: `tty` calls `muxfinder_focus` with the window's
///   terminal device, `windowID` with its id (the other argument empty); a window lacking that
///   value is refused with nothing sent. `app` brings the running app forward through
///   `TerminalAppActivating`, with no Apple event and never launching it.
/// - **Close** only a window whose id this layer's own open recorded for that same loaded
///   definition (any other is refused with nothing sent), through `muxfinder_close`; never as
///   a detach (detach is tmux's, D38). A busy window (1001) stays recorded.
/// - **Forgetting.** A window found missing (-1728) by a focus or a close is forgotten, so it is
///   never closed by its old id. An app seen not running (by any facts read, an open's
///   included, or by the activator) has every window recorded for it forgotten, whichever
///   loaded definition with its bundle identifier opened them: window ids are not stable across
///   a restart of the app. Forgetting only ever leaves a window open.
///
/// - **Run policy** (`PlainRunPolicy`, Phase I-12c3a review fix): `interactive` (the app's,
///   the default) adds nothing. `unattended` (the probe's *Unattended-run rules* 8) applies
///   `PlainRunGate` to the facts the open, focus or close read first, and again to facts read
///   right before each Apple event (`muxfinder_open`, `muxfinder_focus`, `muxfinder_close`)
///   and each `exec` spawn: an app not running or a permission not reading granted refuses
///   (`unattendedRunRefused`) with nothing sent or launched. `checkRunPolicy(for:)` is the same
///   check for the plain backend to make right before it writes a request.
///
/// Every failure is one `PlainTerminalWindowError`, never retried (D13). The layer runs on the
/// main actor, as `AppleScriptRunning` does. It has no default seams: the app passes the real
/// ones, tests pass fakes, so no check can send a real Apple event by omission.
@MainActor
public final class PlainTerminalWindows {
  /// How many recorded window ids are kept; an older one can no longer be closed, which only
  /// leaves a window open.
  public static let rememberedWindows = 64

  /// A window id an open recorded, bound to the loaded definition whose open recorded it.
  struct RecordedWindow: Hashable {
    /// The loaded definition that opened the window (compared whole).
    let openedBy: LoadedTerminalDefinition
    /// The window's id.
    let windowID: String
  }

  /// Compiles scripts and calls their handlers.
  let runner: any AppleScriptRunning
  /// Reads the apps' facts.
  let inspector: any TerminalAppInspecting
  /// Starts `exec` definitions' programs.
  let spawner: any TerminalProcessSpawning
  /// Brings running apps forward for `app` focus.
  let activator: any TerminalAppActivating
  /// The environment an `exec` definition's program gets.
  let environment: [String: String]
  /// How strictly the app is guarded at each side effect (`interactive` unless the caller is
  /// an unattended run).
  public let policy: PlainRunPolicy
  /// The compiled scripts, by the loaded definition they came from.
  private var compiled: [LoadedTerminalDefinition: TerminalScriptCalls] = [:]
  /// The window ids this layer's opens recorded and has not forgotten, oldest first.
  private(set) var recordedWindows: [RecordedWindow] = []

  /// A layer over these seams; `environment` (by default this process's) is what an `exec`
  /// definition's program gets, and `policy` (by default `interactive`, the app's) how
  /// strictly each side effect is guarded.
  public init(
    runner: any AppleScriptRunning,
    inspector: any TerminalAppInspecting,
    spawner: any TerminalProcessSpawning,
    activator: any TerminalAppActivating,
    environment: [String: String] = ProcessInfo.processInfo.environment,
    policy: PlainRunPolicy = .interactive
  ) {
    self.runner = runner
    self.inspector = inspector
    self.spawner = spawner
    self.activator = activator
    self.environment = environment
    self.policy = policy
  } // End of init(runner:inspector:spawner:activator:environment:policy:)

  // MARK: - Open

  /// Opens a new window of `loaded`'s app running `<helperPath> attach-plain <token>` and
  /// returns it. The facts are checked first, then the launch command; then an `appleScript`
  /// definition's script is compiled (once) and `muxfinder_open` called, or an `exec`
  /// definition's program is started.
  public func open(
    _ loaded: LoadedTerminalDefinition,
    helperPath: String,
    token: LaunchToken
  ) throws(PlainTerminalWindowError) -> PlainTerminalWindow {
    let definition = loaded.definition
    let facts = try checkedFacts(for: definition, requiringRunning: false)
    try enforcePolicy(for: definition, facts: facts)
    let command = TerminalLaunchCommand(
      helperPath: helperPath, mode: LaunchHelperMode.attachPlain.word, token: token.rawValue)
    switch definition.open {
    case .appleScript(_, let form):
      do throws(TerminalLaunchCommandError) {
        _ = try command.appleScriptArguments(form: form)
      } catch {
        throw .launchCommandRefused(error)
      }
      let calls = try compiledCalls(for: loaded)
      // Right before the Apple event: the app may have quit while the script compiled.
      try enforcePolicy(for: definition)
      let reply: TerminalOpenReply
      do throws(TerminalScriptCallError) {
        reply = try calls.open(command)
      } catch {
        throw Self.failure(error, appName: definition.displayName)
      }
      if let windowID = reply.windowID {
        record(RecordedWindow(openedBy: loaded, windowID: windowID))
      }
      return PlainTerminalWindow(openedBy: loaded, windowID: reply.windowID, tty: reply.tty)
    case .exec:
      try spawn(definition, command: command, appPath: facts.path)
      return PlainTerminalWindow(openedBy: loaded, windowID: nil, tty: nil)
    }
  } // End of func open(_:helperPath:token:)

  /// Starts an `exec` definition's program: its argv for `command`, its executable inside the
  /// app at `appPath`.
  private func spawn(
    _ definition: TerminalDefinition,
    command: TerminalLaunchCommand,
    appPath: String?
  ) throws(PlainTerminalWindowError) {
    guard let appPath else { throw .appNotInstalled(appName: definition.displayName) }
    let appURL = URL(filePath: appPath, directoryHint: .isDirectory)
    let argv: (executable: URL, arguments: [String])?
    do throws(TerminalLaunchCommandError) {
      argv = try command.execArgv(definition.open, inApp: appURL)
    } catch {
      throw .launchCommandRefused(error)
    }
    guard let argv else { throw .scriptMissing(appName: definition.displayName) }
    // Right before the spawn, which would launch an app that is not running.
    try enforcePolicy(for: definition)
    do throws(ProcessRunnerError) {
      _ = try spawner.spawn(
        TerminalSpawnRequest(
          executable: argv.executable, arguments: argv.arguments, environment: environment))
    } catch {
      throw .spawnFailed(appName: definition.displayName, error)
    }
  } // End of func spawn(_:command:appPath:)

  // MARK: - Focus

  /// Brings `window` forward by `loaded`'s focus kind: `tty` or `windowID` through
  /// `muxfinder_focus` (the app must be running), `app` through the activator. Only a window
  /// `loaded` itself opened. A window found missing (-1728) is forgotten, as is every window of
  /// an app seen not running.
  public func focus(
    _ window: PlainTerminalWindow,
    of loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) {
    let definition = loaded.definition
    let app = definition.displayName
    try checkOpener(of: window, is: loaded)
    let windowID: String?
    let tty: String?
    switch definition.focus {
    case .app:
      switch activator.activate(bundleIdentifier: definition.bundleIdentifier) {
      case .activated: return
      case .notRunning:
        forgetWindows(ofApp: definition.bundleIdentifier)
        throw .appNotRunning(appName: app)
      case .refused: throw .activationFailed(appName: app)
      }
    case .tty:
      guard let value = window.tty else { throw .windowLacksFocusValue(appName: app, .tty) }
      windowID = nil
      tty = value
    case .windowID:
      guard let value = window.windowID else {
        throw .windowLacksFocusValue(appName: app, .windowID)
      }
      windowID = value
      tty = nil
    }
    let facts = try checkedFacts(for: definition, requiringRunning: true)
    try enforcePolicy(for: definition, facts: facts)
    let calls = try compiledCalls(for: loaded)
    try enforcePolicy(for: definition)
    do throws(TerminalScriptCallError) {
      try calls.focus(windowID: windowID, tty: tty)
    } catch {
      let failure = Self.failure(error, appName: app)
      // Missing by the script's answer: its id may be handed out again, so it is never closed
      // by its record.
      if case .windowGone = failure { forgetRecord(of: window) }
      throw failure
    }
  } // End of func focus(_:of:)

  // MARK: - Close

  /// Closes `window` through `muxfinder_close`, only when its id is one this layer's own open
  /// recorded for `loaded` itself (the same loaded definition, compared whole). Closing is
  /// never a detach.
  public func close(
    _ window: PlainTerminalWindow,
    of loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) {
    let definition = loaded.definition
    let app = definition.displayName
    try checkOpener(of: window, is: loaded)
    guard let windowID = window.windowID else { throw .windowHasNoID(appName: app) }
    let recorded = RecordedWindow(openedBy: loaded, windowID: windowID)
    guard recordedWindows.contains(recorded) else { throw .notOpenedHere }
    // An app that is not running has every record of its windows forgotten by the facts read.
    let facts = try checkedFacts(for: definition, requiringRunning: true)
    try enforcePolicy(for: definition, facts: facts)
    let calls = try compiledCalls(for: loaded)
    try enforcePolicy(for: definition)
    do throws(TerminalScriptCallError) {
      try calls.close(windowID: windowID)
    } catch {
      let failure = Self.failure(error, appName: app)
      // Missing by the script's answer: its id may be handed out again, so it is never closed
      // by this record.
      if case .windowGone = failure { forget(recorded) }
      throw failure
    }
    forget(recorded)
  } // End of func close(_:of:)

  // MARK: - Run policy

  /// The run policy's check for `loaded`'s app, for the plain backend to make right before it
  /// writes a launch request: nothing for `interactive`; for `unattended`, `PlainRunGate` over
  /// facts read now (no event sent), `unattendedRunRefused` when the run may not go ahead.
  public func checkRunPolicy(
    for loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) {
    try enforcePolicy(for: loaded.definition)
  }

  /// `unattended` only: refuses (`unattendedRunRefused`) when `PlainRunGate` refuses
  /// `definition` with `facts`, or with facts read now when none are given (an app seen not
  /// running has its windows forgotten, as every facts read does). `interactive` reads nothing.
  func enforcePolicy(
    for definition: TerminalDefinition,
    facts given: TerminalAppFacts? = nil
  ) throws(PlainTerminalWindowError) {
    guard policy == .unattended else { return }
    let facts = given ?? TerminalAppFacts.read(for: definition, inspector: inspector)
    if !facts.running { forgetWindows(ofApp: definition.bundleIdentifier) }
    if let refusal = PlainRunGate.check(definition, facts: facts) {
      throw .unattendedRunRefused(appName: definition.displayName, refusal)
    }
  } // End of func enforcePolicy(for:facts:)

  // MARK: - Shared steps

  /// Refuses, with nothing read, compiled or sent, a window `loaded` did not open itself:
  /// another definition id's (`windowOfAnotherTerminal`), or another loaded definition's with
  /// the same id, such as a user override of a built-in or the definition loaded again with
  /// another bundle identifier or script (`definitionChanged`, named by the window's app).
  func checkOpener(
    of window: PlainTerminalWindow,
    is loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) {
    guard window.definitionID == loaded.definition.id else { throw .windowOfAnotherTerminal }
    guard window.openedBy == loaded else {
      throw .definitionChanged(appName: window.openedBy.definition.displayName)
    }
  }

  /// Reads `definition`'s app facts and refuses, with nothing sent: an app LaunchServices does
  /// not find, too old, of unknown version, a permission read as denied, and (when
  /// `requiringRunning`) an app that is not running. Returns the facts otherwise. Facts that
  /// show the app not running forget every window recorded for it, whatever is refused.
  func checkedFacts(
    for definition: TerminalDefinition,
    requiringRunning: Bool
  ) throws(PlainTerminalWindowError) -> TerminalAppFacts {
    let facts = TerminalAppFacts.read(for: definition, inspector: inspector)
    if !facts.running { forgetWindows(ofApp: definition.bundleIdentifier) }
    let app = definition.displayName
    let minimum = definition.minimumVersion.text
    switch facts.versionCheck {
    case .meets: break
    case .notInstalled: throw .appNotInstalled(appName: app)
    case .tooOld:
      throw .appTooOld(appName: app, installed: facts.version ?? "", minimum: minimum)
    case .unknown: throw .appVersionUnknown(appName: app, minimum: minimum)
    }
    if case .permission(.denied, _) = facts.automation { throw .permissionDenied(appName: app) }
    if requiringRunning, !facts.running { throw .appNotRunning(appName: app) }
    return facts
  } // End of func checkedFacts(for:requiringRunning:)

  /// `loaded`'s compiled script, compiling it the first time it is asked for.
  func compiledCalls(
    for loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError) -> TerminalScriptCalls {
    if let calls = compiled[loaded] { return calls }
    do throws(TerminalScriptCallError) {
      let calls = try TerminalScriptCalls.compile(loaded, with: runner)
      compiled[loaded] = calls
      return calls
    } catch {
      throw Self.failure(error, appName: loaded.definition.displayName)
    }
  } // End of func compiledCalls(for:)

  /// Records `window`'s id as opened here (again last), keeping the newest
  /// `rememberedWindows`.
  private func record(_ window: RecordedWindow) {
    recordedWindows.removeAll { $0 == window }
    recordedWindows.append(window)
    if recordedWindows.count > Self.rememberedWindows {
      recordedWindows.removeFirst(recordedWindows.count - Self.rememberedWindows)
    }
  }

  /// Forgets `window`'s id.
  private func forget(_ window: RecordedWindow) {
    recordedWindows.removeAll { $0 == window }
  }

  /// Forgets the record of `window`'s id, if it has one.
  private func forgetRecord(of window: PlainTerminalWindow) {
    guard let windowID = window.windowID else { return }
    forget(RecordedWindow(openedBy: window.openedBy, windowID: windowID))
  }

  /// Forgets every recorded window of the app with `bundleIdentifier`, whichever loaded
  /// definition opened it (bundle identifiers compared without regard to case, as
  /// LaunchServices does): the app was seen not running, so its windows are gone, and after a
  /// restart their ids may name other windows.
  private func forgetWindows(ofApp bundleIdentifier: String) {
    let app = bundleIdentifier.lowercased()
    recordedWindows.removeAll { $0.openedBy.definition.bundleIdentifier.lowercased() == app }
  }

  /// The layer's failure for a handler call's: the permission's refusal (-1743), a window that
  /// is not there (-1728, from focus or close) and a busy window (1001, from close) by name,
  /// every other runner failure with its number.
  static func failure(
    _ error: TerminalScriptCallError,
    appName app: String
  ) -> PlainTerminalWindowError {
    switch error {
    case .launchCommand(let reason):
      return .launchCommandRefused(reason)
    case .runner(.callFailed(_, let number)) where number == Int(AutomationPermission.deniedStatus):
      return .permissionDenied(appName: app)
    case .runner(.callFailed(let handler, let number))
    where number == TerminalScriptCalls.windowNotFoundErrorNumber && handler != .open:
      return .windowGone(appName: app)
    case .runner(.callFailed(.close, let number))
    where number == TerminalScriptCalls.windowBusyErrorNumber:
      return .windowBusy(appName: app)
    case .runner(let failure):
      return .scriptFailed(appName: app, failure)
    case .unexpectedReply(let handler):
      return .malformedReply(appName: app, handler: handler)
    case .notAppleScript:
      return .scriptMissing(appName: app)
    }
  } // End of static func failure(_:appName:)
} // End of class PlainTerminalWindows

/// The plain backend's window half (Phase I-12c1): open and focus, unchanged. Declared here,
/// next to the class, since the protocol is `Sendable`.
extension PlainTerminalWindows: PlainTerminalWindowLayer {}
