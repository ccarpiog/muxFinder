import Foundation

/// The static discovery probe: one POSIX `sh` script, run locally as
/// `/bin/sh -c <script> muxfinder [override]` and remotely through the PLAN.md D3 command
/// string. Its only argument is the optional tmux override.
///
/// It is read-only (D6): it runs `tmux -V`, `list-sessions` and `list-clients`, nothing else
/// that talks to tmux. It writes no files itself; tmux creates `$TMUX_TMPDIR/tmux-<uid>` (mode
/// 0700) on any command if that directory is missing. It writes report format 1, one record per
/// line, fields separated by tabs (`\t`):
///
/// ```
/// MUXFINDER-PROBE 1
/// nonce   <16 lowercase hex digits, fresh per run>
/// host    <uname -n, control characters replaced by "?">
/// tmux-not-found                      (then straight to "end")
/// tmux    <path, control characters replaced by "?">
/// version <tmux -V, printable ASCII>
/// session <nonce> <id> <created> <windows> <attached> <activity> <pid> <start_time> <socket_path> <name>
/// path    <nonce> <id> <session_path, empty when over 4,096 bytes> <nonce>   (after its session)
/// sessions-exit   <list-sessions exit status>
/// sessions-stderr <its first stderr line, printable ASCII, at most 200 bytes>
/// client  <nonce> <session_id> <control_mode> <client_pid>   (only when sessions-exit is 0)
/// clients-exit    <list-clients exit status>                 (only when sessions-exit is 0)
/// clients-stderr  <its first stderr line>                    (only when sessions-exit is 0)
/// end     <nonce>
/// ```
///
/// Design notes:
/// - `session_name` is the last field, so tabs in a name can never shift the other fields.
/// - Session and client lines are written by tmux itself from the `-F` formats, which carry the
///   per-run nonce. A session name cannot predict the nonce, so even a name with a line break
///   (impossible in tmux 3.8, which rejects control characters) cannot forge a record; the
///   strict parser rejects any line it does not expect.
/// - Each session's start folder, `#{session_path}`, is a record of its own that the same
///   `list-sessions` format writes right after the session's line (the format holds a line
///   break): `path`, the nonce, the session id, the path, and the nonce again as the record's
///   end mark (PLAN.md D31). tmux stores a `-c` folder as given and prints it raw through
///   `tmux -u`, tabs, line breaks, escape sequences and invalid UTF-8 included (Phase I-2a
///   facts), so the path cannot be framed by the line: the parser takes everything up to the
///   first tab, nonce and line break as the path. A path cannot predict the nonce, so it can
///   neither end its record early nor forge another one (a session, a client, a status line or
///   another path); the parser then drops a path that holds a control character, is not valid
///   UTF-8, is empty or is too long. A report without `path` records (an older probe, a fake)
///   still parses, every folder unknown. Format 1 gained this record in Phase I-2a; the app
///   always sends the script with its parser, so the version did not change.
/// - tmux bounds the path itself: `#{?#{e|>|:#{n:session_path},4096},,#{session_path}}` prints
///   a path longer than 4,096 bytes (`n:` counts bytes, control characters and invalid UTF-8
///   included; `ProbeReportParser.maximumStartDirectoryLength`) as nothing, which the parser
///   drops and counts like any empty path, and never cuts one short, so no truncated path can
///   pass for a real one. Every record is then at most
///   `ProbeReportParser.maximumPathRecordLength` bytes, and the runner's output cap for
///   discovery is the largest report the parser accepts (`ProbeReportParser.maximumReportSize`,
///   `DiscoveryProbe.outputLimit`). The path is the false
///   branch, so a tmux that cannot evaluate the comparison (an empty or `0` result) prints it
///   whole, as before, and the parser's length check still applies; only tmux 3.8 is tested.
/// - tmux runs as `tmux -u` (PLAN.md D12). Without a UTF-8 client flag tmux replaces every
///   non-ASCII byte *and the tab separators* with `_`, and noninteractive SSH from a GUI app
///   usually has no UTF-8 locale.
/// - `TMUX` and `TMUX_PANE` are unset so the default server is always the one listed (D9).
/// - The shell never holds unbounded tmux output, and nothing goes through a file (remote file
///   writes are forbidden). `muxfinder_tmux` runs one listing: its stdout goes straight to the
///   report through file descriptor 3 (bounded by the runner's output cap and the parser's
///   limits), never into a variable. Its stderr passes through `head -c 200` into `r`, and
///   `cat >/dev/null` drains the rest, so a noisy tmux costs no shell memory and never dies of
///   SIGPIPE. The exit status travels on its own pipe (descriptor 5) to a `read` that exits
///   with it (125 if none arrives), which makes it the status of the `r=$(…)` assignment, so
///   `s` is tmux's real status without `pipefail`. Every other captured value is bounded too:
///   8 random bytes, `uname -n`, a path, and the first 200 bytes of `tmux -V`.
public enum ProbeScript {
  /// The report format version written in the header line.
  public static let formatVersion = 1

  /// The script body after the locator fragment.
  static let body: StaticShellScript = #"""
    unset TMUX TMUX_PANE
    PATH=${PATH:-/usr/bin:/bin}:/usr/bin:/bin
    export PATH
    tab=$(printf '\t')
    nl='
    '
    muxfinder_ascii() {
      printf '%s' "$1" | LC_ALL=C tr -c ' -~' '?' | LC_ALL=C cut -c 1-200
    }
    muxfinder_text() {
      printf '%s' "$1" | LC_ALL=C tr '\001-\037\177' '?'
    }
    muxfinder_tmux() {
      r=$(
        exec 4>&1
        { { "$t" -u "$@" </dev/null 2>&1 >&3 3>&- 4>&- 5>&-; printf '%s\n' "$?" >&5; } |
          { head -c 200; cat >/dev/null; } >&4 5>&-; } 5>&1 |
          { read -r e || e=; exit "${e:-125}"; }
      )
      s=$?
    }
    exec 3>&1
    printf 'MUXFINDER-PROBE 1\n'
    n=$(od -A n -N 8 -t x1 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc '0-9a-f')
    printf 'nonce\t%s\n' "$n"
    printf 'host\t%s\n' "$(muxfinder_text "$(uname -n 2>/dev/null)")"
    muxfinder_locate_tmux "${1-}"
    if [ -z "$t" ]; then
      printf 'tmux-not-found\n'
    else
      printf 'tmux\t%s\n' "$(muxfinder_text "$t")"
      printf 'version\t%s\n' "$(muxfinder_ascii "$v")"
      f="session$tab$n$tab#{session_id}$tab#{session_created}$tab#{session_windows}"
      f="$f$tab#{session_attached}$tab#{session_activity}$tab#{pid}$tab#{start_time}"
      f="$f$tab#{socket_path}$tab#{session_name}"
      f="$f${nl}path$tab$n$tab#{session_id}$tab"
      f="$f#{?#{e|>|:#{n:session_path},4096},,#{session_path}}$tab$n"
      muxfinder_tmux list-sessions -F "$f"
      printf 'sessions-exit\t%s\n' "$s"
      printf 'sessions-stderr\t%s\n' "$(muxfinder_ascii "${r%%"$nl"*}")"
      if [ "$s" = 0 ]; then
        f="client$tab$n$tab#{session_id}$tab#{client_control_mode}$tab#{client_pid}"
        muxfinder_tmux list-clients -F "$f"
        printf 'clients-exit\t%s\n' "$s"
        printf 'clients-stderr\t%s\n' "$(muxfinder_ascii "${r%%"$nl"*}")"
      fi
    fi
    printf 'end\t%s\n' "$n"
    exit 0

    """#

  /// The complete probe: the tmux locator followed by the report writer.
  public static let script: StaticShellScript = TmuxLocator.script + body
}
