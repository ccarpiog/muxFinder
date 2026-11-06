import Foundation

/// The identity a bound plain command requires of its session on the tmux server (PLAN.md D38):
/// the session id, its creation time, the server's pid and start time and, when given, the
/// server's socket path and the session's name. Session ids start over when a server restarts,
/// so an id alone may name another session (possibly the user's) by the time a command runs.
///
/// A bound command is one `if-shell -F -t <id> <condition> <command> <otherwise>`: the server
/// expands `condition` against the session `-t` resolves and runs the chosen command right after
/// `if-shell`, in the same command queue with nothing in between, so no restart, rename or
/// other client can come between the check and the action (`CreatedSession
/// .killIfUnchangedArguments` is the same form). A missing `-t` session resolves leniently to
/// none, so the condition compares every field and is simply false then.
public struct BoundSessionIdentity: Sendable, Hashable {
  /// The session's id.
  public var sessionID: TmuxSessionID
  /// The server's pid (`#{pid}`).
  public var serverPID: Int32
  /// The server's start time, in seconds since 1970 (`#{start_time}`).
  public var serverStartTime: Int64
  /// The session's creation time, in seconds since 1970 (`#{session_created}`).
  public var createdAt: Int64
  /// The server's socket path (`#{socket_path}`), compared when not `nil`.
  public var socketPath: String?
  /// The session's name (`#{session_name}`), compared when not `nil`. A bound detach needs it.
  public var name: String?

  /// Creates an identity.
  public init(
    sessionID: TmuxSessionID,
    serverPID: Int32,
    serverStartTime: Int64,
    createdAt: Int64,
    socketPath: String? = nil,
    name: String? = nil
  ) {
    self.sessionID = sessionID
    self.serverPID = serverPID
    self.serverStartTime = serverStartTime
    self.createdAt = createdAt
    self.socketPath = socketPath
    self.name = name
  } // End of init(sessionID:serverPID:serverStartTime:createdAt:socketPath:name:)

  /// The identity of a session its creator recorded: every field, socket path and name
  /// included.
  public init(_ session: CreatedSession) {
    self.init(
      sessionID: session.sessionID, serverPID: session.server.pid,
      serverStartTime: session.server.startTime, createdAt: session.createdAt,
      socketPath: session.server.socketPath, name: session.name)
  }

  /// The `if-shell -F` format that is `1` only for a target session with exactly this
  /// identity: `#{==:…}` checks of `session_id`, `session_created`, `pid`, `start_time`, then
  /// `socket_path` and `session_name` when given, joined by right-nested `#{&&:…}`. Only
  /// validated values are written: an id `$<digits>`, a positive pid, non-negative numbers, and
  /// the socket path and name as format literals (`CreatedSession.formatLiteral(_:)`). `nil`
  /// when one of them cannot be written so.
  public var condition: String? {
    let id = sessionID.rawValue
    guard TmuxSessionID.isValid(Array(id.utf8)[...]), serverPID > 0, serverStartTime >= 0,
      createdAt >= 0
    else { return nil }
    var checks = [
      "#{==:#{session_id},\(id)}", "#{==:#{session_created},\(createdAt)}",
      "#{==:#{pid},\(serverPID)}", "#{==:#{start_time},\(serverStartTime)}",
    ]
    if let socketPath {
      guard let literal = CreatedSession.formatLiteral(socketPath) else { return nil }
      checks.append("#{==:#{socket_path},\(literal)}")
    }
    if let name {
      guard let literal = CreatedSession.formatLiteral(name) else { return nil }
      checks.append("#{==:#{session_name},\(literal)}")
    }
    return Self.all(checks)
  } // End of var condition

  /// `checks` joined by right-nested `#{&&:…}` (`#{&&:a,#{&&:b,c}}`); one check is itself.
  static func all(_ checks: [String]) -> String {
    guard let last = checks.last else { return "1" }
    return checks.dropLast().reversed().reduce(last) { "#{&&:\($1),\($0)}" }
  }
} // End of struct BoundSessionIdentity

extension PlainLaunch {
  /// The exit status of a bound plain attach whose session is not exactly the recorded one
  /// (changed or gone): the guard's "changed" (`LaunchGuard`, D17), from `refusal`.
  public static let sessionChangedStatus: Int32 = 65

  /// What a bound attach runs instead of attaching: tmux's `run-shell` with a constant
  /// command, which makes the unattached tmux client exit with `sessionChangedStatus` (tmux
  /// prints `'exit 65' returned 65` to that client; no pane is touched, no runtime value is in
  /// it).
  static let refusal = "run-shell 'exit 65'"

  /// The local attach child's arguments after the tmux path, bound to `session` (PLAN.md D38):
  ///
  /// `-u if-shell -F -t <id> <condition> "attach-session [-d] -t '<id>'" "run-shell 'exit 65'"`
  ///
  /// The server attaches this client (detaching the session's other clients first with `-d`,
  /// a move here, D21) only while `-t <id>` is exactly `session` (`BoundSessionIdentity
  /// .condition`), checked and done in one command; otherwise nothing attaches or detaches and
  /// the client exits `sessionChangedStatus`. With no server tmux exits 1 (`no server running`
  /// or `error connecting`) and starts none, since `if-shell` does not start a server. The id
  /// is single-quoted in the attach for tmux's parser (unquoted, `$3` would be read as an
  /// environment variable). D12's `-u` keeps the client in UTF-8. `nil` when `session` cannot
  /// be encoded.
  public static func localAttachArguments(
    session: BoundSessionIdentity,
    detachingOthers: Bool
  ) -> [String]? {
    guard let condition = session.condition else { return nil }
    let id = session.sessionID.rawValue
    return [
      "-u", "if-shell", "-F", "-t", id, condition,
      "attach-session " + (detachingOthers ? "-d " : "") + "-t '\(id)'", refusal,
    ]
  } // End of static func localAttachArguments(session:detachingOthers:)
} // End of extension PlainLaunch

/// The targeted detach of one identified plain client (PLAN.md D38), decided and done by the
/// tmux server in one command, so a client that left, ended, or whose terminal another client
/// took meanwhile (terminal paths are reused at once) is never detached in its place:
///
/// `if-shell -F -t <id> <condition> "detach-client -t '<name>'" "display-message -p <marker>"`
///
/// `<condition>` is `session`'s (`BoundSessionIdentity.condition`, which must include the
/// name), and, in a client loop (`#{L:…}`, every attached client, as `detach-client -t`
/// searches), exactly one client named `<name>`, and that client with the recorded pid and
/// creation time attached to the session of that name (`#{client_session}`; session names are
/// unique on a server, and the outer check binds the name to the id). The loop compares only
/// client fields: inside it `session_id` is the target's, never the client's. Only a client
/// name `OtherClient.isValidName(_:)` accepts is written, single-quoted for tmux's parser.
public enum PlainClientDetach {
  /// What the command prints (with a line break) when the condition is false.
  public static let notThisClientMarker = "muxfinder-not-this-client"

  /// How a bound detach ended.
  public enum Outcome: String, Sendable, Hashable {
    /// The condition held and tmux detached that client.
    case detached
    /// The client, its session or the server is not exactly the recorded one, or there is no
    /// server: nothing was detached.
    case notThisClient
    /// tmux failed, or its answer was neither: nothing is known.
    case failed
  }

  /// The tmux arguments (after `tmux -u`) of the bound detach of `client` from `session`, or
  /// `nil` when `session` has no name or a value cannot be encoded.
  public static func arguments(of client: OtherClient, in session: BoundSessionIdentity)
    -> [String]?
  {
    guard let name = session.name, let sessionName = CreatedSession.formatLiteral(name),
      let sessionCondition = session.condition, OtherClient.isValidName(client.name)
    else { return nil }
    let named = "#{==:#{client_name},\(client.name)}"
    let unique = "#{==:#{L:#{?\(named),1,}},1}"
    let this = BoundSessionIdentity.all([
      named, "#{==:#{client_pid},\(client.processID)}",
      "#{==:#{client_created},\(client.created)}", "#{==:#{client_session},\(sessionName)}",
    ])
    let condition = BoundSessionIdentity.all([
      sessionCondition, unique, "#{==:#{L:#{?\(this),1,}},1}",
    ])
    return [
      "if-shell", "-F", "-t", session.sessionID.rawValue, condition,
      "detach-client -t '\(client.name)'", "display-message -p \(notThisClientMarker)",
    ]
  } // End of static func arguments(of:in:)

  /// How a run of `arguments(of:in:)` ended: exit 0 with no output is `detached`; exit 0 with
  /// exactly the marker line, or exit 1 with tmux's "no server" error, is `notThisClient`;
  /// anything else is `failed`.
  public static func outcome(
    exitStatus: Int32?,
    standardOutput: String,
    standardError: String
  ) -> Outcome {
    switch exitStatus {
    case 0? where standardOutput.isEmpty:
      return .detached
    case 0? where standardOutput == notThisClientMarker + "\n":
      return .notThisClient
    case 1?:
      let firstLine = standardError.split(separator: "\n").first.map(String.init) ?? ""
      return ErrorClassifier.isNoServerMessage(firstLine) ? .notThisClient : .failed
    default:
      return .failed
    }
  } // End of static func outcome(exitStatus:standardOutput:standardError:)
} // End of enum PlainClientDetach
