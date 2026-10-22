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
- App bundle: `scripts/build-app.sh` → `build/muxFinder.app` (signed with the first "Apple
  Development" identity, or `MUXFINDER_SIGN_IDENTITY`)
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
- iTerm2 API check (read-only, prints JSON, never launches iTerm2): `swift run muxfinder-probe
  iterm2 status`, or `list-sessions`, `list-connections`, `list-profiles`, `attachments`
  (sends every tmux connection the read-only identity `display-message`; in unattended runs
  only while `list-connections` shows none of the user's). Prove `apiDisabled` with
  `--socket <missing path>`, never by quitting iTerm2 or sending a bogus cookie.
- Launch helper (iTerm2 runs it in a launch tab; by hand only for checks):
  `.build/debug/muxfinder-launch attach <uuid>` takes `<uuid>.request.json` from
  `~/Library/Application Support/muxFinder/launch/`. For checks, set
  `MUXFINDER_LAUNCH_DIRECTORY=<absolute private dir>` and a private `TMUX_TMPDIR`.
  `MUXFINDER_LAUNCH_TEST_MODE=1` (or a `test-mode` file in the launch directory) writes an
  argv digest and honors a request's `testLaunchDelaySeconds` (ignored outside test mode);
  `MUXFINDER_LAUNCH_NO_WAIT=1` skips the wait for Return and the 10 s minimum
  lifetime (on a terminal the helper never exits younger). Exit codes and the digest format:
  PLAN.md D14, `docs/TESTING.md`.
- iTerm2 golden fixtures (dev only; output committed, tests never run Python):
  `"$HOME/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3" -I
  scripts/dev/gen-iterm2-fixtures.py` → `Tests/MuxFinderCoreTests/Fixtures/iterm2/`.
- Real-world checks (open real iTerm2 windows; run explicitly, never from `swift test`, with
  `TMUX_TMPDIR` unset, after `swift build`: `swift run muxfinder-probe` does not rebuild the
  `muxfinder-launch` iTerm2 runs): `swift run muxfinder-probe e2e-local` (15 steps, about
  53 s) and `swift run muxfinder-probe e2e-remote saturno-m4` (16 steps, about 105 s; creates
  and kills only its own `muxfinder-test-*` sessions on Saturno over ssh and writes no file
  there; its `still waiting` step makes no login: the helper's test launch delay keeps that
  tab waiting before ssh, then the step closes the tab itself), both asking only their own
  launch tabs' connections; one-off `attach --local | --ssh <dest> --session '<$id>'`
  (focuses instead when the session is attached already; asks every tmux connection first,
  so the same caution as `iterm2 attachments`), `new-session --local | --ssh <dest> --name
  <name> [--dir <dir>]` (creates, then attaches; asks no connection; its pane runs the user's
  shell) and `detach --connection <id> --gateway <session id>` (see `docs/TESTING.md`).
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
