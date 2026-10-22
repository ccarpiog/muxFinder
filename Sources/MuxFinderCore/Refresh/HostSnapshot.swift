import Foundation

/// What the refresh engine knows about one enabled host (PLAN.md D20): its sessions, whether
/// they are live, and when the host was last asked and last answered.
///
/// A snapshot is `live` only while the host's last attempt succeeded. After a failure it is
/// `stale`: the sessions of the last success stay in `sessions` (none if there never was one)
/// so the UI can show them as "last seen", never as live. Identity is per host: two hosts
/// reporting the same session name are two snapshots with two different `SessionKey`s.
public struct HostSnapshot: Sendable, Hashable, Identifiable {
  /// Whether the sessions are current.
  public enum Freshness: String, Sendable, Hashable, Codable, CaseIterable {
    /// No attempt has been applied yet ("Checking…").
    case notChecked
    /// The last attempt succeeded; `sessions` is what the host reported then.
    case live
    /// The last attempt failed; `sessions` is what the last success reported (possibly
    /// nothing), never to be shown as live.
    case stale
  }

  /// How the last applied attempt ended.
  public enum Outcome: Sendable, Hashable {
    /// tmux answered; its sessions (possibly none) are in `sessions`.
    case sessionsListed
    /// tmux is installed but its default server is not running, so there are no sessions.
    case noServer
    /// The attempt failed; the classified status (never `ok` or `noServer`).
    case failed(HostStatus)

    /// A short machine-readable name: `ok`, `noServer` or the failure's `HostStatus.kind`.
    public var kind: String {
      switch self {
      case .sessionsListed: return "ok"
      case .noServer: return "noServer"
      case .failed(let status): return status.kind
      }
    }
  } // End of enum Outcome

  /// One discovered session with the iTerm2 tmux connections on this Mac that show it.
  public struct Session: Sendable, Hashable, Identifiable {
    /// The session as discovery reported it.
    public var discovered: DiscoveredSession
    /// The iTerm2 tmux connections on this Mac attached to the session, from the last
    /// attachment check (PLAN.md D16). Empty when none is, and also when the check failed or
    /// never ran: `RefreshState.attachmentCheck` says which.
    public var attachments: [AttachmentSnapshot.Attachment]

    /// Creates a session entry.
    public init(discovered: DiscoveredSession, attachments: [AttachmentSnapshot.Attachment] = []) {
      self.discovered = discovered
      self.attachments = attachments
    }

    /// The session's identity, which includes its host.
    public var key: SessionKey { discovered.key }

    /// `Identifiable` conformance: the session key.
    public var id: SessionKey { discovered.key }

    /// Whether at least one iTerm2 tmux connection on this Mac shows the session.
    public var isOpenInITerm2Here: Bool { !attachments.isEmpty }
  } // End of struct Session

  /// The host's configuration as of `configRevision`.
  public var host: HostConfig
  /// The configuration revision this snapshot belongs to: results of attempts started under
  /// another revision are never applied to it.
  public var configRevision: Int
  /// Whether the sessions are current.
  public var freshness: Freshness
  /// The sessions: live ones, or (stale) the last success's.
  public var sessions: [Session]
  /// How the last applied attempt ended; `nil` before the first one.
  public var lastOutcome: Outcome?
  /// When the last applied attempt finished (wall clock).
  public var lastAttempt: Date?
  /// When the last successful attempt finished (wall clock).
  public var lastSuccess: Date?
  /// Failed attempts since the last success (or since the first attempt). Sets the background
  /// backoff step.
  public var consecutiveFailures: Int
  /// The host's `uname -n` from the last success; what the attachment index matches.
  public var nodeName: String?
  /// Whether an attempt for the host is running or waiting for a free slot.
  public var isRefreshing: Bool
  /// When the next scheduled attempt is due, on the coordinator's monotonic clock; `nil` when
  /// none is scheduled (an attempt is in flight, the system sleeps, or the engine is not
  /// started or stopped).
  public var nextRefreshAt: ContinuousClock.Instant?

  /// A snapshot of `host` before any attempt.
  public init(host: HostConfig, configRevision: Int) {
    self.host = host
    self.configRevision = configRevision
    freshness = .notChecked
    sessions = []
    lastOutcome = nil
    lastAttempt = nil
    lastSuccess = nil
    consecutiveFailures = 0
    nodeName = nil
    isRefreshing = false
    nextRefreshAt = nil
  } // End of init(host:configRevision:)

  /// `Identifiable` conformance: the host id.
  public var id: UUID { host.id }

  /// Whether the sessions are live.
  public var isLive: Bool { freshness == .live }

  /// The classified failure of the last attempt, or `nil` when it succeeded or none ran.
  public var lastError: HostStatus? {
    if case .failed(let status) = lastOutcome { return status }
    return nil
  }

  /// Records a finished attempt that ended at `date`. `ok` and `noServer` are successes: the
  /// snapshot turns live with the reported sessions and the failure count resets. Anything
  /// else is a failure: the sessions of the last success are kept and the snapshot turns
  /// stale. Session attachments come from `index` (none when `nil`).
  mutating func record(_ result: DiscoveryResult, at date: Date, index: AttachmentSnapshot?) {
    lastAttempt = date
    switch result.status {
    case .ok(let discovered):
      succeed(
        with: discovered, outcome: .sessionsListed, at: date, nodeName: result.report?.nodeName)
    case .noServer:
      succeed(with: [], outcome: .noServer, at: date, nodeName: result.report?.nodeName)
    default:
      freshness = .stale
      lastOutcome = .failed(result.status)
      consecutiveFailures += 1
    }
    mergeAttachments(index)
  } // End of func record(_:at:index:)

  /// The success half of `record(_:at:index:)`.
  private mutating func succeed(
    with discovered: [DiscoveredSession],
    outcome: Outcome,
    at date: Date,
    nodeName reported: String?
  ) {
    freshness = .live
    lastOutcome = outcome
    lastSuccess = date
    consecutiveFailures = 0
    sessions = discovered.map { Session(discovered: $0) }
    if let reported { nodeName = reported }
  } // End of func succeed(with:outcome:at:nodeName:)

  /// Sets every session's attachments to the connections `index` mapped to its key, or to none
  /// when there is no index result (never checked, iTerm2 not running, or the check failed).
  mutating func mergeAttachments(_ index: AttachmentSnapshot?) {
    for position in sessions.indices {
      sessions[position].attachments = index?.attachments(of: sessions[position].key) ?? []
    }
  }

  /// This host as the attachment index matches it: the node name and the servers of the
  /// sessions it last reported. `nil` before the first success.
  var indexHost: AttachmentIndex.Host? {
    guard let nodeName else { return nil }
    return AttachmentIndex.Host(
      hostID: host.id, nodeName: nodeName, servers: Set(sessions.map(\.key.server)))
  }
}

/// The last attachment check of the refresh engine (PLAN.md D16, D20).
public enum AttachmentCheck: Sendable, Hashable {
  /// No check has run: no index is configured, or none has finished yet.
  case notChecked
  /// The check worked; `counts` says how many connections mapped and how many stayed unmapped.
  case checked(at: Date, counts: AttachmentSnapshot.Counts)
  /// iTerm2 was not running, so nothing is open in it on this Mac.
  case iTermNotRunning(at: Date)
  /// Listing iTerm2's tmux connections failed (`nil`: an error that was not an iTerm2 one).
  /// Which sessions are open in iTerm2 is unknown: no session carries an attachment, and the
  /// UI must not read that as "not open here".
  case failed(at: Date, error: ITerm2Error?)

  /// A short machine-readable name: `notChecked`, `checked`, `iTermNotRunning` or `failed`.
  public var kind: String {
    switch self {
    case .notChecked: return "notChecked"
    case .checked: return "checked"
    case .iTermNotRunning: return "iTermNotRunning"
    case .failed: return "failed"
    }
  }
} // End of enum AttachmentCheck

/// Everything the refresh engine publishes: one snapshot per enabled host, in host-list order,
/// and the last attachment check.
public struct RefreshState: Sendable, Hashable {
  /// The enabled hosts' snapshots, in host-list order.
  public var hosts: [HostSnapshot]
  /// The last attachment check.
  public var attachmentCheck: AttachmentCheck
  /// The configuration revision of the host list the engine runs with.
  public var configRevision: Int
  /// Whether the popover is open (refreshes every 15 s and attachment checks).
  public var isPopoverVisible: Bool
  /// Whether the system is asleep (no scheduled refresh runs).
  public var isAsleep: Bool

  /// Creates a state.
  public init(
    hosts: [HostSnapshot],
    attachmentCheck: AttachmentCheck,
    configRevision: Int,
    isPopoverVisible: Bool,
    isAsleep: Bool
  ) {
    self.hosts = hosts
    self.attachmentCheck = attachmentCheck
    self.configRevision = configRevision
    self.isPopoverVisible = isPopoverVisible
    self.isAsleep = isAsleep
  } // End of init(hosts:attachmentCheck:configRevision:isPopoverVisible:isAsleep:)

  /// Every host's sessions, host by host. The same name on two hosts is two entries.
  public var sessions: [HostSnapshot.Session] { hosts.flatMap(\.sessions) }

  /// The snapshot of the host `hostID`, if it is enabled.
  public func snapshot(of hostID: UUID) -> HostSnapshot? {
    hosts.first { $0.host.id == hostID }
  }
}

/// The attachment index as the refresh engine uses it. `AttachmentIndex` is the production
/// implementation; tests pass a fake, so `swift test` never contacts iTerm2.
public protocol AttachmentIndexing: Sendable {
  /// See `AttachmentIndex.snapshot(of:)`. Throws the listing's `ITerm2Error` (`notRunning`
  /// when iTerm2 does not run) or `CancellationError`. Once the calling task is cancelled (the
  /// popover closed), it must not start any further iTerm2 contact.
  func snapshot(of hosts: [AttachmentIndex.Host]) async throws -> AttachmentSnapshot
}

extension AttachmentIndex: AttachmentIndexing {}
