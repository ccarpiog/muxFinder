import Foundation

/// A tmux session as the process that created it recorded it: the server it lives in (socket
/// path, pid, start time), its id, creation time and name, printed by
/// `new-session -P -F CreatedSession.format`.
///
/// Session ids start over when a server restarts (`$0` again), so a later step that finds "its"
/// session again, to attach, inspect or kill it, compares all of these and never trusts the id
/// alone. The `e2e-local` harness uses it for its own `muxfinder-test-*` session.
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

  /// Whether discovery's `session` is this session: the same server (socket path, pid and start
  /// time), id, creation time and name.
  public func matches(_ session: DiscoveredSession) -> Bool {
    session.key.server == server && session.key.sessionID == sessionID
      && session.createdAt == createdAt && session.name == name
  }

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
