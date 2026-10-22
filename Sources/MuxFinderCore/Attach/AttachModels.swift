import Foundation

/// What to attach: a session discovery reported, on the host it was discovered on.
public struct AttachTarget: Sendable, Hashable {
  /// The host (`HostConfig.id` is `session.key.hostID`). Only `.local` hosts until Phase 5.
  public var host: HostConfig
  /// The session as discovery last reported it; its key and `createdAt` are revalidated.
  public var session: DiscoveredSession

  /// Creates a target.
  public init(host: HostConfig, session: DiscoveredSession) {
    self.host = host
    self.session = session
  }

  /// The session's identity, which single-flight coalescing is keyed by.
  public var key: SessionKey { session.key }
}

/// Why an attach failed. `message` is English, sentence case, without user data.
public enum AttachFailure: Error, Sendable, Hashable {
  /// The host is not a local host; SSH attaches arrive in Phase 5.
  case unsupportedHost
  /// The session no longer exists or no tmux server runs (revalidation, or guard exit 64).
  case sessionGone
  /// The session id now belongs to another server or session (revalidation, or guard exit 65).
  case sessionChanged
  /// No usable tmux was found (discovery's `tmuxNotFound`, or guard exit 66).
  case tmuxMissing
  /// Revalidation could not list the host's sessions; the `HostStatus.kind`.
  case discoveryFailed(String)
  /// The launch request could not be written (or the result could not be read).
  case launchStore(LaunchStoreError)
  /// iTerm2 refused or did not answer a request needed for the attach.
  case iTerm2(ITerm2Error)
  /// The helper reported a failure that has no case of its own above (D14).
  case helperFailed(LaunchFailure)
  /// The helper reported that tmux ended normally before muxFinder saw its connection.
  case helperEnded
  /// No tmux connection for the launch tab appeared, and the helper reported nothing, within
  /// the confirmation budget (a modal iTerm2 dialog, for example). The request was withdrawn.
  case timedOut
  /// The identity check through the new connection failed: iTerm2's error, or `nil` when tmux's
  /// answer could not be read (the connection was then detached, once its launch tab was old
  /// enough).
  case identityCheckFailed(ITerm2Error?)
  /// The connection reached a different server or session than discovery reported (a server
  /// restart between the guard and tmux attaching, PLAN.md D4). It was detached, once its
  /// launch tab was old enough.
  case identityMismatch
  /// Every caller waiting for the attach was cancelled.
  case cancelled

  /// The failure an attach reports for a failure in the helper's result file (PLAN.md D14).
  public static func from(_ failure: LaunchFailure) -> AttachFailure {
    switch failure {
    case .sessionGone: return .sessionGone
    case .sessionChanged: return .sessionChanged
    case .tmuxMissing: return .tmuxMissing
    default: return .helperFailed(failure)
    }
  }

  /// A short machine-readable name, such as `sessionChanged`.
  public var kind: String {
    switch self {
    case .unsupportedHost: return "unsupportedHost"
    case .sessionGone: return "sessionGone"
    case .sessionChanged: return "sessionChanged"
    case .tmuxMissing: return "tmuxMissing"
    case .discoveryFailed: return "discoveryFailed"
    case .launchStore: return "launchStore"
    case .iTerm2: return "iTerm2"
    case .helperFailed: return "helperFailed"
    case .helperEnded: return "helperEnded"
    case .timedOut: return "timedOut"
    case .identityCheckFailed: return "identityCheckFailed"
    case .identityMismatch: return "identityMismatch"
    case .cancelled: return "cancelled"
    }
  } // End of var kind

  /// A detail for diagnostics and the probe's JSON: the nested error's kind, if any.
  public var detail: String? {
    switch self {
    case .discoveryFailed(let status): return status
    case .launchStore(let error): return error.description
    case .iTerm2(let error): return error.kind
    case .helperFailed(let failure): return failure.kind
    case .identityCheckFailed(let error): return error?.kind
    default: return nil
    }
  }

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .unsupportedHost:
      return "muxFinder can only attach sessions on this Mac so far."
    case .sessionGone:
      return LaunchFailure.sessionGone.explanation
    case .sessionChanged:
      return LaunchFailure.sessionChanged.explanation
    case .tmuxMissing:
      return LaunchFailure.tmuxMissing.explanation
    case .discoveryFailed:
      return "muxFinder could not check the session before attaching it. Refresh and try again."
    case .launchStore:
      return "muxFinder could not prepare the launch of this session. Try again."
    case .iTerm2(let error):
      return error.errorDescription ?? "iTerm2 did not open the session."
    case .helperFailed(let failure):
      return failure.explanation
    case .helperEnded:
      return "tmux ended before muxFinder could confirm the attachment."
    case .timedOut:
      return "iTerm2 did not start the tmux session in time. If iTerm2 shows a message, "
        + "answer it and try again."
    case .identityCheckFailed:
      return "muxFinder could not confirm which tmux session iTerm2 attached."
    case .identityMismatch:
      return LaunchFailure.sessionChanged.explanation
    case .cancelled:
      return "The attach was cancelled."
    }
  } // End of var message
}

/// The observable state of one attach (PLAN.md Phase 4).
public enum AttachState: Sendable, Hashable {
  /// The attach was asked for; the session is being revalidated and the launch prepared.
  case requested
  /// iTerm2 opened the launch tab; `sessionID` is the tab's iTerm2 session (the helper runs in
  /// it, and it becomes the tmux connection's owning session).
  case launched(sessionID: String)
  /// A tmux connection owned by the launch tab exists and reached the expected session.
  case confirmed(connectionID: String)
  /// The attach ended without a confirmed connection.
  case failed(AttachFailure)

  /// A short machine-readable name: `requested`, `launched`, `confirmed` or `failed`.
  public var kind: String {
    switch self {
    case .requested: return "requested"
    case .launched: return "launched"
    case .confirmed: return "confirmed"
    case .failed: return "failed"
    }
  }
}

/// One state change, as delivered to the coordinator's update handler.
public struct AttachUpdate: Sendable, Hashable {
  /// The session being attached.
  public var key: SessionKey
  /// The launch the state belongs to.
  public var launchID: LaunchToken
  /// The new state.
  public var state: AttachState
  /// Whether the launch is still the session's latest one. A launch whose callers were all
  /// cancelled can still be winding down (its `CreateTab` pending) after a newer launch for the
  /// same session started; its later updates are `false`, do not change
  /// `AttachCoordinator.state(of:)`, and matter only to observers of that launch (its launch
  /// tab, for example), not to observers of the session's state.
  public var isCurrent: Bool

  /// Creates an update.
  public init(key: SessionKey, launchID: LaunchToken, state: AttachState, isCurrent: Bool = true) {
    self.key = key
    self.launchID = launchID
    self.state = state
    self.isCurrent = isCurrent
  }
}

/// How bringing the attached session forward went (step 9, after `confirmed`).
public enum ActivationOutcome: Sendable, Hashable {
  /// The first tab of the connection was activated.
  case activated(tabID: String)
  /// No tab of the connection appeared within the coordinator's tab budget.
  case noTab
  /// iTerm2 refused or did not answer.
  case failed(ITerm2Error)
}

/// How long each step of an attach took, measured from the start of the attach.
public struct AttachTimings: Sendable, Hashable {
  /// Discovery confirmed the session.
  public var revalidated: Duration?
  /// iTerm2 opened the launch tab.
  public var launched: Duration?
  /// The launch tab's tmux connection appeared.
  public var connected: Duration?
  /// The identity check passed.
  public var confirmed: Duration?
  /// The connection's first tab was activated (or the attempt ended).
  public var activated: Duration?
  /// The attach ended.
  public var finished: Duration?

  /// Creates empty timings.
  public init() {}
}

/// The outcome of `AttachCoordinator.attach(_:)`. Callers that were coalesced into one launch
/// get the same result.
public struct AttachResult: Sendable, Hashable {
  /// The session.
  public var key: SessionKey
  /// The launch id (request file name and the helper's argument).
  public var launchID: LaunchToken
  /// `confirmed` or `failed`.
  public var state: AttachState
  /// The launch tab's iTerm2 session, once iTerm2 opened it (also on failure, so a caller can
  /// find the tab).
  public var gatewaySessionID: String?
  /// The tmux connection owned by the launch tab, once it appeared.
  public var connectionID: String?
  /// How activation went; `nil` unless confirmed.
  public var activation: ActivationOutcome?
  /// Step timings.
  public var timings: AttachTimings

  /// Creates a result.
  public init(
    key: SessionKey,
    launchID: LaunchToken,
    state: AttachState,
    gatewaySessionID: String? = nil,
    connectionID: String? = nil,
    activation: ActivationOutcome? = nil,
    timings: AttachTimings = AttachTimings()
  ) {
    self.key = key
    self.launchID = launchID
    self.state = state
    self.gatewaySessionID = gatewaySessionID
    self.connectionID = connectionID
    self.activation = activation
    self.timings = timings
  } // End of init(key:launchID:state:gatewaySessionID:connectionID:activation:timings:)

  /// Whether the attach was confirmed.
  public var isConfirmed: Bool {
    if case .confirmed = state { return true }
    return false
  }

  /// The failure, if the attach failed.
  public var failure: AttachFailure? {
    if case .failed(let failure) = state { return failure }
    return nil
  }
}

/// The outcome of `AttachCoordinator.detach(connectionID:gatewaySessionID:launchID:)`.
public struct DetachResult: Sendable, Equatable {
  /// The connection that was detached.
  public var connectionID: String
  /// Whether the caller was cancelled while the coordinator waited for the launch tab to be old
  /// enough; nothing was sent then.
  public var cancelled: Bool
  /// The error of the `detach-client` request, or `nil` when iTerm2 answered it.
  /// `tmuxConnectionNotOwned` means iTerm2 did not list the connection as the launch tab's, so
  /// nothing was sent.
  public var commandError: ITerm2Error?
  /// Whether the connection disappeared from iTerm2's connections within the budget.
  public var connectionClosed: Bool
  /// A failure of the connection listing while waiting, if any.
  public var pollError: ITerm2Error?
  /// The helper's result after tmux exited, when a launch id was given and it arrived in time.
  public var helperResult: LaunchResult?

  /// Creates a result.
  public init(
    connectionID: String,
    cancelled: Bool = false,
    commandError: ITerm2Error? = nil,
    connectionClosed: Bool = false,
    pollError: ITerm2Error? = nil,
    helperResult: LaunchResult? = nil
  ) {
    self.connectionID = connectionID
    self.cancelled = cancelled
    self.commandError = commandError
    self.connectionClosed = connectionClosed
    self.pollError = pollError
    self.helperResult = helperResult
  } // End of init(connectionID:cancelled:commandError:connectionClosed:pollError:helperResult:)

  /// A clean detach: the connection closed and the helper reported that tmux exited 0.
  public var isClean: Bool {
    connectionClosed && helperResult?.succeeded == true
  }
}

/// The identity check run through a new tmux connection (PLAN.md Phase 4, step 7), and the
/// detach command. Both are static strings: no runtime value is ever inserted into a tmux
/// command.
public enum ConnectionIdentity {
  /// `display-message` printing the server pid, server start time, socket path and session id,
  /// separated by tabs. tmux turns `\t` inside double quotes into a tab (verified with tmux 3.8
  /// in control mode); the client runs with `-u`, so tabs survive (D12).
  public static let command =
    ##"display-message -p "#{pid}\t#{start_time}\t#{socket_path}\t#{session_id}""##

  /// Detaches the connection's own client, which ends `tmux -CC` cleanly.
  public static let detachCommand = "detach-client"

  /// What tmux reported through the connection.
  public struct Reported: Sendable, Hashable {
    /// `#{pid}`.
    public var pid: Int32
    /// `#{start_time}`.
    public var startTime: Int64
    /// `#{socket_path}`.
    public var socketPath: String
    /// `#{session_id}`.
    public var sessionID: TmuxSessionID

    /// Creates a report.
    public init(pid: Int32, startTime: Int64, socketPath: String, sessionID: TmuxSessionID) {
      self.pid = pid
      self.startTime = startTime
      self.socketPath = socketPath
      self.sessionID = sessionID
    }

    /// Whether this is the server and session `key` names.
    public func matches(_ key: SessionKey) -> Bool {
      pid == key.server.pid && startTime == key.server.startTime
        && socketPath == key.server.socketPath && sessionID == key.sessionID
    }
  } // End of struct Reported

  /// Parses `command`'s output: one line (a trailing line break is allowed), the pid and start
  /// time as canonical decimal numbers, the session id last, and the socket path everything in
  /// between (a path may contain a tab). Works on bytes, so `\r\n` and combining characters
  /// cannot hide a separator. Returns `nil` for anything else.
  public static func parse(_ output: String) -> Reported? {
    var bytes = Array(output.utf8)
    while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
    guard !bytes.contains(0x0A), !bytes.contains(0x0D) else { return nil }
    let fields = bytes.split(separator: 0x09, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    guard fields.count >= 4, let pid = canonicalInteger(fields[0], as: Int32.self), pid > 0,
      let startTime = canonicalInteger(fields[1], as: Int64.self),
      let sessionID = TmuxSessionID(fields[fields.count - 1])
    else { return nil }
    let socketPath = fields[2..<(fields.count - 1)].joined(separator: "\t")
    guard socketPath.hasPrefix("/") else { return nil }
    return Reported(pid: pid, startTime: startTime, socketPath: socketPath, sessionID: sessionID)
  } // End of func parse(_:)

  /// A non-negative decimal number without sign, spaces or leading zeros (other than `0`).
  static func canonicalInteger<Value: FixedWidthInteger>(
    _ text: String,
    as type: Value.Type
  ) -> Value? {
    guard !text.isEmpty, text.utf8.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }),
      text == "0" || text.first != "0"
    else { return nil }
    return Value(text)
  }
}
