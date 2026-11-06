import Foundation
import MuxFinderCore

/// The terminal setting and the terminal backends (PLAN.md D38, Phase I-12c3a; requirements 7,
/// 8 and 12 of `autoclaude/processed/110-other-terminal-apps.md`).
///
/// - **Resolution:** at launch the definitions load once and the stored `terminal`
///   (`preferences.json`, only in normal mode) resolves through `TerminalChoice` against
///   LaunchServices' answers: iTerm2, a plain definition, or unavailable with the reason. An
///   absent value resolves to the default (iTerm2 when installed, otherwise Terminal) and is
///   never written. Until then the choice is `unresolved`, which gates iTerm2 like a choice
///   that is not iTerm2 (Settings can open before the model starts); once it resolves to
///   iTerm2, what waited for it runs (Settings' profile list while its window is open, D26's
///   launch rewrite). Without `AppEnvironment.terminal` the choice is iTerm2 from the start
///   and nothing is read.
/// - **One setter:** `setTerminal(_:)` (the picker in Settings › General and onboarding,
///   `terminalPicker`, Phase I-12d1) writes the setting and resolves it again; no file watcher.
///   A change while any session action is pending is applied once none is, never cancelling
///   one; the next action uses the new choice, and the picker says it waits.
/// - **Resolved again after each picker reading** (`resolveTerminalAgain()`: a window's opening
///   or "Check again"): the stored setting, unchanged and not saved again, so a plain or
///   unavailable choice follows its app becoming usable (or not); never another terminal, and
///   with iTerm2 chosen nothing changes.
/// - **Wording** (Phase I-12d1): `terminalWording` names the applied choice everywhere the UI
///   names the terminal (`TerminalWording`); with iTerm2 every string is as before.
/// - **Gating** (requirement 7): applying a choice turns the engine's D16 checks on only for
///   iTerm2, tells Settings (the profile list, the iTerm2 problem, D26's rewrite after a save,
///   the wording), the picker, and the three "Set up SSH in iTerm2…" owners (the popover's,
///   Settings', onboarding's: iTerm2's tab, or a plain terminal's window), and,
///   when iTerm2 becomes the choice again, asks for D26's launch rewrite. Work started under an
///   earlier iTerm2 choice (a buried tab's recovery inside the coordinator) finishes; nothing new
///   starts.
/// - **Backends:** one per terminal id, built lazily at the first action that needs it through
///   `AppEnvironment.makeTerminalBackend`, cached for the model's life, so switching back reuses
///   the earlier backend (no record lost, never two coordinators on one iTerm2). An Open or a
///   Move here is refused (`earlierLaunchPending`, nothing run) while another cached backend
///   holds a launch of the session that may still attach it; each backend's records stay its
///   own (`terminalAttachmentsByTerminal`), and only the chosen one's are offered and routed.
extension AppModel {
  // MARK: - Resolution

  /// Loads the definitions and resolves the stored setting at launch, then applies the result
  /// (before the engine is built, so its checks start in the right state). Without
  /// `AppEnvironment.terminal` the choice stays iTerm2 and nothing is read. A preferences file
  /// that cannot be read or used gives the default, as an absent value does (the file is left
  /// as it is).
  func resolveTerminalAtLaunch(_ environment: AppEnvironment) async {
    guard let terminal = environment.terminal else { return }
    let catalog = await Task.detached(priority: .userInitiated) { terminal.loadDefinitions() }
      .value
    terminalDefinitions = catalog
    var stored: String?
    if let preferences = terminal.preferences,
      let loaded = try? await preferences.load(), loaded.state == .saved
    {
      stored = loaded.preferences.terminal
    }
    storedTerminal = stored
    let resolution = terminal.resolve(stored: stored, catalog: catalog)
    applyTerminalChoice(resolution)
    await environment.diagnostics?.record(
      .settings, outcome: resolution.chosen == nil ? .failure : .info,
      detail: "terminal at launch: \(Self.terminalLogText(resolution, stored: stored))")
  } // End of func resolveTerminalAtLaunch(_:)

  /// Changes the terminal setting (the one setter; Phase I-12d's picker calls it): `id` is
  /// `iterm2` or a definition's id, `nil` goes back to the default (the key removed, the default
  /// never written). The value is saved through `preferences.json`'s store first (D32's rules;
  /// a refused save changes nothing and returns its error); then the setting is resolved again
  /// and applied at once, or, while a session action is pending, once none is
  /// (`pendingTerminalChoice`). Returns the new resolution. Does nothing (returns the current
  /// one) for a fixture, after `shutdown()`, or without `AppEnvironment.terminal`.
  @discardableResult
  public func setTerminal(
    _ id: String?
  ) async -> Result<TerminalChoiceResolution, PreferencesStoreError> {
    guard let terminal = environment?.terminal, lifecycle != .stopped else {
      return .success(terminalChoice)
    }
    if let preferences = terminal.preferences {
      do {
        _ = try await preferences.setTerminal(id)
      } catch {
        await environment?.diagnostics?.record(
          .settings, outcome: .failure, detail: "terminal setting not saved: \(error.code)")
        return .failure(error)
      }
    }
    storedTerminal = id
    let catalog = terminalDefinitions ?? terminal.loadDefinitions()
    terminalDefinitions = catalog
    let resolution = terminal.resolve(stored: id, catalog: catalog)
    await environment?.diagnostics?.record(
      .settings, outcome: resolution.chosen == nil ? .failure : .info,
      detail: "terminal set: \(Self.terminalLogText(resolution, stored: id))")
    if hasPendingSessionActions {
      pendingTerminalChoice = resolution
      terminalPicker.setPending(resolution)
    } else {
      pendingTerminalChoice = nil
      applyTerminalChoice(resolution)
    }
    return .success(resolution)
  } // End of func setTerminal(_:)

  /// The picker read the apps again (a window's opening or "Check again"): resolves the stored
  /// setting again through the same path as `setTerminal(_:)` (nothing saved) and takes the
  /// result only when it changed and names the same terminal as the selected choice (a waiting
  /// change's, else the applied one), so the user's choice is never replaced by another
  /// terminal. A plain or unavailable choice only: with iTerm2 chosen, or before the launch's
  /// resolution, nothing changes. Applied at once, or, while a session action is pending, once
  /// none is (`pendingTerminalChoice`), as a change is. Does nothing for a fixture, after
  /// `shutdown()`, or without `AppEnvironment.terminal`.
  func resolveTerminalAgain() {
    guard let terminal = environment?.terminal, lifecycle != .stopped,
      let catalog = terminalDefinitions
    else { return }
    let selected = pendingTerminalChoice ?? terminalChoice
    switch selected {
    case .plain, .unavailable: break
    case .iTerm2, .unresolved: return
    }
    let resolution = terminal.resolve(stored: storedTerminal, catalog: catalog)
    guard resolution != selected, resolution.terminalID == selected.terminalID else { return }
    let diagnostics = environment?.diagnostics
    let detail =
      "terminal resolved again: \(Self.terminalLogText(resolution, stored: storedTerminal))"
    Task {
      await diagnostics?.record(
        .settings, outcome: resolution.chosen == nil ? .failure : .info, detail: detail)
    }
    if hasPendingSessionActions {
      pendingTerminalChoice = resolution
      terminalPicker.setPending(resolution)
    } else {
      pendingTerminalChoice = nil
      applyTerminalChoice(resolution)
    }
  } // End of func resolveTerminalAgain()

  /// Applies `resolution` everywhere it gates iTerm2 (see the extension's comment). The
  /// engine's change goes through the request queue (at launch the engine is not built yet:
  /// `start()` sets its checks itself before its cadence starts).
  func applyTerminalChoice(_ resolution: TerminalChoiceResolution) {
    let previous = terminalChoice
    setTerminalGates(resolution)
    let usesITerm2 = resolution.usesITerm2
    guard previous != resolution else { return }
    if engine != nil { send(.setAttachmentChecks(usesITerm2)) }
    if !previous.usesITerm2, usesITerm2, environment?.rewritesProfilesAtLaunch == true,
      let savedHosts
    {
      settings.keepProfilesCurrentAtLaunch(savedHosts)
    }
  } // End of func applyTerminalChoice(_:)

  /// Makes `resolution` the choice and tells the gates that need no engine: Settings (its
  /// profile list, iTerm2 problem and D26 update after a save; a profile list deferred while
  /// the window was open runs once iTerm2 is the choice; the wording), the picker (the applied
  /// choice, a waiting one, the definitions) and the three "Set up SSH in iTerm2…" owners (the
  /// popover's, Settings', onboarding's). `init(environment:)` sets `unresolved` through it, so
  /// nothing there contacts iTerm2 before the stored choice is known.
  func setTerminalGates(_ resolution: TerminalChoiceResolution) {
    terminalChoice = resolution
    let wording = TerminalWording(resolution, catalog: terminalDefinitions)
    settings.setTerminal(resolution)
    settings.terminalWording = wording
    terminalPicker.update(
      choice: resolution, pending: pendingTerminalChoice, catalog: terminalDefinitions)
    sshSetup.setTerminal(resolution, wording: wording)
    settings.sshSetup.setTerminal(resolution, wording: wording)
    onboarding.sshSetup.setTerminal(resolution, wording: wording)
  } // End of func setTerminalGates(_:)

  /// The applied choice's wording (`TerminalWording`): iTerm2's for iTerm2, while the choice is
  /// not resolved yet and for a fixture.
  public var terminalWording: TerminalWording {
    TerminalWording(terminalChoice, catalog: terminalDefinitions)
  }

  /// Whether any session action is pending: an open, move here, detach or "Detach other
  /// clients…", a New session being created, an "Open existing" lookup, or a focus ("Show
  /// tab", a window's or an app's).
  var hasPendingSessionActions: Bool {
    !runningActions.isEmpty || creation != nil || !lookups.isEmpty || !showTabTasks.isEmpty
  }

  /// Applies a terminal choice that waited for the pending session actions, once none is
  /// pending. Called whenever one ends.
  func applyPendingTerminalChoiceIfIdle() {
    guard let pending = pendingTerminalChoice, !hasPendingSessionActions else { return }
    pendingTerminalChoice = nil
    applyTerminalChoice(pending)
  }

  /// The log line of a resolution: its kind and terminal id (a definition's id or `iterm2`, no
  /// user data; an unusable stored value is not repeated), and the reason when unavailable.
  static func terminalLogText(_ resolution: TerminalChoiceResolution, stored: String?) -> String {
    let source = stored == nil ? "default" : "stored"
    switch resolution {
    case .iTerm2:
      return "iterm2 (\(source))"
    case .plain(let loaded):
      return "plain \(loaded.definition.id) (\(source))"
    case .unavailable(let failure):
      let id = LaunchTerminalApp(failure.terminalID).map(\.rawValue) ?? "(not a terminal id)"
      return "unavailable \(id), \(failure.kind) (\(source))"
    case .unresolved:
      return "unresolved"
    }
  } // End of static func terminalLogText(_:stored:)

  // MARK: - Backends

  /// The backend of the chosen terminal, built at the first action that needs it through
  /// `AppEnvironment.makeTerminalBackend` (its update handler feeds `actionEvents`) and kept
  /// per terminal id. `nil` for a fixture, without the seam, after `shutdown()`, while the
  /// choice is not resolved yet or unavailable, or when it cannot be built; `backendProblem`
  /// then says why (none for the first four).
  func backend() -> (any TerminalBackend)? {
    backendProblem = nil
    guard lifecycle != .stopped, let factory = environment?.makeTerminalBackend else {
      return nil
    }
    let chosen: ChosenTerminal
    switch terminalChoice {
    case .unavailable(let failure):
      backendProblem = .terminalUnavailable(failure)
      return nil
    case .unresolved: return nil
    case .iTerm2: chosen = .iTerm2
    case .plain(let loaded): chosen = .plain(loaded)
    }
    if let built = backends[chosen.id] { return built }
    let sink = actionSink
    do {
      let made = try factory(chosen) { update in sink.yield(.update(update)) }
      backends[chosen.id] = made
      startActionReader()
      return made
    } catch {
      let fallback =
        chosen.usesITerm2
        ? "muxFinder could not prepare opening sessions in iTerm2."
        : "muxFinder could not prepare opening sessions in this terminal."
      backendProblem = .unavailable(
        (error as? LocalizedError)?.errorDescription ?? fallback)
      return nil
    }
  } // End of func backend()

  /// The chosen terminal's backend if it was built already (nothing is built): what "Show
  /// tab" uses, as it used the coordinator only once an action had built it.
  var builtBackend: (any TerminalBackend)? {
    terminalChoice.chosen.flatMap { backends[$0.id] }
  }

  /// The backends built so far for every terminal id but `terminalID` (all of them for
  /// `nil`), in no particular order: those an Open or a Move here asks for an unresolved launch
  /// of its session (`TerminalBackend.hasUnresolvedLaunch(for:)`).
  func otherBackends(than terminalID: String?) -> [any TerminalBackend] {
    backends.filter { $0.key != terminalID }.map(\.value)
  }

  // MARK: - Focus

  /// Brings forward what `handle` names for `key` through the chosen terminal's backend
  /// (PLAN.md D38): a plain window it opened, or an app the session is open in on this Mac
  /// (`.app`, through the app activator: no Apple event, nothing launched). A handle of another
  /// terminal's backend is refused with nothing sent. A note under the session says when
  /// nothing came forward (`SessionProblem.focusNote(_:)`). Does nothing for a fixture, after
  /// `shutdown()`, or without a backend (an unavailable choice shows its problem).
  public func focus(_ handle: TerminalAttachmentHandle, for key: SessionKey) {
    guard let backend = backend() else {
      if let backendProblem { notes[key] = backendProblem.message }
      return
    }
    startFocus(handle, on: backend, for: key)
  }

  /// "Show window": brings forward the plain window of `key`'s attachment, or the app it was
  /// found open in, as the chosen terminal's backend recorded it (`terminalAttachments`; another
  /// terminal's record is never routed here); nothing without one.
  public func showWindow(for key: SessionKey) {
    guard let handle = terminalAttachments[key] else { return }
    focus(handle, for: key)
  }

  /// Runs one focus of `handle` on `backend` as a "Show tab" request (`showTabTasks`, so
  /// quitting waits for it and a terminal change waits until it ended).
  func startFocus(
    _ handle: TerminalAttachmentHandle, on backend: any TerminalBackend, for key: SessionKey
  ) {
    notes[key] = nil
    nextShowTabID += 1
    let number = nextShowTabID
    showTabTasks[number] = Task { [weak self] in
      let result = await backend.focus(handle)
      self?.focusEnded(number, key: key, result: result)
    }
  }

  /// One focus ended: its note, if any, shows under the session.
  func focusEnded(_ number: Int, key: SessionKey, result: TerminalFocusResult) {
    showTabTasks[number] = nil
    notes[key] = SessionProblem.focusNote(result)
    applyPendingTerminalChoiceIfIdle()
  }
} // End of extension AppModel
