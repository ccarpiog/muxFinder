import Foundation

/// The static folder-search script (PLAN.md D36): one POSIX `sh` script, run on This Mac as
/// `/bin/sh -c <script> muxfinder unchecked` by argv and on SSH hosts through the D3 command
/// string, with no argument. Spotlight runs on the host itself (`mdfind`), so the host needs no
/// muxFinder. Its one optional argument is fixed, never a runtime value: `unchecked`
/// (`uncheckedArgument`, This Mac's, Phase I-10b) turns the readability checks off, so the
/// header says `unchecked` for each protected folder and the script looks at none of them (on
/// This Mac an `ls` of `~/Documents` would run as muxFinder's child and could make macOS ask the
/// user for access); any other argument is ignored.
///
/// It is read-only: it runs `mdfind`, `mdutil -s`, `df -P`, `ls` (output discarded), `sleep`
/// and text tools (`tail`, `wc`, `xargs`), resolved through `PATH` as it comes (the
/// noninteractive SSH `PATH`, which holds `/usr/bin`; This Mac's transport sets the same), and
/// writes no file. Every record it writes ends with a NUL byte. It first writes the header,
/// once:
///
/// ```
/// muxfinder-folders 1
/// home <$HOME without a trailing slash; empty when it is not an absolute path>
/// mdfind yes|no                       (whether `command -v mdfind` finds it)
/// index home on|off|unknown           (`mdutil -s` of the volume `df -P "$HOME"` names)
/// index disk on|off|unknown           (`mdutil -s /`)
/// readable Desktop yes|no|missing|unchecked  (`ls` of the folder succeeds: TCC, then
///                                             permissions; `unchecked` with the argument)
/// readable Documents yes|no|missing|unchecked
/// readable Downloads yes|no|missing|unchecked
/// ready
/// ```
///
/// Then it reads query lines from standard input until end of input (closing it ends the
/// script). A line is `<id> <scope> <name text>`: `id` decimal digits (at most 18), `scope`
/// `home` or `disk`, and the name text as `FolderSearchText` escapes it (1 to 512 bytes, no
/// control character, `\`, `"`, `*` and `?` only escaped with a backslash). A line without a
/// usable id is skipped; any other malformed line gets an error answer. For a good line the
/// script builds the one fixed predicate itself,
/// `kMDItemContentType == "public.folder" && kMDItemFSName == "*<name text>*"cd`, and passes it
/// to `mdfind -0` as one quoted argument (after `-onlyin "$HOME"` for `home`); no `eval`, so
/// the channel can ask nothing but this folder-name question. Its answer is the kept paths
/// (each starts with `/`), then one end record, which never starts with `/`:
///
/// ```
/// end <id> ok <count>                 (count: the paths written, at most 50)
/// end <id> limited 50                 (more than 50 were kept; mdfind was stopped)
/// end <id> error <code>               (malformed, scope, length, text, unavailable, home,
///                                      search, timeout)
/// ```
///
/// **The noise rule** (fixed; `f` below): a folder is left out when (a) it is the home's
/// `Library` or below it, and with `disk` also any `/Users/<name>/Library` and below and the
/// system roots `/System`, `/Library`, `/private`, `/usr`, `/bin`, `/sbin`, `/opt`, `/cores`,
/// `/dev` and below; (b) any component of its path starts with `.`; (c) any component is
/// `node_modules`, `DerivedData`, `Pods` or `__pycache__`; (d) any component but the last ends
/// in `.app`, `.framework`, `.bundle`, `.plugin`, `.kext`, `.photoslibrary`, `.xcodeproj`,
/// `.xcworkspace` or `.xcassets`. `case` patterns match the whole path, and `*` in them matches
/// `/` too, so `/Users/<name>/Library` strips the first two components before it compares.
///
/// **The pipeline** for one query, three stages (the filter and the answer stage in the C
/// locale, `mdfind` in the one the script got):
///
/// 1. **The producer** `sh -c "$k"` (its own process, so `$$` is its pid) writes `@<its pid>`
///    first, starts a timer and `mdfind -0 …` in the background and waits for `mdfind`. Then
///    it writes the status marker `!<mdfind's exit status>` after every path, or, when the
///    timer fired first (`searchDeadline`, 4 s), kills `mdfind` (SIGKILL), reaps it and writes
///    `\0!timeout` (the NUL ends a record `mdfind` may have left unfinished). It closes its
///    output and waits at most `answerSignalWait` (1 s) for the answer stage's SIGTERM; a
///    SIGTERM that comes while `mdfind` runs makes it kill and reap `mdfind` and end at once,
///    writing nothing more. Its timers are reaped before it exits.
/// 2. **The filter** `xargs -0 -n 256 sh -c "$f"`: the noise rule; records that do not start
///    with `/` (`@…`, `!…`) pass through. It ends at the end of its input.
/// 3. **The answer stage** `xargs -0 -n 52 sh -c "$g"`: `g` runs once, as soon as 52 records
///    are in (`@<pid>` and 51 kept paths, the limit, or 50 and the marker) or at the end of its
///    input. It first sends the producer SIGTERM (stopping `mdfind` when the limit was reached,
///    releasing the producer otherwise; the producer waits for this signal, so the pid still
///    names it), then
///    writes at most 50 paths and the end record (`limited` when a 51st was kept, `ok` for
///    marker `0`, `error timeout`, else `error search`) and exits 255, which stops `xargs`
///    reading. Once `mdfind` is gone, the filter reaches the end of its input, and its writes
///    after that fail; the script reads the next line only after all three stages ended.
///
/// The script writes `error search` itself only when `xargs` ran no `g` (exit 0: nothing
/// reached it). After a disconnect (standard input at its end, standard output gone), a query
/// still running ends at the deadline at the latest: `g`'s first write fails, the script's next
/// read finds the end of input, and nothing of the query is left. `xargs -0` drops empty
/// records; `xargs -x` is not used: on macOS it runs one argument per invocation (verified,
/// D36).
public enum FolderSearchScript {
  /// The format version in the header's first record.
  public static let formatVersion = 1
  /// The most paths one answer holds.
  public static let resultLimit = 50
  /// The most bytes of name text the script takes (`FolderSearchText` escapes at most 255
  /// bytes into at most 510).
  public static let maximumNameTextLength = 512
  /// The most decimal digits an id may have.
  public static let maximumIDDigits = 18
  /// How long `mdfind` may run for one query before the script kills it and answers `error
  /// timeout` (the script's `u 4`); below the channel's 5 s answer wait, so the host's answer
  /// comes first and the process stays usable.
  public static let searchDeadline: Duration = .seconds(4)
  /// How long the producer waits, after its last record, for the answer stage's signal (the
  /// script's `u 1`); it bounds the producer's life when the answer stage never runs.
  public static let answerSignalWait: Duration = .seconds(1)
  /// The script's fixed argument that turns the readability checks off (This Mac's transport
  /// passes it, PLAN.md Phase I-10b): the header then reports every protected folder as
  /// `unchecked` and nothing looks at them.
  public static let uncheckedArgument = "unchecked"

  /// The script.
  public static let script: StaticShellScript = #"""
    PATH=${PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
    export PATH
    c=
    if [ "${1-}" = unchecked ]; then c=1; fi
    k='z=
    y=
    t=
    trap "z=1" HUP INT TERM
    trap "y=1" USR1
    u() {
      (
        s=
        trap "kill \$s 2>/dev/null; exit 0" TERM
        sleep "$1" &
        s=$!
        wait "$s" && kill -USR1 "$$"
      ) </dev/null >/dev/null 2>&1 &
      t=$!
    }
    v() {
      kill -TERM "$t" 2>/dev/null
      wait "$t"
    }
    printf "@%s\000" "$$" || exit 0
    u 4
    mdfind -0 "$@" </dev/null 2>/dev/null &
    w=$!
    wait "$w"
    c=$?
    if [ -n "$z$y" ]; then
      kill -KILL "$w" 2>/dev/null
      wait "$w"
    fi
    v
    if [ -n "$z" ]; then exit 0; fi
    if [ -n "$y" ]; then
      printf "\000!timeout\000" || exit 0
    else
      printf "!%s\000" "$c" || exit 0
    fi
    exec >/dev/null
    u 1
    [ -n "$z" ] || wait "$t"
    v'
    f='s=$1; h=$2; shift 2
    for p do
      case $p in
        /*) ;;
        *) printf "%s\000" "$p"; continue ;;
      esac
      case $p in
        */.*) continue ;;
        */node_modules|*/node_modules/*|*/DerivedData|*/DerivedData/*) continue ;;
        */Pods|*/Pods/*|*/__pycache__|*/__pycache__/*) continue ;;
        *.app/*|*.framework/*|*.bundle/*|*.plugin/*|*.kext/*) continue ;;
        *.photoslibrary/*|*.xcodeproj/*|*.xcworkspace/*|*.xcassets/*) continue ;;
      esac
      if [ -n "$h" ]; then
        case $p in
          "$h"/Library|"$h"/Library/*) continue ;;
        esac
      fi
      if [ "$s" = disk ]; then
        case $p in
          /System|/System/*|/Library|/Library/*|/private|/private/*|/usr|/usr/*) continue ;;
          /bin|/bin/*|/sbin|/sbin/*|/opt|/opt/*|/cores|/cores/*|/dev|/dev/*) continue ;;
          /Users/*/*)
            r=${p#/Users/}
            r=${r#*/}
            case $r in
              Library|Library/*) continue ;;
            esac
            ;;
        esac
      fi
      printf "%s\000" "$p"
    done'
    g='i=$1; shift; n=0; t=; k=
    for a do
      case $a in
        /*) n=$((n + 1)) ;;
        @*) k=${a#@} ;;
        !*) t=${a#!} ;;
      esac
    done
    case $k in
      "" | *[!0-9]*) ;;
      *) kill -TERM "$k" 2>/dev/null ;;
    esac
    m=0
    for a do
      case $a in
        /*)
          m=$((m + 1))
          if [ "$m" -gt 50 ]; then break; fi
          printf "%s\000" "$a" || exit 1
          ;;
      esac
    done
    if [ "$n" -gt 50 ]; then
      r="limited 50"
    elif [ "$t" = 0 ]; then
      r="ok $n"
    elif [ "$t" = timeout ]; then
      r="error timeout"
    else
      r="error search"
    fi
    printf "end %s %s\000" "$i" "$r" || exit 1
    exit 255'
    e() {
      printf 'end %s error %s\000' "$i" "$1" || exit 0
    }
    x() {
      if [ -z "$1" ] || ! command -v mdutil >/dev/null 2>&1; then
        echo unknown
        return
      fi
      o=$(mdutil -s "$1" 2>&1 </dev/null)
      case $o in
        *'Indexing enabled'*) echo on ;;
        *disabled*) echo off ;;
        *) echo unknown ;;
      esac
    }
    h=${HOME-}
    case $h in
      /?*/) h=${h%/} ;;
    esac
    case $h in
      /*) ;;
      *) h= ;;
    esac
    if command -v mdfind >/dev/null 2>&1; then m=yes; else m=no; fi
    v=
    if [ -n "$h" ]; then
      l=$(df -P "$h" 2>/dev/null </dev/null | tail -n 1)
      r=${l#*[0-9]% }
      r=${r#"${r%%[! ]*}"}
      case $r in
        /*) v=$r ;;
      esac
    fi
    printf 'muxfinder-folders 1\000'
    printf 'home %s\000' "$h"
    printf 'mdfind %s\000' "$m"
    printf 'index home %s\000' "$(x "$v")"
    printf 'index disk %s\000' "$(x /)"
    for d in Desktop Documents Downloads; do
      if [ -n "$c" ]; then
        r=unchecked
      elif [ -z "$h" ] || [ ! -d "$h/$d" ]; then
        r=missing
      elif ls "$h/$d" >/dev/null 2>&1 </dev/null; then
        r=yes
      else
        r=no
      fi
      printf 'readable %s %s\000' "$d" "$r"
    done
    printf 'ready\000' || exit 0
    while IFS= read -r l; do
      i=${l%% *}
      case $i in
        '' | *[!0-9]*) continue ;;
      esac
      if [ "${#i}" -gt 18 ]; then continue; fi
      case $l in
        *' '*' '*) ;;
        *)
          e malformed
          continue
          ;;
      esac
      r=${l#* }
      s=${r%% *}
      q=${r#* }
      case $s in
        home | disk) ;;
        *)
          e scope
          continue
          ;;
      esac
      n=$(printf '%s' "$q" | wc -c)
      n=$((n + 0))
      if [ "$n" -eq 0 ] || [ "$n" -gt 512 ]; then
        e length
        continue
      fi
      case $q in
        *[[:cntrl:]]*)
          e text
          continue
          ;;
      esac
      t=$q
      b=
      while :; do
        case $t in
          *[\\\"*?]*) ;;
          *) break ;;
        esac
        t=${t#"${t%%[\\\"*?]*}"}
        case $t in
          \\[\\\"*?]*) t=${t#??} ;;
          *)
            b=1
            break
            ;;
        esac
      done
      if [ -n "$b" ]; then
        e text
        continue
      fi
      if [ "$m" = no ]; then
        e unavailable
        continue
      fi
      p="kMDItemContentType == \"public.folder\" && kMDItemFSName == \"*$q*\"cd"
      if [ "$s" = home ]; then
        if [ -z "$h" ]; then
          e home
          continue
        fi
        set -- -onlyin "$h" "$p"
      else
        set -- "$p"
      fi
      /bin/sh -c "$k" muxfinder "$@" 2>/dev/null \
        | LC_ALL=C xargs -0 -n 256 /bin/sh -c "$f" muxfinder "$s" "$h" 2>/dev/null \
        | LC_ALL=C xargs -0 -n 52 /bin/sh -c "$g" muxfinder "$i" 2>/dev/null
      if [ "$?" -eq 0 ]; then e search; fi
    done

    """#

  /// The query line for query `id`: `<id> <scope> <name text>` and a line feed.
  public static func queryLine(
    id: UInt64, scope: FolderSearchScope, name: FolderSearchNameText
  ) -> Data {
    Data("\(id) \(scope.rawValue) \(name.escaped)\n".utf8)
  }
}
