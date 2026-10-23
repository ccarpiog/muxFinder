# shellcheck shell=bash
# Shared by scripts/install.sh and scripts/uninstall.sh (PLAN.md D27); sourced, never run.
#
# - The app bundle's constants (bundle id, executables, the Info.plist key that says the app
#   binary takes --remove-persistent-profiles).
# - The folders the scripts work on: the real home folder and /Applications, or, for checks
#   only, MUXFINDER_TEST_HOME and MUXFINDER_TEST_APPLICATIONS (both private folders under
#   /private/tmp or /private/var/folders, used by their physical paths); in test mode every
#   path a script derives must lie beneath them with no symbolic link on the way, checked
#   before anything is created, moved or deleted.
# - Finding and stopping the processes of one app copy: a process belongs to a copy when its
#   executable, as the kernel reports it (proc_pidpath, read through codesign -dv <pid>), is
#   that copy's file, matched by device and inode. lsof's txt records only find the candidates:
#   they also list every file a process maps (a Spotlight, QuickLook or backup reader), and
#   ps's comm is argv[0], which may be relative or forged. A process whose executable cannot be
#   established is never signalled. Only SIGTERM is ever sent, once, then a bounded wait;
#   never SIGKILL, killall or Apple events.
# - Deleting a folder: bound to the folder that was inspected. It is renamed into a new hidden
#   folder beside it (one rename, so atomic), its device and inode compared with the ones
#   recorded when it was inspected, and only then deleted; anything else is put back, never
#   deleted.
#
# Written for /bin/bash 3.2. Every expansion is quoted; no eval; nothing builds shell source
# from runtime values.

MF_BUNDLE_ID="cc.carpio.muxfinder"
MF_APP_NAME="muxFinder.app"
MF_APP_EXECUTABLE="Contents/MacOS/muxFinder"
MF_HELPER_EXECUTABLE="Contents/MacOS/muxfinder-launch"
# The value of MuxFinderScriptInterface (scripts/build-app.sh) this script works with.
MF_SCRIPT_INTERFACE="1"
# How long a stopped app may take to quit: longer than the app's own quit deadline (15 s,
# AppModel.terminationDeadline). MUXFINDER_TEST_STOP_WAIT overrides it in test mode only.
MF_STOP_WAIT_SECONDS=20

# Prints its arguments as one line on stdout.
mf_say() {
  printf '%s\n' "$*"
}

# Prints a warning on stderr.
mf_warn() {
  printf 'warning: %s\n' "$*" >&2
}

# Prints an error on stderr.
mf_error() {
  printf 'error: %s\n' "$*" >&2
}

# Exits when run as root: the scripts work on the current user's folders and processes only.
mf_refuse_root() {
  if [ "$(/usr/bin/id -u)" -eq 0 ]; then
    mf_error "run this as your own user, not as root or with sudo."
    exit 2
  fi
}

# Whether the path $1 is the path $2 or lies beneath it (both absolute, physical, no trailing
# slash).
mf_path_within() {
  case "$1/" in
    "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

# Prints the physical path (pwd -P) of the test folder $1 when it is usable as a stand-in: an
# absolute path to an existing folder that is not itself a symbolic link, physically strictly
# beneath /private/tmp or /private/var/folders, owned by the current user, writable by
# neither group nor others, and neither the real home folder ($2, physical), /Applications,
# nor inside the real home (which holds ~/Applications). Returns 1 with a message otherwise.
mf_test_root() {
  local folder="$1" real_home="$2" canonical owner mode
  case "$folder" in
    /?*) ;;
    *)
      mf_error "test folder is not an absolute path: $folder"
      return 1
      ;;
  esac
  if [ -L "$folder" ] || [ ! -d "$folder" ]; then
    mf_error "test folder is not a folder (or is a symbolic link): $folder"
    return 1
  fi
  canonical="$(cd -P -- "$folder" && pwd -P)" || return 1
  case "$canonical" in
    /private/tmp/?* | /private/var/folders/?*) ;;
    *)
      mf_error "test folder must be a private folder under /private/tmp or"
      mf_error "/private/var/folders, not $canonical"
      return 1
      ;;
  esac
  if mf_path_within "$canonical" "$real_home" || mf_path_within "$canonical" "/Applications"; then
    mf_error "test folder must be a private folder, not $canonical (the real home or Applications)"
    return 1
  fi
  owner="$(/usr/bin/stat -f '%u' "$canonical")" || return 1
  mode="$(/usr/bin/stat -f '%Lp' "$canonical")" || return 1
  if [ "$owner" != "$(/usr/bin/id -u)" ]; then
    mf_error "test folder must be a private folder of yours, not $canonical (another owner)"
    return 1
  fi
  case "${mode#"${mode%??}"}" in
    *[2367]*)
      mf_error "test folder must be a private folder, not $canonical (group or others may write)"
      return 1
      ;;
  esac
  printf '%s\n' "$canonical"
} # End of function mf_test_root

# Sets MF_TEST_MODE, MF_HOME and MF_APPLICATIONS: the real home folder and /Applications, or,
# for checks only, the physical paths of MUXFINDER_TEST_HOME and MUXFINDER_TEST_APPLICATIONS,
# which must be set together, each a private folder (mf_test_root), and apart (neither inside
# the other). In test mode MUXFINDER_TEST_STOP_WAIT (1 to 60 seconds) may shorten the stop
# wait, and MUXFINDER_TEST_SWAP_AT and MUXFINDER_TEST_SWAP_WITH (both, beneath the test
# folders) arm mf_test_swap; outside test mode those two are refused. Returns 1 with a message
# when something is unusable.
mf_resolve_roots() {
  local test_home="${MUXFINDER_TEST_HOME:-}"
  local test_applications="${MUXFINDER_TEST_APPLICATIONS:-}"
  local real_home
  if [ -z "$test_home" ] && [ -z "$test_applications" ]; then
    MF_TEST_MODE=0
    MF_HOME="${HOME:-}"
    MF_APPLICATIONS="/Applications"
    if [ -n "${MUXFINDER_TEST_SWAP_AT:-}${MUXFINDER_TEST_SWAP_WITH:-}" ]; then
      mf_error "MUXFINDER_TEST_SWAP_AT and MUXFINDER_TEST_SWAP_WITH are for checks only (with"
      mf_error "the MUXFINDER_TEST_* folders)."
      return 1
    fi
    case "$MF_HOME" in
      /?*) ;;
      *)
        mf_error "HOME is not an absolute path."
        return 1
        ;;
    esac
    if [ ! -d "$MF_HOME" ]; then
      mf_error "HOME is not a folder: $MF_HOME"
      return 1
    fi
    return 0
  fi
  if [ -z "$test_home" ] || [ -z "$test_applications" ]; then
    mf_error "MUXFINDER_TEST_HOME and MUXFINDER_TEST_APPLICATIONS (for checks only) go together."
    return 1
  fi
  case "${HOME:-}" in
    /?*) real_home="$(cd -P -- "$HOME" 2>/dev/null && pwd -P)" || real_home="" ;;
    *) real_home="" ;;
  esac
  if [ -z "$real_home" ]; then
    mf_error "HOME must name your home folder in test mode too (to keep the checks out of it)."
    return 1
  fi
  MF_HOME="$(mf_test_root "$test_home" "$real_home")" || return 1
  MF_APPLICATIONS="$(mf_test_root "$test_applications" "$real_home")" || return 1
  if mf_path_within "$MF_HOME" "$MF_APPLICATIONS" \
    || mf_path_within "$MF_APPLICATIONS" "$MF_HOME"; then
    mf_error "the two test folders must be apart (neither inside the other)."
    return 1
  fi
  MF_TEST_MODE=1
  if [ -n "${MUXFINDER_TEST_STOP_WAIT:-}" ]; then
    case "$MUXFINDER_TEST_STOP_WAIT" in
      [1-9] | [1-5][0-9] | 60) MF_STOP_WAIT_SECONDS="$MUXFINDER_TEST_STOP_WAIT" ;;
      *)
        mf_error "MUXFINDER_TEST_STOP_WAIT must be 1 to 60 seconds."
        return 1
        ;;
    esac
  fi
  mf_check_test_swap || return 1
} # End of function mf_resolve_roots

# Test mode only: checks that the path $1, which a script derived from a test folder, lies
# strictly beneath MF_HOME or MF_APPLICATIONS with no ".", ".." or empty component and no
# symbolic link among the folders between the test folder and its last component (that last
# one the callers inspect themselves, never following a link). Outside test mode it succeeds
# at once: the real home folder and /Applications are used as they are. Returns 1 with a
# message otherwise.
mf_check_contained() {
  local path="$1" root rest component current index
  local parts=()
  [ "${MF_TEST_MODE:-0}" = "1" ] || return 0
  if mf_path_within "$path" "$MF_HOME" && [ "$path" != "$MF_HOME" ]; then
    root="$MF_HOME"
  elif mf_path_within "$path" "$MF_APPLICATIONS" && [ "$path" != "$MF_APPLICATIONS" ]; then
    root="$MF_APPLICATIONS"
  else
    mf_error "test mode: $path is not beneath the test folders; nothing changed."
    return 1
  fi
  if [ -L "$root" ] || [ ! -d "$root" ]; then
    mf_error "test mode: the test folder $root is gone or became a symbolic link."
    return 1
  fi
  rest="${path#"$root"/}"
  case "$rest" in
    */ | *$'\n'*)
      mf_error "test mode: $path ends with a slash or holds a line break; nothing changed."
      return 1
      ;;
  esac
  IFS=/ read -r -a parts <<<"$rest"
  current="$root"
  index=0
  for component in ${parts[@]+"${parts[@]}"}; do
    index=$((index + 1))
    case "$component" in
      '' | . | ..)
        mf_error "test mode: $path is not a plain path beneath $root; nothing changed."
        return 1
        ;;
    esac
    current="$current/$component"
    [ "$index" -lt "${#parts[@]}" ] || break
    if [ -L "$current" ]; then
      mf_error "test mode: $current is a symbolic link, so $path may lie outside the test"
      mf_error "folders; nothing changed."
      return 1
    fi
  done # End of loop over the path's components
  return 0
} # End of function mf_check_contained

# Test mode only: checks MUXFINDER_TEST_SWAP_AT and MUXFINDER_TEST_SWAP_WITH (unset, or both
# set, different, beneath the test folders, and the second an existing folder that is not a
# symbolic link). Returns 1 with a message otherwise.
mf_check_test_swap() {
  local at="${MUXFINDER_TEST_SWAP_AT:-}" with="${MUXFINDER_TEST_SWAP_WITH:-}"
  [ -z "$at$with" ] && return 0
  if [ -z "$at" ] || [ -z "$with" ] || [ "$at" = "$with" ]; then
    mf_error "MUXFINDER_TEST_SWAP_AT and MUXFINDER_TEST_SWAP_WITH go together and differ."
    return 1
  fi
  mf_check_contained "$at" || return 1
  mf_check_contained "$with" || return 1
  if [ -L "$with" ] || [ ! -d "$with" ]; then
    mf_error "MUXFINDER_TEST_SWAP_WITH must be a folder: $with"
    return 1
  fi
} # End of function mf_check_test_swap

# Test mode only, a check's stand-in for another program replacing a folder after it was
# inspected: when MUXFINDER_TEST_SWAP_AT is the path $1, the entry there and the folder
# MUXFINDER_TEST_SWAP_WITH exchange places (three renames through the scratch folder $2).
mf_test_swap() {
  [ "${MF_TEST_MODE:-0}" = "1" ] || return 0
  [ -n "${MUXFINDER_TEST_SWAP_AT:-}" ] && [ "$MUXFINDER_TEST_SWAP_AT" = "$1" ] || return 0
  /bin/mv "$MUXFINDER_TEST_SWAP_WITH" "$2/test-swap"
  /bin/mv "$1" "$MUXFINDER_TEST_SWAP_WITH"
  /bin/mv "$2/test-swap" "$1"
  mf_say "  test hook: $1 and $MUXFINDER_TEST_SWAP_WITH exchanged places"
}

# Prints the value of the Info.plist key $2 of the app at $1, or nothing when the file or the
# key is missing.
mf_plist_value() {
  /usr/bin/plutil -extract "$2" raw -o - "$1/Contents/Info.plist" 2>/dev/null || true
}

# Prints what is at the path $1: "none", "link" (a symbolic link, never followed), "app" (a
# folder whose bundle id is muxFinder's) or "other".
mf_copy_kind() {
  if [ -L "$1" ]; then
    mf_say "link"
  elif [ ! -e "$1" ]; then
    mf_say "none"
  elif [ -d "$1" ] && [ "$(mf_plist_value "$1" CFBundleIdentifier)" = "$MF_BUNDLE_ID" ]; then
    mf_say "app"
  else
    mf_say "other"
  fi
} # End of function mf_copy_kind

# Prints the device (as lsof writes it, 0x and lowercase hex) and the inode of the entry $1
# itself (lstat: a symbolic link is never followed), separated by a space; returns 1 when it
# cannot be read.
mf_file_id() {
  local device inode
  device="$(/usr/bin/stat -f '%d' "$1" 2>/dev/null)" || return 1
  inode="$(/usr/bin/stat -f '%i' "$1" 2>/dev/null)" || return 1
  printf '0x%x %s\n' "$device" "$inode"
}

# Prints the executable of the process $1 as the kernel reports it: codesign's dynamic code
# lookup takes the path from proc_pidpath (the process's text vnode), unlike ps's comm, which
# is argv[0]. Prints nothing when it cannot be established (the process is gone, its executable
# was deleted or cannot be read).
mf_process_executable() {
  local details
  case "$1" in
    '' | *[!0-9]*) return 0 ;;
  esac
  details="$(/usr/bin/codesign -dv "$1" 2>&1)" || return 0
  printf '%s\n' "$details" | /usr/bin/sed -n 's/^Executable=//p' | /usr/bin/head -n 1
}

# Prints, one per line, the pids of this user's processes with a txt record (lsof) of the file
# whose device and inode are $1 ("0x… inode", mf_file_id): its executable or any file it maps.
mf_txt_pids() {
  local device="${1% *}" inode="${1#* }" line pid="" mapped_device=""
  { /usr/sbin/lsof -nP -w -u "$(/usr/bin/id -u)" -a -d txt -F pDi 2>/dev/null || true; } \
    | while IFS= read -r line; do
      case "$line" in
        p*)
          pid="${line#p}"
          mapped_device=""
          ;;
        f*) mapped_device="" ;;
        D*) mapped_device="${line#D}" ;;
        i*)
          if [ "$mapped_device" = "$device" ] && [ "${line#i}" = "$inode" ]; then
            printf '%s\n' "$pid"
          fi
          ;;
      esac
    done | /usr/bin/sort -u
} # End of function mf_txt_pids

# Prints one line per process of this user that has the file $1 as text (mf_txt_pids): "run
# <pid>" when the process's executable as the kernel reports it (mf_process_executable) is that
# file (same device and inode), "unknown <pid>" when its executable cannot be established and
# it is still there. A process whose executable is another file only maps $1 (a Spotlight,
# QuickLook or backup reader) and is left out. Prints nothing when the file is missing.
mf_scan_file() {
  local file_id candidates pid executable
  [ -f "$1" ] || return 0
  file_id="$(mf_file_id "$1")" || return 0
  candidates="$(mf_txt_pids "$file_id")"
  while IFS= read -r pid; do
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    executable="$(mf_process_executable "$pid")"
    if [ -z "$executable" ]; then
      if [ -n "$(/bin/ps -o pid= -p "$pid" 2>/dev/null || true)" ]; then
        printf 'unknown %s\n' "$pid"
      fi
    elif [ "$(mf_file_id "$executable" || true)" = "$file_id" ]; then
      printf 'run %s\n' "$pid"
    fi
  done <<<"$candidates" # End of loop over the candidate processes
} # End of function mf_scan_file

# Prints, one per line, the pids of the lines of kind $1 ("run" or "unknown") in the
# mf_scan_file output $2.
mf_scan_pids() {
  local kind pid
  while IFS=' ' read -r kind pid; do
    if [ "$kind" = "$1" ] && [ -n "$pid" ]; then
      printf '%s\n' "$pid"
    fi
  done <<<"$2"
  return 0
}

# Prints, one per line, the pids of this user's processes whose executable is the file $1
# (mf_scan_file's "run" lines). Prints nothing when the file is missing.
mf_pids_running() {
  mf_scan_pids run "$(mf_scan_file "$1")"
}

# Prints the pids in $1 (one per line) on one line, separated by spaces.
mf_pid_list() {
  local pid list=""
  while IFS= read -r pid; do
    if [ -n "$pid" ]; then
      list="${list:+$list }$pid"
    fi
  done <<<"$1"
  printf '%s\n' "$list"
}

# Stops the app copy $1: SIGTERM, once, to every process of this user whose executable is that
# copy's muxFinder (mf_scan_file's "run"; never its muxfinder-launch helpers, never a process
# that only maps the file), then waits up to MF_STOP_WAIT_SECONDS, scanning again each second.
# A process with that file as text whose executable cannot be established ("unknown") is
# named and never signalled, and the wait lasts until it is gone too. With $2 = 1 (dry run)
# only prints what it would do. Returns 1, naming the processes, when any is still there at
# the deadline; it never escalates to SIGKILL.
mf_stop_app() {
  local app="$1" dry_run="$2" executable scan pids unknown pid waited=0
  executable="$app/$MF_APP_EXECUTABLE"
  scan="$(mf_scan_file "$executable")"
  pids="$(mf_scan_pids run "$scan")"
  unknown="$(mf_scan_pids unknown "$scan")"
  if [ -z "$pids" ] && [ -z "$unknown" ]; then
    mf_say "  muxFinder is not running from $app"
    return 0
  fi
  if [ -n "$unknown" ]; then
    mf_say "  pid $(mf_pid_list "$unknown") has $executable mapped, but its executable could not be"
    mf_say "  established, so it is never signalled; nothing changes until it is gone."
  fi
  while IFS= read -r pid; do
    case "$pid" in
      '' | *[!0-9]*) continue ;;
    esac
    if [ "$dry_run" = "1" ]; then
      mf_say "  would stop muxFinder (pid $pid) with SIGTERM"
    else
      mf_say "  stopping muxFinder (pid $pid) with SIGTERM"
      kill -TERM "$pid" 2>/dev/null || true
    fi
  done <<<"$pids" # End of loop over the copy's muxFinder processes
  [ "$dry_run" = "1" ] && return 0
  while :; do
    scan="$(mf_scan_file "$executable")"
    pids="$(mf_scan_pids run "$scan")"
    unknown="$(mf_scan_pids unknown "$scan")"
    if [ -z "$pids" ] && [ -z "$unknown" ]; then
      mf_say "  nothing runs from $executable any more"
      return 0
    fi
    [ "$waited" -ge "$MF_STOP_WAIT_SECONDS" ] && break
    /bin/sleep 1
    waited=$((waited + 1))
  done # End of loop waiting for the processes to quit
  if [ -n "$pids" ]; then
    mf_error "muxFinder is still running from $app after ${MF_STOP_WAIT_SECONDS} s" \
      "(pid $(mf_pid_list "$pids")). Quit it from its menu (Quit), then run this again."
  fi
  if [ -n "$unknown" ]; then
    mf_error "could not tell whether pid $(mf_pid_list "$unknown") runs muxFinder from $app (it"
    mf_error "has that copy's executable mapped and was not signalled). Quit it or wait for it to"
    mf_error "end, then run this again."
  fi
  return 1
} # End of function mf_stop_app

# Prints a note about the muxfinder-launch helpers running from the app copy $1. They belong to
# iTerm2 tabs (an attach, "Set up SSH in iTerm2…" or a persistent profile's tab): stopping one
# could end the work in that tab, so they are left running and end with their tabs.
mf_report_helpers() {
  local pids
  pids="$(mf_pids_running "$1/$MF_HELPER_EXECUTABLE")"
  [ -z "$pids" ] && return 0
  mf_say "  left running: muxfinder-launch (pid $(mf_pid_list "$pids")) in iTerm2 tabs; each"
  mf_say "  ends with its tab, which keeps working after the app copy is gone."
}

# Puts the entry $1 (moved aside into the hidden folder $3) back at $2 when nothing is there,
# then removes $3 if it is empty; otherwise keeps both and names them. Never deletes anything
# but an empty folder.
mf_put_back() {
  if [ ! -e "$2" ] && [ ! -L "$2" ] && /bin/mv "$1" "$2"; then
    mf_warn "put it back at $2"
    /bin/rmdir "$3" 2>/dev/null || true
  else
    mf_error "it is kept at $1; move it back to $2 by hand."
  fi
}

# Removes the entry $1, inspected earlier with the identity $2 (mf_file_id), bound to it:
# renames it into a new hidden folder beside it (.muxFinder-remove.*, same folder, so one
# atomic rename), checks that the moved entry has that device and inode, and only then deletes
# the hidden folder (itself checked to be the one just made). When something else was moved,
# it is put back and never deleted; when the deletion fails part way, what is left is put back
# too. In test mode $1 is checked to lie beneath the test folders first. Returns 0 removed,
# 3 left because the entry there was not the inspected one, 1 refused or failed otherwise
# (each with a message).
mf_remove_bound() {
  local path="$1" expected="$2" parent name aside aside_id moved
  parent="${path%/*}"
  name="${path##*/}"
  mf_check_contained "$path" || return 1
  if [ -z "$expected" ]; then
    mf_error "$path was not inspected; left as it is."
    return 1
  fi
  if ! aside="$(/usr/bin/mktemp -d "$parent/.muxFinder-remove.XXXXXX")"; then
    mf_error "could not make a hidden folder in $parent to move $path aside; left as it is."
    return 1
  fi
  aside_id="$(mf_file_id "$aside")" || aside_id=""
  moved="$aside/$name"
  mf_test_swap "$path" "$aside"
  if ! /bin/mv "$path" "$moved"; then
    /bin/rmdir "$aside" 2>/dev/null || true
    mf_error "could not move $path aside; left as it is."
    return 1
  fi
  if [ "$(mf_file_id "$moved" || true)" != "$expected" ]; then
    mf_error "$path changed after it was checked (it is not the folder that was inspected);"
    mf_error "it is left as it is, never deleted."
    mf_put_back "$moved" "$path" "$aside"
    return 3
  fi
  if [ -n "$aside_id" ] && [ "$(mf_file_id "$aside" || true)" = "$aside_id" ] \
    && /bin/rm -rf -- "$aside" && [ ! -e "$aside" ]; then
    return 0
  fi
  if [ -e "$moved" ] || [ -L "$moved" ]; then
    mf_error "$path was not deleted completely; what is left goes back in its place."
    mf_put_back "$moved" "$path" "$aside"
  fi
  return 1
} # End of function mf_remove_bound

# Runs "$@" (after the first argument, a number of seconds) in the background and waits for it
# up to that many seconds. Returns its exit status, or 124 after sending it SIGTERM when it did
# not finish in time.
mf_run_bounded() {
  local seconds="$1" pid status=0 ticks=0
  shift
  "$@" &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$ticks" -ge $((seconds * 10)) ]; then
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    /bin/sleep 0.1
    ticks=$((ticks + 1))
  done # End of loop waiting for the command
  wait "$pid" || status=$?
  return "$status"
} # End of function mf_run_bounded

# Prints how the app copy $1 is signed: the first signing authority, "ad hoc", or "unsigned".
mf_signing_summary() {
  local details authority
  details="$(/usr/bin/codesign -dv --verbose=2 "$1" 2>&1 || true)"
  authority="$(printf '%s\n' "$details" | /usr/bin/sed -n 's/^Authority=//p' | /usr/bin/head -n 1)"
  if [ -n "$authority" ]; then
    printf '%s\n' "$authority"
    return 0
  fi
  case "$details" in
    *"Signature=adhoc"*) mf_say "ad hoc" ;;
    *) mf_say "unsigned" ;;
  esac
} # End of function mf_signing_summary

# Prints what Gatekeeper says about the app copy $1 (scripts/release.sh, PLAN.md D28):
# "notarized" for an accepted notarized Developer ID, "not notarized" for any other verdict,
# and "notarization unknown" when spctl gives no verdict within 10 s (it asks the system's
# assessment service, which may consult its cache or the network). spctl is part of macOS,
# unlike xcrun's stapler. Test mode never asks it, so the checks stay hermetic.
mf_notarization_summary() {
  local verdict
  if [ "${MF_TEST_MODE:-}" = "1" ]; then
    printf '%s\n' "notarization not checked in test mode"
    return 0
  fi
  verdict="$(mf_run_bounded 10 /usr/sbin/spctl --assess --type execute -vv "$1" 2>&1 || true)"
  case "$verdict" in
    *"accepted"*"source=Notarized Developer ID"*) printf '%s\n' "notarized" ;;
    *"rejected"* | *"accepted"*) printf '%s\n' "not notarized" ;;
    *) printf '%s\n' "notarization unknown" ;;
  esac
} # End of function mf_notarization_summary
