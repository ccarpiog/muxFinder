import Foundation

/// What discovery found out about one host: its sessions, or why they can't be listed.
public enum HostStatus: Sendable, Hashable {
  /// Why a host could not be reached.
  public enum UnreachableReason: String, Sendable, Hashable, Codable, CaseIterable {
    /// The connection or the whole probe ran out of time.
    case timeout
    /// The host name could not be resolved.
    case dnsFailure
    /// The host refused the SSH connection.
    case refused
    /// There is no network route to the host.
    case noRoute
  }

  /// Which host-key problem SSH reported.
  public enum HostKeyProblem: String, Sendable, Hashable, Codable, CaseIterable {
    /// The host key is not known yet (or could not be verified for another reason).
    case unknown
    /// The host key differs from the one recorded in `known_hosts`.
    case changed
  }

  /// tmux is running; these are its sessions (possibly none).
  case ok([DiscoveredSession])
  /// tmux is installed but its default server is not running.
  case noServer
  /// No usable tmux executable was found on the host.
  case tmuxNotFound
  /// The host could not be reached.
  case unreachable(UnreachableReason)
  /// SSH authentication failed or needs interaction.
  case authFailed
  /// SSH refused the host key.
  case hostKeyProblem(HostKeyProblem)
  /// Anything else; the message is English, sentence case, and safe to show.
  case probeError(String)

  /// The discovered sessions, or an empty list for every status other than `ok`.
  public var sessions: [DiscoveredSession] {
    if case .ok(let sessions) = self { return sessions }
    return []
  }

  /// A short machine-readable name for the case, such as `ok` or `hostKeyProblem`. Used in
  /// diagnostics and the probe CLI's JSON.
  public var kind: String {
    switch self {
    case .ok: return "ok"
    case .noServer: return "noServer"
    case .tmuxNotFound: return "tmuxNotFound"
    case .unreachable: return "unreachable"
    case .authFailed: return "authFailed"
    case .hostKeyProblem: return "hostKeyProblem"
    case .probeError: return "probeError"
    }
  } // End of var kind
}
