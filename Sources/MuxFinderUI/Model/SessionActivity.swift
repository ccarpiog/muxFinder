import Foundation
import MuxFinderCore

/// What a session row shows while muxFinder works on it, or how its last action ended (PLAN.md
/// D22, D25). `AppModel`'s attach state machine sets it from the attach coordinator's
/// `AttachState` updates (`init?(_:movingHere:)`) and from each action's result.
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
  /// The last action failed; the problem says why and what the row offers.
  case failed(SessionProblem)

  /// The activity an attach state shows (`movingHere` for a move here's request).
  public init(_ state: AttachState, movingHere: Bool = false) {
    switch state {
    case .requested: self = movingHere ? .movingHere : .opening
    case .launched: self = .waitingForITerm2
    case .stillWaiting(let sessionID): self = .stillConnecting(launchTabID: sessionID)
    case .confirmed: self = .confirmed
    case .focused: self = .focused
    case .failed(let failure): self = .failed(.attach(failure))
    }
  }

  /// The text the row shows.
  public var text: String {
    switch self {
    case .opening: return "Opening…"
    case .movingHere: return "Moving here…"
    case .waitingForITerm2: return "Waiting for iTerm2…"
    case .stillConnecting: return "Still connecting — check the iTerm2 tab"
    case .confirmed: return "Confirmed — open in iTerm2 on this Mac"
    case .focused: return "Already open here — brought its tab forward"
    case .detaching: return "Detaching from this Mac…"
    case .detached: return "Detached from this Mac — the session keeps running"
    case .failed(let problem): return problem.message
    }
  } // End of var text

  /// Whether work is in progress (a spinner).
  public var isInProgress: Bool {
    switch self {
    case .opening, .movingHere, .waitingForITerm2, .stillConnecting, .detaching: return true
    case .confirmed, .focused, .detached, .failed: return false
    }
  }

  /// Whether the last action succeeded (a check mark); these are cleared when the popover opens
  /// again.
  public var isDone: Bool {
    switch self {
    case .confirmed, .focused, .detached: return true
    default: return false
    }
  }

  /// The problem, for a failure.
  public var problem: SessionProblem? {
    if case .failed(let problem) = self { return problem }
    return nil
  }

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
