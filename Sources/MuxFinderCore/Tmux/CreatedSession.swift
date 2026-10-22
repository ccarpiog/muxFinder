import Foundation

/// A tmux session as the process that created it recorded it: the server it lives in (socket
/// path, pid, start time), its id, creation time and name, printed by
/// `new-session -P -F CreatedSession.format`.
///
/// Session ids start over when a server restarts (`$0` again), so a later step that finds "its"
/// session again, to attach, inspect or kill it, compares all of these and never trusts the id
/// alone. `TmuxCommands` returns one for every session it creates; the e2e harness uses it for
/// its own `muxfinder-test-*` sessions.
public struct CreatedSession: Sendable, Hashable {
  /// The tmux format that prints one session's record on one line, tab-separated:
  /// `#{session_id}`, `#{session_created}`, `#{pid}`, `#{start_time}`, `#{socket_path}`,
  /// `#{session_name}`. It works for `new-session -P -F`, `list-sessions -F` and
  /// `display-message -p -t`.
  public static let format =
    "#{session_id}\t#{session_created}\t#{pid}\t#{start_time}\t#{socket_path}\t#{session_name}"

  /// The server.
  public var server: ServerIdentity
  /// The session's id within that server.
  public var sessionID: TmuxSessionID
  /// When the session was created, in seconds since 1970 (`#{session_created}`).
  public var createdAt: Int64
  /// The session's name.
  public var name: String

  /// Creates a record.
  public init(server: ServerIdentity, sessionID: TmuxSessionID, createdAt: Int64, name: String) {
    self.server = server
    self.sessionID = sessionID
    self.createdAt = createdAt
    self.name = name
  }

  /// Parses one line printed with `format` (a trailing line break is allowed): exactly six
  /// tab-separated fields, the numbers canonical decimals, the pid positive, the socket path
  /// absolute and the name not empty. A socket path or name containing a tab makes the line
  /// ambiguous, so it is refused like any other malformed line (`nil`). Works on bytes, so
  /// `\r\n` and combining characters cannot hide a separator.
  public static func parse(_ line: String) -> CreatedSession? {
    var bytes = Array(line.utf8)
    while let last = bytes.last, last == 0x0A || last == 0x0D { bytes.removeLast() }
    guard !bytes.contains(0x0A), !bytes.contains(0x0D) else { return nil }
    let fields = bytes.split(separator: 0x09, omittingEmptySubsequences: false).map {
      String(decoding: $0, as: UTF8.self)
    }
    guard fields.count == 6, let sessionID = TmuxSessionID(fields[0]),
      let createdAt = ConnectionIdentity.canonicalInteger(fields[1], as: Int64.self),
      let pid = ConnectionIdentity.canonicalInteger(fields[2], as: Int32.self), pid > 0,
      let startTime = ConnectionIdentity.canonicalInteger(fields[3], as: Int64.self),
      fields[4].hasPrefix("/"), !fields[5].isEmpty
    else { return nil }
    return CreatedSession(
      server: ServerIdentity(socketPath: fields[4], pid: pid, startTime: startTime),
      sessionID: sessionID, createdAt: createdAt, name: fields[5])
  } // End of func parse(_:)

  /// The attach target for this session on `host` (the host it was created on), as the
  /// coordinator takes it: the key and creation time are this record's, so revalidation
  /// accepts only this very session; the counts are a new detached session's (one window, no
  /// client), which revalidation replaces with what discovery reports.
  public func attachTarget(on host: HostConfig) -> AttachTarget {
    AttachTarget(
      host: host,
      session: DiscoveredSession(
        key: SessionKey(hostID: host.id, server: server, sessionID: sessionID), name: name,
        createdAt: createdAt, windowCount: 1, attachedClientCount: 0, lastActivityAt: createdAt,
        clients: []))
  } // End of func attachTarget(on:)

  /// Whether discovery's `session` is this session: the same server (socket path, pid and start
  /// time), id, creation time and name.
  public func matches(_ session: DiscoveredSession) -> Bool {
    session.key.server == server && session.key.sessionID == sessionID
      && session.createdAt == createdAt && session.name == name
  }

  // MARK: - Killing this session only if it is still this session

  /// What `killIfUnchangedArguments` prints (with a line break) when the session it would kill
  /// is not there or is another one.
  public static let notThisSessionMarker = "muxfinder-not-this-session"

  /// How a run of `killIfUnchangedArguments` ended.
  public enum KillOutcome: String, Sendable, Hashable {
    /// The session was this one, and `kill-session` killed it.
    case killed
    /// No session is exactly this one (another server, id, creation time, socket or name, or
    /// none, or no server at all); nothing was killed.
    case notThisSession
    /// tmux failed, or its answer was not one of the above; nothing is known.
    case failed
  }

  /// The tmux arguments (after `tmux -u`) that kill this session only while it is still exactly
  /// this session, decided and done by one tmux client in one command, so on one server
  /// connection with nothing in between:
  ///
  /// `if-shell -F -t <id> <condition> "kill-session -t '<id>'" "display-message -p <marker>"`
  ///
  /// `<condition>` is a format that is true only for a target whose session id, creation time,
  /// server pid, server start time, socket path and name are this record's (all compared, since
  /// `if-shell` resolves a missing `-t` target leniently, without an error). The server runs the
  /// chosen command right after `if-shell` in the same command queue, so a server restart, or
  /// another client, cannot come between the check and the kill. The kill's command string is
  /// parsed by tmux's own parser, so the id is single-quoted there (unquoted, `$1` would be read
  /// as an environment variable). Only validated values are encoded: an id `$<digits>`,
  /// non-negative decimal numbers, and a name and socket path written as format literals
  /// (`formatLiteral(_:)`). `nil` when one of them cannot be encoded so.
  ///
  /// Run it with `tmux -u` and read the result with `killOutcome(exitStatus:standardOutput:
  /// standardError:)`. The e2e harness uses it for its own `muxfinder-test-*` sessions.
  public var killIfUnchangedArguments: [String]? {
    let id = sessionID.rawValue
    guard TmuxSessionID.isValid(Array(id.utf8)[...]), createdAt >= 0, server.pid > 0,
      server.startTime >= 0,
      let socket = Self.formatLiteral(server.socketPath), let name = Self.formatLiteral(name)
    else { return nil }
    let checks = [
      "#{==:#{session_id},\(id)}", "#{==:#{session_created},\(createdAt)}",
      "#{==:#{pid},\(server.pid)}", "#{==:#{start_time},\(server.startTime)}",
      "#{==:#{socket_path},\(socket)}", "#{==:#{session_name},\(name)}",
    ]
    let condition = checks.dropLast().reversed().reduce(checks[checks.count - 1]) {
      "#{&&:\($1),\($0)}"
    }
    return [
      "if-shell", "-F", "-t", id, condition, "kill-session -t '\(id)'",
      "display-message -p \(Self.notThisSessionMarker)",
    ]
  } // End of var killIfUnchangedArguments

  /// How a run of `killIfUnchangedArguments` ended: exit 0 with no output is `killed`; exit 0
  /// with exactly the marker line, or exit 1 with tmux's "no server" error, is
  /// `notThisSession`; anything else is `failed`.
  public static func killOutcome(
    exitStatus: Int32?,
    standardOutput: String,
    standardError: String
  ) -> KillOutcome {
    switch exitStatus {
    case 0? where standardOutput.isEmpty:
      return .killed
    case 0? where standardOutput == notThisSessionMarker + "\n":
      return .notThisSession
    case 1?:
      let firstLine = standardError.split(separator: "\n").first.map(String.init) ?? ""
      return ErrorClassifier.isNoServerMessage(firstLine) ? .notThisSession : .failed
    default:
      return .failed
    }
  } // End of func killOutcome(exitStatus:standardOutput:standardError:)

  /// `text` as a literal inside a tmux format argument (here the right side of `#{==:…,…}`):
  /// `#`, `,` and `}` are written `##`, `#,` and `#}`. `nil` for empty text, a control
  /// character, or a `{`, `[` or `]`: tmux keeps a run of `#` before `[` undoubled (a style),
  /// so such text would not read back exactly, and leaving brackets out means no style or
  /// nested format can start.
  public static func formatLiteral(_ text: String) -> String? {
    guard !text.isEmpty, !Validation.containsControlCharacter(text),
      !text.unicodeScalars.contains(where: { "{[]".unicodeScalars.contains($0) })
    else { return nil }
    var literal = String.UnicodeScalarView()
    for scalar in text.unicodeScalars {
      if "#,}".unicodeScalars.contains(scalar) { literal.append("#") }
      literal.append(scalar)
    }
    return String(literal)
  } // End of func formatLiteral(_:)

  /// The one session named exactly `name` and created at or after `earliest` (seconds since
  /// 1970) among the lines of a `list-sessions -F format` listing, or `nil` when no line, or
  /// more than one, qualifies. Malformed lines are skipped. This recovers a session whose
  /// creation took effect although its creator never read the `new-session` output.
  public static func find(
    named name: String,
    createdNoEarlierThan earliest: Int64,
    in lines: [String]
  ) -> CreatedSession? {
    let candidates = lines.compactMap(parse).filter {
      $0.name == name && $0.createdAt >= earliest
    }
    return candidates.count == 1 ? candidates[0] : nil
  } // End of func find(named:createdNoEarlierThan:in:)
}
