# Architecture

A short tour of how muxFinder is built. The full design, with the reasons and the verified
facts behind each choice, is in `PLAN.md` (*Architecture*, *Decisions* D1–D30); this page
links there rather than repeating it.

One SwiftPM package (Swift 6 language mode, macOS 14, arm64), no Xcode project and no
third-party dependency. The `.app` bundle is assembled by `scripts/build-app.sh`.

## Modules

| Target | What it holds |
|---|---|
| `MuxFinderCore` (library) | All logic, no SwiftUI, fully unit-testable. |
| ├ `Process/` | `ProcessRunner` over `posix_spawn` (argv only, own process group, hard timeouts, bounded output). |
| ├ `Shell/` | POSIX single-quoting for the one remote command string, input validation. |
| ├ `Config/` | Host list (`HostConfig`, `HostList`, `HostStore` on `hosts.json`), ssh config suggestions, private file storage (0700/0600, no ACLs, atomic renames). |
| ├ `Tmux/` | tmux locator, the static discovery script and its parser, session identity, error classification, session creation commands. |
| ├ `Refresh/` | `RefreshCoordinator` actor (concurrency limit, cadence, backoff, stale results dropped), `HostSnapshot`, sleep/wake and network events. |
| ├ `ITerm2/` | The hand-written iTerm2 API client: WebSocket over iTerm2's Unix socket, a minimal protobuf codec, typed requests, the `ITerm2Integration` protocol and its fake. |
| ├ `Launch/` | The launch protocol shared with the helper: request and result files, the guard script, remote launch strings, `LaunchHelper` itself (with its launch tab restore, `TerminalStatusRequest`), profile mode. |
| ├ `Attach/` | `AttachCoordinator` (revalidate, launch, confirm, focus, detach, move here, create and attach; the launch tab's bury and recovery in `AttachCoordinatorBurial`), `AttachmentIndex`, `LaunchTab`, `SSHSetupLauncher`. |
| ├ `Profiles/` | Persistent profile generator, installer and remover, the hash snapshot of iTerm2's other profiles, the `e2e-profile` run. |
| ├ `Diagnostics/` | Operation log (ring buffer plus `os.Logger`); outcomes and timings, never terminal content. |
| └ `Concurrency/` | Small helpers for awaited, cancellable tasks. |
| `MuxFinderUI` (library) | `AppModel` and the popover's content and views, the menu bar item and popover panel (`MenuBarPopover`, `PopoverController`), the Settings and onboarding windows, the attach state machine, preview fixtures, the self-test driver. |
| `MuxFinderApp` (executable) | Entry point, the SwiftUI app shell (its standard main menu and an empty `Settings` scene nothing opens) and app delegates only; reads the command-line modes. Bundled as `Contents/MacOS/muxFinder`. |
| `muxfinder-launch` (executable) | The helper iTerm2 runs in a launch tab: `attach <id>`, `ssh-setup <id>`, `profile <host id>`. Bundled next to the app. |
| `muxfinder-probe` (executable) | Developer CLI that drives the core without the GUI: discovery, iTerm2 queries, single attaches and detaches, the `e2e-*` real runs, host list and profile checks. Not bundled. |

Tests: `Tests/MuxFinderCoreTests` and `Tests/MuxFinderUITests` (Swift Testing), hermetic: fakes
for processes, clocks and iTerm2, no ssh, tmux only on private sockets (PLAN.md D11).

## Data flow: discovery to popover

1. `HostStore` loads `hosts.json` (read-only at launch; D19).
2. `RefreshCoordinator` (D20) runs `DiscoveryProbe` for each turned-on host, at most three at
   once: This Mac by `posix_spawn` of `/bin/sh -c <static script>`, SSH hosts through
   `/usr/bin/ssh -o BatchMode=yes … <one quoted command string>` (D3, D6). The script finds tmux
   (D5) and runs only `list-sessions`, `list-clients` and `display-message` with explicit `-F`
   formats through `tmux -u` (D12), framed by a nonce.
3. The parser turns the report into sessions keyed by host, socket, server pid and start time,
   and session id (D4); failures are classified (unreachable, sign-in needed, host key, tmux
   not found, no server).
4. While the popover is visible, `AttachmentIndex` (D16) asks iTerm2 which tmux connections
   exist and which server and session each one shows, so a row can say "open in iTerm2 on this
   Mac" from evidence rather than from a client count.
5. `HostSnapshot`s (live or stale) reach `AppModel` through one update stream; `PopoverContent`
   is a pure value computed from them, the search text and the per-session activity (D22).

## The menu bar item and the popover (D22, D30)

muxFinder owns both: an `NSStatusItem` with its template icon (D28) and a borderless,
non-activating `NSPanel` hosting `PopoverView`, at the pop-up menu level, on every Space and
over full-screen apps (`MenuBarPopover`, only AppKit wiring). Every decision is
`PopoverController`'s, over small protocols so tests drive it with fakes:

- **Where it opens:** a mouse press on the button anchors at the button's rectangle; a press
  elsewhere (the other display's copy of the icon, whose in-process frame is a placeholder) at
  the press; no mouse event (`performClick(_:)`, VoiceOver) at the button
  (`PopoverAnchoring`). `PopoverPlacement` then puts the top edge at that display's menu bar
  bottom, the middle on the anchor, clamped inside its visible frame.
- **Toggle and close:** a press toggles it, or moves it to the press's display; Esc, a click
  outside, an app switch, losing the key focus and a display change close it; one press is
  never both a close and a reopen, and two separate presses are never taken for one, however
  quick and close (`PopoverPressRules`, matching by the system's count of mouse presses).
- **Size:** the content is limited to the display's room below the menu bar; taller content
  shrinks its host list, which scrolls, so the search field and footer stay in view
  (`PopoverHeightLimit`).
- **Model glue:** `popoverVisibilityChanged` follows the panel (open and not occluded), so
  attachment checks run only while it shows; a key monitor hands the popover's shortcuts to
  `AppModel.handle(_:)` first.

The placement diagnostic `--report-popover-placement` opens it through the button's own action
and checks the frame against the anchor and the menu bar.

## Attach flow and the launch protocol

```
click → AttachCoordinator: rediscover (still the same session?) → already open here? focus it
      → write launch/<uuid>.request.json (0600) → iTerm2 CreateTab, command
        "<bundle>/Contents/MacOS/muxfinder-launch attach <uuid>"
      → helper in the tab: take and delete the request, guard check, then as its child
        tmux -u -CC attach-session -t <id>          (This Mac)
        ssh -t -- <dest> '<static script>' <args>   (SSH host; the script re-checks identity)
      → iTerm2 shows a new tmux connection owned by that tab
      → coordinator asks it for its server and session (identity) → confirmed → activate
      → bury the launch tab (SetProperty "buried", bound to that connection's owner)
      → tmux ends: the helper restores the tab (Disinter), explains a failure, exits
```

- iTerm2 only ever receives the helper's absolute path and a token (D2); every value travels
  in the request file. The helper runs tmux or ssh as its child so it can write a result
  file, explain a failure in the tab and hold it at least 10 s (iTerm2 warns modally about
  tabs that end within 3 s) (D14).
- "Requested" and "confirmed" are separate states; only an identity-checked connection is a
  success (D15, D25). A click on a session whose action is still pending is ignored, and
  concurrent attaches of one session share one launch. Move here adds `-d` only after
  the user confirms (D21). Detach sends `detach-client` through the bound connection, never
  closes a tab. New session creates with `new-session -d`, then attaches the same way (D18).
- "Set up SSH in iTerm2…" opens the same kind of tab running plain interactive ssh (D24).

## Hiding the launch tab (D29)

- **The bury** is the coordinator's step 10: once an attach (also a new session or a move
  here) is confirmed and step 9 activated a tmux tab, it buries its own launch tab, once per
  launch, through `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` (bound like every command,
  D15). The outcome is `AttachResult.burial` (`buried`, `skipped`, `failed`, `uncertain` or
  `restoredAfterEnd`); a failed bury is never retried and the attach stays confirmed. A
  buried tab still owns its connection, so the bound identity check and `detach-client` work
  as before. muxFinder never reads iTerm2's preferences: with its "Automatically bury the tmux
  client session" setting on, iTerm2 has buried the tab already and the bury answers `OK`.
- **The helper's restore** (D14, D29): once its attach child ends, for every outcome, the
  helper writes its result, then a line feed, `OSC 1337 ; Disinter ST` and a status report
  request (`ESC [ 5 n`), and waits at most 2 s for the answer; iTerm2 answers only after it
  ran what came before, so an answer means the restore ran. The line feed ends iTerm2's tmux
  mode after an abnormal end (tmux sent no `%exit`); when the first exchange goes unanswered,
  `Disinter` and the request go again at once. Then come the explanation, the wait for Return
  and the 10 s hold, and one more restore just before it exits.
- **The race, closed by order:** the result is written before the first restore, so right
  after the bury's answer the coordinator peeks at it (`LaunchRequestStore.peekResult`, never
  a take) and checks the connection's owner; if tmux already ended, it restores the tab at
  once (`restoredAfterEnd`).
- **Recovery while the app runs** (memory only): the coordinator remembers the latest 64 tabs
  it buried. While any is remembered, a file-only peek at their results runs every 2 s
  (`BuriedTabTimer`) and at every attach and detach; iTerm2 is contacted only once a result
  appeared (or one of the coordinator's own connection listings showed the tab owning none).
  After a failure the tab is restored and left visible for its explanation; after a clean end
  a tab still listed 15 s later (a dead buried session) is restored and closed (forced, by its
  own session id).
  "Show tab" restores a buried tab before it activates it.

## The iTerm2 client (D1)

muxFinder speaks iTerm2's API itself: a WebSocket client over the Unix socket
`~/Library/Application Support/iTerm2/private/socket`, a hand-written protobuf codec for the
few messages it needs (`ListSessions`, `CreateTab`, `Activate`, `ListProfiles`, tmux
`ListConnections`/`SendCommand`, `Close`, `SetProperty`/`GetProperty`), and the access cookie
from one static AppleScript
command run in-process (the macOS Automation permission). One reader thread and one writer
queue per connection; requests carry deadlines and are never retried (D13). There is no
Python, no SwiftProtobuf and no code generated from iTerm2's `api.proto`: iTerm2 is GPLv2 and
this repository is MIT, so iTerm2's Python module served only as a read-only protocol
reference. Everything sits behind `ITerm2Integration`, so the backend can be replaced; tests
use a fake.

## Security rules

- No shell or AppleScript source is ever built from runtime values. Local processes get argv
  arrays. The one place a shell must parse data, the remote ssh command, is
  `/bin/sh -c '<static script>' muxfinder '<arg1>' '<arg2>' …` with every argument
  single-quoted (D3). tmux words are escaped for tmux's own parser where needed (D18).
- Host names, session names, paths and directories are validated and treated as data;
  discovery output is framed and length-checked, so a session name cannot break the parser.
- Discovery is read-only, noninteractive and bounded (12 s, process group killed); host key
  checking is never weakened (D6).
- Private files: 0700 folders, 0600 files, extended ACLs stripped, atomic writes, symbolic
  links refused (D8, D14, D19). Logs hold outcomes and timings, never terminal contents.

## Persistent profiles (D26)

`PersistentProfiles` generates `{"Profiles": […]}`, one profile per opted-in host (GUID
`muxfinder-persistent-<host id>`, tag `muxFinder`, command `<helper> profile <host id>`).
`PersistentProfileInstaller` writes or removes only `DynamicProfiles/muxFinder.json`,
atomically, under an `flock` in muxFinder's own folder, and replaces or removes it only while
it holds a generated document (`isGenerated`). The helper's `profile` mode reads `hosts.json`
and runs `tmux -u -CC new-session -A -s <name>` (or the same over ssh); a nesting guard
(`TMUX` or `MUXFINDER_LAUNCHED` set) and any failure fall back to the login shell.

## Packaging (D7, D27)

`scripts/build-app.sh` builds release arm64, assembles the bundle (both executables in
`Contents/MacOS/`), and signs it with hardened runtime: the first "Apple Development" identity,
or ad hoc; never notarized. `scripts/install.sh` and `scripts/uninstall.sh` copy, replace and
remove it; they stop only the copy's own `muxFinder` process (SIGTERM, to the process whose
executable, as the kernel reports it, has that file's inode; never a process that only maps
it), delete only the folder they inspected (renamed aside, device and inode compared, else put
back), and the uninstall removes the profile file through the app binary's
`--remove-persistent-profiles`, so the ownership rule is the Swift one.

## Decision index

All in `PLAN.md` *Decisions*:

| | Decision | | Decision |
|---|---|---|---|
| D1 | Native Swift iTerm2 API client | D15 | Attach coordinator |
| D2 | Launch helper plus request token | D16 | Existing attachments |
| D3 | Remote commands (one quoted string) | D17 | Remote attach over SSH |
| D4 | Session identity | D18 | Creating sessions, vanished sessions |
| D5 | Locating tmux | D19 | Host configuration |
| D6 | Read-only, noninteractive discovery | D20 | Refresh engine |
| D7 | Build and platform | D21 | Move here |
| D8 | Storage | D22 | Menu bar app |
| D9 | Scope: default tmux server | D23 | Settings window |
| D10 | English, sentence case | D24 | Onboarding and "Set up SSH in iTerm2…" |
| D11 | Hermetic tests | D25 | Attach UX in the app |
| D12 | `tmux -u` everywhere | D26 | Persistent work profiles |
| D13 | iTerm2 transport model | D27 | Install and uninstall scripts |
| D14 | Launch protocol | D28 | App icon, menu bar icon and release signing |
| | | D29 | Hiding the launch tab once attached |
| | | D30 | muxFinder's own menu bar item and popover panel |
