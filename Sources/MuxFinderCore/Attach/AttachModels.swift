import Foundation

/// What to attach: a session discovery reported, on the host it was discovered on.
public struct AttachTarget: Sendable, Hashable {
  /// The host (`HostConfig.id` is `session.key.hostID`): this Mac, or a remote Mac reached with
  /// ssh from the launch tab (PLAN.md D17).
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
  /// The host's SSH destination is not usable (empty, whitespace or control characters, a
  /// leading `-`); nothing was run or opened.
  case invalidDestination(ValidationError)
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
  /// the confirmation budget (a modal iTerm2 dialog, for example), or the launch tab of a
  /// remote attach closed without a result. The request was withdrawn.
  case timedOut
  /// A remote attach was still waiting (`AttachState.stillWaiting`: ssh asking for a password,
  /// for example) when its wait limit ran out. muxFinder stopped watching; the launch tab is
  /// left to the user, and a later attachment shows up as existing (PLAN.md D17).
  case waitLimitReached
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
  /// iTerm2 runs, but muxFinder could not list its tmux connections to check whether the
  /// session is already attached there; nothing was opened, so no duplicate could appear
  /// (PLAN.md D16).
  case attachmentCheckFailed(ITerm2Error)
  /// The session was attached in this Mac's iTerm2, but by the time muxFinder brought it
  /// forward, every connection that showed it had closed or its short id named another tab's
  /// connection (PLAN.md D16). Nothing was activated and nothing was opened, since the session
  /// may still be attached elsewhere; attaching again checks afresh.
  case attachmentChanged

  /// The failure an attach reports for a failure in the helper's result file (PLAN.md D14).
  public static func from(_ failure: LaunchFailure) -> AttachFailure {
    switch failure {
    case .sessionGone: return .sessionGone
    case .sessionChanged: return .sessionChanged
    case .tmuxMissing: return .tmuxMissing
    default: return .helperFailed(failure)
    }
  }

  /// Whether the failure means discovery's picture of the host is out of date, so the host's
  /// session list must be refreshed before anything else is offered (PLAN.md D18): the session
  /// vanished (`sessionGone`), or its id now names another session or server (`sessionChanged`,
  /// and `identityMismatch`, the same finding through the new connection). The refresh engine
  /// and the UI read this instead of matching cases.
  public var triggersRefresh: Bool {
    switch self {
    case .sessionGone, .sessionChanged, .identityMismatch: return true
    default: return false
    }
  }

  /// A short machine-readable name, such as `sessionChanged`.
  public var kind: String {
    switch self {
    case .invalidDestination: return "invalidDestination"
    case .sessionGone: return "sessionGone"
    case .sessionChanged: return "sessionChanged"
    case .tmuxMissing: return "tmuxMissing"
    case .discoveryFailed: return "discoveryFailed"
    case .launchStore: return "launchStore"
    case .iTerm2: return "iTerm2"
    case .helperFailed: return "helperFailed"
    case .helperEnded: return "helperEnded"
    case .timedOut: return "timedOut"
    case .waitLimitReached: return "waitLimitReached"
    case .identityCheckFailed: return "identityCheckFailed"
    case .identityMismatch: return "identityMismatch"
    case .cancelled: return "cancelled"
    case .attachmentCheckFailed: return "attachmentCheckFailed"
    case .attachmentChanged: return "attachmentChanged"
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
    case .attachmentCheckFailed(let error): return error.kind
    default: return nil
    }
  } // End of var detail

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .invalidDestination(let error):
      return "muxFinder cannot reach this host: \(error.message)"
    case .sessionGone:
      return LaunchFailure.sessionGone.explanation
    case .sessionChanged:
      return LaunchFailure.sessionChanged.explanation
    case .tmuxMissing:
      return "muxFinder could not find tmux on the session's host. Install tmux, or check the "
        + "tmux path in muxFinder's host settings."
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
    case .waitLimitReached:
      return "The session's tab is still waiting, for example for a password, so muxFinder "
        + "stopped watching it. Finish in the tab or close it, then refresh."
    case .identityCheckFailed:
      return "muxFinder could not confirm which tmux session iTerm2 attached."
    case .identityMismatch:
      return LaunchFailure.sessionChanged.explanation
    case .cancelled:
      return "The attach was cancelled."
    case .attachmentCheckFailed(let error):
      return "muxFinder could not check whether this session is already open in iTerm2, so it "
        + "did not open another tab. \(error.errorDescription ?? "iTerm2 did not answer.")"
    case .attachmentChanged:
      return "This session's tab in iTerm2 changed while muxFinder was bringing it forward, so "
        + "muxFinder did not open another one. Try again."
    }
  } // End of var message
}

/// The observable state of one attach (PLAN.md Phase 4, D17).
public enum AttachState: Sendable, Hashable {
  /// The attach was asked for; the session is being revalidated and the launch prepared.
  case requested
  /// iTerm2 opened the launch tab; `sessionID` is the tab's iTerm2 session (the helper runs in
  /// it, and it becomes the tmux connection's owning session).
  case launched(sessionID: String)
  /// A remote attach passed its confirmation budget (20 s) with its launch tab `sessionID`
  /// still open and no connection or helper result: the helper is still running, for example
  /// ssh waiting for a password or a host-key answer in the tab (PLAN.md D17). Never a
  /// success. Published, never returned: the attach keeps watching and still ends `confirmed`
  /// when the connection appears and its identity matches, or `failed`.
  case stillWaiting(sessionID: String)
  /// A tmux connection owned by the launch tab exists and reached the expected session.
  case confirmed(connectionID: String)
  /// The session was already attached in this Mac's iTerm2 (`AttachmentIndex`): the attach
  /// brought that connection's tab forward instead of opening a launch tab (PLAN.md D16).
  case focused(connectionID: String)
  /// The attach ended without a confirmed or focused connection.
  case failed(AttachFailure)

  /// A short machine-readable name: `requested`, `launched`, `stillWaiting`, `confirmed`,
  /// `focused` or `failed`.
  public var kind: String {
    switch self {
    case .requested: return "requested"
    case .launched: return "launched"
    case .stillWaiting: return "stillWaiting"
    case .confirmed: return "confirmed"
    case .focused: return "focused"
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

/// How bringing the attached session forward went (step 9, after `confirmed`, or the focus of
/// an existing attachment).
public enum ActivationOutcome: Sendable, Hashable {
  /// The first tab of the connection was activated.
  case activated(tabID: String)
  /// No tab of the connection appeared within the coordinator's tab budget.
  case noTab
  /// iTerm2 refused or did not answer. `tmuxConnectionNotOwned` means the connection was no
  /// longer owned by the session it was found under (it closed, or its short id was handed to
  /// another tab's connection), so nothing was activated.
  case failed(ITerm2Error)
}

/// How long each step of an attach took, measured from the start of the attach.
public struct AttachTimings: Sendable, Hashable {
  /// Discovery confirmed the session.
  public var revalidated: Duration?
  /// The existing-attachment check (`AttachmentIndex`) answered.
  public var checked: Duration?
  /// iTerm2 opened the launch tab.
  public var launched: Duration?
  /// A remote attach reported `stillWaiting` (its confirmation budget ran out with the helper
  /// still running).
  public var stillWaiting: Duration?
  /// The launch tab's tmux connection appeared.
  public var connected: Duration?
  /// The identity check passed, or the session was found already attached (`focused`).
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
  /// The launch id (request file name and the helper's argument). A focused attach wrote no
  /// request, so nothing ever used its id.
  public var launchID: LaunchToken
  /// `confirmed`, `focused` or `failed`.
  public var state: AttachState
  /// The launch tab's iTerm2 session, once iTerm2 opened it (also on failure, so a caller can
  /// find the tab). For a focused attach, the session that owns the existing connection (the
  /// tab running `tmux -CC`), so `detach(connectionID:gatewaySessionID:launchID:)` applies.
  public var gatewaySessionID: String?
  /// The tmux connection owned by the launch tab, once it appeared, or the existing connection
  /// a focused attach brought forward.
  public var connectionID: String?
  /// How activation went; `nil` unless confirmed or focused.
  public var activation: ActivationOutcome?
  /// What the existing-attachment check found; `nil` when it did not run (turned off, or the
  /// attach ended before it) and empty when iTerm2 was not running.
  public var existingAttachments: AttachmentSnapshot.Counts?
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
    existingAttachments: AttachmentSnapshot.Counts? = nil,
    timings: AttachTimings = AttachTimings()
  ) {
    self.key = key
    self.launchID = launchID
    self.state = state
    self.gatewaySessionID = gatewaySessionID
    self.connectionID = connectionID
    self.activation = activation
    self.existingAttachments = existingAttachments
    self.timings = timings
  } // End of init(key:launchID:state:gatewaySessionID:connectionID:activation:…)

  /// Whether the attach was confirmed (a new launch tab attached the session).
  public var isConfirmed: Bool {
    if case .confirmed = state { return true }
    return false
  }

  /// Whether the attach focused an attachment that already existed in this Mac's iTerm2.
  public var isFocused: Bool {
    if case .focused = state { return true }
    return false
  }

  /// Whether the session is attached in iTerm2 now: confirmed or focused.
  public var isAttached: Bool { isConfirmed || isFocused }

  /// The failure, if the attach failed.
  public var failure: AttachFailure? {
    if case .failed(let failure) = state { return failure }
    return nil
  }

  /// Whether the attach failed in a way that calls for refreshing the host's session list
  /// (`AttachFailure.triggersRefresh`).
  public var triggersRefresh: Bool { failure?.triggersRefresh ?? false }
}

/// The outcome of `AttachCoordinator.createAndAttach(_:)`: the session created, then attached
/// through the usual launch (PLAN.md D18).
public struct CreateAndAttachResult: Sendable, Hashable {
  /// The session as tmux reported it, once created; `nil` when creation failed.
  public var created: CreatedSession?
  /// Why creation failed; then nothing was attached or opened.
  public var creationFailure: SessionCreationError?
  /// How the attach of the created session ended; `nil` when creation failed.
  public var attach: AttachResult?

  /// Creates a result.
  public init(
    created: CreatedSession? = nil,
    creationFailure: SessionCreationError? = nil,
    attach: AttachResult? = nil
  ) {
    self.created = created
    self.creationFailure = creationFailure
    self.attach = attach
  }

  /// Whether the new session is attached in iTerm2 now (its attach was confirmed).
  public var isAttached: Bool { attach?.isAttached ?? false }

  /// Whether the host's session list should be refreshed: a session was created (or may have
  /// been), a collision showed a session muxFinder did not list, or the attach failed in a
  /// refresh-triggering way.
  public var triggersRefresh: Bool {
    created != nil || creationFailure?.triggersRefresh == true || attach?.triggersRefresh == true
  }
}

/// The outcome of `AttachCoordinator.detach(connectionID:gatewaySessionID:launchID:)`, and of
/// each attachment `AttachCoordinator.detach(session:on:)` found.
public struct DetachResult: Sendable, Equatable {
  /// The connection that was detached.
  public var connectionID: String
  /// The session owning the connection (the tab running `tmux -CC`) the command was bound to;
  /// `nil` when the caller did not give one (never the case for the coordinator's detaches).
  public var gatewaySessionID: String?
  /// Whether the caller was cancelled while the coordinator waited for the launch tab to be old
  /// enough; nothing was sent then.
  public var cancelled: Bool
  /// `detach(session:on:)` only: the identity check run right before `detach-client` showed
  /// that the connection no longer reached the session (another server or session, or a
  /// different host), or answered through a tmux client not in UTF-8 mode in a way that can no
  /// longer be matched exactly (`ConnectionIdentity.Answer.nonUTF8`), so nothing was sent.
  public var identityChanged: Bool
  /// `detach(session:on:)` only: why that identity check got no usable answer (`nil` when it
  /// answered); nothing was sent then.
  public var identityCheckFailure: AttachmentSnapshot.StaleReason?
  /// The error of the `detach-client` request, or `nil` when iTerm2 answered it (or it was not
  /// attempted). `tmuxConnectionNotOwned` means iTerm2 did not list the connection as owned by
  /// `gatewaySessionID`, so nothing was sent.
  public var commandError: ITerm2Error?
  /// Whether the connection disappeared from iTerm2's connections within the budget.
  public var connectionClosed: Bool
  /// A failure of the connection listing while waiting, if any.
  public var pollError: ITerm2Error?
  /// The helper's result after tmux exited, when the launch is known and it arrived in time.
  public var helperResult: LaunchResult?

  /// Creates a result.
  public init(
    connectionID: String,
    gatewaySessionID: String? = nil,
    cancelled: Bool = false,
    identityChanged: Bool = false,
    identityCheckFailure: AttachmentSnapshot.StaleReason? = nil,
    commandError: ITerm2Error? = nil,
    connectionClosed: Bool = false,
    pollError: ITerm2Error? = nil,
    helperResult: LaunchResult? = nil
  ) {
    self.connectionID = connectionID
    self.gatewaySessionID = gatewaySessionID
    self.cancelled = cancelled
    self.identityChanged = identityChanged
    self.identityCheckFailure = identityCheckFailure
    self.commandError = commandError
    self.connectionClosed = connectionClosed
    self.pollError = pollError
    self.helperResult = helperResult
  } // End of init(connectionID:gatewaySessionID:cancelled:identityChanged:…)

  /// A clean detach: the connection closed and the helper reported that tmux exited 0.
  public var isClean: Bool {
    connectionClosed && helperResult?.succeeded == true
  }

  /// Whether `detach-client` certainly never reached tmux: cancelled during the wait, refused
  /// by the identity check, or a request failure that guarantees it was not sent.
  public var certainlyNotSent: Bool {
    cancelled || identityChanged || identityCheckFailure != nil
      || commandError?.isNotSent == true
  }
}

/// The outcome of `AttachCoordinator.detach(session:on:)`: every attachment of one session (on
/// this Mac or a remote host) in this Mac's iTerm2, detached (PLAN.md D16, D17).
public struct SessionDetachResult: Sendable, Equatable {
  /// How the detach ended, overall.
  public enum Outcome: String, Sendable, Hashable, CaseIterable {
    /// No attachment of the session was found (iTerm2 not running, no server, or no connection
    /// that maps to the session). Nothing was sent.
    case nothingAttached
    /// Every attachment found was detached: its connection closed.
    case detached
    /// At least one attachment was not detached because `detach-client` was certainly not sent
    /// (the connection was no longer owned by the same session, no longer reached the session,
    /// or a request failed before it was sent). The others may have been detached.
    case notSent
    /// `detach-client` was sent (or its outcome is unknown) for an attachment whose connection
    /// did not close within the budget.
    case notClosed
    /// The caller was cancelled before every attachment was detached; commands not yet sent
    /// were not sent.
    case cancelled
    /// The attachments could not be listed (discovery or iTerm2 failed; see `checkFailure`).
    /// Nothing was sent.
    case checkFailed
  }

  /// The session.
  public var key: SessionKey
  /// How it ended.
  public var outcome: Outcome
  /// One result per attachment found, in the order they were handled.
  public var detaches: [DetachResult]
  /// Why the attachments could not be listed, for `checkFailed`.
  public var checkFailure: AttachFailure?
  /// What the index found; `nil` when it did not run.
  public var counts: AttachmentSnapshot.Counts?

  /// Creates a result.
  public init(
    key: SessionKey,
    outcome: Outcome,
    detaches: [DetachResult] = [],
    checkFailure: AttachFailure? = nil,
    counts: AttachmentSnapshot.Counts? = nil
  ) {
    self.key = key
    self.outcome = outcome
    self.detaches = detaches
    self.checkFailure = checkFailure
    self.counts = counts
  } // End of init(key:outcome:detaches:checkFailure:counts:)
}

/// The identity check run through a tmux connection (PLAN.md Phase 4, step 7, and D16's
/// attachment index), and the detach command. Both are static strings: no runtime value is ever
/// inserted into a tmux command.
public enum ConnectionIdentity {
  /// `display-message` printing, separated by `:`, whether the connection's tmux client is in
  /// UTF-8 mode (`#{client_utf8}`), the server's host name and socket path each after its length
  /// in bytes (`#{n:…}`), the server's pid and start time, and the session id:
  /// `<utf8>:<length>:<host>:<pid>:<start time>:<length>:<socket path>:<session id>`.
  ///
  /// Only printable ASCII frames the fields, so the line keeps its shape through a client that
  /// is not in UTF-8 mode (started without `-u` under a non-UTF-8 locale; iTerm2 attaches such a
  /// client when a user types `tmux -CC` in a tab): tmux 3.8 replaces every tab, other control
  /// character and non-ASCII character in such a client's output with one `_` and leaves
  /// printable ASCII alone (PLAN.md *Verified facts*, Phase 5a). The lengths make the parse
  /// unambiguous whatever the host name and path contain. `#{host}` is the server's
  /// `gethostname()`, the same text as `uname -n` on that host (verified with tmux 3.8 on this
  /// Mac).
  public static let command =
    ##"display-message -p "#{client_utf8}:#{n:host}:#{host}:#{pid}:#{start_time}:"##
    + ##"#{n:socket_path}:#{socket_path}:#{session_id}""##

  /// Detaches the connection's own client, which ends `tmux -CC` cleanly.
  public static let detachCommand = "detach-client"

  /// What `read(_:)` made of `command`'s output.
  public enum Answer: Sendable, Hashable {
    /// The exact host, server and session the connection shows.
    case reported(Reported)
    /// The connection's tmux client is not in UTF-8 mode, and its answer may have lost bytes:
    /// the host name or socket path holds `_` (where tmux may have replaced a character), `:`
    /// (a shortened field may have swallowed a separator) or a byte tmux never sends such a
    /// client, or the line lost its shape. Never matched to a session.
    case nonUTF8
    /// Not an answer in `command`'s format.
    case unreadable
  }

  /// What tmux reported through the connection.
  public struct Reported: Sendable, Hashable {
    /// `#{host}`: the host name of the machine the tmux server runs on.
    public var host: String
    /// `#{pid}`.
    public var pid: Int32
    /// `#{start_time}`.
    public var startTime: Int64
    /// `#{socket_path}`.
    public var socketPath: String
    /// `#{session_id}`.
    public var sessionID: TmuxSessionID

    /// Creates a report.
    public init(
      host: String,
      pid: Int32,
      startTime: Int64,
      socketPath: String,
      sessionID: TmuxSessionID
    ) {
      self.host = host
      self.pid = pid
      self.startTime = startTime
      self.socketPath = socketPath
      self.sessionID = sessionID
    } // End of init(host:pid:startTime:socketPath:sessionID:)

    /// The server identity the report names.
    public var server: ServerIdentity {
      ServerIdentity(socketPath: socketPath, pid: pid, startTime: startTime)
    }

    /// Whether this is the server and session `key` names (the host name is not part of a
    /// key; `AttachmentIndex` matches it against discovery's `uname -n`).
    public func matches(_ key: SessionKey) -> Bool {
      server == key.server && sessionID == key.sessionID
    }
  } // End of struct Reported

  /// Reads `command`'s output on bytes, so `\r\n` and combining characters cannot hide a
  /// separator: one line (a trailing line break is allowed), the UTF-8 flag `0` or `1`, then
  /// the host name (non-empty, valid UTF-8, no control characters) and the socket path (valid
  /// UTF-8, starting with `/`) each exactly as many bytes as its length says, the pid (positive)
  /// and start time as canonical decimal numbers, and the session id last, every field ended by
  /// `:`. A client in UTF-8 mode sends the exact bytes, so a well-formed line is `reported`.
  /// For a client that is not, a well-formed line is `reported` only when the host name and
  /// socket path are printable ASCII without `_` or `:`. tmux puts one `_` per column in place
  /// of what such a client cannot get, so a zero-width character vanishes and a shortened
  /// field could swallow a separator; without `:` each field ends at a real separator and has
  /// its original length, and without `_` nothing in it was replaced. Every other answer from
  /// such a client is `nonUTF8`, so a value that may have been changed never matches.
  public static func read(_ output: String) -> Answer {
    var bytes = Array(output.utf8)[...]
    while let last = bytes.last, last == newline || last == carriageReturn { bytes.removeLast() }
    guard !bytes.contains(newline), !bytes.contains(carriageReturn), bytes.count >= 2,
      bytes[bytes.startIndex + 1] == colon
    else { return .unreadable }
    let utf8Client: Bool
    switch bytes.first {
    case UInt8(ascii: "1"): utf8Client = true
    case UInt8(ascii: "0"): utf8Client = false
    default: return .unreadable
    }
    let fields = Self.fields(bytes.dropFirst(2))
    guard utf8Client else {
      // Printable ASCII without `_` or `:`: each field then ends at a real separator, and its
      // length equals the original byte length, so tmux replaced and dropped nothing.
      guard let fields,
        (fields.host + fields.socketPath).allSatisfy({
          $0 >= 0x20 && $0 < 0x7F && $0 != underscore && $0 != colon
        })
      else { return .nonUTF8 }
      return fields.reported.map(Answer.reported) ?? .unreadable
    }
    return fields?.reported.map(Answer.reported) ?? .unreadable
  } // End of func read(_:)

  /// `read(_:)`'s report, or `nil` for any other answer.
  public static func parse(_ output: String) -> Reported? {
    guard case .reported(let reported) = read(output) else { return nil }
    return reported
  }

  /// The fields after the UTF-8 flag, as bytes, with the report they make when every field is
  /// valid (`nil` otherwise).
  private struct Fields {
    /// The host name's bytes.
    let host: [UInt8]
    /// The socket path's bytes.
    let socketPath: [UInt8]
    /// The report, when the host name, socket path and session id are valid.
    let reported: Reported?
  }

  /// Splits `bytes` into the length-prefixed host name, the pid, the start time, the
  /// length-prefixed socket path and the session id, each but the last ended by `:`. `nil` when
  /// the line does not have that shape.
  private static func fields(_ bytes: ArraySlice<UInt8>) -> Fields? {
    var rest = bytes
    guard let hostLength = number(&rest, as: Int.self),
      let host = counted(&rest, hostLength),
      let pid = number(&rest, as: Int32.self),
      let startTime = number(&rest, as: Int64.self),
      let socketLength = number(&rest, as: Int.self),
      let socketPath = counted(&rest, socketLength)
    else { return nil }
    let sessionID = TmuxSessionID(String(decoding: rest, as: UTF8.self))
    var reported: Reported?
    if pid > 0, let sessionID, !host.isEmpty, host.allSatisfy({ $0 >= 0x20 && $0 != 0x7F }),
      let hostName = String(bytes: host, encoding: .utf8),
      socketPath.first == UInt8(ascii: "/"), let path = String(bytes: socketPath, encoding: .utf8)
    {
      reported = Reported(
        host: hostName, pid: pid, startTime: startTime, socketPath: path, sessionID: sessionID)
    }
    return Fields(host: Array(host), socketPath: Array(socketPath), reported: reported)
  } // End of func fields(_:)

  /// Takes a canonical decimal number and the `:` after it from the front of `rest`.
  private static func number<Value: FixedWidthInteger>(
    _ rest: inout ArraySlice<UInt8>,
    as type: Value.Type
  ) -> Value? {
    guard let end = rest.firstIndex(of: colon),
      let value = canonicalInteger(String(decoding: rest[..<end], as: UTF8.self), as: type)
    else { return nil }
    rest = rest[(end + 1)...]
    return value
  }

  /// Takes exactly `count` bytes and the `:` after them from the front of `rest`.
  private static func counted(_ rest: inout ArraySlice<UInt8>, _ count: Int) -> ArraySlice<UInt8>? {
    guard rest.count > count, rest[rest.startIndex + count] == colon else { return nil }
    let taken = rest.prefix(count)
    rest = rest.dropFirst(count + 1)
    return taken
  }

  /// `:`, the field separator.
  private static let colon = UInt8(ascii: ":")
  /// `_`, what tmux puts in place of a character a client not in UTF-8 mode cannot get.
  private static let underscore = UInt8(ascii: "_")
  /// `\n`.
  private static let newline = UInt8(ascii: "\n")
  /// `\r`.
  private static let carriageReturn = UInt8(ascii: "\r")

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
