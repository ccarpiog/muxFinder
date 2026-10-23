# muxFinder — agent instructions

A native macOS menu bar app (SwiftUI + AppKit) that discovers tmux sessions on the user's Macs and
attaches them in iTerm2 through native tmux control mode (`tmux -CC`). Product brief:
`docs/REQUIREMENTS.md`. Phased plan, architecture, decisions and verified environment facts:
`PLAN.md`. Progress checkpoint (written by autoclaude runs): `PROGRESS.md`.

## Language and text

- **User-facing text is English**, in sentence case ("New session", "Move here", "Last checked
  2 min ago"). No Title Case in UI strings or doc headings.
- Code comments, docs, README and commit messages are English.

## Code conventions

- Swift 6 language mode, SwiftPM only (no `.xcodeproj`). Deployment target macOS 14, arm64.
- Every function, method and type gets a `///` doc comment.
- Any function or loop longer than 10 lines ends with a closing-brace comment saying what ends,
  e.g. `} // End of func attach(_:)` or `} // End of loop over discovered sessions`.
- No third-party dependencies without recording the reason in `PLAN.md` *Decisions*. The iTerm2
  client is hand-written (D1); never add SwiftProtobuf or code generated from iTerm2's
  `api.proto` (GPLv2, this repo is MIT). iTerm2's installed Python module is a read-only
  protocol reference — never copy its code.
- Never build shell or AppleScript source by inserting runtime values. Local processes use argv
  arrays; remote commands follow PLAN.md D3 (static script + POSIX single-quoted arguments).
- No terminal contents, window titles or command lines containing user data in logs, fixtures
  or docs.

## Commands

- Build: `swift build`
- Unit tests (hermetic): `swift test`
- Format lint: `swift format lint -r Sources Tests`
- App bundle: `scripts/build-app.sh` → `build/muxFinder.app` (release arm64, with
  `muxfinder-launch` in `Contents/MacOS/`; signed with hardened runtime by the first "Apple
  Development" identity, or `MUXFINDER_SIGN_IDENTITY`, else ad hoc with a warning; never
  notarized). Check it with `codesign --verify --deep --strict build/muxFinder.app`.
- Preview fixtures (no menu bar item, engine, host list, login item or iTerm2; one normal
  window with every popover state, or with `--preview-gallery settings` every Settings window
  state, with `--preview-gallery onboarding` every onboarding window state, or with
  `--preview-gallery attach` every session-action state, from synthetic data, shown without
  taking the focus):
  `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures [--preview-gallery
  popover|settings|onboarding|attach] [--appearance light|dark]` prints `muxFinder preview
  window <n> …`; capture only that window with `screencapture -x -o -l <n> <file.png>`, then
  `kill -TERM` it (exit 0). With a locked screen or a sleeping display `screencapture` fails:
  add `--preview-snapshot <file.png>`, which renders the window into the PNG from inside the
  app and quits. Screenshots live in `docs/screenshots/` (`popover-states-*.png`,
  `settings-states-*.png`, `onboarding-states-*.png`, `attach-states-*.png`); never capture
  the screen or another app's window.
- Login item check (read-only; registers nothing, opens no window or menu bar item, reads no
  host list, never contacts iTerm2):
  `build/muxFinder.app/Contents/MacOS/muxFinder --report-login-item-status` prints
  `SMAppService.mainApp.status` and exits 0. Never call `register`/`unregister` for real
  (that changes the user's login items); the toggle's real round trip is the user's.
- App shell check (normal mode; contacts no iTerm2 while no host is enabled and the popover
  stays closed; never through `open`/LaunchServices):
  `build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &` prints the menu bar
  item's windows after 2 s (macOS 27 draws the item outside the app, so `CGWindowList` does
  not show it under the app's pid); without a `hosts.json` it also shows the onboarding
  window, which contacts nothing; then `kill -TERM <pid>` must exit 0 with no child left
  and no `hosts.json` created. See `docs/TESTING.md` (Phases 8 and 9b).
- App self-tests (real runs: they open real iTerm2 windows; run explicitly, never from `swift
  test`, with `TMUX_TMPDIR` unset, after `scripts/build-app.sh`, with the same iTerm2
  thread-count caution as the e2e runs below; never through `open`/LaunchServices):
  `build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local` (create a
  `muxfinder-test-*` session, Open five times → confirmed with one launch, Open again →
  focused, Detach from this Mac, kill) or `--selftest new-session-local` (New session →
  confirmed, the same name → collision, Detach, kill). They drive the real `AppModel` over an
  in-memory This Mac (no `hosts.json` read or written; no menu bar item, popover, onboarding
  or Settings), ask only their own launch tabs' tmux connections, print one PASS/FAIL line
  per step, bound every wait, clean up (detach through the core, never closing a tab, then
  kill their own session) on any failure or SIGTERM/SIGINT, and exit 0 passed, 1 failed, 2
  unusable arguments or environment (nothing contacted). `--selftest-keep` stops once the
  attachment is confirmed, prints `muxFinder self-test keep: session <name> connection <id>
  gateway <session id>` and waits; `kill -TERM <pid>` quits normally (exit 0) leaving both;
  then clean up with `swift run muxfinder-probe detach --connection <id> --gateway <session
  id>` and `/opt/homebrew/bin/tmux kill-session -t '=<name>'`. See `docs/TESTING.md` (Phase
  10a) and PLAN.md D25.
- Discovery check (read-only, prints JSON; `--raw` prints the probe report):
  `swift run muxfinder-probe discover --local` or `discover --ssh saturno-m4`. Prove "no
  server" with `TMUX_TMPDIR=$(mktemp -d /tmp/mfx.XXXXXX)`, never by stopping a real server.
- Host configuration check (read-only, prints JSON; creates no folder or file, runs no ssh,
  never contacts iTerm2): `swift run muxfinder-probe hosts show [--config <path>]` (the host
  list and its load state: `saved`, `notSavedYet` with the onboarding defaults, or `invalid`
  with the problem, the file left as it is; `--config` needs a folder of yours that is not a
  symbolic link, such as one from `mktemp -d`) and `hosts suggestions` (`Host` names from
  `~/.ssh/config` and its includes; they are the user's, so never paste them into docs,
  fixtures or logs). Test a save only through `HostStore` on a private folder, never on
  `~/Library/Application Support/muxFinder/hosts.json`.
- Persistent profile checks (read-only, print JSON; write no file, never contact iTerm2):
  `swift run muxfinder-probe profiles show [--config <path>] [--helper <path>]` prints the
  `DynamicProfiles/muxFinder.json` document the app would install for the host list (loaded
  like `hosts show`; one "Persistent work" profile per host whose persistent profile is on;
  a helper path iTerm2 could split wrongly is refused), and `profiles hashes [--directory
  <path>]` prints names, kinds and SHA-256 digests of every other `DynamicProfiles` entry and
  the count and digest of `New Bookmarks` (`/usr/bin/defaults export com.googlecode.iterm2 -`,
  never `defaults write`), never a profile's contents. Install or remove profiles in checks
  only through `PersistentProfileInstaller` on a private folder, never on the real
  `~/Library/Application Support/iTerm2/DynamicProfiles/` (`e2e-profile` aside). PLAN.md D26.
- Refresh engine check (prints JSON, opens no window, writes nothing): `swift run
  muxfinder-probe refresh --once [--config <path>] [--attachments]` loads the host list like
  `hosts show` (a private `hosts.json` from `mktemp -d` for checks), refreshes every enabled
  host once through `RefreshCoordinator` (This Mac directly, SSH hosts with discovery's
  noninteractive ssh; only `saturno-m4` in unattended runs) and prints the snapshots. Without
  `--attachments` it never contacts iTerm2; `--attachments` asks every tmux connection, so
  the same caution as `iterm2 attachments`.
- iTerm2 API check (read-only, prints JSON, never launches iTerm2): `swift run muxfinder-probe
  iterm2 status`, or `list-sessions`, `list-connections`, `list-profiles`, `attachments`
  (sends every tmux connection the read-only identity `display-message`; in unattended runs
  only while `list-connections` shows none of the user's). Prove `apiDisabled` with
  `--socket <missing path>`, never by quitting iTerm2 or sending a bogus cookie.
- Launch helper (iTerm2 runs it in a launch tab; by hand only for checks):
  `.build/debug/muxfinder-launch attach <uuid>` takes `<uuid>.request.json` from
  `~/Library/Application Support/muxFinder/launch/`; `muxfinder-launch ssh-setup <uuid>`
  ("Set up SSH in iTerm2…", PLAN.md D24) takes only an ssh setup request (`"kind":"sshSetup"`;
  each mode refuses the other kind with 72) and runs plain interactive
  `/usr/bin/ssh -- <destination>`, so never run it by hand with a real request: it starts a
  real ssh login. `muxfinder-launch profile <host id>` (a "Persistent work" profile's tab,
  PLAN.md D26) takes no request: it reads `hosts.json` read-only and runs `tmux -u -CC
  new-session -A -s <name>` (over interactive ssh for an SSH host), and with `TMUX` or
  `MUXFINDER_LAUNCHED` set, or on any failure, execs the login shell; so by hand only in test
  mode with `MUXFINDER_LAUNCH_NO_WAIT=1` (then no shell is started and the host comes from a
  `profile-test-<host id>.json` host list in the launch directory, never the real
  `hosts.json`). For checks, set
  `MUXFINDER_LAUNCH_DIRECTORY=<absolute private dir>` and a private `TMUX_TMPDIR`.
  `MUXFINDER_LAUNCH_TEST_MODE=1` (or a `test-mode` file in the launch directory) writes an
  argv digest and honors a request's `testLaunchDelaySeconds` (ignored outside test mode);
  `MUXFINDER_LAUNCH_NO_WAIT=1` skips the wait for Return and the 10 s minimum
  lifetime (on a terminal the helper never exits younger). Exit codes and the digest format:
  PLAN.md D14, D26, `docs/TESTING.md`.
- iTerm2 golden fixtures (dev only; output committed, tests never run Python):
  `"$HOME/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3" -I
  scripts/dev/gen-iterm2-fixtures.py` → `Tests/MuxFinderCoreTests/Fixtures/iterm2/`.
- Real-world checks (open real iTerm2 windows; run explicitly, never from `swift test`, with
  `TMUX_TMPDIR` unset, after `swift build`: `swift run muxfinder-probe` does not rebuild the
  `muxfinder-launch` iTerm2 runs): `swift run muxfinder-probe e2e-local` (16 steps, about
  65 s) and `swift run muxfinder-probe e2e-remote saturno-m4` (17 steps, about 123 s; creates
  and kills only its own `muxfinder-test-*` sessions on Saturno over ssh and writes no file
  there; its `still waiting` step makes no login: the helper's test launch delay keeps that
  tab waiting before ssh, then the step closes the tab itself), both asking only their own
  launch tabs' connections; their `move here` step attaches a plain `tmux -C` client of
  their own to their own session (over ssh with BatchMode remotely) and ends it on every way
  out; one-off `attach --local | --ssh <dest> --session '<$id>'`
  (focuses instead when the session is attached already; asks every tmux connection first,
  so the same caution as `iterm2 attachments`), `new-session --local | --ssh <dest> --name
  <name> [--dir <dir>]` (creates, then attaches; asks no connection; its pane runs the user's
  shell), `ssh-setup --ssh <dest> [--profile <name>]` (opens a tab running plain interactive
  ssh, a real login; never in unattended runs, its real run owed with Saturno only) and
  `detach --connection <id> --gateway <session id>` (see `docs/TESTING.md`).
  `swift run muxfinder-probe e2e-profile --local | --ssh saturno-m4` (14 steps; PLAN.md D26)
  writes the real `DynamicProfiles/muxFinder.json` for a test host and opens it with
  `CreateTab`: it refuses to start when that file or a `muxfinder-test-profile` session
  exists, creates that session itself (`sleep 600` panes), never reads or writes the real
  `hosts.json` (its host list is a test file in the launch directory, read by the helper in
  test mode), asks only its own tab's connection, detaches it after 10 s, kills only its
  session, removes only the file it wrote, and compares the hash snapshot of iTerm2's other
  profiles before install, after install and after removal; its remote tab runs interactive
  ssh (key authentication; Saturno only).
  Check `muxfinder-probe iterm2 status` and iTerm2's thread count (`ps -M -p <pid> | wc -l`)
  before and after; each run adds about 12 blocked iTerm2 workers that are reclaimed within
  minutes, so let the count fall back between runs (the API stalls at 64 workers). A timeout
  means a modal iTerm2 dialog or an API stall, as does a count that keeps growing: stop and
  report, never script the UI.

## Environment

- This Mac is Neptuno (`neptuno-m4`). Saturno is `saturno-m4` (reachable over Tailscale with key
  auth). Sirio is `sirio-m5` and is often offline. No `Host` blocks exist for them in
  `~/.ssh/config`; OpenSSH resolves the names via Tailscale MagicDNS.
- tmux 3.8 lives at `/opt/homebrew/bin/tmux` on Neptuno and Saturno; noninteractive SSH PATH does
  not include it.
- iTerm2 3.7.6 with the Python API server enabled. API socket:
  `~/Library/Application Support/iTerm2/private/socket`.

## Safety rules for tests and automation (binding)

These mirror PLAN.md *Unattended-run rules*. The user's live work shares this Mac, this iTerm2
instance and these tmux servers.

- Only create, attach, detach or kill tmux sessions named `muxfinder-test-*`. Never
  `kill-server`.
- Never close, send text to, or otherwise touch iTerm2 windows/tabs/sessions the current test did
  not create. Detach tmux attachments with `detach-client`; never close tmux tabs to detach.
- Remote hosts: only `saturno-m4`, only for discovery and `muxfinder-test-*` sessions, no remote
  file writes.
- Never write iTerm2 preferences, other iTerm2 profiles, `~/.ssh/*` or shell startup files. The
  app owns only `~/Library/Application Support/iTerm2/DynamicProfiles/muxFinder.json` and
  `~/Library/Application Support/muxFinder/`.
- Do not launch `muxFinder.app` via LaunchServices in unattended runs (it triggers the macOS
  Automation prompt nobody can answer); run the bundle binary directly from the shell instead.
- No UI scripting or synthesized keystrokes, ever.
