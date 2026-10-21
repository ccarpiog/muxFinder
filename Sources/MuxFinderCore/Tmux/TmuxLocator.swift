import Foundation

/// How muxFinder finds the tmux executable on a host (PLAN.md D5).
///
/// Locating runs on the target host, inside the static scripts muxFinder sends there, because
/// only the host itself knows its file system and `PATH` (noninteractive SSH on macOS has just
/// `/usr/bin:/bin:/usr/sbin:/sbin`, which misses Homebrew). The rules:
///
/// 1. An explicit override is used alone. If it is not an executable file, or does not answer
///    `-V` like tmux, the host reports "tmux not found"; there is no fallback to another tmux.
/// 2. Otherwise the first executable file in `candidatePaths`.
/// 3. Otherwise `command -v tmux`, if it names an absolute path.
///
/// A found file must print a first `-V` line starting with `tmux `, so a wrong override never
/// gets tmux arguments.
public enum TmuxLocator {
  /// The fixed places checked when no override is set, in order: Homebrew on Apple Silicon,
  /// Homebrew on Intel (and manual installs), MacPorts, the system.
  public static let candidatePaths = [
    "/opt/homebrew/bin/tmux",
    "/usr/local/bin/tmux",
    "/opt/local/bin/tmux",
    "/usr/bin/tmux",
  ]

  /// A POSIX `sh` fragment defining `muxfinder_locate_tmux [override]`.
  ///
  /// After the call, `t` holds the tmux path to use (empty when none was found) and `v` the
  /// first line of its `-V` output, cut to 200 bytes before the line is looked for, so an
  /// override that prints one endless line cannot grow the shell. Callers pass the override as
  /// `"${1-}"`; it is data, never shell source. The candidate list must match `candidatePaths`
  /// (a unit test checks it).
  public static let script: StaticShellScript = #"""
    muxfinder_locate_tmux() {
      t=
      if [ -n "$1" ]; then
        if [ -f "$1" ] && [ -x "$1" ]; then t=$1; fi
      else
        for c in /opt/homebrew/bin/tmux /usr/local/bin/tmux /opt/local/bin/tmux /usr/bin/tmux; do
          if [ -f "$c" ] && [ -x "$c" ]; then
            t=$c
            break
          fi
        done
        if [ -z "$t" ]; then
          c=$(command -v tmux 2>/dev/null) || c=
          case $c in
            /*) if [ -f "$c" ] && [ -x "$c" ]; then t=$c; fi ;;
          esac
        fi
      fi
      v=
      if [ -n "$t" ]; then
        v=$("$t" -V </dev/null 2>/dev/null | head -c 200 | head -n 1)
        case $v in
          'tmux '*) ;;
          *) t= ;;
        esac
      fi
    }

    """#
}
