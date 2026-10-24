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
  windows as native iTerm2 tabs and no launch tab window (item 14); the second click says
  "Already open here — brought its tab forward". 3: the session is created and opened; the same name again is refused with "Open
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

## 14. The hidden launch tab

Owed by Phase 13c (the real runs drove the core and the self-tests, never the popover; nobody
looked at the screen or pressed a key; they ran only with iTerm2's auto-hide setting off).

- **Do**, from the installed app with This Mac and Saturno turned on:
  1. Open a detached session of each host from the popover; also try New session and, with a
     session attached on another Mac, "Move here…". While attached, look at iTerm2's Session ›
     Buried Sessions menu.
  2. A while later (more than 10 s after opening), "Detach from this Mac". Note which window
     has the focus afterwards, and whether anything comes to the front.
  3. Open a session and detach it again within 10 s.
  4. The abnormal end: open a session of This Mac that no other Mac has attached (such as
     `manual-check`), then end only iTerm2's tmux client for it:
     `/opt/homebrew/bin/tmux list-clients -t '=manual-check' -F '#{client_pid}
     #{client_control_mode}'` and `kill -9` the pid whose second field is `1`. For Saturno,
     with only one of its sessions open here (and no "Persistent work" tab of it), `kill -9`
     the launch tab's local ssh instead (the pid
     `pgrep -fl 'ssh -t -o ConnectTimeout=10 -- saturno-m4'` lists), and only when `ssh -G
     saturno-m4` shows `controlmaster false`, so no shared connection ends with it.
  5. iTerm2 › Settings › General › tmux: turn on "Automatically bury the tmux client session
     after connecting" (note how it was), then repeat 1–3.
- **Expect:** 1: only the session's windows show, no window with "tmux mode started" or the
  tmux command menu; the launch tab is listed under Session › Buried Sessions while attached
  (a sign-in or host key prompt over ssh shows in the tab before it is hidden). 2: the tab
  shows for a moment in a window of its own and closes by itself; nothing stays under Buried
  Sessions (note where the focus went). 3: the tab shows and stays until it is 10 s old, then
  closes by itself. 4: the session's windows close, the launch tab comes back within a few
  seconds with the explanation readable, and Return closes it (once it is 10 s old); the
  session is still listed in the popover. 5: the same as 1–3.
- **Undo:** put iTerm2's auto-hide setting back as it was; detach and kill `manual-check`.

## 15. The popover's look

Owed by Phase 14 (its new look was seen only in the preview galleries; nobody opened the real
popover, which since Phase I-1b is muxFinder's own panel, PLAN.md D30).

- **Do:** from the installed app with This Mac, Saturno and Sirio turned on, open the popover
  while Sirio is offline (asleep or away), in light and in dark appearance (System Settings
  › Appearance), over a busy or colorful desktop picture. Select a session open in iTerm2
  here with ↑/↓, hover a few rows, and press "Retry" on Sirio.
- **Expect:** it matches `docs/screenshots/popover-states-light.png` and `-dark.png`: an
  opaque background (no desktop showing through, and no square corners poking out of the
  window's rounded ones), one bordered box per host with a header band, a mark at the start
  of each row (blue window here, green dot attached elsewhere, gray ring detached, dim clock
  not live; a gray dot in a dashed ring, attached with the location unknown, only while the
  iTerm2 check has failed or not finished), "Open in iTerm2 here" easy to read with and without the selection (a gray fill
  with a blue outline), Sirio muted (a hollow gray dot, its name gray, a gray info icon, no
  red or orange) while a host needing a sign-in or a host key check stays orange, "Retry"
  working, and the footer's icons clearly closer to their own titles than to the next
  button, "Quit" at the right. The popover is as wide as before and closes with Esc.
- **Undo:** nothing.

## 16. The popover under the menu bar icon

Owed by Phase I-1b (PLAN.md Phase I-1, D30): the placement diagnostic opened the panel through
the button's own action and measured it under the icon on the main display, but with the
screen locked and both displays asleep, and no unattended run may click the real icon, use
another display's copy of it, or press keys.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), with
  both displays on and This Mac turned on:
  1. Click muxFinder's icon in the main display's menu bar, then in the other display's menu
     bar. Click it again on the same display.
  2. ⌘-drag the icon to another place in the menu bar (it must stay in the bar; dragging it
     out quits the app), then click it.
  3. With the popover open: press Esc; open it, click the desktop or another app's window;
     open it, switch apps with ⌘Tab; open it, click another menu bar item.
  4. Open it and type at once (the search field must have the focus); then ↑/↓, Return on a
     session, ⌘F, ⌘R, ⌘N (then Esc), ⌘, (Settings opens and the popover closes).
  5. Put an app in full screen (its own Space), move the pointer to the top to show the menu
     bar, click muxFinder's icon; then try another Space.
  6. Turn a few hosts on and off in Settings, or search, so the popover grows and shrinks
     while open.
- **Expect:** 1: each time the popover opens directly below the icon you clicked, on that
  display, its middle on the icon's and its top edge touching the menu bar, never at the far
  right; the second click on the same display closes it, and a click on the other display's
  icon while it is open moves it there. 2: it opens below the icon's new place. 3: each closes
  it, and the icon's highlight goes with it; the app you were in keeps its menu bar
  throughout. 4: the text goes into the search field; every shortcut works as in item 3. 5: it
  opens over the full-screen app without switching Spaces, and on whichever Space is active.
  6: its top edge stays under the menu bar while its height changes. The look is item 15's.
- **Undo:** ⌘-drag the icon back where you want it.

## 17. New session's directory list

Owed by Phase I-2b (PLAN.md Phase I-2, D31): the list's content, picking, its keys and the
Settings tab are unit-tested and rendered in the galleries, but no unattended run may click
the real popover, press keys in it or create a session from the real app, and the real
`directories.json` is the user's.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), with
  This Mac and Saturno turned on and a tmux session on each started in a folder of yours
  (`tmux new-session -d -s muxfinder-test-dir -c <folder>`):
  1. ⌘N, This Mac, name `muxfinder-test-recent`, a directory of yours typed in Directory;
     Create. Detach the session afterwards ("Detach from this Mac").
  2. ⌘N again, This Mac: click the button at the end of Directory. Pick the directory from
     "Recent", name `muxfinder-test-recent2`, Create.
  3. ⌘N, This Mac, type a directory; open the list and choose "Save this directory". Then
     Settings › Directories: it is listed; add another one, move it up, remove one, Save; Revert
     after an unsaved change. Then remove one entry in the tab without saving, save another
     directory from New session's list, and Save in the tab.
  4. ⌘N, This Mac: pick a directory from "Saved", name `muxfinder-test-saved`, Create.
  5. ⌘N, This Mac: pick the folder of `muxfinder-test-dir` from "Sessions on <host>", name
     `muxfinder-test-folder`, Create.
  6. Steps 2, 4 and 5 again with Saturno chosen (a saved `~/…` directory resolves in
     Saturno's home folder; its own recents and session folders are listed, not This Mac's).
     Change the host while the field holds text, with the list open.
  7. Keys, in New session with the cursor in Directory: ⌥↓ (the list opens on its first row),
     ↑/↓ (the highlight moves, the session list behind does not), Return (the highlighted
     directory fills the field and the list closes), ⌥↓ then Esc (only the list closes), Esc
     again (New session closes). Open the list with the mouse and press Return with nothing
     highlighted (New session creates). ⌥↓, then type in Directory and press Return (the
     highlight went with the typing; New session creates in what you typed, name
     `muxfinder-test-typed`). With macOS's keyboard navigation on (System Settings ›
     Keyboard), Tab to the button and press Space.
  8. "Clear recent directories on <host>" for This Mac; reopen the list.
  9. Kill every `muxfinder-test-*` session you made (`tmux kill-session -t '=<name>'`, and over
     ssh on Saturno).
- **Expect:** 1–6: each session is created in the directory picked (its first pane starts
  there; on Saturno `~/…` is Saturno's home), and the directory used becomes that host's first
  "Recent" entry; long paths are shortened in the middle, with the full path as the row's help.
  3: the saved list matches the tab after Save, and New session lists it for both hosts; the
  last Save removes only the entry removed in the tab and keeps the one saved from New
  session (the tab then lists it). 6:
  the list follows the host, and the field keeps its text. 7: as described, and every other
  popover key works as in item 16. 8: "Recent" disappears for This Mac only. With nothing
  recent, saved or reported, the list says "Nothing to pick yet".
- **Undo:** remove the saved entries in Settings › Directories (Save) and clear the recent
  ones from New session's list.

## 18. The session switcher and its shortcut

Owed by Phases I-3a and I-3b (PLAN.md Phase I-3, D32): the shortcut's checks, storage,
registration lifecycle and recorder, and the switcher's content, keys, actions and visibility
rule, are unit-tested over fakes, `--report-hotkey-registration` showed that registration works
in the signed bundle, and the switcher's states were rendered from fixtures, but no unattended
run may press a key, record in the real Settings window, write the real `preferences.json` or
open the real switcher panel.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), with
  This Mac and Saturno turned on and at least one session on each:
  1. Settings › General › "Session switcher": the field says "Record shortcut". Click it
     ("Type the shortcut"), press ⌃⌥Space.
  2. Switch to another app (Finder, iTerm2) and press ⌃⌥Space; press it again. Do the same
     over a full-screen app, and with the pointer and the frontmost window on the other
     display.
  3. Click the field again and press ⌃⌥Space itself, then Esc in a second recording.
  4. Click the field and press, in turn: K alone, ⇧K, ⌘Space (or ⌘⇧4, if Spotlight takes
     ⌘Space before muxFinder sees it), ⌘K (then "Choose another"), ⌥J (then "Use it anyway"),
     and finally press ⌥J from another app.
  5. A taken shortcut: in an app that registers a global shortcut exclusively (Alfred,
     Raycast, or another muxFinder copy with the same shortcut recorded), set one, then record
     the same combination in muxFinder.
  6. Record a key whose character differs on your Spanish layout (for example the key right of
     L, which prints Ñ), with ⌃⌥.
  7. Quit muxFinder (the popover's Quit) and open it again; check the field and press the
     shortcut.
  8. Click the field (recording), then click another Settings tab; press a letter key, then
     press the shortcut from another app.
  9. From another app, open the switcher, type part of a session's name (also with an accent
     left out, or a dead-key accent composed in the field), move with ↑/↓ and press Return; then
     open it again and double-click another session.
  10. Open the switcher, type a new name such as `muxfinder-test-switcher`, press Return on
      "New session “muxfinder-test-switcher”…", then Return in the form; afterwards kill that
      session (`/opt/homebrew/bin/tmux kill-session -t '=muxfinder-test-switcher'`).
  11. Open the switcher from TextEdit (or any app with a text field focused) and press Esc;
      open it again and click outside it; open it again and press ⌘Tab.
  12. Open the popover from the menu bar icon, then press the shortcut; then click the icon
      while the switcher shows. Open the switcher and press ⌘, and ⌘R.
  13. Take Saturno offline (put it to sleep, or disconnect it from Tailscale) and open the
      switcher. Then make an Open fail (for example turn off iTerm2's Python API in iTerm2's
      settings for a moment), press the shortcut to close the switcher before the failure
      shows, then open the switcher and the popover again.
  14. Click "Clear"; press the old shortcut from another app. Quit and reopen.
- **Expect:** 1: the field shows ⌃⌥Space at once (no Save). 2: each press opens the session
  switcher (a panel in the upper part of the screen with the frontmost window, centered,
  the search field focused and empty), the next one closes it, whichever app is in front, over
  the full-screen app too, and on the other display when that is where you work. 3: pressing
  the recorded shortcut while recording records it (it does not open the switcher); Esc keeps
  it as it was. 4: K and ⇧K: "Add ⌃, ⌥ or ⌘ to the shortcut. Only F1 to F20 work on their
  own."; ⌘Space or ⌘⇧4: "macOS uses this shortcut itself. Choose another." (or the system's
  own action, the field still listening); ⌘K: "⌘K would stop working in every app while
  muxFinder uses it. Use it anyway?"; ⌥J: the ⌥ warning; whether a ⌥J press from another app
  opens the switcher tells whether macOS passes ⌥-only shortcuts to apps on this Mac: note it
  in the results (D32 refuses them if it does not). 5: "Another app uses this shortcut. Choose
  another." beside the field, no alert, the field still listening (or, if that app registered
  it non-exclusively, both apps react: note which). 6: the field shows ⌃⌥Ñ, not the US key's
  ";". 7: the shortcut is still set and works after the relaunch. 8: leaving the tab ends the
  recording (the field shows the shortcut again when you come back), the letter key is not
  captured, and the shortcut opens the switcher. 9: the list narrows as you type (accents and
  case ignored; a host's name keeps all its sessions), the first row is selected after each
  keystroke, the arrows stop at the ends, the composed accent lands in the field; Return and
  the double-click show "Opening…", iTerm2 comes forward with the session's windows and the
  focus in them, and the switcher is gone. 10: the form shows This Mac and the name filled in,
  with the directory list button; Return creates, the session opens in iTerm2 and the switcher
  closes. 11: each closes it and the focus is back in the app you were in (TextEdit's cursor
  where it was), with no muxFinder window left and muxFinder never in front. 12: only one of
  the popover and the switcher shows at a time; ⌘, opens Settings (the switcher closes), ⌘R
  shows the hosts' spinners in the popover later. 13: Saturno's sessions are missing and a
  muted line says why ("Saturno: unreachable" or "checking…"), never in red; the failure shows
  on the popover's row and at the top of the next switcher opening, selected, with "Try
  again", and is not at the top the time after. 14: the field says "Record shortcut", the old
  combination does nothing in muxFinder, and it stays off after the relaunch.
- **Undo:** "Clear" in Settings › General (or remove
  `~/Library/Application Support/muxFinder/preferences.json` while muxFinder is not running);
  kill any `muxfinder-test-*` session step 10 left; turn iTerm2's Python API back on and bring
  Saturno back after step 13.

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
| 14 | | | |
| 15 | | | |
| 16 | | | |
| 17 | | | |
| 18 | | | |
