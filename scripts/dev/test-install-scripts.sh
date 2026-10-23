#!/bin/bash
# Hermetic check of scripts/install.sh and scripts/uninstall.sh (dev only; PLAN.md D27).
#
#   scripts/dev/test-install-scripts.sh
#
# Runs both scripts in test mode only (MUXFINDER_TEST_HOME and MUXFINDER_TEST_APPLICATIONS set
# to private folders under one mktemp -d folder in /private/tmp) and prints one PASS or FAIL
# line per step; exits 0 only when every step passes.
#
# - Needs build/muxFinder.app from the current tree (scripts/build-app.sh): the installs copy
#   it, and the uninstall's profile step runs its binary with --remove-persistent-profiles on
#   the private folders. The app never runs in normal mode here.
# - Processes: "running copies" are a small stub compiled here (cc) and placed in fake bundles
#   as Contents/MacOS/muxFinder and muxfinder-launch (a copy of /bin/sleep is killed by macOS
#   when run from elsewhere); in its "map" mode the stub only maps a file read-only, standing
#   in for a Spotlight, QuickLook or backup reader. Only the stubs this script started are ever
#   signalled, by the scripts under test (SIGTERM to the copy being replaced or removed) or by
#   this script's cleanup.
# - The test-mode guard steps that name real folders (~/Applications, the home folder, a path
#   inside it or a link into it) run install.sh --dry-run only, so even a broken guard could
#   change nothing; each compares the real locations before and after.
# - It never touches the real /Applications, ~/Applications, iTerm2's DynamicProfiles,
#   ~/Library/Application Support/muxFinder or the app's preferences: the last step compares a
#   listing of each, taken before the first step, with one taken at the end.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
UNINSTALL="$ROOT/scripts/uninstall.sh"
BUILT="$ROOT/build/muxFinder.app"
BUNDLE_ID="cc.carpio.muxfinder"
REAL_PROFILES="$HOME/Library/Application Support/iTerm2/DynamicProfiles"
REAL_SUPPORT="$HOME/Library/Application Support/muxFinder"

BASE=""
STUB=""
FAILURES=0
STEP=0
STARTED_PIDS=()
STATUS=0
LOG=""
SCENARIO=""
HOME_ROOT=""
APPS_ROOT=""
READERS=0

# Prints a PASS line for the next step.
pass() {
  STEP=$((STEP + 1))
  printf 'PASS %d %s\n' "$STEP" "$1"
}

# Prints a FAIL line for the next step, with the last script output when there is one.
fail() {
  STEP=$((STEP + 1))
  FAILURES=$((FAILURES + 1))
  printf 'FAIL %d %s\n' "$STEP" "$1"
  if [ -n "$LOG" ] && [ -f "$LOG" ]; then
    /usr/bin/sed 's/^/    | /' "$LOG" | /usr/bin/tail -n 25
  fi
}

# Records step $1 as PASS when the check that follows (a command and its arguments, often
# all_of with several checks) succeeds, else as FAIL.
expect() {
  local name="$1"
  shift
  if "$@"; then
    pass "$name"
  else
    fail "$name"
  fi
}

# Stops every stub this script started (they are its own processes) and removes the private
# folder.
cleanup() {
  local pid
  for pid in ${STARTED_PIDS[@]+"${STARTED_PIDS[@]}"}; do
    kill -KILL "$pid" 2>/dev/null || true
  done
  if [ -n "$BASE" ] && [ -d "$BASE" ]; then
    /bin/rm -rf "$BASE"
  fi
}

# A listing of the real locations the scripts must never touch (read-only).
real_state() {
  local path
  for path in "/Applications/muxFinder.app" "$HOME/Applications/muxFinder.app"; do
    if [ -e "$path" ] || [ -L "$path" ]; then
      printf 'present %s\n' "$path"
    else
      printf 'absent %s\n' "$path"
    fi
  done
  /bin/ls -lATi "$REAL_PROFILES" 2>&1 || true
  /bin/ls -lATRi "$REAL_SUPPORT" 2>&1 || true
  /usr/bin/defaults read "$BUNDLE_ID" 2>&1 || true
} # End of function real_state

# A recursive listing of the folder $1 (kinds, modes, inodes, sizes, times, link targets): any
# write, removal or rename changes it.
snapshot() {
  /bin/ls -lATRi "$1" 2>&1
}

# The listings of the current home and applications stand-ins (not the scenario's logs).
roots_snapshot() {
  snapshot "$HOME_ROOT"
  snapshot "$APPS_ROOT"
}

# Starts fresh private roots for scenario $1: HOME_ROOT with Library/Application Support, and
# APPS_ROOT.
new_roots() {
  SCENARIO="$BASE/$1"
  HOME_ROOT="$SCENARIO/home"
  APPS_ROOT="$SCENARIO/apps"
  /bin/mkdir -p "$HOME_ROOT/Library/Application Support" "$APPS_ROOT" "$SCENARIO/logs"
}

# Runs the script $1 in test mode on the current roots with the remaining arguments; the
# environment variables MUXFINDER_TEST_SOURCE and MUXFINDER_TEST_STOP_WAIT pass through when
# set. Sets STATUS and LOG.
run_script() {
  local script="$1" name
  shift
  name="$(/usr/bin/basename "$script" .sh)-$STEP"
  LOG="$SCENARIO/logs/$name.log"
  STATUS=0
  MUXFINDER_TEST_HOME="$HOME_ROOT" MUXFINDER_TEST_APPLICATIONS="$APPS_ROOT" \
    "$script" "$@" >"$LOG" 2>&1 || STATUS=$?
}

# Whether the last run exited with $1.
status_is() {
  [ "$STATUS" = "$1" ]
}

# Whether the last run's output contains the text $1.
log_has() {
  case "$(/bin/cat "$LOG")" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Whether the last run's output lacks the text $1.
log_lacks() {
  ! log_has "$1"
}

# Whether $1 is a complete muxFinder bundle whose signature verifies.
valid_copy() {
  [ -d "$1" ] && [ ! -L "$1" ] \
    && [ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$1/Contents/Info.plist")" \
      = "$BUNDLE_ID" ] \
    && /usr/bin/codesign --verify --deep --strict "$1" 2>/dev/null
}

# Whether nothing exists at $1 (not even a dangling link).
absent() {
  [ ! -e "$1" ] && [ ! -L "$1" ]
}

# Whether the folder $1 holds no hidden folder of the scripts (.muxFinder-install.* or
# .muxFinder-remove.*).
no_stage_left() {
  local entry
  for entry in "$1"/.muxFinder-*; do
    if [ -e "$entry" ]; then
      return 1
    fi
  done
  return 0
}

# A listing of the folder $1's contents relative to it (kinds, modes, inodes, sizes, times)
# and the SHA-256 of the files different_folder makes: the same before and after only when
# the folder survived byte for byte, wherever it was moved meanwhile.
tree_state() {
  (cd "$1" && /bin/ls -lATRi . && /usr/bin/shasum -a 256 Contents/Info.plist \
    Contents/MacOS/muxFinder Contents/MacOS/muxfinder-launch marker.txt) 2>&1
}

# Makes a folder at $1 that is not the copy a script inspected: a fake muxFinder bundle (it
# passes every bundle check) with a marker file of its own.
different_folder() {
  fake_bundle "$1"
  printf 'not the inspected folder\n' >"$1/marker.txt"
}

# Whether the process $1 is alive (a zombie counts as gone).
alive() {
  local state
  state="$(/bin/ps -o stat= -p "$1" 2>/dev/null || true)"
  case "$state" in
    '' | Z*) return 1 ;;
    *) return 0 ;;
  esac
}

# Whether the process $1 is gone, waiting up to 3 s.
gone() {
  local ticks=0
  while alive "$1"; do
    if [ "$ticks" -ge 30 ]; then
      return 1
    fi
    /bin/sleep 0.1
    ticks=$((ticks + 1))
  done
  return 0
}

# Makes a fake muxFinder bundle at $1 (stub executables, our bundle id unless $2 names
# another, and the script interface key only when $3 is "interface"), unsigned.
fake_bundle() {
  local app="$1" bundle_id="${2:-$BUNDLE_ID}" interface="${3:-}"
  /bin/mkdir -p "$app/Contents/MacOS"
  /bin/cp "$STUB" "$app/Contents/MacOS/muxFinder"
  /bin/cp "$STUB" "$app/Contents/MacOS/muxfinder-launch"
  /usr/bin/plutil -create xml1 "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleIdentifier -string "$bundle_id" "$app/Contents/Info.plist"
  /usr/bin/plutil -insert CFBundleExecutable -string "muxFinder" "$app/Contents/Info.plist"
  if [ "$interface" = "interface" ]; then
    /usr/bin/plutil -insert MuxFinderScriptInterface -integer 1 "$app/Contents/Info.plist"
  fi
} # End of function fake_bundle

# Starts the executable $1 (a stub) in the background with the remaining arguments, records
# its pid in STARTED and STARTED_PIDS, and waits until it runs that executable.
start_stub() {
  local executable="$1" ticks=0
  shift
  "$executable" "$@" &
  STARTED=$!
  STARTED_PIDS+=("$STARTED")
  disown "$STARTED" 2>/dev/null || true
  while [ "$(/bin/ps -o comm= -p "$STARTED" 2>/dev/null || true)" != "$executable" ]; do
    if [ "$ticks" -ge 50 ]; then
      return 1
    fi
    /bin/sleep 0.1
    ticks=$((ticks + 1))
  done
} # End of function start_stub

# Starts the stub copy $1 as a reader with argv[0] $2 (which may name another file) that only
# maps the file $3 read-only, records its pid in STARTED and STARTED_PIDS, and waits up to 5 s
# until the mapping is in place (the stub then creates its ready file).
start_reader() {
  local ready ticks=0
  READERS=$((READERS + 1))
  ready="$SCENARIO/reader-$READERS.ready"
  (exec -a "$2" "$1" map "$3" "$ready") &
  STARTED=$!
  STARTED_PIDS+=("$STARTED")
  disown "$STARTED" 2>/dev/null || true
  while [ ! -e "$ready" ]; do
    if [ "$ticks" -ge 50 ]; then
      return 1
    fi
    /bin/sleep 0.1
    ticks=$((ticks + 1))
  done
} # End of function start_reader

# Writes a generated (muxFinder-made) profile document to $1.
write_generated_profile() {
  /bin/cat >"$1" <<'JSON'
{
  "Profiles" : [
    {
      "Close Sessions On End" : true,
      "Command" : "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch profile 0f8fad5b-d9cb-469f-a165-70867728950e",
      "Custom Command" : "Yes",
      "Guid" : "muxfinder-persistent-0f8fad5b-d9cb-469f-a165-70867728950e",
      "Name" : "Persistent work – This Mac",
      "Tags" : [
        "muxFinder"
      ]
    }
  ]
}
JSON
} # End of function write_generated_profile

# Fills the current home root with what an uninstall finds: the DynamicProfiles folder with
# the user's own entries (and, with $1 = generated or user, a muxFinder.json of that kind),
# and muxFinder's support folder.
populate_home() {
  local profiles="$HOME_ROOT/Library/Application Support/iTerm2/DynamicProfiles"
  local support="$HOME_ROOT/Library/Application Support/muxFinder"
  /bin/mkdir -p "$profiles/folder" "$support/launch"
  printf '{"Profiles": [{"Name": "Mine", "Guid": "mine-1"}]}\n' >"$profiles/mine.json"
  printf 'hidden\n' >"$profiles/.hidden"
  printf 'inner\n' >"$profiles/folder/inner.json"
  /bin/ln -s "/nonexistent/muxfinder-test" "$profiles/dangling.json"
  case "${1:-}" in
    generated) write_generated_profile "$profiles/muxFinder.json" ;;
    user)
      printf '{"Profiles": [{"Name": "Mine too", "Guid": "mine-2"}]}\n' \
        >"$profiles/muxFinder.json"
      ;;
  esac
  printf '{"schemaVersion": 1, "hosts": []}\n' >"$support/hosts.json"
  : >"$support/profiles.lock"
  : >"$support/launch/stale.request.json"
} # End of function populate_home

# Prints a listing of the current home root's DynamicProfiles entries other than
# muxFinder.json (spaces squeezed, since ls pads its columns to the widest entry), with the
# SHA-256 of each file.
siblings() {
  local profiles="$HOME_ROOT/Library/Application Support/iTerm2/DynamicProfiles"
  /bin/ls -lATi "$profiles" | /usr/bin/tr -s ' ' | /usr/bin/sed '/ muxFinder\.json$/d; /^total /d'
  /usr/bin/shasum -a 256 "$profiles/mine.json" "$profiles/.hidden" "$profiles/folder/inner.json"
}

# Prepares the private folder and the stub, and takes the real locations' listing.
setup() {
  if [ ! -d "$BUILT" ] \
    || [ "$(/usr/bin/plutil -extract MuxFinderScriptInterface raw -o - \
      "$BUILT/Contents/Info.plist" 2>/dev/null || true)" != "1" ] \
    || ! /usr/bin/codesign --verify --deep --strict "$BUILT" 2>/dev/null; then
    printf 'FAIL 0 setup: %s is missing, old or unsigned; run scripts/build-app.sh\n' "$BUILT"
    exit 1
  fi
  BASE="$(/usr/bin/mktemp -d /tmp/mfx.XXXXXX)"
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # The scripts work on the test folders' physical paths (/private/tmp/…), and print those.
  BASE="$(cd -P -- "$BASE" && pwd -P)"
  /bin/cat >"$BASE/stub.c" <<'C'
#include <fcntl.h>
#include <signal.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

/* A stand-in for an app copy's executable: waits for a signal; with "ignore-term" it ignores
   SIGTERM, like an app that does not quit; with "map <file> <ready>" it first maps <file>
   read-only, as a Spotlight, QuickLook or backup reader would, then creates <ready>. */
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "ignore-term") == 0) {
    signal(SIGTERM, SIG_IGN);
  }
  if (argc > 3 && strcmp(argv[1], "map") == 0) {
    struct stat st;
    int fd = open(argv[2], O_RDONLY);
    if (fd < 0 || fstat(fd, &st) != 0
        || mmap(NULL, (size_t)st.st_size, PROT_READ, MAP_PRIVATE, fd, 0) == MAP_FAILED) {
      return 3;
    }
    close(fd);
    int ready = open(argv[3], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (ready < 0) {
      return 3;
    }
    close(ready);
  }
  for (;;) {
    pause();
  }
}
C
  STUB="$BASE/stub"
  /usr/bin/cc -o "$STUB" "$BASE/stub.c"
  real_state >"$BASE/real-before.txt"
} # End of function setup

# Install steps: default and --user, a dry run, a reinstall, refusals, a running copy.
install_steps() {
  local before inode pid_app pid_helper pid_other

  new_roots install-default
  run_script "$INSTALL"
  expect "install into the Applications stand-in" status_is 0
  expect "  the copy is complete and its signature verifies" valid_copy "$APPS_ROOT/muxFinder.app"
  expect "  no temporary folder left, no ~/Applications created" \
    all_of no_stage_left "$APPS_ROOT" -- absent "$HOME_ROOT/Applications"

  inode="$(/usr/bin/stat -f '%i' "$APPS_ROOT/muxFinder.app")"
  run_script "$INSTALL"
  expect "reinstall over the existing copy" status_is 0
  expect "  replaced by a new folder that verifies" \
    all_of valid_copy "$APPS_ROOT/muxFinder.app" -- \
    differs "$inode" "$(/usr/bin/stat -f '%i' "$APPS_ROOT/muxFinder.app")" -- \
    no_stage_left "$APPS_ROOT"

  before="$(roots_snapshot)"
  run_script "$INSTALL" --dry-run
  expect "install --dry-run over a copy changes nothing" \
    all_of status_is 0 -- log_has "Would copy" -- same "$before" "$(roots_snapshot)"

  new_roots install-user
  before="$(roots_snapshot)"
  run_script "$INSTALL" --user --dry-run
  expect "install --user --dry-run on empty folders changes nothing" \
    all_of status_is 0 -- log_has "Would create" -- same "$before" "$(roots_snapshot)"
  run_script "$INSTALL" --user
  expect "install --user into the home stand-in's Applications" \
    all_of status_is 0 -- valid_copy "$HOME_ROOT/Applications/muxFinder.app" -- \
    absent "$APPS_ROOT/muxFinder.app" -- no_stage_left "$HOME_ROOT/Applications"

  new_roots install-missing
  before="$(roots_snapshot)"
  MUXFINDER_TEST_SOURCE="$SCENARIO/missing/muxFinder.app" run_script "$INSTALL"
  expect "no built app: refused, says to run build-app.sh" \
    all_of status_is 1 -- log_has "scripts/build-app.sh" -- \
    same "$before" "$(roots_snapshot)"

  new_roots install-other
  fake_bundle "$APPS_ROOT/muxFinder.app" com.example.other
  before="$(roots_snapshot)"
  run_script "$INSTALL"
  expect "another app at the destination: refused, left as it is" \
    all_of status_is 1 -- same "$before" "$(roots_snapshot)"

  new_roots install-link
  /bin/mkdir "$SCENARIO/elsewhere"
  /bin/ln -s "$SCENARIO/elsewhere" "$APPS_ROOT/muxFinder.app"
  before="$(roots_snapshot)"
  run_script "$INSTALL"
  expect "a symbolic link at the destination: refused, left as it is" \
    all_of status_is 1 -- same "$before" "$(roots_snapshot)"

  new_roots install-running
  fake_bundle "$APPS_ROOT/muxFinder.app"
  fake_bundle "$SCENARIO/elsewhere/muxFinder.app"
  start_stub "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxFinder"
  pid_app="$STARTED"
  start_stub "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxfinder-launch"
  pid_helper="$STARTED"
  start_stub "$SCENARIO/elsewhere/muxFinder.app/Contents/MacOS/muxFinder"
  pid_other="$STARTED"
  run_script "$INSTALL"
  expect "install over a running copy stops only that copy's muxFinder" \
    all_of status_is 0 -- gone "$pid_app" -- alive "$pid_helper" -- alive "$pid_other" -- \
    valid_copy "$APPS_ROOT/muxFinder.app" -- log_has "left running: muxfinder-launch"
  kill -KILL "$pid_helper" "$pid_other" 2>/dev/null || true

  new_roots install-stuck
  fake_bundle "$APPS_ROOT/muxFinder.app"
  start_stub "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxFinder" ignore-term
  pid_app="$STARTED"
  before="$(snapshot "$SCENARIO/apps")"
  MUXFINDER_TEST_STOP_WAIT=2 run_script "$INSTALL"
  expect "a copy that does not quit: refused after the wait, nothing changed" \
    all_of status_is 1 -- alive "$pid_app" -- log_has "still running" -- \
    same "$before" "$(snapshot "$SCENARIO/apps")"
  kill -KILL "$pid_app" 2>/dev/null || true
} # End of function install_steps

# Uninstall steps: full removal, the user's own muxFinder.json, a dry run, a symbolic link,
# running and stuck copies, a copy too old to check the profile file, the test-mode guard.
uninstall_steps() {
  local before profiles support pid_app pid_helper pid_other

  new_roots uninstall-full
  run_script "$INSTALL"
  run_script "$INSTALL" --user
  populate_home generated
  profiles="$HOME_ROOT/Library/Application Support/iTerm2/DynamicProfiles"
  support="$HOME_ROOT/Library/Application Support/muxFinder"
  before="$(siblings)"
  local everything
  everything="$(snapshot "$SCENARIO/home") $(snapshot "$SCENARIO/apps")"
  run_script "$UNINSTALL" --dry-run
  expect "uninstall --dry-run changes nothing" \
    all_of status_is 0 -- log_has "would remove $profiles/muxFinder.json" -- \
    log_has "Would remove $support" -- \
    same "$everything" "$(snapshot "$SCENARIO/home") $(snapshot "$SCENARIO/apps")"
  run_script "$UNINSTALL"
  expect "uninstall removes both app copies, no hidden folder left" \
    all_of status_is 0 -- absent "$APPS_ROOT/muxFinder.app" -- \
    absent "$HOME_ROOT/Applications/muxFinder.app" -- no_stage_left "$APPS_ROOT" -- \
    no_stage_left "$HOME_ROOT/Applications" -- \
    no_stage_left "$HOME_ROOT/Library/Application Support"
  expect "  removes the generated muxFinder.json through the app's binary" \
    all_of absent "$profiles/muxFinder.json" -- log_has "removed $profiles/muxFinder.json"
  expect "  leaves every other DynamicProfiles entry as it was" same "$before" "$(siblings)"
  expect "  removes the support folder" absent "$support"
  expect "  touches no preferences in test mode, prints the tccutil command" \
    all_of log_has "not touched in test mode" -- \
    log_has "tccutil reset AppleEvents $BUNDLE_ID"

  new_roots uninstall-user-file
  run_script "$INSTALL"
  populate_home user
  profiles="$HOME_ROOT/Library/Application Support/iTerm2/DynamicProfiles"
  before="$(siblings) $(/usr/bin/shasum -a 256 "$profiles/muxFinder.json")"
  run_script "$UNINSTALL"
  expect "a muxFinder.json that is not muxFinder's: left byte for byte" \
    all_of status_is 0 -- log_has "not muxFinder's generated file" -- \
    same "$before" "$(siblings) $(/usr/bin/shasum -a 256 "$profiles/muxFinder.json")" -- \
    absent "$APPS_ROOT/muxFinder.app"

  new_roots uninstall-link
  /bin/mkdir -p "$SCENARIO/target"
  printf 'keep\n' >"$SCENARIO/target/hosts.json"
  /bin/ln -s "$SCENARIO/target" "$HOME_ROOT/Library/Application Support/muxFinder"
  before="$(snapshot "$SCENARIO/target") $(snapshot "$HOME_ROOT/Library")"
  run_script "$UNINSTALL"
  expect "a symbolic link as support folder: refused, not followed" \
    all_of status_is 1 -- log_has "symbolic link; left as it is" -- \
    same "$before" "$(snapshot "$SCENARIO/target") $(snapshot "$HOME_ROOT/Library")"

  new_roots uninstall-running
  fake_bundle "$APPS_ROOT/muxFinder.app" "$BUNDLE_ID" interface
  fake_bundle "$SCENARIO/elsewhere/muxFinder.app"
  populate_home
  start_stub "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxFinder"
  pid_app="$STARTED"
  start_stub "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxfinder-launch"
  pid_helper="$STARTED"
  start_stub "$SCENARIO/elsewhere/muxFinder.app/Contents/MacOS/muxFinder"
  pid_other="$STARTED"
  run_script "$UNINSTALL"
  expect "uninstall stops only the removed copy's muxFinder" \
    all_of status_is 0 -- gone "$pid_app" -- alive "$pid_helper" -- alive "$pid_other" -- \
    absent "$APPS_ROOT/muxFinder.app" -- log_has "left running: muxfinder-launch" -- \
    log_has "also running from"
  kill -KILL "$pid_helper" "$pid_other" 2>/dev/null || true

  new_roots uninstall-stuck
  fake_bundle "$APPS_ROOT/muxFinder.app"
  populate_home generated
  start_stub "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxFinder" ignore-term
  pid_app="$STARTED"
  before="$(snapshot "$SCENARIO/home") $(snapshot "$SCENARIO/apps")"
  MUXFINDER_TEST_STOP_WAIT=2 run_script "$UNINSTALL"
  expect "a copy that does not quit: nothing removed" \
    all_of status_is 1 -- alive "$pid_app" -- log_has "still running" -- \
    same "$before" "$(snapshot "$SCENARIO/home") $(snapshot "$SCENARIO/apps")"
  kill -KILL "$pid_app" 2>/dev/null || true

  new_roots uninstall-old-copy
  fake_bundle "$APPS_ROOT/muxFinder.app"
  populate_home generated
  profiles="$HOME_ROOT/Library/Application Support/iTerm2/DynamicProfiles"
  before="$(/usr/bin/shasum -a 256 "$profiles/muxFinder.json")"
  run_script "$UNINSTALL"
  expect "no copy able to check the profile file: file left, run incomplete" \
    all_of status_is 1 -- log_has "left $profiles/muxFinder.json as it is" -- \
    same "$before" "$(/usr/bin/shasum -a 256 "$profiles/muxFinder.json")" -- \
    absent "$APPS_ROOT/muxFinder.app" -- \
    absent "$HOME_ROOT/Library/Application Support/muxFinder"
} # End of function uninstall_steps

# Processes that only map a copy's muxFinder (D27): never signalled, by install or uninstall;
# one whose executable cannot be established is never signalled and blocks the run.
reader_steps() {
  local before reader pid_reader pid_forged pid_other executable

  new_roots install-readers
  fake_bundle "$APPS_ROOT/muxFinder.app"
  executable="$APPS_ROOT/muxFinder.app/Contents/MacOS/muxFinder"
  reader="$SCENARIO/reader/reader"
  /bin/mkdir -p "$SCENARIO/reader"
  /bin/cp "$STUB" "$reader"
  start_reader "$reader" "$reader" "$executable"
  pid_reader="$STARTED"
  start_reader "$reader" "$executable" "$executable"
  pid_forged="$STARTED"
  run_script "$INSTALL"
  expect "install: processes that only map the copy's muxFinder (one with argv[0] naming it)" \
    all_of status_is 0 -- alive "$pid_reader" -- alive "$pid_forged" -- \
    valid_copy "$APPS_ROOT/muxFinder.app" -- log_lacks "stopping muxFinder" -- \
    log_has "muxFinder is not running from"
  kill -KILL "$pid_reader" "$pid_forged" 2>/dev/null || true

  new_roots uninstall-readers
  fake_bundle "$APPS_ROOT/muxFinder.app"
  fake_bundle "$SCENARIO/elsewhere/muxFinder.app"
  reader="$SCENARIO/reader/reader"
  /bin/mkdir -p "$SCENARIO/reader"
  /bin/cp "$STUB" "$reader"
  start_reader "$reader" "$reader" "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxFinder"
  pid_reader="$STARTED"
  start_reader "$reader" "$reader" "$SCENARIO/elsewhere/muxFinder.app/Contents/MacOS/muxFinder"
  pid_other="$STARTED"
  run_script "$UNINSTALL"
  expect "  uninstall: never signalled, and no muxFinder warning for a reader of another copy" \
    all_of status_is 0 -- alive "$pid_reader" -- alive "$pid_other" -- \
    absent "$APPS_ROOT/muxFinder.app" -- log_lacks "stopping muxFinder" -- \
    log_lacks "also running from"
  kill -KILL "$pid_reader" "$pid_other" 2>/dev/null || true

  new_roots install-unknown
  fake_bundle "$APPS_ROOT/muxFinder.app"
  /bin/cp "$STUB" "$SCENARIO/vanishing-reader"
  start_reader "$SCENARIO/vanishing-reader" "$SCENARIO/vanishing-reader" \
    "$APPS_ROOT/muxFinder.app/Contents/MacOS/muxFinder"
  pid_reader="$STARTED"
  # Its own executable deleted, the kernel's path for it no longer leads to a file.
  /bin/rm "$SCENARIO/vanishing-reader"
  before="$(snapshot "$SCENARIO/apps")"
  MUXFINDER_TEST_STOP_WAIT=2 run_script "$INSTALL"
  expect "  one whose executable cannot be established: not signalled, refused, nothing changed" \
    all_of status_is 1 -- alive "$pid_reader" -- log_has "could not tell" -- \
    log_lacks "stopping muxFinder" -- same "$before" "$(snapshot "$SCENARIO/apps")"
  kill -KILL "$pid_reader" 2>/dev/null || true
} # End of function reader_steps

# Deletions bound to the inspected folder (D27): the test hook swaps another folder in after
# the check; it must survive byte for byte and the run fail.
swap_steps() {
  local before support

  new_roots install-swapped
  fake_bundle "$APPS_ROOT/muxFinder.app"
  different_folder "$APPS_ROOT/different"
  before="$(tree_state "$APPS_ROOT/different")"
  MUXFINDER_TEST_SWAP_AT="$APPS_ROOT/muxFinder.app" \
    MUXFINDER_TEST_SWAP_WITH="$APPS_ROOT/different" run_script "$INSTALL"
  expect "install: the copy swapped for another folder after the check: it survives, exit 1" \
    all_of status_is 1 -- log_has "test hook" -- log_has "changed after it was checked" -- \
    same "$before" "$(tree_state "$APPS_ROOT/muxFinder.app")" -- no_stage_left "$APPS_ROOT"

  new_roots uninstall-swapped-copy
  fake_bundle "$APPS_ROOT/muxFinder.app"
  different_folder "$APPS_ROOT/different"
  populate_home
  before="$(tree_state "$APPS_ROOT/different")"
  MUXFINDER_TEST_SWAP_AT="$APPS_ROOT/muxFinder.app" \
    MUXFINDER_TEST_SWAP_WITH="$APPS_ROOT/different" run_script "$UNINSTALL"
  expect "  uninstall: an app copy swapped after the check: it survives byte for byte, exit 1" \
    all_of status_is 1 -- log_has "test hook" -- log_has "changed after it was checked" -- \
    same "$before" "$(tree_state "$APPS_ROOT/muxFinder.app")" -- no_stage_left "$APPS_ROOT" -- \
    absent "$HOME_ROOT/Library/Application Support/muxFinder"

  new_roots uninstall-swapped-support
  populate_home
  support="$HOME_ROOT/Library/Application Support/muxFinder"
  different_folder "$HOME_ROOT/different"
  before="$(tree_state "$HOME_ROOT/different")"
  MUXFINDER_TEST_SWAP_AT="$support" MUXFINDER_TEST_SWAP_WITH="$HOME_ROOT/different" \
    run_script "$UNINSTALL"
  expect "  uninstall: the support folder swapped after the check: it survives, exit 1" \
    all_of status_is 1 -- log_has "test hook" -- log_has "changed after it was checked" -- \
    same "$before" "$(tree_state "$support")" -- \
    no_stage_left "$HOME_ROOT/Library/Application Support"
} # End of function swap_steps

# Runs install.sh --dry-run in test mode with the home stand-in $1 and the applications
# stand-in $2 (the built app as source), appending its output to LOG, and prints its exit
# status. A dry run changes nothing even when the guard is broken.
guard_dry_run() {
  local status=0
  MUXFINDER_TEST_HOME="$1" MUXFINDER_TEST_APPLICATIONS="$2" MUXFINDER_TEST_SOURCE="$BUILT" \
    "$INSTALL" --dry-run >>"$LOG" 2>&1 || status=$?
  printf '%s' "$status"
}

# A listing of the real locations a broken guard would reach in guard_steps (read-only).
guarded_state() {
  real_state
  /bin/ls -lATi "$HOME/Applications" 2>&1 || true
  if absent "$HOME/Library/Applications"; then
    printf 'absent ~/Library/Applications\n'
  else
    printf 'present ~/Library/Applications\n'
  fi
} # End of function guarded_state

# The test-mode guard (D27): roots that are not private folders and derived paths that leave
# them are refused with exit 2 before anything; the swap hook is refused outside test mode.
guard_steps() {
  local alone statuses real_before before hook_status=0 outside

  # Both runs are dry runs, so even a broken guard could change nothing real.
  new_roots guard
  LOG="$SCENARIO/logs/guard.log"
  STATUS=0
  MUXFINDER_TEST_HOME="$HOME_ROOT" "$UNINSTALL" --dry-run >"$LOG" 2>&1 || STATUS=$?
  alone="$STATUS"
  STATUS=0
  MUXFINDER_TEST_HOME="$HOME" MUXFINDER_TEST_APPLICATIONS="$APPS_ROOT" "$INSTALL" --dry-run \
    >>"$LOG" 2>&1 || STATUS=$?
  expect "test-mode guard: one variable alone, or the real home, is refused (exit 2)" \
    all_of same "$alone" 2 -- status_is 2 -- log_has "go together" -- \
    log_has "must be a private folder"

  # Dry runs only: the real ~/Applications, /Applications, a folder inside the real home, a
  # path through a link into it, a link to a real folder, a folder others may write.
  new_roots guard-real
  LOG="$SCENARIO/logs/guard-real.log"
  : >"$LOG"
  /bin/ln -s "$HOME" "$SCENARIO/home-link"
  /bin/ln -s "$HOME/Applications" "$SCENARIO/apps-link"
  /bin/mkdir "$SCENARIO/open"
  /bin/chmod 777 "$SCENARIO/open"
  real_before="$(guarded_state)"
  statuses="$(guard_dry_run "$HOME_ROOT" "$HOME/Applications")"
  statuses="$statuses $(guard_dry_run "$HOME_ROOT" "/Applications")"
  statuses="$statuses $(guard_dry_run "$HOME/Library" "$APPS_ROOT")"
  statuses="$statuses $(guard_dry_run "$HOME_ROOT" "$SCENARIO/home-link/Applications")"
  statuses="$statuses $(guard_dry_run "$HOME_ROOT" "$SCENARIO/apps-link")"
  statuses="$statuses $(guard_dry_run "$HOME_ROOT" "$SCENARIO/open")"
  expect "  ~/Applications, /Applications, in the real home, through or as a link, open: exit 2" \
    all_of same "$statuses" "2 2 2 2 2 2" -- log_has "must be a private folder" -- \
    log_has "symbolic link" -- log_has "group or others may write" -- \
    log_lacks "Would" -- same "$real_before" "$(guarded_state)"

  # A derived folder that is a link out of the test folders, to a private decoy: a real run
  # of each script; it must be refused before anything happens there.
  new_roots guard-derived
  outside="$SCENARIO/outside"
  /bin/mkdir -p "$outside/apps" "$outside/library/Application Support/muxFinder"
  fake_bundle "$outside/apps/muxFinder.app"
  printf 'keep\n' >"$outside/library/Application Support/muxFinder/hosts.json"
  /bin/ln -s "$outside/apps" "$HOME_ROOT/Applications"
  /bin/rm -r "$HOME_ROOT/Library"
  /bin/ln -s "$outside/library" "$HOME_ROOT/Library"
  before="$(snapshot "$outside") $(roots_snapshot)"
  run_script "$INSTALL" --user
  alone="$STATUS"
  run_script "$UNINSTALL"
  expect "  a derived folder that links out of the test folders: refused (exit 2), untouched" \
    all_of same "$alone" 2 -- status_is 2 -- log_has "is a symbolic link" -- \
    log_lacks "App copy" -- same "$before" "$(snapshot "$outside") $(roots_snapshot)"

  # The library alone, in a subshell: no script runs, so nothing can be reached.
  LOG="$SCENARIO/logs/hook.log"
  (
    unset MUXFINDER_TEST_HOME MUXFINDER_TEST_APPLICATIONS
    MUXFINDER_TEST_SWAP_AT="$APPS_ROOT/muxFinder.app"
    MUXFINDER_TEST_SWAP_WITH="$SCENARIO/outside"
    # shellcheck source=../lib/app-copies.sh
    . "$ROOT/scripts/lib/app-copies.sh"
    mf_resolve_roots
  ) >"$LOG" 2>&1 || hook_status=$?
  expect "  the swap hook outside test mode: refused (the library's check alone)" \
    all_of same "$hook_status" 1 -- log_has "for checks only"
} # End of function guard_steps

# Whether $1 and $2 are equal.
same() {
  [ "$1" = "$2" ]
}

# Whether $1 and $2 differ.
differs() {
  [ "$1" != "$2" ]
}

# Runs several checks separated by "--" (each a command and its arguments); succeeds only when
# every one does, running them all.
all_of() {
  local ok=0 check=()
  while [ "$#" -gt 0 ]; do
    if [ "$1" = "--" ]; then
      if [ "${#check[@]}" -gt 0 ] && ! "${check[@]}"; then
        ok=1
      fi
      check=()
    else
      check+=("$1")
    fi
    shift
  done # End of loop over the arguments
  if [ "${#check[@]}" -gt 0 ] && ! "${check[@]}"; then
    ok=1
  fi
  return "$ok"
} # End of function all_of

setup
install_steps
uninstall_steps
reader_steps
swap_steps
guard_steps
LOG=""
if same "$(real_state)" "$(/bin/cat "$BASE/real-before.txt")"; then
  pass "real /Applications, ~/Applications, DynamicProfiles, support folder, preferences untouched"
else
  fail "real /Applications, ~/Applications, DynamicProfiles, support folder, preferences untouched"
fi
if [ "$FAILURES" -eq 0 ]; then
  printf 'test-install-scripts: passed (%d steps)\n' "$STEP"
  exit 0
fi
printf 'test-install-scripts: failed (%d of %d steps)\n' "$FAILURES" "$STEP"
exit 1
