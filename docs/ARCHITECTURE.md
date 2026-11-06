# Architecture

A short tour of how muxFinder is built. The full design, with the reasons and the verified
facts behind each choice, is in `PLAN.md` (*Architecture*, *Decisions* D1–D36); this page
links there rather than repeating it.

One SwiftPM package (Swift 6 language mode, macOS 14, arm64), no Xcode project and no
third-party dependency. The `.app` bundle is assembled by `scripts/build-app.sh`.

## Modules

| Target | What it holds |
|---|---|
| `MuxFinderCore` (library) | All logic, no SwiftUI, fully unit-testable. |
| ├ `Process/` | `ProcessRunner` over `posix_spawn` (argv only, own process group, hard timeouts, bounded output); `StreamingProcess`, a long-lived child with its standard input kept open and its output handed over as it arrives (D36). |
| ├ `Shell/` | POSIX single-quoting for the one remote command string, input validation. |
| ├ `Config/` | Host list (`HostConfig`, `HostList`, `HostStore` on `hosts.json`), New session's directories (`DirectoryLists`, `DirectoryStore` on `directories.json`), the session switcher shortcut and the folder search scope (`GlobalShortcut`, `PreferencesStore` on `preferences.json`), ssh config suggestions, private file storage (0700/0600, no ACLs, atomic renames). |
| ├ `Tmux/` | tmux locator, the static discovery script and its parser, session identity, error classification, session creation commands. |
| ├ `FolderSearch/` | Folder search over Spotlight (D36): the static script, `FolderSearchText` (escaping and limits), `FolderSearchOutputParser`, the local and SSH transport and its fake, and the `FolderSearchChannel` actor. |
| ├ `Refresh/` | `RefreshCoordinator` actor (concurrency limit, cadence, backoff, stale results dropped), `HostSnapshot`, sleep/wake and network events. |
| ├ `ITerm2/` | The hand-written iTerm2 API client: WebSocket over iTerm2's Unix socket, a minimal protobuf codec, typed requests, the `ITerm2Integration` protocol and its fake. |
| ├ `Launch/` | The launch protocol shared with the helper: request and result files, the guard script, remote launch strings, `LaunchHelper` itself (with its launch tab restore, `TerminalStatusRequest`), profile mode. |
| ├ `Attach/` | `AttachCoordinator` (revalidate, launch, confirm, focus, detach, move here, create and attach; the launch tab's bury and recovery in `AttachCoordinatorBurial`), `AttachmentIndex`, `LaunchTab`, `SSHSetupLauncher`. |
| ├ `Profiles/` | Persistent profile generator, installer and remover, the hash snapshot of iTerm2's other profiles, the `e2e-profile` run. |
| ├ `Diagnostics/` | Operation log (ring buffer plus `os.Logger`); outcomes and timings, never terminal content. |
| └ `Concurrency/` | Small helpers for awaited, cancellable tasks. |
| `MuxFinderUI` (library) | `AppModel` and the popover's content and views, the menu bar item and popover panel (`MenuBarPopover`, `PopoverController`), the session switcher shortcut (`GlobalShortcutModel`, the Carbon `HotkeyRegistrar`, `GlobalShortcutLabel`, the recorder) and the session switcher panel (`SessionSwitcher`, `SwitcherController`, `SwitcherContent`, `SwitcherView`), the New session window (`NewSessionWindow`, `NewSessionWindowController`, the folder drop's `FolderDrop` and `FolderDropView`), the Settings and onboarding windows, the attach state machine, preview fixtures, the self-test driver. |
| `MuxFinderApp` (executable) | Entry point, the menu bar app's shell (a plain `NSApplication` with muxFinder's own main menu, `MainMenu`; no SwiftUI `App` or scene, D33) and app delegates only; reads the command-line modes. Bundled as `Contents/MacOS/muxFinder`. |
| `muxfinder-launch` (executable) | The helper iTerm2 runs in a launch tab: `attach <id>`, `ssh-setup <id>`, `profile <host id>`. Bundled next to the app. |
| `muxfinder-probe` (executable) | Developer CLI that drives the core without the GUI: discovery, folder search, iTerm2 queries, single attaches and detaches, the `e2e-*` real runs, host list and profile checks. Not bundled. |

Tests: `Tests/MuxFinderCoreTests` and `Tests/MuxFinderUITests` (Swift Testing), hermetic: fakes
for processes, clocks and iTerm2, no ssh, tmux only on private sockets (PLAN.md D11).

## Data flow: discovery to popover

1. `HostStore` loads `hosts.json` (read-only at launch; D19).
2. `RefreshCoordinator` (D20) runs `DiscoveryProbe` for each turned-on host, at most three at
   once: This Mac by `posix_spawn` of `/bin/sh -c <static script>`, SSH hosts through
   `/usr/bin/ssh -o BatchMode=yes … <one quoted command string>` (D3, D6). The script finds tmux
   (D5) and runs only `list-sessions`, `list-clients` and `display-message` with explicit `-F`
   formats through `tmux -u` (D12), framed by a nonce. Each session line is followed by a
   `path` record with its start folder (`#{session_path}`), which ends only at the run's
   nonce, so a folder name holding line breaks cannot break or forge a record; tmux prints a
   folder over 4,096 bytes as nothing, and the runner keeps stdout up to the largest report
   the parser accepts (D31).
3. The parser turns the report into sessions keyed by host, socket, server pid and start time,
   and session id (D4), each with its start folder when it is plain text (one holding a control
   character or invalid UTF-8 is dropped and counted); failures are classified (unreachable,
   sign-in needed, host key, tmux not found, no server).
4. While the popover or the session switcher is visible, `AttachmentIndex` (D16) asks iTerm2
   which tmux connections exist and which server and session each one shows, so a row can say
   "open in iTerm2 on this Mac" from evidence rather than from a client count.
5. `HostSnapshot`s (live or stale) reach `AppModel` through one update stream; `PopoverContent`
   (and the switcher's `SwitcherContent`) is a pure value computed from them, the search text
   and the per-session activity (D22, D32).

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
  attachment checks run only while it (or the session switcher) shows; a key monitor hands the
  popover's shortcuts to `AppModel.handle(_:)` first (one it does not use, such as ⌥↓, goes on
  to the focused view). Which keys it hands over is a pure decision,
  `PanelKeyRoute` (Phase I-8), over the key and the panel's first responder at that moment:
  while a menu tracks (`MenuTrackingObserver`) or an input method composes, none; with a
  pop-up button focused (New session's Host picker), not ↑, ↓ or ⌥↓, which AppKit gives the
  picker (Space, no shortcut, opens its menu); Return and Esc always. Tab and ⇧Tab are no
  shortcut: they follow AppKit's key view loop, which the panels and the New session window
  recalculate as SwiftUI changes their views (`autorecalculatesKeyViewLoop`; with AppKit's
  default New session's fields led nowhere, Phase I-6). Opening it closes the session
  switcher; its "New session" (⌘N) opens the New session window (D34, below) and closes it.

The placement diagnostic `--report-popover-placement` opens it through the button's own action
and checks the frame against the anchor and the menu bar.

## The app shell (D22, D33)

The menu bar app runs on a plain `NSApplication` (`MuxFinderMenuBarApp.run()`): its delegate is
`AppDelegate` (accessory policy, menu bar item, model, SIGTERM and SIGINT, the orderly
shutdown) and its main menu is muxFinder's own (`MainMenu` in `MuxFinderUI`). There is no
SwiftUI `App` or scene, because SwiftUI (on macOS 27.3) shows its first scene's window when
launching finishes, even an empty `Settings` scene (the empty "muxFinder Settings" window
every launch showed before D33). So only muxFinder's code makes windows: the popover and switcher panels, Settings,
onboarding (shown at launch only while there is no `hosts.json`) and the New session window
(made at its first opening, D34).

The main menu is never shown (an accessory app has no menu bar); it carries the key
equivalents: the Edit commands every text field uses (Undo, Redo, Cut, Copy, Paste, Paste and
match style, Delete, Select all), Quit (⌘Q, `terminate:`), Hide, Close (⌘W, disabled for the
borderless panels, enabled for the titled New session window, which it closes like Cancel) and
Minimize, all to the first responder. It has no Settings item: ⌘, is
the popover's and the switcher's key, taken by their key monitor. Settings and onboarding
handle the editing keys and ⌘W themselves too (`SettingsWindow`). Preview mode and the
self-tests run their own plain `NSApplication` with no main menu.

The app shell check (`--report-menu-bar-item`, `AppShellReport`) prints the status item's
windows, every other window of the app (title, class, visibility, level), the launch's Apple
event and the main menu, so an unexpected window at launch shows in its output.

## The session switcher shortcut (D32)

A system-wide hotkey, off until the user records one in Settings › General ("Show session
switcher"). The pieces, each behind a seam so tests use fakes:

- **The value** (`GlobalShortcut`, core): a virtual key code and ⌃⌥⇧⌘ modifiers. `check`
  refuses a typing key without ⌃, ⌥ or ⌘ (F1–F20 may go alone) and macOS's own combinations
  (⌘Space, ⌘Tab, ⌘⇧Tab, ⌘⇧3/4/5, ⌘⌥Esc), and warns before ⌘ with one key and before only ⌥
  or ⌥⇧.
- **The label** (`GlobalShortcutLabel`): the modifier symbols in macOS order and the key as the
  current keyboard layout prints it (`SystemKeyboardLayout`: `TISCopyCurrentKeyboardLayoutInputSource`
  and `UCKeyTranslate`; `StaticKeyboardLayout` in tests and previews), fixed names for F-keys,
  Space, Return, arrows and the like.
- **Storage** (`PreferencesStore`, core): `preferences.json` in muxFinder's folder, schema 1,
  with D19/D31's rules (loading never writes, an unusable file is left as it is and refuses
  every change, 0600 and atomic publication under `preferences.lock`, other keys kept), written
  only when the user records or clears. Not the defaults domain: muxFinder owns only its
  support folder.
- **Registration** (`HotkeyRegistering`; `CarbonHotkeyRegistrar`): `RegisterEventHotKey` with
  `kEventHotKeyExclusive` for the application target, a `kEventHotKeyPressed` handler on the
  event dispatcher target; `eventHotKeyExistsErr` is `taken`. No permission is needed. A
  registration whose unregistration fails keeps its reference and token, so it can still be
  undone later; tests drive the registrar over fake Carbon calls (`CarbonHotkeyCalls`).
- **Lifecycle** (`GlobalShortcutModel`, owned by `AppModel`, shown by Settings): only the menu
  bar app in normal mode has one (`AppEnvironment.globalShortcut`); it loads and registers at
  `AppModel.start()`, registers again on a change, unregisters on clear and at quit. The
  recorder applies at once: clicking it suspends the hotkey, the next combination is checked,
  registered, then saved; a refusal, a taken combination or a failed save shows beside it
  (never an alert) and leaves the previous shortcut in place, except that a save finding
  `preferences.json` unusable leaves the hotkey off as at launch, with "Try again" to reload
  it. A failed unregistration leaves the hotkey on and says so. Another Settings tab, the
  window closing or losing the focus stop recording.
- **The press** reaches one entry point, `AppModel.globalShortcutPressed()`, which toggles the
  session switcher (`SwitcherController.toggle()`, below).

`--report-hotkey-registration` registers fixed test combinations on F19 and J in its own
process, checks that a second registration is refused as taken, and unregisters everything
before it exits; no event is posted.

## Folder search over Spotlight (D36)

A search of a host's folders by name, run by Spotlight on the host itself, so the host needs
no muxFinder. New session's directory list (`Folders on <host>`, below) and `muxfinder-probe
folders` drive it.

- **The script** (`FolderSearchScript.script`, static): This Mac runs it as `/bin/sh -c
  <script> muxfinder unchecked` by argv (the fixed argument turns the readability checks
  off), an SSH host through discovery's noninteractive ssh with the D3 string, no argument,
  and `-T` (no `-n`: standard input is the query stream). It writes a header once (the home
  folder, whether `mdfind` exists, `mdutil -s` for the home's volume and for `/`, whether
  Desktop, Documents and Downloads can be listed, `unchecked` on This Mac, where an `ls` of
  them could raise a privacy prompt), then answers one query line at a time until its
  standard input closes. A line is `<id> <home|disk> <escaped name text>`; the
  script checks it and builds the one fixed predicate itself, `kMDItemContentType ==
  "public.folder" && kMDItemFSName == "*<text>*"cd`, passed to `mdfind -0` as one argument
  (after `-onlyin "$HOME"` for `home`), never through `eval`. Paths come NUL-separated (a line
  feed in a name is kept), filtered by a fixed noise rule (`~/Library`, hidden folders,
  `node_modules` and the like, the inside of packages, and system folders for the whole disk),
  at most 50, then an end record with the id and `ok`, `limited` or an error. Each query is
  three stages: a producer that runs `mdfind` under a 4 s deadline (then kills it and answers
  `error timeout`), the noise filter, and an answer stage that signals the producer as soon as
  a 51st folder is kept (stopping `mdfind`) or the producer is done, then writes the answer.
  So a search never outlives its deadline on the host, also after an SSH disconnect.
- **Escaping** (`FolderSearchText`, pure): `\`, `"`, `*` and `?` get a backslash; control
  characters, more than 255 bytes and fewer than 2 characters are refused. Verified against
  `mdfind` by counts on synthetic folders.
- **Parsing** (`FolderSearchOutputParser`): NUL-separated records, a skipped preamble (a login
  shell's greeting), the header in order, then paths and end records; every buffer bounded
  (16 KiB a record, 50 paths an answer), anything else a protocol error.
- **Transport** (`ProcessFolderSearchTransport` over `StreamingProcess`): output parsed on the
  process's own queue, so only parsed events are buffered, at most 8 waiting for their reader
  (more is `eventOverflow`: reading stops and the process is ended); closing ends standard
  input, then terminates the group after 2 s and returns once the child is reaped.
- **Channel** (`FolderSearchChannel` actor, injected clock and transport): opens on the first
  searchable text, sends only the latest text 150 ms after typing pauses and only after the
  header, one query in flight, older answers dropped; the header within 10 s and each answer
  within 5 s; a failure reopens once, a second in a row is reported until the text, scope or
  host changes; a quiet minute or a host change closes the script; a host without Spotlight or
  with indexing off is reported from the header and no query is sent. Results stay in memory.
- **Scope:** `preferences.json`'s `folderSearchScope`, `home` (default) or `disk` (D32), set
  in Settings › Directories (`SettingsModelFolderSearch.swift`, saved at once) and read for
  each query, so a change applies to the next one.
- **In New session** (Phase I-10b; D31, D34): one channel per New session window and host,
  owned by `AppModel` (`AppModelFolderSearch.swift`, `FolderSearchSession`: the channel, a task
  reading its states and one queue for what is asked of it). The first searchable text (2
  characters, not only spaces, no `/`) while the directory list shows makes it; each new text
  is asked (the scope read first), text that can no longer be searched cancels a waiting
  query, and the window's closing, a host change and quitting end it (its process also closes
  after a quiet minute). `FolderSearchSection`, a pure value inside `DirectoryPickerContent`,
  turns the channel's latest state into the section: "Searching…" until the state is for the
  field's exact text (the previous answer's folders that still match stay listed), the
  folders (`~/…` under the header's home, each passing a typed Directory's checks or dropped
  and counted, each shown once across the list), "No folders found", the host's unavailability,
  the failure, the limit and, for SSH hosts only, the protected folders' note; then "Missing a
  folder?" and its explanation. Only normal mode has it (`AppEnvironment.folderSearch`); the
  tests drive it over `FakeFolderSearchTransport` and a clock they move.

## The session switcher (D32)

A Spotlight-like, keyboard-first panel the shortcut toggles, built in normal mode only (the
menu bar app with the shortcut; never in a preview, self-test or `--report-*` mode). As with
the popover, the AppKit wiring (`SessionSwitcher`) holds no decisions:

- **The panel** is the popover's borderless, non-activating `PopoverPanelWindow` at the floating
  level (on every Space and over full-screen apps; key without activating muxFinder, so the
  frontmost app gets the focus back when it closes), hosting `SwitcherView` through the shared
  `PanelHost` and `PanelObservers`. `SwitcherController` (over the same `PopoverPanelSurface`
  seam) opens it 540 pt wide, centered on the display with the keyboard focus (the frontmost
  app's frontmost window's display by area, from `CGWindowListCopyWindowInfo` bounds only, else
  `NSScreen.main`, else the pointer's), its top 18 % of the visible height below the top
  (`SwitcherPlacement`); Esc, the shortcut, a click outside, an app switch, losing the key
  focus, a display change, the popover opening and an action's success close it.
- **The content** (`SwitcherContent`, a pure value): the live sessions in the popover's order
  (the popover's `SessionRow`s, stale ones left out), filtered by the popover's rule; pinned
  rows first (failures carried from a closed switcher, and sessions of its actions not listed
  yet); "New session…" last, "New session “<name>”…" with the name filled in when the filter
  text is a valid, unused session name; muted host lines ("Sirio: unreachable"); the popover's
  placeholder with no host turned on; the selection kept on the same session across updates.
- **Keys** go through the same local key monitor as the popover's (`PanelKeyTrackingView`,
  routed by `PanelKeyRoute`: not while an input method composes or a menu tracks, and not ↑,
  ↓ or ⌥↓ while a pop-up button has the focus) to `AppModel.handleSwitcherKey(_:)`: the
  list's keys; ⌘N and the New session row open the New session window (D34, below), named
  from the filter, and close the switcher. A click activates a row as Return does (`AppModel.clickSwitcherItem(_:)`), and
  the switcher's tracking view also monitors its window's left mouse button events, so the
  rest of that click's sequence reaches no view (`SwitcherClickSequence`); through the
  double-click interval the controller keeps the panel no shorter than it was and holds back a
  success close (`SwitcherController.holdForClick()`), so that rest lands on the panel, never
  on the window behind it.
- **Actions** (`AppModelSwitcher.swift`): Return or a click opens through the popover's Open
  (D25); an Open started while the switcher shows, and the attach of a New session draft the
  switcher made (its creation, or its "Open existing"), are followed (`switcherActions`): a
  success closes the switcher if it still shows, a failure stays on its row, and one that
  arrives after the switcher closed is carried to the top of its next opening
  (`switcherCarriedFailures`) and stays on the popover row. A pinned row the engine does not list opens through its retained
  target on its host as enabled now (or says its host is no longer turned on). A creation
  that fails brings the New session window back instead (D34).
- **Visibility:** the model combines the popover's and the switcher's (`isSessionListVisible`),
  so the engine hears `.popoverOpened` and `.popoverClosed` once per change of "either one is
  visible", and opening one closes the other (`closePopover`, `closeSwitcher`); both
  controllers report a new visibility before their panel shows, so the swap never looks like a
  close to the engine. A press on muxFinder's status item while the switcher shows hands over
  in either order of its two effects: the switcher leaves a close from outside made by that
  press (`PopoverController.isButtonPressHeld`) to the popover the press opens.

`--preview-gallery switcher` renders every state from synthetic fixtures.

## The New session window (D34)

New session has a window of its own, so going to Finder for a folder no longer loses it: the
popover and the switcher close on any click elsewhere or app switch. The AppKit wiring
(`NewSessionWindow`: the panel `NewSessionPanel` and its host, made at the first opening and
reused) holds no decisions; the model and `NewSessionWindowController` do, over a
`NewSessionWindowSurface` seam (a fake in tests):

- **The window:** a titled, closable, non-activating `NSPanel` titled "New session" at the
  floating level (above other apps' normal windows, below the popover, the switcher and
  menus), on every Space and beside full-screen apps; it becomes key without activating
  muxFinder, never hides when muxFinder is inactive and never closes on a click elsewhere or
  an app switch. It hosts the form (`NewSessionPanelView`, 540 pt wide) at its natural height,
  which follows the directory list with the top edge fixed (`NewSessionWindowPlacement`).
- **The model** (`AppModelNewSession.swift`): `newSessionWindow` says whether it shows and
  holds the latest request, numbered so the controller carries it out once: a user's opening
  (key) or a failure's comeback (not key). The controller is installed by the app shell only,
  so the self-tests drive the model with no window, and preview mode builds the window only
  for its diagnostics. The popover's own `panel` holds only the Move here confirmation, so
  both can show at once.
- **Opening** from the popover or the switcher (which close as it opens) places a fresh
  window's top centre at theirs, clamped to that display, with a fresh draft (named from the
  switcher's filter); an opening while it shows only brings it forward, draft and frame as
  they are.
- **Keys:** the panels' key monitor and `PanelKeyRoute`, to `handleNewSessionKey(_:)`: Return
  creates, ⌥↓, ↑/↓ and Esc as the directory list's (D31), then Esc closes the window; ⌘W and
  the close button close it like Cancel; ⌘, opens Settings.
- **Ending:** Cancel, Esc, ⌘W and the close button drop the draft (a creation under way goes on
  with it); a success closes the window and the attach goes on on its row; a collision or a
  failure stays in it, and one that ends after the window was closed brings it back with that
  draft, in front but not key.
- **The folder drop** (Phase I-9b): one folder dragged from Finder onto the Directory field's
  row (the field and its list button) fills the field with its path, `~/…` under This Mac's
  home folder (the directory list's `~` rule, by whole path components) and absolute
  elsewhere, as a pick: the list closes and does not reopen, and the draft checks the text as
  typed text, for every host. `FolderDrop` is that rule as a pure function over plain facts
  (the dropped items' URLs and their directory and package resource values); anything but
  exactly one `file:` URL of a folder that is not a package is refused, and the drag shows no
  "+". `FolderDropView`, an invisible AppKit view laid over the row, is the drag's
  destination: AppKit gives a drag to the frontmost registered view under the pointer, and it
  registers for every type the field editor takes, so the field editor never inserts a path
  or other text of its own whether or not the field is being edited, while its `hitTest(_:)`
  lets clicks through. It reads only the dropped URL's own resource values and logs nothing;
  the field shows an accent ring while a drop would fill it (`isDirectoryDropTargeted`).

`--preview-gallery new-session` renders every state of the window from synthetic fixtures,
the drop highlight included.

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
- Detach other clients (`AttachCoordinator.detachOtherClients(of:confirmation:)`, D37) keeps
  this Mac's attachment (the one Show tab focuses) and, with a confirmation naming the
  session, sends everything through that attachment's connection, bound to its tab: the
  identity check again, its own client's name with tmux's clock and the session's clients with
  their creation times (read-only, filtered from the server's clients so they cannot fail in
  tmux: iTerm2 3.7 ends a connection on any tmux error for a command sent through its API),
  a wait until every other client is 10 s old by tmux's clock (D15's rule, for clients the
  attachment snapshot did not show too), then for each other client a check of its name, pid,
  creation time and session right before `detach-client -t <name>`, each sent once and
  counted only when tmux confirms it. Names, pids and creation times come only from that
  listing and are validated. The check and the detach are one round trip apart: tmux 3.8 and
  iTerm2's reply pairing allow no single guarded command (D37 records what that leaves). Not
  `attach-session -d`: iTerm2 closes and reopens the session's windows on the
  `%session-changed` it causes. Local and SSH hosts alike, with no new ssh, file or request.
- "Set up SSH in iTerm2…" opens the same kind of tab running plain interactive ssh (D24).

## New session directories (D31)

`directories.json`, beside `hosts.json` in muxFinder's folder and kept apart from it, holds one
saved list shared by every host and each host's recent directories:
`{"schemaVersion": 1, "saved": […], "recent": {"<host id>": […]}}`. `DirectoryStore` loads
and writes it the way `HostStore` treats `hosts.json` (D19): loading never writes; an unusable
file (unsafe, not JSON, malformed, another schema version) gives empty lists and a notice, is
left as it is and refuses every change (`fileNotUsable`) until it is fixed or moved away; a
change holds an exclusive `flock` on `directories.lock` in the same folder while it reads the
file, applies itself and publishes atomically, so two muxFinder processes never lose each
other's changes; and a write keeps whatever it displaces unless it is the store's own last
version (as a `directories.backup-<time>.json`). Every entry passes the working-directory
check; at most 50 saved and 8 recent per host. When New session creates a session, the model
records its directory (not an empty field) as that host's newest recent directory, also when
the attach fails afterwards, in the background; a failed write is logged by kind only. The
self-tests use an in-memory store; preview fixtures have none. Directories are user data: they
never appear in logs, diagnostics or fixtures.

**The picker.** New session's Directory field stays a text field, with a pull-down button at
its end that opens a list drawn inside the New session window, under the field (not a SwiftUI
`Menu` or `NSMenu`: a menu runs its own tracking loop, so its keys would bypass the window's
key monitor and `AppModel.handleNewSessionKey(_:)`, it cannot be opened from the text field by
a key, and the preview galleries could not render it). `DirectoryPickerContent` is a pure value built
from the lists, the host's listed sessions and the field: "Recent" (that host's), "Saved" (the
shared list) and "Sessions on <host>" (the distinct start folders of its sessions, sorted, at
most 10), each only when not empty, else "Nothing to pick yet"; then "Save this directory"
(off for an empty, invalid or saved value, a full list or an unusable file) and "Clear recent
directories on <host>". The field is also the list's search: its trimmed text keeps, in each
section, the entries that contain it (case and diacritics ignored, as the popover's search;
an entry equal to the field always stays), "No matching directories" when none does; the
text is never expanded, but on This Mac each entry is also matched with a leading home folder
written `~` and with a leading `~` spelled out (the home folder is injected,
`AppEnvironment.homeDirectory`; an SSH host's is unknown, so its entries are matched as
stored). The actions are never filtered. Its keys are `PopoverKey`s: ⌥↓ opens the list, ↑/↓
move inside the rows shown, Return picks the highlighted row (with none it creates, as in the
field) and Esc closes the list before the window, keeping the text; editing the field drops the
highlight, so Return then creates. The list keeps those keys wherever the focus is, except
that with the Host picker focused ↑, ↓ and ⌥↓ are the picker's (the list stays open, its
highlight unchanged; Return and Esc keep their list meaning; Phase I-8). A user edit (not a pick or a host change) opens the list
while an entry matches and closes it again when none does or the field is emptied, unless the
button or ⌥↓ opened it (`DirectoryPickerState.opening`); VoiceOver then hears the match count
through `AppEnvironment.announce`. Last comes "Folders on <host>" (D36, above) while folder
search applies to the text; it counts as something to show for that rule, its folders are
rows like the others (then "Missing a folder?"), and VoiceOver hears "Searching…" once per
search and the folder count when it settles. Rows
are identified by section and UTF-8 bytes, as the store compares directories, so two
spellings of one accented name are two rows. Picking only fills the field, as does a folder
dropped from Finder (D34, above); the draft checks it like typed text before any request. Every load (at each New session opening) and change
runs on one queue in `AppModel` (`AppModelDirectories.swift`); a refused change is shown in
the list and logged by its code only.

**Settings › Directories** edits the saved list on a working copy (add, checked inline;
remove; move up and down) with Save and Revert, as the host editor does (D23); Save is one
change through the same store (`mergeSaved`) that applies the tab's edits, under the store's
lock, to the saved list as the file holds it then, so a directory saved from New session (or
by another muxFinder) during an edit is kept, and recents are left alone. An unusable file
shows its notice with "Try again" and offers no edit. A save there updates New session's
list, and a change from New session's list updates the tab while it has no unsaved edits. The
tab also holds New session's folder search scope ("Search folders in: Home folder / Whole
disk", through `SettingsEnvironment.preferences`, saved at once) and the "Missing a folder?"
explanation (D36).

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
queue per connection; requests carry deadlines and are never retried (D13). A tmux command's
answer counts only with its output (empty for a command that prints nothing): one without it
(tmux's `%error`, or the connection ended first) is `tmuxCommandFailed`, never an empty
success (D37). There is no
Python, no SwiftProtobuf and no code generated from iTerm2's `api.proto`: iTerm2 is GPLv2 and
this repository is MIT, so iTerm2's Python module served only as a read-only protocol
reference. Everything sits behind `ITerm2Integration`, so the backend can be replaced; tests
use a fake.

## Security rules

- No shell or AppleScript source is ever built from runtime values. Local processes get argv
  arrays. The one place a shell must parse data, the remote ssh command, is
  `/bin/sh -c '<static script>' muxfinder '<arg1>' '<arg2>' …` with every argument
  single-quoted (D3). tmux words are escaped for tmux's own parser where needed (D18). The
  folder search script takes its queries on standard input as data lines it checks and puts
  into its one fixed predicate as a quoted word, never as shell source (D3, D36).
- Host names, session names, paths and directories are validated and treated as data;
  discovery output is framed and length-checked, so a session name or start folder cannot
  break the parser.
- Discovery is read-only, noninteractive and bounded (12 s, process group killed); host key
  checking is never weakened (D6).
- Private files: 0700 folders, 0600 files, extended ACLs stripped, atomic writes, symbolic
  links refused (D8, D14, D19, D31, D32). Logs hold outcomes and timings, never terminal contents
  or directories.

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
| | | D31 | New session directories and session start folders |
| | | D32 | Session switcher shortcut and panel |
| | | D33 | The menu bar app on a plain `NSApplication` |
| | | D34 | New session in its own window, with folder drop |
| | | D35 | Version numbers |
| | | D36 | Folder search over Spotlight |
| | | D37 | Detach other clients |
