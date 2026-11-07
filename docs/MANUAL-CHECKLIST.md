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
  7. Keys, in the New session window with the cursor in Directory: ⌥↓ (the list opens on its
     first row), ↑/↓ (the highlight moves), Return (the highlighted directory fills the field
     and the list closes), ⌥↓ then Esc (only the list closes), Esc again (the window closes). Open the list with the mouse and press Return with nothing
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
  the list follows the host, and the field keeps its text. 7: as described (item 23 has the
  rest of the window's keys). 8: "Recent" disappears for This Mac only. With nothing
  recent, saved or reported, the list says "Nothing to pick yet".
- **Undo:** remove the saved entries in Settings › Directories (Save) and clear the recent
  ones from New session's list.

## 18. The session switcher and its shortcut

Owed by Phases I-3a, I-3b and I-5 (PLAN.md Phases I-3 and I-5, D32): the shortcut's checks,
storage, registration lifecycle and recorder, and the switcher's content, keys, clicks, actions
and visibility rule, are unit-tested over fakes, `--report-hotkey-registration` showed that registration works
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
     open it again and click another session once; then open it again and quickly double-click
     a session; then open it again and quickly double-click a session already open in iTerm2
     here.
  10. With more than about three sessions listed, open the switcher over a window of another
      app (TextEdit, say) and click "New session…" once; press Esc in the New session window,
      then open the switcher again and quickly double-click "New session…"; press Esc. Open the
      switcher, type a new name such as `muxfinder-test-switcher`, quickly double-click "New
      session “muxfinder-test-switcher”…" near its right end, then press Return in the window;
      afterwards kill that session (`/opt/homebrew/bin/tmux kill-session -t
      '=muxfinder-test-switcher'`).
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
  keystroke, the arrows stop at the ends, the composed accent lands in the field; Return, the
  single click and the double click each show "Opening…" at once on the row pressed or
  clicked, iTerm2 comes forward with the session's windows and the focus in them, and the
  switcher is gone; the double click opens the session once (one launch, no second tab); on a
  session already open here it brings iTerm2 forward, the switcher closes a moment later, and
  its second click selects or clicks nothing in iTerm2's window. 10: one click on "New
  session…" closes the switcher and opens the New session window at once (item 23); a quick
  double click opens it once, and its second click acts on nothing in the window (no
  directory list opens, Cancel and Create are not pressed) and clicks nothing behind it (the
  window underneath is untouched). The window shows This Mac and the name filled in, with the
  directory list button; Return creates, the window closes and the session opens in iTerm2. 11: each closes it and the focus is back in the app you were in (TextEdit's cursor
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

## 19. No window at launch, and the keys of the hand-built main menu

Owed by Phase I-4 (PLAN.md D33): the app shell check, run from a shell, showed that no
window but onboarding appears and listed the hand-built main menu, and the menu's items are
unit-tested, but no unattended run may launch the app through LaunchServices or press a key.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), with
  your host list saved (onboarding done):
  1. Quit muxFinder (the popover's Quit), then double-click it in `/Applications`.
  2. With "Open muxFinder when you log in" on (item 4), log out and in.
  3. Open the popover, type a few words in the search field, then try ⌘A, ⌘C, ⌘X, ⌘V, ⌘Z and
     ⇧⌘Z there; also in New session's Name and Directory fields (⌘N) and in the session
     switcher's field (item 18, if a shortcut is recorded).
  4. Open Settings (the popover's "Settings", or ⌘, in the popover), and in a host's fields try
     the same keys and ⌥⇧⌘V (Paste and match style); press ⌘M, click the Dock's minimized
     window back, then press ⌘W.
  5. Open the popover and press ⌘W there; then press ⌘Q.
- **Expect:** 1 and 2: muxFinder's icon appears in the menu bar and no window opens (no empty
  "muxFinder Settings" window, no other window). 3: each key does what it does in any text
  field (select all, copy, cut, paste, undo, redo), and the popover stays open. 4: the same,
  ⌥⇧⌘V pastes without formatting, ⌘M minimizes the window, ⌘W closes it. 5: ⌘W does nothing
  in the popover (it stays open, perhaps with a beep); ⌘Q quits muxFinder, its icon leaves the
  menu bar, and every tmux session and iTerm2 tab is still there.
- **Undo:** open muxFinder again from `/Applications`; turn launch at login off if you turned
  it on for step 2 (item 4).

## 20. Tab in New session

Owed by Phase I-6 (PLAN.md D30, D31; in the New session window since D34, Phase I-9): the
window's key view loop and where each Tab and ⇧Tab step takes the focus were read in process
(`--preview-key-view-loop`, `docs/TESTING.md` *Phases I-6 and I-9a*) and are unit-tested, but
no unattended run may press a key.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), first
  with macOS's keyboard navigation off (System Settings › Keyboard › "Keyboard navigation"),
  then with it on:
  1. Open the popover and press ⌘N (the popover closes and the New session window opens,
     the cursor in Name); type `muxfinder-test-tab`. Press Tab, then ⇧Tab, then Tab again and
     type a directory of yours in Directory; press Return.
  2. In a new New session window: press Tab several times from Name, then ⇧Tab several
     times. Then ⌥↓ in Directory to open the directory list and press Tab.
  3. Open the session switcher (item 18's shortcut), press ⌘N (the switcher closes, the
     window opens with the cursor in Name), name `muxfinder-test-tab2`, then steps 1 and 2
     there.
  4. Kill both sessions (`tmux kill-session -t '=muxfinder-test-tab'` and
     `'=muxfinder-test-tab2'`).
- **Expect:** 1: Tab puts the cursor in Directory and ⇧Tab back in Name, with no beep; Return
  creates the session in the directory typed, the window closes, and the session opens. 2:
  with keyboard navigation off, Tab and ⇧Tab go only between Name and Directory; with it on,
  Tab goes Name, Directory, the list's button, Cancel, Create, the Host picker, Name (⇧Tab the
  other way), a focus ring on each. Tab never closes the window or reaches anything outside
  the form (not its close button). With the list open, Tab moves on and the list stays open
  (Esc closes it). 3: the same in the window opened from the switcher.
- **Undo:** step 4; set keyboard navigation back as you had it.

## 21. Typing in Directory filters the directory list

Owed by Phase I-7 (PLAN.md D31; in the New session window since D34, Phase I-9): the filter,
the list opening and closing as you type, its keys and the match count announcement are
unit-tested over the model, and the filtered and "No matching directories" states were
rendered in the New session window's gallery (`new-session-states-*.png`), but no unattended
run may press a key, turn VoiceOver on or create a session from the real app, and the real
`directories.json` is the user's.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), with
  This Mac turned on, at least one saved directory and one recent directory (item 17 leaves
  both), and a tmux session started in a folder of yours (`tmux new-session -d -s
  muxfinder-test-filter -c <folder>`):
  1. Open the popover, ⌘N (the New session window opens), This Mac. In Directory, type part of
     a saved directory, then part of a recent one, then part of the session's folder (also as
     `~/…` when it is under your home folder, and as `/Users/<you>/…` for a saved `~/…` one).
  2. Press ↓, then ↓ and ↑ a few times, then Return. Then type something no entry contains.
  3. Clear the field. Type part of a directory again, press Esc, then type one more letter.
  4. Click the button at the end of Directory (or ⌥↓) and type something no entry contains;
     then clear the field.
  5. Name `muxfinder-test-filtered`; in Directory type a folder of yours that contains a
     listed one (the parent of a saved directory, say), so the list opens, and press Return
     with nothing highlighted.
  6. With VoiceOver on (⌘F5), steps 1 to 3 again.
  7. Close the window (Esc), open the session switcher (item 18's shortcut), ⌘N, and steps 1
     to 4 in the window it opens.
  8. Kill the sessions (`tmux kill-session -t '=muxfinder-test-filter'` and
     `'=muxfinder-test-filtered'`).
- **Expect:** 1: the list opens by itself as you type, with nothing highlighted, and trims
  down to the entries that contain what you typed (case and accents ignored), in their
  sections; a section with none left disappears; `~/…` and `/Users/<you>/…` find each other on
  This Mac. 2: ↓ highlights the first match and the arrows go only through the rows shown and
  the actions; Return puts the highlighted directory in the field and the list closes and
  stays closed; typing something nothing contains closes the list again. 3: clearing the field
  closes the list and opens nothing; Esc closes it and keeps the text; the next letter opens it
  again while something still matches. 4: the list stays open, saying "No matching directories" above "Save this directory"
  and "Clear recent directories on <host>"; clearing the field shows every entry again. 5: the
  session is created in the folder typed, not in a listed entry. 6: VoiceOver says the field's
  hint (typing filters the list; dropping a folder from Finder fills in its path) and, after
  the typing, how many directories match ("3 matching directories", "No matching
  directories"). 7: the same in the window opened from the switcher.
- **Undo:** step 8.

## 22. Change the host from the keyboard in New session

Owed by Phase I-8 (PLAN.md D30, D31, D32; in the New session window since D34, Phase I-9):
which view has the focus after ⇧Tab from Name and where the window's key monitor sends each
key with it were read in process (`--preview-key-view-loop`, `docs/TESTING.md` *Phases I-8 and
I-9a*) and the routing is unit-tested, but no unattended run may press a key or open a menu,
so what AppKit's pop-up button does with each key is yours to see.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), with
  at least two hosts turned on and macOS's keyboard navigation on (System Settings › Keyboard ›
  "Keyboard navigation"):
  1. Open the popover, press ⌘N (the New session window opens) and click in Name. Press ⇧Tab.
  2. Press Space. In the menu, press ↓ (↑ if the host shown is the last one), then Return.
  3. Press Space again, then Esc. Then, with the menu closed, press ↑ and ↓ (and ⌥↓).
  4. Click the button at the end of Directory (the directory list opens), press ↓ once (a
     row is highlighted), then click in Name and press ⇧Tab. Press Space, pick another host
     with ↓ (or ↑) and Return, then press Esc once.
  5. Press Tab (back to Name), type `muxfinder-test-host` and press Return.
  6. Open the session switcher (item 18's shortcut), press ⌘N (the switcher closes and the
     window opens, the cursor in Name), then steps 1 to 5 there, naming the session
     `muxfinder-test-host2`.
  7. Turn keyboard navigation off, open New session again, click in Name and press ⇧Tab.
  8. Kill both sessions on the hosts you picked (`tmux kill-session -t
     '=muxfinder-test-host'` and `'=muxfinder-test-host2'`, over ssh for an SSH host).
- **Expect:** 1: a focus ring on the Host picker. 2: Space opens the host menu over the
  picker (the window stays open); ↓ moves to the next host and Return picks it: the picker
  shows it, and the directory list's "Sessions on <host>" section (when you open it) names
  that host. 3: Esc closes only the menu, not the window. ↑ and ↓ on the closed picker do
  what macOS does with them (open the menu, or step to the next host: note which), never
  moving anything else; ⌥↓ opens no directory list. 4: the directory list stays open while
  the focus is on Host and while the host menu is open, its rows following the host picked
  (the highlight goes only if the new host's list lacks that row); Esc then closes the list
  and the window stays (a second Esc would close it). 5: the session is created on the host
  picked, the window closes, and the session opens. 6: the same in the window opened from the
  switcher (Esc in step 3 closes only the menu). 7: with keyboard navigation off, ⇧Tab from
  Name goes to Directory (Host is skipped).
- **Undo:** step 8; set keyboard navigation back as you had it.

## 23. The New session window and a folder dropped from Finder

Owed by Phases I-9a and I-9b (PLAN.md Phase I-9, D34): the window's opening, ending and
failure-after-close rules, its placement and height, its keys and the folder drop (the pure
function, the model, and the drop target ahead of the field editor in the real window, never
shown) are unit-tested, and the window's states were rendered (`new-session-states-*.png`),
but no unattended run may show the real window, switch apps, move between Spaces, drag from
Finder, press a key or turn VoiceOver on.

- **Do**, from the installed app (after `scripts/build-app.sh` and `scripts/install.sh`), with
  This Mac turned on and a folder of yours under your home folder (say `~/Documents`):
  1. Open the popover and click "New session" (or press ⌘N). Then press Esc, open the session
     switcher (item 18's shortcut) and press ⌘N there (or click "New session…").
  2. Type the name `muxfinder-test-drop`. Switch to Finder (click its Dock icon or ⌘Tab),
     browse to your folder, open a few windows, switch Spaces and come back, and put a
     full-screen app in front for a moment.
  3. Drag your folder from Finder onto the Directory field (not being edited); then click in
     Directory, type a few letters (the directory list may open) and drag the folder onto the
     field again while you edit it; once more onto the list button at its end. Drag a folder
     from outside your home folder too (say `/Applications/Utilities`), then yours again.
  4. Press Return.
  5. Open New session again, type a name and a directory, and click the window's close
     button; open it again. Type a name, press Esc (with the directory list closed); open it
     again. Type a name, press ⌘W; open it again.
  6. With the window open and a name typed, click the popover's "New session" (or ⌘N in the
     popover), then ⌘N in the session switcher.
  7. Drag onto Directory, in turn: a file, an app (`/Applications/Safari.app`), two folders at
     once, some selected text from TextEdit, and a link from Safari's address bar.
  8. With VoiceOver on (⌘F5), move to the Directory field.
  9. Kill the session (`tmux kill-session -t '=muxfinder-test-drop'`).
- **Expect:** 1: each time the popover or the switcher closes and one titled "New session"
  window opens where it was, the cursor in Name, muxFinder not becoming the active app (the
  menu bar keeps the app you were in); from the switcher, the name is filled in from its
  filter. 2: the window stays above the other apps' windows the whole time, on every Space
  and beside the full-screen app, with its draft as typed; clicking into it makes it key
  without taking the app in front's menu bar. 3: while the folder hovers over the field or
  its button, the pointer shows "+" and the field an accent ring; dropping fills Directory with
  `~/Documents` (your folder, `~/…`, never `/Users/<you>/…`), replacing what was there, with no
  path or file name typed at the cursor besides, and the directory list closed (it does not
  reopen); a folder outside your home folder fills in its absolute path. While the directory
  list opens and closes the window grows and shrinks, its top edge staying put. 4: the session is
  created in that folder (its first pane starts there), the window closes and the session
  opens in iTerm2. 5: each of the three closes the window, and the next opening is a fresh,
  empty form. 6: the window comes forward with its draft unchanged (the switcher's filter does
  not replace the name), and the popover and switcher close. 7: each shows no "+" and no ring,
  and dropping changes nothing (no text inserted in the field). 8: VoiceOver reads the field's
  hint, ending with "Dropping a folder from Finder here fills in its path."
- **Undo:** step 9.

## 24. Folder search in New session

Owed by Phase I-10b (PLAN.md Phase I-10, D36, D31, D34): the section's states, the channel's
lifetime, the scope setting and the announcements are unit-tested over a fake transport, the
script under stub `mdfind`, and real `--count-only` probe runs counted folders on this Mac and
Saturno; but no unattended run may show the real window, type into it, open Settings or System
Settings, see a privacy prompt or turn VoiceOver on, and folder names are never recorded.

- **Do**, from the installed app, with This Mac and Saturno turned on (Saturno's Spotlight
  indexing on, as the Phase I-10a runs found it):
  1. Open New session (from Sirio, or from this Mac with Saturno chosen as Host), click in
     Directory and type part of the name of a folder you know is in Saturno's home folder.
  2. Pick it from "Folders on Saturno" (click it, or ↓ to it and Return), type the name
     `muxfinder-test-folders` and press Return.
  3. Open Settings › Directories, choose "Whole disk" under "Search folders in", come back to
     New session (Saturno) and type part of the name of a folder outside Saturno's home folder
     (say one under `/Applications` or `/Volumes`).
  4. Click "Missing a folder?" under the folders, read the explanation and click "Open
     muxFinder Settings". Choose "Home folder" again.
  5. Choose This Mac as Host and type a few letters: the first folder search on This Mac.
     Compare the folders listed with what Alfred's File Filter (or Spotlight, ⌘Space) finds for
     the same letters, including folders inside your Desktop, Documents and Downloads.
  6. With VoiceOver on (⌘F5), type a few letters in Directory, slowly, then quickly.
  7. Kill the session (`ssh saturno-m4 /opt/homebrew/bin/tmux kill-session -t
     '=muxfinder-test-folders'`).
- **Expect:** 1: "Searching…" under "Folders on Saturno", then the folder listed within about
  half a second of a pause in typing, written `~/…`; Recent, Saved and Sessions filter at once
  and never wait; a folder already listed there shows only there. 2: the field takes the
  folder as shown, the list closes and does not reopen; the session is created in that folder
  on Saturno and opens in iTerm2. 3: the folder outside the home folder is listed (with
  "Home folder" it was not). 4: the explanation lists what Spotlight and muxFinder leave out
  (dot folders, Spotlight's privacy settings, Library and package contents, node_modules and
  the like), the scope, Remote Login's full disk access and the apostrophe note; the button
  opens muxFinder's Settings on its Directories tab ("Open Spotlight settings" shows only for
  This Mac and opens System Settings' Spotlight pane). 5: **no privacy prompt** asking for
  access to Desktop, Documents or Downloads appears (This Mac's search checks none of them);
  write down whether folders inside Desktop, Documents and Downloads are listed (whether
  macOS's privacy protection hides them from muxFinder's Spotlight queries, and whether the
  results otherwise match Alfred's or Spotlight's). If Saturno's Remote Login did not allow
  full disk access for remote users, the section also said "Desktop, Documents and Downloads
  on Saturno can't be searched over SSH." 6: VoiceOver says "Searching…" once when a search
  starts (never for each key), then the number of folders found when it settles.
- **Undo:** step 7; Settings › Directories back to "Home folder" if you changed it.

## 25. Detach other clients from two Macs

Owed by Phase I-11b (PLAN.md Phase I-11, D37): the command was proven on This Mac and Saturno
with a plain `tmux -C` client standing in for the other Mac (`e2e-detach-others`, Phase
I-11a), and the popover's item, its confirmation, results and failures are unit-tested over a
fake iTerm2 and seen only in the preview galleries; no unattended run may open the real
popover, click it, use another Mac's iTerm2 or press keys.

- **Do**, from the installed app on This Mac, with Saturno turned on and its iTerm2 running:
  1. Create a session on Saturno (`ssh saturno-m4 /opt/homebrew/bin/tmux new-session -d -s
     muxfinder-test-two-macs`) and open it on Saturno itself in iTerm2 (`tmux -CC attach -t
     '=muxfinder-test-two-macs'` there, or muxFinder on Saturno). Leave that window as it is.
  2. On This Mac, open the popover, click the session to open it here; then make This Mac's
     iTerm2 window of it much larger (or smaller) than Saturno's.
  3. Open the popover again (the row now says "Open in iTerm2 here · also attached
     elsewhere" and "2 clients"), right-click the session and choose "Detach other clients…";
     read the dialog, press Esc; choose it again and press "Detach other clients".
  4. Resize This Mac's iTerm2 window of the session again.
  5. With VoiceOver on (⌘F5), open the dialog once more on a session attached on both Macs
     (repeat 1 and 2 first), hear it, and press Cancel.
- **Expect:** 2: This Mac's window shows the session at Saturno's size, the rest of the window
  unused (the problem this fixes). 3: Esc closes the dialog and nothing happens; the dialog
  names the session, says "1 other client was attached when muxFinder last looked", that they
  may be iTerm2 on other Macs, that nothing is closed and the session keeps running, and that
  "While another client is attached, tmux may keep the window at the other client's size."
  Confirming shows "Detaching other clients…" on the row (for up to about 10 s if a client is
  younger than that), then "Detached 1 other client — the session keeps running"; Saturno's
  iTerm2 windows of the session close (its tmux tab shows the detach; no "tmux Reported a
  Problem" alert), This Mac's windows stay open with the same tabs, no window closes and
  reopens here, and the row's badge loses "also attached elsewhere" and reads "1 client"
  after the refresh. 4: the session now follows This Mac's window size. 5: VoiceOver reads the
  dialog's title when it appears, and its buttons by name.
- **The residual race (D37):** muxFinder checks each other client right before it detaches
  it, one round trip apart. If a client ends (or switches session) in exactly that instant,
  tmux may refuse the detach; iTerm2 then shows its "tmux Reported a Problem" alert and may end
  this Mac's attachment too, and the row says "tmux refused to detach one of the other
  clients …" with "Refresh". The session keeps running in every case: open it again. Write
  down if you ever see it.
- **Undo:** in muxFinder, "Detach from this Mac" on the session; then `ssh saturno-m4
  /opt/homebrew/bin/tmux kill-session -t '=muxfinder-test-two-macs'`.

## 26. Other terminal apps: the plain runs (`e2e-plain`)

Owed by Phase I-12c3b (PLAN.md D38 *The plain runs (I-12c3b)*): the run was proven on a
private tmux server with the real helper and a stand-in for the windows, and its gate refused
for real, since neither Terminal nor Ghostty was running and an unattended run must never
launch either or send it an Apple event without the permission already granted
(*Unattended-run rules* 8). The raw AppleScript checks of each app are in `docs/TESTING.md`,
*Phase I-12a*, *Owed*.

- **Do**, from the repository root after `swift build`, in a shell of iTerm2 with
  `TMUX_TMPDIR` unset, for each app you use:
  1. Open the app (Terminal, or Ghostty 1.3 or later) yourself. Check
     `swift run muxfinder-probe terminals list` shows it `running` and its permission
     `granted`. If it reads `notDetermined`, the run would refuse (it never prompts): in the
     same iTerm2 shell run `osascript -e 'tell application id "com.apple.Terminal" to count
     windows'` (Ghostty: `com.mitchellh.ghostty`) once and allow macOS's prompt ("iTerm2"
     wants to control the app). If it reads `denied`, turn it on in System Settings › Privacy
     & Security › Automation › iTerm2.
  2. `swift run muxfinder-probe e2e-plain --terminal terminal --local`, then
     `swift run muxfinder-probe e2e-plain --terminal terminal --ssh saturno-m4`.
  3. `swift run muxfinder-probe e2e-plain --terminal ghostty --local`, then
     `swift run muxfinder-probe e2e-plain --terminal ghostty --ssh saturno-m4`.
  Do not touch the windows the run opens (no typing, no closing) while it runs.
- **Expect:** each run prints 9 PASS lines and "9 of 9 steps passed", exit 0, in under a
  minute locally (the Detach other clients step waits about 10 s). Two windows of the app
  open, one after the other, each showing the session (tmux's status bar, `sleep 600`): the
  first is brought forward again by the second open (no other window opens) and closes after
  the detach; the second (Move here) closes after the last detach (Terminal's closed by the
  run by its id, unless your profile closes them itself; Ghostty's close by themselves). The remote runs log in to
  Saturno with your key in the window. Afterwards no `muxfinder-test-*` session is left
  (`tmux list-sessions`, and on Saturno), the launch folder is empty, and no window of the run
  is open. A FAIL line names the step and why; cleanup still runs and its last line says what,
  if anything, is left to close by hand.
- **If the gate refuses** (exit 2): the line says why (the app not running, or its permission
  not granted) and nothing was created, written or sent.
- **Undo:** nothing, unless cleanup's last line lists a window to close or a session to end:
  close that window yourself once nothing runs in it, and end a session with
  `/opt/homebrew/bin/tmux kill-session -t '=<name>'` (on Saturno through `ssh saturno-m4`).

## 27. Other terminal apps: the picker, "Set up SSH" and persistent work

Owed by Phase I-12d1 (PLAN.md D38 *The UI (I-12d1)*): the picker, "Set up SSH" in a plain
terminal and the persistent work commands were tested over stand-ins only, since a real
permission read is muxFinder's own, "Set up SSH" starts a real ssh login in a real window
through an Apple event, and the commands only work once pasted into the terminal's settings.
Use the installed app (item 1), opened from Finder.

- **Do, the picker:** open Settings › General. Check that the Terminal section lists iTerm2
  (when installed), Terminal and Ghostty (only if 1.3 or later), each with its version, and
  under Terminal and Ghostty "Permission: …" and "Plain tmux: windows and panes stay inside one
  terminal window." With Terminal not running its permission reads "Checked when the app is
  running"; open Terminal yourself and choose "Check again": it reads "Not asked yet" (or
  "Allowed" / "Not allowed" if you answered before). On a "Not asked yet" or "Not allowed" row,
  "Allow in System Settings…" opens System Settings › Privacy & Security › Automation. Choose
  Terminal, then iTerm2 again; while a session is opening, choose another terminal: it says
  "Applies when the current action ends."
- **Do, "Set up SSH":** with Terminal chosen and running, in Settings › Hosts select Saturno
  and choose "Set up SSH in Terminal…" (allow macOS's prompt the first time: "muxFinder" wants
  to control Terminal). Then the same with Ghostty chosen ("Set up SSH in Ghostty…").
- **Do, persistent work:** with Terminal chosen, turn on "Persistent profile" for This Mac and
  Saturno in the Hosts tab and save. In the Persistent profiles tab choose Copy next to Saturno
  and paste it in Terminal › Settings › Profiles › (a new profile) › Shell › Run command, "Run
  inside shell" on; open a window with that profile. With Ghostty chosen, put the copied command
  after `command = ` in Ghostty's config file and open a new Ghostty window.
- **Expect:** the picker's states as described, and the Automation pane opening. "Set up SSH"
  opens a new window of that terminal running ssh to Saturno (sign in or accept the host key
  there; the line in Settings says the terminal opened a window, then "check the host
  again"); closing it after ssh ends is the terminal's own setting. The persistent work window
  attaches (or creates) Saturno's default session with plain tmux; closing the window keeps the
  session running; opening another attaches the same session. No iTerm2 window or profile is
  touched while another terminal is chosen; the "Profiles in iTerm2" line offers Remove only
  while muxFinder's own profiles are installed.
- **Undo:** choose iTerm2 again in Settings › General; clear the Run command (or delete the
  profile) in Terminal and the `command = ` line in Ghostty's config; turn the persistent
  profiles off again if you turned them on only for this; end a test session with
  `/opt/homebrew/bin/tmux kill-session -t '=<name>'` if you made one.

## 28. Other terminal apps: the popover, the switcher and the errors

Owed by Phase I-12d2 (PLAN.md D38 *The UI (I-12d2)*): the rows' actions, states and errors
for Terminal and Ghostty were tested over stand-ins only, since a real Open sends an Apple event
to the terminal and opens a real window. Use the installed app (item 1), opened from Finder,
with a test session of your own (`/opt/homebrew/bin/tmux new-session -d -s muxfinder-test-ui`
on This Mac, and one on Saturno over ssh).

- **Do, Open and Show window:** choose Terminal in Settings › General. In the popover,
  right-click the test session: the menu's first item reads "Open in Terminal". Open it (allow
  macOS's prompt the first time). The row reads "Waiting for Terminal…", then "Confirmed —
  open in Terminal on this Mac"; right-click again: "Show window" is there and "Move here…" is
  not dimmed (choosing it and confirming reads "This session is already open in a Terminal
  window on this Mac, so muxFinder did not move it. …" with "Bring forward" and "Detach from
  this Mac", and nothing is opened). Switch to another app, then choose "Show window". Open
  Saturno's session too: while ssh asks for nothing it confirms the same way; with a host that
  waits (a password), the row reads "Still connecting — check the Terminal window" with "Show
  window".
- **Do, Detach and Move here:** on the This Mac session choose "Detach from this Mac" (the row
  reads "Detached from this Mac — the session keeps running"; the window's helper ends, and the
  window closes or stays as Terminal's own setting for a shell that exits decides; muxFinder
  does not close it). Attach the session in another terminal yourself (`tmux attach -t
  muxfinder-test-ui` in iTerm2), then "Move here…" and confirm: it opens in a new Terminal window and the other
  client is detached. With two clients, "Detach other clients…" detaches the other one. Then
  detach that new window's client in tmux yourself (prefix `d` in the window): "Move here…" is
  still offered, and confirming it opens a new Terminal window (muxFinder's record of the old
  one was stale, so it moves here instead of refusing).
- **Do, Ghostty and Saturno:** choose Ghostty and repeat Open, "Show window", "Detach from this
  Mac" and "Move here…" on the This Mac session (the rows read "Open in Ghostty", "Waiting for
  Ghostty…", "Confirmed — open in Ghostty on this Mac"). Then, with Terminal chosen and again
  with Ghostty, do the same on Saturno's session: Open, "Detach from this Mac", and "Move
  here…" after attaching it yourself elsewhere (for example `ssh -t saturno-m4
  /opt/homebrew/bin/tmux attach -t muxfinder-test-ui` in iTerm2).
- **Do, open elsewhere and another terminal's record:** with the session open in a Terminal
  window muxFinder opened, choose Ghostty in Settings: the row reads "Open in Terminal on this
  Mac" with "Show in Terminal" (which brings Terminal forward), and the menu offers "Detach
  (opened in Terminal)" (it detaches that window's client; nothing else of Terminal is used).
  Choose iTerm2: a session open in Terminal still shows "Open in Terminal on this Mac", and Open
  still opens it in iTerm2.
- **Do, the errors:** with Terminal chosen, turn off muxFinder in System Settings › Privacy &
  Security › Automation › Terminal and Open a session: "muxFinder isn't allowed to control
  Terminal, so it opened nothing. …" with "Open System Settings…" (opening the Automation
  pane) and "Try again"; turn it back on. With Ghostty chosen, put `macos-applescript = false`
  in Ghostty's config, restart Ghostty and Open a session: note the error number the row
  shows; muxFinder takes -1708 and -10004 for "Ghostty's AppleScript is turned off" (tell us
  if the row shows another sentence). Remove the line again. (A terminal definition of your
  own for Ghostty, whose script muxFinder cannot vouch for, reads at -1708 "… may have no
  “muxfinder_open” handler, or Ghostty's AppleScript may be turned off …" instead.) Rename the
  test session to `muxfinder-test[1]` (`tmux rename-session -t muxfinder-test-ui
  'muxfinder-test[1]'`) and Open it with Terminal chosen: "Terminal windows can't attach a
  session whose name has “{”, “[” or “]”, …".
- **Expect:** every line names the chosen terminal and its window, never iTerm2's tab; nothing
  is opened in iTerm2 while another terminal is chosen; Detach never closes a window itself
  (Ghostty's windows close by themselves once their helper ends); Saturno's session confirms
  and detaches as This Mac's does, and Move here leaves only the new window attached; the
  session keeps running throughout.
- **Undo:** remove `macos-applescript = false` from Ghostty's config if it is still there;
  choose iTerm2 again in Settings › General; close the test windows once their helpers ended;
  end the test sessions with `/opt/homebrew/bin/tmux kill-session -t '=muxfinder-test-ui'` (and
  `'=muxfinder-test[1]'` if renamed, and Saturno's over ssh).

## 29. Other terminal apps: onboarding on a Mac without iTerm2

Owed by Phase I-12d1 (PLAN.md D38 *The UI (I-12d1)*, *Onboarding*; added in Phase I-12e from
the specification's acceptance): onboarding without iTerm2 was tested over stand-ins and in
the onboarding gallery only. It needs a Mac without iTerm2; if none is available, write that
in the results.

- **Do:** on a Mac without iTerm2 and without
  `~/Library/Application Support/muxFinder/hosts.json`, install muxFinder (item 1) and open it
  from Finder. Go through onboarding, save the hosts, then Open a session of your own (for
  example `muxfinder-test-ui`, as in item 28).
- **Expect:** the first step lists Terminal (and Ghostty only if 1.3 or later is installed),
  Terminal preselected, no iTerm2 row; the line under the title reads "muxFinder finds the
  tmux sessions on your Macs and opens them in Terminal."; after the hosts and "Good to know",
  the last step explains plain mode ("muxFinder opens each session in a new Terminal window
  with plain tmux: …") with the permission line ("macOS asks once, the first time muxFinder
  opens a Terminal window. …"), and no step asks for iTerm2's Python API. The Open asks once
  whether "muxFinder" may control "Terminal"; allowed, it opens in a new Terminal window and
  confirms. Nothing tries to start iTerm2.
- **Undo:** item 13 (`scripts/uninstall.sh`); end the test session with
  `/opt/homebrew/bin/tmux kill-session -t '=muxfinder-test-ui'`.

## 30. The update check and download against GitHub (`update check`, `update verify --latest`)

Owed by Phases I-13a and I-13b1 (PLAN.md D39): no unattended run sends a request to GitHub or
any other server (*Unattended-run rules* 3), so the check and the download were tested only
through a `URLProtocol` stub and fakes (the verification itself ran for real on a local copy
of 0.2.0's zip). This item needs the network and sends anonymous requests to
`api.github.com`, each counting against GitHub's limit for requests without a token (60 an
hour per address), and step 5 downloads the latest release's `muxFinder.zip` (about 6 MB)
from GitHub.

- **Do:** from the repository, `swift build`, then:
  1. `swift run muxfinder-probe update check --running-version 0.1.0`
  2. `swift run muxfinder-probe update check --running-version 0.2.0` (or whatever version
     is the latest published release when you run it)
  3. `S=$(mktemp -d /private/tmp/mfx.XXXXXX)`, then `swift run muxfinder-probe update check
     --state "$S"` twice, then `ls -l "$S"` and `cat "$S/update-state.json"`.
  4. Optionally, with Wi-Fi off: `swift run muxfinder-probe update check`.
  5. `V=$(mktemp -d /private/tmp/mfx.XXXXXX)`, then `swift run muxfinder-probe update verify
     --into "$V" --team-id <your Team ID> --latest --running-build 1` (the Team ID is the
     `TeamIdentifier` that `codesign -dv /Applications/muxFinder.app` prints for a release
     copy), then `ls "$V" "$V/extracted"`.
- **Expect:**
  1. Exit 0, JSON with `outcome` `newer`, `sent` true, `latestTag` the latest published tag
     (`v0.2.0` when this was written), `newer` true, `releasePage`
     `https://github.com/ccarpiog/muxFinder/releases/tag/<that tag>`, `assetPresent` and
     `digestPresent` true, `size` the zip's size in bytes (about 6 MB, as on the release
     page), `etagKept` true.
  2. Exit 0, `outcome` `upToDate`, `newer` false, the same `latestTag`.
  3. Both runs exit 0 with `outcome` `newer` (the running version defaults to 0.0.0); the
     first's `state` has `found` `missing`, the second's `saved` (the second sent the kept
     `ETag`, so GitHub may answer 304 and the release then comes from the file). The folder
     holds only `update-state.json`, mode `-rw-------`, with `schemaVersion` 1,
     `lastAttempt`, `lastSuccessfulCheck`, `etag`, and `release` with `tag`, `page` and
     `asset` (`url` `https://github.com/ccarpiog/muxFinder/releases/download/<tag>/muxFinder.zip`,
     `sha256` the digest the release page shows, `size`).
  4. Exit 1, `outcome` `failed.offline` (or `failed.timedOut` after at most 15 s).
  5. Exit 0, JSON with `mode` `latest`, `check.outcome` `newer`, `check.latestTag` the latest
     published tag, `expectedVersion` its version, every step (`download`, `digest`,
     `extraction`, `shape`, `signature`, `notarization`, `versions`) `passed`, `verdict`
     `verified`, `bundle.path` `extracted/muxFinder.app` with the release's version and
     build, `zipSize` the asset's size, `cleanedUp` true, and no Team ID in the output. The
     folder holds only `extracted/muxFinder.app` (the zip is deleted). Nothing is installed,
     moved or launched.
  If GitHub's limit is used up, a run prints `outcome` `rateLimited` with
  `rateLimitedUntil` and exits 1; with `--state`, the next run before that time prints the
  same with `sent` false. Steps 1 to 4 download and install nothing; step 5 downloads into
  `$V` only and installs nothing.
- **Undo:** `rm -r "$S" "$V"`.

## 31. The update notice in the app (the popover, the menu bar dot, Settings › General)

Owed by Phase I-13c1 (PLAN.md D39 *The notice (I-13c1)*): no unattended run launches the app
in normal mode, since that sends the update check 5 s later (*Unattended-run rules* 3), so the
notice, the dot and the Settings line were proven only over fakes and galleries. This item
needs the network and an installed copy whose version is older than the latest published
release (for example the 0.1.0 build, or a local build with `CFBundleShortVersionString` set
lower); it sends anonymous requests to `api.github.com`.

- **Do:**
  1. Quit muxFinder, open the older copy normally (Finder or the login item), wait about
     10 s.
  2. Look at the menu bar icon (and, with VoiceOver on, hover it), then open the popover.
  3. Close and reopen the popover; quit and open muxFinder again.
  4. Click **What's new** in the popover.
  5. Open Settings › General: read the "Updates" section; click **Check for updates…**.
  6. Turn **Check for updates automatically** off, quit, open muxFinder again and wait a
     minute; then `cat ~/Library/Application\ Support/muxFinder/preferences.json`.
  7. Optionally, with Wi-Fi off, click **Check for updates…** again.
- **Expect:**
  1–2. The icon shows a small dot in its top-right corner (still tinted like the menu bar);
     VoiceOver reads "muxFinder, update available". The popover shows "muxFinder <latest> is
     available" with **What's new**, above the hosts.
  3. Once the popover has shown the notice, the dot is gone (VoiceOver: "muxFinder") and stays
     gone after relaunching; the notice still shows in the popover. A later, newer release
     brings the dot back.
  4. The release page `https://github.com/ccarpiog/muxFinder/releases/tag/<latest tag>` opens
     in the default browser. Nothing is downloaded or installed.
  5. The section shows the toggle on, the button, and "muxFinder <latest> is available" over
     "Last checked just now" (or a few minutes ago). While the check runs the button is
     disabled and the line reads "Checking for updates…"; afterwards the same lines. On a copy
     that runs the latest version: "You're up to date (<version> (<build>))".
  6. `preferences.json` holds `"checkForUpdatesAutomatically" : false`; no check is sent at
     launch ("Last checked" keeps its earlier time). **Check for updates…** still checks.
  7. "Couldn't check: no connection" (or "Couldn't check: no answer" after at most 15 s); no
     alert.
- **Undo:** turn the toggle back on; quit the older copy and reinstall the current one.

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
| 19 | | | |
| 20 | | | |
| 21 | | | |
| 22 | | | |
| 23 | | | |
| 24 | | | |
| 25 | | | |
| 26 | | | |
| 27 | | | |
| 28 | | | |
| 29 | | | |
| 30 | | | |
| 31 | | | |
