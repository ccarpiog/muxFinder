import Foundation
import MuxFinderCore

/// The session strings of the popover, the switcher and the session states, per terminal
/// (PLAN.md D38 *The UI (I-12d2)*; requirement 9): `TerminalWording` stays the one wording
/// source, this file adds what the rows, their menus, their activities and their failures say.
/// With iTerm2's wording every string is byte for byte what it was before other terminals
/// (requirement 12; `TerminalSessionWordingTests` holds the old literals).
extension TerminalWording {
  /// The wording of the terminal app a client of a session on This Mac runs in (process
  /// ancestry, PLAN.md D38 *Open on this Mac*): iTerm2's for iTerm2, else the first of its
  /// definitions `catalog` has (its display name and kind), else a neutral name.
  public init(app: LocalTerminalApp, catalog: TerminalDefinitionCatalog?) {
    if app.isITerm2 {
      self = .iTerm2
      return
    }
    for id in app.definitionIDs {
      if let loaded = catalog?.definition(withID: id) {
        self.init(definition: loaded.definition)
        return
      }
    }
    self.init(name: Self.otherAppName, kind: .other)
  } // End of init(app:catalog:)

  /// The name of an app a session is open in when no loaded definition names it.
  public static let otherAppName = "another terminal"

  /// What a client of this terminal on This Mac is called: "iTerm2", "Terminal window".
  var hereNoun: String { isITerm2 ? name : "\(name) window" }

  /// What a client on another Mac may be: "iTerm2" for iTerm2's wording, else "terminals".
  var otherMacsNoun: String { isITerm2 ? name : "terminals" }

  // MARK: - Row actions

  /// "Open in iTerm2", "Open in Terminal": the context menu's first item.
  public var openTitle: String { "Open in \(name)" }

  /// The row's VoiceOver hint: "Opens the session in iTerm2."
  public var openHint: String { "Opens the session in \(name)." }

  /// "Show tab" (iTerm2's launch tab) or "Show window" (a plain terminal's window).
  public var showTitle: String { "Show \(place)" }

  /// "Detach from this Mac"'s help.
  public var detachHelp: String {
    "Detaches this Mac's \(hereNoun) from the session. The session keeps running."
  }

  /// "Detach other clients…"'s help.
  public var detachOtherClientsHelp: String {
    guard !isITerm2 else {
      return "Detaches the session's other clients, such as iTerm2 on your other Macs, and keeps "
        + "this Mac's. The session keeps running."
    }
    return "Detaches the session's other clients, such as terminals on your other Macs, and "
      + "keeps this Mac's \(name) window. The session keeps running."
  }

  /// The footer's Quit help.
  public var quitHelp: String {
    "Quit muxFinder. Your tmux sessions and \(name) \(place)s keep running."
  }

  // MARK: - Activities

  /// "Waiting for iTerm2…": the launch opened, its attachment not confirmed yet.
  public var waitingText: String { "Waiting for \(name)…" }

  /// "Still connecting — check the iTerm2 tab", "… the Terminal window".
  public var stillConnectingText: String { "Still connecting — check the \(name) \(place)" }

  /// "Confirmed — open in iTerm2 on this Mac".
  public var confirmedText: String { "Confirmed — open in \(name) on this Mac" }

  /// "Already open here — brought its tab forward", "… brought its Terminal window forward".
  public var focusedText: String {
    isITerm2
      ? "Already open here — brought its tab forward"
      : "Already open here — brought its \(name) window forward"
  }

  /// New session's line while it creates and opens the session.
  public var creatingText: String { "Creating the session and opening it in \(name)…" }

  // MARK: - A session open in an app on this Mac

  /// "Open in Terminal on this Mac": a client of the session runs in this app here.
  public var openOnThisMacText: String { "Open in \(name) on this Mac" }

  /// "Show in Terminal": brings that app forward (no Apple event, nothing launched).
  public var showInTitle: String { "Show in \(name)" }

  /// The row after an Open found the session open in this app and brought it forward.
  public var focusedAppText: String { "Already open in \(name) on this Mac — brought it forward" }

  /// The problem when an Open found the session open in this app but macOS did not bring it
  /// forward (`notRunning`: the app quit meanwhile).
  public func appNotBroughtForward(running: Bool) -> String {
    running
      ? "This session is open in \(name) on this Mac, but macOS didn't bring \(name) forward. "
        + "Switch to \(name) to find it, or try again."
      : "This session was open in \(name) on this Mac, but \(name) isn't running any more, so "
        + "nothing was brought forward. Refresh, then open it again."
  }

  // MARK: - Another terminal's record

  /// "Detach (opened in iTerm2)": a session muxFinder opened in this terminal before another
  /// was chosen.
  public var detachOpenedInTitle: String { "Detach (opened in \(name))" }

  /// That item's help.
  public var detachOpenedInHelp: String {
    "Detaches the \(name) attachment muxFinder opened before you chose another terminal. The "
      + "session keeps running."
  }

  // MARK: - Panels

  /// The Move here confirmation's explanation for a session of `hostName`.
  public func moveHereExplanation(hostName: String) -> String {
    "muxFinder will open this session from \(hostName) in \(name) on this Mac and disconnect "
      + "every other client attached to it, including \(otherMacsNoun) on your other Macs. "
      + "Nothing is closed: the session keeps running, and the other Macs can attach again later."
  }

  /// The Detach other clients confirmation's explanation for a session of `hostName`.
  public func detachOtherClientsExplanation(hostName: String) -> String {
    let kept = isITerm2 ? "attachment" : "\(name) window"
    return "muxFinder will have tmux detach every other client of this session on \(hostName) "
      + "and keep this Mac's \(kept). They may be \(otherMacsNoun) on your other Macs. Nothing "
      + "is closed: the session keeps running, and they can attach again later."
  }

  /// ", including 2 in this Mac's iTerm2" in the Detach other clients confirmation.
  public func otherClientsHereText(_ count: Int) -> String {
    ", including \(count) in this Mac's \(name)"
  }

  // MARK: - Host problems

  /// A sign-in needed: where to set up SSH.
  public var signInProblem: String {
    "SSH could not sign in without asking. Set up SSH for this host in \(name) first."
  }

  /// An unknown host key: where to connect once.
  public var hostKeyUnknownProblem: String {
    "SSH does not know this host's key yet. Connect once in \(name) to check it."
  }

  // MARK: - The unavailable choice (requirement 8)

  /// The chosen terminal is not installed.
  public var unavailableNotInstalled: String {
    "The chosen terminal, \(name), isn't installed. Install it, or choose another terminal in "
      + "Settings."
  }

  /// The chosen terminal is older than `minimum`.
  public func unavailableTooOld(minimum: String) -> String {
    "The chosen terminal, \(name), is older than \(minimum). Update it, or choose another "
      + "terminal in Settings."
  }

  /// The chosen terminal's version cannot be read; it needs `minimum`.
  public func unavailableVersionUnknown(minimum: String) -> String {
    "muxFinder can't read which version of the chosen terminal, \(name), is installed, and it "
      + "needs \(minimum) or later. Update it, or choose another terminal in Settings."
  }
} // End of extension TerminalWording
