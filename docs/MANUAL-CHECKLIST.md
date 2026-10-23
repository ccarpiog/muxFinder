# Manual checklist

The checks only a person can make: they need clicks, a real login, a macOS permission prompt,
another Mac, or the user's own `/Applications` and iTerm2 profiles, all of which unattended
runs must not touch (`PLAN.md`, *Unattended-run rules*). Everything else is in
`docs/TESTING.md`, whose matrix points here by item number. Each item says what to do, what
to expect, how to undo it, and which phase left it open. Record the outcome in the table at
the end.

Before you start: iTerm2 running with its Python API on (iTerm2 › Settings › General › Magic ›
"Enable Python API"), and `scripts/build-app.sh` run on the current tree.

## 1. Install into /Applications

Owed by Phase 12a (the scripts ran only on private folders).

- **Do:** `scripts/install.sh --dry-run`, read it, then `scripts/install.sh`. Then
  `codesign --verify --deep --strict /Applications/muxFinder.app`. Later, with muxFinder
  running from `/Applications`, run `scripts/install.sh` again.
- **Expect:** "Installed /Applications/muxFinder.app (signed with: Apple Development: …; not
  notarized)", exit 0, and the codesign check exit 0. The second run first says "stopping
  muxFinder (pid …) with SIGTERM" and "muxFinder quit", then replaces the copy; tmux sessions
  and iTerm2 tabs stay as they were. The script never starts the app. If macOS asks whether
  your terminal may modify apps (App Management), that is macOS protecting `/Applications`;
  allow it or install with `--user`.
- **Undo:** item 13 (`scripts/uninstall.sh`).

## 2. First launch from Finder: the Automation prompt

Owed since Phase 3b: an app started through LaunchServices has its own identity, so macOS asks
once; started from a shell inside iTerm2 it never asks, which is how every real run so far
started it.

- **Do:** quit any running muxFinder. With iTerm2 running, double-click muxFinder in
  `/Applications`. If the onboarding window opens, do item 6 first. With at least one host
  turned on, click the menu bar icon (a terminal symbol).
- **Expect:** macOS asks whether "muxFinder" may control "iTerm2", with muxFinder's reason
  ("muxFinder asks iTerm2 for access to its Python API, so it can open your tmux sessions in
  iTerm2."). Allow: the popover lists hosts and sessions and nothing asks again. Don't Allow:
  opening a session fails with an explanation and "Open Automation settings", which opens
  System Settings › Privacy & Security › Automation. With the Python API off, the popover shows
  a notice with "How to turn it on".
- **Undo:** `tccutil reset AppleEvents cc.carpio.muxfinder` (the prompt comes back next time).

## 3. The popover by hand

Owed by Phase 8 (the real popover was never opened by a click) and by the matrix rows 1, 6, 7,
11 and 12 of `docs/TESTING.md`.

- **Do**, from the installed app with This Mac and Saturno turned on:
  1. Open the popover; type part of a host or session name in the search; ↑/↓; ⌘R; Esc.
  2. Return or a click on a session: it opens in iTerm2. Click it again: its tab comes forward.
  3. ⌘N: create a session (host, a name such as `manual-check`, optionally a directory).
  4. Right-click a session open here: "Detach from this Mac"; right-click a session attached
     on another Mac: "Move here…", read the confirmation, Cancel (or confirm, if you mean it).
  5. With a session of the same name on Saturno and on this Mac (`tmux new -d -s same` on
     both), look at both rows; open each.
  6. Turn on a host that is offline (Sirio when it sleeps, or a made-up destination such as
     `offline.invalid`) and use the popover while it is checked.
  7. Quit from the popover.
- **Expect:** 1: matching rows only, the selection moves, a refresh spinner, Esc closes. 2:
  "Opening…", "Waiting for iTerm2…", "Confirmed — open in iTerm2 on this Mac", the session's
  windows as native iTerm2 tabs; the second click says "Already open here — brought its tab
  forward". 3: the session is created and opened; the same name again is refused with "Open
  existing" offered. 4: detach leaves the session running (it reappears as Detached); the
  Move here text says the other clients will be detached. 5: two separate rows under two
  hosts, each opening its own host's session. 6: the popover stays responsive; the host shows
  "Unreachable" (and, if it had sessions, "Last seen … · not live"). 7: muxFinder leaves the
  menu bar; every tmux session and iTerm2 tab is still there.
- **Undo:** detach and kill the sessions you made (`/opt/homebrew/bin/tmux kill-session -t
  '=manual-check'`, the same for `same` on both Macs); turn the offline host off again.

## 4. Launch at login from /Applications

Owed by Phase 9a (registering changes the user's login items).

- **Do:** Settings › General: turn on "Open muxFinder when you log in". Look at System
  Settings › General › Login Items (approve muxFinder if asked; the General tab offers "Open
  Login Items settings" when approval is needed). Log out and in. Then turn the switch off.
- **Expect:** the switch stays on and its note matches; muxFinder is listed under Login Items
  and is in the menu bar after logging in; turning it off removes it.
  `/Applications/muxFinder.app/Contents/MacOS/muxFinder --report-login-item-status` (read-only)
  prints `enabled` while on and `notRegistered` after.
- **Undo:** turn the switch off.

## 5. Settings window by hand

Owed by Phase 9a.

- **Do:** open Settings from the popover's "Settings" and with ⌘, while the popover is open,
  with the Settings window behind another window. In a host's fields try ⌘A, ⌘C, ⌘X, ⌘V, ⌘Z.
  If an "Open Automation settings" or "Open Login Items settings" button shows (items 2 and
  4), click it.
- **Expect:** the window comes to the front each time; the editing keys work; each button
  opens its System Settings pane.
- **Undo:** "Revert" any unsaved edit.

## 6. Onboarding by hand

Owed by Phase 9b.

- **Do:** on a Mac without `~/Library/Application Support/muxFinder/hosts.json` (a fresh
  install, or after item 13), start muxFinder. In the onboarding window choose This Mac, give
  Saturno its destination (`saturno-m4`) and turn it on, then "Save hosts". Another time, try
  "Not now".
- **Expect:** the window explains the four points (the host must stay on and reachable, a
  disconnected client does not end a session, a reboot ends running processes, nothing is
  synced or moved); after saving, the popover shows the hosts and the window does not come
  back. "Not now" closes it without saving, so it shows again at the next launch. If the save
  is refused (for example, a host list was saved elsewhere meanwhile), it offers "Open
  Settings".
- **Undo:** Settings › Hosts.

## 7. "Set up SSH in iTerm2…" for real

Owed by Phase 9b; the Phase 10b decision left it to the user because it is an interactive ssh
login.

- **Do:** for a host that shows "Sign-in needed" or "Host key problem" (or from its editor in
  Settings), click "Set up SSH in iTerm2…".
- **Expect:** iTerm2 opens a tab running `ssh` to that destination; sign in or accept the host
  key the normal way, then type `exit`. The tab closes once it is at least 10 s old. The next
  refresh shows the host as "Reachable" or "No sessions". A failure is explained in the tab,
  which waits for Return.
- **Undo:** nothing to undo; accepting a host key adds it to `~/.ssh/known_hosts`, as ssh
  always does.

## 8. "Show tab"

Owed by Phases 10a and 10b (local attaches confirm in well under a second, so the state was
only produced by the probe's test delay, never with the app's button).

- **Do:** whenever an open takes longer than 20 s (a slow network, or a login in the tab
  waiting for your input), click "Show tab" on the row's "Still connecting — check the iTerm2
  tab".
- **Expect:** iTerm2 brings that launch tab forward; finishing the login there confirms the
  open; closing the tab ends it with an explanation in the popover.
- **Undo:** nothing.

## 9. Gatekeeper with a copied app (optional)

The README's statement about quarantined copies was not tried.

- **Do:** send `muxFinder.app` to another Mac with AirDrop (or download it), move it to
  `/Applications`, double-click it.
- **Expect:** a build from `scripts/build-app.sh`: macOS refuses to open it at first (not
  notarized); System Settings › Privacy & Security offers "Open Anyway". A notarized build from
  `scripts/release.sh` (send `build/muxFinder.zip`): macOS asks once whether to open an app
  from the internet, then opens it. A copy made with `ditto`, `rsync` or `scp` opens directly.
- **Undo:** delete that copy.

## 10. Sirio (`sirio-m5`)

Owed since planning: Sirio was offline during every phase.

- **Do:** when Sirio is awake, on Neptuno turn on a Sirio host (SSH, destination `sirio-m5`);
  open one of its sessions; create one with New session. Install muxFinder on Sirio too
  (build there, or copy the app), choose Sirio as This Mac there, and from Sirio open a
  session of Neptuno and one of Saturno; try "Move here…" between two Macs.
- **Expect:** the same as for Saturno: status, sessions, open, create, move. With Sirio
  asleep: "Unreachable", with its last sessions marked "not live".
- **Undo:** kill the sessions you made; turn the host off if you do not want it.

## 11. Persistent profiles from the installed app

Owed by Phases 11b and 11c (the real runs used the probe's harness, never the Settings
buttons, the default profile or a second tab).

- **Do:**
  1. Settings › Hosts: turn on "Persistent profile" for This Mac (session `main` or your
     choice), Save. Settings › Persistent profiles › "Install profiles".
  2. Look at iTerm2 for a moment after installing.
  3. iTerm2 › Settings › Profiles: find "Persistent work – <host>". Open a new tab with it.
  4. Open a second tab with the same profile.
  5. Make it the default (select it, Other Actions › Set as Default) and open a new window.
  6. Settings › Persistent profiles › "Remove profiles".
- **Expect:** 1: "Installed 1 profile in iTerm2." and the status "Installed and up to
  date."; only `muxFinder.json` appears in
  `~/Library/Application Support/iTerm2/DynamicProfiles`. 2: no "Dynamic Profiles Error"
  alert (if one shows, note its text). 3: the tab attaches session `main` in tmux control mode
  (created if missing; its windows as native tabs). 4: the same session is attached once more;
  iTerm2 may show its windows a second time (untried; note what happens). 5: new windows open
  in the session. 6: the profile disappears from iTerm2; your other profiles are as before.
- **Undo:** before step 6, set your previous default profile back as the default; then
  "Remove profiles". Turn the host's switch off.

## 12. Unknown parent profile, and moving the app

Owed by Phases 11b (the fallback was never tried) and 11c (a launch after moving the app).

- **Do (parent):** make a throwaway iTerm2 profile (for example "Parent check"), choose it as
  the host's "Parent profile", Save, "Install profiles", then delete the throwaway profile in
  iTerm2 and open a tab with the "Persistent work" profile.
- **Expect:** the tab still works, based on iTerm2's default profile (iTerm2 3.7.6 logs "Using
  default profile as parent"); note any alert.
- **Do (moving):** with profiles installed, quit muxFinder, `scripts/install.sh --user`,
  start `~/Applications/muxFinder.app`, open Settings › Persistent profiles; then quit it,
  remove `~/Applications/muxFinder.app` and start the `/Applications` copy again.
- **Expect:** each launch brings the installed file up to date for its own helper path: the
  Persistent profiles tab says "Installed and up to date.", and the file's `Command` names the
  copy that is running.
- **Undo:** clear the parent and Save; "Remove profiles" if you do not keep them; make sure
  only one copy of the app is left.

## 13. Uninstall for real

Owed by Phase 12a (the script ran only on private folders).

- **Do:** turn off "Open muxFinder when you log in" (item 4). If you will reinstall, back up
  your host list: `cp ~/Library/Application\ Support/muxFinder/hosts.json
  ~/muxfinder-hosts-backup.json`. Then `scripts/uninstall.sh --dry-run`, read it, and
  `scripts/uninstall.sh`.
- **Expect:** muxFinder quits; "removed …/DynamicProfiles/muxFinder.json" (only if it was
  muxFinder's), the support folder, each app copy and the preferences domain removed; any
  `muxfinder-launch` still running in an iTerm2 tab is named and left; exit 0. Your tmux
  sessions, other iTerm2 profiles and `~/.ssh` are unchanged. Then, if you want, `tccutil reset
  AppleEvents cc.carpio.muxfinder`, and check System Settings › General › Login Items.
- **Undo:** item 1, then copy the backup back to
  `~/Library/Application Support/muxFinder/hosts.json` before the first launch.

## Results

| Item | Date | Result | Notes |
|---|---|---|---|
| 1 | | | |
| 2 | | | |
| 3 | | | |
| 4 | | | |
| 5 | | | |
| 6 | | | |
| 7 | | | |
| 8 | | | |
| 9 | | | |
| 10 | | | |
| 11 | | | |
| 12 | | | |
| 13 | | | |
