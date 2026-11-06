import Foundation

/// The explicit confirmation `AttachCoordinator.detachOtherClients(of:confirmation:)` requires
/// (PLAN.md D37): the user agreed that tmux detaches every other client of this one session,
/// on this Mac or any other, while this Mac's attachment of it stays. It has one case and no
/// default, so a call always spells it out, and it names the session, so a confirmation given
/// for one session can never detach another session's clients
/// (`DetachOtherClientsResult.Outcome.notConfirmed`, nothing run). It is a type of its own,
/// separate from `MoveHereConfirmation`, so a move here's confirmation can never be used here
/// or the other way round.
public enum DetachOtherClientsConfirmation: Sendable, Hashable {
  /// Detach every other client of the session `key`, keeping this Mac's attachment.
  case detachOtherClients(of: SessionKey)

  /// The session this confirmation is for.
  public var key: SessionKey {
    switch self {
    case .detachOtherClients(let key): return key
    }
  }
}

/// Why `AttachCoordinator.detachOtherClients(of:confirmation:)` ended `checkFailed`: what could
/// not be checked or sent, with the problem.
public enum DetachOtherClientsProblem: Sendable, Hashable {
  /// The session's attachments could not be looked up: the host's SSH destination is not
  /// valid, discovery failed or found no tmux, or iTerm2's tmux connections could not be listed
  /// (the `AttachFailure` `detach(session:on:)` reports the same way). Nothing was sent.
  case attachmentCheck(AttachFailure)
  /// The identity check through the kept connection, right before sending, got no usable
  /// answer. Nothing was sent.
  case identityCheck(AttachmentSnapshot.StaleReason)
  /// A read-only request through the kept connection failed (its own client's name with
  /// tmux's clock, the session's clients, or one client's check right before its detach):
  /// iTerm2's error, or `nil` when its answer could not be read (or named a client that cannot
  /// be detached safely). No detach was sent from then on.
  case clientListing(ITerm2Error?)
  /// A `detach-client` failed with iTerm2's error. When the error `isNotSent`, it never reached
  /// tmux; otherwise tmux may have run it. `tmuxCommandFailed` is D37's residual: tmux did not
  /// confirm it, typically because the client checked right before had ended in between (`can't
  /// find client`), and iTerm2 3.7 then also ends the kept connection with its alert. Not
  /// counted as detached; no detach was sent after it.
  case send(ITerm2Error)

  /// A short machine-readable name: `attachmentCheck`, `identityCheck`, `clientListing` or
  /// `send`.
  public var kind: String {
    switch self {
    case .attachmentCheck: return "attachmentCheck"
    case .identityCheck: return "identityCheck"
    case .clientListing: return "clientListing"
    case .send: return "send"
    }
  }

  /// A detail for diagnostics and the probe's output: the nested failure's or error's kind.
  public var detail: String? {
    switch self {
    case .attachmentCheck(let failure): return failure.kind
    case .identityCheck(let reason): return reason.kind
    case .clientListing(let error): return error?.kind ?? "unreadable"
    case .send(let error): return error.kind
    }
  }
} // End of enum DetachOtherClientsProblem

/// The outcome of `AttachCoordinator.detachOtherClients(of:confirmation:)` (PLAN.md D37). None
/// of the outcomes triggers a refresh by itself; the caller refreshes the session's row.
public struct DetachOtherClientsResult: Sendable, Hashable {
  /// How the call ended.
  public enum Outcome: Sendable, Hashable {
    /// Through the kept connection, tmux detached `count` other clients of the session (each
    /// at least `minimumLaunchTabAge` old, checked right before, each `detach-client` sent once
    /// and confirmed by tmux); every other client listed was detached or had left before its
    /// check.
    case detached(count: Int)
    /// The session's only client is the kept connection's, or every other client listed had
    /// left before its check: nothing was detached.
    case nothingToDetach
    /// No connection in this Mac's iTerm2 shows the session (iTerm2 not running, no tmux
    /// server, or no connection mapped to it). Nothing was sent.
    case notAttachedHere
    /// Right before the listing, the kept connection no longer showed the session (another
    /// server or session, an answer through a tmux client not in UTF-8 mode, or its own client
    /// missing from the session's clients), or every attachment's connection had closed or
    /// changed owner. Nothing was detached.
    case identityChanged
    /// Something could not be checked or sent; see the problem. The detaches tmux confirmed
    /// before it are counted in `detachedClients`; nothing more was sent after it.
    case checkFailed(DetachOtherClientsProblem)
    /// The confirmation names another session. Nothing ran: no discovery and no iTerm2
    /// request.
    case notConfirmed
    /// The caller was cancelled; nothing more was sent from then on (the detaches tmux
    /// confirmed before are counted in `detachedClients`).
    case cancelled

    /// A short machine-readable name, such as `detached`.
    public var kind: String {
      switch self {
      case .detached: return "detached"
      case .nothingToDetach: return "nothingToDetach"
      case .notAttachedHere: return "notAttachedHere"
      case .identityChanged: return "identityChanged"
      case .checkFailed: return "checkFailed"
      case .notConfirmed: return "notConfirmed"
      case .cancelled: return "cancelled"
      }
    }
  } // End of enum Outcome

  /// The session.
  public var key: SessionKey
  /// How it ended.
  public var outcome: Outcome
  /// The attachment kept (the one "Show tab" focuses: `attach(_:)`'s choice), through whose
  /// connection the listing, the checks and the detaches went; `nil` before one was chosen.
  public var kept: AttachmentSnapshot.Attachment?
  /// How many other attachments of the session the index found in this Mac's iTerm2 besides
  /// the kept one. They are among the other clients, never kept.
  public var otherAttachmentsHere: Int
  /// How many other clients the session's listing showed (the session's clients less the kept
  /// connection's own).
  public var listedOthers: Int
  /// How many of them had left by their check (nothing was sent for them).
  public var goneBeforeDetach: Int
  /// How many `detach-client` commands tmux confirmed (answered with their output; one
  /// answered without it is `checkFailed(.send(.tmuxCommandFailed))`, never counted).
  public var detachedClients: Int
  /// How long the call waited, after the listing, for every other client to be
  /// `minimumLaunchTabAge` old by tmux's clock before the first check (zero when each one was;
  /// PLAN.md D37).
  public var ageWait: Duration
  /// What the index found; `nil` when it did not run.
  public var counts: AttachmentSnapshot.Counts?

  /// Creates a result.
  public init(
    key: SessionKey,
    outcome: Outcome,
    kept: AttachmentSnapshot.Attachment? = nil,
    otherAttachmentsHere: Int = 0,
    listedOthers: Int = 0,
    goneBeforeDetach: Int = 0,
    detachedClients: Int = 0,
    ageWait: Duration = .zero,
    counts: AttachmentSnapshot.Counts? = nil
  ) {
    self.key = key
    self.outcome = outcome
    self.kept = kept
    self.otherAttachmentsHere = otherAttachmentsHere
    self.listedOthers = listedOthers
    self.goneBeforeDetach = goneBeforeDetach
    self.detachedClients = detachedClients
    self.ageWait = ageWait
    self.counts = counts
  } // End of init(key:outcome:kept:otherAttachmentsHere:listedOthers:goneBeforeDetach:…)

  /// Whether a detaching command may have reached tmux: one was answered, or one failed in a
  /// way that does not prove it was never sent.
  public var mayHaveSent: Bool {
    if detachedClients > 0 { return true }
    if case .checkFailed(.send(let error)) = outcome { return !error.isNotSent }
    return false
  }
} // End of struct DetachOtherClientsResult

/// One other client of a session, as the session's client listing showed it: its process id,
/// creation time and name, all validated, so they can be put into a tmux command (PLAN.md D37).
public struct OtherClient: Sendable, Hashable {
  /// The longest name accepted, in bytes.
  public static let maximumNameLength = 255

  /// `#{client_pid}`: a positive number.
  public let processID: Int32
  /// `#{client_created}`: when tmux created the client, in whole seconds since 1970 by the tmux
  /// server's clock.
  public let created: Int64
  /// `#{client_name}`: `client-<digits>` (a client without a terminal) or `/dev/` and a
  /// terminal's name (`/dev/ttys003`), only ASCII letters, digits, `.`, `_`, `-` and `/`.
  public let name: String

  /// Validates the values; `nil` when one is not what tmux reports for a client (a canonical
  /// positive pid, a canonical number of seconds, a name `isValidName(_:)` accepts).
  public init?(processID: String, created: String, name: String) {
    guard
      let pid = ConnectionIdentity.canonicalInteger(processID, as: Int32.self), pid > 0,
      let created = ConnectionIdentity.canonicalInteger(created, as: Int64.self),
      Self.isValidName(name)
    else { return nil }
    self.processID = pid
    self.created = created
    self.name = name
  } // End of init?(processID:created:name:)

  /// Whether `name` is `client-` and a canonical number, or `/dev/` and at least one
  /// character, every one an ASCII letter, digit, `.`, `_`, `-` or `/`, at most
  /// `maximumNameLength` bytes. Such a name holds nothing tmux's parser or its formats would
  /// read as syntax (no quote, space, `#`, `,`, `{`, `}`, `;`, `$` or `\`).
  public static func isValidName(_ name: String) -> Bool {
    guard name.utf8.count <= maximumNameLength else { return false }
    if name.hasPrefix("client-") {
      return ConnectionIdentity.canonicalInteger(String(name.dropFirst(7)), as: Int64.self) != nil
    }
    guard name.hasPrefix("/dev/"), name.utf8.count > 5 else { return false }
    return name.utf8.allSatisfy { byte in
      (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A)
        || (byte >= 0x61 && byte <= 0x7A) || [0x2E, 0x5F, 0x2D, 0x2F].contains(byte)
    }
  } // End of static func isValidName(_:)

  /// How long to wait, from the listing's answer, before this client may be detached so it is
  /// at least `minimumAge` old (PLAN.md D37, the age rule of D15 applied to every client
  /// detached): `serverTime` is tmux's clock read before the listing, in whole seconds like
  /// `created`, so the client's age when the listing answered is more than `serverTime -
  /// created - 1` s, and the wait is `minimumAge + 1 s - (serverTime - created)`, never below
  /// zero. It is never above `minimumAge` either: the client existed when the listing answered,
  /// so after `minimumAge` it is that old whatever tmux's clock says (a client created after the
  /// clock was read, or a creation time ahead of it, gets the whole `minimumAge`).
  public func ageWait(serverTime: Int64, minimumAge: Duration) -> Duration {
    let age = Duration.seconds(serverTime) - Duration.seconds(created)
    let wait = minimumAge + .seconds(1) - age
    return min(max(wait, .zero), minimumAge)
  }
} // End of struct OtherClient

/// The tmux commands `AttachCoordinator.detachOtherClients(of:confirmation:)` sends through the
/// kept connection (PLAN.md D37), one command per request, and the reading of their answers.
///
/// One command per request because iTerm2 pairs every reply block tmux marks as the control
/// client's (`%begin` flag 1) with the oldest command it is waiting for, and tmux 3.8 marks the
/// command `if-shell` inserts that way too (it shares the sender's command state), so a guarded
/// `if-shell -F … 'detach-client …'` would answer one request with two blocks. And no command
/// may fail in tmux: iTerm2 3.7 tolerates no `%error` for a command sent through its API, it
/// shows its "tmux Reported a Problem" alert and ends the whole connection. So the three
/// read-only commands filter the server's clients (`list-clients -f`, never `-t`, which fails
/// once the session is gone) and cannot fail: the connection's own client name with tmux's
/// clock, the session's clients, and the check of one client right before its detach. The
/// fourth, `detach-client -t <name>`, detaches that one client; it fails only when no client
/// has that name any more (the residual of D37: the checked client ended within the round trip
/// since its check).
///
/// The only runtime values ever inserted are the session id (validated by `TmuxSessionID`: `$`
/// and digits) and a client's validated process id, creation time and name (`OtherClient`),
/// each inside single quotes, so tmux's parser takes them literally. Never `detach-client -a`
/// (every other client of the server), `-s` (the sending one too) or `attach-session -d`
/// (iTerm2 closes and reopens the session's windows on the `%session-changed` it sends the
/// sender, D37's proof).
public enum OtherClientsCommands {
  /// Prints tmux's clock (`%s`, whole seconds since 1970; `display-message` expands `strftime`
  /// sequences in its template) and the name of the connection's own tmux client, separated by
  /// one space.
  public static let ownClientAndTime = "display-message -p '%s #{client_name}'"

  /// Lists every client of the session `sessionID`, one `<pid>:<created>:<name>` line each
  /// (read-only; filtered by the client's session id, so a session that is gone lists nothing
  /// instead of failing).
  public static func clients(of sessionID: TmuxSessionID) -> String {
    "list-clients -f '#{==:#{session_id},\(sessionID.rawValue)}' "
      + "-F '#{client_pid}:#{client_created}:#{client_name}'"
  }

  /// Prints `client`'s process id only while a client with its name, process id and creation
  /// time is attached to the session `sessionID` (read-only; empty otherwise): the check right
  /// before its detach, so a client that left the session, or a name another client took
  /// meanwhile, is not detached.
  public static func check(_ client: OtherClient, of sessionID: TmuxSessionID) -> String {
    "list-clients -f '#{&&:#{==:#{client_name},\(client.name)},"
      + "#{&&:#{==:#{client_pid},\(client.processID)},"
      + "#{&&:#{==:#{client_created},\(client.created)},"
      + "#{==:#{session_id},\(sessionID.rawValue)}}}}' -F '#{client_pid}'"
  }

  /// Detaches the one client named `client.name`.
  public static func detach(_ client: OtherClient) -> String {
    "detach-client -t '\(client.name)'"
  }

  /// What `ownClientAndTime` printed.
  public struct Own: Sendable, Hashable {
    /// tmux's clock, whole seconds since 1970.
    public var serverTime: Int64
    /// The connection's own client name.
    public var name: String
  }

  /// What the session's client listing showed, against the connection's own client name.
  public enum Listing: Sendable, Hashable {
    /// The own client is listed once; these are the others, in listing order.
    case others([OtherClient])
    /// The own client is not among the session's clients (it moved to another session).
    case ownNotListed
    /// A line was not `<pid>:<created>:<name>` with valid values, or the own name is listed
    /// twice.
    case unreadable
  }

  /// What one client's check showed.
  public enum Check: Sendable, Hashable {
    /// The client is still attached to the session with that name, process id and creation
    /// time.
    case present
    /// No such client is attached to the session any more.
    case gone
    /// The answer was neither.
    case unreadable
  }

  /// Reads `ownClientAndTime`'s answer: one line (a trailing line break allowed) without
  /// control characters, a canonical number of seconds, one space and a non-empty name; `nil`
  /// otherwise.
  public static func readOwn(_ output: String) -> Own? {
    guard let lines = lines(of: output), lines.count == 1,
      let space = lines[0].firstIndex(of: " ")
    else { return nil }
    let name = String(lines[0][lines[0].index(after: space)...])
    guard
      let time = ConnectionIdentity.canonicalInteger(String(lines[0][..<space]), as: Int64.self),
      !name.isEmpty
    else { return nil }
    return Own(serverTime: time, name: name)
  } // End of static func readOwn(_:)

  /// Reads `clients(of:)`'s answer against the own client's name `ownName`: every line must be
  /// `<pid>:<created>:<name>`, the own name listed exactly once and every other client valid.
  public static func readListing(_ output: String, ownName: String) -> Listing {
    // No line at all means no client, so not the own one either.
    guard let lines = lines(of: output) else { return .unreadable }
    var ownCount = 0
    var others: [OtherClient] = []
    for line in lines {
      let fields = line.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
      guard fields.count == 3 else { return .unreadable }
      if fields[2] == ownName {
        ownCount += 1
        continue
      }
      guard
        let client = OtherClient(
          processID: String(fields[0]), created: String(fields[1]), name: String(fields[2]))
      else { return .unreadable }
      others.append(client)
    } // End of loop over the listing's lines
    switch ownCount {
    case 0: return .ownNotListed
    case 1: return .others(others)
    default: return .unreadable
    }
  } // End of static func readListing(_:ownName:)

  /// Reads `check(_:of:)`'s answer for `client`.
  public static func readCheck(_ output: String, for client: OtherClient) -> Check {
    switch lines(of: output) {
    case [String(client.processID)]?: return .present
    case []?: return .gone
    default: return .unreadable
    }
  }

  /// The lines of `output` without one trailing line break; `nil` when a line is empty or holds
  /// a control character (a client name never does).
  static func lines(of output: String) -> [String]? {
    var text = Substring(output)
    if text.hasSuffix("\n") { text.removeLast() }
    guard !text.isEmpty else { return [] }
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    for line in lines {
      guard !line.isEmpty, line.unicodeScalars.allSatisfy({ $0.value >= 0x20 && $0.value != 0x7F })
      else { return nil }
    }
    return lines
  } // End of static func lines(of:)
} // End of enum OtherClientsCommands
