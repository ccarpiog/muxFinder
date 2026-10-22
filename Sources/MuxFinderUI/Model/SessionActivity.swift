import Foundation
import MuxFinderCore

/// What a session row shows while muxFinder works on it (PLAN.md Phase 8: per-session
/// progress and errors). Phase 8 renders it from model state only; Phase 10's attach state
/// machine sets it from the attach coordinator's `AttachState` updates (`init?(_:)`).
public enum SessionActivity: Sendable, Hashable {
  /// The attach was asked for: revalidating and preparing the launch.
  case opening
  /// iTerm2 opened the launch tab; the tmux connection is not confirmed yet.
  case waitingForITerm2
  /// A remote launch tab is still waiting, for example for a password (PLAN.md D17
  /// `stillWaiting`).
  case waitingForYou
  /// The last attempt failed; `message` explains why, and the row offers "Retry".
  case failed(message: String)

  /// The activity an attach state shows: `nil` once the attach is confirmed or focused (the
  /// row goes back to its normal look).
  public init?(_ state: AttachState) {
    switch state {
    case .requested: self = .opening
    case .launched: self = .waitingForITerm2
    case .stillWaiting: self = .waitingForYou
    case .confirmed, .focused: return nil
    case .failed(let failure): self = .failed(message: failure.message)
    }
  }

  /// The text the row shows.
  public var text: String {
    switch self {
    case .opening: return "Opening…"
    case .waitingForITerm2: return "Waiting for iTerm2…"
    case .waitingForYou: return "Waiting for you in iTerm2"
    case .failed(let message): return message
    }
  }

  /// Whether work is in progress (a spinner), as opposed to a failure (an error and "Retry").
  public var isInProgress: Bool {
    if case .failed = self { return false }
    return true
  }
}
