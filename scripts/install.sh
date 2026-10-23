#!/bin/bash
# Installs build/muxFinder.app (PLAN.md D27) into /Applications, or into ~/Applications with
# --user.
#
#   scripts/install.sh [--user] [--dry-run]
#
# - Source: build/muxFinder.app from scripts/build-app.sh (run that first). Its bundle id,
#   executables and signature are checked before anything changes.
# - A copy already at the destination must be muxFinder's (its bundle id) and not a symbolic
#   link, else nothing changes; its device and inode are recorded when it is inspected.
# - The new copy is made with ditto (signature and attributes kept) in a hidden temporary folder
#   next to the destination and verified with codesign. Only then, if the old copy is running,
#   its muxFinder process (only a process whose executable, as the kernel reports it, is that
#   copy's file) gets SIGTERM and up to 20 s to quit; if it is still running then, nothing
#   changes. A process that only maps that file is never signalled; one whose executable
#   cannot be established is named, never signalled, and nothing changes while it stays. Its
#   muxfinder-launch helpers in iTerm2 tabs are left running. Then the old copy is renamed
#   aside into the hidden folder and checked to be the inspected one (device and inode): if it
#   is not, it is put back, never deleted, nothing is installed and the run fails. Otherwise
#   the new one is renamed into place (the old one is put back if that fails), so a failed
#   copy never leaves half an app or a stopped app. The old copy is deleted last.
# - It never starts the app (no open, no LaunchServices, no Apple events); it prints how to.
# - --dry-run prints every action and changes nothing.
# - For checks only: MUXFINDER_TEST_HOME and MUXFINDER_TEST_APPLICATIONS (both, private folders
#   of yours under /private/tmp or /private/var/folders, such as ones from mktemp -d, used by
#   their physical paths) stand in for the home folder and /Applications; MUXFINDER_TEST_SOURCE
#   may then name the bundle to install, MUXFINDER_TEST_STOP_WAIT the stop wait in seconds,
#   and MUXFINDER_TEST_SWAP_AT and MUXFINDER_TEST_SWAP_WITH swap a folder in just before the
#   old copy is moved aside (lib/app-copies.sh, mf_test_swap). In test mode every path the
#   script works on must lie beneath those folders with no symbolic link on the way, checked
#   before anything changes (exit 2 otherwise), so nothing outside them is changed.
#
# Exit status: 0 installed (or a dry run), 1 refused or failed (nothing changed), 2 unusable
# arguments or environment.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/app-copies.sh
. "$SCRIPT_DIR/lib/app-copies.sh"

USAGE="usage: scripts/install.sh [--user] [--dry-run]"
USER_INSTALL=0
DRY_RUN=0
STAGE=""
STAGE_ID=""
PREVIOUS=""
TARGET=""
TARGET_ID=""
UNEXPECTED=0

# Prints the usage and exits with $1.
usage() {
  mf_say "$USAGE"
  mf_say "  --user     install into ~/Applications instead of /Applications"
  mf_say "  --dry-run  print every action and change nothing"
  exit "$1"
}

# Reads the command line into USER_INSTALL and DRY_RUN.
parse_arguments() {
  local argument
  for argument in "$@"; do
    case "$argument" in
      --user) USER_INSTALL=1 ;;
      --dry-run) DRY_RUN=1 ;;
      -h | --help) usage 0 ;;
      *)
        mf_error "unknown argument: $argument"
        usage 2
        ;;
    esac
  done # End of loop over the arguments
} # End of function parse_arguments

# On any exit: puts what was moved aside (the previous copy, or an entry found there instead
# of the inspected copy) back when the new copy is not in place, and removes the temporary
# folder (remove_stage), unless that entry could not be put back: then the folder is kept and
# named.
cleanup() {
  local what="the previous copy"
  [ "$UNEXPECTED" = "1" ] && what="the entry found there instead"
  if [ -n "$PREVIOUS" ] && { [ -e "$PREVIOUS" ] || [ -L "$PREVIOUS" ]; }; then
    if [ ! -e "$TARGET" ] && [ ! -L "$TARGET" ] && /bin/mv "$PREVIOUS" "$TARGET"; then
      mf_warn "put $what back at $TARGET"
    else
      mf_error "$what is kept at $PREVIOUS; move it back to $TARGET by hand."
      return 0
    fi
  fi
  remove_stage
} # End of function cleanup

# Deletes the temporary folder, bound to what was checked: only while it is the folder this
# run made (device and inode) and a previous copy in it is the inspected one; otherwise keeps
# it and names it. It holds only this run's new copy and that previous copy.
remove_stage() {
  local previous
  if [ -z "$STAGE" ] || [ ! -d "$STAGE" ]; then
    return 0
  fi
  previous="$STAGE/previous-$MF_APP_NAME"
  if [ "$(mf_file_id "$STAGE" || true)" != "$STAGE_ID" ] \
    || { { [ -e "$previous" ] || [ -L "$previous" ]; } \
      && [ "$(mf_file_id "$previous" || true)" != "$TARGET_ID" ]; }; then
    mf_warn "kept the temporary folder $STAGE: it changed meanwhile."
    return 0
  fi
  /bin/rm -rf -- "$STAGE" || mf_warn "could not remove the temporary folder $STAGE"
} # End of function remove_stage

# Checks that $1 is a complete, signed muxFinder bundle; exits 1 when it is not.
check_source() {
  local source="$1"
  if [ -L "$source" ] || [ ! -d "$source" ]; then
    mf_error "no built app at $source. Run scripts/build-app.sh first."
    exit 1
  fi
  if [ "$(mf_plist_value "$source" CFBundleIdentifier)" != "$MF_BUNDLE_ID" ]; then
    mf_error "$source is not muxFinder (bundle id is not $MF_BUNDLE_ID)."
    exit 1
  fi
  if [ ! -x "$source/$MF_APP_EXECUTABLE" ] || [ ! -x "$source/$MF_HELPER_EXECUTABLE" ]; then
    mf_error "$source is incomplete (an executable is missing). Run scripts/build-app.sh again."
    exit 1
  fi
  if ! /usr/bin/codesign --verify --deep --strict "$source" 2>/dev/null; then
    mf_error "the signature of $source does not verify. Run scripts/build-app.sh again."
    exit 1
  fi
} # End of function check_source

# Installs: the checks, stopping a running copy, the staged copy, the swap, the report.
main() {
  local source destination kind other new_id notarization
  parse_arguments "$@"
  mf_refuse_root
  mf_resolve_roots || exit 2
  source="$ROOT/build/$MF_APP_NAME"
  if [ -n "${MUXFINDER_TEST_SOURCE:-}" ]; then
    if [ "$MF_TEST_MODE" != "1" ]; then
      mf_error "MUXFINDER_TEST_SOURCE is for checks only (with the MUXFINDER_TEST_* folders)."
      exit 2
    fi
    source="$MUXFINDER_TEST_SOURCE"
  fi
  if [ "$USER_INSTALL" = "1" ]; then
    destination="$MF_HOME/Applications"
    other="$MF_APPLICATIONS/$MF_APP_NAME"
  else
    destination="$MF_APPLICATIONS"
    other="$MF_HOME/Applications/$MF_APP_NAME"
  fi
  TARGET="$destination/$MF_APP_NAME"
  # Test mode: the copy's place (with the destination folder on the way) and the other
  # location must lie beneath the test folders before anything is read or changed there.
  mf_check_contained "$TARGET" || exit 2
  mf_check_contained "$other" || exit 2
  [ "$DRY_RUN" = "1" ] && mf_say "Dry run: nothing will be changed."
  [ "$MF_TEST_MODE" = "1" ] && mf_say "Test mode: home $MF_HOME, applications $MF_APPLICATIONS."

  check_source "$source"
  mf_say "Source: $source ($MF_BUNDLE_ID, signed with: $(mf_signing_summary "$source"))"

  if [ -L "$destination" ] || { [ -e "$destination" ] && [ ! -d "$destination" ]; }; then
    mf_error "$destination is not a folder (or is a symbolic link); nothing changed."
    exit 1
  fi
  if [ ! -d "$destination" ]; then
    if [ "$USER_INSTALL" != "1" ]; then
      mf_error "$destination does not exist; nothing changed."
      exit 1
    fi
    if [ "$DRY_RUN" = "1" ]; then
      mf_say "Would create $destination"
    else
      /bin/mkdir "$destination"
      mf_say "Created $destination"
    fi
  fi
  case "$TARGET" in
    *[!A-Za-z0-9._/-]*)
      mf_warn "$TARGET has characters other than letters, digits and . _ / -, so muxFinder"
      mf_warn "will refuse to open sessions from there (PLAN.md D2). Install into /Applications."
      ;;
  esac

  kind="$(mf_copy_kind "$TARGET")"
  case "$kind" in
    link)
      mf_error "$TARGET is a symbolic link; left as it is (remove it yourself first)."
      exit 1
      ;;
    other)
      mf_error "$TARGET is not muxFinder ($MF_BUNDLE_ID); left as it is."
      exit 1
      ;;
    app)
      if ! TARGET_ID="$(mf_file_id "$TARGET")"; then
        mf_error "could not read $TARGET; left as it is."
        exit 1
      fi
      mf_say "Existing copy: $TARGET"
      ;;
  esac

  if [ "$DRY_RUN" = "1" ]; then
    mf_say "Would copy $source with ditto into a hidden temporary folder in $destination"
    mf_say "Would verify the copy's signature with codesign"
    if [ "$kind" = "app" ]; then
      mf_stop_app "$TARGET" "$DRY_RUN"
      mf_report_helpers "$TARGET"
      mf_say "Would rename the existing copy aside, rename the new copy to $TARGET, then"
      mf_say "delete the old copy"
    else
      mf_say "Would rename the new copy to $TARGET"
    fi
    mf_say "Dry run done: nothing was changed."
    return 0
  fi

  # The new copy is complete and verified before a running copy is asked to quit, so a failed
  # copy never stops the app.
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  STAGE="$(/usr/bin/mktemp -d "$destination/.muxFinder-install.XXXXXX")"
  STAGE_ID="$(mf_file_id "$STAGE")"
  mf_say "Copying with ditto into $STAGE"
  /usr/bin/ditto "$source" "$STAGE/$MF_APP_NAME"
  new_id="$(mf_file_id "$STAGE/$MF_APP_NAME")"
  if ! /usr/bin/codesign --verify --deep --strict "$STAGE/$MF_APP_NAME" 2>/dev/null; then
    mf_error "the copy's signature does not verify; nothing changed."
    exit 1
  fi
  if [ "$kind" = "app" ]; then
    mf_stop_app "$TARGET" "$DRY_RUN" || exit 1
    mf_report_helpers "$TARGET"
    mf_check_contained "$TARGET" || exit 1
    mf_test_swap "$TARGET" "$STAGE"
    # One rename into the hidden folder (same parent folder, so atomic), then the moved entry
    # must be the inspected copy before anything else happens; if not, cleanup puts it back.
    PREVIOUS="$STAGE/previous-$MF_APP_NAME"
    if ! /bin/mv "$TARGET" "$PREVIOUS"; then
      PREVIOUS=""
      mf_error "could not move $TARGET aside; nothing changed."
      exit 1
    fi
    if [ "$(mf_file_id "$PREVIOUS" || true)" != "$TARGET_ID" ]; then
      UNEXPECTED=1
      mf_error "$TARGET changed after it was checked (it is not the folder that was inspected);"
      mf_error "it is left as it is, never deleted, and nothing was installed."
      exit 1
    fi
  fi
  if [ -e "$TARGET" ] || [ -L "$TARGET" ]; then
    mf_error "something appeared at $TARGET meanwhile; left as it is."
    exit 1
  fi
  /bin/mv "$STAGE/$MF_APP_NAME" "$TARGET"
  if [ "$(mf_file_id "$TARGET" || true)" != "$new_id" ]; then
    mf_error "something appeared at $TARGET meanwhile, and the new copy may have been moved"
    mf_error "into it; nothing was deleted."
    exit 1
  fi
  PREVIOUS=""
  remove_stage
  STAGE=""
  trap - EXIT INT TERM

  notarization="$(mf_notarization_summary "$TARGET")"
  mf_say "Installed $TARGET (signed with: $(mf_signing_summary "$TARGET"); $notarization)."
  if [ "$(mf_copy_kind "$other")" != "none" ]; then
    mf_warn "another copy is at $other; macOS may open either. Remove the one you don't use."
  fi
  mf_say ""
  mf_say "This script does not start muxFinder. Start it from Finder (double-click muxFinder"
  mf_say "in $destination) or from a terminal with: open \"$TARGET\""
  mf_say "The first launch may show macOS prompts: Automation (\"muxFinder wants access to"
  mf_say "control iTerm2\", needed to talk to iTerm2's Python API; allow it), and, for a copy"
  case "$notarization" in
    "notarized")
      mf_say "downloaded or AirDropped from another Mac, Gatekeeper's one-time question whether"
      mf_say "to open an app from the internet."
      ;;
    "not notarized")
      mf_say "downloaded or AirDropped from another Mac, Gatekeeper (the app is not notarized;"
      mf_say "see README.md, \"Install on each Mac\")."
      ;;
    *)
      mf_say "downloaded or AirDropped from another Mac, Gatekeeper (see README.md, \"Install on"
      mf_say "each Mac\")."
      ;;
  esac
} # End of function main

main "$@"
