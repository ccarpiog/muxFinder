import Darwin
import Foundation

/// The guard: a static `/bin/sh` script the helper runs as its **check** child right before
/// attaching. It locates tmux, repeats the D4 identity check and, on success, prints the tmux
/// path it used (PLAN.md D4, D5, D12, D14). The **attach** child, `tmux -u -CC attach-session
/// -t <id>`, is spawned by the helper itself from that path (`attachArguments(for:)`), never
/// through a shell.
///
/// The check runs locally as `/bin/sh -c <script> muxfinder <override> <id> <pid> <start>
/// <created>`, data only as argv (D3): never a login shell, never string-built source.
/// `<override>` is empty when the host has none. The helper runs it with piped output, in its
/// own process group and with a hard deadline (`defaultTimeout`), so a hung tmux server or a
/// passed-on signal ends the whole check (every locator and `display-message` subprocess)
/// together.
///
/// Steps:
/// 1. `TMUX` and `TMUX_PANE` are unset (default server only, D9), and `/usr/bin:/bin` is
///    appended to `PATH`.
/// 2. The arguments are checked (5 of them, a `$N` id, decimal numbers); anything else exits
///    68.
/// 3. tmux is located with `TmuxLocator.script`; none usable exits 66.
/// 4. `tmux -u display-message -p -t <id> '#{session_id}:#{pid}:#{start_time}:#{session_created}'`
///    runs with stdout and stderr merged; at most 300 bytes are kept (the rest is drained) and
///    its real exit status travels on its own descriptor, as in `ProbeScript`.
/// 5. Gone versus other errors, decided deliberately:
///    - tmux failed with `no server running on …` (stale socket) or `error connecting to …
///      (No such file or directory)` (no socket): no server, so the session is **gone** (64).
///      `can't find session` counts as gone too, should a tmux resolve the target strictly.
///    - tmux failed with anything else (permission denied on the socket, protocol mismatch, …):
///      **check failed** (67); its first line goes to stderr as `tmux: …`, printable ASCII.
///    - tmux succeeded: `display-message` resolves `-t` leniently, so in tmux 3.8 a missing id
///      prints the server fields with an empty session (`:<pid>:<start>:`) and exits 0
///      (verified 2026-10-21). The first output line decides: exactly
///      `<id>:<pid>:<start>:<created>` is a match; `<id>:` with other values means the id now
///      belongs to another server or session, **changed** (65); an empty or different session
///      id means **gone** (64); any other shape is **check failed** (67).
/// 6. A match prints the tmux path and a newline on stdout and exits 0. The helper accepts it
///    only through `tmuxPath(fromCheckOutput:request:)`.
///
/// A session that disappears between the check and the attach makes tmux exit 1, which the
/// helper reports as `childExited(1)`.
public enum LaunchGuard {
  /// The shell that runs the check.
  public static let shellPath = "/bin/sh"

  /// The check's hard deadline in production. tmux answers `display-message` in milliseconds,
  /// so this only ends a check whose server or file system hangs.
  public static let defaultTimeout: Duration = .seconds(10)

  /// The most output kept from each of the check's stdout and stderr.
  public static let outputLimit = 4096

  /// The format the guard asks `display-message` for (PLAN.md D4).
  public static let identityFormat = "#{session_id}:#{pid}:#{start_time}:#{session_created}"

  /// The identity check after the locator fragment (steps 1–5), shared with the remote attach
  /// (`RemoteLaunch.script`, PLAN.md D17): on a match it falls through with `t` holding the
  /// tmux path and `id` the session id; every refusal exits with the guard's code. The format
  /// literal must match `identityFormat` (a unit test checks it).
  static let check: StaticShellScript = #"""
    unset TMUX TMUX_PANE
    PATH=${PATH:-/usr/bin:/bin}:/usr/bin:/bin
    export PATH
    if [ "$#" -ne 5 ]; then exit 68; fi
    case $2 in '$'[0-9]*) ;; *) exit 68 ;; esac
    for n in "${2#?}" "$3" "$4" "$5"; do
      case $n in '' | *[!0-9]*) exit 68 ;; esac
    done
    id=$2
    e="$id:$3:$4:$5"
    muxfinder_locate_tmux "$1"
    if [ -z "$t" ]; then exit 66; fi
    f='#{session_id}:#{pid}:#{start_time}:#{session_created}'
    r=$(
      exec 4>&1
      { { "$t" -u display-message -p -t "$id" "$f" </dev/null 2>&1 4>&- 5>&-
          printf '%s\n' "$?" >&5; } |
        { head -c 300; cat >/dev/null; } >&4 5>&-; } 5>&1 |
        { read -r c || c=; exit "${c:-125}"; }
    )
    s=$?
    nl='
    '
    l=${r%%"$nl"*}
    if [ "$s" != 0 ]; then
      case $r in
        *"no server running on "* | *"can't find session"*) exit 64 ;;
        *"error connecting to "*"(No such file or directory)"*) exit 64 ;;
      esac
      if [ -n "$l" ]; then
        printf 'tmux: %s\n' "$(printf '%s' "$l" | LC_ALL=C tr -c ' -~' '?' | LC_ALL=C cut -c 1-200)" >&2
      fi
      exit 67
    fi
    case $l in
      "$e") ;;
      "$id:"*) exit 65 ;;
      : | :* | '$'[0-9]*:*) exit 64 ;;
      *)
        printf 'tmux: unexpected answer to the session check\n' >&2
        exit 67
        ;;
    esac

    """#

  /// The local check's last step (6): print the tmux path the helper spawns.
  static let printPath: StaticShellScript = #"""
    printf '%s\n' "$t"

    """#

  /// The script after the locator fragment: the identity check, then the path on a match.
  static let body: StaticShellScript = check + printPath

  /// The complete check: the tmux locator followed by the identity check.
  public static let script: StaticShellScript = TmuxLocator.script + body

  /// The check's positional parameters for `request`, data only: the override (empty when the
  /// host has none), the session id, the server pid and start time, and the creation time. The
  /// remote attach passes the same ones (PLAN.md D17).
  public static func checkArguments(for request: LaunchRequest) -> [String] {
    [
      request.tmuxPathOverride ?? "",
      request.sessionID.rawValue,
      String(request.expectedServerPID),
      String(request.expectedServerStartTime),
      String(request.expectedSessionCreated),
    ]
  } // End of func checkArguments(for:)

  /// The arguments after `/bin/sh` that run the check for `request`.
  public static func arguments(for request: LaunchRequest) -> [String] {
    ["-c", script.source, ShellQuoting.scriptName] + checkArguments(for: request)
  }

  /// The check child for `request`: `/bin/sh` with `arguments(for:)`, `environment`, stdin
  /// `/dev/null`, `timeout` and `outputLimit`.
  public static func checkRequest(
    for request: LaunchRequest,
    environment: [String: String],
    timeout: Duration = defaultTimeout
  ) -> ProcessRequest {
    ProcessRequest(
      executableURL: URL(fileURLWithPath: shellPath),
      arguments: arguments(for: request),
      environment: environment,
      timeout: timeout,
      outputLimit: outputLimit
    )
  } // End of func checkRequest(for:environment:timeout:)

  /// The attach child's arguments after the tmux path: `-u -CC attach-session -t <id>`. D12's
  /// `-u` applies to control mode too, so the formats iTerm2 requests keep UTF-8 and tabs.
  public static func attachArguments(for request: LaunchRequest) -> [String] {
    ["-u", "-CC", "attach-session", "-t", request.sessionID.rawValue]
  }

  /// The tmux path a successful check printed, or `nil` if the output is not usable.
  ///
  /// The output must be exactly one line: valid UTF-8, an absolute path without NUL or line
  /// breaks, then a newline. With an override it must be the override itself (D5 uses an
  /// override alone). The path must name a regular executable file now (symbolic links are
  /// followed, as Homebrew's `tmux` is one). The D2 character rule does not apply: the path is
  /// spawned as argv, never parsed by a shell.
  public static func tmuxPath(fromCheckOutput output: Data, request: LaunchRequest) -> String? {
    guard output.last == 0x0A, let text = String(data: output.dropLast(), encoding: .utf8),
      text.hasPrefix("/"), !text.utf8.contains(where: { $0 == 0 || $0 == 0x0A || $0 == 0x0D })
    else { return nil }
    if let override = request.tmuxPathOverride, override != text { return nil }
    var info = stat()
    guard stat(text, &info) == 0, info.st_mode & S_IFMT == S_IFREG, access(text, X_OK) == 0
    else { return nil }
    return text
  } // End of func tmuxPath(fromCheckOutput:request:)
}
