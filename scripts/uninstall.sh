#!/bin/bash
# Removes muxFinder from this Mac (PLAN.md D27): the app in /Applications and in
# ~/Applications, its iTerm2 dynamic profile file and its support folder.
#
#   scripts/uninstall.sh [--dry-run]
#
# - Quits the app: SIGTERM, once, to the muxFinder process of each copy being removed (only a
#   process whose executable, as the kernel reports it, is that copy's file; never one that
#   only maps it), then up to 20 s for it to quit; if one is still running then, nothing is
#   removed. A process with that file mapped whose executable cannot be established is named,
#   never signalled, and nothing is removed while it stays. Its muxfinder-launch helpers are
#   left running: each belongs to an iTerm2 tab (an attach, "Set up SSH in iTerm2…" or a
#   persistent profile) and stopping it could end the work in that tab; they end with their
#   tabs.
# - Every deletion is bound to what was inspected: an app copy or the support folder is
#   renamed into a new hidden folder beside it, checked to have the device and inode recorded
#   when it was inspected, and only then deleted; anything else is put back, never deleted,
#   and the run exits 1.
# - ~/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json is removed only when
#   it is muxFinder's generated file: the app copy's own binary decides and removes it
#   (muxFinder --remove-persistent-profiles, under muxFinder's lock), and only when that copy's
#   Info.plist says it takes that flag (MuxFinderScriptInterface 1) and its signature
#   verifies. Without such a copy the file is left and its path printed.
# - ~/Library/Application Support/muxFinder is removed (host list, launch folder, lock file),
#   unless it is a symbolic link (never followed) or not a folder.
# - The app's preferences domain (cc.carpio.muxfinder, where AppKit keeps the menu bar item's
#   state) is deleted with /usr/bin/defaults when it exists, never in a dry run or test mode.
# - It prints how to clear the login item and the Automation permission (it never runs tccutil)
#   and never touches tmux sessions, iTerm2's preferences or other profiles, ~/.ssh or shell
#   startup files. No open, osascript, killall or Apple events.
# - --dry-run prints every action and changes nothing.
# - For checks only: MUXFINDER_TEST_HOME and MUXFINDER_TEST_APPLICATIONS (both, private folders
#   of yours under /private/tmp or /private/var/folders, such as ones from mktemp -d, used by
#   their physical paths) stand in for the home folder and /Applications, MUXFINDER_TEST_STOP_WAIT
#   for the stop wait in seconds, and MUXFINDER_TEST_SWAP_AT and MUXFINDER_TEST_SWAP_WITH swap
#   a folder in just before one is moved aside (lib/app-copies.sh, mf_test_swap). Every path
#   the script works on must then lie beneath those folders with no symbolic link on the way,
#   checked before anything changes (exit 2 otherwise), so nothing outside them is changed and
#   no process outside their app copies gets a signal.
#
# Exit status: 0 everything of muxFinder's removed (files proven not to be muxFinder's are left
# and named), 1 something was refused or failed (named), 2 unusable arguments or environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/app-copies.sh
. "$SCRIPT_DIR/lib/app-copies.sh"

USAGE="usage: scripts/uninstall.sh [--dry-run]"
DRY_RUN=0
INCOMPLETE=0
COPIES=()
COPY_IDS=()

# Prints the usage and exits with $1.
usage() {
  mf_say "$USAGE"
  mf_say "  --dry-run  print every action and change nothing"
  exit "$1"
}

# Reads the command line into DRY_RUN.
parse_arguments() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      --dry-run) DRY_RUN=1 ;;
      -h | --help) usage 0 ;;
      *)
        mf_error "unknown argument: $argument"
        usage 2
        ;;
    esac
  done # End of loop over the arguments
} # End of function parse_arguments

# Finds the app copies to remove (/Applications and ~/Applications) into COPIES, with the
# device and inode of each as inspected in COPY_IDS: only folders whose bundle id is
# muxFinder's. A symbolic link there is left (never followed) and makes the run incomplete;
# another app there is left and named.
find_copies() {
  local path kind file_id
  for path in "$MF_APPLICATIONS/$MF_APP_NAME" "$MF_HOME/Applications/$MF_APP_NAME"; do
    kind="$(mf_copy_kind "$path")"
    case "$kind" in
      app)
        if ! file_id="$(mf_file_id "$path")"; then
          mf_error "could not read $path; left as it is."
          INCOMPLETE=1
          continue
        fi
        COPIES+=("$path")
        COPY_IDS+=("$file_id")
        mf_say "App copy: $path"
        ;;
      link)
        mf_error "$path is a symbolic link; left as it is (never followed)."
        INCOMPLETE=1
        ;;
      other) mf_say "Not muxFinder ($MF_BUNDLE_ID), left as it is: $path" ;;
      none) mf_say "No app copy at $path" ;;
    esac
  done # End of loop over the app locations
} # End of function find_copies

# Prints "<pid> <device> <inode>" for every txt record (lsof) of this user's processes whose
# file is named …/muxFinder.app/Contents/MacOS/muxFinder: the candidates for warn_other_processes.
muxfinder_txt_records() {
  local line pid="" device="" inode=""
  { /usr/sbin/lsof -nP -w -u "$(/usr/bin/id -u)" -a -d txt -F pDin 2>/dev/null || true; } \
    | while IFS= read -r line; do
      case "$line" in
        p*) pid="${line#p}" ;;
        f*)
          device=""
          inode=""
          ;;
        D*) device="${line#D}" ;;
        i*) inode="${line#i}" ;;
        n*)
          case "${line#n}" in
            */"$MF_APP_NAME/$MF_APP_EXECUTABLE") printf '%s %s %s\n' "$pid" "$device" "$inode" ;;
          esac
          ;;
      esac
    done | /usr/bin/sort -u # End of loop over lsof's records
} # End of function muxfinder_txt_records

# Warns about muxFinder processes running from anywhere but the copies being removed (another
# copy, a build folder; told apart from those copies by device and inode): they may write
# muxFinder's support folder again. A process counts only when its executable, as the kernel
# reports it (mf_process_executable), is the muxFinder file it has as text, so a process that
# only maps one is no muxFinder. Never signals them.
warn_other_processes() {
  local copy file_id ours="|" records pid device inode executable
  for copy in ${COPIES[@]+"${COPIES[@]}"}; do
    if file_id="$(mf_file_id "$copy/$MF_APP_EXECUTABLE")"; then
      ours="$ours$file_id|"
    fi
  done
  records="$(muxfinder_txt_records)"
  while read -r pid device inode; do
    [ -n "$pid" ] || continue
    case "$ours" in
      *"|$device $inode|"*) continue ;;
    esac
    executable="$(mf_process_executable "$pid")"
    [ -n "$executable" ] || continue
    [ "$(mf_file_id "$executable" || true)" = "$device $inode" ] || continue
    mf_warn "muxFinder is also running from $executable (pid $pid), which is not"
    mf_warn "being removed; it may write its support folder again. Quit it too."
  done <<<"$records" # End of loop over the candidate processes
} # End of function warn_other_processes

# Picks the app copy whose binary decides about the profile file: the first copy whose
# Info.plist has MuxFinderScriptInterface 1, whose executable is there and whose signature
# verifies. Prints its executable, or nothing.
profile_remover() {
  local copy
  for copy in ${COPIES[@]+"${COPIES[@]}"}; do
    if [ "$(mf_plist_value "$copy" MuxFinderScriptInterface)" = "$MF_SCRIPT_INTERFACE" ] \
      && [ -x "$copy/$MF_APP_EXECUTABLE" ] \
      && /usr/bin/codesign --verify --deep --strict "$copy" 2>/dev/null; then
      mf_say "$copy/$MF_APP_EXECUTABLE"
      return 0
    fi
  done
} # End of function profile_remover

# Removes DynamicProfiles/muxFinder.json through the app's own binary, only when it is
# muxFinder's generated file; otherwise leaves it and says why.
remove_profile_file() {
  local profiles="$MF_HOME/Library/Application Support/iTerm2/DynamicProfiles"
  local file="$profiles/muxFinder.json" support="$1" remover status=0
  local arguments=(--remove-persistent-profiles)
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    mf_say "No persistent profile file at $file"
    return 0
  fi
  remover="$(profile_remover)"
  if [ -z "$remover" ]; then
    mf_error "left $file as it is: no app copy being removed can tell whether it is muxFinder's"
    mf_error "generated file (no copy, a copy too old for --remove-persistent-profiles, or one"
    mf_error "whose signature does not verify). If its profiles are named \"Persistent work –"
    mf_error "…\", delete it yourself, or reinstall muxFinder and use Settings › Persistent"
    mf_error "profiles › \"Remove profiles\" first."
    INCOMPLETE=1
    return 0
  fi
  [ "$DRY_RUN" = "1" ] && arguments+=(--dry-run)
  if [ "$MF_TEST_MODE" = "1" ]; then
    arguments+=(--profiles-directory "$profiles" --lock-directory "$support")
  fi
  mf_run_bounded 30 "$remover" "${arguments[@]}" || status=$?
  case "$status" in
    0) ;;
    1) mf_say "  (muxFinder never writes such a file, so it stays)" ;;
    *)
      mf_error "the profile file was not removed (status $status); see the line above."
      INCOMPLETE=1
      ;;
  esac
} # End of function remove_profile_file

# Removes muxFinder's support folder $1, unless it is a symbolic link or not a folder; the
# deletion is bound to the folder inspected here (mf_remove_bound).
remove_support_folder() {
  local support="$1" file_id status=0
  if [ -L "$support" ]; then
    mf_error "$support is a symbolic link; left as it is (never followed)."
    INCOMPLETE=1
  elif [ -d "$support" ]; then
    file_id="$(mf_file_id "$support")" || file_id=""
    if [ "$DRY_RUN" = "1" ]; then
      mf_say "Would remove $support (host list, launch folder, lock file)"
      return 0
    fi
    mf_remove_bound "$support" "$file_id" || status=$?
    case "$status" in
      0) mf_say "Removed $support" ;;
      3) INCOMPLETE=1 ;;
      *)
        mf_error "could not remove $support completely."
        INCOMPLETE=1
        ;;
    esac
  elif [ -e "$support" ]; then
    mf_error "$support is not a folder; left as it is."
    INCOMPLETE=1
  else
    mf_say "No support folder at $support"
  fi
} # End of function remove_support_folder

# Removes every app copy in COPIES, each bound to the folder find_copies inspected
# (COPY_IDS, mf_remove_bound).
remove_copies() {
  local index=0 copy file_id status
  for copy in ${COPIES[@]+"${COPIES[@]}"}; do
    file_id="${COPY_IDS[$index]}"
    index=$((index + 1))
    if [ "$DRY_RUN" = "1" ]; then
      mf_say "Would remove $copy"
      continue
    fi
    status=0
    mf_remove_bound "$copy" "$file_id" || status=$?
    case "$status" in
      0) mf_say "Removed $copy" ;;
      3) INCOMPLETE=1 ;;
      *)
        mf_error "could not remove $copy (macOS may ask to allow your terminal under System"
        mf_error "Settings › Privacy & Security › App Management; or drag it to the Trash)."
        INCOMPLETE=1
        ;;
    esac
  done # End of loop over the app copies
} # End of function remove_copies

# Deletes the app's preferences domain when it exists; never in test mode or a dry run.
remove_preferences() {
  if [ "$MF_TEST_MODE" = "1" ]; then
    mf_say "Preferences domain $MF_BUNDLE_ID: not touched in test mode"
  elif ! /usr/bin/defaults read "$MF_BUNDLE_ID" >/dev/null 2>&1; then
    mf_say "No preferences domain $MF_BUNDLE_ID"
  elif [ "$DRY_RUN" = "1" ]; then
    mf_say "Would delete the preferences domain $MF_BUNDLE_ID (/usr/bin/defaults delete)"
  elif /usr/bin/defaults delete "$MF_BUNDLE_ID" >/dev/null 2>&1; then
    mf_say "Deleted the preferences domain $MF_BUNDLE_ID"
  else
    mf_error "could not delete the preferences domain $MF_BUNDLE_ID."
    INCOMPLETE=1
  fi
} # End of function remove_preferences

# Prints what the user may still want to do by hand.
print_instructions() {
  mf_say ""
  mf_say "Left for you (this script never changes them):"
  mf_say "- Launch at login: if it was on, open System Settings › General › Login Items (Login"
  mf_say "  Items & Extensions on newer macOS) and remove muxFinder if it is still listed. Next"
  mf_say "  time, first turn off \"Open muxFinder when you log in\" in muxFinder's Settings ›"
  mf_say "  General."
  mf_say "- Automation permission for iTerm2: to clear it, run"
  mf_say "    tccutil reset AppleEvents $MF_BUNDLE_ID"
  mf_say "- Your tmux sessions, iTerm2's preferences and other profiles, ~/.ssh and shell"
  mf_say "  startup files were not touched. Sessions keep running on their hosts."
} # End of function print_instructions

# Uninstalls: find and stop the copies, then the profile file, the support folder, the copies
# and the preferences domain; then the instructions.
main() {
  local support copy path
  parse_arguments "$@"
  mf_refuse_root
  mf_resolve_roots || exit 2
  support="$MF_HOME/Library/Application Support/muxFinder"
  # Test mode: every path this run reads or changes must lie beneath the test folders before
  # anything happens.
  for path in "$MF_APPLICATIONS/$MF_APP_NAME" "$MF_HOME/Applications/$MF_APP_NAME" "$support" \
    "$MF_HOME/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json"; do
    mf_check_contained "$path" || exit 2
  done
  [ "$DRY_RUN" = "1" ] && mf_say "Dry run: nothing will be changed."
  [ "$MF_TEST_MODE" = "1" ] && mf_say "Test mode: home $MF_HOME, applications $MF_APPLICATIONS."

  find_copies
  for copy in ${COPIES[@]+"${COPIES[@]}"}; do
    if [ "$DRY_RUN" = "1" ]; then
      mf_say "Would quit $copy if it is running"
    else
      mf_say "Quitting $copy"
    fi
    mf_stop_app "$copy" "$DRY_RUN" || exit 1
    mf_report_helpers "$copy"
  done # End of loop over the app copies
  warn_other_processes

  remove_profile_file "$support"
  remove_support_folder "$support"
  remove_copies
  remove_preferences
  print_instructions
  if [ "$INCOMPLETE" = "1" ]; then
    mf_error "muxFinder was not removed completely; see the errors above."
    exit 1
  fi
  if [ "$DRY_RUN" = "1" ]; then
    mf_say "Dry run done: nothing was changed."
  else
    mf_say "muxFinder was removed."
  fi
} # End of function main

main "$@"
