import Foundation
import MuxFinderCore

/// What "Test connection" found: the classified status with the popover's wording (PLAN.md
/// D22's host statuses), the popover's one-line explanation for a failure, and a short detail
/// for a success. No session name, destination or command output is shown.
public struct ConnectionTestResult: Sendable, Hashable {
  /// The status label, exactly as the popover shows it.
  public var status: HostStatusLabel
  /// The popover's explanation of a failure.
  public var explanation: String?
  /// For a host that answered: "2 sessions · tmux 3.8", "No tmux server is running · …".
  public var detail: String?

  /// Creates a result from its parts.
  public init(status: HostStatusLabel, explanation: String? = nil, detail: String? = nil) {
    self.status = status
    self.explanation = explanation
    self.detail = detail
  }

  /// The result of a discovery of a host in `mode`. A host that answered reads "This Mac"
  /// (local), "Reachable" (SSH, sessions) or "No sessions" (SSH, none or no server), as in the
  /// popover; a failure reads its popover label with its explanation.
  public init(_ result: DiscoveryResult, mode: HostConfig.ConnectionMode) {
    let version = result.report?.tmuxVersion
    switch result.status {
    case .ok(let sessions):
      if mode == .local {
        status = .thisMac
      } else {
        status = sessions.isEmpty ? .noSessions : .reachable
      }
      explanation = nil
      let count = sessions.count == 1 ? "1 session" : "\(sessions.count) sessions"
      let parts = [status == .noSessions ? nil : count, version].compactMap { $0 }
      detail = parts.isEmpty ? nil : parts.joined(separator: " · ")
    case .noServer:
      status = mode == .local ? .thisMac : .noSessions
      explanation = nil
      detail = ["No tmux server is running", version].compactMap { $0 }.joined(separator: " · ")
    default:
      status = HostStatusLabel(failure: result.status)
      explanation = HostProblemText.explanation(for: result.status)
      detail = nil
    }
  } // End of init(_:mode:)
}

/// "Test connection": not run, running, or its result.
public enum ConnectionTestState: Sendable, Hashable {
  /// Not run for the current fields.
  case idle
  /// Running.
  case running
  /// Finished with this result.
  case finished(ConnectionTestResult)
}

/// "Detect" next to the tmux path: not run, running, or what it found.
public enum DetectionState: Sendable, Hashable {
  /// Not run for the current fields.
  case idle
  /// Running.
  case running
  /// tmux was found at `path` (now in the field), reporting `version`.
  case found(path: String, version: String?)
  /// The host answered, but no tmux was found in the usual places.
  case notFound
  /// The host could not be checked: the popover's label and explanation.
  case failed(status: HostStatusLabel, explanation: String?)

  /// The state for a discovery run without the tmux path.
  public init(_ result: DiscoveryResult) {
    if let path = result.report?.tmuxPath {
      self = .found(path: path, version: result.report?.tmuxVersion)
      return
    }
    switch result.status {
    case .tmuxNotFound, .ok, .noServer:
      self = .notFound
    default:
      self = .failed(
        status: HostStatusLabel(failure: result.status),
        explanation: HostProblemText.explanation(for: result.status))
    }
  } // End of init(_:)

  /// The line shown under the field, if any.
  public var message: String? {
    switch self {
    case .idle:
      return nil
    case .running:
      return "Looking for tmux…"
    case .found(let path, let version):
      return "Found \(version ?? "tmux") at \(path)."
    case .notFound:
      return "tmux wasn't found in the usual places on this host. Install it, or enter its "
        + "full path."
    case .failed(let status, let explanation):
      return [status.text + ".", explanation].compactMap { $0 }.joined(separator: " ")
    }
  } // End of var message

  /// Whether the line reports a problem.
  public var isProblem: Bool {
    switch self {
    case .notFound, .failed: return true
    case .idle, .running, .found: return false
    }
  }
}

/// The iTerm2 profile picker's choices.
public enum ProfileChoices: Sendable, Hashable {
  /// Not asked yet.
  case notLoaded
  /// Asking iTerm2.
  case loading
  /// iTerm2's profiles: the picker offers them.
  case available([String])
  /// iTerm2 is not running: the field is free text.
  case iTermNotRunning
  /// Listing failed: the field is free text; the error may have a fix-it.
  case failed(ITerm2Error?)

  /// The choices for a listing result.
  public init(_ result: ProfileListResult) {
    switch result {
    case .available(let names): self = .available(names)
    case .iTermNotRunning: self = .iTermNotRunning
    case .failed(let error): self = .failed(error)
    case .cancelled: self = .notLoaded
    }
  }

  /// Whether the picker is shown (otherwise a free-text field).
  public var offersPicker: Bool {
    if case .available = self { return true }
    return false
  }

  /// The note under the profile field, if any.
  public var note: String? {
    switch self {
    case .notLoaded, .available:
      return nil
    case .loading:
      return "Asking iTerm2 for its profiles…"
    case .iTermNotRunning:
      return "iTerm2 isn't running, so muxFinder can't list its profiles. Type a profile name, "
        + "or leave it empty for iTerm2's default profile."
    case .failed(let error):
      let reason = error?.errorDescription.map { " " + $0 } ?? ""
      return "muxFinder couldn't list iTerm2's profiles.\(reason) Type a profile name, or leave "
        + "it empty for iTerm2's default profile."
    }
  } // End of var note

  /// The fix-it for the listing's error, if any.
  public var fixIt: FixIt? {
    if case .failed(let error) = self { return FixIt(error: error) }
    return nil
  }
}
