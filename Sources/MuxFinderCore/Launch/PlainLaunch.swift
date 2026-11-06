import Foundation

/// A plain tmux attach, for terminal apps without tmux control mode (PLAN.md D38, proven in
/// Phase I-12a by `muxfinder-probe plain-proof`): an ordinary `tmux -u attach-session` client
/// with its own status bar, prefix keys and copy mode, never `-CC`.
///
/// The helper's `attach-plain` runs it for a request (`localAttachArguments(for:)`,
/// `sshArguments(for:)`, Phase I-12b2); nothing in the app writes a plain request yet (I-12c).
/// Everything here is static text or argv, so it changes no existing behavior.
///
/// Every attach is **bound**: one `tmux -u if-shell -F -t <id> <condition> "attach-session
/// [-d] -t '<id>'" "run-shell 'exit 65'"`, so the server attaches (and, for a move here,
/// detaches the session's other clients) only while the session is exactly the recorded one,
/// checked and done in one command; otherwise it exits 65, the guard's "changed"
/// (`localAttachArguments(session:detachingOthers:)`, `BoundSessionIdentity`).
///
/// - **This Mac:** the attach child is `<tmux>` with `localAttachArguments(session:
///   detachingOthers:)` (`-d` for a move here, PLAN.md D21), spawned as argv on the launch's
///   terminal. The launch's client is the one whose `client_tty` is that terminal
///   (`PlainClientIdentification.local`).
/// - **SSH hosts:** D17's remote script with the attach made plain and bound, and the launch
///   token added as a sixth positional parameter, after the guard's five check values. The
///   guard's check (`LaunchGuard.check`) runs first, for its exit codes; the bound attach then
///   repeats its four values (id, server pid and start time, creation time) inside tmux. The
///   script does not `exec` tmux: the `/bin/sh` that ran the check stays as the tmux client's
///   parent, so its argument list, which ends with the token, tells this launch's client from
///   every other client of the session (`PlainClientIdentification.remoteScript`, read with
///   `ps` by `client_pid`). The token is a canonical launch id (lowercase hexadecimal digits
///   and `-`), checked again by the script, and only ever data (D3).
public enum PlainLaunch {
  /// Checks and removes the token, the sixth positional parameter: exactly six arguments, the
  /// sixth 36 bytes of lowercase hexadecimal digits and `-`; anything else exits 68 (the guard's
  /// usage code). The parameters are then the guard's five, while the shell's own argument list
  /// (what `ps` shows) still ends with the token.
  static let tokenStep: StaticShellScript = #"""
    if [ "$#" -ne 6 ]; then exit 68; fi
    case $6 in '' | *[!0-9a-f-]*) exit 68 ;; esac
    if [ "${#6}" -ne 36 ]; then exit 68; fi
    set -- "$1" "$2" "$3" "$4" "$5"

    """#

  /// The bound attach's condition after a matching check, the same format
  /// `BoundSessionIdentity.condition` writes for the guard's four values (session id, creation
  /// time, server pid, server start time; a unit test compares them). The values are the
  /// guard's, already checked to be `$<digits>` and decimal digits, so nothing else can enter
  /// the format.
  static let boundCondition: StaticShellScript = #"""
    c="#{&&:#{==:#{session_id},$id},#{&&:#{==:#{session_created},$5},#{&&:#{==:#{pid},$3},#{==:#{start_time},$4}}}}"

    """#

  /// The last step after a matching check: the bound plain attach as a child of this shell
  /// (never `exec`, so the shell holding the token stays its parent), then the shell exits
  /// with the client's status (0 after a detach, 65 when the session changed since the check).
  static let attachTail: StaticShellScript =
    boundCondition
      + #"""
      "$t" -u if-shell -F -t "$id" "$c" "attach-session -t '$id'" "run-shell 'exit 65'"
      exit "$?"

      """#

  /// The last step of a move here (PLAN.md D21): the same with `-d`.
  static let moveHereTail: StaticShellScript =
    boundCondition
      + #"""
      "$t" -u if-shell -F -t "$id" "$c" "attach-session -d -t '$id'" "run-shell 'exit 65'"
      exit "$?"

      """#

  /// The remote script of a plain attach: the tmux locator, the token step, the guard's
  /// identity check (`LaunchGuard.check`, exit 64–68 as in D17) and the bound plain attach
  /// (65 when the session is no longer the checked one by the time tmux attaches).
  public static let remoteScript: StaticShellScript =
    TmuxLocator.script + tokenStep + LaunchGuard.check + attachTail

  /// The remote script of a plain move here: `remoteScript` ending with `attach-session -d`.
  public static let remoteMoveHereScript: StaticShellScript =
    TmuxLocator.script + tokenStep + LaunchGuard.check + moveHereTail

  /// The D3 string ssh hands the remote login shell: the static script (the move here one when
  /// `detachingOthers`) with the guard's five check values (`LaunchGuard.checkArguments(for:)`:
  /// override, session id, server pid, server start time, creation time) and the token, each
  /// POSIX single-quoted.
  public static func remoteCommand(
    checkArguments: [String],
    token: LaunchToken,
    detachingOthers: Bool
  ) -> String {
    ShellQuoting.remoteCommand(
      script: detachingOthers ? remoteMoveHereScript : remoteScript,
      args: checkArguments + [token.rawValue])
  }
} // End of enum PlainLaunch

extension PlainLaunch {
  /// The identity a plain attach of `request` binds to: the guard's four values (session id,
  /// creation time, server pid and start time), as the request carries them.
  public static func boundIdentity(of request: LaunchRequest) -> BoundSessionIdentity {
    BoundSessionIdentity(
      sessionID: request.sessionID, serverPID: request.expectedServerPID,
      serverStartTime: request.expectedServerStartTime,
      createdAt: request.expectedSessionCreated)
  }

  /// The local attach child's arguments after the tmux path for `request`
  /// (`localAttachArguments(session:detachingOthers:)` over `boundIdentity(of:)`, with `-d`
  /// exactly when the request moves the session here, `LaunchRequest.detachesOtherClients`);
  /// `nil` when its values cannot be encoded.
  public static func localAttachArguments(for request: LaunchRequest) -> [String]? {
    localAttachArguments(
      session: boundIdentity(of: request), detachingOthers: request.detachesOtherClients)
  }

  /// ssh's arguments after argv[0] for a plain attach of `request` on an SSH host: D17's
  /// options, `--`, the validated destination and `remoteCommand(checkArguments:token:
  /// detachingOthers:)` with the guard's five values (`LaunchGuard.checkArguments(for:)`) and
  /// the request's launch id as the token (`remoteMoveHereScript` for a move here). `nil` when
  /// it is not an SSH request with a valid destination.
  public static func sshArguments(for request: LaunchRequest) -> [String]? {
    guard case .ssh(let raw) = request.host,
      let destination = try? Validation.sshDestination(raw)
    else { return nil }
    let command = remoteCommand(
      checkArguments: LaunchGuard.checkArguments(for: request), token: request.id,
      detachingOthers: request.detachesOtherClients)
    return RemoteLaunch.sshOptions + ["--", destination, command]
  } // End of static func sshArguments(for:)
} // End of extension PlainLaunch

/// Which client of a session is a plain launch's (PLAN.md D38, requirement 5 of
/// `autoclaude/processed/110-other-terminal-apps.md`): only evidence counts (D15, D25), and a
/// reading that cannot tell two clients apart confirms nothing.
///
/// - **This Mac:** the session's clients whose `client_tty` is the launch's terminal (`local`).
/// - **SSH hosts:** the session's clients whose parent process's argument list ends with the
///   launch token (`remoteScript`, run over discovery's noninteractive ssh: read-only `tmux
///   list-clients` and `ps`, no file written; its answer read by `remote`).
public enum PlainClientIdentification {
  /// What a reading found.
  public enum Outcome: Sendable, Hashable {
    /// Exactly one client of the session carries the launch's evidence.
    case confirmed(OtherClient)
    /// No client of the session carries it.
    case none
    /// More than one does, so none is confirmed.
    case ambiguous([OtherClient])
  }

  /// One reading of a session's clients.
  public struct Reading: Sendable, Hashable {
    /// Every client of the session, in listing order.
    public var clients: [OtherClient]
    /// The clients carrying the launch's evidence, in listing order.
    public var candidates: [OtherClient]

    /// Creates a reading.
    public init(clients: [OtherClient], candidates: [OtherClient]) {
      self.clients = clients
      self.candidates = candidates
    }

    /// `confirmed` for exactly one candidate, `none` for none, `ambiguous` otherwise.
    public var outcome: Outcome {
      switch candidates.count {
      case 0: return .none
      case 1: return .confirmed(candidates[0])
      default: return .ambiguous(candidates)
      }
    }
  } // End of struct Reading

  // MARK: - This Mac

  /// The `list-clients -F` format of the local reading, tab-separated: `#{session_id}`,
  /// `#{client_pid}`, `#{client_created}`, `#{client_tty}`, `#{client_name}`. Every client of
  /// the server is listed (no filter, so nothing from the run is put into a format), and the
  /// reading keeps the session's.
  public static let localFormat =
    "#{session_id}\t#{client_pid}\t#{client_created}\t#{client_tty}\t#{client_name}"

  /// Reads `list-clients -F localFormat`'s output for the session `sessionID` and the launch's
  /// terminal `terminal` (its path, such as `/dev/ttys004`). `nil` when any line is not five
  /// tab-separated fields, or a client of the session has a value `OtherClient` refuses: an
  /// unreadable listing confirms nothing.
  public static func local(
    listing: String,
    sessionID: TmuxSessionID,
    terminal: String
  ) -> Reading? {
    guard let lines = lines(of: listing), !terminal.isEmpty else { return nil }
    var reading = Reading(clients: [], candidates: [])
    for line in lines {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 5 else { return nil }
      guard fields[0] == sessionID.rawValue else { continue }
      guard let client = OtherClient(processID: fields[1], created: fields[2], name: fields[4])
      else { return nil }
      reading.clients.append(client)
      if fields[3] == terminal { reading.candidates.append(client) }
    } // End of loop over the listing's lines
    return reading
  } // End of static func local(listing:sessionID:terminal:)

  // MARK: - SSH hosts

  /// The remote reading: a static script run as `/bin/sh -c <script> muxfinder <override>
  /// <session id> <token>` over discovery's noninteractive ssh (PLAN.md D3, D6). It locates
  /// tmux (D5), lists the server's clients, and for each client of the session reads its
  /// parent's pid (`ps -o ppid=`) and that parent's whole argument list (`ps -ww -o args=`);
  /// the client is `match` when that list ends with a space and the token, else `other`. It
  /// prints one `<match|other> <pid> <created> <name>` line per client of the session, then
  /// `end <count>`. It prints no argument list, writes nothing and changes nothing. Exit 68
  /// for unusable arguments, 66 when no tmux is found, 67 when `list-clients` fails.
  public static let remoteScript: StaticShellScript =
    TmuxLocator.script
      + #"""
      unset TMUX TMUX_PANE
      PATH=${PATH:-/usr/bin:/bin}:/usr/bin:/bin
      export PATH
      if [ "$#" -ne 3 ]; then exit 68; fi
      case $2 in '$'[0-9]*) ;; *) exit 68 ;; esac
      case ${2#?} in '' | *[!0-9]*) exit 68 ;; esac
      case $3 in '' | *[!0-9a-f-]*) exit 68 ;; esac
      if [ "${#3}" -ne 36 ]; then exit 68; fi
      sid=$2
      tok=$3
      muxfinder_locate_tmux "$1"
      if [ -z "$t" ]; then exit 66; fi
      all=$("$t" -u list-clients -F '#{session_id} #{client_pid} #{client_created} #{client_name}' </dev/null 2>/dev/null) || exit 67
      printf '%s\n' "$all" | {
        n=0
        while read -r s p c m; do
          [ "$s" = "$sid" ] || continue
          r=other
          case $p in
            '' | *[!0-9]*) ;;
            *)
              q=$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')
              case $q in
                '' | *[!0-9]*) ;;
                *)
                  a=$(ps -ww -o args= -p "$q" 2>/dev/null)
                  a=${a%"${a##*[! ]}"}
                  case $a in *" $tok") r=match ;; esac
                  ;;
              esac
              ;;
          esac
          printf '%s %s %s %s\n' "$r" "$p" "$c" "$m"
          n=$((n + 1))
        done
        printf 'end %s\n' "$n"
      }

      """#

  /// The remote reading's positional parameters: the host's tmux override (empty when it has
  /// none), the session id and the launch token.
  public static func remoteArguments(
    tmuxPathOverride: String?,
    sessionID: TmuxSessionID,
    token: LaunchToken
  ) -> [String] {
    [tmuxPathOverride ?? "", sessionID.rawValue, token.rawValue]
  }

  /// Reads `remoteScript`'s output: every line `match` or `other`, a space and a client
  /// `OtherClient` accepts (`<pid> <created> <name>`), then exactly one last line `end <n>`
  /// with `n` the number of client lines. `nil` for anything else (a cut-off answer, a bad
  /// value): an unreadable answer confirms nothing.
  public static func remote(output: String) -> Reading? {
    guard var lines = lines(of: output), let last = lines.popLast(), last.hasPrefix("end "),
      let count = ConnectionIdentity.canonicalInteger(String(last.dropFirst(4)), as: Int.self),
      count == lines.count
    else { return nil }
    var reading = Reading(clients: [], candidates: [])
    for line in lines {
      let fields = line.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 4, fields[0] == "match" || fields[0] == "other",
        let client = OtherClient(processID: fields[1], created: fields[2], name: fields[3])
      else { return nil }
      reading.clients.append(client)
      if fields[0] == "match" { reading.candidates.append(client) }
    } // End of loop over the client lines
    return reading
  } // End of static func remote(output:)

  /// `text` split into lines without its final line break; `[]` for empty text; `nil` when it
  /// holds a NUL or a carriage return.
  static func lines(of text: String) -> [String]? {
    guard !text.utf8.contains(0), !text.utf8.contains(0x0D) else { return nil }
    var body = Substring(text)
    if body.last == "\n" { body.removeLast() }
    if body.isEmpty { return [] }
    return body.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }
} // End of enum PlainClientIdentification
