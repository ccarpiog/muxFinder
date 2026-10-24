import Foundation
import os

@testable import MuxFinderCore

/// Builds discovery reports line by line, valid by default, so each test can break exactly one
/// thing. Line numbers of a default report with one session and one client: header 1, nonce 2,
/// host 3, tmux 4, version 5, session 6, sessions-exit 7, sessions-stderr 8, client 9,
/// clients-exit 10, clients-stderr 11, end 12.
enum ReportBuilder {
  /// The nonce used by built reports.
  static let nonce = "0123456789abcdef"

  /// A `session` line; every field can be replaced.
  static func session(
    id: String = "$0",
    created: String = "1792600000",
    windows: String = "1",
    attached: String = "0",
    activity: String = "1792600100",
    pid: String = "4242",
    startTime: String = "1792599999",
    socketPath: String = "/private/tmp/tmux-501/default",
    name: String = "name",
    nonce: String = ReportBuilder.nonce
  ) -> String {
    [
      "session", nonce, id, created, windows, attached, activity, pid, startTime, socketPath,
      name,
    ].joined(separator: "\t")
  } // End of func session(id:created:…)

  /// A `path` record (PLAN.md D31): tag, nonce, session id, the path, and `end` (the nonce by
  /// default) as its end mark. A line break in `path` makes it span lines, as tmux prints it.
  static func path(
    _ path: String,
    id: String = "$0",
    nonce: String = ReportBuilder.nonce,
    end: String? = nil
  ) -> String {
    ["path", nonce, id, path, end ?? nonce].joined(separator: "\t")
  }

  /// A `client` line; every field can be replaced.
  static func client(
    session: String = "$0",
    controlMode: String = "0",
    pid: String = "5000",
    nonce: String = ReportBuilder.nonce
  ) -> String {
    ["client", nonce, session, controlMode, pid].joined(separator: "\t")
  }

  /// The lines of a report. `clients == nil` leaves the client section out (as the probe does
  /// when `list-sessions` fails).
  static func lines(
    header: String = ProbeReportParser.header,
    nonce: String = ReportBuilder.nonce,
    sessions: [String] = [session()],
    sessionsExit: String = "0",
    sessionsStderr: String = "",
    clients: [String]? = [client()],
    end: String? = nil
  ) -> [String] {
    var lines = [
      header, "nonce\t\(nonce)", "host\tSynthetic-Host.local", "tmux\t/opt/homebrew/bin/tmux",
      "version\ttmux 3.8",
    ]
    lines += sessions
    lines += ["sessions-exit\t\(sessionsExit)", "sessions-stderr\t\(sessionsStderr)"]
    if let clients {
      lines += clients
      lines += ["clients-exit\t0", "clients-stderr\t"]
    }
    lines.append("end\t\(end ?? nonce)")
    return lines
  } // End of func lines(header:nonce:sessions:sessionsExit:sessionsStderr:clients:end:)

  /// `lines` joined into report bytes, each line newline-terminated.
  static func data(_ lines: [String]) -> Data {
    Data(lines.map { $0 + "\n" }.joined().utf8)
  }

  /// A default report with the given changes, as bytes.
  static func report(
    header: String = ProbeReportParser.header,
    nonce: String = ReportBuilder.nonce,
    sessions: [String] = [session()],
    sessionsExit: String = "0",
    sessionsStderr: String = "",
    clients: [String]? = [client()],
    end: String? = nil
  ) -> Data {
    data(
      lines(
        header: header,
        nonce: nonce,
        sessions: sessions,
        sessionsExit: sessionsExit,
        sessionsStderr: sessionsStderr,
        clients: clients,
        end: end
      )
    )
  } // End of func report(header:nonce:sessions:sessionsExit:sessionsStderr:clients:end:)
}

/// A `ProcessRunner` that records requests and returns a canned result or error.
final class FakeProcessRunner: ProcessRunner {
  /// What `run(_:)` does.
  enum Behavior: Sendable {
    /// Return this result.
    case result(ProcessResult)
    /// Throw this error.
    case error(any Error)
  }

  /// The canned behavior.
  let behavior: Behavior
  /// Requests received so far.
  private let received = OSAllocatedUnfairLock<[ProcessRequest]>(initialState: [])

  /// Creates a fake with the given behavior.
  init(_ behavior: Behavior) {
    self.behavior = behavior
  }

  /// A fake that exits 0 with `stdout`.
  convenience init(stdout: Data) {
    self.init(.result(ProcessResult(processID: 1, termination: .exited(0), standardOutput: stdout)))
  }

  /// The requests received so far.
  var requests: [ProcessRequest] { received.withLock { $0 } }

  /// Records `request` and plays the behavior.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    received.withLock { $0.append(request) }
    switch behavior {
    case .result(let result): return result
    case .error(let error): throw error
    }
  }
}

/// Shorthand for a session id that is known to be valid.
func sessionID(_ raw: String) -> TmuxSessionID {
  TmuxSessionID(raw)!
}

/// A fake `tmux` for running the real probe script without tmux. Its behavior comes from the
/// environment variable `MUXFINDER_FAKE_MODE`:
///
/// - `sessions` (default): two sessions (`$0` "plain", `$7` with shell metacharacters and a tab
///   in its name) and one control client on `$0`.
/// - `no-server`, `noisy` (escape sequence, tab and UTF-8 in the first stderr line, plus a
///   second line), `long-stderr` (5,000 bytes): `list-sessions` fails like that.
/// - `flood-stderr`: `list-sessions` writes `flood <ESC>[1m`, 8 MiB of `x` on the same line and
///   a second line to stderr, then exits 3.
/// - `clients-fail`: `list-clients` fails with "lost server".
/// - `not-tmux`: `-V` does not answer like tmux.
/// - `endless-version`: `-V` prints `tmux 9.9-` followed by an endless line of `x` (it stops
///   only when its reader goes away); listings behave like `sessions`.
/// - `hang`: `list-sessions` sleeps for 30 s.
/// - `hang-pids`: `list-sessions` starts `sleep 30` in the background, writes its own pid and
///   that child's pid (`<pid> <child pid>` and a newline) to the file named by
///   `MUXFINDER_FAKE_PIDFILE`, and waits for the child.
/// - `many-paths`: a report at the parser's limits (PLAN.md D31): 1,000 sessions `$0`…`$999`,
///   each line exactly 4,096 bytes (a long name of `n`), each followed by its path record with
///   the longest folder kept (`/` and 4,095 `x`), except `$999`, whose record is empty, as tmux
///   prints a folder over 4,096 bytes; and 1,000 clients, one per session.
///
/// It fails with exit 98 if `TMUX` or `TMUX_PANE` reached it, and 99 if `-u` is missing. Records
/// are printed after the literal prefix of the `-F` format (tag and nonce), the way real tmux
/// expands it. When the `list-sessions` format holds a line break (the probe's `path` record,
/// PLAN.md D31), each session line is followed by its path record, framed by the literal prefix
/// and suffix the format gives it: `$0` starts in `/Users/example/projects/site`, and `$7`'s
/// path holds a line break and a forged `sessions-exit` line (the parser drops it).
let fakeTmuxScript = #"""
  #!/bin/sh
  mode=${MUXFINDER_FAKE_MODE:-sessions}
  if [ "$1" = -V ]; then
    case $mode in
      not-tmux) echo "fake 1.0" ;;
      endless-version) printf 'tmux 9.9-'; yes x | tr -d '\n' ;;
      *) echo "tmux 9.9-fake" ;;
    esac
    exit 0
  fi
  if [ -n "${TMUX-}" ] || [ -n "${TMUX_PANE-}" ]; then echo "TMUX leaked" >&2; exit 98; fi
  if [ "$1" != -u ]; then echo "missing -u" >&2; exit 99; fi
  prefix=${4%%#\{*}
  nl='
  '
  pprefix=
  psuffix=
  case ${4-} in
    *"$nl"*) rest=${4#*"$nl"}; pprefix=${rest%%#\{*}; psuffix=${rest##*\}} ;;
  esac
  case "$mode:$2" in
    hang:list-sessions) sleep 30 ;;
    hang-pids:list-sessions)
      sleep 30 &
      printf '%s %s\n' "$$" "$!" > "$MUXFINDER_FAKE_PIDFILE"
      wait ;;
    no-server:list-sessions)
      echo "no server running on /private/tmp/tmux-501/default" >&2; exit 1 ;;
    noisy:list-sessions)
      printf 'bad \033[31mthing\t\303\274 here\nsecond line\n' >&2; exit 1 ;;
    long-stderr:list-sessions)
      i=0
      while [ $i -lt 50 ]; do
        printf '%s' xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx >&2
        i=$((i + 1))
      done
      exit 1 ;;
    flood-stderr:list-sessions)
      printf 'flood \033[1m' >&2
      dd if=/dev/zero bs=1048576 count=8 2>/dev/null | LC_ALL=C tr '\0' x >&2
      printf '\nsecond line\n' >&2
      exit 3 ;;
    many-paths:list-sessions)
      tab=$(printf '\t')
      fixed="${tab}1700000000${tab}1${tab}1${tab}1700000100${tab}4242${tab}1699999999"
      fixed="$fixed${tab}/private/tmp/tmux-501/default${tab}"
      room=$((4096 - ${#prefix} - ${#fixed}))
      name=$(printf "%${room}s" '' | tr ' ' n)
      folder=/$(printf '%4095s' '' | tr ' ' x)
      i=0
      while [ $i -lt 1000 ]; do
        case $i in
          ?) cut=${name#??} ;;
          ??) cut=${name#???} ;;
          *) cut=${name#????} ;;
        esac
        [ $i -lt 999 ] || folder=
        printf '%s$%s%s%s\n' "$prefix" "$i" "$fixed" "$cut"
        printf '%s$%s\t%s%s\n' "$pprefix" "$i" "$folder" "$psuffix"
        i=$((i + 1))
      done # End of loop over the sessions
      ;;
    many-paths:list-clients)
      i=0
      while [ $i -lt 1000 ]; do
        printf '%s$%s\t1\t%s\n' "$prefix" "$i" "$((5000 + i))"
        i=$((i + 1))
      done ;;
    *:list-sessions)
      printf '%s$0\t1700000000\t2\t1\t1700000100\t4242\t1699999999\t/private/tmp/tmux-501/default\tplain\n' "$prefix"
      if [ -n "$pprefix" ]; then printf '%s$0\t/Users/example/projects/site%s\n' "$pprefix" "$psuffix"; fi
      printf '%s$7\t1700000001\t1\t0\t1700000101\t4242\t1699999999\t/private/tmp/tmux-501/default\ta;rm -rf ~ $(touch x) "q" \047q\047\tend\n' "$prefix"
      if [ -n "$pprefix" ]; then printf '%s$7\t/x\nsessions-exit\t0%s\n' "$pprefix" "$psuffix"; fi ;;
    clients-fail:list-clients) echo "lost server" >&2; exit 1 ;;
    *:list-clients) printf '%s$0\t1\t5151\n' "$prefix" ;;
    *) echo "unexpected call" >&2; exit 97 ;;
  esac
  """#

/// Writes `fakeTmuxScript` as an executable `tmux` into a new directory named `directoryName`
/// under `parent`, and returns the executable's path.
func installFakeTmux(in parent: URL, directoryName: String = "bin") throws -> String {
  let directory = parent.appending(path: directoryName, directoryHint: .isDirectory)
  try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  let executable = directory.appending(path: "tmux")
  try Data(fakeTmuxScript.utf8).write(to: executable)
  try FileManager.default.setAttributes(
    [.posixPermissions: 0o755],
    ofItemAtPath: executable.path(percentEncoded: false)
  )
  return executable.path(percentEncoded: false)
} // End of func installFakeTmux(in:directoryName:)
