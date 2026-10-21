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
- Real-world checks (open real iTerm2 windows; run explicitly, never from `swift test`):
  `swift run muxfinder-probe e2e-local`, `swift run muxfinder-probe e2e-remote saturno-m4`
  (available once the corresponding phase lands; see `docs/TESTING.md`).

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
