import Foundation
import MuxFinderCore

/// The session rows per terminal (PLAN.md D38 *The UI (I-12d2)*; requirement 9): the wording of
/// the terminal whose backend ran an action, the chosen plain terminal's windows ("Show window",
/// "Detach from this Mac"), and the records other terminals keep, each detached through its own
/// backend only ("Detach (opened in <terminal>)").
extension AppModel {
  /// The wording of the terminal `id` names (`ChosenTerminal.id`): iTerm2's for `iterm2` and
  /// `nil`; a plain terminal's from the applied or waiting choice, else the loaded
  /// definitions; "the chosen terminal" for an id neither knows.
  func wording(forTerminalID id: String?) -> TerminalWording {
    guard let id, id != TerminalChoice.iTerm2ID else { return .iTerm2 }
    if let loaded = loadedDefinition(forTerminalID: id) {
      return TerminalWording(definition: loaded.definition)
    }
    return TerminalWording(name: TerminalWording.unknownTerminalName, kind: .other)
  }

  /// The loaded definition of the plain terminal `id` names: the applied or waiting choice's,
  /// else the loaded definitions'; `nil` for an id neither knows.
  func loadedDefinition(forTerminalID id: String) -> LoadedTerminalDefinition? {
    for resolution in [terminalChoice, pendingTerminalChoice] {
      if case .plain(let loaded)? = resolution, loaded.definition.id == id { return loaded }
    }
    return terminalDefinitions?.definition(withID: id)
  }

  /// Where the definition of the terminal `id` names came from, which says whether its script
  /// is muxFinder's own (PLAN.md D38 *The UI (I-12d2)*, review fix): `builtIn` for iTerm2 and
  /// `nil` (no script of anyone else's), the loaded definition's source for a plain terminal,
  /// and `user` for an id nothing knows (its script cannot be known to be muxFinder's).
  func definitionSource(forTerminalID id: String?) -> TerminalDefinitionSource {
    guard let id, id != TerminalChoice.iTerm2ID else { return .builtIn }
    return loadedDefinition(forTerminalID: id)?.source ?? .user
  }

  /// The sessions with a window the chosen plain terminal's backend recorded (confirmed or
  /// brought forward; an app a session was found open in is not one): "Show window" and
  /// "Detach from this Mac" are offered for them. Empty with iTerm2 chosen.
  var windowsHere: Set<SessionKey> {
    Set(
      terminalAttachments.compactMap { key, handle in
        if case .plainWindow = handle { return key }
        return nil
      })
  }

  /// The records other terminals than the chosen one keep, by session (PLAN.md D38 *The UI
  /// (I-12d2)*): iTerm2's attachments muxFinder made or found (`attachedHere`) while iTerm2 is
  /// not chosen, and each plain backend's windows (never an app it found the session in), one
  /// entry per terminal, iTerm2 first, then by terminal id. While the choice is unavailable or
  /// not resolved yet every terminal's records are another terminal's.
  var otherTerminalDetaches: [SessionKey: [OtherTerminalDetach]] {
    let chosen = terminalChoice.chosen?.id
    var entries: [SessionKey: [OtherTerminalDetach]] = [:]
    if chosen != TerminalChoice.iTerm2ID {
      for key in attachedHere.keys {
        entries[key, default: []].append(
          OtherTerminalDetach(terminalID: TerminalChoice.iTerm2ID, wording: .iTerm2))
      }
    }
    for (terminalID, records) in terminalAttachmentsByTerminal.sorted(by: { $0.key < $1.key })
    where terminalID != chosen {
      let wording = wording(forTerminalID: terminalID)
      for (key, handle) in records {
        guard case .plainWindow = handle else { continue }
        entries[key, default: []].append(
          OtherTerminalDetach(terminalID: terminalID, wording: wording))
      }
    } // End of loop over the other terminals' records
    return entries
  } // End of var otherTerminalDetaches

  /// "Detach (opened in <terminal>)": detaches `key`'s attachment kept by the terminal
  /// `terminalID` through that terminal's own cached backend's `detach(session:on:)` (iTerm2's
  /// detaches with `detach-client`, a plain one with D38's bound detach; never by closing a tab
  /// or a window). Offered only for a terminal that is not the chosen one
  /// (`otherTerminalDetaches`), it runs on the record that terminal keeps and its cached backend
  /// whether or not that terminal is the chosen one by now (`keepsRecord(of:terminalID:)`), so
  /// "Try again" repeats it on the same backend after a change of terminal that waited for it
  /// (PLAN.md D38 *The UI (I-12d2)*, review fix). Nothing else of that backend is used, and no
  /// backend is built for it. Its result changes only that terminal's records and is worded for
  /// it. Ignored while an action on the session is pending, without such a record or backend,
  /// for a fixture, and after `shutdown()`.
  public func detach(_ key: SessionKey, openedIn terminalID: String) {
    guard lifecycle != .stopped, runningActions[key] == nil,
      keepsRecord(of: key, terminalID: terminalID),
      let terminalBackend = backends[terminalID], let host = host(withID: key.hostID)
    else { return }
    lastActions[key] = .detachOpenedIn(terminalID)
    activities[key] = .detaching
    notes[key] = nil
    let sink = actionSink
    let task = Task {
      let result = await terminalBackend.detach(session: key, on: host)
      sink.yield(.finished(key, .detached(result)))
    }
    runningActions[key] = RunningAction(
      kind: .detachOpenedIn(terminalID), target: target(for: key), task: task,
      terminalID: terminalID)
    logger.info("Session action started: detach (another terminal)")
  } // End of func detach(_:openedIn:)

  /// Whether the backend of `terminalID` keeps a record of `key` that its own detach ends,
  /// whichever terminal is chosen: iTerm2's attachment muxFinder made or found (`attachedHere`),
  /// or a plain backend's window (never an app it found the session in).
  func keepsRecord(of key: SessionKey, terminalID: String) -> Bool {
    guard terminalID != TerminalChoice.iTerm2ID else { return attachedHere[key] != nil }
    if case .plainWindow? = terminalAttachmentsByTerminal[terminalID]?[key] { return true }
    return false
  }
} // End of extension AppModel
