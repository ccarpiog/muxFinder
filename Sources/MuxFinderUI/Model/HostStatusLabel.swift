import Foundation
import MuxFinderCore

/// The status shown at the end of a host's header (PLAN.md Phase 8): one of a fixed set of
/// short labels, mapped from the host's refresh snapshot.
public enum HostStatusLabel: String, Sendable, Hashable, CaseIterable {
  /// No attempt has finished yet.
  case checking
  /// An SSH host answered and has sessions.
  case reachable
  /// The local host answered (with or without sessions).
  case thisMac
  /// An SSH host answered: no tmux server, or a server without sessions.
  case noSessions
  /// The host could not be reached (timeout, name not found, refused, no route).
  case unreachable
  /// SSH needs the user to sign in.
  case signInNeeded
  /// SSH refused the host key (unknown or changed).
  case hostKeyProblem
  /// No usable tmux was found on the host.
  case tmuxNotFound
  /// Discovery failed for another reason; the problem line says why.
  case checkFailed

  /// How a status reads at a glance; the text always says it too, so color is never the only
  /// signal. No host status is red: red is kept for failed session actions (PLAN.md D22).
  public enum Tone: Sendable, Hashable, CaseIterable {
    /// The host answered (a green dot).
    case good
    /// Nothing to report yet, or nothing running (a gray dot).
    case neutral
    /// The user can fix it: sign in, host key, tmux path, a failed check (an orange dot, and
    /// the orange triangle on the problem line).
    case attention
    /// The host is out of reach, which is routine (a Mac asleep or away): a hollow gray dot,
    /// the section dimmed, a neutral icon on the problem line.
    case muted
  }

  /// The label for `snapshot`: "Checking…" before any attempt finished, then the last
  /// attempt's outcome. A refresh in progress keeps the last outcome's label (the header shows
  /// a spinner beside it), so a failing host does not flicker every 15 seconds.
  public init(_ snapshot: HostSnapshot) {
    switch snapshot.lastOutcome {
    case nil:
      self = .checking
    case .sessionsListed:
      if snapshot.host.isThisMac {
        self = .thisMac
      } else {
        self = snapshot.sessions.isEmpty ? .noSessions : .reachable
      }
    case .noServer:
      self = snapshot.host.isThisMac ? .thisMac : .noSessions
    case .failed(let status):
      self = Self(failure: status)
    }
  } // End of init(_:)

  /// The label of a failed attempt's classified status.
  init(failure status: HostStatus) {
    switch status {
    case .ok: self = .reachable
    case .noServer: self = .noSessions
    case .unreachable: self = .unreachable
    case .authFailed: self = .signInNeeded
    case .hostKeyProblem: self = .hostKeyProblem
    case .tmuxNotFound: self = .tmuxNotFound
    case .probeError: self = .checkFailed
    }
  } // End of init(failure:)

  /// The text shown, exactly as PLAN.md Phase 8 lists it.
  public var text: String {
    switch self {
    case .checking: return "Checking…"
    case .reachable: return "Reachable"
    case .thisMac: return "This Mac"
    case .noSessions: return "No sessions"
    case .unreachable: return "Unreachable"
    case .signInNeeded: return "Sign-in needed"
    case .hostKeyProblem: return "Host key problem"
    case .tmuxNotFound: return "tmux not found"
    case .checkFailed: return "Check failed"
    }
  } // End of var text

  /// How the status reads at a glance.
  public var tone: Tone {
    switch self {
    case .reachable, .thisMac: return .good
    case .checking, .noSessions: return .neutral
    case .signInNeeded, .hostKeyProblem, .tmuxNotFound, .checkFailed: return .attention
    case .unreachable: return .muted
    }
  }
}

/// The one-line explanation of a failed discovery, shown under the host's header with "Retry".
/// English, sentence case, and free of host names, paths and command output.
public enum HostProblemText {
  /// The explanation for `status`, or `nil` for the successes (`ok`, `noServer`).
  public static func explanation(for status: HostStatus) -> String? {
    switch status {
    case .ok, .noServer:
      return nil
    case .unreachable(let reason):
      switch reason {
      case .timeout: return "The connection timed out."
      case .dnsFailure: return "The host name could not be found."
      case .refused: return "The host refused the SSH connection."
      case .noRoute: return "There is no network route to the host."
      }
    case .authFailed:
      return "SSH could not sign in without asking. Set up SSH for this host in iTerm2 first."
    case .hostKeyProblem(.unknown):
      return "SSH does not know this host's key yet. Connect once in iTerm2 to check it."
    case .hostKeyProblem(.changed):
      return "This host's SSH key changed. Check it before connecting; muxFinder never skips "
        + "the check."
    case .tmuxNotFound:
      return "tmux was not found on this host. Install it, or set its path in Settings."
    case .probeError(let message):
      return message
    }
  } // End of func explanation(for:)
}
