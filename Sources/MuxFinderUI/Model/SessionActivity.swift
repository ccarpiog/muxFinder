import Foundation
import MuxFinderCore

/// What a session row shows while muxFinder works on it, or how its last action ended (PLAN.md
/// D22, D25). `AppModel`'s attach state machine sets it from the backends' `AttachState`
/// updates (`init(_:movingHere:wording:)`) and from each action's result. iTerm2's cases are
/// as before other terminals; the plain backend's carry the wording of their terminal (PLAN.md
/// D38 *The UI (I-12d2)*).
public enum SessionActivity: Sendable, Hashable {
  /// An attach was asked for: revalidating and preparing the launch.
  case opening
  /// A move here was confirmed and asked for.
  case movingHere
  /// iTerm2 opened the launch tab; the tmux connection is not confirmed yet.
  case waitingForITerm2
  /// A remote launch tab is still waiting, for example for a password (PLAN.md D17
  /// `stillWaiting`); the row offers "Show tab" for the launch tab `launchTabID`.
  case stillConnecting(launchTabID: String)
  /// The core confirmed the attachment (a launch tab's tmux connection reached the session).
  case confirmed
  /// The session was open in this Mac's iTerm2 already; its tab was brought forward.
  case focused
  /// "Detach from this Mac" runs.
  case detaching
  /// "Detach from this Mac" detached every attachment here; the session keeps running.
  case detached
  /// "Detach other clients…" runs (PLAN.md D37; it may wait about 20 s for young tabs and
  /// clients).
  case detachingOtherClients
  /// "Detach other clients…" detached `count` other clients (at least one); `alreadyLeft` had
  /// left before their check.
  case detachedOtherClients(count: Int, alreadyLeft: Int)
  /// "Detach other clients…" found every other client gone: nothing to detach (informational,
  /// not a failure).
  case noOtherClientsLeft
  /// The last action failed; the problem says why and what the row offers.
  case failed(SessionProblem)
  /// Plain backend (PLAN.md D38 *The UI (I-12d2)*), `waitingForITerm2`'s counterpart: the
  /// terminal app (`wording`) opened the window; its tmux client is not confirmed yet.
  case waitingForTerminal(TerminalWording)
  /// Plain backend, `stillConnecting`'s counterpart: a remote window is still waiting (ssh
  /// asking for a password in it, D17); the row offers "Show window" for `window`.
  case stillConnectingInWindow(PlainTerminalWindow, TerminalWording)
  /// Plain backend, `confirmed`'s counterpart: the new window's tmux client was confirmed.
  case confirmedInTerminal(TerminalWording)
  /// Plain backend, `focused`'s counterpart: the backend's own window of the session was
  /// brought forward.
  case focusedWindow(TerminalWording)
  /// Open on this Mac (PLAN.md D38, Phase I-12c2): the session was open in the app `wording`
  /// names (a client traced to it), and that app was brought forward.
  case focusedApp(TerminalWording)

  /// The activity an attach state shows (`movingHere` for a move here's request). `wording` is
  /// the terminal the action runs in: the plain backend's states show its name and place
  /// (`appFocused` names the app it found, as far as `wording` knows it); iTerm2's states are
  /// as before whatever it says.
  public init(_ state: AttachState, movingHere: Bool = false, wording: TerminalWording = .iTerm2) {
    switch state {
    case .requested: self = movingHere ? .movingHere : .opening
    case .launched: self = .waitingForITerm2
    case .stillWaiting(let sessionID): self = .stillConnecting(launchTabID: sessionID)
    case .confirmed: self = .confirmed
    case .focused: self = .focused
    case .failed(let failure): self = .failed(.attach(failure, wording: wording))
    case .plainLaunched(let window):
      self = .waitingForTerminal(TerminalWording(definition: window.openedBy.definition))
    case .plainStillWaiting(let window):
      self = .stillConnectingInWindow(
        window, TerminalWording(definition: window.openedBy.definition))
    case .plainConfirmed: self = .confirmedInTerminal(wording)
    case .plainFocused: self = .focusedWindow(wording)
    case .appFocused(let app):
      self = .focusedApp(app.isITerm2 ? .iTerm2 : wording)
    }
  } // End of init(_:movingHere:wording:)

  /// The text the row shows.
  public var text: String {
    switch self {
    case .opening: return "Opening…"
    case .movingHere: return "Moving here…"
    case .waitingForITerm2: return TerminalWording.iTerm2.waitingText
    case .stillConnecting: return TerminalWording.iTerm2.stillConnectingText
    case .confirmed: return TerminalWording.iTerm2.confirmedText
    case .focused: return TerminalWording.iTerm2.focusedText
    case .waitingForTerminal(let wording): return wording.waitingText
    case .stillConnectingInWindow(_, let wording): return wording.stillConnectingText
    case .confirmedInTerminal(let wording): return wording.confirmedText
    case .focusedWindow(let wording): return wording.focusedText
    case .focusedApp(let wording): return wording.focusedAppText
    case .detaching: return "Detaching from this Mac…"
    case .detached: return "Detached from this Mac — the session keeps running"
    case .detachingOtherClients: return "Detaching other clients…"
    case .detachedOtherClients(let count, let alreadyLeft):
      let clients = count == 1 ? "1 other client" : "\(count) other clients"
      let left = alreadyLeft > 0 ? " (\(alreadyLeft) had already left)" : ""
      return "Detached \(clients) — the session keeps running" + left
    case .noOtherClientsLeft: return "No other clients to detach — they had already left"
    case .failed(let problem): return problem.message
    }
  } // End of var text

  /// Whether work is in progress (a spinner).
  public var isInProgress: Bool {
    switch self {
    case .opening, .movingHere, .waitingForITerm2, .stillConnecting, .detaching,
      .detachingOtherClients, .waitingForTerminal, .stillConnectingInWindow:
      return true
    case .confirmed, .focused, .detached, .detachedOtherClients, .noOtherClientsLeft, .failed,
      .confirmedInTerminal, .focusedWindow, .focusedApp:
      return false
    }
  }

  /// Whether the last action succeeded (a check mark; for "No other clients to detach", an
  /// information mark); these are cleared when the popover opens again.
  public var isDone: Bool {
    switch self {
    case .confirmed, .focused, .detached, .detachedOtherClients, .noOtherClientsLeft,
      .confirmedInTerminal, .focusedWindow, .focusedApp:
      return true
    default: return false
    }
  }

  /// Whether an Open, a Move here or a New session's attach ended attached: confirmed, or an
  /// existing attachment (a tab, a window, an app) brought forward. The session switcher closes
  /// on it (PLAN.md D32).
  public var isAttached: Bool {
    switch self {
    case .confirmed, .focused, .confirmedInTerminal, .focusedWindow, .focusedApp: return true
    default: return false
    }
  }

  /// The problem, for a failure.
  public var problem: SessionProblem? {
    if case .failed(let problem) = self { return problem }
    return nil
  }

  /// The plain window "Show window" brings forward (PLAN.md D38 *The UI (I-12d2)*): a
  /// still-connecting attach's, or a failure's.
  public var launchWindow: PlainTerminalWindow? {
    switch self {
    case .stillConnectingInWindow(let window, _):
      return window
    case .failed(let problem):
      for recovery in problem.recoveries {
        if case .showWindow(let window) = recovery { return window }
      }
      return nil
    default:
      return nil
    }
  } // End of var launchWindow

  /// The launch tab "Show tab" brings forward: a still-connecting attach's, or a failure's.
  public var launchTabID: String? {
    switch self {
    case .stillConnecting(let id):
      return id
    case .failed(let problem):
      for recovery in problem.recoveries {
        if case .showTab(let id) = recovery { return id }
      }
      return nil
    default:
      return nil
    }
  } // End of var launchTabID
}
