# Testing

How muxFinder is tested, and what was checked against real hosts: first the tested vs
expected-to-work matrix, then the unit tests, the real-check procedures and every phase's
real results. The checks only a person can make are in `docs/MANUAL-CHECKLIST.md`.

## Tested vs expected to work

One row per acceptance bullet of the brief (`docs/REQUIREMENTS.md`, "The app is acceptable
when"). **Tested for real** means against the real iTerm2 3.7.6 and real tmux 3.8 on Neptuno
(this Mac) and, where named, Saturno (`saturno-m4`); **tested hermetically** means unit tests
with fakes; **expected to work, unverified** says why it was not tried. "Orbit" in the brief
is muxFinder. Every real run below used `muxfinder-test-*` sessions only; probe runs drive the
same core the app uses, and the self-tests drive the app's own `AppModel` in the bundled
binary. The last column is the Phase 12b acceptance run's, made on the final tree on
2026-10-23: every unit test, both `e2e-*` runs, `e2e-profile` locally and on Saturno, both
self-tests and row 12's quit check ran fresh and exited 0 (details under *Phase 12b —
acceptance run* below). Phase 13c ran them again on 2026-10-24 with the launch tab hidden once
attached (PLAN.md D29), all exiting 0 with every step passing: `e2e-local` 16 of 16,
`e2e-remote saturno-m4` 17 of 17, `e2e-profile --local` 14 of 14 and the two self-tests,
now 8 and 7 steps (rows 1–5, 9–11 and 13, the last locally only; row 12's quit check was not
repeated; *Phase 13c* below).

| # | Acceptance bullet | Status | Evidence so far (command, date, result, where) | 12b fresh run |
|---|---|---|---|---|
| 1 | A local session appears and opens through native iTerm2 tmux integration. | Tested for real (probe and app self-test). A click in the real popover is owed to a person (checklist 3). | `swift run muxfinder-probe e2e-local`, 2026-10-22: exit 0, 16 of 16 PASS in 64.8 s, steps 1–3 create, discover, attach confirmed on a `tmux -CC` connection owned by the launch tab with its identity checked (`docs/progress-archive/6b.md`, closure; earlier runs in `docs/INTEGRATION-PROOF.md`, *Runs of e2e-local*). `muxFinder --selftest attach-local`, 2026-10-22: exit 0, 6 of 6 PASS (*Phase 10b* below). | `swift run muxfinder-probe e2e-local`, 2026-10-23: exit 0, 16 of 16 PASS in 63.4 s (steps 1–3; *Phase 12b* below). `muxFinder --selftest attach-local`, 2026-10-23: exit 0, 6 of 6 PASS. |
| 2 | A session on an accessible remote host can be discovered and attached. | Tested for real on Saturno. Sirio: expected to work, unverified: it was offline throughout (checklist 10). | `swift run muxfinder-probe e2e-remote saturno-m4`, 2026-10-22: exit 0, 17 of 17 PASS in 123.1 s, steps 2–3 discover over ssh, attach through `ssh -t` confirmed (`docs/progress-archive/6b.md`, closure); runs 4–5 (11 of 11) in *Phase 5b* below and `docs/INTEGRATION-PROOF.md`, *Over SSH*. | `swift run muxfinder-probe e2e-remote saturno-m4`, 2026-10-23: exit 0, 17 of 17 PASS in 121.8 s (steps 2–3 discover over ssh and attach). |
| 3 | Native tabs and split panes are preserved. | Tested for real, locally and on Saturno. | Step 4 "tabs and split" of `e2e-local` and `e2e-remote` (same runs as rows 1–2): the session's 2 tmux windows appear as 2 native iTerm2 tabs on the run's connection, one with a two-pane split (`docs/INTEGRATION-PROOF.md`, step 4 of each run list). | Step 4 of `e2e-local` and `e2e-remote`, 2026-10-23: PASS, both runs exit 0 (the runs of rows 1–2). |
| 4 | Work survives detachment and can be resumed. | Tested for real, locally and on Saturno. | `e2e-local` steps 6–7 and `e2e-remote` steps 5–6: detach by session through `detach-client`, the session alive with its 2 windows and 3 live `sleep` panes, then reattached (same runs); the self-tests' "detach from this Mac" steps (*Phase 10b*). | `e2e-local` steps 6–7 and `e2e-remote` steps 5–6, 2026-10-23: PASS, both runs exit 0 (the runs of rows 1–2); both self-tests' "detach from this Mac" steps PASS, exit 0 (rows 1 and 11). |
| 5 | Sessions created outside Orbit are discovered. | Tested for real, locally and on Saturno. | `muxfinder-probe discover --local` and `--ssh saturno-m4` on sessions made with the tmux CLI (`tmux new-session -d`), 2026-10-21: `ok`, every session with its exact name and id (*Phase 2* below). Every `e2e-*` run creates its session with tmux directly and discovers it (step 2). | Step 2 of `e2e-local` and `e2e-remote`, 2026-10-23: PASS, both runs exit 0 (the runs of rows 1–2). |
| 6 | Two hosts with identically named sessions remain distinct. | Tested hermetically; parts tested for real. Two same-named sessions side by side in the real popover: expected to work, unverified: needs a person (checklist 3). | `RefreshSnapshotTests.theSameSessionNameOnTwoHostsStaysTwoEntries` (two entries, two keys, an attachment marks only one), `ErrorClassifierTests.keysDifferPerHost` (keys carry the host id, PLAN.md D4). Real: Phase 2 created the same names on Neptuno and Saturno and discovered each (2026-10-21); over ssh the identity check tells Saturno's server from Neptuno's by node name although both socket paths are `/private/tmp/tmux-501/default` (`docs/INTEGRATION-PROOF.md`, *Observed behavior over SSH*). | `swift test`, 2026-10-23: exit 0, 680 tests in 67 suites (core) and 159 in 13 suites (UI). |
| 7 | An unreachable host does not freeze the UI. | Tested hermetically; the bound is tested for real. The real popover with an offline host: expected to work, unverified: needs a person (checklist 3). | `RefreshCoordinatorTests.aSlowHostDoesNotDelayTheOthers`, `theConcurrencyLimitIsThree`; `ProcessRunnerTests.doesNotBlockTheMainActor`; `PopoverContentTests` (an unreachable host's sessions kept, stale). Real: `discover --ssh 192.0.2.1` ends `unreachable(timeout)` after 5.0 s, `something.invalid` `unreachable(dnsFailure)` in 6 ms (*Phase 2*, 2026-10-21). | `swift test`, 2026-10-23: exit 0 (the run of row 6). |
| 8 | Authentication failure is distinguishable from an empty host. | Tested for real (discovery); the popover labels hermetically. | `discover --ssh nonexistent-muxfinder@saturno-m4` → `authFailed`; `discover --ssh saturno-m4` with no server → `noServer` (*Phase 2*, 2026-10-21). Labels "Sign-in needed" vs "No sessions": `PopoverContentTests`, `ErrorClassifierTests`. | `swift test`, 2026-10-23: exit 0 (the run of row 6). |
| 9 | A disappeared session is handled without silently recreating it. | Tested for real, locally and on Saturno. | `e2e-local` step 10 and `e2e-remote` step 11 "vanished session": the attach ends `sessionGone` with no launch tab, request or new session (*Phase 6a*, 2026-10-22, runs 3 and 4; the 6b closure runs); the helper's guard refuses a changed session (step 9, `sessionChanged`). | `e2e-local` steps 9–10 and `e2e-remote` steps 9 and 11, 2026-10-23: PASS, both runs exit 0 (the runs of rows 1–2). |
| 10 | Repeated clicks do not launch a burst of duplicate connections. | Tested for real (app self-test and probe). | `muxFinder --selftest attach-local`, 2026-10-22: step 3 "open (5 clicks)" confirmed with 1 launch, step 4 "open again" focused the same connection (*Phase 10b*). `e2e-local` step 8: two concurrent attaches share 1 launch tab and 1 connection; step 5: a second attach of an attached session focuses it, nothing opens. | `muxFinder --selftest attach-local`, 2026-10-23: exit 0, 6 of 6 PASS: 5 clicks on Open confirmed with 1 launch, Open again focused. `e2e-local` steps 5 and 8: PASS, run exit 0 (the run of row 1). |
| 11 | New Session creates persistent work on the selected host. | Tested for real, locally and on Saturno; the New session sheet by hand is owed (checklist 3). | `e2e-local` step 14 and `e2e-remote` step 15: created with a name and working directory, confirmed attached, pane in that directory (*Phase 6a*, 2026-10-22). `muxFinder --selftest new-session-local`, 2026-10-22: exit 0, 5 of 5 PASS, the same name again refused as a collision (*Phase 10b*). | `e2e-local` step 14 and `e2e-remote` step 15, 2026-10-23: PASS, both runs exit 0 (the runs of rows 1–2). `muxFinder --selftest new-session-local`, 2026-10-23: exit 0, 5 of 5 PASS, the same name again refused as a collision with "Open existing" offered and nothing launched. |
| 12 | Quitting Orbit leaves the work running. | Tested for real (SIGTERM, the app's normal quit path). Quit clicked in the popover: owed to a person (checklist 3). | `muxFinder --selftest attach-local --selftest-keep`, then `kill -TERM`, 2026-10-22: app exit 0, `tmux has-session` exit 0, iTerm2 still listed the connection owned by its tab (*Phase 10b*). | `muxFinder --selftest attach-local --selftest-keep`, then `kill -TERM`, 2026-10-23: app exit 0, `tmux has-session` exit 0, iTerm2 still listed the connection owned by the test's tab. |
| 13 | Generated persistent profiles work without modifying unrelated settings. | Tested for real through the probe, locally and on Saturno. From the installed app's Settings, as the default profile, a second tab: owed to a person (checklist 11–12). | `swift run muxfinder-probe e2e-profile --local` and `--ssh saturno-m4`, 2026-10-23: exit 0, 14 of 14 PASS each (runs 5–6): `CreateTab` by profile name gets a confirmed control-mode connection; hashes of every other `DynamicProfiles` entry and of `New Bookmarks` identical before install, after install and after removal (*Phase 11b*). `profiles hashes` identical before and after every later phase. | `swift run muxfinder-probe e2e-profile --local` and `--ssh saturno-m4`, 2026-10-23: exit 0, 14 of 14 PASS each (11.3 s and 15.7 s), the snapshots before install, after install and after removal identical. `profiles hashes` after all 12b runs byte-identical to the one before the first. |

Other deliverables of the brief:

| Deliverable | Status | Evidence so far | 12b fresh run |
|---|---|---|---|
| Reproducible build, runnable `.app` | Tested for real | `rm -rf build && scripts/build-app.sh`, then `codesign --verify --deep --strict build/muxFinder.app`, 2026-10-23: exit 0 both (*Phase 12a* below). | `rm -rf build && scripts/build-app.sh`, then `codesign --verify --deep --strict build/muxFinder.app`, 2026-10-23: exit 0 both (*Phase 12b* below). |
| Signing status | Tested for real | Everyday builds (`scripts/build-app.sh`): hardened runtime, "Apple Development" certificate, not notarized (*Phase 8* onwards). Release builds (`scripts/release.sh`, D28), 2026-10-23: "Developer ID Application" certificate with a secure timestamp, notarized (Apple: Accepted, no issues), stapled, `spctl` "accepted, source=Notarized Developer ID" (*D28* below). | The same clean build, 2026-10-23: signed by the "Apple Development" identity, not notarized. |
| Install and removal instructions, scripts | Tested hermetically | `scripts/dev/test-install-scripts.sh` (both scripts on private folders, stubs for running copies), 2026-10-23: exit 0, 35 of 35 PASS, twice, after the review fixes; each new regression fails with its fix reverted (*Phase 12a*). A real install into `/Applications` and a real uninstall are the user's (checklist 1 and 13). | `scripts/dev/test-install-scripts.sh`, 2026-10-23: exit 0, 35 of 35 PASS. |
| Unit tests | Tested hermetically | `swift test` (*Phase I-8* for the latest counts). | `swift test`, 2026-10-23: exit 0, 680 tests in 67 suites (core) and 159 in 13 suites (UI). `swift build -Xswiftc -warnings-as-errors` and `swift format lint -r Sources Tests`: exit 0 each. |

Added after the brief (the user's reports of 2026-10-24, 2026-11-04, 2026-11-05 and 2026-11-06, PLAN.md Phases 13, 14 and I-1 to I-12; for other terminal apps also `docs/REQUIREMENTS.md`, *Addendum, 2026-11-06*):

| Requirement | Status | Evidence |
|---|---|---|
| An attach (Open, New session, Move here) shows only the session's windows: the launch tab is buried once its first tmux tab is active, leaves by itself after every detach, and comes back after a failure. | Tested for real, locally and on Saturno, with iTerm2's "Automatically bury the tmux client session after connecting" off (its default); with it on, only by the Phase 13a spike. Through the real popover, with that setting on and off, where the focus goes after a detach, and Return after an abnormal end: owed to a person (checklist 14). | Phase 13c, 2026-10-24 (*Phase 13c* below): `e2e-local` 16 of 16 and `e2e-remote saturno-m4` 17 of 17 PASS, every confirmed attach (attach, reattach, concurrent attaches, new session, move here) `burial` `buried` with the tab in `buried_sessions` and in no tab, and after every detach the tab gone by itself, no restore or `Close` of the coordinator's recorded. `e2e-bury --local` and `--ssh saturno-m4` 13 of 13 PASS each: detaches within 10 s and after 10 s; the bury released together with a detach, sent and answered `OK` (`restoredAfterEnd` locally, `buried` on Saturno), the tab gone by itself; a dead buried tab removed by the coordinator's recovery; the attach child killed: the helper's result `childSignaled(9)`, the tab back with an answered status report and in a tab, its helper alive, past the helper's minimum lifetime, and the session alive. Both self-tests PASS with "launch tab buried" and "launch tab left". Hermetic: `LaunchTabBurialTests`, `ShowLaunchTabTests`, `LaunchTabRestoreTests`, `RecordingITerm2IntegrationTests`, `LaunchTabChecksTests`, `SelfTestDriverTests`. |
| The popover reads at a glance: an opaque background, a bounded section per host, each row's attach state at a glance, a readable "Open in iTerm2 here" badge, an unreachable host muted rather than red, even footer spacing. | Tested hermetically and in the preview renders (both appearances). The real popover in muxFinder's panel, by a person (checklist 15). | Phase 14, 2026-10-24 (*Phase 14* below): `PopoverStyleTests` (the badge at least 4.5:1 against what is behind it, light and dark, unselected, selected and hovered rows; a neutral selection; opaque fills; no red host status, a hollow dot only for the muted tone; distinct indicators; the footer's spacing); `PopoverContentTests` (every status's tone, `.unreachable` alone muted, the row-state mapping, the fixtures covering a selected row with the badge and an unreachable host next to an attention one). `docs/screenshots/popover-states-*.png` and `attach-states-*.png` regenerated and inspected. |
| New session: the Directory field offers, per host, its recent directories, the shared saved ones and its sessions' start folders; picking fills the field; "Save this directory", "Clear recent directories on <host>"; the keys (⌥↓, ↑/↓, Return, Esc); Settings › Directories edits the saved list (PLAN.md Phase I-2, D31). | Tested hermetically and in the preview renders (both appearances); the store and the start folders by I-2a. Creating from a recent, a saved and a session folder on This Mac and Saturno, the keys and the Settings tab in the real app: by a person (checklist 17). | Phase I-2b, 2026-10-24 (*Phase I-2b* below): `DirectoryPickerTests` (content, rules, picking, keys, store changes and failures) and `SettingsDirectoriesTests` (add, remove, reorder, Save, Revert, unusable file); `docs/screenshots/attach-states-*.png` and `settings-states-*.png` regenerated and inspected. |
| Clicking the menu bar icon opens the popover directly below it (its middle on the icon's, its top at the menu bar's bottom, clamped inside the display), on the display clicked; the toggle, Esc, a click outside and an app switch closing it, the keys, the search field's focus, Spaces and full-screen apps as before (PLAN.md Phase I-1, D30). | Tested for real through the button's own action (`performClick(_:)` in process) on the main display; the controller's rules hermetically. A click on each display's icon, after a ⌘-drag, the closing paths, the keys and a full-screen Space: by a person (checklist 16). | Phase I-1b, 2026-10-24 (*Phase I-1b* below): `--report-popover-placement` exit 0, twice: the panel at {{1250, 1530}, {360, 168}}, its middle x 1430 on the button's 1430 and its top 1698 on the menu bar's bottom 1698 (offsets 0 and 0; the next tree's run the same 1 pt further right), with the screen locked;
then once after the review fixes, unlocked, with screen 1 main: the button at screen 1's right
edge and the panel clamped 8 pt inside it, top on the menu bar's bottom, "after-fix check:
passed"; `PopoverControllerTests` (toggle, move, every close, both orders of the toggle bug, occlusion, size) and `PopoverAnchoringTests` (the anchor rule over this Mac's displays, the replica frames never anchors, the after-fix check). |
| A global shortcut, off until recorded in Settings › General ("Show session switcher"): checked (a modifier besides ⇧ unless F1–F20, macOS's own combinations refused, a warning before ⌘ with one key or only ⌥/⌥⇧), shown with the current layout's key, kept in `preferences.json`, registered at launch, again on a change, unregistered on clear and at quit, suspended while recording, a taken one explained beside the recorder; its press toggles the session switcher (next row; PLAN.md Phase I-3a, D32). | Registration and its refusal of a second registration tested for real in the signed bundle (`--report-hotkey-registration`); the rest hermetically and in the preview renders (both appearances). Recording in the real Settings window, a taken shortcut, "Clear", a relaunch, the label on the user's layout and a press from another app: by a person (checklist 18). | Phase I-3a, 2026-10-24 (*Phase I-3a* below): `--report-hotkey-registration` exit 0, 8 of 8 checks as expected; `GlobalShortcutTests`, `PreferencesStoreTests`, `GlobalShortcutModelTests`, `GlobalShortcutAppTests`; `docs/screenshots/settings-states-*.png` regenerated and inspected. |
| The session switcher: the shortcut toggles a non-activating panel centered on the display with the keyboard focus, in its upper part, over full-screen apps; a search field focused and empty at each opening; the live sessions in the popover's order (stale ones left out) with Phase 14's row look, filtered by the popover's rule; "New session…" last, naming the session from the filter; muted lines for hosts checking or unreachable; Return or one click opens as the popover does (the rest of that click's sequence is ignored and lands on the panel, held through the double-click interval, so a quick double click opens once and never acts on the form or on the window behind the panel), Return or a click on New session or ⌘N shows the form (since Phase I-9a in the New session window, PLAN.md D34), ⌘R, ⌘, and Esc; it closes on success, keeps a failure on its row, and carries a failure that arrives once it closed to its next opening and the popover row; only one of it and the popover shows, and the engine hears one opened and one closed per change of "either one is visible" (PLAN.md Phases I-3b and I-5, D32, D22). | Tested hermetically and in the preview renders (both appearances); the app shell check as before. A press over a full-screen app, filtering and opening with iTerm2 coming forward, creating, and Esc giving the focus back: by a person (checklist 18). | Phase I-3b, 2026-10-24 (*Phase I-3b* below): `SwitcherContentTests`, `SwitcherControllerTests`, `SwitcherModelTests`, `GlobalShortcutAppTests.theShortcutTogglesTheSwitcher`; `docs/screenshots/switcher-states-*.png` rendered and inspected. Phase I-5, 2026-11-04 (*Phase I-5* below): `SwitcherClickTests`, and for the review fix the hold tests in `SwitcherControllerTests` and `PopoverHeightLimitTests`; the switcher gallery rendered again in both appearances, unchanged. |
| A launch shows no window except onboarding (only while there is no `hosts.json`): no empty "muxFinder Settings" window; the Edit shortcuts in every text field, ⌘W in Settings and onboarding, ⌘Q with the orderly shutdown, SIGTERM and SIGINT as before (PLAN.md Phase I-4, D33). | Tested for real from the shell (the app shell check under two private homes, before and after the fix); the main menu hermetically. A launch from Finder and at login, and the keys pressed in the popover and Settings: by a person (checklist 19). | Phase I-4, 2026-11-04 (*Phase I-4* below): before the fix both homes listed a visible `SwiftUI.AppKitWindow` "muxFinder Settings"; after it, the empty home lists only the hidden popover panel and onboarding, the home with every host off only the hidden panel; exit 0 after SIGTERM, no child, nothing written; `MainMenuTests`, `AppShellReportTests`. |
| New session's Tab order, in the popover and the session switcher (since Phase I-9a in the New session window, PLAN.md D34): Tab from Name to Directory and ⇧Tab back; with macOS's keyboard navigation on, the Host picker, the directory list's button, Cancel and Create too, in reading order; never out of the panel, never closing it; Tab with the directory list open moves on and leaves it open; an input method's marked text gets Tab first (PLAN.md Phase I-6, D30, D31). | Read in process in the real panels (`--preview-key-view-loop`, before and after the fix: the focus moved by the key bindings' own action messages, no event) and tested hermetically. Real key presses, with keyboard navigation off and on, then a creation: by a person (checklist 20). | Phase I-6, 2026-11-04 (*Phase I-6* below): before the fix the form's fields led nowhere (Name → none) and Tab stayed in Name in both panels; after it Name → Directory → the list's button → Cancel → Create → Host picker → Name, and back; `NewSessionTabOrderTests`. |
| New session: typing in Directory filters the directory list, combo-box style, in the popover and the session switcher (since Phase I-9a in the New session window, PLAN.md D34): each section keeps the entries that contain the trimmed text (case and diacritics ignored; an exact match always), on This Mac also with the home folder written `~` or spelled out; "No matching directories" apart from "Nothing to pick yet"; the actions never filtered; typing opens the list while something matches, highlighting nothing, and closes a list it opened when nothing matches or the field is cleared, a list the button or ⌥↓ opened staying; Esc keeps the text; ↓/⌥↓ highlight the first match and the arrows stay in the rows shown; Return with nothing highlighted creates; a pick never reopens it; a host change re-filters; VoiceOver hears the match count (PLAN.md Phase I-7, D31). | Tested hermetically and in the preview renders (both appearances). Typing, the keys, VoiceOver and a creation in the real popover and switcher: by a person (checklist 21). | Phase I-7, 2026-11-04 (*Phase I-7* below): `DirectoryFilterContentTests` and `DirectoryFilterModelTests` (`DirectoryFilterTests.swift`); `docs/screenshots/attach-states-*.png` and `switcher-states-*.png` regenerated and inspected. |
| New session: the Host picker from the keyboard, in the popover and the session switcher (since Phase I-9a in the New session window, PLAN.md D34), with macOS's keyboard navigation on: ⇧Tab from Name reaches it; while it (an `NSPopUpButton`) has the focus, the panels' key monitor leaves ↑, ↓ and ⌥↓ to it (Space already reached it), Return still creates and Esc still closes the panel; while a menu tracks every key is the menu's; with the directory list open the list keeps its highlight and Return and Esc their list meaning; with any other focus nothing changes; a host picked from the menu acts as a click (PLAN.md Phase I-8, D30, D31, D32). | Read in process in the real panels (`--preview-key-view-loop`: the first responder after the window's own step back from Name and the monitor's route for each key, before and after the fix; no event, no menu opened) and tested hermetically (the routing as a pure function, the menu tracking observer, a pick through the picker's binding). What AppKit's pop-up button does with each key, the menu opening from the panel, and a creation on the host picked: by a person (checklist 22). | Phase I-8, 2026-11-05 (*Phase I-8* below): before the fix ↑/↓/⌥↓ went to the panel's handler with the picker focused (↑/↓ swallowed, ⌥↓ opening the directory list), after it to the picker; `PanelKeyRouteTests`, `MenuTrackingObserverTests`, `HostPickerBindingTests` (`HostPickerKeyboardTests.swift`). |
| The New session window and a folder dropped from Finder (PLAN.md Phase I-9, D34): one titled, floating, non-activating window opened from the popover and the switcher, which close as it opens; it stays above other apps on every Space and beside full-screen apps until Create succeeds, Cancel, Esc, ⌘W or its close button, which drop the draft; an opening while it shows brings it forward unchanged; a failure after closing brings it back, not key. One folder dragged onto the Directory field or its button fills the field as a pick, `~/…` under This Mac's home folder, absolute elsewhere, whether or not the field is being edited (the field editor never inserts text of its own); a file, an app, several items, text or a link are refused with no "+"; a highlight while a folder hovers; the field's VoiceOver hint mentions the drop. | Tested hermetically: the model, placement and keys over fake surfaces (Phase I-9a), the drop as a pure function, in the model, and its AppKit drop target in the real window, never shown, over private pasteboards; the window's states rendered in both appearances. The real window over other apps and Spaces, a real drag from Finder, the keys, VoiceOver and a creation: by a person (checklist 23). | Phases I-9a and I-9b, 2026-11-05 (*Phases I-9a and I-9b* below): `NewSessionWindowTests`, `FolderDropFunctionTests`, `FolderDropModelTests`, `FolderDropTargetTests` (`FolderDropTests.swift`); `docs/screenshots/new-session-states-*.png`. |
| New session's folder search, the core (PLAN.md Phase I-10, D36; the list section, the setting and "Missing a folder?" are Phase I-10b's): one static script on This Mac and over discovery's noninteractive ssh, folder names only (case- and diacritic-insensitive "contains"), typed text escaped and bounded, a fixed noise rule, at most 50 folders, a header that says when Spotlight is missing or indexing is off, one channel with a 150 ms debounce, one query in flight and bounded waits, and the home or whole-disk scope in `preferences.json`. | Tested hermetically and for real (core only) | Hermetic: the real script under stub `mdfind`/`mdutil` (bash and dash), the parser, the transport with real local processes, the channel over a fake transport and clock, the preference on private folders. Real: escaping by counts against `mdfind` on synthetic folders, and `folders --count-only` runs on this Mac and Saturno, both scopes, several queries per channel, no process left (*Phase I-10a* below). |
| Detach other clients, the core (PLAN.md Phase I-11, D37; the popover's item and its confirmation are the next row's): with a confirmation naming the session, this Mac's attachment (the one Show tab focuses) stays and every other client of the session, on any Mac, is detached through that attachment's tmux connection, each once it is 10 s old and by name after a check of its pid, creation time and session right before (one round trip before; PLAN.md D37 records what that leaves); a `detach-client` tmux did not confirm is never counted; iTerm2's windows of the session are never closed or reopened; local and SSH hosts alike. | Tested hermetically and for real (core only) | Hermetic: `DetachOtherClientsTests` (the confirmation for another key, the commands and their validated values, identity changed, nothing to detach, not attached here, every failure, an unconfirmed detach, the wait for young clients, several attachments here, cancellation) and `ITerm2APIClientTests` (a send-command answer without output is `tmuxCommandFailed`). Real: `e2e-detach-others --local` and `--ssh saturno-m4`, 9 of 9 each, a plain control client of the harness detached (`%exit`, exit 0), the launch tab's tabs and sessions unchanged for 2 s; option (a), `attach-session -d`, rejected after iTerm2 closed and reopened the session's windows on both hosts (*Phase I-11a* below). |
| Detach other clients in the popover (PLAN.md Phase I-11b, D25, D37): the row's context menu shows "Detach other clients…" only for a live row (not stale, not unreachable) this Mac's iTerm2 shows whose listing has more clients than this Mac's attachments of it, disabled while another action of the row is pending, hidden otherwise, never in the switcher; the badge then reads "Open in iTerm2 here · also attached elsewhere"; the in-popover confirmation (the count, "including <k> in this Mac's iTerm2", other Macs, the session keeps running, the window-size sentence; Return confirms, Esc and Cancel run nothing, the arrows, ⌘F and ⌘N do nothing; VoiceOver hears its title) is the only way to the core call, for the session it names; "Detaching other clients…", then each outcome's own line and recoveries ("Try again", as after a move here, in the popover only: the switcher's row offers the others), the host refreshed afterwards (not after `cancelled` or `notConfirmed`); quitting cancels it. | Tested hermetically and in the preview renders (both appearances). Two real Macs, the real popover, VoiceOver and the window size afterwards: by a person (checklist 25). | Phase I-11b, 2026-11-06 (*Phase I-11b* below): `DetachOtherClientsUITests` (`DetachOtherClientsUITests.swift`), `FailureMessageTests`; `docs/screenshots/attach-states-*.png` and `popover-states-*.png` regenerated and inspected. |
| Terminal (Terminal.app) as the chosen terminal, plain tmux (PLAN.md Phase I-12, D38; `docs/TERMINALS.md`): chosen in Settings › General or onboarding (the default without iTerm2); Open in a new window through the built-in script's `do script` with D3's command text, confirmed from the helper's early report and tmux's clients (on This Mac by `client_tty`, over SSH by the launch token); "Show window" by the tab's tty; Detach and Move here through bound tmux commands; Detach other clients; "Open in Terminal on this Mac" from process ancestry; "Set up SSH in Terminal…"; the persistent work command; every line naming Terminal; iTerm2 never contacted. | Tested hermetically; the plain attach and its bound commands tested for real without a terminal app (on This Mac and Saturno); the gate's refusals tested for real. Terminal's windows (its script compiled and called, `e2e-plain --terminal terminal` locally and on Saturno, the app's rows, the picker's real permission, "Set up SSH in Terminal…", the pasted command, onboarding without iTerm2): owed to a person (checklist 26–29), since Terminal never ran during the work (*Unattended-run rules* 8). | Phases I-12a to I-12d2, 2026-11-06 and 2026-11-07 (*Phase I-12a* to *Phase I-12d2* below): `TerminalCommandTextTests` (the text read the same by sh, zsh, bash, dash, ksh, tcsh and csh), `TerminalDefinitionTests` (the built-in loads cleanly), `PlainTerminalWindowsTests` (its open with `attach-plain`, focus by tty, close only of recorded ids, over a fake runner), `PlainTerminalBackendTests`, `PlainTerminalBackendEndToEndTests` and `E2EPlainStepsTests` (the real helper, tmux and bound commands on a private server, the window a pseudo-terminal), `LocalClientAttributionTests` (Terminal's chain), `TerminalChoiceTests`, `TerminalSeamTests`, `TerminalPickerTests`, `PlainSSHSetupLauncherTests` and the session wording, error and model suites. Real: `plain-proof --local` and `--ssh saturno-m4`, 9 of 9 each (no terminal app); `attach --terminal terminal` and `e2e-plain --terminal terminal --local`: exit 2, nothing created, written or sent; `terminals list`: Terminal 2.15 installed, not running (`targetNotRunning`); `pgrep -x Terminal` empty before and after every phase. |
| Ghostty 1.3 or later as the chosen terminal, plain tmux (PLAN.md Phase I-12, D38; `docs/TERMINALS.md`): as the Terminal row, with the built-in script's `new window with configuration` (the helper path, mode word and launch id as the command's words, "wait after command" off), "Show window" by the window id it returned, Ghostty before 1.3 never listed and, as the stored choice, unavailable with its reason; "Ghostty's AppleScript is turned off" when its open answers -1708 or -10004 (a guess); the persistent work command after `command = ` in its config. | Tested hermetically; the plain attach for real without a terminal app (the same `plain-proof` runs); the gate's refusal tested for real. Ghostty's windows (its script compiled and called, its ids, `e2e-plain --terminal ghostty` locally and on Saturno, the app's rows, the real error number with `macos-applescript = false`, "Set up SSH in Ghostty…", the pasted command): owed to a person (checklist 26–28), since Ghostty never ran during the work. | Phases I-12a to I-12d2 (*below*): `TerminalLaunchCommandTests` (the `words` form and its 23 refused characters), `TerminalDefinitionTests` (the built-in loads cleanly), `PlainTerminalWindowsTests` (its open with the token as the last word, focus by window id, over a fake runner), `TerminalPickerTests` (Ghostty 1.2 too old, upgraded on "Check again"), `TerminalErrorMappingTests` and `TerminalReviewFixTests` (the AppleScript-off line only from muxFinder's own script). Real: `e2e-plain --terminal ghostty --local`: exit 2, nothing created, written or sent; `terminals list`: Ghostty 1.3.1 installed, not running (`targetNotRunning`); `pgrep -x ghostty` empty before and after every phase. |
| The update check, the core (PLAN.md Phase I-13a, D39; the download and install are I-13b's, the popover notice, the icon's dot and Settings are I-13c's): one anonymous `GET` of `releases/latest` with `Accept`, a constant `Accept-Language`, `User-Agent: muxFinder/<version>` and `If-None-Match` only; tags exactly `v<major>.<minor>.<patch>` compared numerically; the one `muxFinder.zip` at its exact URL with a `sha256:` digest and a size from 1 byte to 50 MiB, else the release page only; a body over 1 MiB, a redirect off `api.github.com`, drafts and prereleases offer nothing; 304, rate limits and failures; `update-state.json`; `checkForUpdatesAutomatically` on by default; the first check 5 s after start, then 24 h after a success, an hour after a failure, never before a rate limit ends, none with the toggle off, a manual check always. | Tested hermetically (the transport through a `URLProtocol` stub only). The real request to GitHub: owed to the user (checklist 30), since no run sends one (*Unattended-run rules* 3). | Phase I-13a, 2026-11-07 (*Phase I-13a* below): `UpdateVersionTests`, `UpdateReleaseParserTests`, `UpdateTransportTests`, `UpdateCheckTests`, `UpdateStateStoreTests`, `UpdateCheckPreferenceTests`, `UpdateSchedulerTests`, `UpdateProbeTests`; `update --help` and `update check --help` exit 0, nothing contacted. |
| The update's download and verification, the core (PLAN.md Phase I-13b1, D39; the running app's eligibility, the swap and the relaunch are I-13b2's, the UI I-13c's): only the release's exact asset URL, into a given private staging folder, redirects followed only to `https` on GitHub's three download hosts (at most 5), the exact declared size, SHA-256 while streaming, progress, Cancel deleting the partial file, 30 s and 20 min timeouts; the zip's directory and local headers checked before unpacking (declared sizes, entry count, compression ratio, consistency, names inside `muxFinder.app`), `ditto -x -k` into a fresh folder under a watchdog that stops it past the byte or entry budget; exactly one `muxFinder.app` with no link leading out of it, walked within bounds; the Developer ID signature of the given team and its notarization through Security.framework; the versions after the signature, read from the checked bundle, which must still be the one at its path; every failure deleting what was written, success keeping only the bundle with its identity. | The download tested hermetically (the transport through a `URLProtocol` stub only); the other steps on synthetic zips and ad hoc signed stubs. Tested for real on a local copy of 0.2.0's stapled release zip (zip mode, no server contacted): verified, and a changed byte and another Team ID refused. The real download from GitHub (`update verify --latest`): owed to the user (checklist 30), since no run sends a request (*Unattended-run rules* 3). | Phase I-13b1, 2026-11-07 (*Phase I-13b1* below): `UpdateDownloadTests`, `UpdateArchiveTests`, `UpdateExtractionTests`, `UpdateCodeCheckTests`, `UpdateBundleVersionsTests`, `UpdateVerifierTests`, `UpdateVerifyProbeTests`; `update verify --zip` on a copy of `build/muxFinder.zip`: every step passed, exit 0; one byte changed: `digestMismatch`, exit 1; another Team ID: `otherTeam`, exit 1; after the review fixes, a fresh copy: every step passed, exit 0. |

## Unit tests (`swift test`)

Hermetic (PLAN.md D11): no ssh, no iTerm2, never the user's tmux server.

- **Discovery parser** (`ProbeReportParserTests`): real captured reports from this Mac and
  Saturno (`Tests/MuxFinderCoreTests/Fixtures/discovery/`), real hostile names captured from a
  private tmux 3.8 server, synthesized hostile names (raw tabs, text that mimics records,
  `a;rm -rf ~`, `$(touch /tmp/x)`, quotes, `-x`, emoji, CJK), a malformed corpus (bad ids,
  non-canonical integers, nonce mismatches, forged records after a line break, duplicate ids,
  mixed servers, missing or extra lines), the 4 KiB line and 1,000 session/client caps, every
  truncation of a real report, and single-byte corruption at every position.
- **Classifier** (`ErrorClassifierTests`): a table of ssh stderr strings captured on
  2026-10-21 (plus standard OpenSSH wordings that could not be produced here, marked
  synthesized), "changed beats verification failed", run failures, no-server messages,
  session keys per host.
- **Requests** (`DiscoveryProbeTests`): exact argv for local and SSH runs, `TMUX`/`TMUX_PANE`
  stripped, D6 options, strict-harness options (including no connection sharing), invalid
  configuration rejected before any process runs.
- **Probe script** (`ProbeScriptTests`): the real static script through `/bin/sh`, and the D3
  command string through `/bin/sh`, `/bin/zsh -f` and `/bin/bash`, against a fake `tmux`
  (fails if `-u` is missing or `TMUX` leaks): sessions and clients, metacharacters in the
  override path, not found / not tmux, no server, stderr sanitizing (first line, printable
  ASCII, 200 bytes), an 8 MiB stderr flood (real exit status kept, 200 bytes reported, peak
  memory of the shell and its children under 8 MiB per `/usr/bin/time -l`), an endless `-V`
  line cut to 200 bytes, client-listing failure, a hanging tmux stopped by the timeout.
- **End to end** (`DiscoveryEndToEndTests`): real tmux on a private `TMUX_TMPDIR` under `/tmp`,
  started with `-f /dev/null`, holding only `muxfinder-test-*` sessions running `sleep 60`
  (Unicode, emoji, shell metacharacters). Checks no-server, every created id and name, no
  injected file, then kills the server's `muxfinder-test-*` sessions by id and checks
  no-server again. Cleanup runs in a task of its own, so it is not cancelled with the test,
  each tmux command has a timeout, and it ends before the directory is removed; a second test
  cancels its task while a session exists and checks the session is gone. `TMUX` and
  `TMUX_PANE` are set to a bogus server to prove they are ignored. Skips when tmux is absent.
- **Session start folders** (`ProbeSessionPathTests`, `StartFolderSnapshotTests`,
  `SessionPathEndToEndTests`; PLAN.md D31): the real capture from a private tmux 3.8 server
  (`local-session-paths.txt`: 7 sessions, 2 folders kept, 5 dropped, no forged session) and a
  synthetic corpus (`synthetic-session-paths.txt`, 17 sessions: spaces, Unicode, `#`, `;`, `%`
  and a leading `-` kept; forged session, client, status, end and path lines after a line
  break, a tab, an escape sequence, DEL, a C1 control, a carriage return, invalid UTF-8 and an
  empty path dropped; one session without a record); 12 kept and 15 dropped paths one by one
  (NUL, overlong encodings, 4,096 bytes kept and 4,097 dropped, 9,000 bytes past the line cap
  dropped without failing the report); seven forgeries with a guessed nonce that stay inside
  their record; misplaced records (before any session, another id, a second one, another
  nonce, no end mark) failing the report; line numbers across a multi-line record; every
  report without records still parsing; every truncation and single-byte corruption of the
  corpus; the real script through the fake `tmux` locally and through the D3 string with sh,
  zsh and bash; the script's bounded format; a report at the parser's limits through the real
  runner and discovery's request (1,000 sessions on 4,096-byte lines in 4,096-byte folders
  and 1,000 clients, about 8 MiB: nothing cut, every folder kept, the empty record dropped and
  counted) and the largest accepted report (18-digit ids, header lines at the cap) within the
  budget while one byte over it is "too large"; a stale snapshot keeping its folders; and real
  tmux on a private server with plain, `~/…`, Unicode and `##`, forged, escape-sequence and
  empty `-c` values, and with 4,096-byte (kept whole), 4,097-byte and 8,001-byte `-c` values
  (printed as an empty record, no part of them in the raw report, dropped and counted).
- **iTerm2 protobuf codec** (`ProtoWireTests`): varint edge cases (0, 127, 128, `UInt32.max`,
  2^63, `UInt64.max`, negative `int32`/`int64` as 10-byte varints), every scalar and
  length-delimited encoding, unknown fields of all four wire types skipped, known fields with
  the wrong wire type skipped, repeated occurrences of a singular embedded message merged (no
  value may span two occurrences, and the nesting limit still holds), split-tree link oneofs
  merged until the member changes, and typed `ProtoWireError`s for truncated keys, varints,
  length prefixes, fixed-width and length-delimited values, lengths past the end (also past a
  nested message's end), overlong varints, wire types 3/4/6/7, field numbers 0 and 2^29, and
  nesting past 100 levels; each malformed input is also checked inside a response envelope.
- **iTerm2 golden messages** (`ITerm2GoldenTests`, `ITerm2JSONTests`): every request type
  (list sessions, create tab with a command, with window/index/close-on-end, with a command
  needing every JSON escape, activate session/tab/window/app, list profiles with and without
  filters, tmux list connections and send command, close sessions with `force` and close windows
  without it) encodes byte for byte like the fixture
  iTerm2's Python module produced. Every response fixture decodes to the expected values:
  nested split trees, tmux tab fields, minimized and buried sessions, unknown fields of every
  wire type (top level and nested), status enums, profile `Name`/`Guid`, errors, unsupported
  submessages and notifications, close statuses both unpacked (as iTerm2 writes them) and as a
  packed run; the three send-command answers iTerm2 3.7 builds without a status (an empty
  output present, a `send_command` without output, no payload at all); unknown enum values
  decode to `unknown`. Merge fixtures, which
  the generator checks against `api_pb2`'s own decoding, cover responses split across
  occurrences (`08 01 92 07 02 08 01 92 07 00`, a list-sessions response whose tab root and
  links arrive in pieces, a tmux send-command), unknown fields before and after a response
  (including Python's re-serialization of the list-sessions fixture), and oneof members
  replacing each other. Every truncation and single-byte corruption of every response fixture
  decodes or throws `ProtoWireError`. The fixtures (`Tests/MuxFinderCoreTests/Fixtures/iterm2/`)
  hold only synthetic values (a test checks for machine-specific strings) and are committed;
  `swift test` never runs Python.
  Regenerate them (dev only, after changing the generator) with iTerm2's interpreter in
  isolated mode, then check that `git status` shows only intended changes:
  `"$HOME/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3" -I scripts/dev/gen-iterm2-fixtures.py`.
- **WebSocket frames** (`WebSocketFrameTests`): the three payload-length encodings at 0, 125,
  126, 65,535, 65,536 and 70,000 bytes (header bytes, mask bit, key, masked payload), unmasked
  round trips, a fresh masking key drawn per frame (counted with an injected key source; the
  default source is random), no data frames after a close, a failed write shutting the stream
  down, the writer's queue behind a blocked write (a withdrawn message never written, one whose
  deadline passes while queued skipped with `timedOut`, the message being written no longer
  withdrawable and written whole, unstarted data before a close skipped), the close codes
  allowed on the wire (all 65,536 checked), strict UTF-8 validation, and rejected server
  frames: reserved bits, reserved opcode, masked, fragmented or over-125-byte control frames, a
  64-bit length with its top bit set, an oversized length refused from the header alone;
  every split point of a frame decodes only once complete.
- **WebSocket handshake** (`WebSocketHandshakeTests`, fake stream): the exact request iTerm2
  needs (every verified header, random 16-byte key), the RFC 6455 accept example, unsafe header
  values refused, a reply delivered one byte per read, frame bytes in the same read as the
  header tail handed to the reader, 401/406/500 replies, a wrong accept key, missing
  `Upgrade`/`Connection`, malformed status and header lines, an unrequested subprotocol or
  extension, the server closing mid-reply, an endless reply head (16 KiB cap) and a silent
  server (timeout).
- **WebSocket reader** (`WebSocketReaderTests`, fake stream): a three-fragment message with a
  ping and a pong between fragments delivered one byte per read (reassembled; pong with the
  ping's payload), several frames in one read, frames split mid-header and mid-payload, a
  server close answered with its code and the stream shut down, valid close codes with a UTF-8
  reason echoed (1000, 1003, 1007, 1014, 3000, 4999), malformed close payloads answered with
  1002 and never echoed (one byte; codes 0, 999, 1004, 1005 — the review's `88 02 03 ED` —,
  1006, 1015, 1016, 2999, 5000) or with 1007 (a reason with an invalid byte, a surrogate or an
  overlong form), a client-initiated close not answered twice, the 16 MiB cap (exactly 16 MiB
  accepted; one byte more refused from the header with close code 1009), read timeouts that
  keep partial input, protocol violations closing with 1002 (text message, stray continuation,
  new message inside a fragmented one), end of stream mid-frame.
- **Unix socket transport** (`UnixSocketStreamTests`): `socketpair()` transfer both ways
  (200 KB through a small buffer on two threads), read timeout, `shutDown()` waking a blocked
  read, peer close as end of stream and `closedByPeer` instead of `SIGPIPE`, missing socket and
  stale socket file (bound, then closed, under `/tmp`) both `apiDisabled`, an overlong path,
  and a whole handshake plus request plus close handshake over a socket pair with a server
  thread. Never iTerm2's socket.
- **Request matching** (`ITerm2ConnectionTests`, fake peer): ids 1, 2, 3; responses answered
  3, 1, 2 with a notification and an unknown id in between; a server `error` failing only its
  request; end of stream failing every pending request; per-request timeout with the late
  response ignored; an undecodable message (`protocolError`); an empty response; task
  cancellation; ping while a request waits; server close; a malformed server close
  (`protocolError`, answered with 1002); client close; a stalled half-received message
  (`timedOut`) while an idle connection stays open; a failed write (`notSent`); and, with the
  fake stream's writes held, a request queued behind a blocked write then cancelled or expired
  (fails as not sent; its frame never reaches the stream, the next frame is request 3), a
  request cancelled or expired mid-write (plain `CancellationError`/`timedOut`; its frame still
  arrives whole), and a connection end failing the request being written with `disconnected`
  and the queued one with `notSent(.disconnected)`.
- **Client lifecycle** (`ITerm2APIClientTests`, fake connector, cookie provider and app
  control): first call connects with the verified headers and decodes the list-sessions
  fixture; not running (no cookie, no connect, no launch); socket missing (no cookie);
  connection refused; cookie failures (`automationDenied`, `cookieUnavailable`); HTTP 401
  (`authRejected`); a reconnect after iTerm2 drops the connection using the second cookie;
  concurrent first calls sharing one connection; `createTabFailed`, `activateFailed`,
  `tmuxRequestFailed`; a tmux reply without payload as an empty list; a send-command answer
  counted only with its output (an empty output is the empty string; a `send_command` without
  output, or no payload, is `tmuxCommandFailed`, never an empty success, for the plain and the
  ownership-bound call; Phase I-11a review); successful create tab,
  send command, list profiles, activate and close; an ownership-bound tmux command (the listing,
  then the command on the same connection when the owner matches; only the listing for another
  owner, `tmuxConnectionNotOwned`; a listing lost with its connection → `notSent`, no
  reconnect); an ownership-bound activation (the connections, the sessions and `Activate` of
  the connection's first tab on the same connection, the given target replaced; `nil` and no
  `Activate` for a connection without a tab; only the listing for another owner; a sessions
  listing lost with its connection → `notSent`, no reconnect); a mismatched response type;
  `ensureRunning()`
  launching only when needed and failing when the socket never appears; disconnect then
  reconnect; `disconnect()` during the cookie request (gated fake provider: the waiting call
  fails at once with `notSent(.disconnected)`, the invalidated attempt never connects, the next
  call uses the second cookie) and during the handshake (the late connection is closed with a
  1000 close frame and shut down, the next call opens a new one); a caller cancelled while
  waiting for an attempt that is connecting (`CancellationError` at once, the attempt's
  connection serves the next call); an attempt every caller left during the cookie request
  stopping before it connects (nothing written, the next call uses the second cookie), and
  one left during the running check asking for no cookie; a caller joining during the cookie
  request after the earlier one left keeping the attempt (one cookie, one connection);
  diagnostics recording only the error kind.
- **Cookie and fake** (`ITerm2CookieAndFakeTests`): strict `"<cookie> <key>"` parsing (12
  malformed shapes refused, including header injection), AppleScript error mapping (-1743 →
  `automationDenied`), the static script source, the real provider refusing to run while
  iTerm2 is not running, error kinds (including `notSent`) and one-line descriptions without
  iTerm2's error text,
  `FakeITerm2Integration` (queued results then fallback, call log including close, not-running and
  socket-missing guards, `ensureRunning()`, the ownership-bound tmux command checking the next
  listing), and `Tab.isTmuxTab` with iTerm2's `"-1"`.
- **Launch models** (`LaunchModelsTests`): canonical lowercase launch ids accepted, 12
  malformed ones refused (uppercase, braces, missing hyphens, non-hex, path traversal,
  whitespace, non-ASCII); request and result JSON round trips and the exact request keys; an
  unknown host kind, a non-`$N` session id or an uppercase id refused on decode; unusable
  values (format version, pid 0, relative override, negative time); every failure's
  `{"kind": …}` encoding; the full exit status → failure tables for the attach child (64–68,
  other statuses, 126/127/255, signals) and the check child (a timeout wins, 64–68, anything
  else check failed), and each failure's exit status (75 for a check timeout, 128 + n when
  interrupted; PLAN.md D14).
- **Launch store** (`LaunchStoreTests`, temporary directories only): directory 0700 and files
  0600 checked with `lstat`, no temporary file left; `<root>/launch` from `AppPaths`; a 0755
  directory tightened; a symbolic link as the directory refused for every operation (target
  untouched); a foreign directory refused (root-owned `/usr`, and a temporary one checked
  against another uid, unchanged); a file in the way; a missing directory never created by
  the helper's operations; delete on read and single use; duplicate ids refused; TTL with a
  fake clock (valid at 120 s, refused and removed at 121 s, and when dated 60 s in the
  future); the sweep (only stale request/result/digest/temporary files; the test-mode marker,
  other files and directories kept); results taken once; unsafe request files refused and
  removed (symbolic link with the target kept, FIFO without blocking, 0644, oversized,
  invalid JSON, another id); the test-mode marker only as a regular file, created 0600 and
  removed once; argv digests. Extended ACLs, set with `acl_set_link_np` inside the test's own
  temporary directory: an inheritable `everyone` ACL and a deny-only one on the launch
  directory removed by the helper's and the app's operations; a parent with an inheritable
  ACL leaves none on the created launch directory or on any file written there (request,
  result, argv digest, marker), all 0600; the writer removes an ACL a new file inherited
  (the premise checked first) before writing; request and result files with an allow or a
  deny-only ACL refused and removed; an immutable directory whose ACL cannot be removed
  refused as unusable.
- **Helper path** (`LaunchHelperPathTests`): the D2 rule (space, quotes, `$`, backticks, `;`,
  tab, line break, `~`, `\`, non-ASCII and relative paths refused; bundle, build and plain
  paths accepted), the tab command line, and locating the helper next to an executable
  (missing, not executable, through a symbolic link, in a folder with a space).
- **Guard script** (`LaunchGuardTests`): the real static guard (the check child) through
  `/bin/sh` against a fake `tmux`: exact argv and check request (stdin `/dev/null`, 10 s
  default deadline, 4 KiB cap), the separate attach argv, no `exec` or `attach-session` in
  the script; a match exits 0 and prints exactly the tmux path, nothing on stderr, no
  attach; the printed path accepted only as one line with an absolute path to a regular
  executable file (links followed) and, with an override, only the override (11 refused
  shapes: no newline, extra lines, relative, empty, missing, a directory, not executable,
  CR, NUL, invalid UTF-8); identity answers classified (changed values → 65, empty or other
  session id → 64, empty or garbage → 67); tmux errors (no server, no socket, can't find
  session → 64; permission denied, protocol mismatch → 67 with the line on stderr, sanitized
  to printable ASCII and 200 bytes); missing or non-tmux override → 66 without fallback; 11
  bad argument shapes → 68; `TMUX`/`TMUX_PANE` never reach tmux.
- **Guard on real tmux** (`LaunchGuardRealTmuxTests`): a private `TMUX_TMPDIR` server under
  `/tmp`, started with `-f /dev/null`, holding one `muxfinder-test-*` session; the check only,
  never an attach. No socket → 64; the discovered session passes and yields the located tmux,
  with and without an override; a wrong id → 64; a wrong `session_created`, pid or server
  start time → 65; after the server exits (stale socket) → 64. Cleanup kills the session by
  id, like the discovery end-to-end test. Skips when tmux is absent.
- **Terminal child runner** (`TerminalChildRunnerTests`): attach child: exit status and
  signal terminations; the child stays in the parent's process group and gets only
  descriptors 0–2 (an inheritable descriptor numbered 100 or above does not leak); signals
  forwarded through the control, both queued before the spawn and sent while the child runs
  (SIGHUP → `terminalHungUp`); task cancellation → SIGTERM; spawn failures. Check child:
  piped output and its own process group; a pending signal interrupts it before anything is
  spawned; a signal while it runs kills its whole group, including a background descendant
  that ignores SIGTERM (pids and group gone); task cancellation → `interrupted([SIGTERM])`; a
  spawn failure is thrown.
- **Helper logic** (`LaunchHelperTests`, fake child runner and terminal): success (request
  consumed; the check with the guard argv, the helper's deadline and `TMUX`, `TMUX_PANE` and
  `MUXFINDER_LAUNCH_*` removed from its environment; the attach as the printed tmux path with
  `-u -CC attach-session -t <id>` and the same environment; success result, no output, no
  wait); a guard failure ends the launch before any attach, explained, and waited for only
  when interactive; the check's stderr copied to the tab as printable ASCII before the
  explanation and kept out of the diagnostics; an unusable printed path (missing, not the
  override) → 67 without an attach; a check timeout → 75; a check interrupted by SIGHUP
  (129, no wait) or SIGINT (130, waits); a closed tab during the attach (SIGHUP passed on)
  never waited for; signal deaths exit 128 + n; missing (70), expired (71) and spawn-failure
  (74, either child) results; 7 usage errors (exit 2, nothing run or consumed) and `help`;
  an unusable directory override (73); the argv digest written by the environment variable
  or the marker file, before parsing; diagnostics free of paths and session ids. The minimum
  lifetime (D14): on an interactive terminal that was not hung up, every outcome (a tmux exit
  right after attaching, a guard failure after Return, a usage error) holds the tab until the
  helper is 10 s old, after the result is written and after any wait for Return; only the
  rest of the 10 s is held (4 s elapsed → 6 s, 9.5 s → 0.5 s, 10 s or more → none, a clock
  that went backwards → 10 s); `help`, a terminal that is not interactive and a SIGHUP never
  hold. `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` sets the lifetime only when it is 1 to 7
  decimal digits (else 10 s). The wait gate resumes its wait exactly once, also when the end
  comes before the wait or several ends race.
- **Stalled check** (`LaunchHelperStalledCheckTests`): the helper in the test process with
  the real child runner (300 ms grace) and the real guard against the fake tmux hanging in
  `display-message` (it ignores HUP, INT and TERM and keeps a background `sleep 30` that does
  too). With a 1 s deadline (doubled and retried, up to four times, if a loaded machine did
  not reach `display-message` in time) the launch ends as `checkTimedOut` (75) after the
  deadline and less than 5 s past it; a SIGHUP passed on through the control ends it at once
  as `interrupted` (129) without a wait for Return. Either way the fake, its sleeper and their
  process group are gone, and nothing attaches.
- **Helper binary** (`LaunchHelperBinaryTests`): the built `muxfinder-launch` run with a
  private launch directory, `MUXFINDER_LAUNCH_NO_WAIT=1` and stdin that is not a terminal:
  usage errors (2); a missing request (70) with its result and an argv digest of exactly
  argv (count 3, the binary path's length and SHA-256, the launch id); the attach path
  against the fake tmux (tmux is the helper's direct child, in the helper's process group,
  reading the helper's stdin, writing its stdout; exit 0 → success, exit 1 →
  `childExited(1)` with the explanation); SIGTERM and SIGHUP sent to the helper alone reach
  tmux (the fake's traps exit 43/44), and the helper survives to record the result; SIGTERM
  and SIGHUP sent to the helper alone while the check hangs end the launch as `interrupted`
  (143/129) with a result, and the check's process group (separate from the test runner's,
  so only the helper can have removed it) is gone; real tmux on a private server: no server
  → 64, wrong `session_created` → 65, both recorded in the result. No real tmux client is
  ever attached by `swift test`.
- **Helper binary in a terminal** (`LaunchHelperTerminalTests`): the built `muxfinder-launch`
  with its stdin on a pseudo-terminal's slave side (so it is interactive), stdout and stderr
  on a pipe, its own process group, a launch id without a request (70, no child) and a
  shortened `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS`. Signals and Return are repeated every
  50 ms until they take effect. SIGINT and SIGTERM, from the failure prompt on or only during
  the hold after Return, never end it: it exits 70 with its result no earlier than its 3 s
  lifetime and less than 5 s after the later of that lifetime and the end of the wait, which
  the signal ended like Return. SIGHUP, at the prompt or during the hold, kills it at once,
  far inside its 60 s lifetime.

- **Attach coordinator** (`AttachCoordinatorTests`, fakes for iTerm2, discovery, the launch
  store and the clock; a manual clock makes the 15 s budget run out at once; the
  existing-attachment check off, so only the launch path's calls are seen): a successful
  attach (states `requested` → `launched(gateway)` → `confirmed(connection)`, the request file's
  values, the launch tab request — new window, `<helper> attach <uuid>`, close on end, the host's
  profile and tmux override —, the identity command through the connection, bound to the launch
  tab, activation of the
  connection's first tab without `select_session`, no close request); a connection that appears
  after two polls next to another tab's; activation waiting for the first tab, `noTab` after its
  budget (still confirmed), a refused activation, and a launch tab's connection id that is
  another tab's by the activation (`failed(tmuxConnectionNotOwned)`, nothing activated, still
  confirmed); two concurrent attaches for one session
  sharing one launch and one result (one discovery, one request, one `CreateTab`, one
  `launched`), a later attach launching again, different sessions not coalescing; cancelling
  every caller (`cancelled`, request withdrawn, launch tab still reported); an all-cancelled
  launch whose held `CreateTab` answers after a newer launch was confirmed (its updates reported
  with `isCurrent` false, the session's state left at the newer `confirmed`); the 15 s poll timeout
  (`timedOut`, request withdrawn, nothing sent through a connection); helper results mapped to
  failures (64–66 to `sessionGone`/`sessionChanged`/`tmuxMissing`, others to `helperFailed`,
  exit 0 before a connection to `helperEnded`); identity answers naming another pid, start time,
  socket or session (`identityMismatch`) or unreadable (`identityCheckFailed`), each followed by
  `detach-client` bound to the launch tab only once it is 10 s old (virtual time, counted from
  `launched`) and no activation (a tab-separated answer, wrong lengths or a client not in
  UTF-8 mode are unreadable); a failed identity request with nothing more sent;
  revalidation failures (no server, tmux missing, session gone, `session_created` changed, id
  reused by another server, probe error) before anything is written or sent; SSH destinations
  that are not valid (empty, option-like, whitespace, a line break) refused before discovery;
  a request that cannot be written; `CreateTab` failures (definitive, not sent, unknown outcome)
  sent once, never retried, request withdrawn; `ensureRunning()` failing; detach sending
  `detach-client` bound to the launch tab, waiting for the connection to close and taking the
  helper's result (clean), a detach not sent (no wait), a connection that never closes (budget,
  one command only); detach waiting until the launch tab is 10 s old (right after the attach:
  sent at 10 s; 12 s later: no wait; a tab it did not open: 10 s from the call), a detach
  cancelled during that wait sending nothing, and a connection id now owned by another session
  (an iTerm2 restart) refused with `tmuxConnectionNotOwned`, nothing sent. Every failure has a
  kind and an English message.
- **Created session** (`CreatedSessionTests`): the static `CreatedSession.format`, its parser
  (trailing line breaks; 14 refused shapes, among them a tab in the socket path or name), the
  match against discovery (server pid, start time, socket path, id, creation time and name must
  all agree: a restarted server reusing the id does not match), and recovery by exact name
  among sessions created since a given time (no match, older, ambiguous). The conditional kill
  (PLAN.md D18 *Real-run safety*): the exact `if-shell -F` argv (every field compared, the id
  single-quoted in the kill's command string), a name with `#`, `,`, `}` written as a format
  literal, no argv at all for a name or socket with `{`, `[`, `]` or a control character or for
  a negative number, and how its answer reads (no output: killed; the marker line or tmux's
  "no server": not this session; anything else: failed). Against a real tmux on a private
  `TMUX_TMPDIR`: a session that got the old id and name on a restarted server is not killed by
  the old record; a record off in any one field (another session's id, `$999`, creation time,
  pid, start time, socket, name) kills nothing; the exact record kills only its session, then
  finds nothing; the last session's kill succeeds and, with no server, the answer is not this
  session.
- **Connection identity** (`ConnectionIdentityTests`): the static length-prefixed identity
  command (PLAN.md D16) and detach command; exact answers from a client in UTF-8 mode
  (trailing `\n` or `\r\n`; `:`, `_`, a tab and non-ASCII inside the host name and socket
  path, the lengths deciding); a clean answer from a client not in UTF-8 mode; 8 answers from
  such a client that are `nonUTF8`, never an identity (`é` replaced so the path is shorter than
  its length, a tab replaced at the same length, `_` or `:` in the host or path, a dropped
  zero-width character that makes the host swallow the next separators, a non-ASCII byte, the
  old tab-separated line as tmux mangles it); and 30 unreadable shapes (no or another flag, the
  old tab-separated line, wrong or overflowing lengths, missing or extra fields, an empty or
  control-character host, leading zeros, signs, pid 0, overflow, spaces, empty fields, a
  relative or empty path, a bad session id, an extra line, invalid values from a client not in
  UTF-8 mode).
- **Attachment index** (`AttachmentIndexTests`, a fake iTerm2 with per-connection answers and a
  clock whose timeouts fire only when the test advances it): a connection mapped to its
  session, bound to the owner from the listing, with the identity command the only command
  sent; the session id taken from the answer and two connections of one session; unknown
  connections (another host name, a case difference, another pid, start time or socket, a
  restarted server, no hosts) and ambiguous ones (two hosts with the same node name and
  server; the same host listed twice counts once), each counted, never guessed; stale ones
  (no id, no owner or an empty id in the listing, with no command sent; a refused request, an
  unreadable answer, a lost connection; an owner change between the listing and the command,
  refused by the binding rule); clients not in UTF-8 mode (a clean answer maps; `é` or a tab
  replaced, or a `_` that may be a replacement, are `nonUTF8` and never mapped, even when
  discovery reports that very path; the same path through a client in UTF-8 mode maps); a
  hung connection bounded by the 3 s timeout (still waiting at
  2.999 s, stale at 3 s, its request cancelled) while the other connection maps; the filter
  (connections left out get no command and count as excluded); listing failures thrown
  (`notRunning` included); cancellation; hosts built from discovery results.
- **Attach coordinator, existing attachments** (`AttachFocusTests`, the coordinator with an
  index whose clock never fires): a session attached in the user's own tab is focused
  (`requested` → `focused`, the owning session as gateway, the first tab activated without
  `select_session`, the counts reported) with no request, no `ensureRunning` and no
  `CreateTab`, also when no tab appears (`noTab`); a connection id that is another tab's by the
  activation (the user's connection closed and its id was reused) activates nothing and opens
  nothing (`attachmentChanged`), and with two attachments the other one is focused;
  concurrent attaches share one focus; other
  sessions' connections, unknown servers and stale answers do not block a launch; a listing
  failure fails the attach (`attachmentCheckFailed`) before anything is written; iTerm2 not
  running proceeds to `ensureRunning` and the launch; the default coordinator checks before
  launching; a discovery result without a report fails. `detach(session:on:)`: an attachment
  the coordinator opened (`detach-client` at 10 s counted from its launch, the identity checked
  again first, the helper's result taken), two attachments of the user's (both at 10 s from
  the index's snapshot, in listing order, each bound to its own tab), a user's connection that
  first appears in a snapshot taking 7 s of virtual time (discovery 4 s, listing 3 s: the
  re-check and `detach-client` at 17 s, not 10 s), an owner change refused by the re-check or
  by `detach-client`'s own binding check (`notSent`), a connection that shows another session
  by then, or answers through a client not in UTF-8 mode (`identityChanged`, nothing sent),
  nothing attached (another
  session's connection, no server, iTerm2 not running), cancellation during the wait (nothing
  sent), and check failures (listing, discovery, an SSH host whose destination is not valid).
- **Remote launch** (`RemoteLaunchTests`, PLAN.md D17): the ssh argv
  (`-t -o ConnectTimeout=10 -- <destination> <D3 string>`, no `BatchMode` or other
  host-key option) and the D3 string (the static remote script — locator, the guard's check,
  `exec tmux -u -CC attach-session` — and the five values single-quoted); none for a local
  request or a destination that is not valid; a destination full of shell metacharacters as one
  argv element after `--`, never in the command; adversarial override paths quoted; a hostile
  session name never in the command. The D3 string through `/bin/sh`, `/bin/zsh -f` and
  `/bin/bash` (as a remote login shell would run it) against the fake tmux in a directory whose
  name holds quotes, a substitution and spaces, with `TMUX` set outside: changed 65, gone 64,
  tmux missing 66, a tmux error 67 with its sanitized line, none attaching; a match `exec`s the
  attach of `$3`. The `ssh` host kind's JSON, refused shapes, requests with invalid
  destinations refused when taken; ssh's statuses (64–68 from the remote guard, 0, 1, 255
  classified from captured stderr strings as `authFailed`, `unreachable`, `hostKeyProblem` or
  `other`, a signal as `childSignaled`, 255 locally an ordinary status) and the remote
  explanations.
- **Helper, remote** (`RemoteLaunchHelperTests`, fake child runner and terminal): an SSH
  request runs no local check and one child, `/usr/bin/ssh` with the D17 argv, a relayed
  standard error and the cleaned environment; success holds the tab for the minimum lifetime;
  11 fast failures (ssh 255 with authentication, timeout, DNS, host-key and unclassified
  stderr; the remote guard's 64–67; tmux 1; a signal) each write the result first, print the
  remote explanation, wait for Return and hold until 10 s; a closed tab (SIGHUP passed on) and
  a terminal that is not interactive never wait or hold; ssh that cannot start is 74 (held), a
  request with an option-like destination is refused (72) without running anything;
  diagnostics never name the destination.
- **Standard error relay** (`StandardErrorRelayTests`, real `/bin/sh` children): what the child
  writes on standard error reaches the destination descriptor and its first bytes are captured
  (classifying `Permission denied` as `authFailed`); 20,000 bytes all relayed, 16 KiB captured;
  nothing captured without the relay; a background `sleep` holding the pipe delays the result
  by at most the 0.5 s drain.
- **Relay supervision** (`RelaySupervisionTests`, PLAN.md D17; each fails on a relay that drains
  its pipe in one go with blocking writes to the tab): one pump reads exactly 64 KiB of the
  256 KiB waiting in a socket and four pumps read it all, nothing dropped; a background `yes`
  writing to the relayed pipe, with a tab (a pipe, and a pseudo-terminal) read more slowly
  than that, does not hide the child's exit (the run ends within 3 s, the writer ends once
  the pipe closes); a destination that takes nothing (a full pipe, and a pseudo-terminal whose
  master nobody reads) while the child writes 256 KiB: a SIGTERM given to the control is
  passed on and the child reaped within 3 s, with the full 16 KiB captured.
- **Helper, test launch delay** (`TestLaunchDelayTests`, PLAN.md D14 *Test launch delay*): a
  request with `testLaunchDelaySeconds` 30 runs `/bin/sleep 30` (deadline 35 s, stdin
  `/dev/null`, cleaned environment) before ssh and prints one line, only in test mode (the
  variable or the marker); outside test mode nothing extra runs or prints; without the field
  nothing waits; a local request waits before its check; a SIGHUP, SIGINT or SIGTERM during the
  delay ends the launch `interrupted` with no child started (no wait or hold after SIGHUP, the
  wait for Return and the 10 s hold otherwise); 0, -1, 121 and `Int.max` make the request
  unreadable (72) while 1 and 120 are accepted, and the field round-trips (absent when unset);
  with the real runner a SIGHUP passed on ends a real 30 s delay at once (129) and the check
  never runs.
- **Awaited task** (`AwaitedTaskTests`): `withAwaitedTask` cancels its operation and returns
  only once it has ended, after the body returns, throws, or is cancelled with its caller; and
  the `still waiting` step in miniature: a step cancelled while the coordinator's `CreateTab`
  is held still has the launch tab among its updates when it ends (a `defer { cancel() }`
  without the wait fails all four).
- **Attach coordinator, remote** (`RemoteAttachTests`): an SSH attach writes an `ssh` request
  and confirms within its budget without listing iTerm2's sessions; an identity answer with
  this Mac's node name for the remote session is `identityMismatch` (detached at 10 s); no
  connection for 20 s with the launch tab listed publishes `stillWaiting` at 20 s, then polls
  every second and confirms when the connection appears (at 26 s); a local attach still times
  out at 15 s without listing sessions; while waiting, a helper result
  (`sshFailed(authFailed)`) fails the attach; a tab gone at the budget without a result is
  `timedOut` after the 10 s closed-tab result wait, no `stillWaiting`, request withdrawn; a tab
  closed while waiting ends with the helper's result, also when it comes 7 s later; the wait
  limit ends it `waitLimitReached` at 300 s; a second caller joining while waiting shares the
  one launch and its confirmation; cancelling while waiting ends it `cancelled`. Existing remote
  attachments: the user's connection answering the remote node name is focused (nothing
  opened); one answering this Mac's node name for the same server and session is `unknown` and
  the attach launches; `detach(session:on:)` for the remote host detaches the user's
  connection at 10 s after the re-check, and ignores another Mac's (`nothingAttached`).
- **Attachment index, remote hosts** (`RemoteAttachmentIndexTests`): remote and local
  connections map to their own hosts by node name even though both servers use the same socket
  path, an unconfigured Mac is `unknown`, a node name with another host's server is `unknown`,
  two SSH entries for one Mac are `ambiguous` (2 candidates), and a remote connection that
  never answers is `stale` after 3 s while the other maps.
- **New session: commands** (`TmuxCommandsTests`, PLAN.md D18): the local argv
  (`/bin/sh -c <script> muxfinder <override> <trimmed name> <directory> <command…>`, `TMUX` and
  `TMUX_PANE` stripped, 12 s, 16 KiB cap) and the remote one (discovery's BatchMode options,
  `-n -T --`, one D3 string with every argument single-quoted, a hostile name and a `'` in the
  directory); the script's `-F` format is `CreatedSession.format` and it never uses `-A`;
  invalid names (empty, `.`, `:`, `\`, leading `-`, a tab, 101 characters), a directory with a
  line break, bad destinations and a relative override are refused with zero processes run
  (a recording runner); `-P -F` output parsed strictly (a valid record becomes an attach
  target with tmux's key and creation time; empty, two lines, no line break, bad id,
  non-canonical number, pid 0, relative socket, empty name, extra field, spaces for tabs, cut
  by the cap, invalid UTF-8 are `unexpectedOutput`); every status (80 and tmux's
  `duplicate session` are collisions, other exit 1 `tmuxFailed` with the first line, 81, 66,
  68, 127, 255 local versus remote, a signal, a timeout), the "Set up SSH in iTerm2 first"
  message for `authFailed` and `hostKeyProblem`, a runner error and a cancelled run. Exit 255
  over ssh: eleven ssh messages printed before the remote command can run (permission denied,
  too many authentication failures, an unknown or changed host key, a name that does not
  resolve, connect refused, timing out, no route, network unreachable, host down) are
  `sshFailed` with their class, not `mayHaveCreated`, no refresh; fourteen others (a keepalive
  timeout, `Read from remote host` timing out, without a route or reset, `client_loop` broken
  pipe or unreachable network, `packet_write_wait`, `ssh_dispatch_run_fatal`, closed by the
  remote host, `Killed by signal`, remote text before a close, a reset during key exchange, an
  unknown message, none) are `connectionLost`; those, a signal (local or remote) and exit 137
  or 129 are `mayHaveCreated`, refresh-triggering, with a message saying the session may have
  been created; 68, 127 and 128 stay definite. The real script through `/bin/sh`, and the D3
  string through `/bin/sh` the way the remote login shell parses it, against a fake `tmux`
  that records its argv: a name
  and a `~/` directory full of quotes, `$(…)`, backticks, `#{pid}`, `##`, Unicode and emoji
  reach `has-session -t =<name>` and `new-session -d -P -F <format> -s <name> -c <dir>
  <command…>` byte for byte, every `#` doubled for `-s` and `-c`; `~`, empty, missing and
  relative directories resolve from `$HOME`; a missing directory (a Unicode name, an absolute
  path, a file) exits 81 before `new-session`; `has-session` finding the name stops before
  `new-session`; tmux's duplicate-session error and another error; an override that is not
  tmux; locally and through the D3 string (which carries the raw values), a trailing `;` on
  the `has-session` target, the name, the directory (`~/work #;` reaches tmux as `…/work
  ##\;`) and command words (`;`, `x;`) arrives written `\;`, a lone `;` name as `\;`, and a
  directory ending in `\;` as `\\;`. Against a real tmux on a private `TMUX_TMPDIR` and home: a
  name with `#{pid}`, `##`, Unicode and spaces is stored exactly, the pane runs in
  `~/work #1 {x} ü 日本` (checked with `#{pane_current_path}`), the same name again is a
  `has-session` collision and, through a
  wrapper that hides `has-session`, tmux's duplicate-session error; a missing directory creates
  nothing (one session listed at the end). Also there, with `~/work` and `~/work;` both
  existing and a session `muxfinder-test-semi` already there: `muxfinder-test-semi;` in
  `~/work;` running `sleep 60` is created with that exact name, its pane in `…/work;` (not
  `…/work`), the other session untouched, the server listing exactly the two panes (no extra
  tmux command ran), and the same name again is a `has-session` collision. With the escaping
  removed this test fails (a false `has-session` collision with `muxfinder-test-semi`), and so
  do the fake-tmux one and the `connectionLost` one with the old 255 classification.
- **New session: coordinator** (`CreateAndAttachTests`): `createAndAttach` creates, then
  launches and confirms (`requested` → `launched` → `confirmed`) with the existing-attachment
  check skipped: no connection listing before `CreateTab` and no tmux command but the launch's
  own identity check, although an index is configured (the same session through `attach`
  focuses the listed connection); the request carries tmux's id, creation time and server
  pid. A collision (either kind), a missing directory, a tmux or ssh failure, an invalid name,
  a timeout, a lost connection or a signal never discovers, writes a request, calls iTerm2 or
  publishes a state. A
  created session gone at revalidation (`noServer`, or not listed) is `sessionGone`, marked
  refresh-triggering, with no request or iTerm2 call; so is an ordinary attach of a session
  killed after discovery, and a guard refusal (64, 65) after the tab opened. Exactly
  `sessionGone`, `sessionChanged` and `identityMismatch` (and the guard's 64 and 65) are
  refresh-triggering.
- **Move here: launch side** (`MoveHereLaunchTests`, PLAN.md D21): a normal request is encoded
  without `detachOtherClients` and decodes as a normal attach; `true` decodes as a move here,
  `false` and `null` as a normal attach, `"yes"`, `1` or `[]` make it undecodable; the real
  store keeps the choice. The local attach argv is exactly `-u -CC attach-session -t $3`, or
  `-u -CC attach-session -d -t $3` for a move here only. The remote D3 string uses
  `RemoteLaunch.script` or `RemoteLaunch.moveHereScript`, which differ only in their last step,
  with the same five quoted values; both run through `/bin/sh` against the fake tmux, which
  marks a `-d` attach. The helper (fake child runner, test mode) spawns `-d` only for a move
  here, locally and over ssh, and its digest's `attachChild` holds the exact child argv and
  `detachesOtherClients`; a guard refusal leaves no `attachChild`; a digest without one still
  decodes. The built `muxfinder-launch` against the fake tmux attaches with `-d` only for a move
  here.
- **Move here: coordinator** (`MoveHereCoordinatorTests`): a confirmation naming another key
  (another host entry, session or server) fails `moveHereNotConfirmed` with no discovery,
  iTerm2 call, request or state; a confirmed move here goes `requested` → `launched` →
  `confirmed` with a request whose `detachOtherClients` is `true` (also for an SSH host, whose
  remote script is then `moveHereScript`); `attach` and `createAndAttach` write no such field and
  no `-d`. Attached in this Mac's iTerm2 already (also with the coordinator's check `.off`): it
  fails `alreadyAttachedHere` with that connection and owner, nothing activated, written or
  opened, the identity check the only tmux command; iTerm2 not running: it launches. One
  connection that cannot be ruled out (an unreadable answer, a failed request, no answer
  before the index's timeout, no owner in the listing, a client not in UTF-8 mode, or an exact
  answer naming the session's server and session from an unknown host name) makes it fail
  `possiblyAttachedHere(unresolved: 1)` with nothing written, opened or sent but the identity
  check, while an attach with the same connections launches; connections of another session or
  server, and one the index's filter leaves out, do not block it, and
  `AttachmentSnapshot.unresolvedConnections(for:)` keeps exactly the stale, non-UTF-8 and
  same-server-and-session unknown or ambiguous entries. Seven
  failures (gone, changed, tmux missing, the check failing, the tab refused, the guard's 64,
  no connection) end the same for an attach and a move here, with the same states and request
  handling. Two move here calls share one launch; a move here waits out an attach in progress
  and then ends `alreadyAttachedHere`, an attach waits out a move here and then focuses it, and
  a move here cancelled while waiting starts nothing. A move here cancelled during its held
  `CreateTab` (on a gated clock) keeps a later attach or move here from revalidating, writing
  or opening anything until it is settled: withdrawn before its helper took the request (the
  later call launches as soon as the run ended), its helper's result or its tab gone for 10 s
  (it launches), its connection (an attach focuses it, a move here ends `alreadyAttachedHere`),
  or nothing within 15 s (`earlierLaunchPending`, the launch still pending); a move here after
  a cancelled attach whose connection appears ends `alreadyAttachedHere` with no `-d` written;
  an attach after a cancelled attach still launches at once. With the confirmation guard
  removed, or with `attach` asking for `-d`, these tests fail (checked by mutation), and the
  unresolved-connection and pending-launch tests fail with the Phase 6b review's fixes
  reverted (checked).
- **Detach other clients** (`DetachOtherClientsTests`, PLAN.md D37): a confirmation naming
  another key (another host entry or session) ends `notConfirmed` with no discovery, iTerm2
  call or wait. One attachment with one other client: the identity check again, the own name
  with tmux's clock, the listing, the check and `detach-client -t '<name>'`, in that order,
  each bound to the connection's owner, nothing else (no tab created, closed, activated or
  buried); a client on a terminal is detached by its terminal's path. The commands hold only
  the single-quoted session id, pid, creation time and name; the listing and the check filter
  the server's clients (no `-t`), the check binding the client's name, pid, creation time and
  session id; no command holds `-a`, `-s`, `;`, `attach-session` or `if-shell`. Names, pids
  and creation times that are not what tmux reports for a client (quotes, spaces, `;`, `,`,
  `#{…}`, `}`, `$`, `\`, control characters, options, leading zeros, non-ASCII, over 255
  bytes) are refused, and a listing naming one detaches nobody. The answers are read
  strictly. A `detach-client` tmux did not confirm (`tmuxCommandFailed`) is not counted: with
  two other clients, the second one's unconfirmed, the call ends
  `checkFailed(.send(.tmuxCommandFailed))` with one detached, and with one, none. Every other
  client is left until it is 10 s old by tmux's clock before its check: 3 s old, 8 s after
  the listing; created when or after tmux's clock was read, the whole 10 s (never more); 10 s
  old, 1 s; 11 s old, none; a caller cancelled during that wait sends no check or detach. Identity changed (another session at the re-check, an answer
  through a client not in UTF-8 mode, the own client missing from the listing, every
  attachment's connection gone) sends no detach; nothing to detach (only the own client
  listed, or the other gone at its check); not attached here (another session's connection
  only, no server, iTerm2 not running); every failure (the index's listing, discovery, an
  invalid SSH destination, an unreadable re-check, the own name, a check, the detach) with
  nothing sent after it. Two attachments here: the first listed is kept, the other's client is
  checked and detached through the kept connection only, 10 s after the snapshot (its tab's
  age); with the first's connection closed before its re-check the second is kept; a caller
  cancelled during that wait sends nothing. Every outcome's and problem's name, and
  `mayHaveSent`. `RecordingITerm2Integration.forwardedCallCount` counts every call.
- **Host list** (`HostListTests`, PLAN.md D19): the onboarding defaults exactly (Saturno,
  Neptuno, Sirio, in order; SSH, empty destination, disabled, no override or profile, unique
  ids, none This Mac); the This Mac switch (the host becomes local and enabled, the previous
  one SSH and disabled with its destination kept, a repeat changes nothing, an unknown id
  changes nothing); enabling an SSH host with an empty destination, a space, a leading `-`, a
  line break, a tab or a control character refused by `setEnabled`, `update` and `add` with
  the list unchanged, while the same values are kept on a disabled host; a local host enabled
  without a destination; two This Mac hosts and repeated ids refused at creation and by every
  change; add, update and remove keeping the order; messages that name no host.
- **Host store** (`HostStoreTests`, private temporary folders only): save and load round trip
  (`saved`, the same list, a schema 1 object with optional keys left out when unset, no
  backup when the store's own file is replaced); the default path computed without creating it;
  under a parent with an inheritable ACL the created folder (which inherits it) ends 0700 and
  `hosts.json` 0600, neither with an ACL, and a folder made 0755 with an allow or deny-only
  ACL is tightened and stripped by the next save; a folder whose ACL cannot be removed
  (immutable) refused with nothing written; a folder that is a link, a file or another
  user's refused by load and save; a missing folder or file gives the defaults as
  `notSavedYet` with nothing created and an existing 0755 folder with an ACL left exactly as
  it was (mode, ACL, entries, bytes). Fifteen invalid files (truncated, empty and binary
  bytes; an array and a number; no version, a string version, no hosts; a bad host, a bad
  mode; schema 2 with an unknown key; schema 0; two This Mac hosts; a repeated id; an enabled
  host without a destination) are each reported with their problem and the defaults, the folder unchanged
  by the load; the next save leaves a byte-identical 0600 backup without ACL named
  `hosts.backup-<UTC stamp>.json` and the save after it no other. Group or other bits, an
  allow or deny-only ACL (also together with loose bits) and a file over 1 MiB are reported
  unsafe and left as they were, then backed up and replaced by a private file (with the ACL
  removal before the swap disabled, the deny-delete case fails with `EACCES`). A link, a
  folder and a FIFO at `hosts.json` are reported without being followed or blocking, and a
  save refuses them with nothing written; another user's file is not trusted; two backups in
  the same second get `-2`; an invalid list, an enabled host without destination and a list
  over 1 MiB are refused before the folder is created; a missing parent folder is
  `directoryMissing`; 16 concurrent saves leave one valid list and no temporary file. Files
  changed between a save's check and its publication (the `beforePublishing` hook, no
  timing): an invalid file and a valid list with other bytes renamed over it, a valid list
  edited in place, and a file created where there was none are each kept byte for byte in a
  0600 backup without ACL (with publication by a plain rename, as before the fix, these
  tests fail: the file is lost); a link or folder that takes the name is kept as it was, its
  target untouched; a file removed in that window is replaced with no backup. A store
  deletes only a displaced file holding the bytes it last loaded or wrote (a store that has
  done neither keeps a backup). With all 100 backup names taken, the save throws
  `displacedFileNotKept` naming the hidden temporary file, which still holds the displaced
  bytes, and the new list is in place.
- **Directory store** (`DirectoryStoreTests`, `DirectoryListsTests`, private temporary folders
  only; PLAN.md D31): a missing folder or file gives empty lists with nothing created; ten
  unusable files (not JSON, an array, no or a string version, `saved` or `recent` of the wrong
  type, schema 2 and 0, open permissions, over 1 MiB) and a link, a folder and an ACL at the
  name give empty lists and a notice, the folder unchanged; unknown keys ignored; invalid
  entries (not a string, empty, NUL, a line break, too long, a non-UUID host, a non-array
  value) dropped and counted while a duplicate is not; the 50 and 8 caps on load; duplicates by
  exact bytes (`~/x` and `/Users/…/x`, composed and decomposed accents stay distinct); round
  trip, schema shape, 0700 and 0600 without ACL under an inheritable ACL; recents newest
  first, moved to the front, capped, per host, cleared; add, existing add (no write), remove,
  move, replace and the cap; Settings' merge (`mergeSaved`: the edits' removals, order and
  additions hold, what was removed since the base stays removed and what was added since
  follows, by bytes, the cap and the rules refusing it with the recents unchanged); lists
  equal only byte for byte (saved, recent, as set members); refused changes writing nothing;
  a change that changes nothing writing nothing; removed hosts pruned at the next write; what
  another program wrote kept;
  a file with entries left out kept as `directories.backup-<stamp>.json` (once); six
  unusable files (unsafe permissions on valid lists, schema 2, not JSON, malformed, an ACL, a
  link) refusing all ten kinds of change with `fileNotUsable(problem)`, the file's bytes,
  mode, inode and modification time and the folder (its 0750 mode, no backup, temporary or
  lock file) unchanged; a link or a folder at the name refused (`fileNotUsable`), and one that
  takes the name after the read refused by the write (`existingFileNotRegular`); a file put at
  the name during the write kept as a backup (`beforePublishing`); two stores on one file,
  the second's change started while the first holds the lock before publishing, ending with
  both changes and no backup; a held `directories.lock` making a change give up (`busy`, the
  file unchanged) and a linked one refused (`lockUnavailable`), the lock file 0600, empty, no
  ACL; lists over 1 MiB refused; the default path beside `hosts.json`; `hosts.json` and its
  backups never touched; the in-memory store's rules.
- **Session switcher shortcut: value and storage** (`GlobalShortcutTests`,
  `PreferencesStoreTests`, private temporary folders only, never `UserDefaults` or
  `~/Library/Preferences`; PLAN.md D32): a typing key without ⌃, ⌥ or ⌘ (none, or ⇧ alone)
  refused, all 20 F-keys alone or with ⇧ usable; ⌘Space, ⌘Tab, ⌘⇧Tab, ⌘⇧3/4/5 and ⌘⌥Esc
  refused, neighbours not; ⌘ with one key and only ⌥ or ⌥⇧ warned about, not refused; key
  codes past 127 refused; modifier names round-trip in ⌃⌥⇧⌘ order. The store: a missing file
  or folder gives no shortcut and creates nothing; record, change and clear round-trip
  (0600 file, 0700 folder, the lock file, schema 1 with the key code and modifier names);
  unchanged changes write nothing; eight unusable files (not JSON, an array, no or a string
  version, schema 2 and 0, open permissions, over 64 KiB) and a link, a folder and an ACL at
  the name give no shortcut and refuse both a record and a clear, the folder byte for byte
  unchanged; a folder that is a link refused; ten unusable `globalShortcut` values (a
  string, no modifiers key, a fractional, too large or negative key code, an unknown or
  non-array modifier, a combination the check refuses, a boolean key code) dropped with the
  file usable, and a recording then keeps the old file as a backup; unknown keys kept on
  write; a file another program wrote during a write kept as a 0600 backup; a held
  `preferences.lock` gives `busy` with nothing written; the in-memory store.
- **SSH config suggestions** (`SSHConfigSuggestionsTests`, a synthetic home per test, never
  the user's `~/.ssh`): `Host` lines with several patterns; every keyword form (any case,
  `Host=a`, `Host = a`, `Host =a`, `Host= a`, tabs, indentation; `Hostname` and
  `HostKeyAlias` ignored); quotes and escapes (single, double, inside a word, `\"`, a quoted
  space left out, an unterminated quote skipping its line); comment lines and a `#` starting
  a word, while `#` inside a word or quotes is kept; `*`, `?`, `!` and a leading `-` left out;
  `Include` with a glob relative to `~/.ssh/` in lexical order at its place, `~/`, an absolute
  path, several paths per line and `Include=`; a home path holding `[`, `*` and `?` matched
  literally; a chain of 20 nested includes read down to depth 16; a file including itself,
  two files including each other and a link to a file already read; missing files, empty
  globs, an unreadable file, a folder and a FIFO skipped; includes inside `Match` and `Host`
  blocks; the size cap (a file at the cap read, one byte over skipped); de-duplication in
  first-seen order across files; no `.ssh` or no config; CRLF, trailing spaces and form
  feeds; `~user` paths not expanded; every file's bytes, mode and mtime unchanged afterwards.
- **Refresh engine** (`RefreshCoordinatorTests`, `RefreshScheduleTests`,
  `RefreshSnapshotTests`, `RefreshPopoverCloseTests`; PLAN.md D20): a scripted prober whose calls wait until the test
  answers them (optionally ignoring cancellation, like a probe that finished as it was
  cancelled), a fake attachment index, and `GatedAttachClock`, whose sleeps end only when the
  test advances virtual time, so every timer fires exactly when the test says and no test
  orders steps by real time (waits only poll for a state the engine reaches by itself). One
  test each: a hung host not delaying three others (one queued behind the limit); overlapping
  requests making exactly one follow-up after the running attempt; the limit of 3 with
  first-come queueing and a request joining a queued attempt; a probe retired by an edit
  keeping its host's single flight and its slot (hosts queued behind it going first, the host
  starting by itself once the probe ends); a late result from before a sleep, answered after
  waking, discarded and never published, the post-wake attempt waiting for it and then
  applied; a destination edit retiring the attempt in flight (its result discarded, the new
  attempt under revision 2 starting once it ended); a removed host's result dropped and the
  host re-added under a new revision; a rename keeping the attempt in flight; background backoff
  30 s, 1 min, 2 min, 5 min, 15 min, 15 min (nothing 1 s before each step), reset to 5 min by
  a success and to 30 s by the next failure; "Retry" and "Refresh" bypassing backoff with
  the failure still counted; the visible 15 s cadence ignoring backoff and the background
  step returning on close; the healthy cadence (5 min, at once on opening, 15 s, 5 min after
  closing); stale marking after a failure that follows a success (sessions, `lastSuccess`
  kept, `lastAttempt` moved, failure classified) and live again after the next success; a
  failure with no success before and `noServer`; the same session name, id and server on two
  hosts staying two entries; sleep cancelling the probe in flight and every timer before it
  returns, nothing running in an hour of virtual sleep or on a network change, and every host
  refreshed exactly 5 s after waking (not at 4.999 s); sleep ending a
  `refreshOnce(includeAttachments: true)` round, which then starts no attachment check; a
  network change refreshing only the
  failing host; the attachment merge (only the mapped session marked, the index given every
  host's node name and servers), no attachment check in the background, and D16's failure
  policy (`apiDisabled` clearing an earlier check's attachments, `notRunning` meaning nothing
  attached); `refreshOnce` scheduling nothing; This Mac discovered by `/bin/sh` and only the
  SSH host by `/usr/bin/ssh`; the sleep/wake adapter keeping order, a `stop()` run inside its
  `start()` leaving nothing observed, and the path filter;
  `stop()` cancelling a hung probe, a timer and a hung attachment check, leaving no task,
  sleeper or running call and finishing the update stream. Closing the popover, with the
  engine over the real `AttachmentIndex` and `ITerm2APIClient` (gated cookie provider, fake
  connector and byte stream): closed while the check waits for the cookie, nothing connects
  or is sent once the cookie arrives and nothing is published; closed after one connection
  answered its identity question while the other's ownership listing is pending, that
  connection is never asked even when the listing's answer comes (the next frame is the
  test's own); reopened while the cancelled check (a held fake index that ignores
  cancellation) has not ended, a fresh check runs at once and the stale answer is discarded.
  Without the cancellation on close all three fail; without the client's checks before the
  cookie and the connection, the cookie one does. With the real
  `PosixSpawnProcessRunner` and `DiscoveryProbe` against the fake tmux (`hang-pids`: a
  `sleep 30` child), both `stop()` and `systemWillSleep()` return only once the probe's
  process group has no live member, and every pid is gone soon after. Removing the stale
  result guards, the follow-up, the limit, the wait in `systemWillSleep()`, the per-host guard
  over retired probes, the `refreshOnce` work epoch, the adapter's start generation or the
  backoff steps makes these tests fail.
- **App model and popover** (`Tests/MuxFinderUITests/`: `PopoverContentTests`,
  `PopoverStyleTests`, `AppModelKeyboardTests`, `AppModelEngineTests`; PLAN.md D22). Content,
  from the preview fixtures and hand-built snapshots: every host outcome to its status label
  (SSH and This Mac, every unreachable reason, both host-key problems, `probeError`), a
  refresh keeping the last label, the exact label texts and one explanation per failure;
  every status's tone ("Unreachable" alone muted, the four the user can act on "attention")
  and only an unreachable host's section muted; each row's attach state (open here, attached
  elsewhere, detached, stale; "open here" first even for a stale row) with only the first two
  reading as attached. Look (`PopoverStyleTests`, colors resolved with `Color.resolve(in:)`
  in light and dark environments and composited in sRGB): the "Open in iTerm2 here" badge's
  text at least 4.5:1 (WCAG 2) against its fill over an unselected, a selected and a hovered
  row, the old accent-on-accent badge shown to fail the same measure, the selection a
  neutral gray and neither the badge's fill nor its text the accent color, every fill
  opaque, no host status red and only the muted tone's dot hollow, four distinct attach-state
  symbols and colors, and the footer's buttons at least three times as far apart as an icon
  from its title. Relative times at every
  boundary ("just now" under a minute and for future dates, then minutes, hours, days) and
  the "Last checked …" / "Last seen … · not live" sentences; counts ("4 windows · 1 client",
  "1 window · Detached"); stale marking (an unreachable host's sessions kept, all stale, no
  live counts, caption from the last success); the badge only from the attachment index (a
  session with clients but no connection here has none, no row claims activity or
  idleness), and a failed iTerm2 check showing a notice and no badge; accessibility labels
  and values of rows and headers; search by session name across hosts, by host name (all
  its sessions), ignoring case, diacritics and spaces, and no match; empty and never-checked
  hosts, "Not reached yet", "Loading hosts…", "No hosts turned on", the host-list notices;
  `AttachState` to row activity; the fixtures covering every status, activity, placeholder,
  notice, badge, stale row, selection (one on a row with the badge), attach state and empty
  host, and an unreachable host next to an attention one, with synthetic data only. Model over
  fixtures: ↑/↓ through the listed rows across hosts, clamped at the ends, restarting when
  the search hid the selection; Return and clicks selecting without opening anything (a
  fixture builds no attach coordinator); ⌘F, ⌘N, ⌘, and Esc; a fixture model starting
  nothing; key-press mapping with and without modifiers; the command-line flags, `--selftest`
  and its usage errors included. Model over a real `RefreshCoordinator` with fake
  discovery and attachment index: start loading the list and turning hosts live; the
  onboarding defaults discovering nothing; invalid and unreadable host lists; attachment
  checks only while the popover is visible (none in the background or after closing, the
  badge appearing after opening); an open before start applied after it, repeats ignored;
  "Refresh" asking every host, "Retry" one, a session's Retry clearing its failure; sleep and
  wake through `RefreshSystemEvents` on a private notification center; quit asking to
  terminate and shutdown stopping the engine with no task left and no iTerm2 request; a
  popover opening still queued when shutdown begins dropped (no attempt, no check started);
  a shutdown during loading building no engine. The iTerm2 cookie, through the real
  `ITerm2APIClient` (a counting cookie provider that refuses, a fake running check, a regular
  file standing in for the socket, so nothing connects): no cookie and no running check at
  start or with the popover closed (results applied, no attachment check started), a cookie
  request once the popover opens while iTerm2 runs, and none (only the running check, never a
  launch) while it does not; and, with a gated cookie provider and a counting connector,
  closing the popover while the cookie request is pending: nothing connects once the cookie
  arrives and nothing is published. Making `start()` open the popover in the engine makes the
  first two cookie tests fail; undoing the cancellation on close fails the third, and handing
  queued requests to the engine during shutdown fails the shutdown test.
- **Popover placement** (`Tests/MuxFinderUITests/PopoverPlacementTests`; PLAN.md Phase I-1),
  pure values, no `NSScreen` or window: `PopoverPlacement.frame(contentSize:anchor:screen:)`
  centered below the icon (top edge at the menu bar's bottom, the middle on the icon's);
  clamped 8 pt inside the visible frame at the left and right edges and beside a Dock at the
  left; a second display left of and above the main one (negative coordinates, its own menu
  bar's bottom and edges); an auto-hiding menu bar (the system thickness, or a taller camera
  housing safe area; a menu bar that reserves room is measured, never guessed); a 2x and a
  1x display (the same size in points, the left edge on half points at 2x and whole points
  at 1x); content wider or taller than the display (narrowed, or shortened keeping its top);
  the room the content is limited to (`availableHeight(on:)`: to 8 pt above the visible
  frame's bottom, a Dock at the bottom, an auto-hiding menu bar, never negative);
  a click point and the icon's rectangle with the same middle; `screenIndex(for:in:)` for an
  anchor on each display, a pointer on the main display's top row (`y == frame.maxY`, also
  the bottom of a display above), points on no display (the nearest) and no displays. The
  `--report-popover-placement` flag: no profile rewrite, a usage error with every other mode,
  and an environment loading an empty in-memory list with no Settings seams or attach
  coordinator. The diagnostic's window identification
  (`Tests/MuxFinderUITests/PopoverWindowIdentificationTests`): a replica status-bar window
  (level 25, no button, newly visible, also under a key-value observing subclass) is never the
  popover, nor the real item's window with its button, nor a status-bar window claiming the
  live popover; a newly visible normal-level window is the fallback candidate, one at or above
  level 25 is not without the live popover view, hidden windows and windows visible before the
  click are not; the window holding the live popover view wins at any level;
  `LivePopoverLookup` finds the tracking view anywhere under a view. Its output
  (`Tests/MuxFinderUITests/NonblockingLineWriterTests`): with a full blocking pipe (a stalled
  standard output) 200 lines return at once from another thread, at most the capacity waits,
  190 are dropped and counted and none is written until the pipe is read; with a full
  nonblocking pipe every line is dropped and counted at once (`EAGAIN`), and once read a line
  arrives whole; a line longer than the capacity is dropped. With the old predicate (visible
  now, not before the click, no button) the replica, fallback-level and live-popover tests
  fail; with the old synchronous write the stalled-pipe test fails ("write(_:) blocked the
  caller").
- **Popover panel** (PLAN.md D30). `Tests/MuxFinderUITests/PopoverAnchoringTests`, pure
  values over this Mac's two displays as Phase I-1a recorded them: a mouse press on the button
  (anywhere in its column of the menu bar, top row and bottom edge included) anchors at the
  button's rectangle, one beside it or on the other display at the press, one in the button's
  column on a display stacked above is not on the button; with no mouse event the button's
  rectangle, else the pointer; the replica windows' placeholder frames (and an empty or
  off-menu-bar rectangle) are never usable, so never anchors; `screenIndex(holding:in:)` has no
  nearest-display fallback; the toggle rules (a press while open closes, or moves on another
  display; the classic toggle bug in both orders, the same press count within 0.5 s and 40 pt
  only, matched once, a close with no mouse button held never matched; a separate press
  0.15 s and 20 pt after a neighboring item's, in either order, never matched); the after-fix
  check (centered passes, a
  middle 3 pt off or a top 1.5 pt off fails, a clamped popover passes). `PopoverControllerTests`
  over a fake panel, button and system: a press opens below the icon (frame, highlight,
  visible, the search field's focus asked) and a second closes; `performClick(_:)` anchors at
  the button, a placeholder button rectangle at the pointer; a press on the other display opens
  there, and while open moves there with no visibility change; Esc, a press outside, an app
  switch, resigning key and a display change each close once and a press reopens; the press
  that closed it from outside does not reopen it (and opens it on the other display); the
  outside close for the action's own press is ignored after opening and after moving; with
  the popover open, a press on a neighboring menu bar item and then on the icon 0.2 s later
  and 20 pt away opens it again, and a press on the icon and then on a neighboring item 0.2 s
  later closes it; occlusion hides and shows it, never while closed; a content size change
  places it again while open only; the content is limited to the anchor's display's room
  before its size is read (on opening, moving and a size change), so taller content fills the
  room exactly. `PopoverHeightLimitTests`, in hosting views never put in a window, over the
  overview fixture (501 pt natural): offered 120 pt less, `PopoverView` lays itself out at the
  offer (its host list shrinks; the search field, dividers and footer keep their 82 pt), and
  at its natural height when offered more; the panel's root is the natural height with no
  limit or a roomy one and exactly the limit otherwise, also when the limit is set on the
  existing root view. With the press count left out of the match the four rapid-press tests
  fail; with the old fixed list height, the root's `fixedSize()` and no limit from the
  controller the shrink, root and limit tests fail. `MenuBarIconTests.statusItemImage`: the bundle's template PNGs, else the
  SF Symbol, a template either way.
- **Settings window** (`Tests/MuxFinderUITests/`: `HostDraftValidationTests`,
  `SettingsHostsTests`, `SettingsGeneralTests`; PLAN.md D23). Over fakes for the store,
  discovery, profile list, login item, pasteboard and URL opening, plus a real `HostStore` in a
  private temporary folder; nothing touches the real `hosts.json`, a login item, iTerm2 or
  System Settings. Validation: each name rule (required, 50 characters, control characters,
  another host's name ignoring case), each destination rule (required while on, spaces,
  control characters, leading "-", ignored for This Mac), the tmux path and profile rules, and
  what a draft stores (trimmed, empty as none). Editing: an SSH host without a valid
  destination is refused when turned on; choosing This Mac turns it on and saving demotes the
  previous This Mac (SSH, off, destination kept); adding a host (as This Mac) and cancelling
  one; removal and discarding unsaved changes each asked first; a store error shown with the
  list and draft kept. Saving through `HostStore` in a private folder: loading the examples
  creates nothing, a save writes the file a fresh store loads back. An unusable file: shown
  with its problem, no edit, save, add or removal possible and its bytes unchanged until
  "Replace" is confirmed; then a save puts a new list in place and the old bytes are kept in a
  `hosts.backup-*.json`. An unreadable folder disables editing until "Try again" works. Detect
  probes without the tmux path and fills it in, or reports "not found" or the popover's
  failure wording; Test connection shows the popover's label and explanation for every
  classified status, This Mac included; a probe whose fields changed (or whose window closed)
  is dropped, an incomplete draft runs none. The profile picker over listed profiles (with a
  warning for an unknown name) and its free-text fallback when iTerm2 is not running or
  listing fails (Automation fix-it); the real `ITerm2ProfileSource` over the fake iTerm2 asks
  only `isRunning()` while iTerm2 is not running and never `ensureRunning()`. Launch at login:
  every `SMAppService.Status` mapped, the toggle's round trip on a fake (register,
  unregister, `requiresApproval` with its Login Items fix-it, `notFound`, an error shown and
  the status read again). "Copy diagnostics": the exact header lines, hosts by name and id,
  status kinds, the log with host names, the closing note, and none of a planted destination,
  tmux path, profile name, session name, probe message, node name or foreign host id. Fix-its:
  selection for every relevant iTerm2 error and attach failure (through `notSent`), the
  Automation URL, the explanation, and each performed through its seam, in Settings and the
  popover. The app model: ⌘, and the footer present the Settings window; a list saved there
  reaches the engine and its host turns live. The Settings fixtures cover every required state
  with synthetic data, and the new flags parse.
- **SSH setup, launch side** (`Tests/MuxFinderCoreTests/SSHSetupTests.swift`, PLAN.md D24).
  The request kind: an attach request is still encoded without `kind`; request files as
  earlier builds wrote them (no `kind`, a local or ssh host with its own nested `kind`) are
  taken as the same attach request, `"kind":"attach"` too; an unknown kind, a number, or
  `sshSetup` with an attach body is unreadable; an ssh setup request has exactly its six keys
  and round-trips. Each typed take refuses the other kind (`requestKindMismatch`, 72) and the
  file is gone. Destinations that are empty, start with `-` (`-oProxyCommand=…`, `-`, `--`)
  or hold whitespace or control characters: the request is not well formed, the store writes
  no file and refuses one written by hand, and no argv is built. The argv is exactly
  `["--", <destination>]` after `/usr/bin/ssh`; the tab's command line is `<helper> ssh-setup
  <uuid>`. ssh's outcome: 0, 1 and 130 are successes, 255 is classified from its standard
  error (auth, host key, other), a signal is `childSignaled`. The helper over a fake child
  runner and terminal: `ssh-setup <id>` runs only `/usr/bin/ssh -- <destination>` (no check,
  standard error relayed, cleaned environment), writes the result, logs no destination and
  holds 10 s; a 255 is explained with the ssh setup wording, waited for and held; every exit
  path (success, ssh failure, spawn failure, expired, missing, the other kind) holds, and only
  a SIGHUP skips the hold; a request of the other kind in either mode is refused (72) with
  nothing run; a file with an option-like destination is refused before any process; bad
  `ssh-setup` usage consumes nothing; the test-mode digest records the ssh child. The
  launcher over a fake iTerm2 and a real store: one ssh setup request, `ensureRunning()`, then
  one `CreateTab` in a new window with the host's profile, `<helper> ssh-setup <id>` and Close
  Sessions On End; This Mac, invalid destinations, a missing helper and a cancelled caller
  write and contact nothing; iTerm2 not starting, a refused `CreateTab` and a tab without a
  session id withdraw the request. The real binary in a pseudo-terminal (`SSHSetupTerminalTests`):
  `ssh-setup` given an attach request exits 72 only after its 3 s minimum lifetime even with
  Return pressed at once, starts nothing and shows the ssh setup wording.
- **Onboarding and the action in the UI** (`Tests/MuxFinderUITests/OnboardingTests.swift`,
  PLAN.md D24). The examples (D19's defaults) and the fixed text (four expectations of one
  line, the scope line, both iTerm2 requirements); only `notSavedYet` prepares the model, and
  the app presents the window only then (not for saved, unusable or unreadable lists), with no
  save, no ssh tab and no discovery. Editing: This Mac exclusive with D19's switch and "none";
  the name and destination rules and the refused "Turned on"; a draft with an error never
  saved. Saving through a real `HostStore` in a private folder: every edit reads back, the app
  gets the list and the window closes; a file saved meanwhile is left byte for byte with no
  backup, the save refused and editing stopped; closing or "Not now" creates no folder or
  file. A list saved in onboarding reaches the engine. The action over a fake opener: offered
  only for a valid SSH destination, sent once while opening, the opened and failed lines (with
  the API fix-it), forgotten on a destination change, cancelled by closing the window and by
  quitting; in the popover only for sign-in and host key problems on SSH hosts (Retry forgets
  the line); in Settings under the destination and after a test that needed a sign-in or had
  a host key problem, never for This Mac. The onboarding fixtures and `--preview-gallery
  onboarding`.
- **Session actions** (`Tests/MuxFinderUITests/AttachFlowTests.swift`: `AttachFlowTests`,
  `NewSessionSheetTests`, `FailureMessageTests`; the core's `ShowLaunchTabTests`; PLAN.md
  D25). The real `AppModel`, engine and `AttachCoordinator`
  over `SimulatedITerm2` (launch tabs and tmux connections as state: a tab's connection shows
  the session of the request just written, identity answers, `detach-client` closing it, every
  command, activation and `close` counted), fake discovery, an in-memory launch store and a
  virtual clock. A burst of five clicks gives one `CreateTab` and one result, "Confirmed" and
  Detach offered; Return opens the selection; a session already open here is focused with no
  tab and no request; while the identity question is held the row shows "Waiting for iTerm2…"
  and never "Confirmed", which comes after the answer; a connection reaching another session
  is never confirmed (a "changed" banner, the host refreshed); a remote tab still waiting shows
  "Still connecting — check the iTerm2 tab", and "Show tab" activates that launch tab by its
  session id and nothing else (a failure without a tab offers none; the coordinator refuses
  any id it did not open and sends nothing); Move here asked, cancelled or dismissed with Esc
  runs nothing, and only "Move here" (or Return) runs a move whose request asks for `-d`; a
  move of a session open here offers "Bring forward" and "Detach from this Mac"; Detach is not
  offered or run before an attach, is offered for the index's badge, and after a confirmed
  attach sends one `detach-client`, closes no tab and says the session keeps running; a failure
  shows its message and recoveries and "Try again" repeats the attach; a missing helper is
  explained with nothing to retry; vanished and changed sessions get their banners (dismissed
  on request); opening the popover clears results, not failures; panels take Return and Esc
  and ignore the arrows, ⌘F and ⌘N. A focus that iTerm2 refused, or that found no tab, never
  reads "Already open here — brought its tab forward": its own problem with "Try again", the
  attachment kept, and the retry focusing it. Quitting while an attach waits for iTerm2's
  answer to its `CreateTab` (held by the fake) stops Settings' probe and the engine at once,
  returns after its (shortened) budget reporting the open still running, and that attach
  withdraws its request once iTerm2 answers. New session (its window, PLAN.md D34): This Mac
  by default, an empty or invalid name or directory reported inline with no creation, a valid
  name created (trimmed, directory kept, the user's shell) and attached with the window
  closed; for a remote
  host whose tab still waits, the new session's row shows "Still connecting — check the iTerm2
  tab" before the attach ended, "Show tab" activates that launch tab, a click starts nothing
  and quitting cancels it; a collision offering "Open existing", which resolves the name in a
  fresh listing of the host (the coordinator's discovery, while the engine's list is still the
  old one): the session that has the name now is opened, not the listed one that was renamed;
  with no session of that name any more, or a host that cannot be listed, the window says so
  and nothing is written or launched; another failure kept in the window until a field
  changes.
  Every failure path's message (each `AttachFailure`, each detach outcome, the Show tab notes,
  the missing helper, both focuses that did not bring the tab forward, the two "Open existing"
  outcomes that open nothing) is pairwise distinct and a sentence; every attach failure offers
  a recovery; the attach fixtures cover every state with synthetic data. In the core,
  `CreateAndAttachTests` checks that `onCreated` comes once, before the first state, and never
  for a failed creation, and that `currentSession(named:on:)` matches the exact name in a fresh
  listing (another case, a renamed session or no server is `sessionGone`).
- **Detach other clients in the popover** (`Tests/MuxFinderUITests/DetachOtherClientsUITests.swift`,
  PLAN.md D37, Phase I-11b), over the same harness, the engine's badge from a fake index and the
  fake iTerm2 answering the core's commands for a connection of the user's (its own client
  name with tmux's clock, the session's client listing with other clients as state, each
  check, `detach-client -t <name>`, clients that leave after the listing, a detach that throws).
  The offer rule over `PopoverContent`: shown for a live row open here with 2 clients (and for
  one only muxFinder recorded), with 3 clients and 2 attachments here; hidden with 1 client,
  with 2 clients and 2 attachments here, not open here, on a stale row, on an unreachable
  host's row and before the first check; the badge's "also attached elsewhere" and VoiceOver's
  value only while offered. In the model: the confirmation's session and counts (1 other
  client; "including 1 in this Mac's iTerm2"), its texts and buttons; 1 client shows nothing
  and contacts nothing; shown but disabled (`isPending`) and refused while a Detach from this
  Mac waits; Cancel, Esc and a confirm without a dialog run nothing (no coordinator, no
  request), the arrows, ⌘F and ⌘N do nothing, Return confirms, VoiceOver hears each dialog's
  title (Move here's too); with two sessions asked for in turn only the second one's client is
  detached, through its own connection; detached (one other gone at its check: "(1 had already
  left)"), nothing to detach (informational), not attached here (the record forgotten, nothing
  sent), tmux refusing a detach ("Refresh" only), a failed send ("Try again" shows the dialog
  again, and "Refresh"; seen from the session switcher its row offers "Refresh" only, as a
  failed move here's offers "Open Settings" only, and a retry there keeps the failure, sets no
  dialog and contacts nothing, while the popover's "Try again" shows the dialog and nothing
  runs until it is confirmed), each followed by a refresh of the host, `notConfirmed` and
  `cancelled` by none; while the call waits for a young client the row says "Detaching other
  clients…", a click and the item are ignored, and quitting cancels it (`cancelled` within the
  budget, no detach sent, nothing shown). Every outcome's line is pairwise distinct (and its
  failures from every other message, `FailureMessageTests`), with the recoveries and D23's
  fix-its listed in PLAN.md D37; the galleries' fixtures show both dialogs, the pending row,
  every result and the hint.
- **Recent directories** (`Tests/MuxFinderUITests/DirectoryRecordingTests.swift`, PLAN.md
  D31), over the same harness with an in-memory store: a created session records its directory
  as checked, newest first, for its host; an attach that fails after the creation still
  records; an empty field, both collisions, a failed creation and every `mayHaveCreated`
  failure never call the store; a store whose writes fail leaves the creation confirmed and
  logs `recent directory not recorded: <code>` with no directory; a real store over an
  unusable file in a private folder (valid lists, mode 0644) logs `fileNotUsable.unsafe
  .permissionsTooOpen` and leaves the file's bytes, mode, modification time and inode and the
  folder as they were, the creation confirmed; hosts removed from the list
  (in Settings, or never in it) lose their recents at the next write, and an unsaved list
  prunes nothing; the app's environment uses the real `directories.json`, the self-tests an
  in-memory store (and `new-session-local` passes with it empty), the placement diagnostic
  and every preview fixture none.
- **New session's directory list** (`Tests/MuxFinderUITests/DirectoryPickerTests.swift`,
  PLAN.md D31). The content as a pure value: per host, "Recent" (that host's), "Saved" (the
  shared list) and "Sessions on <host>" in that order; session folders distinct by exact
  string (two spellings of an accented name stay two), sorted as Finder sorts names, at most
  10, a folder that breaks the entry rules or is missing skipped; empty sections hidden;
  nothing to pick (still "Save this directory" for a typed value); "Save this directory" off
  for an empty field, a line break, a value saved already (byte for byte), a full list, an
  unusable file, an unreadable folder or no store; "Clear recent directories on <host>" only
  with recents and a usable store; the keyboard's items and moves. Over fixtures and the
  attach harness: picking fills the field, which the draft checks and carries unchanged into
  the request, and closes the list (a row not listed, or a busy sheet, picks nothing; a pick
  after a collision returns to editing); a host change keeps the field and updates the list;
  ⌥↓ opens on the first row, ↑/↓ move and stop at the ends without moving the session
  selection, Return picks, Esc closes the list and then the New session window, ⌘N and ⌘, as
  the window has them and ⌘F and ⌘R left to the focused view (PLAN.md D34; these keys go
  through `handleNewSessionKey(_:)` since D34); ⌥↓ in the host list and in Move here is
  `ignored` (left to the focused view); the
  key mapping (⌥↓ only, with the arrows' own flags); Return with the list open and nothing
  highlighted, or closed, creates; editing the field drops the highlight, so Return then
  creates from the field, and a row highlighted with ↓ after the edit is what Return picks;
  two spellings of one accented name (composed and decomposed) are two rows that hash apart,
  the keys pass from one to the other and on to the next entry and Return fills the field
  with that row's bytes, and lists that differ only in a spelling reach the view (the model
  notifies). Through an in-memory store: the lists load when New
  session opens, "Save this directory" and "Clear recent directories" change only what they
  name (hosts no longer listed pruned); a failing store's refusal shows in the list and is
  logged as `directory list: addSaved not done: <code>` with no directory; a real store over
  an unusable file (mode 0644, private folder) shows its notice, offers neither action and
  leaves the file's bytes and mode; a Settings save reaches the list and a save from the list
  reaches Settings. The gallery fixtures cover the open list, nothing to pick, a saved value
  and an unusable file, with synthetic paths. Five of these tests had their field adjusted in
  Phase I-7, since the field now filters the list (see *Phase I-7*).
- **The directory list's filter** (`Tests/MuxFinderUITests/DirectoryFilterTests.swift`,
  PLAN.md D31, Phase I-7). The content as a pure value: an empty field (or only spaces and
  line breaks) filters nothing; a query keeps each section's matching entries in order and
  hides a section left empty, surrounding spaces trimmed; case and diacritics (composed or
  decomposed) ignored; with entries all hidden, "No matching directories" (`noMatches`) and
  the actions that are on as the only items, or none; with no entry at all "Nothing to pick
  yet" whatever the field holds; an entry equal to the field byte for byte always shown, both
  spellings of an accented name too; the actions never filtered (Clear on for recents the
  filter hides, Save's rules from the typed text); the `~` rule on This Mac (`~/proj` finds
  `/Users/me/projects-old`, `/Users/me/pr` finds `~/projects`, `~bob` matched as typed and
  never spelled out, `/Users/meadow` not in `/Users/me`, the home folder's trailing slash and
  a root or empty home ignored) and not on an SSH host or without a home; the field's hint.
  Over fixtures and the attach harness: typing that matches opens the list as the typing's
  with no highlight, typing that matches nothing opens nothing; no match closes a list the
  typing opened, not one the button or ⌥↓ opened (which shows "No matching directories" and
  the actions); clearing the field closes a typing list and opens nothing, a requested list
  showing every entry again; Esc keeps the text and the next edit reopens; ↓ and ⌥↓ highlight
  the first match, ↑/↓ visit only the rows shown and stop at the ends; Return with nothing
  highlighted creates from the field (the request carries the typed text); a pick by Return
  or click fills the field, closes the list and announces nothing; a host change re-filters,
  keeps the field and neither opens nor closes the list; a busy draft, no host or an unlisted
  one opens nothing; the announcements in order (the count when the list opens or its rows
  change, "No matching directories" when a typing list closes or a requested one empties,
  the whole count when a requested list is cleared, nothing otherwise); the app's
  environment injects `NSHomeDirectory()` and the announcer, fixtures the synthetic home and
  none, tests neither; the gallery states, with synthetic paths.
- **Settings' Directories tab** (`Tests/MuxFinderUITests/SettingsDirectoriesTests.swift`,
  PLAN.md D31, D23): the window's opening loads the saved list; "Add" is checked inline (a
  line break, a duplicate by exact string, the 50-entry cap) and appends the value as typed;
  move up and down never past an end, remove, all on the working copy only (the store
  unchanged); Save writes the edits in one change with the recents untouched, says
  "Saved.", tells the app and logs the count only; Revert brings back the list as saved;
  Save merges (`mergeSaved`): with an entry removed in the tab and not saved, a "Save this
  directory", a clear and a recording from New session are kept (the store, the tab and New
  session's list then show the merged list and the new recent), and over two real stores on
  one private file another muxFinder's addition stays and its removal stays removed; a
  failing store keeps the edits, says why and logs the code only; a real store over an
  unusable file shows its notice with "Try again", offers no edit and leaves the file as it is,
  and loads it once fixed; a file with an entry left out is editable, its notice counts the
  entry, and the save keeps it as a backup; changes from New session follow while there are
  no unsaved edits; the app gives the tab and New session's list one store instance; the
  fixtures load and save nothing.
- **Session switcher shortcut: label, registrar and recorder**
  (`Tests/MuxFinderUITests/GlobalShortcutModelTests.swift`, `GlobalShortcutAppTests.swift`
  over `FakeHotkeyRegistrar`, a Spanish-like `StaticKeyboardLayout` and in-memory or scripted
  stores; PLAN.md D32): the label prints Ñ, Ç, the grave accent and + from the fake layout
  after ⌃⌥⇧⌘ in macOS order, fixed names for F-keys, Space, Return, Tab, Delete, Esc and the
  arrows, the key code for a key that types nothing, and a spoken form; the real layout
  reads a letter (read-only); event flags map to the four modifiers. The model: a saved
  shortcut registered at launch and its press reaching `onPress`, nothing registered without
  one; a change unregisters the old one while recording and registers and saves the new one;
  "Clear" and Delete unregister and save none; quitting unregisters and stops listening; a
  taken shortcut at launch and while recording shows "Another app uses this shortcut. Choose
  another." (the recorder keeps listening, Esc brings the saved one back); while recording
  the hotkey is unregistered so a press never reaches `onPress`; refusals keep listening;
  ⌘K and ⌥J ask first ("Use it anyway", Return, "Choose another"); a failed save or clear
  brings the previous shortcut back with the reason; an unusable file or folder leaves the
  hotkey off, the recorder disabled, with "Try again"; a save or clear that finds the file
  unusable (a real `PreferencesStore` on a private `mkdtemp` folder) leaves it byte for byte
  as it is and the hotkey off, and "Try again" registers what the fixed file holds; a failed
  unregistration keeps the hotkey registered (recording does not start, "Clear" saves
  nothing, a failed save keeps the new shortcut), says so and names the kind in
  diagnostics, and the next attempt unregisters it; `CarbonHotkeyRegistrar` over fake Carbon
  calls keeps a registration whose unregistration fails, and `unregisterAll()` keeps and
  counts it and keeps the handler until nothing is registered; inert and fixture models do
  nothing; the log holds kinds only. In the app: `AppModel.start()` registers and the press
  reaches `globalShortcutPressed()`, which toggles the session switcher through
  `toggleSwitcher`, and `shutdown()` unregisters; with no shortcut environment nothing is read
  or registered; Settings' window closing or losing the focus, or another tab, stops
  recording; `SwitcherController`'s toggle opens the switcher on the focused display and
  closes it; only normal mode gets a shortcut
  (`registersGlobalShortcut`), `--report-hotkey-registration` with any other mode is a usage
  error; the app's environment has `preferences.json`, the Carbon registrar and the system
  layout, the placement diagnostic and the self-tests none; the gallery covers the recorder
  empty, recording with a refusal, warning, set and taken; "Copy diagnostics" names the
  state by kind.
- **Session switcher** (`Tests/MuxFinderUITests/SwitcherContentTests.swift`,
  `SwitcherControllerTests.swift`, `SwitcherModelTests.swift`; PLAN.md D32, D22). The content,
  a pure value: stale sessions left out (an unreachable host lists nothing), host order then
  session order with the popover's rows, the popover's filter (a host name keeps all its
  sessions; case, diacritics and spaces ignored), the New session row ("New session…", "New
  session “<name>”…" with the trimmed valid name when no live session has exactly it, none
  for an existing, invalid or empty name), the selection kept on the same session across an
  update and the first row otherwise, ↑/↓ stopping at the ends, "No live sessions." and "No
  session matches …", the no-hosts and loading placeholders (no New session row), muted host
  lines with their tones, pinned rows (a carried failure first and not repeated, a stale one
  too, an action's session not listed made from its target). The controller over a fake
  panel and system: the toggle opens it centered on the focused display, the top 18 % of the
  visible height down, reporting visible before the panel shows and limiting the content to
  the room below; each close reason; occlusion; a size change keeping the top; the placement's
  narrowing and shortening and the display choice (the focused window's area, `NSScreen.main`,
  the pointer, the first). In the app (real model, engine and coordinator over
  `SimulatedITerm2`): ↑/↓ without wrapping and typing selecting the first row; Return opening
  the selected session and its success closing the switcher; Return on New session and ⌘N
  opening the New session window with the filter's name for This Mac and asking the switcher
  to close (PLAN.md D34); in the window Esc closing the directory list, then the window;
  Return in the window creating from the switcher's draft, the created session's attach
  closing the switcher on success while it still shows; ⌘R, ⌘, and ⌘F; a failure while it
  shows staying on its row; a failure after it closed (the launch held, then refused) on the
  popover row and pinned and selected at the next opening, once; a creation failure after the
  window was closed bringing the window back, not key, the switcher's opening and closing
  leaving it; the popover, then the switcher, then both, then neither giving one
  opened and one closed to the engine with each opening asking the other to close; both real
  controllers over fakes swapping; the fake registrar's press toggling the switcher with an
  empty, focused search field.
- **App shell and main menu** (`Tests/MuxFinderUITests/MainMenuTests.swift`,
  `AppShellReportTests.swift`; PLAN.md D33). The hand-built main menu: the app menu, Edit and
  Window in that order, the Services and Window menus handed to AppKit; every item's title, key
  equivalent, modifier mask and action (Quit ⌘Q `terminate:`, Redo ⇧⌘Z, Paste and match style
  ⌥⇧⌘V `pasteAsPlainText:`, Close ⌘W `performClose:`, Minimize ⌘M and the rest); every command
  to the first responder, no key equivalent twice, no Settings item and no ⌘,; Close enabled
  for `SettingsWindow` and `NewSessionPanel` (PLAN.md D34) and disabled for
  `PopoverPanelWindow` (none shown). The app shell
  check's listing: the status item lines as before, then the other windows (title, class,
  visibility, level, with a visible count), the launch's Apple event and the main menu; at
  most 32 windows and 80 menu items, the rest counted; titles cut to 80 characters, control
  characters replaced, quotes escaped; key labels (`⇧⌘+z`, `⌃⌘+U+0020`); the real menu's
  description.
- **New session's Tab order** (`Tests/MuxFinderUITests/NewSessionTabOrderTests.swift`;
  PLAN.md D30, D31, D34, Phase I-6). Both panels' window class and the New session window's
  (`NewSessionPanel`) recalculate their key view loop; in the real New session window (never
  shown) over the popover's and the switcher's fixtures, its loop computed first and the
  directory list then opened, Tab's action message to the field editor moves the editing from
  Name to Directory and ⇧Tab's back (the two cases one after another); Tab and ⇧Tab, alone or
  with ⌥, ⌃ or ⌥⇧, are no `PopoverKey`, so the key monitor leaves them to the focused view and
  an input method; the `--preview-key-view-loop popover|switcher` flag (only with
  `--preview-fixtures`; another name, no name or no `--preview-fixtures` a usage error).
- **The New session window** (`Tests/MuxFinderUITests/NewSessionWindowTests.swift`; PLAN.md
  D34), through the real model, engine and coordinator over fakes and the real popover,
  switcher and window controllers over fake surfaces: opening from the popover and from the
  switcher (each closes, the window shows key with its top centre at theirs, the switcher's
  filter naming only a fresh draft); opening again bringing it forward with its draft,
  directory list and moved frame; Cancel, Esc (the list first) and the close button dropping
  the draft; a running creation keeping its draft busy across a close and reopen, its success
  closing the window; a collision and a failure staying in it; a collision and a failure that
  end after the window was closed bringing it back at its last frame, not key, from either
  entry point, even with a Move here confirmation showing ("Open existing" then working); a
  Move here confirmation and the window at the same time; the popover's and the switcher's
  openings and closings leaving the window, its draft and its list alone; the window's keys
  (⌘, Settings, ⌘R and ⌘F going on, ⌘N and the arrows nothing, none with it closed); its click
  filter after each opening; the model with no window; the placement as pure functions (the
  fresh frame clamped, a request's frame, the height with the top fixed) and the controller's
  resize.
- **The folder drop** (`Tests/MuxFinderUITests/FolderDropTests.swift`; PLAN.md D34, Phase
  I-9b). `FolderDrop.outcome(for:home:)` as a pure function over plain facts (no disk): a
  folder under the home folder `~/…`, the home itself `~`, one outside absolute, a sibling
  such as `/Users/me2` absolute (whole components), a file, a package, two items, none, a
  non-file URL, no URL and a relative `file:` URL refused, a trailing slash (in the URL or the
  home) dropped, a path needing no change kept, no rule without a home or with `/`, `//`, `.`
  and `..` standardized by text, percent escapes decoded, `/tmp` never resolved. In the model:
  the fill opens no list (the same text typed would) and announces nothing, closes a list the
  button or the typing opened, replaces the field's text; a refused drop changes nothing; the
  highlight follows the drag (on for a folder, off for a refusal, on exit, at the drop, when
  the window closes); a closed window or a busy draft takes none; an SSH host gets the same
  `~/…` and the draft's checks (a line break shows its issue); no home, no `~`; the gallery's
  highlight fixture and the field's hint. In the real New session window (never shown): one
  `FolderDropView`, covering the Directory field and in front of it and of its field editor
  while edited, registered for file URLs and every type that field editor registers, clicks at
  the field's centre reaching the field (or its editor), never focused or an accessibility
  element; its decisions over private pasteboards (`NSPasteboard.withUniqueName()`) holding
  folders, a file and an `.app` in a private temporary folder: a folder, also as a Finder file
  reference URL, shows copy and fills `~/folder`; a file, an `.app`, two folders, text, a link
  and a move-only source show none and fill nothing; reading the drag (resource values, a link,
  text); the operation shown.
- **The panels' key routing and the Host picker** (`Tests/MuxFinderUITests/HostPickerKeyboardTests.swift`;
  PLAN.md D30, D31, D32, Phase I-8). `PanelKeyRoute.decide` as a pure function: Space is no
  panel key and always reaches the focused view; with a pop-up button focused, ↑, ↓ and ⌥↓ go
  on to it while Return and Esc are the handler's (the panel's with the directory list
  closed, the list's with it open) and ⌘F, ⌘R, ⌘N and ⌘, the panel's; with any other focus
  (a text field, its field editor, a button, a view, none) every panel key goes to the
  handler as before Phase I-8; only `NSPopUpButton`s (pop-up, pull-down, subclass) count as
  pop-up buttons; while a menu tracks, or an input method composes, every key goes on
  untouched; the keys the routing calls the directory list's are exactly those the model's
  open list answers; the diagnostic's keys are ↑, ↓, ⌥↓, Space, Return and Esc.
  `MenuTrackingObserver` over a private notification center: a begin and its end, nested
  menus, an end whose begin was never seen forgetting every menu, another center's and other
  menu notifications ignored. A host written through the picker's binding (as AppKit's menu
  pick, by click, keyboard or VoiceOver, makes SwiftUI write it) changes the draft's host,
  re-filters the directory list, keeps Name and Directory, and opens or closes no list.
- **Self-test drivers** (`Tests/MuxFinderUITests/SelfTestDriverTests.swift`, PLAN.md D25).
  `SelfTestDriver` over the real model, engine and coordinator with `SimulatedITerm2`, a
  `SimulatedTmux` (sessions in memory: the driver's tmux, discovery and New session's creator)
  and a virtual clock, with a connection of the user's present in every run. Both self-tests
  pass (every step, one launch, one `detach-client` to the run's own connection, the session
  killed); a step that fails (iTerm2 refusing the tab) and a detach whose connection never
  closes both end `failed` after cleanup (the run's own attachment detached again through the
  core, the session killed); a creation that fails kills nothing; cancelling the run during
  the attach (as SIGTERM does) cleans up the same way; a run interrupted while iTerm2 has not
  answered the launch's `CreateTab` waits for the attach only within the attach timeout, then
  detaches and kills nothing and prints what it left with the `tmux kill-session` to run; keep
  mode reports the session, the connection and the gateway and leaves both in place after the
  model stopped. In every run the user's connection gets no command and no tab is closed.
- **Persistent profiles: host-list fields** (`HostProfileFieldsTests`, PLAN.md D26, private
  folders only): a schema 1 file exactly as earlier builds wrote it loads with the defaults (no
  profile, `main`, no parent) and saves back byte for byte; set fields round-trip (the opt-in
  written only when on); `false` and `null` read as defaults and a wrong type is `malformed`;
  default session names refused by the invariant (empty, `:`, a leading `-`, `$`, `=` or `{`,
  surrounding whitespace, a tab), also as a loaded file (`invariantBroken`, file unchanged);
  parent names (empty or with a control character refused, Unicode and spaces kept).
- **Persistent profiles: generator** (`PersistentProfilesTests`): golden documents
  (`Fixtures/profiles/local-and-ssh.json`, `with-parent.json`) for This Mac and an SSH host
  turned off for discovery, the host without a profile left out, with and without a parent (a
  quote and Unicode escaped as JSON); deterministic; iTerm2's JSON types; no host with a
  profile is an empty document; helper paths with a space, a quote, `$`, non-ASCII, a tab, or
  not absolute refused with D2's error; GUIDs read back; the command line is three words that
  the helper parses as `profile <id>`.
- **Persistent profiles: installer** (`PersistentProfileInstallerTests`, a private stand-in for
  `DynamicProfiles` with a profile file, a hidden file, a plist, a link to a file outside, a
  dangling link and a subfolder): install (0600, exactly the document), identical bytes
  rewrite nothing (same inode and modification time), a moved helper is `stale` and replaced
  by a new file, removal of `muxFinder.json` only; every other entry's kind, mode, inode,
  modification time and bytes (or link text) unchanged at every step, no temporary file left;
  an empty document removes the file; a link (to a file or dangling) or a folder at the name
  refused by install, status and remove and left as it was; `createOnly` never replaces a file
  and removal with expected bytes leaves a different file alone; the folder created 0755 only
  by an install, never through a missing parent, a linked folder or another user's; a file
  over 1 MiB refused; a swap that finds another entry puts it back.
- **Persistent profiles: hash snapshot** (`ITerm2ProfileSnapshotTests`, a fake `defaults`):
  every entry but `muxFinder.json` with its kind and digest (file bytes, link text, folders
  not read); exactly `/usr/bin/defaults export com.googlecode.iterm2 -`; `New Bookmarks`
  counted; the snapshot unchanged by an install and a removal, a changed sibling or bookmark
  named by `differences(from:)`; the bookmarks digest independent of key order and free of
  profile names; booleans, integers and reals told apart; no `New Bookmarks`, output that is
  not a property list, `New Bookmarks` not an array, a failing `defaults`, a missing folder;
  the export's timeout is the default 20 s or the one a caller passes.
  The exclusion of iTerm2's copies of muxFinder's profiles (`MirrorRule`): without written
  profiles, only a well-formed generated `Guid` together with a `Dynamic Profile Filename`
  that standardizes to exactly the owned `muxFinder.json` is left out and counted
  (`excludedMuxFinderEntries`); the GUID alone, the file alone, another dynamic profile's
  copy, a look-alike GUID (`muxfinder-persistent-custom`, an uppercase UUID, a suffix, a
  capitalized prefix), another folder's, a bare or a relative `muxFinder.json`, a trailing
  `/` or `.`, a path climbing out of the folder and non-string values are hashed, in order;
  no rule or an unusable owned path leaves nothing out. With the profiles written (parsed
  from a generated document), only a copy with one of their GUIDs holding every written key
  with an equal value is left out: a changed `Command` or `Name`, `Tags` gone or changed, a
  boolean turned integer, another generated GUID, another folder's file or no file key is
  hashed. The snapshotter's owned file is `<its folder>/muxFinder.json`. The JSON holds
  `count`, `sha256` and `excludedMuxFinderEntries` and nothing of any entry; snapshots
  differing only in that count match (`hashesMatch`, `differences(from:)`) but are not `==`.
- **Persistent profiles: launch parts** (`ProfileLaunchTests`): the plan from the host list
  (override, session name, `main`, discovery switch ignored) and every refusal; problems'
  kinds, explanations and exit statuses (77 nesting, 76 host); the nesting variables (empty
  counts as unset); the local argv with the name escaped (`TmuxWord`); the remote ssh argv;
  the remote D3 string run through `/bin/sh` and `/bin/zsh` with a fake tmux for names with
  `#`, `;`, quotes and Unicode (exact argv, `-u`, no `TMUX`); the remote script's 66 and 68;
  the local check; the termination mapping.
- **Helper, profile mode** (`LaunchHelperProfileTests`, fake child runner, terminal and login
  shell, a private host list): the nesting guard through `TMUX` and through
  `MUXFINDER_LAUNCHED` (one line, the login shell started at once, nothing read or run, no
  hold; the shell keeps `TMUX`, gets `MUXFINDER_LAUNCHED=1`, loses `MUXFINDER_LAUNCH_*`);
  empty variables do not trigger; no host list, an unknown host, a host without a profile
  each start the login shell, the host list never written; This Mac (the check, then `tmux
  -u -CC new-session -A -s 'work ##1\;'`, `MUXFINDER_LAUNCHED=1`, no `TMUX`, the hold); local
  failures (tmux missing, the check timing out, exit 1, a signal, a spawn error) fall back to
  the shell; a closed tab starts nothing; the SSH host's argv and a refused login falling
  back; a remote detach; a shell that cannot start (74, wait and hold) or no shell at all; no
  shell on a terminal that is not interactive; test mode recording the shell in the digest
  without starting it, and reading a test host list only in test mode and only for its host
  id; attach children carrying `MUXFINDER_LAUNCHED=1`; parsing; login shell candidates.
- **Helper binary, profile mode** (`LaunchHelperProfileBinaryTests`): the built helper in test
  mode with `MUXFINDER_LAUNCH_NO_WAIT=1` (no shell ever started): the nesting guard through
  each variable (exit 77, the digest of `<helper> profile <id>` with the login shell recorded,
  nothing left); This Mac from a test host list with a fake tmux override (exact argv, `-u`,
  `MUXFINDER_LAUNCHED=1`, exit 0, the child in the digest); tmux exiting 1 and an unknown host
  (76).
- **e2e-profile harness** (`PersistentProfileRunTests`, simulated iTerm2 that reads the
  stand-in folder and plays the helper, in-memory tmux and discovery, a fake `defaults`, a
  virtual clock): locally and remotely all 14 steps pass (one `CreateTab` by profile name
  without a window id or custom properties, the GUID-filtered listing, the identity and then
  `detach-client` only through the tab's binding once it is 10 s old, no forced close,
  nothing left, the user's entries unchanged); an existing `muxFinder.json` or session stops
  the run before anything is created (the file untouched, the session not killed); a tab that
  never connects fails step 6 and cleanup closes only that tab, once 10 s old; a helper whose
  child is not the expected argv fails step 6 and cleanup detaches through the binding. With
  a fake `defaults` playing iTerm2's copy of the installed profile in `New Bookmarks`
  (`MirroringDefaults`: every key of the file plus keys of its own): a copy dropped 12 s after
  the removal passes all 14 steps (step 8's note counts the copy left out, step 13 reports
  the drop 12000 ms after the removal); a copy never dropped fails step 13 30 s after the
  removal with the file gone and nothing left; a renamed user profile still fails step 8
  (while installed) or step 13 (after the copy went). Beside the run's copy at step 8, a
  copy with a changed `Command`, a look-alike GUID naming the owned file, the run's GUID
  naming another folder's `muxFinder.json`, or another generated GUID fails step 8 on `New
  Bookmarks` with a note of 3 profiles hashed against 2. A copy of a muxFinder profile before
  the run (no `muxFinder.json`) is waited for in step 1 (dropped after 2 s: noted, all 14
  pass) or fails step 1 after 5 s with nothing created. Step 13's deadline counts from the
  removal: with step 12 taking 25 s, a copy that stays fails step 13 after the 5 s left, the
  exports' timeouts 5 s, 4.5 s … 0.5 s; an export of 6 s then is cut at its 5 s timeout, or
  overruns it and ends clean after the deadline, and either way fails step 13 as out of time.
- **Persistent profiles: the app's own file** (`PersistentProfilesTests`,
  `PersistentProfileInstallerTests`, PLAN.md D26, Phase 11c): `isGenerated` accepts every
  generated document (any helper path, a parent) and refuses another GUID, a look-alike or
  uppercase GUID, no `muxFinder` tag, an extra key, an empty or non-array `Profiles`, a top-level
  array, text that is not JSON; a file of the user's is `notMuxFinders` for status and refused
  by `replaceGenerated` (also with an empty document) and `onlyIfGenerated`, its bytes and the
  siblings unchanged, no temporary file left; a generated file of another helper path is
  replaced and removed. `updateExistingGenerated` (the automatic updates) creates nothing: no
  folder or no file (also one removed after a status read it as stale) is `notInstalled`, the
  folder not created; it updates a stale generated file (0600), writes nothing for identical
  bytes, removes only a generated file for an empty document and refuses a file of the user's
  (with a document or an empty one); a swap over a checked file that went meanwhile is
  `fileChanged` and creates nothing at the name.
- **Persistent profiles in Settings** (`Tests/MuxFinderUITests/PersistentProfilesSettingsTests
  .swift`, a fake seam that holds the generator's real bytes; the real seam only over a private
  folder): the session name and parent rules (trimmed, empty as none, each refusal with the
  validation's sentence, checked with the profile off too, an untouched parent saved back as
  loaded); an invalid draft blocks Save and writes nothing; a host without the fields and one
  with them save back byte for byte through `HostStore` in a private folder; the tab's content
  for every status (the not-saved list, an unusable helper with the file still there, a file of
  the user's, no profile on, an operation running, unsaved edits) and every result line;
  Install uses the saved list, never the draft, Remove only muxFinder's file, Install and
  Remove calling nothing while off; a busy lock shown as a failure; an install held at the
  fake's gate leaves the main actor free; a save while installed updates the file (a rename)
  through `update(_:)`, never `install(_:)`, turning off the last profile removes it, a save
  with nothing installed writes nothing; a save's update held at its status check while
  Settings closes and reopens (the list loading) updates to the list the save wrote, never to
  an empty document; "Check again" while the list loads asks nothing, and an install held
  while the list reloads checks the status for the list it installed; at launch a stale file
  (the helper moved) is updated, a missing or current file or an unusable helper writes
  nothing, a list not loaded as `saved` or a launch that does not rewrite never asks the seam,
  and the log holds kinds only; a file removed after an automatic update read it as stale
  (at launch, after a save) is not created again; only normal mode rewrites
  (`AppLaunchOptions`: never `--preview-fixtures`, `--selftest`, either report, the profile
  removal or unusable arguments); `shutdown()` stops profile work; every Settings fixture's
  model has no environment and no action changes its state; `PersistentProfileFiles` over a
  private stand-in folder (not installed, an update then creating nothing, installed, stale
  after a helper move, updated, an unsafe helper still seeing the file and removing it, a file
  of the user's left exactly as it was).
- **Profile removal for the uninstall script** (`PersistentProfileRemovalTests`, PLAN.md D27,
  private stand-ins for `DynamicProfiles` and muxFinder's folder): a generated file (also of
  another helper path) is removed, exit 0, every sibling hashed unchanged, the lock file kept;
  a second run is "none installed"; a file of the user's (another GUID, `{}`, a look-alike
  GUID, not JSON) is left byte for byte with exit 1, in a dry run and for real; a dry run over
  the generated file reports it, changes nothing and creates no lock folder; no folder creates
  neither folder; a linked `muxFinder.json` is left with its target unread; a held lock fails
  with exit 3 and deletes nothing; every installer error is sorted into left or failed; no
  folders means the real ones. `AppModelTests.profileRemovalOptions`: the flag, `--dry-run`
  and both folders parse; each option without the flag, the flag with another mode, one
  folder alone, a missing, empty or relative folder are usage errors, and none rewrites at
  launch.
- **Hiding the launch tab** (PLAN.md D29). The client: `SetProperty`/`GetProperty` against
  golden fixtures from iTerm2's Python module and the bound `buryLaunchTab`
  (`ITerm2APIClientTests`, `ITerm2GoldenTests`). The helper's restore (`LaunchTabRestoreTests`:
  the bytes and their order after the result, the 2 s bound under back pressure, the second
  restore when unanswered, the Return reader and signals, in a pseudo-terminal too). The
  coordinator over the fakes' buried state (`LaunchTabBurialTests`: a bury before or after the
  helper's restore, the result before or after the peek, a bury timeout, the connection gone,
  coalesced callers, focus, Move here, `.noTab`, a failed activation, the recovery closing a
  clean dead tab and leaving a failed one visible; `ShowLaunchTabTests` for Show tab during a
  pending bury; `LaunchStoreTests` for `peekResult`). `RecordingITerm2IntegrationTests` for the
  e2e runs' recording (each bury's answer included), `LaunchTabChecksTests` for `e2e-bury`'s
  judgements of steps 7 and 11 (an ownership refusal is never the race; a killed attach's tab
  that vanishes or is buried again after coming back, a wrong result, a dead helper or a short
  watch fail), and `SelfTestDriverTests` for the self-tests' two new steps.
- **Update check** (PLAN.md D39, Phase I-13a; no request ever leaves the process): versions and
  tags (`UpdateVersionTests`); the `releases/latest` parser over synthetic bodies written by
  hand, every asset rule and the offer against the running version
  (`UpdateReleaseParserTests`); `URLSessionUpdateTransport` through `UpdateStubProtocol`, the
  only protocol class on its sessions, which claims every request (`UpdateTransportTests`:
  the headers, `If-None-Match`, no cookies, the timeouts, the body bound, rate limits, the
  redirect refusal); how each answer changes the kept state, the 304 rule
  (`UpdateCheckTests`); `update-state.json` on private folders (`UpdateStateStoreTests`); the
  `checkForUpdatesAutomatically` key (`UpdateCheckPreferenceTests`); the schedule over a
  manual clock and a fake transport (`UpdateSchedulerTests`); the probe's arguments and output
  over a fake transport (`UpdateProbeTests`). See *Phase I-13a* below.
- **Update download and verification** (PLAN.md D39, Phase I-13b1; no request ever leaves the
  process, every signature ad hoc): `URLSessionUpdateDownloadTransport` and `UpdateDownloader`
  through `UpdateStubProtocol` (download URLs routed by their tag) into private staging
  folders (`UpdateDownloadTests`: the headers, the configuration, progress, the exact size,
  `Content-Length`, the digest, the redirect allowlist, HTTP errors and failures, Cancel, the
  zip mode's local copy); the archive check and the extraction's watchdog on synthetic zips
  built with `ditto -c -k` and patched, and on a stand-in for `ditto` (`UpdateArchiveTests`);
  `ditto` and the shape on synthetic zips and on hand-made trees (`UpdateExtractionTests`);
  the Team ID, the requirement and
  `SecurityUpdateCodeChecker` on ad hoc signed stubs (`UpdateCodeCheckTests`); the versions
  and `Info.plist`'s bounded read (`UpdateBundleVersionsTests`); the staging folder's rules,
  the pipeline's verdicts and cleanup, and the bundle's identity binding
  (`UpdateVerifierTests`); the probe's `update verify`
  arguments and JSON over fakes (`UpdateVerifyProbeTests`). See *Phase I-13b1* below.
- **Install and uninstall scripts** (not `swift test`; `scripts/dev/test-install-scripts.sh`,
  PLAN.md D27): see *Phase 12a* below.

## Helper test mode: argv digest

To see exactly how iTerm2 splits a tab's `Command` property, turn on the helper's test mode
and read the digest it writes before parsing its arguments (PLAN.md D14):

- Turn it on with `MUXFINDER_LAUNCH_TEST_MODE=1` (direct runs) or, for helpers iTerm2
  starts, by creating a regular file named `test-mode` in the launch directory
  (`~/Library/Application Support/muxFinder/launch/`). An e2e run creates the marker before
  opening the tab and removes it during cleanup. The sweep never removes it.
- The helper writes `argv-<helper pid>.json` (0600) in the launch directory: `argumentCount`,
  `arguments` (per argument, argv[0] first: `byteLength` and lowercase hex `sha256`),
  `launchID` (the first argument after argv[0] that is a canonical launch id, else absent),
  `helperPID` and `recordedAt`. No other raw argument is stored.
- Right before the helper starts its attach child (tmux locally, ssh for a remote host, or the
  plain `/usr/bin/ssh -- <destination>` of `ssh-setup`, PLAN.md D24), it writes the same file
  again with `attachChild`: `argumentCount` and `arguments` of that
  child's argv (argv[0] the executable's path), digested the same way, and
  `detachesOtherClients` (`true` only for a move here, whose tmux gets `attach-session -d`,
  PLAN.md D21). A launch that ends before its attach child (a guard refusal, an interrupted
  test launch delay) leaves none.
- `LaunchStore.takeArgvDigests()` reads the digests (and deletes them), oldest first. To check
  a run, compare `argumentCount` with 3, `arguments[0]` with the helper path's length and
  SHA-256, and `launchID` with the request's id. `muxfinder-probe e2e-local` does exactly that
  for every launch it makes, and checks that no attach child of a normal attach used `-d`;
  for its attaches and its move here it also compares `attachChild` with the exact argv it
  expects. A helper rewrites its digest after each launch tab restore (below), also after a
  later step took it, so the run leaves out digests of launches a step already checked.
- In `profile` mode (PLAN.md D26) test mode never starts the login shell: its argv
  (`-<name>`) is recorded as `attachChild` with `startsLoginShell: true`, and the helper ends
  like a failed launch. It also reads `launch/profile-test-<host id>.json`, when one exists for
  the profile's host id, in place of `hosts.json`; `e2e-profile` writes and removes it.
- Test mode also honors a request's `testLaunchDelaySeconds` (1–120): the helper prints
  `muxFinder test mode: waiting <n> s before starting.` and waits that long in a `/bin/sleep`
  child before its first real child, so its tab stays open with nothing running; closing the
  tab ends it as `interrupted` (PLAN.md D14 *Test launch delay*). Outside test mode the field
  is ignored. `e2e-remote`'s `still waiting` step is its only user.
- In `attach` mode the digest also gets `attachChildProcessID` right after the spawn, and one
  `tabRestores` record per launch tab restore (`afterChild`, `afterTmuxModeEnd`,
  `beforeExit`: whether `Disinter` was written, when, and how the status report ended; PLAN.md
  D14, D29). A request's `testSuppressDisinter` leaves `Disinter` out of every restore.
  `e2e-bury` uses all three.

## Real-world checks with iTerm2 (`muxfinder-probe`)

These open real iTerm2 windows. Run them explicitly from a shell inside iTerm2 (so the cookie
request shows no prompt), never from `swift test`, with `TMUX_TMPDIR` unset: the helper in
iTerm2 always uses the default tmux server. Run `swift build` first: `swift run
muxfinder-probe` builds only the probe, and iTerm2 runs the `muxfinder-launch` built next to
it, which may be older. Check `muxfinder-probe iterm2 status` before and after: a timeout
(exit 75) means a modal iTerm2 dialog is open; stop and report which step caused it.

- `swift run muxfinder-probe e2e-profile --local | --ssh saturno-m4` — the persistent
  profile run (PLAN.md D26, Phase 11b); its steps and real results are under *Phase 11b —
  real persistent profile runs* below. It writes the real `DynamicProfiles/muxFinder.json` for the run only and
  refuses to start when that file exists.
- `swift run muxfinder-probe e2e-local` — the local integration proof (PLAN.md Phases 4, 5a,
  6a and 6b). It creates `muxfinder-test-<8 hex digits>` on the default server (two windows, the first
  split in two, every pane `sleep 600`), turns on the helper's test mode (the
  `launch/test-mode` marker, through `LaunchStore`), and prints one `PASS`/`FAIL` line per
  step: 1 create, 2 discover, 3 attach (the existing-attachment check finding nothing, states,
  activation, the argv digest: 3 arguments), 4 tabs and split through `ListSessions`, 5 focus
  existing (a second attach of the attached session ends `focused` on the same connection and
  launch tab, `requested` → `focused`, one of its tabs activated, the check counting exactly 1
  mapped and 0 unmapped connections; nothing opens: the same window and tab ids before and
  after, for the run's own windows and every other, the same connections, no new launch tab or
  argv digest), 6 detach by session (`detach(session:on:)` finds exactly that attachment,
  checks it again and sends `detach-client`: answered, connection closed, helper exit 0, tmux
  tabs and launch tab closed, session alive with the same id, 2 windows, 3 live `sleep` panes,
  no client), 7 reattach (attach, tabs, then a detach by connection with the same checks), 8
  two concurrent attaches (one launch: one launch tab, one new connection, its two tmux tabs;
  one argv digest), 9 stale guard (a stale target refused by revalidation without a tab; with
  discovery reporting the same wrong `session_created` the helper's guard refuses it:
  `sessionChanged`, no connection, no tmux client; the refused launch tab must still be open a
  second later, showing the explanation and waiting for Return, and is then closed by its
  recorded session id once it is 10 s old), then the Phase 6a steps (PLAN.md D18): 10 vanished
  session (a second session, `<name>-gone` running `sleep 600`, created by the harness,
  discovered and then killed; its attach must end `sessionGone`, refresh-triggering,
  `requested` → `failed`, with no launch tab, request or argv digest, and the `list-sessions`
  ids unchanged by the attach), 11 collision (`createAndAttach` with the main session's name:
  `sessionExists` from `has-session`, no state published, the main session as recorded with 2
  windows and 3 live panes, the count unchanged), 12 invalid name (five names with `.`, `:`,
  `\`, a line break, only spaces: `invalidName` with zero processes run by a counting runner,
  nothing launched), 13 missing directory (`<private directory>/missing ünïcödé 日本`:
  `directoryMissing`, no session of that name, the count unchanged), 14 new session
  (`createAndAttach` of `<name>-new #ü 日本;`, `sleep 600`, in a real directory
  `dir with spaces ünïcödé 日本 #1;` that the run creates with `mkdir` in a private
  `/private/tmp/mfx.XXXXXX`; both trailing `;` must reach tmux escaped: confirmed with
  `requested` → `launched` → `confirmed`, the
  existing-attachment check skipped, activated, the argv digest; the exact name stored, the
  pane's `#{pane_current_path}` byte-equal to the directory, discovery listing it with one
  window and one control client; then a clean detach by connection and a kill by id), then
  the Phase 6b step (PLAN.md D21): 15 move here (the harness starts a plain control client on
  the unattached test session, `tmux -u -C attach-session -t '=<name>'` with stdin a pipe it
  holds open and its output drained, never logged, and waits until `list-clients` shows it as
  the session's only client, by its pid; a move here confirmed for another key must fail
  `moveHereNotConfirmed` with no state and no digest, the plain client still attached; the
  confirmed move here must end `confirmed` (`requested` → `launched` → `confirmed`,
  activated, the check finding nothing of the run's) with `attachChild` exactly
  `<tmux> -u -CC attach-session -d -t <id>`; the plain client must print `%exit` and exit by
  itself within 10 s; the session's only client must then be another control client, and 2 s
  later the launch tab must still own its connection, which still shows the session with both
  tmux tabs; then a clean detach by connection, the session surviving unattached), 16
  cleanup (first ends the plain control client if it still runs; also kills any extra session
  of the run, found by its exact name if its output was lost, and removes the private
  directory). Steps 3 and 7 also compare their attach child with the exact argv without
  `-d`. Every confirmed attach (steps 3, 7, 8, 14 and 15) must also end with `burial`
  `buried` and its launch tab in `buried_sessions` and in no tab within 5 s, and after every
  detach that tab must leave both iTerm2's tabs and `buried_sessions` by itself within 10 s,
  before any cleanup: the run's coordinators talk to iTerm2 through
  `RecordingITerm2Integration`, and a restore or `Close` of the coordinator's that may have
  touched the tab fails the step (PLAN.md D29). Cleanup closes each leftover launch tab
  (forced), checking the answer and its absence, and restores a still-listed buried one before
  closing it again. Notes under the steps record what iTerm2 did
  (argv split, placement, tab fields, the check's counts and timings, whether the launch tab
  closed, how old each launch tab was when it ended). Exit 0 only when all 16 pass; 128 + n
  after signal n. Safety: only its own session, which every later step (rediscovery
  before each attach, the survival checks, the kill) accepts only if its server pid, start
  time, socket path, id, creation time and exact generated name are those `new-session -P`
  reported; when a signal cuts `new-session` short, cleanup first finds the session by that
  exact name among sessions created since the attempt; it is killed by id, and every kill
  (the steps' and cleanup's) makes that identity check in the same tmux command
  (`if-shell -F` choosing between `kill-session` and a marker, PLAN.md D18), never in an
  earlier call, so a server restarted in between cannot lose a session of the user's. Its
  attachment
  index asks only connections owned by launch tabs the run opened (PLAN.md D16), so other tmux
  connections get no command at all; setup prints how many exist. Only connections iTerm2
  lists as owned by launch tabs it opened are detached (checked again right before each
  `detach-client`), only those launch tabs closed, and only by the ids iTerm2 reported; every
  wait is bounded (tmux calls 5 s, iTerm2 requests 10 s, the index 3 s per connection, polls
  3–5 s, attach 15 s to a connection, the whole run 300 s); cleanup runs after a failure,
  SIGINT/SIGTERM/SIGHUP or the time limit. Every launch tab is at least 10 s old before it ends
  (the coordinator waits before `detach-client`, the harness before it kills the session or
  closes a tab, and the helper does not exit younger), because iTerm2 shows a blocking modal
  warning for sessions that end within 3 s of starting (see `docs/INTEGRATION-PROOF.md`). The
  focus step opens and ends nothing. The move-here step's plain control client attaches only
  to the run's session, by its exact name; on any failure the step closes its input and then
  ends its process group (SIGTERM, SIGKILL) before cleanup, which does the same first. A full
  passing run takes about 65 s.
- `swift run muxfinder-probe e2e-remote saturno-m4` — the integration proof over SSH (PLAN.md
  Phase 5b, D17); only `saturno-m4` is authorized for it. Its tmux calls on Saturno (create,
  split, list, display, kill) go through `/usr/bin/ssh` with discovery's noninteractive
  options (`BatchMode=yes`, `-n -T`, a 12 s deadline), a static script and every argument
  single-quoted (D3); it writes no file there. It creates `muxfinder-test-<8 hex digits>` on
  Saturno's default server (the same shape as `e2e-local`), turns on the helper's test mode,
  and prints one `PASS`/`FAIL` line per step: 1 create, 2 discover (over ssh; notes the remote
  `uname -n` the index matches by), 3 attach (the launch tab runs `ssh -t` to Saturno; states
  `requested` → `launched` → `confirmed` within the 20 s budget, so no `stillWaiting`;
  activation; the argv digest), 4 tabs and split, 5 detach by session (`detach(session:on:)`
  for the SSH host; ssh and the helper exit 0, the session survives with 2 windows and 3
  `sleep` panes, `pane_dead` 0, no client), 6 reattach (attach and tabs again), 7 focus existing
  (a second attach ends `focused` on that connection; nothing opens, as in `e2e-local`), 8
  detach (by connection, the same checks), 9 stale guard (the remote guard refuses a stale
  request, ssh exits 65: `sessionChanged`, no connection or client; the refused tab stays open
  with the explanation and is closed by the test once 10 s old), 10 still waiting (an attach
  through `saturno-m4` whose request asks for the helper's 60 s test launch delay, PLAN.md
  D14: the helper waits before it would start ssh, so there is no login and no prompt, and no
  connection; after its 20 s budget the attach must publish `stillWaiting`, never
  `confirmed`, with the tab open and no connection; the test then closes that tab, forced,
  once 10 s old, the helper ends `interrupted` without starting ssh, and the attach must end
  `failed`, the session alive and unattached; the attach runs in a task the step cancels and
  awaits on every way out, so Ctrl-C during its `CreateTab` still leaves the tab to cleanup),
  11–15 the Phase 6a steps of `e2e-local` (vanished session, collision, invalid name, missing
  directory, new session) on Saturno, creation going through `TmuxCommands` over ssh with
  BatchMode; the missing directory is `~/<name>-missing ünïcödé 日本` and the new session's
  directory `~/Library/Application Support` (an existing directory with a space; the run writes
  no file on Saturno), its `#{pane_current_path}` compared with the server's `HOME` (from
  `show-environment -g HOME`) plus `/Library/Application Support`, the name's trailing `;`
  kept, 16 move here (as in `e2e-local`; the plain control client runs on Saturno through
  `/usr/bin/ssh` with discovery's noninteractive options plus `ControlMaster=no`,
  `ControlPath=none` and `-T`, its stdin the harness's pipe, and `RemoteTestTmux`'s static
  D3 script, so it writes no file there; its tmux client pid is the remote one, so the step
  tells it apart from iTerm2's client by that pid; the expected attach child is
  `/usr/bin/ssh -t -o ConnectTimeout=10 -- saturno-m4 <D3 string>` with
  `RemoteLaunch.moveHereScript`), 17 cleanup (ends the plain control client first if it still
  runs, detaches leftovers, kills the run's sessions by id with the identity check
  in the same tmux command, one ssh invocation each — never
  `kill-server`; the server exits by itself when it was the last session — closes the run's
  leftover launch tabs once 10 s old, removes the marker). The same launch tab checks as
  `e2e-local` (steps 3, 6, 15 and 16 buried; every detach's tab gone by itself). The same
  safety rules as `e2e-local`: only its own session, recognized by server, id, creation time
  and name; its
  index asks only its own launch tabs' connections; every wait bounded (ssh calls 12 s, the
  plain client 15 s to attach and 10 s to exit, the whole run 300 s); cleanup after a failure,
  a signal or the time limit; exit 0 only when all 17 pass, 128 + n after signal n. Needs key
  authentication to the destination (setup fails when `tmux -V` over ssh in `BatchMode` does
  not answer). Every ssh login it makes is the run's own, with key authentication. A passing
  run takes about 123 s, 28.7 s of it the still-waiting step, 16.6 s the move-here step and
  14 s the new-session step.
- `swift run muxfinder-probe e2e-bury --local | --ssh saturno-m4` — the real check of the
  hidden launch tab (PLAN.md D29; Phase 13a's spike, run through the coordinator since Phase
  13c, whose own bury is on as in the app; `--help` contacts nothing). It creates
  `muxfinder-test-<8 hex digits>` (one `sleep 600` pane) and attaches it five times (up to
  seven when step 7 races again) with no existing-attachment check, so it asks no other
  connection; its coordinator goes through `RecordingITerm2Integration`, which also records
  each bury's answer, with a hook right before each bury. Steps 7 and 11 are judged by
  `BuryRaceOutcome` and `KilledLaunchTabWatch`
  (`Sources/MuxFinderCore/Attach/LaunchTabChecks.swift`, covered by `LaunchTabChecksTests`; the
  probe has no test target). Steps: 1 create session, 2 discover, 3 attach (bury): confirmed,
  `burial` `buried`, the tab in `buried_sessions` and in no tab, the helper's digest naming
  its attach child's pid; 4 detach within 10 s (a bound
  `detach-client` of the harness at 5 s); 5 reattach; 6 detach after 10 s (the
  coordinator's); 7 detach at the bury, D29's race for real: once the tab is 5 s old the hook
  releases the coordinator's bury together with a bound `detach-client` of the harness,
  neither waiting for the other's answer (attempt 1: both at once; later attempts: the bury
  first, the detach the moment the recorder forwarded it); the bury must be sent and answered
  `OK` and `burial` be `buried` (the helper's restore undoes it) or `restoredAfterEnd` (the
  coordinator's check after the bury saw tmux had ended), and the order of the detach, the
  bury, their answers, the helper's result and first restore and the attach's return is
  printed; a bury its ownership check refused (`failed` `tmuxConnectionNotOwned`, nothing
  buried) is reported as not the race, its tab must still leave by itself, and the step
  attaches and races again, at most 3 attaches, then fails; 8 attach without Disinter
  (`testSuppressDisinter`); 9 dead tab recovery (b, d): with iTerm2's auto-hide setting on
  the tab must leave by itself, with it off the coordinator's recovery must restore and close
  the dead buried tab within 29 s of the helper's result; 10 attach for the kill; 11 kill
  attach child (e): SIGKILL of only the helper's attach child (checked to be the helper's
  child running tmux, or remotely the local `/usr/bin/ssh`, killed only when `ssh -G` shows
  no connection sharing) while buried, then a watch until 2 s past the helper's 10 s minimum
  lifetime (at least 8 s, at most 20 s after the kill): the helper's result
  `childSignaled(9)`, exit 137 (D14); the tab back in a tab with an answered status report
  (who brought it back observed) and in a tab at every later look (never buried again, never
  gone), its helper alive at the end (waiting for Return), no `Close` or further bury of the
  coordinator's, the session alive; 12 close after the kill (the same checks once more right
  before the close); 13 cleanup (restores, then closes, only its own launch tabs,
  checking every status and their absence; kills only its own session). After every detach
  the tab must leave its tab and `buried_sessions` by itself within 10 s, before any cleanup,
  with no restore or `Close` of the coordinator's recorded for it (but step 7's one restore
  right after the bury).
  It passes with the auto-hide setting on or off, never reads or writes it, and prints
  `OBSERVATION` lines with what iTerm2 did, ending with what it saw of the setting. Exit 0
  only when all 13 pass, 128 + n after signal n; the whole run is bounded to 300 s. A passing
  run takes about 72 s locally and 84 s on Saturno (about 11 s more for each extra attempt of
  step 7).
- `swift run muxfinder-probe e2e-detach-others --local | --ssh saturno-m4` — the real check of
  Detach other clients (PLAN.md D37, Phase I-11a; `--help` contacts nothing). It creates
  `muxfinder-test-<8 hex digits>` with two windows of `sleep 600` and attaches it through a
  coordinator whose own bury is on, as in the app, over `RecordingITerm2Integration` (every
  call counted) and an index that asks only its own launch tabs' connections, with discovery
  counted too. Steps: 1 create session; 2 discover (both windows); 3 attach (bury): confirmed,
  activated, `burial` `buried`, the tab in `buried_sessions` and in no tab, both windows as
  tabs of the connection, the session's one client the launch tab's; 4 plain client attached
  (`BackgroundControlClient`, `tmux -u -C attach-session -t '=<name>'`, remotely over ssh with
  `BatchMode` and no connection sharing; locally the session's second client has its own pid);
  5 confirmation for another session: `notConfirmed`, no discovery, no iTerm2 request, both
  clients still there; 6 detach other clients: `detached(count: 1)` (one other client listed,
  checked and detached, its `detach-client` confirmed by tmux), this run's attachment kept,
  none other here, the call returning no earlier than 10 s after the plain client was started
  and, when it was started more than 5 s short of that before the call, reporting a wait for
  young clients (`ageWait`), the plain client printing `%exit` and exiting 0 by itself within
  10 s of the call's return; 7 attachment
  kept: every 250 ms until 2 s after the call's return, the connection's tabs (window, tab,
  tmux window and session ids) exactly as right before the call, then the launch tab still
  owning its connection, buried and in no tab, the identity check through it still mapping to
  the session, its client the session's only one, and no restore or `Close` of the
  coordinator's recorded; 8 detach by connection (the coordinator's): its `detach-client`
  answered with its (empty) output (no `commandError`), the helper exits 0, the tmux tabs
  close, the launch tab leaves by itself within 10 s, the session survives with no client; 9
  cleanup (ends the plain client, waits until every launch tab is 10 s old, sends a
  bound `detach-client` to any connection its launch tabs still own, restores, then closes,
  only its own launch tabs still listed, kills only its own session, takes the helper results
  nobody took, and checks nothing is left). Exit 0 only when all 9 pass, 128 + n after signal
  n; the whole run is bounded to 180 s. A passing run takes about 14 s locally and 20 s on
  Saturno (most of step 6 is the wait for the young plain client).
- `swift run muxfinder-probe attach --local | --ssh <destination> --session '<$id>'` — one
  real attach of a session of the default server of this Mac or of a remote host (the launch
  tab runs `ssh -t`, so any password prompt appears there), the way the app does it; prints
  the result as JSON (state, failure,
  launch id, launch tab session, connection, activation, the existing-attachment counts,
  timings). It leaves the session attached; when the session is attached in iTerm2 already,
  it brings that tab forward instead (state `focused`, exit 0) and opens nothing. Its check
  asks every tmux connection which session it shows (a read-only `display-message`), so during
  unattended runs use it only on `muxfinder-test-*` sessions and only while `iterm2
  list-connections` shows no connection of the user's.
- `swift run muxfinder-probe new-session --local | --ssh <destination> --name <name> [--dir
  <directory>]` — creates a detached session on the default server of this Mac or of a remote
  host (noninteractive; over ssh with BatchMode, PLAN.md D18) and attaches it the way the app's
  "New session" does; prints JSON (the created id, creation time and server pid, the creation
  failure with its kind, message and `mayHaveCreated`, or the attach as `attach` prints it,
  and `triggersRefresh`). It leaves the session attached. An existing session with the name is
  never touched (`sessionExists`), a missing directory creates nothing (`directoryMissing`).
  It asks none of iTerm2's tmux connections anything (the existing-attachment check is
  skipped for a session created a moment ago), so it is safe while the user's connections
  exist; in unattended runs use only `muxfinder-test-*` names. Its panes run the user's shell.
- `swift run muxfinder-probe ssh-setup --ssh <destination> [--profile <name>]` — "Set up SSH
  in iTerm2…" the app's way (PLAN.md D24): writes an ssh setup request and opens a launch tab
  in a new iTerm2 window whose helper (`muxfinder-launch ssh-setup <uuid>`) runs plain
  interactive `/usr/bin/ssh -- <destination>`; prints `opened`, the tab's session id, or the
  failure's kind and message as JSON (never the destination). It asks no tmux connection
  anything, but it starts a real ssh login in that tab and leaves the tab to whoever ran it, so
  it never runs in unattended windows. Its real run is owed: in a real-run window, Saturno only
  (`--ssh saturno-m4`, key authentication, so ssh reaches a login shell at once): the tab must
  show the remote shell, and it must end only once it is at least 10 s old (a person types
  `exit`, so ssh exits 0 and the helper ends after its hold, or closes the tab; the probe has no
  command that closes a tab by the printed session id yet, so an unattended run needs one
  first); then check `iterm2 status`, the thread count and an empty launch directory.
- `swift run muxfinder-probe iterm2 attachments` — read-only: discovers this Mac, asks every
  tmux connection which host, server and session it shows (the same `display-message`), and
  prints the mapped connections (session id, connection id, owning session) and the unmapped
  ones by kind with their counts; no titles, host names or paths. The same caution as
  `attach` applies in unattended runs.
- `swift run muxfinder-probe detach --connection <id> --gateway <session id> [--launch-id
  <uuid>]` — `detach-client` on one connection, sent only while iTerm2 lists it as owned by
  that launch tab (both ids from `attach`'s JSON), after a 10 s wait (the process cannot know
  when the tab opened); waits for it to close (and for the helper's result with
  `--launch-id`).

## Real-world checks

### Phase 2 — discovery (2026-10-21)

Environment: Neptuno (`neptuno-m4`, macOS 27.2, tmux 3.8 at `/opt/homebrew/bin/tmux`,
OpenSSH_10.5p1); Saturno (`saturno-m4` over Tailscale, key auth, tmux 3.8). Neither had a
tmux server running before the checks. Commands ran from the repo root with the debug build
(`.build/debug/muxfinder-probe`, i.e. `swift run muxfinder-probe`).

| Check | Command | Observed result |
|---|---|---|
| Local, no server | `TMUX_TMPDIR=$(mktemp -d /tmp/mfx.XXXXXX) muxfinder-probe discover --local` (`TMUX`, `TMUX_PANE` unset) | `noServer`; tmux `error connecting to …/tmux-501/default (No such file or directory)`; 26 ms |
| Local, tmux not found | `discover --local --tmux-path /nonexistent/tmux` | `tmuxNotFound` (no fallback to Homebrew tmux); 10 ms |
| Local, test sessions | `tmux new-session -d -P -F '#{session_id}' -s <name> 'sleep 300'` for `muxfinder-test-plain` and `muxfinder-test-ünïcödé-日本-🧪` on the default server, a control client (`tmux -u -C attach-session -t '$0'`, stdin closing after 4 s), then `discover --local` | `ok`, 2 sessions: `$0` plain (1 attached client, control mode) and `$1` with the exact Unicode name; same server pid/start time/socket `/private/tmp/tmux-501/default`; ids equal the ones `new-session -P` printed; 35 ms. Both sessions killed by id; tmux then reported `no server running` |
| Saturno, no server | `env -u LANG -u LC_ALL -u LC_CTYPE muxfinder-probe discover --ssh saturno-m4` | `noServer`, node `Saturno-M4.local`, tmux `/opt/homebrew/bin/tmux` found without PATH help; 743 ms |
| Saturno, test sessions | same two names created on Saturno over ssh, a remote control client on `$0`, then the command above (no locale on the client) | `ok`, `$0` and `$1` with the exact Unicode name, client listed as control mode; 750 ms. Sessions killed by id; Saturno then reported `no server running` |
| Unicode without `-u` (negative control, D12) | on Saturno with one `muxfinder-test-ünï` session: `env -u LANG ssh saturno-m4 "tmux list-sessions -F '#{session_id}<TAB>#{session_name}'"` vs. the same with `tmux -u` | without `-u`: `$0_muxfinder-test-_n_` (tab and Unicode both `_`); with `-u`: exact bytes. Session killed |
| DNS failure | `discover --ssh something.invalid` | `unreachable(dnsFailure)`; 6 ms |
| Timeout bound | `discover --ssh 192.0.2.1` | `unreachable(timeout)` after 5.0 s (ssh `ConnectTimeout=5`; the 12 s runner limit is the backstop) |
| Refused | `discover --ssh ssh://127.0.0.1:1` | `unreachable(refused)`; 7 ms |
| Auth failure | `discover --ssh nonexistent-muxfinder@saturno-m4` | `authFailed`; 501 ms |
| Host key unknown | `discover --ssh saturno-m4 --strict-known-hosts <empty temp file>` | `hostKeyProblem(unknown)`; 277 ms. Re-run after `ControlPath=none` was added: same result, 352 ms |
| Host key changed | `discover --ssh saturno-m4 --strict-known-hosts <temp file with a freshly generated, wrong ed25519 key for saturno-m4>` | `hostKeyProblem(changed)`; 289 ms |
| Hostile names, real tmux | 7 `muxfinder-test-*` sessions on a private `TMUX_TMPDIR` server (`-f /dev/null`) named with `;rm -rf ~`, `$(touch /tmp/mfx-x)`, quotes and backticks, `-x`, emoji, `##{pid}`, a backslash; `discover --local --raw` | every name came back as tmux stored it (`#{pid}` literal, `\` as `\\`); `/tmp/mfx-x` never created; captured as `local-hostile-names.txt`; sessions killed by id |

Method notes:

- **No server without touching the user's server:** tmux's default socket lives in
  `$TMUX_TMPDIR/tmux-<uid>/default` (default `/tmp`), and the CLI passes its environment
  through (minus `TMUX`/`TMUX_PANE`), so a fresh empty `TMUX_TMPDIR` gives a server-less
  default. Use a short `/tmp` path: socket paths must stay under 104 bytes.
- **Host-key harness:** `--strict-known-hosts <file>` adds `StrictHostKeyChecking=yes`,
  `UserKnownHostsFile=<file>`, `GlobalKnownHostsFile=/dev/null`, `ControlMaster=no` and
  `ControlPath=none` (an existing master connection would otherwise be reused without checking
  `<file>`); it is stricter than the user's configuration and ssh never writes known-hosts
  files under strict checking. The "changed" row predates the `Control*` options; the
  "unknown" row was re-run with them. The temp files were unchanged afterwards (empty file still 0 bytes). `~/.ssh` was not touched.
- **Fixtures:** captured with `discover … --raw` during the checks above, so they contain only
  `muxfinder-test-*` session names; no other session existed on either server at the time.
- **Cleanup:** after the checks, `tmux list-sessions` reported no server on Neptuno and on
  Saturno, and no `tmux` process was left on Neptuno.

### Phase 3b — iTerm2 API client (2026-10-21)

Environment: Neptuno, iTerm2 3.7.6 with the API server on. Commands ran from the repo root in
a shell inside iTerm2 (so the in-process `NSAppleScript` cookie request showed no prompt),
through `swift run muxfinder-probe` (debug build). All read-only: no tab was created or
activated, no tmux command was sent, no window, tab or session was touched, and no tmux
session was created or killed. Only the output's shape is recorded here.

| Check | Command | Exit | Observed shape |
|---|---|---|---|
| Status | `iterm2 status` | 0 | `{connected: true, protocolVersion: "1.21", running: true, socketPath, socketPresent: true}`; 0.18 s end to end (cookie, handshake, and a close handshake that iTerm2 answered) |
| tmux connections | `iterm2 list-connections` | 0 | `{connections: [], count: 0}` (no tmux integration connection was open) |
| Sessions | `iterm2 list-sessions` | 0 | `{summary: {windows: 3, tabs: 3, sessions: 3, tmuxTabs: 0, buriedSessions: 0}, windows: [{windowID, tabs: [{tabID, tmuxWindowID: "-1", sessionIDs: [1 id], layout: {vertical, children: [{sessionID}]}}]}], buriedSessionIDs: []}`; all ids strings; no tab had `tmuxConnectionID` |
| Profiles | `iterm2 list-profiles` | 0 | `{count: 13, profiles: [{guid, name}]}`; every `guid` and `name` a string, GUIDs in uppercase UUID form |
| API off (mapping) | `iterm2 status --socket /tmp/mfx-nonexistent/socket` | 69 | `{connected: false, error: {kind: "apiDisabled", message}, running: true, socketPresent: false, …}` plus the one-line stderr error; no cookie requested |
| API off, listing | `iterm2 list-sessions --socket /tmp/mfx-nonexistent/socket` | 69 | stderr only: `muxfinder-probe: iTerm2's API server is off. … [apiDisabled]` |

Method notes:

- `notRunning` and `authRejected` were not produced against the real iTerm2: the first would
  need iTerm2 to quit, the second a deliberately bogus cookie, and the run rules forbid both.
  They are covered by the hermetic client tests; `authRejected` is HTTP 401, the status
  iTerm2's Python module handles as an authentication failure (PLAN.md *Verified facts*).
  The stale-socket case (`ECONNREFUSED` → `apiDisabled`) is covered with a private socket
  under `/tmp`.
- The listings' raw stdout (ids, profile names) went to temporary files that were deleted
  after the shape above was extracted.

### Phase 4a — launch helper (2026-10-21)

Environment: Neptuno, tmux 3.8, debug build (`.build/debug/muxfinder-launch`). Everything ran
in a pseudo-terminal from `script -q /dev/null …` (not iTerm2), with a private launch
directory (`MUXFINDER_LAUNCH_DIRECTORY`) and a private `TMUX_TMPDIR` server under `/tmp` that
held one `muxfinder-test-*` session running `sleep 60`. iTerm2 was not involved at any point.

| Check | Command | Observed result |
|---|---|---|
| Wait for Return on a terminal | `(sleep 2; printf '\n') \| script -q /dev/null muxfinder-launch attach <fresh uuid>` (no request) | exit 70; printed the "launch request … was not found" explanation and `Press Return to close.`, then returned 2 s later, when the newline arrived |
| Real control-mode attach | request file for `$0` written 0600 by hand (identity from `display-message`), then `(sleep 2; list-clients; printf 'detach-client\n'; sleep 2) \| script -q /dev/null muxfinder-launch attach <uuid>` | exit 0; the check child passed, then tmux was spawned directly; while attached, `list-clients` showed one control-mode client on `$0`; control-mode `%`-prefixed protocol lines on the terminal; result `{"childTermination":{"kind":"exited","status":0},"exitStatus":0,…}` with no failure; no client left afterwards |
| Hung tmux server | the same request flow on a fresh private server stopped with `kill -STOP <server pid>` before the helper ran, helper stdin `/dev/null` | exit 75 after 10 s; result `{"childTermination":{"kind":"signaled","signal":15},"exitStatus":75,"failure":{"kind":"checkTimedOut"},…}`; the "did not answer … in time" explanation on the terminal; no `tmux -u display-message` process left; then `kill -CONT`, and cleanup as below |
| Cleanup | `kill-session -t '$0'` on the private server, then `list-sessions` | `no server running on /private/tmp/mfx.…/tmux-501/default`; socket and launch directories removed |

Method notes:

- The terminal's output (control-mode protocol from a `sleep 60` session) was only counted for
  its `%` markers, not recorded.
- After `swift test`, no `/tmp/mfx-*` directory created by the tests was left, and
  `/opt/homebrew/bin/tmux -u list-sessions` reported no server on the user's default socket.

### Phase 4b — attach in iTerm2 (2026-10-21/22)

Environment: Neptuno, iTerm2 3.7.6 (API protocol 1.21, default tmux preferences), tmux 3.8,
debug build, from a shell inside iTerm2 with `TMUX_TMPDIR` unset. Only `muxfinder-test-*`
sessions existed on the default server. Observed behavior and timings:
`docs/INTEGRATION-PROOF.md`.

| Check | Command | Observed result |
|---|---|---|
| Single attach and detach (6 cycles) | `attach --local --session '$0'` then `detach --connection tmux --launch-id <id>` on one `muxfinder-test-*` session (2 windows, 3 `sleep` panes) | attach confirmed in about 1.5 s each time; detach clean (connection closed, helper exit 0) in 0.63 s; the launch tab and the tmux windows closed; iTerm2 back to the user's 3 windows and 3 tabs. The first cycles showed `Activate` refusing `select_session` with a tab target (`INVALID_OPTION`); fixed before the e2e runs |
| `e2e-local`, run 1 | `swift run muxfinder-probe e2e-local` | exit 1 after 43.2 s: steps 1–4 PASS (argv digest: 3 arguments), step 5 FAIL — the detach one second after the attach ended sessions within about 1.5 s of their start, iTerm2 opened its modal short-lived-session warning and its API stopped answering; cleanup killed the test session and removed the marker, but could not close the launch window behind the warning. The harness now keeps launch tabs 10 s old before ending them |
| `e2e-local`, later runs | — | not run: the warning was still open (checked every 2 minutes for an hour by sampling iTerm2's main thread), and only a person can dismiss it |

Method notes:

- After run 1: no tmux server was left on the default socket, the launch directory was empty
  (no request, result, digest or marker), and no other window, tab or session was touched. The
  launch window holding the warning is the only thing this phase left open.
- iTerm2's main thread was inspected with `sample` (stack frames only) to tell a modal dialog
  from a hang; no screenshot and no UI scripting was used.


### Phase 4c — real local proof (2026-10-22)

Environment: as in Phase 4b, after a person had dismissed the warning run 1 left open
(`iterm2 status` connected again). iTerm2's short-lived-session threshold was read without
writing anything: `defaults read com.googlecode.iterm2` has no `ShortLivedSessionDuration`
override and no "never warn" entry for the default profile, and the setting's default in the
iTerm2 3.7.6 binary (`+[iTermAdvancedSettingsModel advancedSettingsModelDictionary_shortLivedSessionDuration]`,
read with `lldb` on the file, not the running app) is 3 s.

| Check | Command | Observed result |
|---|---|---|
| Helper refusal in a pseudo-terminal | private `TMUX_TMPDIR` server with one `muxfinder-test-*` session, private `MUXFINDER_LAUNCH_DIRECTORY`, a request with `expectedSessionCreated` + 1; `(sleep 2; printf '\n'; sleep 12) \| script -q /dev/null muxfinder-launch attach <uuid>` | exit 65 `sessionChanged`, result written 20 ms after the start; the helper waited for Return (sent at 2 s), then held until it was 10 s old: `script` ended after 10.6 s |
| Quick end in a pseudo-terminal | the same setup with a matching request; `(sleep 1; printf 'detach-client\n'; sleep 12) \| script …` | tmux attached and exited 0 after the detach at 1.0 s; the success result was written at once (1.0 s), and the helper held until `script` ended after 10.2 s; no client left |
| `e2e-local`, run 1 | `swift build`, then `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` | exit 0, 9 of 9 steps PASS in 42.2 s; per-step timings and notes in `docs/INTEGRATION-PROOF.md` |
| `e2e-local`, run 2 | the same command, right after run 1's checks | exit 0, 9 of 9 steps PASS in 42.7 s |
| Before and after each run | `muxfinder-probe iterm2 status`; `tmux -u ls`; `ls` of the launch directory; `iterm2 list-sessions` (summary only) | always exit 0 (connected, protocol 1.21); `no server running on /private/tmp/tmux-501/default`; launch directory empty, no `test-mode` marker; 3 windows, 3 tabs, 0 tmux tabs, as before the runs |

Method notes:

- The pseudo-terminal checks ran outside iTerm2; their terminal output went to `/dev/null`.
  Their server and launch directories were removed afterwards.
- A first pseudo-terminal attempt ended after 2.0 s and 1.0 s: `swift test --filter` had
  rebuilt `muxfinder-launch` while the hold was briefly disabled to see the new tests fail,
  and nothing had rebuilt it since. That is why the real-check procedure now starts with
  `swift build`.
- No modal dialog appeared during the runs: iTerm2's API answered every request, and
  `iterm2 status` connected after each run.

### Phase 5a — existing attachments, local (2026-10-22)

Environment: as in Phase 4c. Before the runs iTerm2 listed no tmux connection, the default
tmux server was not running, the launch directory was empty, and the user's 3 windows and 3
tabs were open.

| Check | Command | Observed result |
|---|---|---|
| `#{host}` versus `uname -n` | private `TMUX_TMPDIR` server (`-f /dev/null`) with one `muxfinder-test-*` session; `tmux -u display-message -p -t <it> "#{host}\t#{pid}\t#{start_time}\t#{socket_path}\t#{session_id}"` and `uname -n`; then the session killed | one line, five fields separated by real tabs; `#{host}` byte-identical to `uname -n` (`Neptuno-M4.local`); afterwards `no server running` on the private socket, directory removed |
| Attachments, none | `muxfinder-probe iterm2 attachments`, before and after the runs | exit 0; `discovery: noServer`, every count 0, no attachment, nothing unmapped |
| `e2e-local`, run 1 | `swift build`, then `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` | exit 0, 10 of 10 steps PASS in 42.9 s; focus existing PASS (131 ms; nothing opened); detach by session PASS; per-step timings and notes in `docs/INTEGRATION-PROOF.md` |
| `e2e-local`, run 2 | the same commands after two notes were reworded | exit 0, 10 of 10 steps PASS in 43.3 s; focus existing PASS (107 ms) |
| Clients not in UTF-8 mode | private `TMUX_TMPDIR` servers (socket directories holding `é`, a combining acute, a zero-width space, a tab and `_`) with one `muxfinder-test-*` session each; the identity command, and the tab-separated one it replaced, fed on stdin to `tmux -C attach-session` with `-u` and without, under `LC_ALL=C`, with no locale (`env -i`) and with `LANG=en_US.UTF-8`; `list-sessions -F` without `-u`; then the sessions killed | without `-u` and a UTF-8 locale: `client_utf8` 0, tabs and `é` one `_` each, the zero-width characters dropped, `_` and `:` kept, the tab-separated line one field; with `-u` or `LANG=en_US.UTF-8`: `client_utf8` 1, exact bytes; `#{n:…}` in bytes; `-F` output replaced the same way; afterwards `no server running` on each private socket, directories removed |
| `e2e-local`, run 3 | `swift build`, then `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local`, on the final tree with the review fixes (length-prefixed identity command, bound activation, an unknown tab's age from its observation) | exit 0, 10 of 10 steps PASS in 42.2 s; focus existing PASS (88 ms; 1 mapped, 0 nonUTF8, 0 stale; nothing opened); detach by session PASS (launch tab 10.3 s old) |
| After each run | `muxfinder-probe iterm2 status`; `iterm2 list-connections`; `tmux -u ls`; `ls` of the launch directory; `iterm2 list-sessions` (summary only; runs 1 and 2) | always exit 0 (connected, protocol 1.21); 0 connections; `no server running on /private/tmp/tmux-501/default`; launch directory empty, no `test-mode` marker; 3 windows, 3 tabs, 0 tmux tabs, as before |

Method notes:

- Setup reported 0 tmux connections the run had not opened, and the run's index asks only
  connections of its own launch tabs, so no connection of the user's could get a command.
- No modal dialog appeared: iTerm2's API answered every request, and `iterm2 status` connected
  after each run.

### Phase 5b — remote attach over SSH (2026-10-22)

Environment: Neptuno as in Phase 5a; Saturno (`saturno-m4` over Tailscale, key auth, tmux 3.8
at `/opt/homebrew/bin/tmux`). Before the runs iTerm2 listed no tmux connection, neither Mac
had a tmux server running, and the launch directory was empty. Each run was preceded by
`swift build`. `e2e-remote` runs 1–3 used the `still waiting` step's original design (a
login as `nonexistent-muxfinder@saturno-m4`, so ssh waited at a password prompt). The review
that followed replaced it with the helper's test launch delay (no login), bounded the
standard error relay and made the step await its attach (PLAN.md D14, D17). Runs 4 and 5 and
the last `e2e-local` are on that final tree, made once iTerm2's API answered again (see below).

| Check | Command | Observed result |
|---|---|---|
| Remote tmux over ssh | `ssh -o BatchMode=yes -o ConnectTimeout=5 -n -T -- saturno-m4 '/opt/homebrew/bin/tmux -u -V; uname -n'` (read-only) | `tmux 3.8`, `Saturno-M4.local` |
| `e2e-remote`, run 1 | `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-remote saturno-m4` | exit 0, 11 of 11 steps PASS in 75.9 s; still waiting PASS (`stillWaiting` 21.0 s after the call; the attach ended `helperFailed(childSignaled)` after the test closed the tab); per-step timings in `docs/INTEGRATION-PROOF.md` |
| `e2e-local` | `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local`, after run 1 (the remote path added, `e2e-local` on the shared harness) | exit 0, 10 of 10 steps PASS in 42.2 s; focus existing 89 ms; detach by session 10.0 s |
| `e2e-remote`, run 2 | the same command, same tree as `e2e-local` | exit 0, 11 of 11 steps PASS in 76.3 s; step 10: helper `childSignaled`, exit 129 (SIGHUP), the attach ending 5.2 s after the forced close |
| `e2e-remote`, run 3 | the same command, on the tree with the 10 s closed-tab result wait (added after run 2 showed the attach ending 5.2 s after a close, past the 5 s wait) | exit 1 after 92.2 s: steps 1–9 PASS, step 10 FAIL ("the attach ended failed instead of waiting", about 10 s after the call, before its 20 s budget), cleanup FAIL (it killed the session and removed the marker, but could not list iTerm2's connections or close the step-10 launch tab): iTerm2's API had stopped answering (see the next row) |
| After run 3 | `muxfinder-probe iterm2 status` (once); `/usr/bin/log show --predicate 'subsystem == "cc.carpio.muxfinder"'`; `ps`; `lsof -p <ssh pid> -i`; one `sample` of iTerm2 (stack frames only) | `status` exit 75 (`timedOut`) after about 2 minutes. No helper failure was logged for step 10, and its helper and ssh child were still running, ssh at its password prompt with its TCP connection already `CLOSED` by Saturno: the tab had opened and the remote side behaved as in runs 1–2, so the attach failed on an iTerm2 request timing out. iTerm2's main thread was idle in its event loop (no modal run loop); 64 GCD worker threads were each blocked in `-[NSAnimation _runBlocking]` (PLAN.md *Verified facts*, Phase 5b) |
| After each run | `iterm2 status` and `iterm2 list-connections` (runs 1 and 2); `discover --ssh saturno-m4`; `discover --local`; `ls` of the launch directory | runs 1–2 and `e2e-local`: exit 0, 0 connections; after every run: Saturno `noServer`, this Mac `noServer`, launch directory empty with no `test-mode` marker, no `/private/tmp/mfx.*` |
| Before the final-tree runs | `iterm2 status`; `ps -axo pid,lstart,comm` and `ps -M -p <iTerm2 pid> \| wc -l`; `discover --ssh saturno-m4`; `discover --local`; `ls` of the launch directory | `status` exit 0 (connected, protocol 1.21) with iTerm2 the same process as before the stall (up since 2026-10-21 19:27, never restarted); 19 lines (18 threads); both hosts `noServer`; launch directory empty. Run 3's launch tab was still open; a person ended it at 13:46, around the start of run 4, and its unread result file (ssh ended by SIGINT, helper exit 130) was removed after run 4 |
| `e2e-remote`, run 4 | `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-remote saturno-m4`, on the final tree | exit 0, 11 of 11 steps PASS in 77.2 s; still waiting PASS (`stillWaiting` 21.1 s after the call, the helper still in its test launch delay, no ssh, no login; the attach ended `helperFailed`, helper `interrupted` exit 129, 5.0 s after the forced close) |
| `e2e-remote`, run 5 | the same command, same tree | exit 0, 11 of 11 steps PASS in 77.5 s; step 10 as in run 4, the attach ending 5.2 s after the close |
| `e2e-local`, final tree | `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local`, after run 5 | exit 0, 10 of 10 steps PASS in 43.1 s; focus existing 195 ms; detach by session 9.7 s |
| After each final-tree run | `iterm2 status`; `ps -M -p <iTerm2 pid> \| wc -l`; `discover --ssh saturno-m4`; `discover --local` (after `e2e-local`); `ls` of the launch directory; `ls -d /private/tmp/mfx.*` | always `status` exit 0; 15, 19 and 16 lines, so no growth; both hosts `noServer`; launch directory empty with no `test-mode` marker; no `/private/tmp/mfx.*`. Each run's setup reported 0 tmux connections it had not opened (`iterm2 list-connections` itself was not run) |

Method notes:

- Every remote tmux call of the harness went through ssh with `BatchMode=yes`, a static script
  and quoted arguments; nothing was written on Saturno beyond what tmux itself creates for its
  socket. Only `muxfinder-test-*` sessions existed there, and each was killed by id.
- In these runs the still-waiting step logged in as `nonexistent-muxfinder@saturno-m4` (one
  attempt per run, the same kind as Phase 2's authentication check; nothing was typed into the
  prompt). The review ruled that outside the run rules; the step now makes no login attempt.
- Left behind by run 3, because iTerm2's API no longer answered: one launch window of the run
  (its helper and ssh, the latter at a password prompt whose connection Saturno had closed).
  Nothing was sent to iTerm2 after the stall was found, not even ending that helper: closing a
  window would put more work on iTerm2's starved queues.
- The stall cleared by itself within about two hours, without a restart. A person ended run
  3's launch tab at 13:46, around the start of run 4.

### Phase 6a — new session and vanished sessions (2026-10-22)

Environment: Neptuno and Saturno as in Phase 5b, iTerm2 3.7.6 (the same process since
2026-10-21 19:27). Before the runs iTerm2 listed no tmux connection, neither Mac had a tmux
server running, and the launch directory was empty. Every run followed `swift build` and ran
as `.build/debug/muxfinder-probe` (what `swift run` runs) with `TMUX_TMPDIR` unset. Runs 1
and 2 are on the tree before one change to the new-session step's note (it now reports the
creation time apart from the attach's own timings); runs 3 and 4 are on the final tree.

| Check | Command | Observed result |
|---|---|---|
| tmux behavior for creation | a private `TMUX_TMPDIR` server under `/tmp` holding only `muxfinder-test-*` sessions: `has-session -t '=…'` with no server, missing, a prefix, a literal `#{pid}`, `=$0`; `new-session -d -P -F … -s … -c …` with `##`, `#{pid}`, `#(…)`, `\`, a missing directory, a duplicate name; then every session killed by id and the directory removed | the facts in PLAN.md *Verified facts*, Phase 6a: `-s` and `-c` are format-expanded (`##` gives `#`), a missing `-c` directory silently starts the pane in the home directory, the `-t` target is not expanded, `duplicate session: <name>` exit 1 |
| Before the runs | `iterm2 status`; `ps -M -p <iTerm2 pid> \| wc -l`; `iterm2 list-connections`; `discover --local`; `discover --ssh saturno-m4`; `ls` of the launch directory | `status` exit 0 (protocol 1.21); 15 lines; 0 connections; both hosts `noServer`; launch directory empty |
| `e2e-local`, run 1 | `env -u TMUX_TMPDIR .build/debug/muxfinder-probe e2e-local` | exit 0, 15 of 15 steps PASS in 53.2 s. Steps 1–9 as before (focus existing 92 ms, detach by session 9.6 s); 10 vanished session 105 ms (`sessionGone` from revalidation 38 ms after the call, 1 session listed before and after); 11 collision 26 ms; 12 invalid name 3 ms (5 names, 0 processes); 13 missing directory 21 ms; 14 new session 10.7 s (the pane in the private directory with spaces, Unicode and `#`; detached cleanly, then killed); 15 cleanup |
| `e2e-remote`, run 2 | `env -u TMUX_TMPDIR .build/debug/muxfinder-probe e2e-remote saturno-m4` | exit 0, 16 of 16 steps PASS in 105.1 s. Steps 1–10 as in Phase 5b (still waiting: `stillWaiting` at 21.0 s, the attach ended 5.2 s after the forced close); 11 vanished session 5.6 s (`sessionGone` 695 ms after the call); 12 collision 3.5 s; 13 invalid name 0.7 s; 14 missing directory 3.0 s (`~/<name>-missing ünïcödé 日本`); 15 new session 14.3 s (the attach after creation: launched 868 ms, confirmed 1.81 s, activated 2.09 s into it; the pane in `~/Library/Application Support`); 16 cleanup |
| iTerm2's workers after run 2 | `ps -M -p <iTerm2 pid> \| wc -l`; `sample <iTerm2 pid> 3` (read-only, stack frames only) | 28 lines after run 1 (27 a few minutes later), 38 after run 2; 23 GCD worker threads blocked in AppKit's `-[NSAnimation _runBlocking]`, the frames of the Phase 5b stall (which came at 64, the pool's limit), with the API still answering. Real runs paused; about four minutes later the count was back at 15 |
| `e2e-local`, run 3 | the same command, final tree, the count back at 15 | exit 0, 15 of 15 steps PASS in 53.6 s; 10 vanished session 105 ms; 14 new session 10.7 s (`createAndAttach` 377 ms: creation about 16 ms, then the attach launched at 138 ms, confirmed at 359 ms, activated at 360 ms). Afterwards 28 lines, back at 15 about seven minutes later |
| `e2e-remote`, run 4 | `env -u TMUX_TMPDIR .build/debug/muxfinder-probe e2e-remote saturno-m4`, final tree, the count at 15 | exit 0, 16 of 16 steps PASS in 104.0 s; 10 still waiting (`stillWaiting` at 21.0 s, the attach ended 5.2 s after the forced close); 11 vanished session 5.3 s (`sessionGone` 682 ms after the call); 12 collision 3.3 s; 13 invalid name 0.7 s; 14 missing directory 2.7 s; 15 new session 14.1 s (`createAndAttach` 2.65 s: creation over ssh about 0.66 s, then the attach launched at 842 ms, confirmed at 1.73 s, activated at 1.99 s). Afterwards 25 lines |
| After each run | `iterm2 status`; `ps -M`; `discover --local` or `--ssh saturno-m4`; `ls` of the launch directory and of `/private/tmp/mfx.*` | always `status` exit 0; both hosts `noServer`; launch directory empty with no `test-mode` marker; no `/private/tmp/mfx.*`; line counts in the rows above |

Method notes:

- The sessions the runs created ran `sleep 600` (`NewSessionRequest.command`), never a login
  shell, and every one was a `muxfinder-test-<run>…` session killed by id after its identity
  check. Nothing was written on Saturno beyond what tmux itself keeps for its socket; the
  missing directory was never created there. Each run's setup reported 0 tmux connections it
  had not opened.
- The new-session step's timings in runs 1 and 2 are the attach's own (`AttachTimings`,
  counted from the start of the attach that follows creation), although that note called them
  "after the call (creation included)"; from run 3 on the note gives the creation time apart.
- **iTerm2's thread count rises with each run and falls back later:** about 12 lines per run,
  as GCD workers blocked in `-[NSAnimation _runBlocking]`, reclaimed within minutes once the
  runs stop (38 back to 15). In Phase 5b three runs left it at 15–19 lines. The cause is still
  unknown (no UI was touched to find out). Run 3 waited for the count to come back to 15, and
  so did run 4.
- `muxfinder-probe new-session` itself was not run against the real iTerm2: its path is the
  one the e2e steps drive (`createAndAttach` through the standard coordinator), and an
  unattended run would start the user's login shell in its pane.

#### Phase 6a review fixes (2026-10-22)

The fixes for `docs/reviews/phase-6a.md` (PLAN.md D18): the harness kills with the identity
check inside the same tmux command, trailing `;` escaped for tmux's argv parser, and an ssh 255
that cannot be placed before the remote command is `connectionLost` (`mayHaveCreated`). Every
tmux check below ran on a private server (`TMUX_TMPDIR=$(mktemp -d /tmp/mfx.XXXXXX)`,
`/opt/homebrew/bin/tmux -u`, tmux 3.8, `muxfinder-test-*` sessions only), whose directory was
removed afterwards; the default servers were only discovered (both `noServer`).

| Check | Command | Observed result |
|---|---|---|
| Conditional kill | `if-shell -F -t '$N' <condition> "kill-session -t '$N'" "display-message -p mismatch"` against two sessions created in the same second, with each field of the record changed in turn, then exact | each changed field (another session's id, `$99`, creation time, pid, start time, name) printed the marker, exit 0, both sessions left; the exact record killed only its session, exit 0, no output; again: the marker; the server's only session: killed, exit 0, the server exited; no server: exit 1 `no server running on …` (PLAN.md *Verified facts*) |
| The race the fix closes | the old two calls with a restart between them: `display-message -p -t '$0'` (matched), the session killed and the server gone, a new session with the same name, then `kill-session -t '$0'`; then the one-command kill with the old record | the old `kill-session` killed the new server's session (`$0`, same name, creation time and start time; only the pid differed); the one-command kill printed the marker and left the session alone |
| Trailing `;` in argv | `new-session -d -P -c '<dir>/work;'` with `work` and `work;` both existing, with and without `sleep 600`, written raw and as `\;`; `-s 'x;'`, `has-session -t '=x;'`, a lone `;`, `x##;`, `w\;` | raw: the pane in `work` (exit 0), `unknown command: sleep`, `unknown command: -c`, the check looking for `x`; escaped: every value literal (PLAN.md *Verified facts*) |
| `#[` in a name | `new-session -s 'muxfinder-test-##[x]'` | stored `muxfinder-test-##[x]` (tmux keeps `#` runs before `[`); recorded as an open question, not changed |
| Unit tests | `swift test` | exit 0, 457 tests in 46 suites, among them the new private-server tests (`killsOnlyTheRecordedSessionOnAPrivateServer`, `keepsTrailingSemicolonsOnAPrivateServer`). With the script's escaping removed and the old 255 classification and `mayHaveCreated` restored, `keepsTrailingSemicolonsOnAPrivateServer` (a false `has-session` collision), `escapesTrailingSemicolonsForTmux` (both cases), `connectionLossOrASignalMayHaveCreated` (61 issues) and `classifiesFailures` failed; the fix restored, all pass |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0, no output |
| Real runs on the final tree | `env -u TMUX_TMPDIR .build/debug/muxfinder-probe e2e-local`, then `… e2e-remote saturno-m4` | not run: iTerm2's `ps -M` line count stayed at 23 from 14:53 to 15:32 (polled every minute for the 20 minutes the run rules allow), above the 18 they require; a read-only one-second `sample` showed 7 user-interactive GCD workers blocked in `-[NSAnimation _runBlocking]` that were not being reclaimed. `iterm2 status` exit 0 (protocol 1.21); the launch directory was empty; no `/private/tmp/mfx.*` |

### Phase 6b — Move here (2026-10-22)

Environment: Neptuno and Saturno as in Phase 6a, iTerm2 3.7.6 (the same process). Every real
run followed `swift build` and ran with `TMUX_TMPDIR` unset; `iterm2 status` and iTerm2's
`ps -M -p <pid> | wc -l` were read before and after each one. Before the runs no tmux server ran
on Neptuno and the launch directory was empty.

| Check | Command | Observed result |
|---|---|---|
| Plain control client, locally | a private `TMUX_TMPDIR` server under `/tmp` with one `muxfinder-test-*` session: `tmux -u -C attach-session -t '=<name>'` with stdin a FIFO held open, `list-clients`, then a second control client with `attach-session -d`, then the second one's stdin closed; the session killed and the directory removed | the first client was listed with its own pid, control mode 1; the `-d` attach made it print `%exit` and exit 0, leaving only the second client; closing the second one's input also made it print `%exit` and exit 0 |
| Plain control client over ssh | the same on Saturno's default server through `/usr/bin/ssh -o BatchMode=yes -o ConnectTimeout=5 -o ServerAliveInterval=5 -o ServerAliveCountMax=1 -o ControlMaster=no -o ControlPath=none -T`, a `muxfinder-test-exp*` session created and killed by exact name | the remote client was listed (control mode 1); the second client's `-d` made it print `%exit`, and ssh exited 0; stderr empty; no `muxfinder-test-*` session left |
| Before `e2e-local` | `.build/debug/muxfinder-probe iterm2 status`; `ps -M -p <iTerm2 pid> \| wc -l` | exit 0 (protocol 1.21); 25 lines |
| `e2e-local`, run 1 | `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` | exit 0, 16 of 16 steps PASS in 63.2 s. Steps 1–14 as in Phase 6a (attach child of steps 3 and 7: exactly the expected 6 arguments, no `-d`); 15 move here 10.6 s: the refused confirmation ran nothing; the move here was launched at 145 ms and confirmed at 537 ms, its attach child exactly the expected 7 arguments with `attach-session -d`; the plain client (its own pid as tmux's client pid) had printed `%exit` and exited 0 by the time the call returned; 2 s later the session's only client was the launch tab's, its connection still showing the session with both tabs; the detach by connection was clean (launch tab 10.3 s old); 16 cleanup |
| After `e2e-local` | `iterm2 status`; `ps -M`; `ls -A` of the launch directory; `ls -A /private/tmp \| rg '^mfx\.'`; `/opt/homebrew/bin/tmux ls` | exit 0; 42 lines; launch directory empty; no `mfx.*`; no server running |
| `e2e-remote saturno-m4` | not run by the phase worker | the run rules start it only at 38 lines or fewer; the count stayed at 40–41 for about 30 minutes after `e2e-local` (polled read-only), `iterm2 status` exit 0 throughout; left for a later run. `ssh saturno-m4 /opt/homebrew/bin/tmux ls` (read-only): no server running |
| Unit tests | `swift test`, twice | exit 0 both times, 557 tests in 54 suites (23 new in `MoveHereLaunchTests` and `MoveHereCoordinatorTests`) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0, no output |

### Phase 7a — host configuration (2026-10-22)

Read-only commands (PLAN.md D19); neither creates muxFinder's folder or any file, runs ssh or
contacts iTerm2:

- `swift run muxfinder-probe hosts show [--config <path>]` loads the host list and prints the
  file, its state (`saved`, `notSavedYet` with the onboarding defaults, or `invalid` with the
  problem's code and message and the defaults; the file is left as it is), the hosts and This
  Mac's id. `--config` reads another file; its folder must be yours and not a symbolic link
  (`mktemp -d` gives one).
- `swift run muxfinder-probe hosts suggestions` prints `{"suggestions": [ … ]}`, the `Host`
  names from `~/.ssh/config` and its includes. The names are the user's; never paste them into
  docs, fixtures or logs.

Environment: Neptuno, from the repo root after `swift build`, `TMUX_TMPDIR` unset. No iTerm2
window was opened, no tmux connection queried, no ssh run.

| Check | Command | Observed result |
|---|---|---|
| No saved list | `ls -la ~/Library/Application\ Support/muxFinder`; `swift run muxfinder-probe hosts show`; the same `ls` | exit 0; `"state" : "notSavedYet"`, the three onboarding hosts (SSH, empty destination, disabled), no This Mac. The folder listed only `launch/` before and after: no `hosts.json`, no backup, its mtime unchanged |
| Invalid JSON | `mktemp -d /tmp/mfx.XXXXXX`; `printf '{"schemaVersion": 1, "hosts": [' > <dir>/hosts.json`; `chmod 600`; `shasum -a 256` and `ls -lae <dir>`; `.build/debug/muxfinder-probe hosts show --config <dir>/hosts.json`; `shasum` and `ls` again | exit 0; `"state" : "invalid"`, `"problem" : "notJSON"`, `"reason" : "The host list file isn't valid JSON."`, the defaults. The hash (`c008e8ae…92ad`) and the listing (one 31-byte 0600 file, no ACL) were identical after: nothing written, no backup |
| Missing folder | `.build/debug/muxfinder-probe hosts show --config <dir>/missing/hosts.json`; `ls -la <dir>` | exit 0; `notSavedYet`; no `missing` folder created |
| Suggestions | `.build/debug/muxfinder-probe hosts suggestions > <dir>/suggestions.json`, then a count of the array (names not printed) | exit 0; a JSON object whose only key is `suggestions`, one name. `ls -lae ~/.ssh` afterwards: every entry's mtime as before (the config's is months old) |
| Cleanup | `rm -r <dir>` | the private directory removed |
| Unit tests | `swift test` | exit 0, 499 tests in 49 suites (42 new: `HostListTests`, `HostStoreTests`, `SSHConfigSuggestionsTests`) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |

### Phase 7b — refresh engine (2026-10-22)

`muxfinder-probe refresh --once [--config <path>] [--attachments]` (PLAN.md D20) loads the
host list like `hosts show` (read-only; `--config` names the `hosts.json` file, whose folder
must be yours and not a symbolic link), refreshes every enabled host once through a real
`RefreshCoordinator` that is never started (nothing scheduled) and prints JSON: the load
state, the configuration revision, the attachment check, and per host its freshness, last
outcome (`ok`, `noServer` or the failure with its reason), `lastAttempt`, `lastSuccess`,
failure count, node name and sessions. This Mac runs the probe directly; SSH hosts run
discovery's noninteractive ssh (D6). No iTerm2 window opens and nothing is written.

- Without `--attachments` (the default) iTerm2 is never contacted; `attachments.state` is
  `notChecked`.
- `--attachments` adds one attachment check after the round: it sends the read-only identity
  `display-message` to every iTerm2 tmux connection, the user's included, so in unattended
  runs use it only while `iterm2 list-connections` shows none of the user's (the same caution
  as `iterm2 attachments`). Each session then lists its `iTerm2Connections`;
  `attachments.state` is `checked` (with counts), `iTermNotRunning` or `failed` (with the
  error's kind, attachments unknown).

Environment: Neptuno, from the repo root after `swift build`, `TMUX_TMPDIR` unset except
where noted. Saturno (`saturno-m4`) was only discovered; nothing was written on it. No iTerm2
window was opened and no tmux connection queried (`--attachments` was not run).

| Check | Command | Observed result |
|---|---|---|
| Private host list | `mktemp -d /tmp/mfx.XXXXXX`; a schema 1 `hosts.json` (0600) holding This Mac (`local`) and Saturno (`ssh`, `saturno-m4`), both enabled; `.build/debug/muxfinder-probe hosts show --config <dir>/hosts.json` | exit 0; `"state" : "saved"`, both hosts, This Mac's id |
| One refresh round | `swift run muxfinder-probe refresh --once --config <dir>/hosts.json` | exit 0; `saved`, revision 1, attachments `notChecked`; both hosts `live` with outcome `noServer` (no tmux server ran on either Mac), so 0 sessions; `lastAttempt`, `lastSuccess` and the node name set, 0 failures |
| Sessions through the engine | a second `mktemp -d` as a private `TMUX_TMPDIR` with one `muxfinder-test-<8 hex>` session (`tmux -u -f /dev/null new-session -d -s … 'sleep 600'`); `TMUX_TMPDIR=<it> .build/debug/muxfinder-probe refresh --once --config <dir>/hosts.json` | exit 0; This Mac `live`, outcome `ok`, 1 session: the test session, its key carrying This Mac's id and the private socket; Saturno `live`, `noServer` |
| Cleanup | `kill-session -t '=muxfinder-test-…'` on the private server; `rm -r` both folders; `ls -A /private/tmp \| rg '^mfx\.'` | the private server ended with its session (`list-sessions`: no server running); nothing listed |
| Unit tests | `swift test`, repeated | exit 0, 531 tests in 52 suites (26 new in `RefreshCoordinatorTests`, `RefreshScheduleTests`, `RefreshSnapshotTests`). On the final tree 19 of 20 runs passed, 13 of them in a row. The one failure was the existing `doesNotBlockTheMainActor` (fewer than 5 main-actor ticks in 0.9 s) at a load average of about 12. With the new suites skipped, the earlier 505 tests also failed 2 of 20 runs (`doesNotBlockTheMainActor`, `keepsTrailingSemicolonsOnAPrivateServer`). No refresh test failed in 36 full runs |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |

### Phase 8 — menu bar app and popover (2026-10-22)

The app binary runs from the shell only, never through `open` or Finder (LaunchServices would
raise the Automation prompt, PLAN.md *Unattended-run rules*), and no check here opens the real
popover: that needs a click, and UI scripting is never used. The popover's states are shown
by the preview window and covered by the unit tests (PLAN.md D22).

- **Screenshots.** `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures
  --appearance light` (then `dark`) opens one normal window with every state from synthetic
  fixtures, without taking the keyboard focus, and prints `muxFinder preview window <n>
  appearance <a>`. Capture only that window, `screencapture -x -o -l <n>
  docs/screenshots/popover-states-<a>.png`, look at the PNG, then `kill -TERM <pid>` (exit
  0). `screencapture` needs a visible, unlocked screen and Screen Recording permission for
  the terminal; otherwise add `--preview-snapshot <file.png>`: the app draws the window into
  the PNG itself (spinners show as a still frame) and quits with 0. Never capture the screen
  or another app's window, and never change a privacy setting to make a capture work.
- **Shell check.** `build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`;
  after a few seconds the app prints its status-bar-level windows (the menu bar item, one per
  display); `pgrep -P <pid>` lists no child; `kill -TERM <pid>` and `wait` give exit 0;
  `ls -A ~/Library/Application\ Support/muxFinder` still shows no `hosts.json`. On this Mac
  `CGWindowListCopyWindowInfo` lists no window under the app's pid: macOS 27 draws third-party
  menu bar items outside the app (other, older apps' items are still listed at layer 25),
  which is why the app reports its own.

Environment: Neptuno, macOS 27.2, from the repo root. The screen was locked and the display
asleep for the whole run (`CGSessionCopyCurrentDictionary` `CGSSessionScreenIsLocked = 1`,
`CGDisplayIsAsleep` true, both read-only). No hosts are enabled here (no `hosts.json`, so the
onboarding defaults, all off): the real app discovered nothing and contacted no iTerm2.

| Check | Command | Observed result |
|---|---|---|
| Bundle | `scripts/build-app.sh` | exit 0; release `arm64-apple-macosx14.0` (both binaries thin arm64), signed by "Apple Development: Carlos Carpio García (5XHQZ98534)" chosen by hash; not notarized |
| Signature | `codesign --verify --deep --strict --verbose=2 build/muxFinder.app`; `codesign -d --entitlements - build/muxFinder.app`; `codesign -dvv` of the app and of `Contents/MacOS/muxfinder-launch` | exit 0, "valid on disk", "satisfies its Designated Requirement", the helper validated; entitlements exactly `com.apple.security.automation.apple-events = true`; both `flags=0x10000(runtime)` (hardened runtime), team `CXVKS8ZNCD` |
| Info.plist | `plutil -p build/muxFinder.app/Contents/Info.plist` | `CFBundleIdentifier` `cc.carpio.muxfinder`, `CFBundleExecutable` `muxFinder`, `LSUIElement` true, `LSMinimumSystemVersion` `14.0`, `NSAppleEventsUsageDescription` set |
| Screen capture permission | `CGPreflightScreenCaptureAccess()` from a script outside the repo | true |
| `screencapture -l` | the preview window's number from its output line | exit 1, "could not create image from window" (screen locked, display asleep); a ScreenCaptureKit single-window capture of the same window failed with error -3811 |
| Preview screenshots | `muxFinder --preview-fixtures --appearance light --preview-snapshot docs/screenshots/popover-states-light.png`, then `dark` | exit 0 both; 3904×1728 PNGs (1952×864 pt at 2x), ten states each, inspected: every status, the badge, stale rows, progress, a failure with Retry, search with and without matches, both global placeholders, both notices, loading; text readable in both appearances |
| Preview leaves nothing | `ls ~/Library/Preferences ~/Library/Saved\ Application\ State \| rg -i muxfinder`; the support folder | nothing; `launch/` only. An earlier build that hid an un-inserted `MenuBarExtra` in preview mode had made AppKit write `NSStatusItem VisibleCC Item-0 = 0` to the app's own domain (and to `MuxFinderApp` for the unbundled debug binary); both domains were deleted and preview mode now creates no status item |
| Shell check | `muxFinder --report-menu-bar-item &`; after 8 s the window listing, `pgrep -P`; `kill -TERM`; `wait` | 7 status-bar-level windows, all visible: 35×30 pt at y 1698 in the main display's menu bar, one on the second display, the rest parked off screen; `CGWindowListCopyWindowInfo` listed none under the pid; no child process; exit status 0 at once; no muxFinder process left |
| Nothing written | `ls -la` of `~/Library/Application Support/muxFinder` and `launch/` before and after; preferences as above | identical: `launch/` only, empty, mtime unchanged; no `hosts.json`; no preference or saved-state file |
| Unit tests | `swift test`, twice | exit 0 both times: 563 tests in 54 suites (core) and 44 in 3 suites (new `MuxFinderUITests`) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |

### Phase 9a — Settings window (2026-10-22)

No check here opens the real Settings window or popover (that needs a click; UI scripting is
never used), registers or unregisters a login item (that changes the user's login items), or
saves the real `hosts.json`. The window's states are shown by the preview window and covered
by the unit tests (PLAN.md D23); saves are tested through `HostStore` in private temporary
folders only.

- **Screenshots.** As in Phase 8, with `--preview-gallery settings`:
  `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery settings
  --appearance light` (then `dark`) opens one window with every Settings state; capture it
  with `screencapture -x -o -l <n> docs/screenshots/settings-states-<a>.png`, or, when that
  fails, add `--preview-snapshot <file.png>`. Without `--preview-gallery` the window shows the
  popover's states (`popover-states-<a>.png`).
- **Login item status (read-only).** `build/muxFinder.app/Contents/MacOS/muxFinder
  --report-login-item-status` prints `muxFinder login item status: <status> (running from an
  app bundle: yes|no)` and exits 0, before any window, menu bar item, host list or iTerm2
  contact. Reading the status registers nothing.
- **Owed to the user:** the launch-at-login toggle's real round trip (turn it on and off in
  the General tab, from the app installed in `/Applications`, and check System Settings ›
  General › Login Items), the "Open Automation settings" and "Open Login Items settings"
  buttons opening their System Settings panes, the Settings window coming to the front from
  the popover and with ⌘, and the editing keys (⌘C, ⌘V, …) in its fields.

Environment: Neptuno, macOS 27.2, from the repo root. The support folder held only an empty
`launch/` before and after (no `hosts.json`).

| Check | Command | Observed result |
|---|---|---|
| Bundle | `scripts/build-app.sh` | exit 0; signed by the "Apple Development" identity; not notarized |
| Signature | `codesign --verify --deep --strict build/muxFinder.app` | exit 0 |
| `screencapture -l` | the Settings preview window's number from its output line | exit 1, "could not create image from window" (as in Phase 8: the screen could not be captured); the preview then quit on `kill -TERM` with exit 0 |
| Settings screenshots | `muxFinder --preview-fixtures --preview-gallery settings --appearance light --preview-snapshot docs/screenshots/settings-states-light.png`, then `dark` | exit 0 both; 4528×5572 PNGs (2264×2786 pt at 2x), 11 states each, inspected (and cropped with `sips` into `/tmp` to read details): the host list with statuses, the editor with a successful test, every inline validation error, This Mac with its demotion note and a Detect result, "Sign-in needed" with the popover's explanation, the Automation fix-it, the unusable-file banner with Replace and a disabled editor, the examples banner with a new host, the log with the API-disabled explanation, and each launch-at-login state (on, off with an error, needs approval with its fix-it, not found); readable in both appearances |
| Popover screenshots | `muxFinder --preview-fixtures --appearance light --preview-snapshot docs/screenshots/popover-states-light.png`, then `dark` | exit 0 both; 3904×1984 PNGs, ten states, now with "Open Automation settings" on a session failure and "How to turn it on" expanded on the iTerm2-check notice; inspected in both appearances |
| Login item status | `muxFinder --report-login-item-status` | exit 0: `notFound (running from an app bundle: yes)`: the bundle in `build/` is not an installed app, which is what the General tab's `notFound` message says |
| Shell check | `muxFinder --report-menu-bar-item &`; the window listing; `pgrep -P`; `kill -TERM` | 7 status-bar-level windows, all visible; no child process; exit status 0; no muxFinder process left |
| Nothing written | `ls -la` of `~/Library/Application Support/muxFinder` and `launch/`; `ls ~/Library/Preferences ~/Library/Saved\ Application\ State \| rg -i muxfinder` | `launch/` only, empty, mtimes unchanged; no `hosts.json`; no preference or saved-state file |
| Unit tests | `swift test`, twice | exit 0 both times: 569 tests in 55 suites (core) and 76 in 6 suites (UI; 30 new in 3 new suites) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |

### Phase 9b — Onboarding and SSH setup (2026-10-22)

No check here opens the real onboarding window by a click, runs "Set up SSH in iTerm2…" for
real (it opens an iTerm2 tab and an interactive ssh login: owed to a real-run window, Saturno
only, see `muxfinder-probe ssh-setup` above), contacts iTerm2, or saves the real `hosts.json`.
The onboarding states are shown by the preview window and covered by the unit tests (PLAN.md
D24); saves are tested through `HostStore` in private temporary folders only, and the helper's
`ssh-setup` mode through a fake child runner and, in a pseudo-terminal, with a request it
refuses before starting anything.

- **Screenshots.** As in Phase 8, with `--preview-gallery onboarding`:
  `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery
  onboarding --appearance light` (then `dark`) opens one window with every onboarding state,
  each at its full height; capture it with `screencapture -x -o -l <n>
  docs/screenshots/onboarding-states-<a>.png`, or, when that fails, add
  `--preview-snapshot <file.png>`.
- **Shell check.** As in Phase 8. With no `hosts.json` the app now also shows the onboarding
  window at launch (and brings it forward); it must still contact nothing, create no
  `hosts.json`, and exit 0 on `kill -TERM`. Its window can be seen read-only in
  `CGWindowListCopyWindowInfo` under the app's pid (layer 0).
- **Owed to a person:** the onboarding window's buttons and fields by hand (Save hosts writes
  the real `hosts.json`; "Not now"; "Open Settings" after a refused save), "Set up SSH in
  iTerm2…" from the onboarding window, the Settings editor and the popover, and the helper's
  `ssh-setup` tab in a real iTerm2 (the remote shell appears; a failure is explained and held).

Environment: Neptuno, macOS 27.2, from the repo root. The support folder held only an empty
`launch/` before and after (no `hosts.json`).

| Check | Command | Observed result |
|---|---|---|
| Bundle | `scripts/build-app.sh` | exit 0; signed by the "Apple Development" identity; not notarized |
| Signature | `codesign --verify --deep --strict build/muxFinder.app` | exit 0 |
| `screencapture -l` | the onboarding preview window's number from its output line | exit 1, "could not create image from window" (as in Phases 8 and 9a); the preview then quit on `kill -TERM` |
| Onboarding screenshots | `muxFinder --preview-fixtures --preview-gallery onboarding --appearance light --preview-snapshot docs/screenshots/onboarding-states-light.png`, then `dark` | exit 0 both; 6496×2916 PNGs, 7 states each, inspected (a host row cropped with `sips` into `/tmp`): the examples, This Mac chosen with a tab opened, validation errors with a refused "Turned on", a tab opening and one failing with the Python API explanation, saving, a list saved elsewhere with "Open Settings", a failed save; readable in both appearances |
| Popover and Settings screenshots | `--preview-gallery popover` and `settings`, light and dark, with `--preview-snapshot` | exit 0 all four; "Set up SSH in iTerm2 first" under Saturno's sign-in and Sirio's host key problem (Saturno's tab opened), "Set up SSH in iTerm2…" under the editor's destination, and "Set up SSH in iTerm2 first" with its line under a "Sign-in needed" test |
| Shell check | `muxFinder --report-menu-bar-item &`; the window listing; `pgrep -P`; the app's windows read-only; `kill -TERM`; `wait` | 7 status-bar-level windows, all visible; the onboarding window on screen (layer 0); no child process; exit status 0; no muxFinder process left |
| Host list | `swift run muxfinder-probe hosts show` | exit 0; `notSavedYet` with the three examples; the support folder unchanged |
| Nothing written | `ls -AR` of `~/Library/Application Support/muxFinder` before and after; `ls ~/Library/Preferences ~/Library/Saved\ Application\ State \| rg -i muxfinder` | `launch/` only, empty; no `hosts.json`; no preference or saved-state file |
| Unit tests | `swift test`, twice | exit 0 both times: 587 tests in 57 suites (core; 16 new in 2 suites) and 98 in 7 suites (UI; 15 new in 1 suite) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |

### Phase 10a — attach UX in the app (2026-10-22)

Hermetic only: no check here attaches, opens an iTerm2 window or tab, or runs a self-test for
real; those are Phase 10b's. The session actions' states are shown by the preview window and
covered by the unit tests above (PLAN.md D25).

- **Screenshots.** As in Phase 8, with `--preview-gallery attach`:
  `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery attach
  --appearance light` (then `dark`), captured with `screencapture -x -o -l <n>
  docs/screenshots/attach-states-<a>.png`, or with `--preview-snapshot <file.png>` when that
  fails.
- **Self-tests (real runs, Phase 10b).** From the repo root after `scripts/build-app.sh`, with
  `TMUX_TMPDIR` unset, iTerm2 running with its Python API on, and iTerm2's thread count checked
  before and after (`ps -M -p <pid> | wc -l`) as for every real run:
  `build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local` and `--selftest
  new-session-local`. Each prints `setup:` (how many tmux connections it did not open and
  never asks), then `PASS|FAIL <n> <step> (<ms> ms): <detail>` per step and `muxFinder
  self-test <name>: passed (<n> steps)` or `failed` after `cleanup:` lines; exit 0 passed, 1 a
  step failed or the run was interrupted (cleanup ran), 2 unusable arguments, `TMUX_TMPDIR` set
  or the helper missing (nothing contacted). It opens one launch tab (in a new window) and
  its session's tmux tab; since Phase 13c a "launch tab buried" step checks that tab in
  `buried_sessions` and in no tab after the confirmation, and a "launch tab left" step its
  departure by itself after the detach (`attach-local` 8 steps, `new-session-local` 7). It
  creates and kills only its own `muxfinder-test-<hex>` session,
  detaches only with `detach-client` through the core and never closes a tab; SIGTERM or
  SIGINT during the steps clean up and exit 1.
- **Quit leaves work running (Phase 10b).** `build/muxFinder.app/Contents/MacOS/muxFinder
  --selftest attach-local --selftest-keep &` stops after the attachment is confirmed and prints
  `muxFinder self-test keep: session <name> connection <id> gateway <session id>`, the cleanup
  commands and `waiting for SIGTERM (pid <pid>)`. `kill -TERM <pid>` quits through the app's
  normal termination with exit 0; then `/opt/homebrew/bin/tmux -u has-session -t '=<name>'`
  (exit 0) and `swift run muxfinder-probe iterm2 list-connections` (the connection still
  owned by the gateway) show both still there. Clean up with `swift run muxfinder-probe detach
  --connection <id> --gateway <session id>` (it waits until the tab is 10 s old, then sends
  `detach-client`), then `/opt/homebrew/bin/tmux kill-session -t '=<name>'`.

Environment: Neptuno, macOS 27.2, from the repo root. No `hosts.json` (`hosts show`:
`notSavedYet`, every example off).

| Check | Command | Observed result |
|---|---|---|
| Unit tests | `swift test` | exit 0: 589 tests in 58 suites (core; 2 new in 1 suite) and 132 in 11 suites (UI; 4 new suites) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0; exit 0 |
| Attach screenshots | `muxFinder --preview-fixtures --preview-gallery attach --appearance light --preview-snapshot docs/screenshots/attach-states-light.png`, then `dark` | exit 0 both; 3136×3730 PNGs, 15 states and the context menu card, inspected: progress and results, "Still connecting — check the iTerm2 tab" with "Show tab" and its note, every failure with its recoveries and fix-its, Move here, Detach and its problems, the New session panel empty, invalid, creating and after a collision, both banners; readable in both appearances |
| Popover screenshots | `--preview-gallery popover`, light and dark, with `--preview-snapshot` | exit 0 both; 3904×2036 PNGs; the progress card now shows "Still connecting — check the iTerm2 tab" with "Show tab" and a timeout with "Show tab" and "Try again" |
| Self-test usage | `muxFinder --selftest bogus`; `--selftest-keep`; `--selftest`; `env TMUX_TMPDIR=/nonexistent-mfx muxFinder --selftest attach-local` | exit 2 each, with the reason and the usage line; nothing contacted (the first three exit before the app starts, the last before iTerm2 or tmux is touched) |
| Shell check | `muxFinder --report-menu-bar-item &`; after 3.5 s `kill -TERM`; `wait`; `pgrep -P` | 7 status-bar-level windows, all visible; exit status 0; no child process; no `hosts.json` before or after |

### Phase 10b — real self-tests (2026-10-22)

The app's self-tests and the quit-leaves-work-running check, run against the real iTerm2 and
the local tmux, as described in the Phase 10a section above.

Environment: Neptuno, macOS 27.2, iTerm2 3.7.6 (API protocol 1.21), tmux 3.8, from the repo
root, `TMUX_TMPDIR` unset. No `hosts.json` (the self-tests use an in-memory This Mac). No tmux
server running and no iTerm2 tmux connection before the first run, so every run reported
`0 tmux connection(s) this run did not open`. Before each run: `swift build`,
`scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` (exit 0
each), `.build/debug/muxfinder-probe iterm2 status` (exit 0). iTerm2 threads (`ps -M -p <pid>
| wc -l`): 15 before the first run, then 18, 20 and 21 after each check.

| Check | Command | Observed result |
|---|---|---|
| Attach self-test | `env -u TMUX_TMPDIR build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local` | exit 0, `passed (6 steps)`: 1 create session 26 ms; 2 listed as `$0` on This Mac 107 ms; 3 open (5 clicks) 421 ms, confirmed on connection `tmux` with 1 launch for 5 clicks; 4 open again 106 ms, focused the same connection, still 1 launch; 5 detach from this Mac 9.7 s (one attachment, `detach-client`, the session kept running); 6 kill session 46 ms |
| New session self-test | `env -u TMUX_TMPDIR build/muxFinder.app/Contents/MacOS/muxFinder --selftest new-session-local` | exit 0, `passed (5 steps)`: 1 This Mac listed 103 ms; 2 new session 419 ms, created `$0` and confirmed on connection `tmux`; 3 collision 106 ms, refused (`hasSession`) with "Open existing" offered and nothing launched; 4 detach from this Mac 9.8 s; 5 kill session 45 ms |
| Quit leaves work running | `env -u TMUX_TMPDIR build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local --selftest-keep` in the background, then `kill -TERM <pid>` once it printed `waiting for SIGTERM` | steps 1–3 PASS (open confirmed, 1 launch for 5 clicks, 414 ms), then the keep line with the session, connection `tmux` and gateway ids and the two cleanup commands; after SIGTERM the app exited 0 with no child left; `tmux -u has-session -t '=<name>'` exit 0; `muxfinder-probe iterm2 list-connections` still listed connection `tmux` owned by the gateway session |
| Keep-mode cleanup | `.build/debug/muxfinder-probe detach --connection tmux --gateway <session id>`, then `/opt/homebrew/bin/tmux -u kill-session -t '=<name>'` | detach exit 0 after its 10 s wait, `connectionClosed: true` (`clean: false`, as always without `--launch-id`: no helper result is awaited); kill exit 0; `iterm2 list-connections` then showed 0 connections |
| Leftovers | `ls -A` of the launch directory, `ls -A /private/tmp`, `tmux ls` | after the two self-tests: launch directory empty, no `mfx.*`, no tmux server. After the keep-mode check: no tmux server, but one `<launch id>.result.json` in the launch directory — the helper wrote its result when the detach ended tmux, after the app that would have consumed it had quit. That is D14's design (the sweep before the next launch removes results older than 120 s); it holds only the helper's outcome, and was removed by hand so the folder ended empty |

The run made no fix necessary. Still unverified for real: Show tab (a local attach never
reaches "Still connecting"), and the "Set up SSH in iTerm2…" round trip, which needs an
interactive ssh login and is owed to the user (see `PROGRESS.md`).

### Phase 11b — real persistent profile runs (2026-10-23)

The `e2e-profile` harness (PLAN.md D26) against the real iTerm2, locally and on Saturno, with
`profiles hashes` as an independent record around it. Runs 1 and 2 are on the Phase 11a tree:
both failed at step 8, because iTerm2 copies a loaded dynamic profile into its saved `New
Bookmarks` (the diagnosis below; PLAN.md *Verified facts*). The fix: the snapshot leaves out
iTerm2's copies of muxFinder's own profiles and counts them (`excludedMuxFinderEntries`), and
step 13 waits, by 30 s after the removal, for iTerm2 to drop its copy (D26). Runs 3 and 4 are
on the fixed tree. The review of 11b then tightened both after those runs (D26): only a copy
proven to be the run's (its exact GUID, exactly the installer's `muxFinder.json` path, every
key the run wrote unchanged) is left out, a baseline holding a copy is waited for (5 s) or
refused, and step 13's deadline is absolute from the removal, each export and pause capped
to it. Runs 5 and 6 ran that tightened rule on the final tree, locally and on Saturno, and
passed.

Procedure, kept for a rerun. Use the same rules as every real run: from a shell inside
iTerm2, `TMUX_TMPDIR` unset, after `swift build` (iTerm2 runs the `muxfinder-launch` next to
the probe), checking `.build/debug/muxfinder-probe iterm2 status` and iTerm2's thread count
(`ps -M -p <pid> | wc -l`) before and after each run and letting the count fall back between
runs; a timeout means a modal iTerm2 dialog or an API stall: stop and report.

1. Preconditions: `ls -A ~/Library/Application\ Support/iTerm2/DynamicProfiles` shows no
   `muxFinder.json` (the run refuses otherwise; never move the user's file in an unattended
   run), `tmux -u has-session -t '=muxfinder-test-profile'` fails locally (and on Saturno over
   BatchMode ssh), and `iterm2 list-connections` shows none of the user's connections or only
   ones the run never asks (it asks only its own tab's).
2. `swift run muxfinder-probe profiles hashes > /tmp/mfx.<run>/hashes-before.json` (read-only)
   as an independent record besides the run's own snapshots.
3. `swift run muxfinder-probe e2e-profile --local`: expect 14 PASS lines — 1 snapshot before (if
   `New Bookmarks` still holds a copy of a muxFinder profile, an earlier run's, the step waits
   up to 5 s for iTerm2 to drop it and notes how long that took, or fails: rerun once
   `profiles hashes` shows `excludedMuxFinderEntries` 0);
   2 create session (`muxfinder-test-profile`, `sleep 600` panes, discovered); 3 install
   profile (`muxFinder.json` with one profile for `muxFinder test <hex>`, the test host list
   and the test-mode marker in the launch directory); 4 profile listed (`ListProfiles` for the
   GUID shows it with its name; note how long iTerm2 took); 5 open tab (`CreateTab` by profile
   name, a new window); 6 connection (owned by that tab; the argv digest exactly `<helper>
   profile <id>`, the child `/opt/homebrew/bin/tmux -u -CC new-session -A -s
   muxfinder-test-profile`); 7 identity (the created session and server, `#{host}` as
   discovery reported); 8 snapshot installed (identical hashes; iTerm2 saves the loaded
   profile into `New Bookmarks`, and that copy, the run's exact `Guid` with a `Dynamic Profile
   Filename` that is exactly the installed `muxFinder.json` and every key the run wrote
   unchanged, is left out of the hash; its note counts the copies left out, expected 1; a
   FAIL on `New Bookmarks` with a note of one more profile hashed means iTerm2's copy did not
   match, so record it); 9 detach (after 10 s; the connection and the tab
   close by themselves, the session survives); 10 kill session; 11 remove profile; 12 profile
   gone; 13 snapshot after (snapshots every 0.5 s until `New Bookmarks` holds no copy of the
   run's profile, by 30 s after the removal, each export capped to what is left, then
   identical hashes; its note says how many ms after the removal iTerm2 dropped the copy; a
   FAIL saying iTerm2 still holds it 30 s after the removal, or that no snapshot ended in
   time, needs no cleanup, the file is gone); 14 cleanup (nothing left). A `FAIL 14 cleanup`
   saying the run's tab may still be attached left that tab and the session on purpose:
   finish with the commands it
   prints (the bound `detach`, then the kill), never by closing the tab. Record the timings
   (iTerm2's drop of its copy included), whether iTerm2 showed any alert (none is expected;
   "Dynamic Profiles Error" would be one), and that no other window or tab changed.
4. `swift run muxfinder-probe e2e-profile --ssh saturno-m4`: the same 14 steps on Saturno (the
   tab's ssh is interactive, key authentication; the child is `/usr/bin/ssh -t -o
   ConnectTimeout=10 -- saturno-m4 <D3 string>`), the run's own tmux calls over BatchMode ssh,
   no file written on Saturno.
5. `swift run muxfinder-probe profiles hashes` again, compared with step 2 (identical, with
   `newBookmarks.excludedMuxFinderEntries` 0 in both), and
   `ls -A` of `DynamicProfiles` and of `~/Library/Application Support/muxFinder/launch/` (no
   `muxFinder.json`, no `profile-test-*.json`, no `test-mode`, no `argv-*`), `tmux ls` locally
   and on Saturno (no `muxfinder-test-profile`).
6. What the steps cannot show by themselves (PLAN.md D26, *Owed to 11b*): a non-modal
   "Dynamic Profiles Error" alert in iTerm2 during the install (only a person looking at
   iTerm2 can tell), and the unknown-parent fallback if a parent is tried (with a synthetic
   parent name, never one of the user's profiles; the harness has no option for it yet).

Environment: Neptuno, macOS 27.2 (build 26B118), iTerm2 3.7.6 (API protocol 1.21), tmux 3.8
on Neptuno and Saturno. iTerm2's thread count: 22 before run 1, then 25, 26, 28 and 30 after
runs 1 to 4, still 30 before run 5, then 34 and 35 after runs 5 and 6 (1–4 per run).

| Check | Command | Observed result |
|---|---|---|
| Before the runs | `iterm2 status`; `iterm2 list-connections`; listings of `DynamicProfiles`, of `~/Library/Application Support/muxFinder` and of `/private/tmp/mfx.*`; tmux on Neptuno and Saturno | connected (protocol 1.21); 0 connections; `DynamicProfiles` empty; muxFinder's folder only `launch/`, empty; no tmux server on either Mac; no `/private/tmp/mfx.*` |
| Hashes, before | `swift run muxfinder-probe profiles hashes` | 0 other `DynamicProfiles` entries; `New Bookmarks` count 13, SHA-256 `9178e053…5d6f` |
| `e2e-profile --local`, runs 1 and 2 (Phase 11a tree) | `swift run muxfinder-probe e2e-profile --local`, twice | exit 1 both times, after 11.0 s and 11.6 s. Steps 1–7 PASS: `ListProfiles` showed the GUID after 213 ms and 408 ms; `CreateTab` by profile name opened a new window; the connection was owned by the tab 210–224 ms after `CreateTab`; iTerm2 split the command into exactly `<helper> profile <id>`, and the helper's child had exactly the expected 7 arguments; the control-mode identity was confirmed. Then `FAIL 8 snapshot installed: iTerm2's other profiles changed: New Bookmarks`, and `PASS 14 cleanup` (`detach-client` through the tab's connection, the session killed, `muxFinder.json` removed) |
| Diagnosis | during run 2, a digest-only comparison of `/usr/bin/defaults export com.googlecode.iterm2 -` (no value read) | while `muxFinder.json` was installed, `New Bookmarks` went from 13 to 14 entries: the new one had a `Guid` with the `muxfinder-persistent-` prefix and a `Dynamic Profile Filename` key (78 keys), and the 13 user entries were byte-identical. Right after the run's removal the copy was still there; seconds later it was gone and the array identical to before. So iTerm2 3.7.6 mirrors loaded dynamic profiles into `New Bookmarks` and drops them after the file goes |
| `e2e-profile --local`, run 3 (fixed tree) | `swift run muxfinder-probe e2e-profile --local` | exit 0, 14 of 14 steps PASS in 11.1 s: 1 snapshot before 159 ms (0 other entries, 13 bookmarks hashed); 2 create session 54 ms; 3 install profile 7 ms (440 bytes); 4 profile listed after 208 ms; 5 open tab 118 ms (a new window); 6 connection 215 ms (owned by the tab 214 ms after `CreateTab`; the command split into exactly `<helper> profile <id>`; the child 7 arguments); 7 identity 0 ms (control-mode attachment confirmed); 8 snapshot installed 23 ms, identical (note: 1 mirrored muxFinder entry left out); 9 detach 10086 ms (the connection closed, the helper ended, the tab closed by itself, the session survived); 10 kill session 4 ms; 11 remove profile 0 ms; 12 profile gone after 205 ms; 13 snapshot after 32 ms, identical, iTerm2's copy gone 238 ms after the removal; 14 cleanup, nothing left |
| `e2e-profile --ssh saturno-m4`, run 4 (fixed tree) | `swift run muxfinder-probe e2e-profile --ssh saturno-m4` | exit 0, 14 of 14 steps PASS in 16.1 s: 1 snapshot before 918 ms; 2 create session 1474 ms; 3 install profile 10 ms (440 bytes); 4 profile listed after 629 ms; 5 open tab 142 ms (a new window); 6 connection 870 ms (owned by the tab 869 ms after `CreateTab`; split exactly; the child 7 arguments); 7 identity 76 ms (confirmed); 8 snapshot installed 40 ms, identical (1 mirrored entry left out); 9 detach 10303 ms (as in run 3: the connection closed, the helper ended, the tab closed by itself, the session survived); 10 kill session 691 ms; 11 remove profile 0 ms; 12 profile gone after 204 ms; 13 snapshot after 61 ms, identical, the copy gone 266 ms after the removal; 14 cleanup, nothing left |
| `e2e-profile --local`, run 5 (final tree, after the review fixes) | `.build/debug/muxfinder-probe e2e-profile --local`, iTerm2 at 30 threads | exit 0, 14 of 14 steps PASS in 11.4 s: 1 snapshot before 155 ms; 2 create session 55 ms; 3 install profile 5 ms (440 bytes); 4 profile listed after 417 ms; 5 open tab 134 ms (a new window); 6 connection 226 ms (owned by the tab 226 ms after `CreateTab`; split exactly; the child 7 arguments); 7 identity 1 ms (confirmed); 8 snapshot installed 27 ms, identical, iTerm2's copy recognized by the strict rule (exact GUID, exact path, every written key unchanged) and left out; 9 detach 10135 ms (as in run 3); 10 kill session 5 ms; 11 remove profile 0 ms; 12 profile gone after 210 ms; 13 snapshot after 32 ms, identical, the copy gone 243 ms after the removal; 14 cleanup, nothing left. iTerm2 then at 34 threads |
| `e2e-profile --ssh saturno-m4`, run 6 (final tree) | `.build/debug/muxfinder-probe e2e-profile --ssh saturno-m4` | exit 0, 14 of 14 steps PASS in 15.8 s: 1 snapshot before 904 ms; 2 create session 1439 ms; 3 install profile 8 ms; 4 profile listed after 212 ms; 5 open tab 153 ms (a new window); 6 connection 866 ms (owned by the tab 865 ms after `CreateTab`; split exactly; the child 7 arguments); 7 identity 74 ms (confirmed); 8 snapshot installed 43 ms, identical (the copy left out by the strict rule); 9 detach 10504 ms (as in run 3); 10 kill session 700 ms; 11 remove profile 1 ms; 12 profile gone after 206 ms; 13 snapshot after 38 ms, identical, the copy gone 245 ms after the removal; 14 cleanup, nothing left. iTerm2 then at 35 threads |
| Hashes, after all runs | `swift run muxfinder-probe profiles hashes` (again after runs 5 and 6) | identical to before: the same entries (none), `New Bookmarks` count 13 with the same SHA-256, `excludedMuxFinderEntries` 0 |
| Leftovers after all runs | `iterm2 status`; `iterm2 list-connections`; listings of `DynamicProfiles`, of the launch folder and of muxFinder's folder; `tmux ls` on Neptuno and Saturno | connected; 0 connections; `DynamicProfiles` empty; the launch folder empty; muxFinder's folder holds `launch/` and `profiles.lock` (D26: the lock file is never removed); `no server running` on either Mac; no file written on Saturno |

Still unverified (PLAN.md D26):

- The dot-file skip is seen only indirectly: no stray profile, no failure, and the API
  answered throughout. Whether iTerm2 showed a non-modal "Dynamic Profiles Error" alert while
  the hidden temporary file existed cannot be seen by an unattended run (no screen capture of
  iTerm2 is allowed), so a person's glance at iTerm2 during a run is still owed.
- The unknown-parent fallback was not tried for real: the harness installs a profile without
  a parent, and a try needs a synthetic parent name and a harness option.
- `new-session -A -s muxfinder-test-profile` attached the run's existing session by its exact
  name on both hosts. A name tmux could read as another target (a leading `$ = @ % ! ~ { + ^`)
  stays untried on a server; validation refuses such names.
- A login shell ending by itself within 3 s, beyond the helper's hold, was not exercised: the
  runs never reach the login-shell fallback.

### Phase 11c — Settings section and the rewrite at launch (2026-10-23)

Hermetic only: no check here contacts iTerm2, opens the real Settings window (that needs a
click; UI scripting is never used), writes in iTerm2's `DynamicProfiles` folder, or reads or
writes the real `hosts.json` (there is none on Neptuno). The new controls, the Persistent
profiles tab and the rewrite at launch are covered by the unit tests above (fakes, and the real
seam over private folders only) and shown by the preview window (PLAN.md D26).

- **Owed to the user:** "Install profiles" and "Remove profiles" for real from the app in
  `/Applications` (the profiles appear in iTerm2's Settings › Profiles and go again), making a
  persistent profile the default and opening a tab with it, a second tab of the same profile
  (the copy's "may show its windows a second time" is untried), and a launch after moving the
  app with the profiles installed (the file follows the new helper path).

Environment: Neptuno, macOS 27.2, from the repo root. The support folder held only an empty
`launch/` and the empty `profiles.lock` of Phase 11b before and after (no `hosts.json`).

| Check | Command | Observed result |
|---|---|---|
| iTerm2's profiles before and after | `swift run muxfinder-probe profiles hashes`; `ls -A ~/Library/Application\ Support/iTerm2/DynamicProfiles/` | identical output at the start and the end: no `DynamicProfiles` entry, `New Bookmarks` 13 entries, `sha256` `9178e053…3ef5d6f`, `excludedMuxFinderEntries` 0; the folder empty both times (no `muxFinder.json`) |
| Unit tests | `swift test` | exit 0: 672 tests in 66 suites (core) and 158 in 13 suites (UI) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Settings screenshots | `muxFinder --preview-fixtures --preview-gallery settings --appearance light --preview-snapshot docs/screenshots/settings-states-light.png`, then `dark` | exit 0 both; 4528×7920 PNGs, 16 states, inspected (cropped with `sips` into `/tmp`): the persistent profile fields with the `$work` error and Save off, and the Persistent profiles tab not installed (with the unsaved-changes note), installed after an install, out of date after a busy failure, and unavailable (unsafe helper path, Remove still on, the launch failure line), each with the copy; readable in both appearances |
| Shell check | `muxFinder --report-menu-bar-item` in the background; `pgrep -P`; `kill -TERM` | 7 status-bar-level windows, all visible; no child process; exit status 0; nothing written to the support folder (no `hosts.json`) |

### Phase 12a — scripts and documents (2026-10-23)

Hermetic only: nothing here contacts iTerm2, runs ssh, or touches the real `/Applications`,
`~/Applications`, iTerm2's `DynamicProfiles`, `~/Library/Application Support/muxFinder` or the
app's preferences domain. The app binary ran only in its `--remove-persistent-profiles` mode,
on private folders.

- **The scripts' check.** `scripts/dev/test-install-scripts.sh` (after `scripts/build-app.sh`
  on the current tree) runs `scripts/install.sh` and `scripts/uninstall.sh` in test mode only
  (`MUXFINDER_TEST_HOME` and `MUXFINDER_TEST_APPLICATIONS` set to private folders under one
  `mktemp -d /tmp/mfx.XXXXXX`, used by its physical path `/private/tmp/mfx.…`, removed at the
  end) and prints one `PASS`/`FAIL` line per step:
  install into the Applications stand-in (complete, signature verifies, no temporary folder
  left, no `~/Applications` created); a reinstall (a new folder that verifies); `--dry-run`
  over a copy and `--user --dry-run` on empty folders (recursive listings identical); `--user`;
  refusals with nothing changed (no built app, saying to run `build-app.sh`; another app's
  bundle id at the destination; a symbolic link there); a running copy (only that copy's
  `muxFinder` stub gets SIGTERM and quits, its `muxfinder-launch` stub and a stub of another
  copy keep running); a copy that ignores SIGTERM (refused after the shortened wait, nothing
  changed); uninstall `--dry-run` (listings identical); uninstall of two real copies with a
  generated `muxFinder.json` (removed through the copy's binary), the user's other
  `DynamicProfiles` entries (listing and SHA-256 unchanged), the support folder removed, no
  preferences touched, the `tccutil` command printed; a `muxFinder.json` of the user's left
  byte for byte (exit 0); a symbolic link as support folder refused, its target unchanged (exit
  1); only the removed copy's `muxFinder` stopped, its helper left running and another copy's
  process named in a warning; a copy that does not quit (nothing removed); a copy without the
  `MuxFinderScriptInterface` key (the profile file left and named, exit 1); processes that
  only map a copy's `muxFinder` (a reader stub, and one whose argv[0] names the copy): install
  and uninstall never signal them and proceed (exit 0, the readers alive, no "stopping" line,
  no warning for a reader of another copy); a reader whose own executable was deleted (its
  executable cannot be established): never signalled, the install refused after the shortened
  wait with "could not tell", nothing changed (exit 1); the swap hook (`MUXFINDER_TEST_SWAP_AT`
  and `MUXFINDER_TEST_SWAP_WITH`) exchanging the inspected place with a different folder after
  the check, for the install's copy, an uninstalled copy and the support folder: each time the
  different folder is found at that place byte for byte (relative recursive listing and
  SHA-256 of its files), no hidden folder is left, and the run exits 1; the test-mode guard
  (one variable alone, or the real home, exit 2, both as dry runs; the real `~/Applications`,
  `/Applications`, `~/Library`, a path through a link into the real home, a link to the real
  `~/Applications`, and a folder others may write, each exit 2 as `install.sh --dry-run` with
  no "Would" line, the real locations' listing and `~/Applications` unchanged; a home stand-in
  whose `Applications` and `Library` are links to a private decoy outside it, real runs of
  `install.sh --user` and `uninstall.sh`, both exit 2 with the decoy and the stand-ins
  unchanged; the swap hook outside test mode refused by the library's own check, nothing
  run); and last, the real locations' listing compared with the one taken before the first
  step. Exit 0 only when all pass.
- **Stubs.** A running copy is a small C program compiled by the check (`cc`) and copied into
  a fake bundle as `muxFinder` and `muxfinder-launch`: on macOS 27.2 a copy of `/bin/sleep`
  run from another path is killed with SIGKILL at once (exit 137), so it cannot stand in. Its
  `map <file> <ready>` mode maps a file read-only and then creates the ready file, standing in
  for a Spotlight, QuickLook or backup reader.
- **Matching processes.** `lsof -d txt` lists every file a process maps, not only its
  executable (the review reproduced a reader mapping the bundled `muxFinder` being picked),
  and `ps -o comm` prints argv[0] (`./muxFinder` for a relative start, any text with `exec
  -a`). So `lsof` (`0x…` device, as `stat -f %d` gives in hex, and inode) only finds the
  candidates, and each candidate's executable is read with `codesign -dv <pid>`
  (`Executable=`, from `proc_pidpath`). Checked with stubs: an absolute start, a relative
  start, a start through a symbolic link and a reader with a forged argv[0] naming the copy
  gave their true executables (`/private/tmp/…`), a helper in a bundle its own path, a process
  whose executable was deleted and a dead pid failed (`No such file or directory`, `No such
  process`); `ps -o comm` gave the forged path for the reader. One `codesign` call takes about
  9 ms; a scan of every process of the user about 0.35 s.
- **Regressions against the reverted fixes.** Each fix was reverted in the working tree
  (every `lsof` match counted as running again; the old root guard, which refused only `/`,
  the real home and `/Applications`, with no containment check; no comparison of the moved
  entry with the inspected one), the check run, and the fix restored (`cmp` with a copy of the
  fixed file): steps 25 to 27, 32 and 33, and 28 to 30 failed respectively, every other step
  passed, the last step included (the real locations untouched).

Environment: Neptuno, macOS 27.2, from the repo root; no `hosts.json`; the support folder held
`launch/` (empty) and `profiles.lock` before and after.

| Check | Command | Observed result |
|---|---|---|
| iTerm2's profiles, before | `.build/debug/muxfinder-probe profiles hashes` | exit 0: no other `DynamicProfiles` entry; `New Bookmarks` 13 entries, `sha256` `9178e053…3ef5d6f`, `excludedMuxFinderEntries` 0 |
| Removal flag, private folders | `build/muxFinder.app/Contents/MacOS/muxFinder --remove-persistent-profiles [--dry-run] --profiles-directory <tmp>/DP --lock-directory <tmp>/mf` over a generated `muxFinder.json`; then `muxFinder --dry-run` | dry run: `muxFinder persistent profiles: would remove <tmp>/DP/muxFinder.json (muxFinder's generated file)`, exit 0, no lock folder created; real: `… removed <tmp>/DP/muxFinder.json`, exit 0, `<tmp>/mf/profiles.lock` made; `--dry-run` alone: the usage error and both usage lines, exit 2 |
| Unit tests | `swift test` with `pipefail`, three times | exit 0 each: 680 tests in 67 suites (core; 8 new in `PersistentProfileRemovalTests`) and 159 in 13 suites (UI; `profileRemovalOptions` new) |
| Build and lint | `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests` | exit 0; exit 0; exit 0, no output |
| Scripts | `bash -n` on `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/lib/app-copies.sh`, `scripts/dev/test-install-scripts.sh`, `scripts/build-app.sh` | exit 0 each; `shellcheck` is not installed on this Mac, so it was not run |
| Scripts' check | `scripts/dev/test-install-scripts.sh`, twice on the final scripts (after the review fixes) | exit 0 both, `passed (35 steps)`, about 62 s each |
| Reverted fixes | the same check with each fix reverted in turn, then restored | exit 1 each: `failed (3 of 35 steps)` (25–27), `failed (2 of 35 steps)` (32, 33), `failed (3 of 35 steps)` (28–30) |
| Clean build | `rm -rf build && scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, "signed with: Apple Development: …; not notarized", `MuxFinderScriptInterface` 1 in the Info.plist; exit 0 |
| After | `profiles hashes` again (compared with `diff`); `ls` of `/Applications/muxFinder.app`, `~/Applications/muxFinder.app`, `DynamicProfiles`, the support folder; `defaults read cc.carpio.muxfinder`; `ls -A /private/tmp \| rg '^mfx'`; `ps` | hashes identical; neither app copy exists; `DynamicProfiles` empty; the support folder `launch/` (empty) and `profiles.lock`; the domain does not exist; no `/private/tmp/mfx.*` folder left by the check; no stub or muxFinder process |

Owed to the user: a real install into `/Applications` and a real uninstall
(`docs/MANUAL-CHECKLIST.md`, items 1 and 13).

### Phase 12b — acceptance run (2026-10-23)

The fresh run of PLAN.md's Phase 12b on the final tree (commit 520b7e3, the Phase 12a tree,
clean and unchanged throughout), recorded in the matrix's "12b fresh run" column above. Every
check exited 0, and the tree needed no change.

Environment: Neptuno, macOS 27.2, iTerm2 3.7.6, tmux 3.8, from the repo root. Every real run
had `TMUX_TMPDIR` unset, ran one at a time and only with iTerm2 at 38 threads or lower. The
hermetic checks and `e2e-local` ran at about 05:05; the other real runs between 07:49 and
08:00, each gated before and after: `iterm2 status` connected, iTerm2's thread count read
(read-only), leftovers checked. iTerm2's thread count (`ps -M -p <pid> | wc -l`): 33
before `e2e-local`, 49 after it; then 48–50 until 07:47 and 16 at 07:48, in one step, about
2 h 40 min after the run (the same iTerm2 process, no restart). During the later runs, in
order: 16, 17, 19, 18, 18, 18, 17.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build -Xswiftc -warnings-as-errors` | exit 0 |
| Unit tests | `swift test` | exit 0: 680 tests in 67 suites (core) and 159 in 13 suites (UI) |
| Format lint | `swift format lint -r Sources Tests` | exit 0 |
| Clean build | `rm -rf build && scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Scripts' check | `scripts/dev/test-install-scripts.sh` | exit 0, 35 of 35 steps PASS |
| `e2e-local` | `swift run muxfinder-probe e2e-local`, run as the built `.build/debug/muxfinder-probe e2e-local` right after `swift build`, `TMUX_TMPDIR` unset, iTerm2 at 33 threads, at about 05:05 | exit 0, 16 of 16 steps PASS in 63.4 s. iTerm2 then at 49 threads |
| Leftovers after `e2e-local` | listings of the launch directory and of `DynamicProfiles/`; the tmux sessions on Neptuno | the launch directory and `DynamicProfiles/` empty; no `muxfinder-test-*` session |
| `e2e-remote` | `swift run muxfinder-probe e2e-remote saturno-m4`, run as the built `.build/debug/muxfinder-probe e2e-remote saturno-m4` | exit 0, 17 of 17 steps PASS in 121.8 s; step 10 still waiting published `stillWaiting` at 21.1 s (20 s budget) with no login attempted; step 16 move here PASS. No `muxfinder-test-*` session left on Saturno; the launch directory empty |
| `e2e-profile`, locally | `swift run muxfinder-probe e2e-profile --local` | exit 0, 14 of 14 steps PASS in 11.3 s; the snapshots before install, after install and after removal identical (0 other `DynamicProfiles` entries, 13 `New Bookmarks` entries hashed); iTerm2's copy gone 256 ms after the removal. `DynamicProfiles/` empty afterwards |
| `e2e-profile`, Saturno | `swift run muxfinder-probe e2e-profile --ssh saturno-m4` | exit 0, 14 of 14 steps PASS in 15.7 s; the same snapshot result; iTerm2's copy gone 260 ms after the removal |
| Attach self-test | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local` | exit 0, passed (6 steps): Open five times confirmed with 1 launch, Open again focused, detach from this Mac, kill |
| New session self-test | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest new-session-local` | exit 0, passed (5 steps): new session confirmed, the same name refused as a collision with "Open existing" offered and nothing launched, detach, kill |
| Quit leaves work running | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local --selftest-keep`, then `kill -TERM <pid>` | steps 1–3 PASS and the keep line printed; after SIGTERM the app exited 0; `tmux has-session -t '=<name>'` exit 0; `iterm2 list-connections` still listed connection `tmux` owned by the test's tab |
| Keep-mode cleanup | `.build/debug/muxfinder-probe detach --connection tmux --gateway <session id>`, then `tmux -u kill-session -t '=<name>'` | detach exit 0, `connectionClosed: true` (`clean: false`, as always without `--launch-id`); kill exit 0; then 0 connections. The helper's `<launch id>.result.json` stays in the launch directory for the next launch's sweep (D14, results older than 120 s), as in Phase 10b |
| After all runs | `muxfinder-probe profiles hashes`, compared with the one taken before the first real run; tmux on Neptuno and Saturno; `/private/tmp` | hashes byte-identical; no tmux server left on either Mac; no new `mfx.*` folder |

### D28 — app icon, menu bar icon and release signing (2026-10-23)

The menu bar icon and the app icon (PLAN.md D28) were installed and the release flow written.
The rows down to "Review" ran before `scripts/dev/icon/plate.png` (the painted background)
was added, when `AppIcon.icns` used `BRIEF.md`'s gradient at every size; the rows after it
ran with the plate, ending with one real `scripts/release.sh`.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build -Xswiftc -warnings-as-errors` | exit 0 |
| Unit tests | `swift test` | exit 0: 680 tests in 67 suites (core) and 162 in 14 suites (UI; the 3 new ones are `MenuBarIconTests`: the committed PNGs are 18/36/54 px, black wherever not transparent, 37–41 % covered, outer ring empty; a bundle with them gives one 18 pt template image with representations 18, 36, 54 px; without them, nil and the fallback symbol exists) |
| Format lint | `swift format lint -r Sources Tests` | exit 0 |
| Icon regeneration | `scripts/dev/icon/build-icon.sh` twice, outputs compared with `cmp` | exit 0 (warns: no `plate.png`); all four files byte-identical between the runs; the renderer compiles in Swift 6 mode; its output identical to the reviewed scratch renderer at 16, 18, 24, 36, 48, 54, 72 and 1024 px |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict --verbose=2 build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; `Contents/Resources` holds `AppIcon.icns` and `MenuBarIcon.png`, `@2x`, `@3x`; `CFBundleIconFile` = `AppIcon`; "valid on disk", "satisfies its Designated Requirement" |
| Usage refusal | `scripts/build-app.sh --bogus` | exit 2, usage line |
| Release signing | `scripts/build-app.sh --release`, then `codesign -dvv` of the app and the helper and `codesign -d --entitlements -` | exit 0, both signed by "Developer ID Application: … (CXVKS8ZNCD)" with a secure timestamp and `flags=0x10000(runtime)`; entitlements only `com.apple.security.automation.apple-events`; verify exit 0. The development build was rebuilt afterwards |
| Release refusals | `MUXFINDER_NOTARY_PROFILE=muxfinder-no-such-profile scripts/release.sh`; `scripts/release.sh extra-argument` | exit 1 before building, naming the profile and how to create it; exit 2, usage line. Nothing uploaded |
| Menu bar item | the app shell check (`--report-menu-bar-item`, then SIGTERM) on this build and on a scratch copy of the tree with only the old `MenuBarExtra("muxFinder", systemImage: "terminal")` restored | both: 7 item windows (two displays), each 34 × 30 pt (new) and 35 × 30 pt (old), so one icon-only item either way; exit 0 after SIGTERM, no process left, no `hosts.json` created |
| Notarization line of `install.sh` | `mf_notarization_summary` from `scripts/lib/app-copies.sh` on the development build, a missing path, and in test mode | "not notarized" (`spctl`: rejected), "notarization unknown", "notarization not checked in test mode" |
| Scripts' check | `scripts/dev/test-install-scripts.sh` | exit 0, 35 of 35 steps PASS |
| Review | Codex, read-only, over the whole change | no P0/P1; fixed: `install.sh`'s `spctl` call is now bounded (10 s), skipped in test mode, and tells "unknown" from "not notarized"; the icon renderers compile with `-swift-version 6`; the identity lookup's `awk` reads to the end so `security` cannot get SIGPIPE under `pipefail` |
| Plate | `sips -g format -g pixelWidth -g pixelHeight -g hasAlpha` on the ChatGPT image; looked at; average colours of its top and bottom tenths | PNG, 1024 × 1024, no alpha: nothing to fix; full-bleed, no rounded corners, frame or symbol. Top `#1D3A6D`, bottom `#071533` (the prompt asked for `#1E2F57` → `#0A1024`), so `BRIEF.md`'s `bg-start`/`bg-end` were set to the measured colours and the 16/32 px gradient matches the painting |
| Icon with the plate | `scripts/dev/icon/build-icon.sh` | exit 0, no warning; `AppIcon.icns` changed; the three menu bar PNGs byte-identical to the previous ones |
| Release | `scripts/release.sh` (one real run, 10:34–10:36) | exit 0: profile check passed; built and signed by "Developer ID Application: … (CXVKS8ZNCD)", timestamp 10:34:59, verify passed; notarization submission `f2a44f4a-ea99-40ca-9f7d-e1dc734c6fd9` Accepted ("Ready for distribution", `issues: null`, ticket covering both executables); stapled on the first attempt and validated; `spctl`: "accepted, source=Notarized Developer ID"; `build/muxFinder.zip` written (4.9 MB) |
| Release zip | `ditto -x -k build/muxFinder.zip <scratch folder>`, then `codesign --verify --deep --strict`, `xcrun stapler validate`, `spctl --assess --type execute -vv` on the extracted app | exit 0 each; "The validate action worked!"; "accepted, source=Notarized Developer ID" |
| Notarization line of `install.sh`, notarized | `mf_notarization_summary build/muxFinder.app` (real mode) after the release | "notarized" |

### Phase 13a — the bury spike (2026-10-24)

`muxfinder-probe e2e-bury` (PLAN.md Phase 13a) against the real iTerm2 3.7.6, locally and on
Saturno, each run gated before and after: `iterm2 status` connected, iTerm2's thread count,
no `muxfinder-test-*` session left on either Mac, no tab or buried session of the run in
`iterm2 list-sessions`, the launch directory empty. iTerm2's "Automatically bury the tmux
client session after connecting" setting was on (read only), so the harness buried its own
tab again where the default would have left it buried. The answers to (a)–(e) are in PLAN.md
*Verified facts*, Phase 13a; D29 is written from them.

| Check | Command | Observed result |
|---|---|---|
| Local, run 1 | `swift run muxfinder-probe e2e-bury --local`, `TMUX_TMPDIR` unset, iTerm2 at 16 threads | exit 0, 12 of 12 PASS in 39.1 s. (e): the first restore unanswered, the tab back in a tab only about 2.1 s after the kill, once the explanation ended iTerm2's tmux mode. Fixed in the helper: a line feed before the first restore and a second restore when it goes unanswered (D29). The harness then gained the auto-hide detection, the bury during the hold and the dense sampling |
| Local, runs 2–3 | the same, after the fixes | exit 0, 12 of 12 PASS each (39.4 s, 36.6 s); run 2's order check counted samples after the hold's bury and was bounded before run 3 |
| Local, run 4 (final) | the same | exit 0, 12 of 12 PASS in 39.2 s. iTerm2 at 16 threads before, 17 after |
| Saturno, runs 1–2 | `swift run muxfinder-probe e2e-bury --ssh saturno-m4` (`ssh -G`: no connection sharing, so step 10 killed the local ssh child) | exit 0, 12 of 12 PASS each in 47.8 s (run 2 is the final one). iTerm2 at 17 and 16 threads after |
| Leftovers after every run | `tmux ls` on Neptuno and Saturno; `iterm2 list-sessions` (summary); `ls` of the launch directory; `pgrep -fl muxfinder-launch` | no tmux server on either Mac; 1 window, 1 tab, 0 buried sessions, as before; the launch directory empty; no helper running |
| Hermetic | `swift build`; `swift test`; `swift format lint -r Sources Tests` | exit 0, no warnings; exit 0, 705 tests in 70 suites (core) and 162 in 14 suites (UI); exit 0 |

### Phase 13c — real runs with the launch tab hidden (2026-10-24)

The coordinator's bury (Phase 13b) and the self-tests' new steps against the real iTerm2
3.7.6 and tmux 3.8, locally and on Saturno, one run at a time from the repo root with
`TMUX_TMPDIR` unset. Before each run: `swift build`, `iterm2 status` connected, iTerm2 at 38
threads or fewer, no leftovers. iTerm2 exited between 12:15 and 12:24, not by the run; the
first gate found it not running (`iterm2 status` exit 69) and waited, never launching it. It
came back with the `AutoHideTmuxClientSession` key absent (read only; it read on before the
exit), so every run below had iTerm2's default, auto-hide off; Phase 13a's spike had it on.
iTerm2 buried none of the 20 launch tabs of the four `e2e-bury` runs itself, and step 9's tab
stayed buried at the tmux end without `Disinter`: S5's "off" branch, seen at run time. From
the second `e2e-local` attempt on, one tmux connection of the user's existed; no run asked it
anything. iTerm2's thread
count stayed at 17–23.

| Check | Command | Observed result |
|---|---|---|
| `e2e-local`, attempt 1 | `swift run muxfinder-probe e2e-local` | exit 1, 7 of 16 PASS in 22.4 s: step 7 reattach found 2 argv digests where it expected 1. Since Phase 13a the helper rewrites its digest after each launch tab restore, so step 3's helper rewrote it after step 6's detach, after that step's take. Harness fix: `takeNewArgvDigests()` (`Sources/muxfinder-probe/E2ERun.swift`) leaves out launches a step already checked; then `swift build`, `swift test` (737 tests in 73 suites, core; 166 in 14 suites, UI) and the lint exit 0. Cleanup left nothing of the run but one helper result in the launch directory (later removed by the sweep, D14) |
| `e2e-local`, attempt 2 | the same | exit 0, 16 of 16 PASS in 65.5 s. Every confirmed attach (steps 3, 7, 8, 14, 15) `burial` `buried`, the bury and its check done 449–702 ms after the call (29–31 ms after the activation in steps 3 and 7); after every detach the tab left its tab and `buried_sessions` by itself, 224–241 ms after the helper's result where noted, the tabs 10.3–10.4 s old. Threads 19 → 21 |
| `e2e-remote` | `swift run muxfinder-probe e2e-remote saturno-m4` | exit 0, 17 of 17 PASS in 120.4 s. The bury and its check done 2174–3341 ms after the call (76–105 ms after the activation in steps 3 and 6); the tab left by itself 23–248 ms after the helper's result. Threads 18 → 18 |
| `e2e-bury`, locally | `swift run muxfinder-probe e2e-bury --local` | exit 0, 13 of 13 PASS in 72.3 s (the rerun after the Phase 13c review's harness fix: the first run, 13 of 13 in 72.6 s, had passed step 7 on a bury its ownership check refused, `failed` `tmuxConnectionNotOwned`, since its detach went out first and the bury only after the detach's answer; such a refusal no longer counts, and step 11 now asserts more; then `swift build`, `swift test` (745 tests in 74 suites, core; 166 in 14 suites, UI) and the lint exit 0). Steps 4 and 7 (detach at 5 s): the tab left by itself 5519 and 5053 ms after the helper's result (its 10 s minimum lifetime); step 6 (the coordinator's detach at 10.3 s): 225 ms. Step 7, attempt 1 (the bury and the detach released together, the tab 5.2 s old): the bury answered `OK` 10 ms after the release, the detach's answer and the helper's result at 39 ms, its first restore requested at 40 ms; the coordinator's check after the bury saw tmux had ended and restored the tab (`restoredAfterEnd`, its one restore; the attach returned at 140 ms); the tab left by itself. Step 9: a dead buried session once its helper exited (S4); the coordinator's recovery sent 1 restore and 1 forced `Close`, and it was gone within the 29 s bound; the helper's status reports, with no `Disinter`, answered after 58 and 1008 ms. Step 11 (SIGKILL of the `tmux -CC` child): the helper's result exit 137 `childSignaled`; the connection gone 102 ms after the kill; the helper's first restore unanswered, its second answered after 10 ms; the tab back in a tab 1555 ms after the kill, possibly by the coordinator's recovery (it had sent a restore after the helper's failure result), and in a tab at every look after that until 11.9 s after the kill (the helper's minimum lifetime ended at 9.7 s; 55 looks); the helper alive, waiting for Return; the session alive. Step 12: still in a tab right before the close; `Close` answered OK, the tab gone 25 ms later. Threads 17 → 20 |
| `e2e-bury`, Saturno | `swift run muxfinder-probe e2e-bury --ssh saturno-m4` (`ssh -G`: no connection sharing, so step 11 killed the local ssh child) | exit 0, 13 of 13 PASS in 83.7 s (the rerun after the review fix; the first run, 13 of 13 in 81.5 s, had passed step 7 on an ownership refusal as locally). Steps 4 and 7: left 4829 and 4844 ms after the helper's result; step 6: 0 ms. Step 7, attempt 1 (released together, the tab 5.2 s old): the bury answered `OK` 8 ms after the release and the attach returned at 39 ms with `burial` `buried` (its check saw no result and the connection still owned); the detach answered at 88 ms, the helper's result and its first restore came at 165 ms and undid the bury; the tab left by itself. Step 9: as locally; the status reports with no `Disinter`: two unanswered within 2 s, the last answered after 1341 ms. Step 11: the result exit 137 `childSignaled`; the connection gone 104 ms after the kill; the first restore unanswered, the second answered after 116 ms; the tab back 2127 ms after the kill, possibly by the coordinator's recovery, and in a tab at every later look until 10.9 s after the kill (the minimum lifetime ended at 8.7 s; 55 looks); the helper alive; the session alive. Step 12: gone 25 ms after `Close`. Threads 20 → 17 |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Attach self-test | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local` | exit 0, passed (8 steps) in about 16 s: Open five times confirmed with 1 launch in 623 ms; 4 launch tab buried (`burial` `buried`, listed so when the attach ended); Open again focused; detach from this Mac; 7 launch tab left by itself 106 ms after the detach ended; kill. Threads 18 → 20 |
| New session self-test | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest new-session-local` | exit 0, passed (7 steps) in 11 s: new session confirmed in 526 ms; 3 launch tab buried; the same name refused as a collision with "Open existing" offered; detach; 6 launch tab left 107 ms after the detach ended; kill. Threads 17 → 23 |
| `e2e-profile`, locally | `swift run muxfinder-probe e2e-profile --local` | exit 0, 14 of 14 PASS in 11.3 s, unchanged (its tab is not the coordinator's, so nothing buries it); the snapshots before install, after install and after removal identical (0 other `DynamicProfiles` entries, 13 `New Bookmarks` entries hashed). Threads 18 → 18 |
| Leftovers after every run | `tmux ls` on Neptuno and Saturno; `iterm2 list-sessions` (summary); `ls` of the launch directory, `DynamicProfiles/` and `/private/tmp`; `ps` | no `muxfinder-test-*` session on either Mac; 0 buried sessions and iTerm2's listing as before the run; the launch directory empty (after attempt 1, the one helper result above); no `mfx.*` folder; no `muxFinder.json`; no process of the bundle left after the self-tests |
| After all runs | `muxfinder-probe profiles hashes`, compared with the one taken before the first run | byte-identical |

### Phase 14 — popover readability (2026-10-24)

Hermetic UI work (PLAN.md Phase 14, D22 *Look*): no iTerm2 window was opened and no real run
was needed. The real popover, drawn over the menu bar extra's material, needs a click, so
comparing it with the screenshots is owed to a person (checklist 15). A row with clients is
"attached elsewhere" (green dot) only when this Mac's attachment check worked or found iTerm2
not running (`PopoverContent.knowsWhatIsOpenHere(_:)`); while the check failed or has not
run, the engine clears every attachment, so such a row is attached with its location unknown
(a gray dot in a dashed ring, `attachedUnknownLocation`), on This Mac and SSH hosts alike
(one check covers every host). No row's text ever says "elsewhere". No accessibility label,
value or trait changed (the attach-state indicator is hidden from VoiceOver; the row's value
already says "1 client", "Detached", "Last seen … · not live" or "Open in iTerm2 here"); the
only existing expectation changed is `statusTexts`'s tone for "Unreachable" (`.muted`, was
`.problem`). The first render used the system `windowBackgroundColor` behind the content:
resolved outside a window it is white (`#1E1E1E` dark), but a window draws it 0.925 (0.196
dark, sampled from the PNG), which matched the light header band, so the palette now fixes
the window gray per scheme and every fill above it.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build --build-tests` | exit 0, no warnings, each |
| Unit tests | `swift test` | exit 0: 745 tests in 74 suites (core), 178 in 15 suites (UI; 12 new: `PopoverStyleTests`, 8, with the badge contrast over 2 appearances × 3 rows and every indicator an existing SF Symbol, the location-unknown one never green; `PopoverContentTests.statusTones`, `mutedSections`, `attachStateMapping`, `attachStateFollowsTheAttachmentCheck` over 5 checks (`checked` and `iTermNotRunning`: elsewhere; `failed` with and without an iTerm2 error and `notChecked`: location unknown, on the SSH and the This Mac host; detached and stale unchanged; no row text says "elsewhere"); `failedAttachmentCheck` gained that no row with clients is "elsewhere"; `fixturesCoverEveryState` gained the badge on a selected row, every attach state and a muted host next to an attention one). With the old mapping (clients always "elsewhere") `failedAttachmentCheck`, `attachStateFollowsTheAttachmentCheck` (3 failing checks) and `fixturesCoverEveryState` fail |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Popover screenshots | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --appearance light --preview-snapshot docs/screenshots/popover-states-light.png`, then `dark` | exit 0 both; 4672×2168 PNGs, 11 states in rows of 6 (the new "Selected session open here, offline host" second), inspected: an opaque popover, one bordered box per host with a header band, a leading indicator per row (blue window, green dot, gray ring, dim clock; in "iTerm2 check failed" Saturno's "build-farm", 1 client, the gray dot in a dashed ring, never the green dot) and semibold attached names, white-on-blue "Open in iTerm2 here" on a selected (gray fill, accent outline) and an unselected row, Sirio "Unreachable" muted (hollow dot, gray name, info icon, Retry) next to Saturno "Sign-in needed" in orange, the footer's buttons evenly spaced with "Quit" trailing. "Progress and errors" and "Host problems" scroll inside the 440 pt list, as in the menu bar |
| Attach screenshots | `muxFinder --preview-fixtures --preview-gallery attach --appearance light --preview-snapshot docs/screenshots/attach-states-light.png`, then `dark` | exit 0 both; 3136×4088 PNGs, 15 states and the context menu card, inspected: the same sections and indicators, the badge on "photo-export", red only on failed session actions, the panels on the opaque background |
| Settings screenshots | `muxFinder --preview-fixtures --preview-gallery settings --appearance light --preview-snapshot docs/screenshots/settings-states-light.png`, then `dark` | exit 0 both; 4528×7920 PNGs, regenerated because the Settings host list and "Test connection" share `StatusDot`: Sirio's dot is now the hollow gray ring; nothing else in that window changed |
| Sizing and closing | read from the code | `PopoverView` keeps `.frame(width: 360)` and the measured list height capped at 440 pt; the opaque background is a `.background` behind that frame, so it changes no size; the `MenuBarExtra(.window)` scene and `PopoverWindowBridge` (visibility, keys, Esc closing the window) are unchanged |
| Shell check, safety | `CFFIXED_USER_HOME=<private folder from mktemp -d> .build/debug/muxfinder-probe hosts show`; a scratch program printing `URL.applicationSupportDirectory`, `FileManager.default.homeDirectoryForCurrentUser` and `NSHomeDirectory()` with the same variable | the default `HostStore()` (the app's) read `<folder>/Library/Application Support/muxFinder/hosts.json`: `notSavedYet`, the three onboarding hosts all off; every path under the folder. The user's real `hosts.json` exists now, so the check ran only this way: with no host turned on the engine discovers nothing (no ssh, no tmux), with the popover closed no attachment check runs (D20) so iTerm2 is not contacted, and `--report-menu-bar-item` turns off the profile rewrite (D26) |
| Shell check | `CFFIXED_USER_HOME=<that folder> build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`; after the listing `pgrep -P <pid>`; `kill -TERM <pid>` | 7 status-bar-level windows, all visible, 34 × 30 pt (as in D28's run); no child process; exit 0 after SIGTERM; no copy left. The folder still empty (no `hosts.json` or anything else created); the real `hosts.json` with the same modification time, size and SHA-256 before and after; the user's installed copy, running throughout, untouched |

### Phase I-1a — popover placement diagnostic (2026-10-24)

`--report-popover-placement` (PLAN.md Phase I-1, I-1a; its in-process `performClick(_:)` was
allowed by the orchestrator) ran from the shell on the bundle binary with `CFFIXED_USER_HOME`
set to an empty private folder, never through `open`: twice in full (the second time with the
view trees, the button's click wiring, other processes' status-bar windows and the off-screen
content size added), once interrupted, all three with the screen locked and both displays
asleep (`CGSSessionScreenIsLocked` yes, on console yes, `CGDisplayIsAsleep` true on both);
then, after the review fixes (no click without an action or a menu, exit 4; the popover window
identified explicitly; nonblocking output and a watchdog), twice more by the review-fix
worker, which reported the screen unlocked and both displays awake, the same output both
times; and once more by the orchestrator on the final tree (about 15:25), which reported the
screen locked and both displays asleep again, with the same windows, frames and click wiring,
exit 4, the private home left empty and no process left. The user's installed copy ran
throughout and was not touched.

**Before the fix.** The popover's frame before the fix is **unmeasured**. The only
observation of where it opens is the user's own report of 2026-10-24: at the far right of the
screen; no run saw it. No run can open it within the run rules: the status item's button has
no action and no target, so `performClick(_:)` sends nothing (SwiftUI's `MenuBarExtra` takes
the click some other way) and no popover window was created; the only other ways to open it
in process are SwiftUI's private internals or synthesized mouse events (in process or not),
both outside `CLAUDE.md` and PLAN.md *Unattended-run rules*. The first three runs also had the
screen locked; in the last two, with the screen unlocked, the button still had no action, so
the diagnostic said so and exited 4 ("not openable in process") without clicking. Why it opens at the far right is an inference from
the window frames, not an observation (PLAN.md *Verified facts*, "Phase I-1a placement
diagnostic"): besides the real item's window, AppKit keeps six replica item windows for the
other menu bars whose in-process frames are placeholders; the second display's two sit exactly
at its right edge. A window placed below one of them and kept on screen would open at that
display's far right (where `PopoverPlacement` itself puts x 3784 of 3072–4152), while the
real item's frame would put it under the icon (x 1250–1610 on the main display).

| Item | Measured |
|---|---|
| Displays | screen 0 (main, primary): frame {{0, 0}, {3072, 1728}}, visible {{63, 0}, {3009, 1698}} (Dock at the left), scale 2, menu bar 30 pt, bottom 1698; screen 1 (portrait, right of the main one): frame {{3072, 249}, {1080, 1920}}, visible {{3072, 249}, {1080, 1890}}, scale 2, menu bar 30 pt, bottom 2139. Separate Spaces on; `NSStatusBar.system.thickness` 22; safe area top 0 on both; neither menu bar hidden |
| The status item | length −1 (variable), visible, behavior 6 (removal allowed, termination on removal), no menu. Its only button (`NSStatusBarButton`, 34 × 22 pt, in window 0): action none, target none, cell `NSStatusBarButtonCell`, no menu, no gesture recognizer, key-value observed only for `effectiveAppearance` |
| Window 0, the item | `NSStatusBarWindow`, level 25, 34 × 30 pt at {1413, 1698}, on screen 0 (in its menu bar); the button in screen {{1413, 1702}, {34, 22}}, its middle at x 1430 |
| Windows 1, 2, 5, 6 | replicas (an `NSStatusItemReplicantView` with shadow and image views; each window's status item is another one; no button), 34 × 30 pt at {0, −30}, below the main display's bottom-left corner, on no screen |
| Windows 3, 4 | replicas, 34 × 30 pt at {4152, 2139}: x is screen 1's right edge (3072 + 1080), y its menu bar's bottom; on no screen |
| Other processes' status-bar windows on screen | none listed (Phase 8, also with the screen locked, had listed older apps' items; why none now was not checked), so where the system draws muxFinder's icon could not be compared with window 0 |
| Popover content, off screen | 360 × 168 pt (`PopoverView` in an `NSHostingView` never put in a window; the never-started model's "Loading hosts…" placeholder) |
| `PopoverPlacement` frames for it | at the button: {{1250, 1530}, {360, 168}} on screen 0 (middle 1430, top 1698); anchored at windows 3 and 4: {{3784, 1971}, {360, 168}} on screen 1 (its right edge less 8 pt, top 2139); at windows 1, 2, 5, 6: {{71, 1530}, {360, 168}} on screen 0 (beside the Dock) |
| `performClick(_:)` on the button | first two runs: no new window within 2 s (still the 7 status-bar windows), exit 1 both |
| The runs after the review fixes (the worker's two reported the screen unlocked and both displays awake; the orchestrator's re-run reported it locked and both asleep) | the same displays (visible frame of screen 0 {{62, 0}, {3010, 1698}}, the Dock 1 pt narrower), the same seven windows and frames (window 0 at {1413, 1698}; four replicas at {0, −30}, two at {4152, 2139}), the button's class now reported as `NSKVONotifying_NSStatusBarButton`, the same click wiring (action none, target none, no menu); still no other process's on-screen status-bar window listed (in the runs reported unlocked too, so their absence seems not to be the lock's doing); then "the popover cannot be opened in process: button 0 has no action (target none) and no menu, …; not clicking" and `exit 4`, 3 s after launch, all three runs |

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build --build-tests`; after the review fixes also `swift build --build-tests -Xswiftc -warnings-as-errors` | exit 0, no warnings, each |
| Unit tests | `swift test` | exit 0: 745 tests in 74 suites (core), 194 in 18 suites (UI; 9 new in `PopoverPlacementTests`, 4 in `PopoverWindowIdentificationTests`, 3 in `NonblockingLineWriterTests`, and `onlyNormalModeRewritesAtLaunch` gained the new flag). Each review regression fails with the old code put back (the window predicate; the synchronous write) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Placement diagnostic | `CFFIXED_USER_HOME=<private folder from mktemp -d> build/muxFinder.app/Contents/MacOS/muxFinder --report-popover-placement`, in the background; `pgrep -P <pid>` after 1 s and 3 s; `wait` | first two runs (before the review fixes): the lines above, then "popover window did not appear within 2000 ms", the app's 7 windows and `exit 1`; after the review fixes (two runs): the reason line and exit status 4, nothing clicked; no child process during any run; no copy left |
| Interrupted | the same, `kill -TERM <pid>` after 1 s (before the review fixes) | "interrupted by SIGTERM", exit 3; no copy left |
| Usage | `muxFinder --report-popover-placement --report-menu-bar-item` | exit 2 with the usage lines, before any window |
| Nothing written | `ls -laR` of the private folder after each run; `defaults export cc.carpio.muxfinder -` digested before and after | the folder still empty (no `hosts.json`, no `Library`); the digest unchanged, also for the runs after the review fixes |
| Shell check | `CFFIXED_USER_HOME=<another private folder> build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`; `pgrep -P <pid>`; `kill -TERM <pid>` | the same 7 windows and frames; no child process; exit 0 after SIGTERM; the folder still empty (no `hosts.json`); the same again after the review fixes |

### Phase I-1b — popover under the icon (2026-10-24)

The popover is now muxFinder's own: an `NSStatusItem` and a borderless, non-activating
`NSPanel` placed by `PopoverPlacement` (PLAN.md D30). `--report-popover-placement` ran twice
from the shell on the bundle binary, in the background, each time with `CFFIXED_USER_HOME` set
to a new empty private folder, never through `open`: once on the first complete tree, and once
on the final tree (rebuilt after the panel's root view gained its own size report). **In both
runs the screen was locked and both displays asleep** (`CGSSessionScreenIsLocked` yes, on
console yes, `CGDisplayIsAsleep` true on both). The user's
installed copy ran throughout and was not touched; no iTerm2 window was opened and no `e2e-*`
run or self-test was needed (the attach path is unchanged).

**After the fix.** The button now has muxFinder's action (`pressed:`, target
`StatusItemButton`), so `performClick(_:)` reached `PopoverController.buttonPressed()`; with no
mouse event behind it the controller anchored at the button's rectangle {{1413, 1702},
{34, 22}} on screen 0, as D30's rule says. The panel (`PopoverPanelWindow`, level 101) was
visible 101 ms after the click at {{1250, 1530}, {360, 168}} on screen 0, the same frame once
settled: **its middle x 1430 is the button's 1430 (offset 0, not clamped) and its top 1698 is
the menu bar's bottom 1698 (offset 0)**, within the 2 pt and 1 pt tolerances; the frame equals
`PopoverPlacement`'s and the controller's own, and the content was 360 × 168 (the
never-started model's "Loading hosts…"). The second `performClick(_:)` closed it. The final
tree's run gave the same with the item 1 pt further right (window 0 at {1414, 1698}, the
button {{1414, 1702}, {34, 22}}): the panel at {{1251, 1530}, {360, 168}} after 102 ms, middle
x 1431 on the button's 1431, top 1698 on 1698, both offsets 0, "after-fix check: passed",
exit 0. AppKit still
keeps the six replica windows with placeholder frames (four at {0, −30}, two at {4152, 2139});
nothing read them as an anchor.

**After the review fixes** (the orchestrator, the final tree, one more run the same way, then
the shell check once): this time **the screen was unlocked and both displays awake**, and
screen 1 (the portrait display) was the main one. The real button's window had moved to screen
1's right edge, {4118, 2139} (the button {{4118, 2143}, {34, 22}}, middle x 4135), and the six
replicas stayed where they were (two at {4152, 2139}, four at {0, −30}). The controller anchored
at that button on screen 1 and placed the panel at {{3784, 1971}, {360, 168}}, its right edge
8 pt inside the display's: "panel middle x 3964 minus anchor middle x 4135 = −171 (tolerance
2 pt unless clamped; clamped yes): pass", "panel top 2139 minus menu bar bottom 2139 = 0
(tolerance 1 pt): pass", "after-fix check: passed", exit 0, no child, the private home empty.
So in-process AppKit puts muxFinder's one real button on the main display's menu bar, and on
the portrait display at its right edge; whether the system draws the icon there is still
unchecked (hypothesis (c) of the specification), which is why a real press anchors at the press
when it falls outside that rectangle (D30) and why a click on each display stays checklist 16.
The shell check on the same tree: 7 windows (window 0 at {4118, 2139}), exit 0 after SIGTERM,
no child, its home empty.

**Not measured** (the screen was locked, and no run may click the real icon): the panel never
became key ("key no", occlusion not visible, so the model was told it was hidden right away),
so the search field's focus and the keys are unchecked; a press on the other display's copy of
the icon (anchored at the press by D30's rule), a click after a ⌘-drag, the closing paths
(Esc, a click outside, an app switch) on the real panel and a full-screen Space are owed to a
person (`docs/MANUAL-CHECKLIST.md`, item 16); where the system draws the icon still could not
be compared with window 0 (no other process's status-bar window was listed).

| Item | Measured |
|---|---|
| Displays | as in Phase I-1a: screen 0 frame {{0, 0}, {3072, 1728}}, visible {{62, 0}, {3010, 1698}}, menu bar bottom 1698; screen 1 frame {{3072, 249}, {1080, 1920}}, visible {{3072, 249}, {1080, 1890}}, bottom 2139; both 2x; separate Spaces on |
| The status item | muxFinder's own `NSStatusItem`, reachable from the status-bar windows; length −1, visible, behavior 6 (as the `MenuBarExtra` item's), no menu; its button `NSStatusBarButton` 34 × 22 pt in window 0 at {1413, 1698}, in screen {{1413, 1702}, {34, 22}}; action `pressed:`, target `MuxFinderUI.StatusItemButton`, cell `NSStatusBarButtonCell` |
| Status-bar windows | the same seven as in Phase I-1a, before and with the panel open |
| The panel | `PopoverPanelWindow` (made at launch, so "window existed before the click: yes"), identified by the live popover view, level 101, visible, not key, occlusion not visible, screen 0, frame {{1250, 1530}, {360, 168}} at appearance and settled |
| Controller placement | anchor rect {{1413, 1702}, {34, 22}} from the button, screen 0, frame {{1250, 1530}, {360, 168}} (the panel's: the same) |
| After-fix check | "panel middle x 1430 minus anchor middle x 1430 = 0 (tolerance 2 pt unless clamped; clamped no): pass"; "panel top 1698 minus menu bar bottom 1698 = 0 (tolerance 1 pt): pass"; "after-fix check: passed" |

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` | exit 0: 745 tests in 74 suites (core), 211 in 20 suites (UI; 17 new: 8 in `PopoverAnchoringTests`, 8 in `PopoverControllerTests`, `MenuBarIconTests.statusItemImage`; no existing test changed); after the review fixes (orchestrator, final tree) 745 in 74 suites and 220 in 21 suites (`PopoverHeightLimitTests` and the rapid-press cases) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Placement diagnostic | `CFFIXED_USER_HOME=<private folder from mktemp -d> build/muxFinder.app/Contents/MacOS/muxFinder --report-popover-placement &`, `pgrep -P <pid>` every 0.1 s while it ran, `wait`; twice (the second on the final tree, after `scripts/build-app.sh` and `codesign --verify --deep --strict`, exit 0 both) | the lines above, "popover closed by the second click", exit 0 about 3 s after launch, both runs; no child process in 24 and 22 samples; no copy left |
| Shell check | `CFFIXED_USER_HOME=<another private folder> build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`; `pgrep -P <pid>` every 0.1 s for 3.5 s; `kill -TERM <pid>`; once, on the first complete tree (the final tree changed only the panel's hosted root view) | 7 status-bar-level windows, all visible, 34 × 30 pt, the same frames; no child process; exit 0 after SIGTERM; no copy left |
| Nothing written | `ls -laR` of the three private folders after each run and once more later | all still empty (no `hosts.json`, no `Library`) |

### Phase I-2a — directory store and session start folders (2026-10-24)

The probe now reports each session's start folder in a `path` record that ends at the run's
nonce, and New session records the directories it creates sessions in, in `directories.json`
(PLAN.md D31). The app's UI did not change. The real checks were read-only discovery only:
nothing contacted iTerm2, and no `e2e-*` run or self-test was made here (`--selftest
new-session-local`, whose path now injects an in-memory store, is the orchestrator's). Folders
are the user's data, so the real runs' JSON went straight through `jq` and only counts were
seen and recorded; the private server's paths were synthetic. The real `hosts.json` and
`directories.json` were neither read nor written (stores in tests use private folders).

| Check | Command | Observed result |
|---|---|---|
| Private-server capture | tmux 3.8 with `TMUX_TMPDIR` from `mktemp -d`, `-f /dev/null`, seven `muxfinder-test-*` sessions with synthetic `-c` values (plain, Unicode with `##1` and `;`, a line break before a forged session, status and `end` line, a tab and escape sequence, empty, a C1 control, invalid UTF-8); `.build/debug/muxfinder-probe discover --local --raw`, then `discover --local`; the sessions killed by id | `ok`: 7 sessions, 2 folders kept exactly, 5 dropped, no forged session; the raw report is the fixture `local-session-paths.txt`; afterwards "no server running", the folder removed |
| This Mac | `swift run muxfinder-probe discover --local \| jq -c '{kind, tmux, sessions, withFolder, dropped}'` (counts computed by `jq`) | `ok`, tmux 3.8: 2 sessions, 2 with a folder, 0 dropped, 151 ms |
| Refresh engine | `swift run muxfinder-probe refresh --once --config <private hosts.json with This Mac only, from mktemp -d> \| jq -c '…'` (counts per host) | `saved`, attachments `notChecked` (iTerm2 not contacted): This Mac `ok`, 2 sessions, 2 with a folder; the private folder still held only its `hosts.json` |
| Saturno | `swift run muxfinder-probe discover --ssh saturno-m4 \| jq -c '…'` (the same counts) | `noServer` (no tmux server was running there), tmux 3.8: 0 sessions, 0 dropped, 731 ms. No session was created on Saturno, so a real remote `path` record was not seen; the D3 command string carries it through `/bin/sh`, `/bin/zsh -f` and `/bin/bash` in `ProbeSessionPathTests.remoteCommandStringFramesThePathRecord` |
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` | exit 0: 786 tests in 79 suites (core; 41 new in 5 suites: `ProbeSessionPathTests`, `StartFolderSnapshotTests`, `SessionPathEndToEndTests`, `DirectoryStoreTests`, `DirectoryListsTests`) and 228 in 22 suites (UI; 8 new in `DirectoryRecordingTests`). No existing test changed; the shared fake `tmux` now also prints `path` records when the format asks for them, `ReportBuilder` gained `path(…)` and `AttachHarness.make` optional `directories` and `diagnostics` |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized, no warnings; exit 0 |
| Uninstall | `scripts/uninstall.sh` read (not run) | it removes the whole `~/Library/Application Support/muxFinder` folder, so `directories.json` and its backups go with it; no change |

#### Phase I-2a review fixes (2026-10-24)

Three should-fix findings of `docs/reviews/phase-I-2a.md`, each with regression tests that
were run with the fix taken out again and failed, then passed with it (PLAN.md D31): an
unusable `directories.json` now refuses every change and is left as it is
(`refusesEveryChangeWhileTheFileIsUnusable`, `aRecordingLeavesAnUnusableFileAsItIs`); changes
hold `directories.lock` (`twoStoresNeverLoseEachOthersChanges`,
`aHeldLockMakesAChangeWaitThenGiveUp`); tmux prints a folder over 4,096 bytes as nothing and
discovery's stdout budget is the largest accepted report (`printsNothingForAFolderOverTheLimit`
on a private tmux 3.8 server, `discoversAReportAtTheParsersLimits`,
`theOutputBudgetHoldsTheLargestAcceptedReport`). Nothing contacted iTerm2; the real
`hosts.json` and `directories.json` were neither read nor written.

| Check | Command | Observed result |
|---|---|---|
| tmux bound | private tmux 3.8 server (`TMUX_TMPDIR` from `mktemp -d`, `-f /dev/null`, `muxfinder-test-*` sessions with synthetic `-c` values), `list-sessions -F` with the bounded format | 4,096 bytes printed whole; 4,097 and 9,000 ASCII bytes and 4,097 bytes of two-byte characters printed as nothing; *Verified facts*, Phase I-2a |
| Flake check, before the fixes | `swift test --skip-build --filter boundsAFloodOfTmuxErrors` and `--filter discoversSessionsOnAPrivateServer`, 5 times each; `swift test --skip-build` twice | 5/5 (0.53–0.93 s) and 5/5 (0.25–0.44 s); both full runs exit 0 (228 UI and 786 core tests, about 1 s and 5.2 s) |
| Flake check, after the fixes | the same filters 5 times each; the full suite | 5/5 (0.60–3.14 s) and 5/5 (0.99–6.33 s, the machine busier); exit 0 |
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` | exit 0: 793 core tests in 79 suites (7 new), 229 UI tests in 22 suites (1 new); about 9.6 s. Changed: the store tests that saw an unusable file replaced (now refused), a link at the name (now `fileNotUsable`), and the folder listings (now with `directories.lock`) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Uninstall | `scripts/uninstall.sh` read (not run) | it removes the whole support folder, so `directories.lock` goes with it; no change |

### Phase I-2b — New session's directory list and Settings › Directories (2026-10-24)

New session's Directory field gained its list (Recent, Saved, "Sessions on <host>", "Save this
directory", "Clear recent directories on <host>") drawn inside the popover, its keys, and
Settings gained the Directories tab (PLAN.md D31). The only real run was `--selftest
new-session-local` (its create path is unchanged, but opening its panel now also reads its
in-memory store); no `e2e-*` run was made. The real `hosts.json` and `directories.json` were
neither read nor written; the galleries use synthetic paths only. Figures are for the final tree,
after the review's fixes (Settings Save merged onto the list as it is, the highlight dropped on
a field edit, byte identity for list rows).

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` | exit 0: 795 core tests in 79 suites (2 new in `DirectoryStoreTests`: byte-for-byte equality, the Save merge) and 263 UI tests in 25 suites (34 new in 3 suites: `DirectoryPickerContentTests`, `DirectoryPickerModelTests`, `SettingsDirectoriesTests`). No existing test changed. An earlier full run, while another project's simulator run held the load average near 500, failed only in the private-tmux-server suites (timing); with the load back near 25 every test passed |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery attach\|settings --appearance light\|dark --preview-snapshot <png>`, each image looked at | `attach-states-*.png` 3136 × 5374 px (the four New session list states: three sections with a highlighted recent row and a path shortened in the middle, nothing to pick, saved already, an unusable file), `settings-states-*.png` 4528 × 8740 px (Directories with unsaved changes and an inline issue, and with an unusable file); readable in both appearances. `--preview-snapshot` now sizes the window to the content's natural size first: on this display the taller attach gallery had been shrunk to the screen's height, squeezing its host lists |
| Install scripts | `scripts/dev/test-install-scripts.sh` (after `scripts/build-app.sh`) | exit 0, 35 of 35 PASS. Before that, step 26 ("uninstall: never signalled, and no muxFinder warning for a reader of another copy") failed on every run only because its `log_lacks "also running from"` also matched the warning about the user's own muxFinder running from `/Applications`; the step now checks that no warning names either reader's pid (the warning prints `(pid N)`). With the uninstall script's executable-identity check removed for a moment, step 26 failed again (1 of 35), so the step still catches what it guards. Step 35 (the real folders untouched) can still fail when the user's installed app writes its own `launch/` folder during the run |
| Self-test | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest new-session-local` (`TMUX_TMPDIR` unset; gate: `iterm2 status` connected, iTerm2 17 threads) | exit 0, 7 of 7 PASS; iTerm2 17 → 19 threads; afterwards no `muxfinder-test-*` session, an empty `launch/` folder and no `directories.json` |

### Phase I-3a — session switcher shortcut (2026-10-24)

The shortcut value, `preferences.json`, the Carbon registrar, its lifecycle in normal mode
and the recorder in Settings › General (PLAN.md Phase I-3, D32). The attach path did not
change, so no `e2e-*` run or self-test was made. No hotkey was pressed and no event was
posted (a press is checklist 18's). The real `hosts.json`, `directories.json` and
`preferences.json` were neither read nor written; nothing was written to
`~/Library/Preferences`.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites (20 new in 2 suites: `GlobalShortcutTests`, `PreferencesStoreTests`) and 288 UI tests in 27 suites (25 new in 2 suites: `GlobalShortcutModelTests`, `GlobalShortcutAppTests`). No existing test changed |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Registration, run 1 | `build/muxFinder.app/Contents/MacOS/muxFinder --report-hotkey-registration` (the first tree, which still refused only-⌥ shortcuts) | exit 1: ⌃⌥⇧⌘F19 registered; registered again: taken (`eventHotKeyExistsErr`); unregistered; registered and unregistered again; ⌥F19, ⌥⇧F19, ⌥J and ⌥⇧J all **registered** (`noErr`) where the tree expected a refusal, so macOS 27.2 does not refuse them; nothing left registered. The validation then warns about them instead of refusing them (PLAN.md D32, *Verified facts*) |
| Registration, run 2 | the same, on the final tree | exit 0: `macOS Version 27.2 (Build 26B118)`; the same eight results, each as expected ("registered, as muxFinder only warns about it" for the four ⌥ ones); "8 checks, all as expected; nothing left registered" |
| App shell | `CFFIXED_USER_HOME=$(mktemp -d) build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`, then `kill -TERM` | 7 status-bar windows printed as before (the item at {1520, 1698} and {4152, 2139}, the replicas at {0, −30}); no child process; exit 0; the private home still empty (no `hosts.json`, no `preferences.json`) |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery settings --appearance light\|dark --preview-snapshot <png>`, each image looked at | `settings-states-*.png` 4528 × 10808 px, 23 states: the five new General states (no shortcut, recording with a refusal, the ⌘K warning with "Use it anyway" and "Choose another", ⌃⌥Space set, ⌃⌥K taken with its message) readable in both appearances; the General frames are 420 pt tall (were 330) for the new section |
| Install scripts | `scripts/dev/test-install-scripts.sh` (after `scripts/build-app.sh`) | exit 0, 35 of 35 PASS. `scripts/uninstall.sh` removes the whole support folder (`remove_support_folder`), so `preferences.json` and `preferences.lock` go with it; the script did not change |
| Review fixes | `swift build` (and `-Xswiftc -warnings-as-errors`), `swift test`, `swift format lint -r Sources Tests`, `scripts/build-app.sh`, `codesign --verify --deep --strict build/muxFinder.app` | exit 0 each: 815 core tests in 81 suites and 292 UI tests in 27 suites, 4 of them new (`carbonRegistrarKeepsAFailedUnregistration`, `aFailedUnregistrationKeepsTheHotkey`, `anUnusableFileFoundBySavingCanBeRetried`, `settingsStopsRecordingOnAnotherTab`), each failing with its fix reverted. The Settings gallery's look did not change, so it was not regenerated; no `--report-hotkey-registration` run |

### Phase I-3b — session switcher panel (2026-10-24)

The switcher panel, its content, keys and actions, the visibility rule shared with the popover,
and the hotkey's entry point switched from the interim popover toggle to the switcher (PLAN.md
Phase I-3, D32, D22). The attach path did not change (the switcher calls the popover's Open and
New session), so no `e2e-*` run or self-test was made; `--report-hotkey-registration` was not
run again. No key was pressed, no event was posted and the real switcher panel was never shown
(a press is checklist 18's). The real `hosts.json`, `directories.json` and `preferences.json`
were neither read nor written.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0, no warnings (the UI and app modules rebuilt from touched sources showed none) |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 317 UI tests in 30 suites (25 new in 3 suites: `SwitcherContentTests`, `SwitcherControllerTests`, `SwitcherModelTests`). Three I-3a tests in `GlobalShortcutAppTests` asserted the interim popover toggle the plan replaces and now assert the switcher: `thePressReachesTheEntryPoint` and `noEnvironmentRegistersNothing` count `toggleSwitcher` instead of `togglePopover`, and `theShortcutTogglesThePopover` became `theShortcutTogglesTheSwitcher` (over `SwitcherController`, since `PopoverController.shortcutPressed()` is gone). No other test changed |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| App shell | `CFFIXED_USER_HOME=$(mktemp -d) build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`, then `kill -TERM` | 7 status-bar windows printed as before (the item at {1629, 1698} and {4152, 2139}, the replicas at {0, −30}); no child process while running or after; exit 0; the private home still empty (no `hosts.json`, no `preferences.json`). That mode builds no switcher panel (only normal mode with the shortcut does) |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery switcher\|settings --appearance light\|dark --preview-snapshot <png>`, each image looked at | `switcher-states-*.png` 3448 × 2452 px, 9 states (sessions, filtered, New session with a name, the form, opening, a failure, a failure since the last opening pinned on top, no hosts, hosts checking or unreachable) readable in both appearances; `settings-states-*.png` regenerated (4528 × 10808 px) for the General tab's new note, otherwise as before |

### Phase I-4 — no window at launch (2026-11-04)

The menu bar app moved from a SwiftUI `App` (one empty `Settings` scene, kept for its standard
main menu) to a plain `NSApplication` with a hand-built main menu (PLAN.md Phase I-4, D33). The
app shell check first gained the listing of every other window, the launch's Apple event and
the main menu, and ran on the unchanged shell before the fix. Both runs used private homes
from `mktemp -d` through `CFFIXED_USER_HOME`: **home a** empty (no `hosts.json`, so onboarding
shows), **home b** holding `Library/Application Support/muxFinder/hosts.json` (0600 in a 0700
folder), a schema 1 list made from `muxfinder-probe hosts show`'s onboarding defaults with
Neptuno as This Mac and every host off, which `hosts show` reads back as `saved`. Each run:
in the background, the output read after 6 s (3 s was too early for a freshly signed bundle's
first launch: nothing printed yet), `pgrep -P <pid>`, `kill -TERM <pid>`, `wait`. The attach
path did not change, so no `e2e-*` run or self-test was made; no iTerm2 window was opened, no
key was pressed and nothing went through LaunchServices. The real `hosts.json`,
`preferences.json` and `DynamicProfiles/` were neither read nor written.

| Check | Command | Observed result |
|---|---|---|
| Before, home a | `CFFIXED_USER_HOME=<home a> build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &` (the unchanged shell, the extended check) | 7 status-bar windows as before; "other windows: 3, 2 visible": **`"muxFinder Settings"` class `SwiftUI.AppKitWindow` visible level 0**, the hidden `PopoverPanelWindow` (level 101) and onboarding's `"Welcome to muxFinder"` `SettingsWindow`; launch: Apple event `oapp`, default launch true; SwiftUI's main menu: 5 menus (app menu, Edit, an empty View, Window listing both windows, Help), no Settings, Close or Paste and Match Style item. No child; exit 0 after SIGTERM; the home still empty |
| Before, home b | the same with `<home b>` | "other windows: 2, 1 visible": **`"muxFinder Settings"` `SwiftUI.AppKitWindow` visible**, the hidden panel; the same launch line and menu. No child; exit 0; the home holding only its `hosts.json` (555 bytes, unchanged) |
| What opens it | the debug binary with a temporary trace of `NSWindow.makeKeyAndOrderFront:` and `orderWindow:relativeTo:` (a scratch source, removed before the fix), home b | `SwiftUI.AppWindowsController.showInitialWindow()` from `SwiftUI.AppDelegate.applicationDidFinishLaunching`, inside `-[NSApplication _handleAEOpenEvent:]` for the launch's `oapp` event; `~/Library/Saved Application State/` holds no muxFinder state (PLAN.md *Verified facts*, Phase I-4) |
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 336 UI tests in 32 suites (12 new in 2 suites: `MainMenuTests`, `AppShellReportTests`). No existing test changed |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| After, home a | `CFFIXED_USER_HOME=<a new empty home> build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &` | 7 status-bar windows; "other windows: 2, 1 visible": the hidden `PopoverPanelWindow` and onboarding's `"Welcome to muxFinder"` only, **no SwiftUI window**; launch: `oapp`, default launch true; main menu: 3 menus, the hand-built items plus AppKit's own (AutoFill, Start Dictation, Emoji & Symbols in Edit; "Close All" ⌥⌘W under Close; the onboarding window in Window's list). No child while running or after; exit 0 after SIGTERM; the home still empty (no `hosts.json`, no `preferences.json`); the same again on the final tree in a third empty home |
| After, home b | the same with `<home b>` | "other windows: 1, 0 visible": the hidden popover panel only, so no window besides the status item; the same menu. No child; exit 0; the home holding only its unchanged `hosts.json`; the same again on the final tree |
| Close and the panels | a scratch program (its own off-screen windows, no status item): `validateMenuItem` of a `performClose:` item, `performClose(nil)` on a borderless non-activating panel, `closeAll:` | Close disabled for the borderless panel and the borderless status-bar-level window, enabled for the titled closable one; `performClose` left the panel open; `closeAll:` left all three visible. `MainMenuTests.closeValidation` checks muxFinder's own `PopoverPanelWindow` and `SettingsWindow` |
| Placement diagnostic | `CFFIXED_USER_HOME=<another empty home> build/muxFinder.app/Contents/MacOS/muxFinder --report-popover-placement` (it runs on the new shell), once | exit 0: offsets 0 and 0, "after-fix check: passed"; no child; the home still empty |
| Other modes | `muxFinder --selftest bogus-name`; `muxFinder --preview-fixtures [--preview-gallery settings] --preview-snapshot <png in a private folder>`; `muxFinder --report-login-item-status` | exit 2 with the usage lines, nothing contacted; exit 0 each (the popover gallery 4672 × 2200 px, the Settings gallery 4528 × 10808 px, the size of the committed `settings-states-light.png`; preview mode does not run the changed shell); exit 0, `enabled` (read-only) |

### Phase I-5 — one click activates a switcher row (2026-11-04)

A click on a session switcher row now activates it at once (PLAN.md Phase I-5, D32): a session
opens through the popover's Open, "New session…" shows the form with ⌘N's draft, and the rest
of that click's sequence reaches no view in the panel (`SwitcherClickSequence`), so a quick
double click opens once and never acts on the form. After the review, that rest also never
reaches the window behind the panel: through the double-click interval the panel is no shorter
than it was and a success close waits (`SwitcherController.holdForClick()`). The attach path did not change, so no
`e2e-*` run or self-test was made; no iTerm2 window was opened, no click or key was synthesized
and nothing went through LaunchServices. The real switcher panel and a real double click are
checklist 18 (items 9 and 10).

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 343 UI tests in 33 suites (7 new in 1 suite: `SwitcherClickTests`). `aSecondActivationOfNewSessionLeavesTheDraft` fails with the `newSessionFromSwitcher()` fix reverted. No existing test changed |
| Unit tests after the review fix | `swift test` | exit 0: 815 core tests in 81 suites and 350 UI tests in 33 suites (7 new: four in `SwitcherControllerTests`, two in `SwitcherClickTests`, one in `PopoverHeightLimitTests`). Each fails with its part of the fix reverted (the minimum height, the waiting close, a close ending the hold, the hold's number check, the click arming it, `PopoverHeightLimit`'s minimum); the growth test fails with a hold that freezes the frame instead. Only the test panel and switcher system changed, gaining the minimum and the two seams |
| Held panel render | a scratch test (removed afterwards) rendering the real `PanelHost<SwitcherPanelRoot>`'s content view off screen into PNGs in a private folder: the list, then the form with the list's height held, then released | the held form at the top with the switcher's opaque background below and the panel's rounded corners; released, the form at its natural height in the same place |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Gallery | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery switcher --appearance light\|dark --preview-snapshot <png in a private folder>`, each image looked at | exit 0 each, 3448 × 2452 px, the 9 states as committed in both appearances (no visible text changed: neither row's accessibility hint mentioned a double click), so `switcher-states-*.png` were not regenerated. After the review fix, again exit 0 each and unchanged (a first light run came out 3448 × 2448 px, the next 3448 × 2452; the gallery uses none of the changed types) |

### Phase I-6 — Tab in New session (2026-11-04)

Tab from New session's Name field now reaches Directory and ⇧Tab comes back, in the popover's
and the session switcher's form (PLAN.md Phase I-6, D30, D31, D32). The cause was found with a
new read-only preview-fixture diagnostic, `--preview-fixtures --preview-key-view-loop
popover|switcher` (`KeyViewLoopReport`): it shows muxFinder's real panel (`PanelHost` with the
live view and its key monitor) over a synthetic fixture, first with its list, then with the
form replacing it as ⌘N does; makes it key for about ten seconds (the frontmost app stays
frontmost); exits 0 (the form's fields found), 1 (not found), 2 (usage) or 3 (its watchdog, 30 s
after the start, off the main thread; review fix: its lines go through a
`NonblockingLineWriter`, so a reader that stops reading never holds the panel up); prints the
panel's key views (numbered in view tree order, with their position from
the panel's top left and their `nextKeyView`), the `nextValidKeyView` and `previousValidKeyView`
chains from Name before and after the steps, and where each step takes the focus from Name,
with the directory list closed and open. A step is what Tab or ⇧Tab does without its event:
with a field editor first, the key binding's action message (`insertTab(_:)`,
`insertBacktab(_:)`, sent through `doCommand(by:)`), else the window's own
`selectNextKeyView(_:)` or `selectPreviousKeyView(_:)`. No event was made or posted, no key
was pressed, no iTerm2 or engine was contacted, nothing went through LaunchServices, and the
real `hosts.json`, `directories.json` and `preferences.json` were neither read nor written.
The creation path did not change, so no self-test or `e2e-*` run was made. Real key presses are
checklist 20.

Before the fix (the debug binary with `PopoverPanelWindow.recalculatesKeyViewLoop` set to
`false` for the run, the final diagnostic; the switcher's panel printed the same chains and
steps, its Name field focused by the form itself):

```
panel popover key yes app active yes keyboard navigation on autorecalculatesKeyViewLoop no
with the list: initialFirstResponder PopoverPanelContentView (AXUnknown); first responder field editor of AppKitTextField text field “Search hosts and sessions”
with the form: initialFirstResponder PopoverPanelContentView (AXUnknown); first responder the panel window
list closed, before the steps: nextValidKeyView from Name: #3 AppKitTextField text field “work” → none
list closed: Tab 1 (insertTab): field editor of #3 AppKitTextField text field “work”; list shows no
list closed: ⇧Tab 1 (insertBacktab): field editor of #3 AppKitTextField text field “work”; list shows no
list closed: view #1 SwiftUIPopupButton pop-up button at (50, 41) canBecomeKeyView yes next AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformView>> (AXUnknown)
list closed: view #3 AppKitTextField text field “work” at (16, 88) canBecomeKeyView yes next AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformTextFieldAdaptor>> (AXUnknown)
list closed: view #4 AppKitTextField text field “Home folder on the host” at (16, 136) canBecomeKeyView yes next AppKitPlatformViewHost<PlatformViewRepresentableAdaptor<PlatformTextFieldAdaptor>> (AXUnknown)
list closed: view #5 SwiftUIAppKitButton button “” at (307, 132) canBecomeKeyView yes next none
list closed: view #6 SwiftUIAppKitButton button “” (Esc) at (215, 165) canBecomeKeyView yes next none
list closed: view #7 SwiftUIAppKitButton button “” (Return) at (281, 165) canBecomeKeyView yes next none
list closed, after the steps: nextValidKeyView from Name: #3 AppKitTextField text field “work” → none
list open, before the steps: nextValidKeyView from Name: #3 … “work” → #6 … “Home folder on the host” → #7 … button “” → #8 … (Esc) → #9 … (Return) → none
list open, before the steps: previousValidKeyView from Name: #3 AppKitTextField text field “work” → none
list open: Tab 1 (insertTab): field editor of #6 AppKitTextField text field “Home folder on the host”; list shows yes
list open: Tab 4 to 10 (selectNextKeyView): #9 SwiftUIAppKitButton button “” (Return); list shows yes
list open: ⇧Tab 1 (insertBacktab): field editor of #3 AppKitTextField text field “work”; list shows yes
```

After the fix (the signed bundle binary of the final tree; the switcher's panel the same, its
controls at the switcher's 540 pt width):

```
panel popover key no app active no keyboard navigation on autorecalculatesKeyViewLoop yes
list closed, before the steps: nextValidKeyView from Name: #3 AppKitTextField text field “work” → none
list closed: Tab 1 (insertTab): field editor of #4 AppKitTextField text field “Home folder on the host”; list shows no
list closed: Tab 2 (insertTab): #5 SwiftUIAppKitButton button “”; list shows no
list closed: Tab 3 (selectNextKeyView): #6 SwiftUIAppKitButton button “” (Esc); list shows no
list closed: Tab 4 (selectNextKeyView): #7 SwiftUIAppKitButton button “” (Return); list shows no
list closed: Tab 5 (selectNextKeyView): #1 SwiftUIPopupButton pop-up button; list shows no
list closed: Tab 6 (selectNextKeyView): field editor of #3 AppKitTextField text field “work”; list shows no
list closed: ⇧Tab 1 to 6: #1 pop-up button, #7 (Return), #6 (Esc), #5, field editor of #4 “Home folder on the host”, field editor of #3 “work”
list closed, after the steps: nextValidKeyView from Name: #3 … “work” → #4 … “Home folder on the host” → #5 … button “” → #6 … (Esc) → #7 … (Return) → #1 … pop-up button → back to #3 … “work”
list open: Tab 1 to 6: field editor of #6 “Home folder on the host”, #7, #8 (Esc), #9 (Return), #1 pop-up button, field editor of #3 “work”; list shows yes at every step
list open: ⇧Tab 1 to 6: the same order backwards; list shows yes at every step
```

(`…` stands for the class and kind repeated from the line above.) #5 at (307, 132) is the
directory list's button, at the Directory field's trailing edge; Cancel and Create carry Esc
and Return; the order is the reading order. Before the steps the links read straight from the
views are still the stale ones: AppKit recalculates a loop it was told to only when the window
is next asked for a key view.

| Check | Command | Observed result |
|---|---|---|
| Diagnosis, form shown at once | the first version of the diagnostic, which opened the panel with the form already in it (debug binary, the unchanged panel) | the loop was intact (Name → Directory → the three buttons → the Host picker → Name) and Tab's action message moved Name to Directory, once with the panel key and the app active, once with neither; so the hosting setup, the non-activating panel and the inactive app were ruled out. Those first runs often stopped early with exit 0: the text cursor's indicator window (`TUINSWindow`, closed by `TextInputUIMacHelper`'s `TUINSCursorUIController`) closed, which the preview app took for its last window closing (a temporary trace of `NSWindow.willCloseNotification` and `NSApplication.willTerminateNotification`, removed). The preview app now keeps running through that in this diagnostic |
| Diagnosis, the app's sequence | `.build/debug/MuxFinderApp --preview-fixtures --preview-key-view-loop popover`, then `switcher` (the unchanged panel) | the record above: the panel's loop, computed when it was first shown with the list (`autorecalculatesKeyViewLoop` no), never recalculated for the form; Name's link is SwiftUI's view host, which takes no focus, so Tab and ⇧Tab stay in Name in both panels. Keyboard navigation was on (`defaults read -g AppleKeyboardUIMode`: 2, read only); the chain from Name ends at once whatever the setting |
| After the fix | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-key-view-loop popover`, then `switcher` | exit 0 each, the record above: Tab and ⇧Tab move in reading order and wrap inside the panel, the list staying open |
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 354 UI tests in 34 suites (4 new in 1 suite: `NewSessionTabOrderTests`). `panelsRecalculateTheirKeyViewLoop` and `tabMovesFromNameToDirectoryAndBack` (both panels, real but never shown) fail with the fix reverted, the latter on its ⇧Tab step (in a panel that is never shown the stale loop still happens to lead Name to Directory); its two cases run one after another, since two hidden panels editing text at once disturbed each other's focus. No existing test changed |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery popover\|attach\|switcher --appearance light\|dark --preview-snapshot <png in a private folder>`, the attach gallery looked at | exit 0 each: popover 4672 × 2200 px, attach 3136 × 5374, switcher 3448 × 2452, as before; no state's look changed (the views only gained the two placeholders as constants), so no screenshot was regenerated |

### Phase I-7 — typing in Directory filters the directory list (2026-11-04)

New session's Directory field is now the directory list's search (PLAN.md Phase I-7, D31), in
the popover's and the session switcher's form: the list keeps the entries that contain the
field's text, with the `~` rule on This Mac, says "No matching directories" when none does, and
opens and closes by itself as the user types; VoiceOver hears the match count. The creation
path did not change (Return with nothing highlighted already created), so no self-test or
`e2e-*` run was made; no key was pressed or event made, VoiceOver was not turned on, nothing
went through LaunchServices, and the real `hosts.json` and `directories.json` were neither read
nor written (the tests use fixtures and in-memory stores; their home folder is synthetic).
Typing, the keys, VoiceOver and a creation in the real panels are checklist 21.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 376 UI tests in 36 suites (22 new in 2 suites: `DirectoryFilterContentTests`, `DirectoryFilterModelTests`). Five existing tests had their Directory field changed, since the field now filters the list, with their expectations kept: in `DirectoryPickerContentTests`, `clearRuleAndNotice` (`"~/b"` → `"~/"`) and `itemsAndMoving` (`"~/typed"` → `"/"`), which typed a field only for Save's rule; in `DirectoryPickerModelTests`, `pickingFillsAndChecksTheDraft` (the field emptied before reopening the list and before the pick after a collision, as a picked value now hides the other rows), `hostChangeKeepsTheField` (`"~/typed by hand"` → `"/"`, which every entry contains) and `editingTheFieldDropsTheHighlight` (`"~/typed again"` → `"~/s"`, so ↓ still finds `~/s1`) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery attach\|switcher\|popover --appearance light\|dark --preview-snapshot <png in a private folder>`, the attach and switcher images looked at | exit 0 each. Attach 3136 × 6104 px (was 5374): "typing filters the list" (This Mac with `~/proj`: Recent `~/projects/blog`, Saved `~/projects/site` and `~/projects/api`, "Sessions on Neptuno" `/Users/example/projects/site` through the `~` rule, nothing highlighted) and "no matching directories" (Saturno, the button's list: the note above both actions); "directory saved already" now shows only its saved entry, which the field keeps. Switcher 3448 × 3120 px (was 2452): the form filtered and with no match. Readable in both appearances; `attach-states-*.png` and `switcher-states-*.png` regenerated. The popover gallery holds no New session state: 4672 × 2200 px as in Phase I-6, not regenerated |

### Phase I-8 — change the host from the keyboard in New session (2026-11-05)

With macOS's keyboard navigation on, ⇧Tab from New session's Name field already reached the
Host picker, in the popover's and the session switcher's form, but the keyboard could not
change the host: the panels' key monitor took ↑, ↓ and ⌥↓ wherever the focus was (PLAN.md
Phase I-8, D30, D31, D32; the cause under *Verified facts*, Phase I-8). The diagnosis came from
I-6's read-only `--preview-fixtures --preview-key-view-loop popover|switcher`, which grew a Host
picker section: for each directory list state, the routes the monitor would make with the focus
in Name, then the first responder after the window's own step back from Name
(`selectKeyView(preceding:)`; with `selectPreviousKeyView(_:)` sent with Name's field editor
first, and ⇧Tab's `insertBacktab(_:)` to that editor, as cross-checks), its class, whether it
is an `NSPopUpButton`, its menu's item count (never a title), the key binding messages it
answers, and the route `PanelKeyRoute.decide` gives ↑, ↓, ⌥↓, Space, Return and Esc with it.
The "before" runs used the debug binary with the routing's two new rules (menu tracking, the
pop-up button) taken out, which is exactly the monitor's rule before this phase; the "after"
runs the signed bundle binary of the final tree. No event was made, posted or delivered, no key
was pressed, no menu was opened, no iTerm2 or engine was contacted, nothing went through
LaunchServices, and the real `hosts.json`, `directories.json` and `preferences.json` were
neither read nor written (synthetic fixtures only). The creation path did not change, so no
self-test or `e2e-*` run was made. Real key presses are checklist 22.

Before the fix (popover; the prefix `muxFinder key view loop: ` left out; the earlier lines,
the Tab walks and the chains, are I-6's record unchanged; `…` repeats the line above's
"menu tracking no, marked text no"):

```
panel popover key yes app active yes keyboard navigation on autorecalculatesKeyViewLoop yes
host picker, list closed, focus in Name (kind other, …, list open no): ↑ → the panel's up; ↓ → the panel's down; ⌥↓ → the panel's openList; Space → the focused view; Return → the panel's open; Esc → the panel's close
host picker, list closed: after the window's selectPreviousKeyView with Name's field editor first: field editor of #3 AppKitTextField text field “work”
host picker, list closed: after the window's selectKeyView(preceding: Name): #1 SwiftUIPopupButton pop-up button; NSPopUpButton yes; kind popUpButton; list shows no
host picker, list closed: pop-up button: 2 menu items, selected item 2, enabled yes, pulls down no; answers moveUp: yes, moveDown: yes, moveForward: no, moveToEndOfParagraph: no
host picker, list closed, focus after selectKeyView(preceding: Name) (kind popUpButton, …, list open no): ↑ → the panel's up; ↓ → the panel's down; ⌥↓ → the panel's openList; Space → the focused view; Return → the panel's open; Esc → the panel's close
host picker, list closed: after ⇧Tab's insertBacktab from Name: #1 SwiftUIPopupButton pop-up button; list shows no
host picker, list open, focus in Name (kind other, …, list open yes): ↑ → the directory list's up; ↓ → the directory list's down; ⌥↓ → the directory list's openList; Space → the focused view; Return → the directory list's open; Esc → the directory list's close
host picker, list open: after the window's selectKeyView(preceding: Name): #1 SwiftUIPopupButton pop-up button; NSPopUpButton yes; kind popUpButton; list shows yes
host picker, list open, focus after selectKeyView(preceding: Name) (kind popUpButton, …, list open yes): ↑ → the directory list's up; ↓ → the directory list's down; ⌥↓ → the directory list's openList; Space → the focused view; Return → the directory list's open; Esc → the directory list's close
host picker, list open: after ⇧Tab's insertBacktab from Name: #1 SwiftUIPopupButton pop-up button; list shows yes
```

The switcher's panel printed the same lines (its form focuses Name itself; its picker shows
selected item 1, as its fixture lists the draft's host first). "The panel's up/down" is `AppModel.handle(_:)`
doing nothing while a panel shows, so the key was swallowed; "the panel's openList" opened the
directory list; "the directory list's up/down/openList" moved its highlight.

After the fix (the signed bundle binary; every other line as before, the switcher's the same):

```
host picker, list closed, focus in Name (kind other, …, list open no): ↑ → the panel's up; ↓ → the panel's down; ⌥↓ → the panel's openList; Space → the focused view; Return → the panel's open; Esc → the panel's close
host picker, list closed: after the window's selectKeyView(preceding: Name): #1 SwiftUIPopupButton pop-up button; NSPopUpButton yes; kind popUpButton; list shows no
host picker, list closed, focus after selectKeyView(preceding: Name) (kind popUpButton, …, list open no): ↑ → the focused view; ↓ → the focused view; ⌥↓ → the focused view; Space → the focused view; Return → the panel's open; Esc → the panel's close
host picker, list open, focus in Name (kind other, …, list open yes): ↑ → the directory list's up; ↓ → the directory list's down; ⌥↓ → the directory list's openList; Space → the focused view; Return → the directory list's open; Esc → the directory list's close
host picker, list open: after the window's selectKeyView(preceding: Name): #1 SwiftUIPopupButton pop-up button; NSPopUpButton yes; kind popUpButton; list shows yes
host picker, list open, focus after selectKeyView(preceding: Name) (kind popUpButton, …, list open yes): ↑ → the focused view; ↓ → the focused view; ⌥↓ → the focused view; Space → the focused view; Return → the directory list's open; Esc → the directory list's close
```

| Check | Command | Observed result |
|---|---|---|
| Diagnosis | `.build/debug/MuxFinderApp --preview-fixtures --preview-key-view-loop popover`, then `switcher` (the two new rules taken out for the run) | exit 0 each, the record above: ⇧Tab from Name reaches the picker (`SwiftUIPopupButton`, an `NSPopUpButton`, 2 items) with the list closed or open, the list staying open; with it focused ↑, ↓ and ⌥↓ went to the panel's handler. Keyboard navigation was on (the diagnostic reads `NSApp.isFullKeyboardAccessEnabled`) |
| AppKit, read | the SDK's `NSEvent.h`, `NSMenu.h`, `NSPopUpButton.h`, `NSPopUpButtonCell.h`; `StandardKeyBinding.dict` through `plutil -convert json`; a scratch Swift process (outside the repository) listing the methods `NSPopUpButton`, `NSPopUpButtonCell`, `NSButton`, `NSButtonCell` and `NSControl` implement and which of them answer `moveUp:`, `moveDown:`, `moveForward:`, `moveToEndOfParagraph:`, `cancelOperation:`, `insertNewline:`, `performClick:` and `keyDown:` | ↑ `moveUp:`, ↓ `moveDown:`, ⌥↓ `moveForward:` + `moveToEndOfParagraph:`, Esc `cancelOperation:`, Return `insertNewline:`; only `NSPopUpButton` answers `moveUp:`/`moveDown:` (its own), none answers ⌥↓'s or `cancelOperation:`/`insertNewline:`; `NSPopUpButtonCell` implements `keyDown:inRect:ofView:` and `performClickWithFrame:inView:`; a local monitor is not called for events a menu's tracking loop consumes (`NSEvent.h`). No header says which key opens the menu (*Verified facts*, Phase I-8) |
| After the fix | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-key-view-loop popover`, then `switcher` | exit 0 each, the record above: with the picker focused ↑, ↓, ⌥↓ and Space go to it, Return and Esc as before in both list states; with Name focused, unchanged |
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 390 UI tests in 39 suites (14 new in 3 suites: `PanelKeyRouteTests`, `MenuTrackingObserverTests`, `HostPickerBindingTests`). `aPopUpButtonKeepsTheArrows`, `theListOpenAndThePopUpButtonFocused` and `aTrackingMenuGetsEveryKey` fail with the two new rules taken out. No existing test changed. A test picking a host through the real picker's menu (`NSMenu.performActionForItem(at:)`) in a never-shown panel was tried and dropped: SwiftUI makes no AppKit pop-up button (nor buttons) in a panel that never showed, even after layout and a display pass, so the pick is tested through the picker's binding instead |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery popover\|attach\|switcher --appearance light\|dark --preview-snapshot <png in a private folder>` | exit 0 each: popover 4672 × 2200 px, attach 3136 × 6104, switcher 3448 × 3120, as in Phase I-7 (one switcher light run came out 3114 px tall, a second 3120); no view's look changed (the views gained doc comments only), so no screenshot was regenerated |

### Phase I-9a — New session in its own window (2026-11-05)

New session moved out of the popover's and the switcher's shared `panel` into its own titled,
floating, non-activating "New session" window (PLAN.md Phase I-9, D34; D30–D33 edited), opened
from both entry points, which close as it opens; the window's state is the model's
(`AppModel.newSessionWindow`), followed by `NewSessionWindowController` in the app shell only.
A creation that fails after its window was closed brings the window back, not key, replacing
the switcher-only deferred failure. The folder drop, the window's gallery, the screenshots and
the user docs are Phase I-9b's, so no gallery was rendered. Every check below ran with private
folders or none: no real `hosts.json`, `directories.json` or `preferences.json` was read or
written, and nothing went through LaunchServices. No `e2e-*` run was needed.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 405 UI tests in 40 suites (17 new in 1 suite: `NewSessionWindowTests`). Changed, because New session's form, keys and endings are the window's now: `SwitcherClickTests` (opening the window instead of showing the form; the click's hold now also covers the window's opening, its close for `newSessionOpened` waiting for the interval), `SwitcherModelTests` (`returnOnNewSessionOpensTheWindow`, `commandNAndTheWindowsKeys`, `aCreationFailureBringsTheWindowBack` replace the form tests; the two Move here deferral tests were removed with the retired path, their guarantee now in `NewSessionWindowTests.aFailureAfterClosingIsNotHeldBackByMoveHere`; `failedPinnedCreation` presses Return in the window), `NewSessionSheetTests` and `AttachFlowTests` (the window's state instead of `panel == .newSession`; the attach fixtures' New session states counted in `newSessionStates`), `DirectoryPickerTests`, `DirectoryFilterTests`, `HostPickerBindingTests` and `DirectoryRecordingTests` (the window's keys through `handleNewSessionKey(_:)`, ⌘F and ⌘R `ignored` there; `closeNewSession()` for Cancel), `NewSessionTabOrderTests` (over the real window, never shown), `MainMenuTests` (Close enabled for `NewSessionPanel`), `AppModelTests.commandKeys` |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| App shell | `CFFIXED_USER_HOME=$(mktemp -d) build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`, then `kill -TERM <pid>` | exit 0, no child while it ran or after, the private home still empty; the other windows were the popover's `PopoverPanelWindow` (hidden) and the onboarding window, no New session window (it is made at its first opening) |
| Popover placement | `CFFIXED_USER_HOME=$(mktemp -d) build/muxFinder.app/Contents/MacOS/muxFinder --report-popover-placement` (in the background) | exit 0, "after-fix check: passed" (both offsets 0), the popover appeared after 122 ms; `pgrep -P` empty while it ran, the private home empty |
| Key view loop | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-key-view-loop popover`, then `switcher` | exit 0 each, now over the real New session window (`NewSessionPanel` "New session", `autorecalculatesKeyViewLoop` yes; key no and app active no from the bundle binary, as in Phase I-6's bundle run): the Name field focused at the opening (with the switcher's prefilled name), Tab Name → Directory → the list's button → Cancel → Create → Host picker → Name and ⇧Tab back, the list staying open; with the picker focused ↑, ↓, ⌥↓ and Space go to it, Return and Esc as before |
| New session self-test | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest new-session-local` (`TMUX_TMPDIR` unset; `iterm2 status` connected; iTerm2 17 threads before, 20 after) | exit 0, passed (7 steps): listed 107 ms; new session created and confirmed 1.16 s; launch tab buried; the same name refused as a collision with "Open existing" offered and nothing launched; detach 10.1 s; launch tab left 248 ms after the detach; kill. Afterwards no `muxfinder-test-*` session and nothing of the run in `iterm2 list-sessions` (tabs or buried sessions) |

### Phase I-9b — the folder drop, the window's gallery and the docs (2026-11-05)

One folder dragged from Finder onto the New session window's Directory field (or its list
button) fills the field as a pick, `~/…` under This Mac's home folder (PLAN.md Phase I-9, its
I-9b calls, D34). The rule is a pure function (`FolderDrop`), the model decides the highlight
and the fill (`AppModelDirectories.swift`), and an invisible AppKit view in front of the field
(`FolderDropView`) is the drag's destination, so the field editor never inserts text of its
own. Tested hermetically: the function over plain facts; the model over fixtures; the drop
target in the real New session window (never shown), its place in front of the field and of
its field editor, its registered types against that field editor's, clicks going through, and
its decisions over private pasteboards holding folders, a file and an `.app` in a private
temporary folder (never the general pasteboard). Owed to a person: a real drag from Finder,
the window over other apps and Spaces, the keys, VoiceOver and a creation (checklist 23; items
17, 18, 20, 21 and 22 now describe the window). Every check below ran with private folders or
none: no real `hosts.json`, `directories.json` or `preferences.json` was read or written,
nothing went through LaunchServices, and no `--selftest` or `e2e-*` run was needed (the model
behind creating did not change). Before writing the drop target, a throwaway probe outside the
repository (a window never shown) confirmed that AppKit looks for a drag's destination
frontmost first among views registered for its types (`-[NSView _hitTest:dragTypes:]`), so a
view laid over the field is found before the field editor, edited or not, while `hitTest(_:)`
still gives clicks to the field; muxFinder's code uses no private API.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 815 core tests in 81 suites and 431 UI tests in 43 suites (25 new in 3 suites: `FolderDropFunctionTests`, `FolderDropModelTests`, `FolderDropTargetTests`, `FolderDropTests.swift`). Changed: `AttachFlowTests.attachFixturesCoverEveryState` (the New session states now include a failure and the drop highlight), `DirectoryFilterModelTests.galleryFixturesCoverTheFilter` (the switcher's filtered and no-match form fixtures were retired as duplicates of the popover's in the window's gallery; the two popover fixtures are still checked); `DirectoryFilterContentTests.theFieldsHintMentionsTheFilter` only gained a sentence in its comment (the hint still starts the same) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| App shell | `CFFIXED_USER_HOME=$(mktemp -d) build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`, then `kill -TERM <pid>` after 3 s | exit 0, no child while it ran, the private home still empty; the other windows the hidden popover panel and onboarding, no New session window |
| New session gallery | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery new-session --appearance light --preview-snapshot docs/screenshots/new-session-states-light.png`, then `dark` | exit 0 both; 3448 × 3760 px, 13 states in window-like frames, inspected (the drop highlight cropped with `sips` into `/tmp`): editing as the popover and as the switcher open it (the name from the filter), an invalid name, the directory list open with a highlighted row, nothing to pick, saved already, an unusable file, filtered by typing, no matching directories, creating (fields off), a name taken with "Open existing", a failed creation, and a folder dragged over Directory (an accent ring just outside the field); readable in both appearances |
| Attach and switcher galleries | `--preview-gallery attach` and `switcher`, light and dark, with `--preview-snapshot docs/screenshots/<gallery>-states-<appearance>.png` | exit 0 all four, regenerated and inspected now that their inline form states are gone (Phase I-9a): attach 3136 × 3386 px (was 3136 × 6104), the 11 session-action states and the context menu card; switcher 3448 × 2260 px (was 3448 × 3120), its 8 states, "New session…" rows but no form |
| Popover gallery | `--preview-gallery popover --appearance light --preview-snapshot <png in /tmp>` | exit 0, 4672 × 2200 px as in Phases I-6 to I-8; it holds no New session state and I-9 changed nothing in it, so `popover-states-*.png` were not regenerated |

### Phase I-10a — folder search core (2026-11-06)

The core of New session's folder search (PLAN.md Phase I-10, D36; D3 and D32 edited): the
static script run through `/bin/sh` on This Mac and through discovery's noninteractive ssh on
a host, the escaping of typed text, the answer parser, the process transport, the channel's
state machine, the search scope preference and the probe command `folders`. No UI (Phase
I-10b). Hermetic tests run the real script with stub `mdfind` and `mdutil` first on `PATH`,
printing synthetic paths, under `/bin/sh` (bash) and `dash`. Real runs used `--count-only`
(never `--paths`), neutral fragments ("do", "pro", "ab", "es") and improbable ones ("qx",
"wkz") as names, on this Mac and `saturno-m4` only: counts and timings below, never a folder
name or path. No real `hosts.json`, `directories.json` or `preferences.json` was read or
written, nothing went through LaunchServices, and iTerm2 and tmux were not involved.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0; exit 0 |
| Unit tests | `swift test` | exit 0: 879 core tests in 87 suites (64 new in 6 suites: `FolderSearchTextTests`, `FolderSearchOutputTests`, `FolderSearchScriptTests`, `FolderSearchTransportTests`, `FolderSearchChannelTests`, `FolderSearchScopePreferenceTests`) and 431 UI tests in 43 suites (unchanged; `ScriptedPreferencesStore` gained the new store requirement). The folder search suites passed 6 runs in a row (about 4.3 s each). |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Probe help | `muxfinder-probe folders --help` | exit 0, usage only, nothing contacted |

**After the adversarial review** (`docs/reviews/phase-I-10a.md`; PLAN.md D36, *The
pipeline, the limit and the deadline* and *Disconnects*). The stub `mdfind` is now one
long-lived process, as the real one is (`endless` loops in the shell, `hang` is `exec sleep
30`), records its pid in `mdfind.pids` (`FolderSearchSandbox.noStubLeft(within:)` checks each
with `kill(pid, 0)`), and has two new modes: `noise` (the paths file, then hidden folders
forever) and `hang-once` (blocks on its first call only). Each new test below was run against
the code without its fix and failed there:

| Test | What it proves | Without the fix |
|---|---|---|
| `FolderSearchScriptTests.stopsAtTheLimitAmidEndlessNoise` (bash, dash) | 51 kept folders, then endless left-out ones: two queries answer `limited` with the first 50 in well under the deadline (under 1 s in the suite), no stub left | the old script hung until the run's 15 s timeout; without only `g`'s signal, each query waited for the deadline (10 s for two) |
| `FolderSearchScriptTests.answersATimeoutForABlockedSearch` (bash, dash) | a blocked `mdfind` is killed at the 4 s deadline, the query gets `error timeout`, the same script answers the next query, no stub left | timed out at 15 s with no answer |
| `FolderSearchScriptTests.deadlinesMatchTheScript` | `searchDeadline` (4 s) and `answerSignalWait` (1 s) are the script's `u 4` and `u 1`, and the deadline is below the channel's 5 s answer wait | — |
| `FolderSearchTransportTests.aDisconnectEndsABlockedSearchOnTheHost` (bash, dash) | the host side of a closed SSH channel: the script's pipes closed with no signal while its stub `mdfind` blocks; the stub is gone and the script exits by itself after about 4 s, its group empty | the stub was still running after 8 s and the script had not exited |
| `FolderSearchTransportTests.failsOnAFloodWithAStalledReader` | endless valid answers with nobody reading (event limit 4): the connection ends the process by itself, and the reader then gets the header, 4 answers, `eventOverflow` and the end, last | the process kept running and the buffer kept growing |

Changed: `stopsAnEndlessSearch` also checks that no stub is left; `passesThePredicateAsOneArgument`
expects `mdfind.pids` among the sandbox's files; `FolderSearchChannelTests.reportsTheScriptsErrors`
covers `error timeout` (`searchTimedOut`, no reopen). By hand, outside the tests: a Python
harness closed the pipes of the real script under each stub mode with SIGPIPE ignored and
not: the stub was gone at 4.0 s (`hang`, and `noise` with only 50 kept) or at once, the script
exited by itself each time and its group was empty; 40 queries with a stub `mdfind` took
about 16 ms each of the pipeline's own time.

**Real runs after the fixes** (`folders --count-only`, neutral fragments as above):

| Run | Queries | Open | Answers | Latency min / median / max | After the close |
|---|---|---|---|---|---|
| This Mac, home | 6 (3 names × 2) | 164 ms | 4 limited (50), 2 ok 0 | 243 / 301 / 457 ms | closed in 15 ms; 0 children |
| This Mac, disk | 2 | 53 ms | 2 limited (50) | 118 / 258 / 258 ms | closed in 25 ms; 0 children; `pgrep -x mdfind` 0, no script, producer or answer stage left |
| `saturno-m4`, home | 6 (3 names × 2) | 892 ms | 4 limited (50), 2 ok 0 | 264 / 314 / 407 ms | closed in 57 ms; 0 children here; on Saturno `pgrep -x mdfind` 0 and no script, producer or answer stage left |

**Escaping against real `mdfind`, by counts** (a 16 MB scratch APFS image attached with
`-nobrowse`, indexing turned on for it, holding 12 synthetic folders whose names differ in one
character; detached and deleted afterwards). Each escaped special character matched exactly
its one folder: `\*` 1, `\?` 1, `\"` 1, `\\` 1. Unescaped, `*` acted as a wildcard (2
matches) and `?` happened to match 1; escaping makes both literal whatever Spotlight's wildcard
rules are. An unescaped `"` or a lone trailing `\` gave a different predicate silently (exit 0,
no message, 0 matches), which is why the script refuses both. `cd` folded case and diacritics both ways (`e`, `é` typed as NFC and as NFD, `AEZ`: 2
each). An inner space matched 1, a trailing space 0, a leading one 1. `LC_ALL=C` and an
empty environment gave the same counts (`mdfind` reads its argument as UTF-8). A `'` between
letters matched nothing (with or without a backslash), while the same name was found by its
start or by exact name: Spotlight's own word matching, not escaping. End to end through the
probe (`--scope disk`, which includes the scratch volume), the same synthetic names gave 1, 1,
1, 1, 2, 2, 1, 0 and 12 (the name with a line feed among them), 178–191 ms each.

**Real runs** (one channel per run; latency is from the query line to its end record, open is
from the start to the header):

| Run | Queries | Open | Answers | Latency min / median / max | After the close |
|---|---|---|---|---|---|
| This Mac, home | 8 (4 names × 2) | 106 ms | 8 limited (50) | 317 / 388 / 1729 ms (the slowest the first "es"; its repeat 563 ms) | closed in 15 ms; 0 children; `pgrep -f 'muxfinde[r]-folders'` 0 |
| This Mac, disk | 8 (4 names × 2) | 66 ms | 8 limited (50) | 284 / 311 / 719 ms | closed in 15 ms; 0 children |
| This Mac, home | 3 ("qx", "wkz", "do") | 63 ms | ok 0, ok 0, limited (50) | 208 / 229 / 321 ms | closed in 15 ms; 0 children |
| `saturno-m4`, home | 10 (5 names × 2) | 911 ms | 8 limited (50), 2 ok 0 | 240 / 392 / 918 ms (first query 1376 ms from the call, open included) | closed in 59 ms; 0 children |
| `saturno-m4`, disk | 10 (5 names × 2) | 781 ms | 8 limited (50), 2 ok 0 | 255 / 341 / 689 ms | closed in 64 ms; 0 children here; on Saturno `pgrep -f 'muxfinde[r]-folders'` 0 and `pgrep -x mdfind` 0 |
| This Mac, interrupted | `--repeat 50`, SIGINT after 1.5 s; then SIGTERM | 75 ms | 3 and 4 answers | — | exit 130 and 143; channel closed in 194 and 266 ms (a query was in flight); 0 children, 0 left |

Header on both hosts: home present, `mdfind` yes, indexing on for the home's volume and for
`/`, Desktop, Documents and Downloads readable (on Saturno over SSH too). For comparison, raw
`mdfind -onlyin "$HOME" -count` for the three fragments on this Mac took 0.23–0.24 s, and
the script itself, outside the app, answered in 0.24–0.27 s per query after a 68 ms header:
the channel adds little; a query's time is Spotlight's, and the first query for a broad
fragment is slower than its repeat. The first interrupt run exposed a probe bug (the signal
only took effect once every query had run, since the task group waited for the queries'
task, which cancellation does not interrupt); the signal now cancels the queries at once.

### Phase I-10b — the folder search UI (2026-11-06)

New session's "Folders on <host>" section, the window's channel, Settings › Directories'
"Search folders in" and "Missing a folder?" (PLAN.md Phase I-10, its I-10b calls; D31, D34,
D36). The section is a pure value (`FolderSearchSection` inside `DirectoryPickerContent`)
tested apart from the view; the model's channel (`AppModelFolderSearch.swift`) is tested over
`FakeFolderSearchTransport` and a gated clock the test moves (`GatedClock`,
`FolderSearchUITestSupport.swift`), so no test starts a process, runs Spotlight or ssh. The
scope is read through `InMemoryPreferencesStore`, a store whose reads fail, a store whose
saves wait until the test releases them (`GatedPreferencesStore`), or
`PreferencesStore` on a private `mkdtemp` folder; Settings' "Open Spotlight settings" and the
section's links go through recorded seams, never opened. The core changed in one place: the
script's fixed argument `unchecked` (This Mac's transport passes it), tested through the real
script under the stub `mdfind`/`mdutil` harness with a logging `ls` stub first on `PATH`. No
real `hosts.json`, `directories.json` or `preferences.json` was read or written, nothing went
through LaunchServices, no Settings or System Settings window was opened, and no `--selftest`
or `e2e-*` run was needed (creating and attaching did not change). Owed to a person: checklist
item 24.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors`; `swift build --build-tests -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0; exit 0 |
| Unit tests | `swift test` | exit 0: 881 core tests in 87 suites (2 new: `FolderSearchScriptTests.skipsTheReadabilityChecksWhenAsked`, bash and dash, and `FolderSearchOutputTests.readsUncheckedFolders`; changed: `FolderSearchTransportTests.buildsTheArgv` expects `unchecked` after the script name for This Mac and none for ssh, `FolderSearchOutputTests.headerFacts` covers `unreadableProtectedFolders`) and 468 UI tests in 46 suites (37 new in 3 suites: `FolderSearchSectionTests` 14, `FolderSearchModelTests` 16, `SettingsFolderSearchTests` 7; 3 of them added for the review's two findings: `searchingDropsThePreviousFoldersOfAnotherScope` and `aScopeChangeDropsThePreviousFolders`, a Whole disk answer's folders no longer listed while a Home folder search runs, and `quittingWaitsForTheScopeSave`, `shutdown()` returning only once a gated save of a pick ended; each failed with its fix reverted). The new UI suites passed 18 runs in a row (about 0.11 s each) once the harness waited for each debounce to wait before moving the clock (before that, one run spent 10 s in an unchecked wait, and one full run failed an expectation that a closing's bookkeeping was already done; both fixed in the tests). Seven full `swift test` runs afterwards: the UI target passed all seven; the core target failed once each in two of them under the full parallel load, in process-spawning tests (`TerminalChildRunnerTests.cancellationInterruptsTheCheck`, untouched here, and `FolderSearchTransportTests.answersAndEndsAtEndOfInput`, whose close took over its 2 s bound), and both suites passed 15 runs in a row on their own |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Real local check (read-only Spotlight, counts only) | `swift run muxfinder-probe folders --local --name do --name pro --count-only` | header: home present, `mdfind` yes, index home on, index disk on, Desktop, Documents and Downloads **not checked** (the new argument; no `ls` ran); channel open 44 ms; "do" limited (50) in 472 ms, "pro" limited (50) in 438 ms; closed in 15 ms, 0 child processes left. No privacy prompt appeared during the run. No remote run: the SSH path did not change (it passes no argument) |
| New session gallery | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery new-session --appearance light --preview-snapshot docs/screenshots/new-session-states-light.png`, then `dark` | exit 0 both; 3448 × 7494 px, 22 states (the 13 of Phase I-9b and 9 new), inspected in crops (Pillow, `/tmp`): searching ("Searching…" with a small spinner, nothing local matching), folders found on This Mac (one left out as Saved shows it, a long path shortened in the middle, one outside the home folder, a highlighted row), "No folders found", "Folder search isn't available on Build box" (no Spotlight), on Saturno with indexing off and with no home folder, "The host can't be reached, so folders weren't searched.", Desktop, Documents and Downloads hidden over SSH (the note under three folders found), and "Missing a folder?" open on This Mac with "Open muxFinder Settings" and "Open Spotlight settings" below the scrolling sections; readable in both appearances (the highlighted help row's accent text keeps its contrast in dark) |
| Settings gallery | `--preview-gallery settings`, light and dark, with `--preview-snapshot docs/screenshots/settings-states-<appearance>.png` | exit 0 both; 4528 × 12392 px, 25 states (2 new): the Directories tab with "Folder search" ("Search folders in", Whole disk chosen) and "Missing a folder?" with "Open Spotlight settings", and an unusable preferences file (the choice off, its explanation and "Try again"); the other Directories states now show the two sections below their own (cut by the card's height, as the tab scrolls) |
| Attach, switcher and popover galleries | — | not regenerated: none of them shows the directory list (D34) |

### Phase I-11a — Detach other clients, the proof and the core (2026-11-06)

The proof of the command (PLAN.md Phase I-11, its I-11a calls; D37) and the coordinator call,
against the real iTerm2 3.7.7 (it was 3.7.6 in the earlier phases) and tmux 3.8, locally and on
Saturno, one run at a time from the repo root with `TMUX_TMPDIR` unset, the probe run as
`.build/debug/muxfinder-probe` (what `swift run` runs). Before each run: `swift build` (the
probe does not rebuild `muxfinder-launch`), `muxfinder-probe iterm2 status`
exit 0 (connected, protocol 1.23) and iTerm2 at 38 threads or fewer; after each run: the launch
directory, `/private/tmp` `mfx.*`, `muxfinder-test-*` sessions on Neptuno and on Saturno (a
read-only `tmux ls` over ssh) and `iterm2 list-sessions` for the run's launch tabs. Every run
found no tmux connection of the user's ("0 tmux connection(s) this run did not open"). The
first attach's sweep (D14) removed two helper results left in the launch directory since 08:17
and 08:53, older than 120 s, as any attach does; nothing else was found before or after any
run. The harness is the `e2e-detach-others` command itself, first with option (a) as the
coordinator's command, then with option (b).

| Check | Command | Observed result |
|---|---|---|
| Option (a), locally | `swift run muxfinder-probe e2e-detach-others --local`, the coordinator sending `attach-session -d -t '<session id>'` once through the launch tab's connection | exit 1, 7 of 9 PASS in 11.4 s. Steps 1–6 passed: the plain control client printed `%exit` and exited 0 by itself within 57 ms of the call's return (the call took 59 ms), the connection stayed. FAIL 7 attachment kept: at the first look, 201 ms after the call, both tmux tabs of the connection had other ids (2 tabs with 2 sessions before and after, none unchanged): iTerm2 closed and reopened the session's windows on the `%session-changed` tmux sent its client. Cleanup PASS (the launch tab detached by a bound `detach-client`, the session killed). Threads 18 → 24 |
| Option (a), Saturno | `swift run muxfinder-probe e2e-detach-others --ssh saturno-m4`, the same command | exit 1, 7 of 9 PASS in 16.0 s. The plain client `%exit` and exit 0 within 59 ms (the call 1055 ms). FAIL 7: 81 ms after the call the connection had no tmux tab at all (2 tabs with 2 sessions before). Cleanup PASS. Threads 24 → 30 |
| tmux's reply blocks (private server, no iTerm2) | a `muxfinder-test-proof` session on `tmux -S <mktemp -d /tmp/mfx.XXXXXX>/s`, plain `tmux -C` clients fed from a pipe; then `kill-session` of that session and the folder removed | `display-message -p a ; display-message -p b`: two `%begin`/`%end` blocks; `if-shell -F 1 'display-message -p x'`: two blocks (the `if-shell` and the command it inserted, both flag 1); `detach-client -t '#{client_name}'`: `%error`, "can't find client: #{client_name}" (no format expansion in `-t`). The binding of (b), one client B: `list-clients -t '$0' -F '#{client_pid}:#{client_name}'` listed both clients; the check `list-clients -t '$0' -f '#{&&:#{==:#{client_name},client-<B's pid>},#{==:#{client_pid},<B's pid>}}' -F '#{client_pid}'` printed B's pid, with another pid printed nothing; `detach-client -t 'client-<B's pid>'`: B printed `%exit` and exited 0; one block per command. A control client on a terminal (under `script`) is named by its terminal's path, `/dev/ttys003` |
| Option (b), locally | `swift run muxfinder-probe e2e-detach-others --local`, the final code | exit 0, 9 of 9 PASS in 11.5 s. 3: confirmed in 981 ms, `burial` `buried`, 2 tmux tabs with 2 sessions; 4: the plain client the session's second client (its own pid); 5: `notConfirmed`, no discovery and no iTerm2 request, both clients still attached; 6: `detached(count: 1)` in 63 ms (discovery, the index, the identity check, the listing, the check and one `detach-client` by name), the plain client `%exit` and exit 0 within 60 ms of the call's return; 7: 9 looks over 2148 ms, the same 2 tabs and 2 sessions, the launch tab still owning its connection, buried and in no tab, the connection still showing the session as its only client; 8: the coordinator's detach at 10.2 s, the helper exit 0, the tabs closed, the launch tab gone by itself 230 ms after the helper's result, the session alive with no client; 9: the session killed, nothing left. Threads 29 → 36 |
| Option (b), Saturno | `swift run muxfinder-probe e2e-detach-others --ssh saturno-m4`, the final code | exit 0, 9 of 9 PASS in 18.0 s. 3: confirmed in 2297 ms, buried; 6: `detached(count: 1)` in 1166 ms, the plain client `%exit` and exit 0 within 60 ms; 7: 9 looks over 2150 ms, the same 2 tabs and 2 sessions, the launch tab as before; 8: the coordinator's detach at 10.5 s, the launch tab gone 1 ms after the helper's result; 9: the session killed on Saturno, nothing left there or here. Threads 36 → 40 |
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 900 core tests in 88 suites (19 new in `DetachOtherClientsTests`, one of them `recorderCountsEveryForwardedCall` for `RecordingITerm2Integration.forwardedCallCount`) and 468 UI tests in 46 suites |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Leftovers after every run | `ls` of the launch directory and `/private/tmp`; `tmux ls` on Neptuno and, read-only over ssh, on Saturno; `iterm2 list-sessions` | the launch directory empty; no `mfx.*` folder (the private server's removed); no `muxfinder-test-*` session on either Mac; none of the runs' launch tabs listed, in a tab or buried |

No UI changed (Phase I-11b), so no gallery was regenerated and no `--selftest` was needed.

### Phase I-11a review fixes (2026-11-06)

The adversarial review's three findings (`docs/reviews/phase-I-11a.md`; PLAN.md D37): the
check right before a detach did not bind it, a tmux error could count as a detach, and the age
rule missed clients found after the attachment snapshot. Investigated first on a private tmux
server and in iTerm2 3.7.7's public source (read only, nothing copied), then fixed, then the
real runs again under the same gate as above (`swift build` first, `TMUX_TMPDIR` unset,
`iterm2 status` exit 0 and 38 threads or fewer before each run, the same leftover checks
after).

| Check | Command | Observed result |
|---|---|---|
| iTerm2's reply pairing (source, v3.7.7) | `TmuxGateway.m` and `iTermAPIHelper.m` at the `v3.7.7` tag, read through `gh api` | `parseBegin:`: a `%begin` with flag 0 opens a placeholder with no callback, a flag-1 one takes the oldest command waiting (none: "%begin with empty command queue", an abort). `currentCommandResponseFinishedWithError:`: an `%error` for a command not sent with `kTmuxGatewayCommandShouldTolerateErrors` (a flag-0 placeholder included) aborts: the "tmux Reported a Problem" warning and the connection detached. `sendCommand:responseTarget:responseSelector:` tolerates errors only without a target, and `handleTmuxSendCommand:` always passes one, so every API `SendCommand` that tmux answers with `%error` ends the connection; its answer then has no `output` (set only in the success callback; the failure path answers with neither payload nor status). A flag-0 block is ignored only when it ends with `%end` |
| tmux 3.8, guarded detach (private server) | `TMUX_TMPDIR=$(mktemp -d /tmp/mfx.XXXXXX)`, sessions `muxfinder-test-a` and `-b`, plain `tmux -C` clients fed from pipes | `if-shell -F 1 'display-message -p inserted'`: two blocks, the inserted command's `%begin … 1` like the `if-shell`'s; `if-shell -F 1 'detach-client -t nosuchclient'`: the `if-shell`'s `%end … 1`, then `%error … 1` ("can't find client"). `if-shell -F '#{L:#{?#{&&:#{==:#{client_name},<B>},#{==:#{session_id},$0}},1,}}' 'detach-client -t <B>'`, sent by a client of `$0` for a client B of `$1`: the condition held and B was detached (two blocks), so in the client loop `session_id` is the sender's session. So no single guarded command: D37's two-request binding stays |
| tmux 3.8, the new commands (private server) | the same server | `display-message -p '%s #{client_name}'`: tmux's clock (the second `date +%s` printed) and the name; `list-clients -F '#{client_pid}:#{client_created}:#{client_name}:#{session_id}'`: each client's own session id and creation second; `list-clients -f '#{==:#{session_id},$1}'` listed only `$1`'s client, `-f` naming `$99` printed nothing (`%end`) while `list-clients -t '$99'` answered `%error` ("can't find session: $99"); the check binding name, pid, creation time and `$1` printed B's pid, with the creation time + 1 or `$0` nothing. The first probe ended its private server with `kill-server` (only that socket's server, holding only its two test sessions); the later ones killed their sessions by name; every folder removed |
| Fixtures | `"$HOME/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3" -I scripts/dev/gen-iterm2-fixtures.py` | 47 fixtures; the 44 earlier ones byte for byte as before (SHA-256 compared); new `tmux-send-command-response-empty` (`output` present and empty), `-no-output`, `tmux-response-ok-no-payload` |
| Regressions fail on the old code | each fix reverted in turn, the suite run, the fix restored | the old `output ?? ""` reading: `tmuxCommandWithoutOutputFails` fails (4 issues); the old `-t` listing and a check without creation time and session id: `commandsHoldOnlyValidatedValues` fails (3 issues); the wait for young clients skipped: `waitsUntilEveryClientIsOldEnough` fails for every argument with a wait (8 issues); all pass restored |
| `e2e-detach-others`, locally | `.build/debug/muxfinder-probe e2e-detach-others --local`, the final code (gate at 11:24: `iterm2 status` exit 0, 38 threads) | exit 0, 9 of 9 PASS in 14.1 s. 3: confirmed in 1110 ms, buried, 2 tmux tabs with 2 sessions; 4: the plain client the session's second client (its own pid); 5: `notConfirmed`, no discovery and no iTerm2 request; 6: `detached(count: 1)` in 10105 ms, the plain client started 23 ms before the call and waited for 10000 ms (`ageWait`) until 10 s old, then `%exit` and exit 0 within 53 ms of the call's return (its `detach-client` confirmed with its empty output); 7: 9 looks over 2138 ms, the same 2 tabs and 2 sessions, the launch tab still owning its connection, buried and in no tab, its client the session's only one; 8: the coordinator's detach at 12.9 s answered with its output, the helper exit 0, the tabs closed, the launch tab gone 219 ms after the helper's result, the session alive with no client; 9: the session killed, nothing left. Threads 38 → 42 |
| `e2e-detach-others`, Saturno | `.build/debug/muxfinder-probe e2e-detach-others --ssh saturno-m4`, the final code (gate at 12:19, after waiting for the count to fall from 42: `iterm2 status` exit 0, 16 threads) | exit 0, 9 of 9 PASS in 23.9 s. 3: confirmed in 2088 ms, buried, 2 tmux tabs with 2 sessions; 4: the plain client attached over ssh; 5: `notConfirmed`, no discovery and no iTerm2 request; 6: `detached(count: 1)` in 9472 ms, the plain client started 2380 ms before the call and waited for 8000 ms (`ageWait`), then `%exit` and exit 0 within 52 ms of the call's return; 7: 9 looks over 2142 ms, the same 2 tabs and 2 sessions, the launch tab as before; 8: the coordinator's detach at 17.4 s answered with its output, the launch tab gone 226 ms after the helper's result; 9: the session killed on Saturno, nothing left there or here. Threads 16 → 17 |
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0; exit 0 |
| Unit tests | `swift test` | exit 0: 905 core tests in 88 suites (22 in `DetachOtherClientsTests`, 3 of them new; `tmuxCommandWithoutOutputFails` in `ITerm2APIClientTests`; `identityAnswerWithoutOutput` in `AttachCoordinatorTests`) and 468 UI tests in 46 suites |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Leftovers after both runs | `ls` of the launch directory and `/private/tmp`; `tmux ls` on Neptuno and, read-only over ssh, on Saturno; `iterm2 list-sessions` | the launch directory empty; no `mfx.*` folder; no `muxfinder-test-*` session on either Mac; neither run's launch tab listed, in a tab or buried |

### Phase I-11b — Detach other clients, the UI (2026-11-06)

The popover's "Detach other clients…" on top of the core call I-11a shipped (PLAN.md Phase
I-11, its I-11b calls; D25, D37). No core code changed. The fake iTerm2 of the UI tests
(`SimulatedITerm2`) now answers the core's four commands for a session's connections and its
other clients (state, never a process), so the tests run the real coordinator call; no test
contacts iTerm2, tmux, ssh or the network. No real `hosts.json` was read or written, nothing
went through LaunchServices, and no `--selftest` or `e2e-*` run was made (the core and the
attach did not change). Owed to a person: checklist item 25 (two real Macs, the real popover,
VoiceOver, and the window size afterwards).

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 905 core tests in 88 suites (none new) and 485 UI tests in 47 suites (17 new in `DetachOtherClientsUITests`, 2 of them from the review: a failed "Detach other clients…" and a failed move here seen from the switcher offer no "Try again" there, and a retry there sets no confirmation and contacts nothing, while the popover's "Try again" shows the confirmation with no core call until it is confirmed; each fails with the fix reverted; `FailureMessageTests.messagesArePairwiseDistinct` now includes the 8 new failure messages, `attachFixturesCoverEveryState` the new fixtures) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, signed by the "Apple Development" identity, not notarized; exit 0 |
| Attach gallery | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery attach --appearance light --preview-snapshot docs/screenshots/attach-states-light.png`, then `dark` | exit 0 both; 3136 × 4908 px, 16 states and the context menu card (5 new states): the confirmation for one other client and for two others including one in this Mac's iTerm2 (title, explanation, the window-size sentence, the count, "Cancel" and "Detach other clients"), the results card ("Detaching other clients…" on a row whose badge reads "Open in iTerm2 here · also attached elsewhere" on one line, "Detached 1 other client — the session keeps running", "Detached 2 other clients … (1 had already left)" over two lines, "No other clients to detach — they had already left" with an information mark), the problems card (not attached here, this Mac's tab changed, tmux refused a detach; each with "Refresh") and the failures card (a failed check with "Try again", "Refresh" and "How to turn it on", a failed send, a confirmation for another session); the context menu of the open-here row now lists "Detach other clients…". Inspected in crops (`sips`, `/tmp`): nothing truncated or overlapping, readable in both appearances |
| Popover gallery | `--preview-gallery popover`, light and dark, with `--preview-snapshot docs/screenshots/popover-states-<appearance>.png` | exit 0 both; 4672 × 2200 px, the 11 states; "Selected session open here, offline host" now has 2 clients on its selected row, whose badge reads "Open in iTerm2 here · also attached elsewhere" on one line, inside the row at the popover's width. The hint was kept |
| Switcher gallery | — | not regenerated: no switcher fixture has a session open here with more clients than attachments, so no switcher row changed |

### Phase I-12a — other terminal apps, the proof and the decision (2026-11-06)

The proof of plain tmux attaches for terminal apps without control mode (PLAN.md Phase I-12,
its I-12a calls; D38 and D3's extension). Only probe code and pure core helpers that nothing
uses yet; no app, helper, seam or coordinator change, so no gallery, `--selftest` or `e2e-*`
run. The harness (`plain-proof`) hosts plain tmux clients on pseudo-terminals it opens itself
and never contacts iTerm2 or any terminal app; it was run from the repo root with
`TMUX_TMPDIR` unset, as `.build/debug/muxfinder-probe` (what `swift run` runs) after `swift
build`. Terminal.app and Ghostty were not running (checked with `pgrep` before, and by
`terminals list`), so under *Unattended-run rules* 8 no Apple event was sent to either and no
window run was made: their real runs are owed (below). Before and after every run: no
`muxfinder-test-*` session on Neptuno or (read-only over BatchMode ssh) on Saturno.

| Check | Command | Observed result |
|---|---|---|
| Bundle ids and versions | `plutil -extract CFBundleIdentifier raw` and `CFBundleShortVersionString` of both apps' `Info.plist` | `com.mitchellh.ghostty` 1.3.1; `com.apple.Terminal` 2.15 |
| Scripting dictionaries | `sdef /Applications/Ghostty.app`; `sdef /System/Applications/Utilities/Terminal.app` (read-only; neither app started) | exit 0 both (318 and 588 lines, read in a scratch folder removed afterwards). Ghostty: `new window`/`new tab [with configuration]` return a window/tab; `new surface configuration` with `command`, `environment variables` (`KEY=VALUE` list), `wait after command`, `initial input`, `initial working directory`, `font size`; window, tab and terminal `id` (text); `activate window`, `focus`, `close window`, `close tab`, `close`; no tty, pid or process. Terminal: `do script [in tab/window]` and `do script in new tab [next to]` return a tab; window `id` (integer), `frontmost`, `index`; tab `tty`, `processes`, `busy`, no id (PLAN.md *Verified facts*, "Phase I-12a proof") |
| Ghostty's docs | ghostty.org `docs/features/applescript` and `docs/config/reference` (read) | AppleScript on by default, `macos-applescript = false` turns it off, macOS asks before another app controls Ghostty; config `command` runs through `/bin/sh -c` when it has arguments, `direct:` skips the shell, `shell:` forces it (1.2.0); nothing on whether `environment variables` reach the command or on the ids' shape |
| Terminal apps | `swift run muxfinder-probe terminals list` (and `--help` of `plain-proof`, which contacts nothing) | exit 0: iTerm2 3.7.7 `/Applications/iTerm.app` running, `granted` (0); Terminal 2.15 `/System/Applications/Utilities/Terminal.app` and Ghostty 1.3.1 `/Applications/Ghostty.app` installed, not running, `targetNotRunning` (-600). No prompt, no app started |
| A read-only standard input (diagnosis) | a scratch Python script (`python3 -I`, in a folder removed afterwards) attaching plain clients of a `muxfinder-test-ptyexp` session (killed afterwards) on pseudo-terminals, counting the bytes drawn, never showing them | a client spawned with its terminal as standard input opened read-write: 994 bytes drawn within 0.5 s, with and without a controlling terminal; through a shell that opened standard input read-only (`<`): 0 bytes in 2 s, only the 49-byte detach line. The harness's trampoline opens the terminal once with `<>` |
| Plain proof, locally | `swift run muxfinder-probe plain-proof --local` (the phase's code, before the review fixes; rerun in *Phase I-12a review fixes*) | exit 0, 9 of 9 PASS in 1.3 s. 2: client A confirmed by its `client_tty` 233 ms after its start (readings every 200 ms, at most 20 ms each), its pid the child's, its controlling terminal its pseudo-terminal (`ps -o tty=`), tmux seeing `xterm-256color 80x24`, control 0, `attached,focused,UTF-8`; 3: a pseudo-terminal with no client matched none of 1; 4: B and A each confirmed by their own terminal among 2; 5: A2 on A's terminal: 2 candidates among 3, none confirmed, A confirmed again once A2 was ended (SIGTERM, exit 1); 6: the check and `detach-client -t /dev/ttys004` in 22 ms, A's child exit 0 by itself, B still attached; 7: M (`attach-session -d`) the session's only client within 239 ms, B's child exit 0 by itself; M got A's freed `/dev/ttys004`; 8: M detached the same way in 22 ms, exit 0, the session alive with no client; 9: 4 pseudo-terminals closed (4210 bytes discarded, counted only), the session killed, no child process left. Four earlier development runs of intermediate code: 9 of 9 each |
| Plain proof, Saturno | `swift run muxfinder-probe plain-proof --ssh saturno-m4` (the phase's code, before the review fixes; rerun in *Phase I-12a review fixes*) | exit 0, 9 of 9 PASS in 17.7 s. 2: A confirmed by its token 1674 ms after its ssh started; 3: a token nobody carries matched none of 1; 4: B and A each confirmed by their own token among 2; 5: A2 with A's token: 2 candidates among 3, none confirmed, A confirmed again once A2's ssh was ended (SIGTERM, exit 255); 6: check and `detach-client -t /dev/ttys003` in 1437 ms (two ssh connections), A's ssh exit 0 by itself, B still attached; 7: M the only client 1672 ms after its start, B's ssh exit 0 by itself; M got A's freed remote `/dev/ttys003`; 8: M detached in 1430 ms, exit 0, the session alive; 9: the session killed on Saturno, no child left. 13 readings, 727–744 ms (median 733 ms). An earlier run of the same code: 9 of 9 in 17.7 s |
| Interrupted run | `plain-proof --ssh saturno-m4` sent SIGTERM 6 s after its start | exit 143: steps 1–3 PASS, 4 FAIL "interrupted", cleanup PASS (2 clients' ssh ended, 2 pseudo-terminals closed, the session killed, no child left) |
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 925 core tests in 91 suites (20 new in 3 suites: `PlainLaunchTests` 11, the remote script run through sh and zsh against a fake tmux (the guard still refuses, the attach is a child of the shell holding the token, `-d` for a move here, bad tokens 68) and the remote reading against real waiting launches (a match, none, the same token twice ambiguous); `TerminalCommandTextTests` 6, the text read the same by sh, zsh, bash, dash, ksh, tcsh and csh (fish not installed, skipped); `AutomationPermissionTests` 3) and 485 UI tests in 47 suites (unchanged) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Leftovers after every run | `tmux ls` on Neptuno and, read-only over BatchMode ssh, on Saturno; `ps -A -ww -o args=` on both, counted for the scripts' and sessions' names only; `pgrep`; `ls /private/tmp` | no `muxfinder-test-*` session and no launch shell on either Mac, no process of the harness, no folder or file of the runs in `/private/tmp` |

**Owed to the user** (Terminal and Ghostty real runs; *Unattended-run rules* 8 let an
unattended run do none of them). Start the app yourself, then from a shell in iTerm2 run
`swift run muxfinder-probe terminals list` until it shows that app `running`; the first
`osascript` below asks for the Automation permission if it is `notDetermined`. Each step opens
only a new window and closes only that one, by its id. Record the answers' shapes in PLAN.md
D38 and here, never a window title or terminal contents.

1. Terminal, what `do script` returns:
   `osascript -e 'tell application "Terminal"' -e 'set t to do script "exec /bin/sleep 20"' -e 'delay 1' -e 'return {t, tty of t, busy of t}' -e 'end tell'`
   (expected: the tab as a reference through its window's id, a `/dev/ttysNNN` path, `true`).
   After 20 s, `osascript -e 'tell application "Terminal" to exists window id <n>'` shows
   whether the window closed itself when its process ended (Settings › Profiles › Shell,
   "When the shell exits"); if it is still there and `busy` is false, `osascript -e 'tell
   application "Terminal" to close window id <n>'`.
2. Terminal, a plain attach confirmed by its `tty`:
   `/opt/homebrew/bin/tmux new-session -d -s muxfinder-test-owed sleep 600`, then
   `osascript -e 'tell application "Terminal" to tty of (do script "exec /opt/homebrew/bin/tmux -u attach-session -t =muxfinder-test-owed")'`;
   `/opt/homebrew/bin/tmux list-clients -F '#{client_tty} #{session_name}'` must show that
   `tty` for `muxfinder-test-owed`; `/opt/homebrew/bin/tmux detach-client -t <that tty>` ends
   it (the window closes or shows the process ended); then
   `/opt/homebrew/bin/tmux kill-session -t =muxfinder-test-owed`.
3. Ghostty, whether `environment variables` reach a two-word `command`, and the ids:
   `osascript -e 'tell application "Ghostty"' -e 'set cfg to new surface configuration' -e 'set command of cfg to "/usr/bin/printenv MUXFINDER_OWED_CHECK"' -e 'set environment variables of cfg to {"MUXFINDER_OWED_CHECK=reached"}' -e 'set wait after command of cfg to true' -e 'set w to new window with configuration cfg' -e 'return {id of w, id of focused terminal of selected tab of w}' -e 'end tell'`
   (the window shows `reached` when they do); then
   `osascript -e 'tell application "Ghostty" to close window id "<window id>"'`. Repeat with
   `"direct:/usr/bin/printenv MUXFINDER_OWED_CHECK"` as the command.
4. Ghostty, a plain attach: as step 2 with `set command of cfg to "/opt/homebrew/bin/tmux -u attach-session -t =muxfinder-test-owed"`
   and `wait after command` false; `list-clients` shows one client of the session on a
   `/dev/ttys…`; detach it with `detach-client -t <that tty>`; the window closes by itself or
   is closed by its id; then kill the session.
5. Optional: with `macos-applescript = false` in Ghostty's config (restart Ghostty), the error
   number step 3 gets, for I-12d's "Ghostty's AppleScript is turned off".
6. Once I-12c has built it: `swift run muxfinder-probe e2e-plain --terminal terminal --local`,
   `… --terminal terminal --ssh saturno-m4`, `… --terminal ghostty --local` and `…
   --terminal ghostty --ssh saturno-m4`, each with that app running and `granted`.


### Phase I-12a review fixes (2026-11-06)

The adversarial review's two findings (`docs/reviews/phase-I-12a.md`; PLAN.md D38): the
harness's detach checked a client and then ran `detach-client -t <name>` as a second command
(a second ssh connection remotely), so a client that took the checked one's terminal in
between (terminal paths are reused at once) could be detached in its place; and the local
attaches named the session by its id alone, which a restarted server reuses. Both are now
**bound**: one `if-shell -F -t '<id>' '<condition>' '<command>' '<otherwise>'` that the tmux
server checks and carries out in one command queue, nothing in between
(`Sources/MuxFinderCore/Launch/PlainBoundCommands.swift`: `BoundSessionIdentity`,
`PlainLaunch.localAttachArguments(session:detachingOthers:)`, `PlainClientDetach`; the remote
script's attach the same, after the guard). The forms were tried first on private servers
(`TMUX_TMPDIR=$(mktemp -d /tmp/mfx.XXXXXX)`, `muxfinder-test-exp1` and `-exp2`, plain clients
on pseudo-terminals of a scratch script and control clients; the sessions ended, every folder
removed), then the real runs again from the repo root with `TMUX_TMPDIR` unset after `swift
build`. No iTerm2, Terminal or Ghostty contact.

| Check | Command | Observed result |
|---|---|---|
| tmux 3.8, the bound attach (private server) | `tmux -u if-shell -F -t '$0' '<session_id, session_created, pid, start_time, session_name checks>' "attach-session [-d] -t '$0'" "run-shell 'exit 65'"`, on a pseudo-terminal and with standard input `/dev/null` | matching, on a terminal: the client attached (`attached,focused,UTF-8`, its pid the tmux process's); with `-d` the other client of `$0` exited 0 and a client of `$1` stayed; one value off: exit 65 (`'exit 65' returned 65` on its terminal), nothing attached or detached; matching with no terminal: `open terminal failed: not a terminal` (exit 1) and, with `-d`, the other client still attached; with no server: exit 1 (`error connecting to …`), no server and no socket created |
| tmux 3.8, the bound detach (private server) | `if-shell -F -t '$0' '<session checks, #{==:#{L:#{?#{==:#{client_name},<name>},1,}},1} and the client loop on name, client_pid, client_created, client_session>' "detach-client -t '<name>'" 'display-message -p muxfinder-not-this-client'`; `display-message -p -t '$0' '<the condition>'` to read it | a client of `$1` named against `$0`, the pid off, the session's creation time off, a missing id `$7`, the client's creation time off: condition 0, the marker printed, exit 0, every client still listed; the exact one: condition 1, no output, exit 0, that client's process exited 0, the others stayed. `#{L:…}` listed both clients of `$0` with their own names and `client_session`, `session_id` the target's for each |
| Regressions fail on the old code | each fix reverted in turn in the builder, the suites run, the fix restored | the detach's client binding dropped (the session's condition only, as the old two-command detach acted): `buildsTheBoundDetach` (1 issue) and `bindsTheDetachOnAPrivateServer` (20 issues: the clients with pid, creation time or name off, and the client of another session, were detached); the local attach back to the bare `-u attach-session [-d] -t <id>`: `buildsTheBoundLocalAttach` (3 issues), `bindsTheAttachOnAPrivateServer` (18 issues: the restarted server's session with the old id and name and all 16 variant runs reached tmux's attach, exit 1, instead of 65), and `attachesAsAChildOfTheTokenShell` (sh and zsh) and `moveHereDetachesOthers` (the remote script's recorded arguments no longer the builder's); the remote script's tail back to `"$t" -u attach-session -t "$id"`: `buildsTheRemoteScripts`, `attachesAsAChildOfTheTokenShell`, `moveHereDetachesOthers` and `readsTheLaunchClientByItsToken` fail; all pass restored. In the reverted attach's runs the no-server case's bare `attach-session` started a private server (a bare attach starts one; it found no session and exited), re-creating 4 private `/tmp/mfx-*` test folders after the test had removed them, each holding only a dead socket; they were removed. The final code's runs leave none |
| Build | `swift build -Xswiftc -warnings-as-errors` | exit 0 |
| Unit tests | `swift test` | exit 0: 931 core tests in 92 suites (`PlainBoundCommandsTests` 7 new: the condition, its refusals, the bound attach and detach text, the detach outcome, on a private server the attach (a restarted server's session with the old id and name refused, eight one-field-off identities refused with 65 for attach and move here, the exact one reaching tmux's attach, exit 1 with no server and none started) and the detach (three control clients: pid, creation time, name, any session field off, or a client of another session, detached nothing; the exact one only its client); `PlainLaunchTests` 10, the old local-arguments test replaced, the remote script's recorded arguments compared with the local builder's for the guard's four values, its 65 passed through) and 485 UI tests in 47 suites (unchanged) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Plain proof, locally | `swift run muxfinder-probe plain-proof --local` (final code) | exit 0, 9 of 9 PASS in 1.5 s. 2: A confirmed by its `client_tty` 241 ms after its start; 3: a pseudo-terminal with no client matched none, a stale attach there (the server's start time 1 s off) exited 65 after 60 ms, still none and 1 client; 5: with A2 on A's terminal 2 candidates among 3, and the bound detach of A (two clients of that name) detached nothing in 10 ms, all 3 stayed; 6: a stale bound detach of A (creation time 1 s off) detached nothing in 11 ms, A and B stayed; the bound detach of `/dev/ttys004` in 9 ms, A's child exit 0 by itself, B still attached; 7: a stale move here exited 65 after 60 ms, B still attached; M (bound `attach-session -d`) the only client within 244 ms, B's child exit 0 by itself; 8: M's bound detach in 11 ms, exit 0, the session alive with no client; 9: 5 pseudo-terminals closed (4492 bytes discarded, counted only), the session killed, no child left. Readings 17, median 11 ms, at most 20 ms |
| Plain proof, Saturno | `swift run muxfinder-probe plain-proof --ssh saturno-m4` (final code) | exit 0, 9 of 9 PASS in 20.7 s. 2: A confirmed by its token 1661 ms after its ssh started (the remote bound attach); 3: a token nobody carries matched none, a stale attach with a new token exited 65 after 792 ms (the guard refused it), still none; 5: A2 with A's token: 2 candidates among 3, none confirmed (A2 has its own remote terminal, so no shared name); 6: a stale bound detach of A detached nothing (713 ms), the bound detach of `/dev/ttys003` in 717 ms (one ssh connection), A's ssh exit 0 by itself, B still attached; 7: a stale move here exited 65 after 792 ms, B still attached; M the only client 1663 ms after its start, B's ssh exit 0 by itself; 8: M's bound detach in 714 ms, the session alive; 9: the session killed on Saturno, no child left. Readings 16, median 730 ms, at most 740 ms |
| Leftovers after both runs | `tmux ls` on Neptuno and, read-only over BatchMode ssh, on Saturno; `ps -A -ww -o args=` on both, counted for the scripts' and sessions' names only; `ls -d /tmp/mfx.*` | no `muxfinder-test-*` session and no launch shell on either Mac, no process of the harness or of the scratch script, no `mfx.*` folder |

What remains: nothing between a check and its attach or detach. A remote stale attach is
refused by the guard before the bound attach, since both check the same four values; the
remote bound attach's refusal is covered by the hermetic test that its arguments are the local
builder's, whose refusals run on a private server. tmux names a client to `detach-client -t`
by name only, so the detach's binding rests on that name being unique among attached clients,
which the same command checks.


### Phase I-12b1 — terminal definitions, loader and AppleScript runner (2026-11-06)

The terminal definitions (PLAN.md D38, *Definitions (I-12b1)*): the schema and its parser,
the loader under D19's rules, the two built-ins in `Resources/Terminals/`, the launch
command's forms and `exec` argv expansion, the AppleScript runner seam with its handler
contract, per-definition app facts, and `terminals list` extended. Nothing in the app, the
helper or the coordinator uses them yet, so no gallery, `--selftest` or `e2e-*` run. No
script of a built-in was compiled anywhere (compiling a `tell` block reads the target app's
dictionary); Terminal and Ghostty were not running, so no Apple event was sent to either
(*Unattended-run rules* 8). No iTerm2 API contact, no tmux.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 986 core tests in 97 suites (55 new in 5 suites: `TerminalDefinitionTests` 25, every schema refusal (unknown key at the top, in each `open` kind and in `focus`; bad and reserved ids; bad names, bundle ids, versions, notes, script names, executables; a placeholder or brace inside a longer argument, unknown placeholders, each placeholder not exactly once, too many arguments; `tty`/`windowID` focus with `exec`; missing, newer, zero, negative, text, fractional and boolean `schemaVersion`), version comparison, both built-ins loading cleanly with the forbidden commands absent from their text; `TerminalDefinitionLoaderTests` 13, on private temporary folders: links (a file, a script, the folder, a folder on its path, `/var`), folder modes other than 0700, another owner, ACLs on folder and file, group- or world-writable files (0644 accepted), a FIFO and a folder named `*.json`, 64 KiB and 256 KiB limits at and over the edge, 33 files, a missing folder and a dangling link (no problem, nothing created), an unsafe folder (exactly one problem, built-ins kept), overrides, duplicate ids in either folder; `TerminalLaunchCommandTests` 6, `shellText`, `words` and its 23 refused characters, `exec` argv expansion and its refusals; `AppleScriptRunnerTests` 8, the real runner over three test scripts with no `tell` block (arguments passed as values, a wrong shape, a raised error with its number, a missing handler -1708, a syntax error -2741), the strict open reply, the fake; `TerminalAppFactsTests` 3, over a fake inspector) and 485 UI tests in 47 suites (unchanged). A first full run had one failure in `FolderSearchTransportTests.answersAndEndsAtEndOfInput` (2.018 s against its 2 s bound under the parallel load; untouched by this phase), which passed alone (8 of 8) and in the full rerun |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0, Apple Development identity; `Contents/Resources/Terminals/` holds the four files, identical to `Resources/Terminals/` (`diff -r`), sealed in `_CodeSignature/CodeResources`; verify exit 0 |
| Terminal apps, before and after | `pgrep -x Terminal`; `pgrep -x ghostty` (before the first probe run and after the last) | exit 1, no output, both times: neither app ran, none was started |
| `terminals list`, from the repository | `swift run muxfinder-probe terminals list`; `--help` | exit 0: the three app rows as in I-12a (iTerm2 running and `granted`; Terminal 2.15 and Ghostty 1.3.1 installed, not running, `targetNotRunning` -600); `definitions` Ghostty and Terminal, `builtIn`, open `appleScript` with `words` / `shellText`, focus `windowID` / `tty`, minimum version `meets`, permission `targetNotRunning`; `problems` empty (the real user folder does not exist: only looked at, not created). `--help` exit 0, contacts nothing; a missing option value exit 64 |
| `terminals list`, private folders | `mktemp -d /private/tmp/mfx.XXXXXX` holding `builtin/` (the four built-in files) and `terminals/` (0700: an `exec` definition `wezterm`, a definition with id `terminal` and its own script, and `broken.json` with `--command={helper}`), then `terminals list --builtin-directory <it>/builtin --user-directory <it>/terminals` | exit 0: `ghostty` `builtIn`, `terminal` `userOverride` (`my-terminal.json`), `wezterm` `user` (permission `notNeeded`, `notInstalled`); one problem, `broken.json` `placeholderInsideArgument` ("Its argument 1 has a placeholder or a brace inside other text. …"). The same user folder named through `/tmp`: no user definition, one problem `unsafeFolder.symbolicLink`. The folder was removed afterwards |

The first private-folder run found a probe bug, fixed before the runs above: the probe passed
its folder options through `standardizedFileURL`, which turns `/private/tmp/…` into the
symbolic link `/tmp/…`, so the user folder was refused; the options are now taken as given.

**Owed** (to the user, or to I-12c's `e2e-plain` under the same gate): compiling and calling
the built-in scripts, with that app running and `terminals list` showing it `granted` for the
app running the command: Terminal's open (the window found by the new tab's `tty`, the window
id and tty returned), focus (`set index … to 1`, the tab `selected`), close (refused with 1001
while busy, then closed by id); whether `do script` on a Terminal that was not running opens a
second window; Ghostty's open (`new window with configuration`, the id's shape), `activate
window` and `close window` by id. The I-12a owed steps stay as listed there.


### Phase I-12b2 — helper plain mode (2026-11-06)

The launch helper's plain modes (PLAN.md D38 *Helper plain mode (I-12b2)*, D14 *Plain modes*):
`muxfinder-launch attach-plain <uuid>` and `profile-plain <host id>`, the attach request's
`terminal` field (with `keepsMinimumLifetime` on plain requests) and the early report
`<uuid>.report.json`. Nothing in the app or the coordinator writes a plain request yet
(I-12c), so no gallery, `--selftest` or `e2e-*` run here; the regression runs of the helper's
`attach` (`e2e-local`, `e2e-bury --local`) are the orchestrator's, under the gate in
`PROGRESS.md`. No iTerm2, Terminal.app or Ghostty contact, no remote host, no real launch
directory and no real tmux server: the real check below runs on a private server.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | first full run: 1 issue, in the "Directory store" suite (untouched by this phase), which passed alone (31 of 31) and in the full rerun; the rerun exit 0: 1022 core tests in 101 suites (30 new in 4 suites: `LaunchHelperPlainTests` 17, the mode words and their `{mode}` forms, plain mode never taken from `TERM_PROGRAM`/`TERM`, the `terminal` field's round trip, absence (`iterm2`) and refused values, `keepsMinimumLifetime` refused on iTerm2 requests, the store's typed takes refusing the other terminal both ways (72, the file gone), `attach` refusing a plain request and `attach-plain` an iTerm2 one (explicit or missing) with nothing run, the local and remote argv equal to `PlainLaunch`'s builders with and without a move here, the terminal opened read-write, every exit status mapped and the result equal to `attach`'s for the same end, no OSC 1337 and no status report request, the explanation and the wait for Return kept, the minimum lifetime only with `keepsMinimumLifetime: true`, the report's fields written right after the spawn, 0600, no temporary file left, peeked twice and removed with the result, no report from `attach`, test mode's digest with the child's pid and the launch delay; `PlainLaunchReportTests` 6, the write's atomicity (a planted link replaced, its target untouched), refused writes, malformed, other-id, bad-value, oversized (16 KiB), group-readable and linked reports as typed failures left in place, removal with the result and by the sweep, kernel start times, terminal paths; `LaunchHelperProfilePlainTests` 5, local and remote argv without `-CC` (and `profile` unchanged), the plain remote script run by `/bin/sh` against a fake tmux for six names, the fallbacks, test mode; `LaunchHelperPlainBinaryTests` 2, below) and 485 UI tests in 47 suites (unchanged). One existing expectation grew by the new key: `LaunchModelsTests.requestRoundTrip`'s key set now includes `terminal` (`"iterm2"`) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app`; `build/muxFinder.app/Contents/MacOS/muxfinder-launch --help` | exit 0, Apple Development identity; verify exit 0; the usage line `usage: muxfinder-launch attach\|attach-plain\|ssh-setup <launch id> \| profile <host id> \| profile-plain <host id>` |
| Read-write standard input | `swift test --filter LaunchHelperPlainBinaryTests` (`reopensTheTerminalReadWrite`) | a pseudo-terminal's slave reached only read-only is opened again `O_RDWR` (same device); a child run with `terminalReadWrite` wrote through its standard input (exit 0, the bytes on the master); a pipe and `/dev/null` are no terminal, nothing reopened |
| Real plain attach of the built helper | `swift test --filter LaunchHelperPlainBinaryTests` (`realPlainAttachOnAPseudoTerminal`: the debug helper), then `MUXFINDER_TEST_LAUNCH_HELPER=<repo>/build/muxFinder.app/Contents/MacOS/muxfinder-launch swift test --filter LaunchHelperPlainBinaryTests` (the signed bundle's helper) | pass both times, 0.1–0.4 s. The test opens a pseudo-terminal itself (80 × 24, everything drained and counted, never kept) and runs `/bin/sh` in a new session that opens it as standard input read-only and output and error write-only (its controlling terminal) and `exec`s `muxfinder-launch attach-plain <uuid>` with `TMUX_TMPDIR` a folder from `mkdtemp("/private/tmp/mfx.XXXXXX")`, a private `MUXFINDER_LAUNCH_DIRECTORY`, test mode, `MUXFINDER_LAUNCH_NO_WAIT=1`, `TERM=xterm-256color`, against its own `muxfinder-test-plain-helper-<8 hex>` session (`sleep 600`) on that private server and a plain request (`terminal` `terminal`). The report named that pseudo-terminal and the helper's pid; its child pid was the digest's `attachChildProcessID`, the helper's own child, with the kernel's start time; the session had exactly one client, on that terminal, its pid the child's; at least 200 bytes were drawn; the bound `PlainClientDetach` (all six session fields, the client's name, pid and creation time) answered `detached`; the helper exited 0 with a success result (child `exited(0)`); taking the result removed the report and left the launch directory empty; the session was killed (only `muxfinder-test-*` ones, never `kill-server`), the server gone, the attach child gone. With `MUXFINDER_TEST_LAUNCH_HELPER` naming a missing file the test is skipped (the override is honored) |
| The check fails without the reopen | the runner's reopen replaced by `nil` for one run, then restored | both real tests failed: the child could not write through its read-only standard input, and tmux drew under 200 bytes on the helper's terminal; restored, both pass |
| Leftovers after every run | `pgrep -fl muxfinder-test-plain-helper`; `ls -d /private/tmp/mfx.*` | exit 1, no process; no folder |


### Phase I-12b3 — terminal seam (2026-11-06)

The terminal seam (PLAN.md D38 *Terminal seam (I-12b3)*): the protocol `TerminalBackend` at
the attach coordinator's session operations, iTerm2's backend `ITerm2TerminalBackend` (a
wrapper forwarding each operation to `AttachCoordinator` unchanged), and the plain window
layer `PlainTerminalWindows` (open, focus and close of a terminal app's window from a
`LoadedTerminalDefinition`) with its spawn and activation seams, fakes and one failure enum.
Nothing calls the seam yet (I-12c), and no file under `Attach/`, `ITerm2/`, `Launch/`, the UI,
the probe or the helper changed, so no runtime path changed: the regression is every existing
test passing with no expectation edited, and no gallery, `--selftest` or `e2e-*` run is due.
Hermetic only: the built-in definitions were loaded as text and driven through
`FakeAppleScriptRunner`; no script was compiled, no Apple event sent, no terminal app or iTerm2
contacted or launched, no tmux.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (the phase's code, before the review fixes; rerun in *Phase I-12b3 review fixes*) | exit 0: 1053 core tests in 104 suites (31 new in 3 suites: `ITerm2TerminalBackendTests` 9, each scenario run twice on fresh, identical coordinator fakes, directly and through the backend, with equal results, updates, iTerm2 fake calls, launch store records and discovery calls (launch ids compared by position): attach and `state(of:)`, move here confirmed and refused, create and attach with and without `onCreated` and a creation failure, the current session found and gone, detach of a session's two attachments, detach other clients confirmed and refused, a launch tab focus equal to `showLaunchTab` (`shown`, `notOpenedHere`), a plain window handle refused with nothing sent; `PlainTerminalWindowsTests` 16, Terminal's open with D3's command text and `attach-plain`, Ghostty's with the token the last word, an `exec` definition spawned inside the app with every placeholder one argument, the compile once per loaded definition across opens, focuses and closes (another definition, a reloaded one and a new layer compile their own), every facts-gate refusal with nothing compiled, sent or started and every status that goes ahead, an `exec` definition's gate without a permission read, the launch command refused before anything, every open failure typed (compile, handler number, -1743, malformed replies, no script, spawn), focus by tty, by window id and by app (no event, no facts read) with each missing value and refusal, close only of recorded ids (busy kept, missing and app-not-running forgotten, no id, another definition's window), the newest 64 ids kept; `PlainTerminalSeamsTests` 6, the real spawner on `/bin/sleep 30` (returns at once, the program alive after the call, a session and process group of its own, reaped after a `SIGKILL`) and `/usr/bin/true` (reaped), its refusals (`ENOENT`, not a file URL, NUL), the real activator for an identifier nobody uses (`notRunning`, nothing launched), the fakes, and all 17 failure kinds with their sentences) and 485 UI tests in 47 suites, unchanged |
| Repeated runs | `swift test --skip-build --filter "ITerm2TerminalBackendTests\|PlainTerminalWindowsTests\|PlainTerminalSeamsTests"` 5 times; `--filter ITerm2TerminalBackendTests` 20 times | all passed every time |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Terminal apps after the runs | `pgrep -x Terminal`; `pgrep -x ghostty` | exit 1, no output: neither app ran |

Two findings while writing the tests, neither a code change outside the new files: the first
comparison of the session detach failed because the attachment index checks several
connections' identities concurrently, so their order differs between any two runs (the
adapter's or not); that comparison now takes those requests in any order and the
`detach-client` commands in order. And one later full `swift test` run had a timing issue in
`FolderSearchTransportTests.answersAndEndsAtEndOfInput` (its 2 s bound, a suite this phase did
not touch); it passed alone and in the next full run (exit 0, the counts above).

**Owed:** nothing new in this phase. Compiling and calling the built-in scripts for real (open,
focus and close in Terminal and Ghostty) stays owed as listed in *Phase I-12b1*, to the user or
to I-12c's `e2e-plain` under the same gate; the `exec` spawn of a real terminal app (no
built-in uses `exec`) is owed to whoever adds such a definition.


### Phase I-12b3 review fixes (2026-11-06)

The adversarial review's three findings (`docs/reviews/phase-I-12b3.md`; PLAN.md D38 *Terminal
seam (I-12b3)*), each fixed in `Sources/MuxFinderCore/Terminals/` with a hermetic regression:
**the opener** (blocker): a window and its close record were tied to the definition id only, so
after a same-id override or reload a window could be focused or closed through another app's
or another script's handler; now `PlainTerminalWindow.openedBy` and each record hold the
`LoadedTerminalDefinition` that opened it (compared whole), and a focus or close through any
other is `definitionChanged` (a new, 18th failure case) with nothing read, compiled or sent.
**Forgetting** (blocker): a focus that found the window missing (-1728) or its app not running
left the record, so a later close sent the stale id; now a focus's -1728 forgets that record,
and an app seen not running (any facts read, an open's included, or the activator) has every
record of its bundle identifier forgotten. **The reaper** (should-fix): it dropped its watch
after one `waitpid(WNOHANG)`, also when that answered 0 (XNU posts the exit event before the
child is a zombie), leaving a zombie; now the child stays pending and is waited for again
after 1, 2, 4, … ms, at most 1 s apart, until its pid or `ECHILD`. Fakes and `/usr/bin/true`
only: no script compiled, no Apple event, no terminal app or iTerm2, no tmux.

| Check | Command | Observed result |
|---|---|---|
| The regressions | `swift test --filter "ITerm2TerminalBackendTests\|PlainTerminalWindowsTests\|PlainTerminalSeamsTests"`, 5 times | 36 tests, all passed every time. `bindsAWindowToTheDefinitionThatOpenedIt`: Terminal's window focused and closed through an override for another app with its own script, and through the definition with another script: `definitionChanged` ("Terminal"), nothing compiled, called or read; a window value naming the override with the recorded id `notOpenedHere`; the same files loaded again (an equal value) focus and close it; an `exec` window's `app` focus through a variant with another bundle identifier refused, the activator not asked. `focusFindingTheWindowGoneRevokesItsClose`: Terminal (by tty) and Ghostty (by id), a focus answered -1728, then the close `notOpenedHere`, no `muxfinder_close`; the other window still closes. `anAppSeenNotRunningRevokesItsWindows`: a focus's facts showing Terminal not running forget the built-in's and a lowercase-bundle-identifier variant's records, not Ghostty's; the activator's `notRunning` and an open's facts the same; each later close `notOpenedHere`. `reaperKeepsWaitingWhenTheExitComesFirst`: the wait seam answers 0, `EINTR`, 0, then real waits; `/usr/bin/true` reaped, the watch dropped, at least 4 waits, the delays 1, 2, 4 … 512, 1000, 1000 ms. `reaperStopsAtNoSuchChild`: `ECHILD` ends the watch after 1 wait (the test reaps the child itself) |
| Regressions fail on the old code | each fix reverted in turn (the data model kept), its tests run, the fix restored | the opener checks dropped and records matched by definition id: `bindsAWindowToTheDefinitionThatOpenedIt` 9 issues, the calls `open, focus, close, focus` (the window closed through the other app's script); the forgetting dropped (close forgetting only its own record on `appNotRunning` or -1728, as before): `focusFindingTheWindowGoneRevokesItsClose` 8 issues (close calls `["7"], ["8"]`), `anAppSeenNotRunningRevokesItsWindows` 8 issues (close calls `1, 2, G, 3, 4, 5`), `closeMapsBusyAndMissingWindows` still passing; the old single-wait reap: `reaperKeepsWaitingWhenTheExitComesFirst` 2 issues (1 wait, the child left a zombie and reaped by the test), `reaperStopsAtNoSuchChild` passing. All pass restored |
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` | exit 0: 1058 core tests in 104 suites (5 new: 3 in `PlainTerminalWindowsTests`, 2 in `PlainTerminalSeamsTests`) and 485 UI tests in 47 suites |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Leftovers | `pgrep -fl "/usr/bin/true\|/bin/sleep 30"`; `pgrep -x Terminal`; `pgrep -x ghostty` | exit 1 each: no test child left, neither app ran |

Existing tests edited (finding 1 changes the window's shape): every `PlainTerminalWindow`
built in `PlainTerminalWindowsTests` (5 places) and `ITerm2TerminalBackendTests` (2; those two
tests now `throws`), and the one recorded-window expectation, name the opening loaded
definition instead of its id, with the same meaning; `everyFailureHasItsSentence` gained the
`definitionChanged` row and counts 18 kinds. No other expectation changed.


### Phase I-12c1 — the plain backend (2026-11-06)

The plain backend (PLAN.md D38 *Plain backend (I-12c1)*): `PlainTerminalBackend`, the terminal
seam's conformance for one plain-mode terminal definition, writing plain requests, opening
windows through the window layer, confirming the attach only from evidence (the helper's early
report plus tmux's client list), detaching and moving here through D38's bound tmux commands,
and keeping its attachments in memory. Nothing calls it yet (I-12c3 rewires the app, the
self-tests and the probe), so no runtime path changed: the regression is every existing test
passing with no expectation edited, and no gallery, `--selftest` or `e2e-*` run is due.
Hermetic tests use the fake window layer, a scripted process runner for tmux and ssh, the
existing fake discovery, session creator and manual clock, and a real `LaunchStore` on a
private folder; one end-to-end test runs the built helper on a pseudo-terminal of its own
against a private tmux server. No Apple event, no script compiled, no terminal app or iTerm2
launched or contacted, no ssh, nothing of the user's tmux server touched.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1090 core tests in 107 suites (32 new in 3 suites, below) and 486 UI tests in 47 suites (1 new) |
| `PlainTerminalBackendTests` (21) | `swift test --filter PlainTerminalBackendTests` | This Mac: the plain request (`terminal` the definition's id, its `keepsMinimumLifetime`, the four identity values, no move-here marker), one open with the launch id, the listing `/bin/sh -c <script> muxfinder '' list-clients -F <localFormat>` without `TMUX`, confirmed with the record's six session fields, client, no token and the report's terminal, states `requested`, `plainLaunched`, `plainConfirmed`, one focus; no candidate, two candidates, a stale report (another start time, the child gone, another pid) each `timedOut`; a report without a terminal `cannotConfirmHere` with no listing; a malformed and an oversized report `launchStore(fileMalformed)` and `(fileUnsafe(tooLarge))`; a helper result first (`helperEnded`, `sessionGone`, `sessionChanged`, `helperFailed`) before any reading; a failed listing `clientCheckFailed`, "no server" an empty listing. SSH host: the token reading's exact ssh argv (D6 options, `remoteScript` with override, `$3` and the launch id), confirmed with the token kept; none then two candidates publish `plainStillWaiting` once past 20 s, then a single match confirms; none at all reaches `waitLimitReached` at 300 s; an unreadable answer and ssh's 255 `clientCheckFailed`. Ten open failures each `terminalWindow` with the same error, one open each, the request withdrawn; a failed focus keeps the attach confirmed. Two concurrent attaches share one discovery, request, window and result; an unresolved earlier launch refuses the next attach `earlierLaunchPending` (one window), and once its result exists the next attach goes ahead; a withdrawn launch blocks nothing. A live attachment (the presence check's exact argv) is `plainFocused`, no window opened; a stale one (the check refuses, or its helper's result exists) is dropped and a window opened; a check that cannot run fails with nothing opened. Focus: a plain window through the layer, another definition's refused there, an iTerm2 launch tab `handleOfAnotherTerminal`, nothing run. The new kinds |
| `PlainTerminalBackendDetachTests` (10) | `swift test --filter PlainTerminalBackendDetachTests` | Detach on This Mac: exactly `/bin/sh -c <script> muxfinder '' if-shell -F -t $3 <condition> "detach-client -t '/dev/ttys004'" "display-message -p muxfinder-not-this-client"` over the six fields, `detached`, the helper's result taken (no file left), the attachment dropped, a second detach `nothingAttached` with nothing run; over ssh the same bound arguments in one BatchMode call; no attachment `nothingAttached` with no discovery or tmux; the bound check's refusal `notSent` (dropped), a failed run `notClosed` (kept). Move here: another session's confirmation runs nothing; the request's move-here marker gives `attach-session -d` locally and `remoteMoveHereScript` remotely; with the attachment live, `alreadyOpenInTerminal`. Detach other clients: the kept client the attachment's, only the session's other client detached with the bound command, the listing's exact argv; a 5 s old client waited 6 s; another session's confirmation, no attachment (nothing run), the kept client missing (`identityChanged`), a refused detach (`nothingToDetach`, gone 1), a failed one (`plainDetach`, may have sent), an unreadable listing. Create and attach (and a failed creation, nothing opened); the current session by name and the state per key |
| `PlainTerminalBackendEndToEndTests` (1) | `swift test --filter PlainTerminalBackendEndToEndTests` | The built `muxfinder-launch attach-plain` started by the fake open on a pseudo-terminal of the test's, against a `muxfinder-test-plain-backend-*` session on a private server (`-f /dev/null`, private `HOME` and `TMUX_TMPDIR` from `mkdtemp`), a private launch directory, `MUXFINDER_LAUNCH_NO_WAIT=1`, real `DiscoveryProbe` and `PlainTmuxCommands`: confirmed (the report's terminal and attach child, the record's identity equal to the created session's); a second attach focused through the real presence check, no window opened; "Detach other clients…" detached a second plain client (it exited 0) and kept the backend's; the backend's detach ended only its own client (a third stayed listed), the helper exited 0 with a successful result, the report gone; cleanup killed only the test's session and the server ended. About 1 s |
| UI messages (1 new) | `swift test --filter FailureMessageTests` | `plainMessagesAreDistinctSentences`: the four new failures and the two new "Detach other clients…" problems give six sentences distinct from every existing message |
| Repeated runs | `swift test --skip-build --filter PlainTerminalBackend` 5 times (the end-to-end test alone 5 more) | all passed every time |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Leftovers | `pgrep -x Terminal`; `pgrep -x ghostty`; `pgrep -fl "muxfinder-test-plain\|attach-plain"` | exit 1 each: neither app ran, no helper or test client left |

A finding while writing the end-to-end test: a pseudo-terminal is revoked when its session
leader exits, so a plain client detached on one cannot be followed by another on the same
terminal; the test gives its third client a terminal of its own. Its own plain clients get their
terminal read-write (`exec "$@" 0<>"$0"` after the harness's read-only open), since a plain
client draws through its standard input.

Existing tests edited: `FailureMessageTests.caseIndex` (UI tests), the exhaustive switch that
makes the compiler insist on new `AttachFailure` cases, gained the four plain cases (20–23) so
it compiles; its 20 samples and every count it expects are unchanged, and the new test above
covers the plain messages. No other test changed.

#### Review fixes (2026-11-06)

The adversarial review (`docs/reviews/phase-I-12c1.md`) found three gaps, fixed as PLAN.md D38
*Plain backend (I-12c1)* records: every bound detach of "Detach other clients…" also requires
the kept client in the session (and the loop stops once the backend's record is dropped or
replaced, or a refusal turns out to be the kept client's); a confirming reading counts only if
the helper's result still does not exist after it; the first early report read is kept for the
whole wait. Each regression test below failed with its fix reverted (the fix taken out, the
suite run, the fix put back), and passes with it.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1098 core tests in 107 suites (8 new, below) and 486 UI tests in 47 suites (unchanged) |
| Attach (3 new in `PlainTerminalBackendTests`, now 24) | `swift test --filter PlainTerminalBackendTests` | `helperEndingDuringAConfirmingReadingFails` (This Mac and ssh): the helper's result written while the one matching reading is in flight ends the attach `helperEnded`, no attachment, no `plainConfirmed`, no focus (reverted: confirmed). `removedReportStillConfirms` (This Mac and ssh): the report removed during the first reading (no candidate), the second reading confirms from the kept report, its file still gone (reverted: not confirmed, one reading only). `changedReportIsAFailure`: the report rewritten with another attach child, one the listing matches, is `launchStore(fileMalformed)` after one reading (reverted: confirmed from the rewritten report) |
| Detach other clients (3 new in `PlainTerminalBackendDetachTests`, now 13) | `swift test --filter PlainTerminalBackendDetachTests` | Over a listing with the kept client and two others: `refusedDetachStopsUnlessTheKeptClientHoldsTheSession`: the first detach refused, then the kept client's presence check present (the second detached, gone 1), not present (`identityChanged`, no second detach, the attachment dropped) or failing (`plainClientListing`, no second detach). `keptHelperEndingStopsTheDetaches`: the kept launch's result written while the first detach runs: `identityChanged`, 1 detached, no second detach. `droppedOrReplacedRecordStopsTheDetaches` (dropped by the backend's own detach, or replaced by a new attach, both while the first detach runs, through the scripted runner's new hook): `identityChanged`, 1 detached, no second detach (reverted: all three failed) |
| Bound commands (2 new in `PlainBoundCommandsTests`) | `swift test --filter PlainBoundCommandsTests` | `buildsTheBoundDetachKeepingAClient`: the exact condition (session, the detached client's two checks, the kept client's two, right-nested), no kept client the plain detach, the kept client's own name or no session name `nil`. `bindsTheDetachToTheKeptClientOnAPrivateServer` (private server, `-f /dev/null`, control clients K, O1, O2 on a `muxfinder-test-*` session): K's pid, creation time or name off detaches nothing; keeping K detaches O1 alone; K switched (`switch-client -c`) to another session, then K ended: O2's detach keeping K refused each time, O2 still attached; O2's detach with no kept client detached it (reverted, the kept client's checks left out: failed, as did the text test) |
| Repeated runs | `swift test --skip-build --filter 'PlainTerminalBackend\|PlainBoundCommands'` 3 times | 47 tests in 4 suites passed every time, about 1 s |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Leftovers | `pgrep -fl "muxfinder-test\|attach-plain"` | exit 1: nothing left |

Existing test edited: `detachesOtherClientsKeepingTheAttachments` expects the detach's argv with
the kept client's checks (`PlainClientDetach.arguments(of:keeping:in:)`), the change the fix
makes; its other expectations are unchanged. Test support gained `ScriptedProcessRunner.setHook`
(awaited while a request is in flight), `PlainBackendSupport.reportToken(in:)` and an optional
kept client on `PlainBoundCommandsTests.Server.detach`.

**Owed:** the plain backend's real runs with Terminal and Ghostty and the remote plain attach
(I-12c3's `e2e-plain`, under *Unattended-run rules* 8), and, as before, compiling and calling
the built-in scripts for real (*Phase I-12b1*).

### Phase I-12c2 — open on this Mac (2026-11-06)

Process ancestry for requirement 7 (PLAN.md D38 *Open on this Mac (I-12c2)*), core only:
discovery's `list-clients` output gains, after each client line, a nonce-framed `tty` record
(`client_pid`, `client_created`, `client_tty`; a review fix); a read-only process table
(`SystemProcessTable`) and `LocalClientAttributor` trace a client on This Mac to the terminal
app it descends from; the per-session rule, the refresh engine's optional attributor, the
`.app` focus handle and the plain backend's attach focusing such an app instead of opening a
window; the read-only probe `local-clients`. Nothing in the app, the self-tests or the existing
probe commands calls it yet (I-12c3), so no gallery, `--selftest` or `e2e-*` run is due.
Hermetic tests use a fake process table, the fake activator, the existing plain backend and
refresh fakes; one test reads the real process table for clients of a private tmux server. No
Apple event, no terminal app launched or activated, no iTerm2 contact.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0 (final tree, after the review fix): 1134 core tests in 112 suites (36 new in 5 suites, below) and 486 UI tests in 47 suites (unchanged); before the fix 1130 + 486 |
| `ProbeClientFieldsTests` (9) | `swift test --filter ProbeClientFieldsTests` | The client line keeps its five fields; a `tty` record (`tty <nonce> <client_pid> <client_created> <client_tty> <nonce>`, a terminal over 255 bytes printed as nothing by tmux) follows each client. Present: both kept. Absent: no record, both `nil`; a six-field client line is still `malformed`. Unusable, one at a time, the client and the report kept: an empty terminal, a relative path, a space, a tab inside, an escape or a non-ASCII byte, 256 bytes (255 kept); a creation time empty, signed, padded, with a leading zero or not a number. **Review fix:** a full report through `DiscoveryProbe.discover` with 10 hostile terminals (line feeds, tabs, nonce-like text, forged lines): the host and its sessions discovered, that client's terminal `nil`, its pid, control mode and creation time intact, the other clients unaffected (failed `malformed` on all 7 line-feed cases on the old code); a misplaced or mismatched `tty` record fails the report like a misplaced `path`; the report's line count; the real script through the fake tmux's `hostile-tty` mode. The classified sessions' `ClientSummary` carries both; its JSON shows them and leaves an unknown one out; it decodes back |
| `LocalClientAttributionTests` (14) | `swift test --filter LocalClientAttributionTests` | Over a fake table: Terminal's chain (`Terminal → login → zsh → tmux`) names Terminal with its definition id, four reads; an app chain matched without case; iTerm2's job server under iTerm2 and under launchd names iTerm2 (stopping there), one outside the folder or with no folder known does not; nested tmux and sshd have no terminal ancestor (launchd never read); a cycle stops at the repeated pid; an app 64 steps up is found, 65 is `tooDeep` (65 reads each); a process gone mid-walk, an unreadable entry and a parent started after its child end the walk; pid reuse refused (another terminal, no device, no controlling terminal, a start 1.5 s after `client_created`; 0.5 s and exactly 1 s allowed); no terminal path or creation time `incompleteClient` with no read; two definitions sharing a bundle identifier both listed in loader order; the per-session rule with and without the index; an SSH host's sessions never read; the app type and handle kinds; the real job server folder's shape |
| `LocalClientsRealTests` (1) | `swift test --filter LocalClientsRealTests` | A `muxfinder-test-local-clients-*` session on a private server (`-f /dev/null`, `TMUX_TMPDIR` from `mkdtemp`): a plain client on a pseudo-terminal of the test was discovered with that terminal and a creation time of now; `SystemProcessTable` showed its controlling terminal equal to that path's `st_rdev`, the test as its parent, tmux as its executable, no bundle identifier and a start not after the client; the walk ended in iTerm2 or no terminal ancestor; a creation time 10 s early `startedAfterClient`, another terminal `terminalMismatch`; a `tmux -C` client on a pipe had no terminal path and was `incompleteClient`. Only that session killed, about 0.2 s |
| `RefreshLocalAttachmentsTests` (3) | `swift test --filter RefreshLocalAttachmentsTests` | No attributor: sessions unchanged, no local attachments. With one: This Mac's session carries Terminal's client and iTerm2's control-mode client, one walk each; the SSH host's same clients are never attributed. With an index configured, iTerm2's control-mode client is left to it |
| `PlainTerminalBackendOpenHereTests` (9) | `swift test --filter PlainTerminalBackendOpenHereTests` | A client traced to Terminal: `appFocused(Terminal)` (a focus, attached, not confirmed), the attachment and `activated` in the result, Terminal's bundle identifier activated, no request, file, window or tmux command, the table read once, states `requested` then `appFocused`. Ghostty's backend focuses Terminal, and iTerm2's control-mode client (first attributed in client order). `refused` and `notRunning` still end `appFocused`, nothing opened. A live own record is `plainFocused` with the table never read. A client whose process is gone, one with no terminal, and an unreadable table never block (opened and confirmed). Move here and an SSH host: no ancestry read, a window opened. An `.app` handle activates through the plain backend and iTerm2's backend (nothing sent to iTerm2's fake); the real activator answers `notRunning` for an app nobody runs and launches nothing |
| Repeated runs | the five suites above 3 times | 32 tests in 5 suites passed every time, about 0.2 s |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| `local-clients --help` | `swift run muxfinder-probe local-clients --help` | exit 0, the usage only (nothing contacted) |
| Real run: `local-clients` | `swift run muxfinder-probe local-clients --user-directory <private empty folder, mode 0700>` from the repository root, JSON counted with `jq` | exit 0, status `ok`; definitions `ghostty`, `terminal`, no problems; the job server folder known; 1 session, 1 client (control mode, terminal and creation time known), attributed to iTerm2: 1; unmapped: 0 for every reason; local attachments 1 without the index, 0 with it (left to D16's index) |
| Real run: `discover --local` | `swift run muxfinder-probe discover --local`, counted with `jq` | exit 0, `ok`: 1 session, 1 client, 1 with `terminalPath`, 1 with `createdAt` (control mode 1), 37 ms |
| Real run: `discover --ssh saturno-m4` | `swift run muxfinder-probe discover --ssh saturno-m4`, counted with `jq` | exit 0, `ok`: 1 session, 1 client, 1 with `terminalPath`, 1 with `createdAt` (control mode 1), 759 ms |
| Leftovers | `pgrep -x Terminal`; `pgrep -x ghostty`; `pgrep -fl muxfinder-test` | exit 1 each: neither app ran, no test session or client left |

Existing tests edited: one, by the review fix:
`ProbeSessionPathTests.theOutputBudgetHoldsTheLargestAcceptedReport` gives each of its 1,000
clients the longest `tty` record accepted and also expects every terminal and creation time
back (its other expectations kept; `maximumReportSize` counts the new record). After the fix
`discover --local` showed the same counts as above. Test support gained two defaulted
parameters on
`PlainBackendHarness` (`localClients`, `appActivator`; `nil` as before) and the shared
`LocalClientSupport` fixtures. The two `MuxFinderUI` switches over `AttachState` gained
`appFocused` (shown as `focused`) so they compile; no UI test changed.

**Owed:** a client in Terminal and in Ghostty traced for real (neither is used on this Mac), and
the attributor wired into the app with the terminal setting (I-12c3).

### Phase I-12c3a — onto the seam (2026-11-06)

The app, the self-tests, the refresh engine's attributor and the probe's one-off commands on
`TerminalBackend` (PLAN.md D38 *Onto the seam (I-12c3a)*): the terminal setting in
`preferences.json`, its typed resolution, one backend per terminal id built lazily and
cached, every iTerm2 contact gated on the choice, the plain backend's up-front name refusal,
and `muxfinder-probe attach --terminal <id>` with its own *Unattended-run rules* 8 gate.
Hermetic tests use the existing fakes plus a counting iTerm2 integration, a recording
attributor and a scripted backend; the real runs are the seam's iTerm2 path (the two
self-tests), the app shell check and the read-only terminal checks. No plain real run, no
Apple event to Terminal or Ghostty.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1158 core tests in 118 suites (24 new in 6 suites, below; 6 of them in 2 suites from the review fixes) and 497 UI tests in 48 suites (11 new in 1 suite; 4 from the review fixes); before 1134 + 486 |
| `TerminalChoiceTests` (9) | `swift test --filter TerminalChoiceTests` | The default: iTerm2 when installed (no definition asked), else Terminal's definition (only it asked). A stored definition id resolves to it with iTerm2 installed or not. A stored `iterm2` with iTerm2 gone is `unavailable(notInstalled)`, never Terminal. Every unavailable reason: an unknown id, the empty id (a non-string value), not installed, too old, version unknown, and no Terminal definition for the default. The failures' kinds and four distinct sentences quoting the id cut to printable ASCII. `TerminalAppFacts.versionCheck(of:minimum:)` both ways. The `terminal` key through `PreferencesStore` on a private folder: removing an absent one writes nothing (no folder made); set keeps every other key; the same value writes nothing; `nil` removes it. Reading `null`, no key, a string, a number and an object; an unusable file refuses a change and stays byte for byte. `InMemoryPreferencesStore` keeps it and counts real changes |
| `RefreshAttachmentChecksTests` (2) | `swift test --filter RefreshAttachmentChecksTests` | Checks off before the popover opens: refreshes and an explicit `refreshOnce(includeAttachments: true)` never call the index, `notChecked`, This Mac's session carries Terminal's and iTerm2's control-mode clients; on again: a check runs at once (popover visible) and the next attempt leaves iTerm2's control client to the index. Off while a check hangs: its task cancelled, a caller waiting for it resumed with `notChecked`, attachments forgotten, no later call; off twice, or with no index, does nothing |
| `PlainTerminalBackendNameTests` (3) | `swift test --filter PlainTerminalBackendNameTests` | `a{b`, `[work]`, `x]`: attach and move here fail `unsupportedSessionName` with no discovery, request, window, tmux command or published state. A session renamed `fixture[2]` since the listing: refused after the one revalidation, no request or window. Create-and-attach with `  build{1}  ` fails `invalidName(sessionNameNotSupportedByTerminal)` before the creator is asked; an empty name gets creation's own error |
| `AttachCommandOptionsTests` (4) | `swift test --filter AttachCommandOptionsTests` | Today's options (iTerm2 by default, `--terminal iterm2`, the tmux path and profile) and `--help`; a plain `--terminal` with both folders; 14 refusals (no host, both hosts, a repeat, a missing value, a bad session id, an unknown option, a terminal that is no id, folders without a plain terminal, a profile with one, `--help` with more). The gate: an installed, recent, running app with `granted` goes ahead (an `exec` definition without a permission too); not installed, too old, version unknown, not running (also `exec`), `denied`, `notDetermined`, another status and a missing permission read are refused with a reason |
| `TerminalSeamTests` (11) | `swift test --filter TerminalSeamTests` | The default resolves to iTerm2 with nothing built at launch; two Opens build iTerm2's backend once; the setter writes `sample-exec` and the next Open builds the plain backend (a plain request, the window layer asked, the request withdrawn after its scripted open failure); back to the default reuses iTerm2's backend (2 builds in all). **Never contact:** with `sample-exec` stored, launch (an out-of-date persistent profile file), the popover and a refresh, an Open and a Move here (the plain backend, `-d`), "Show tab", Settings' window, a save, every "Set up SSH in iTerm2…" owner and the popover's ssh setup: the counting iTerm2 got 0 calls (it sits under the engine's real `AttachmentIndex` and the coordinator), iTerm2's backend never built, the profile list and the ssh opener never asked, the profile file neither written nor removed, `notChecked`, attribution always without the index; choosing `iterm2` then resumes the rewrite (1 update). With iTerm2 chosen the index runs and the attributor beside it (`indexInUse`), rows carry their local attachments. An unknown stored id: Open, New session and an app's focus end in the typed failure with nothing built, written or opened; a stored `iterm2` with iTerm2 gone resolves unavailable and gates every iTerm2 seam. A change while an Open is held waits (`pendingTerminalChoice`), never cancels it, applies when it ends, and the next Open builds the new backend. Plain results: a brought-forward window is recorded (Detach offered and sent to the backend, "Show window" and an app's focus through it), a bracketed name shows `unsupportedSessionName` with nothing written. The new sentences are distinct from each other and from every existing message |
| `UnresolvedLaunchQueryTests` (2; review fix 1) | `swift test --filter UnresolvedLaunchQueryTests` | `hasUnresolvedLaunch(for:)` is read-only on both backends: the plain backend's launch whose helper took the request and never confirmed is unresolved, and resolved once its result exists (the result left in place, the launch still pending inside); the coordinator's launch is unresolved while its `CreateTab` is held and after its callers were cancelled, resolved once its helper's result exists, with no iTerm2 call and nothing settled |
| `PlainRunPolicyTests` (4; review fix 3) | `swift test --filter PlainRunPolicyTests` | The real window layer with the `unattended` policy over fake facts, runner and spawner, after an early `PlainRunGate.check` that passes: Terminal quitting before the attach is refused right before the write (no request file, no compile, no Apple event, no spawn); its permission turning `notDetermined` right after the write is refused before the compile and the event, the request withdrawn; an `exec` app quitting after the write is never spawned, the request withdrawn; each refusal is `terminalWindow(unattendedRunRefused)` and `PlainRunGate.refusal(of:)` names it (the probe's exit 2). The `interactive` policy reads nothing for the policy and still opens an app that is not running |
| `TerminalSeamTests`, review fixes (4 of the 11) | `swift test --filter TerminalSeamTests` | **Fix 1:** the plain backend's `timedOut` launch whose helper took the request blocks the same session's Open after a change to iTerm2: `earlierLaunchPending`, nothing written or opened, 0 iTerm2 calls; once the helper's result exists the Open goes to iTerm2's backend. **Fix 2:** with the setting's read held, the choice is `unresolved`; Settings opened then asks no profile list (`notLoaded`, no iTerm2 problem) and every "Set up SSH in iTerm2…" asks no opener; with `sample-exec` stored nothing contacts iTerm2 after the resolution either (no profile list, no D26 update, no backend); with `iterm2` stored, once the read is let through the profile list is asked exactly once (window still open), D26's launch rewrite runs once and the not-chosen ssh line is cleared. **Fix 4:** a session opened in `sample-exec`, then in `sample-two`: both windows kept under their terminals, `sample-two`'s window not offered while `sample-exec` is chosen and the reverse, "Show window" and Detach go only to the chosen backend with its own window, switching back offers and focuses the first window |
| Repeated runs | the seven suites above 3 times (after the review fixes) | 35 tests passed every time, about 0.15 s |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Gate | `.build/debug/muxfinder-probe iterm2 status`; iTerm2's thread count (`ps -M -p <pid> \| wc -l`) | exit 0, connected (protocol 1.23); 16 before the runs |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0 (Apple Development identity); exit 0 |
| Real run: `--selftest attach-local` | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local` (`TMUX_TMPDIR` unset) | 8/8 PASS (one launch for five clicks, buried, focused again, detached in 9.8 s, the launch tab left by itself, session killed), exit 0; 1 connection of the user's never asked; threads 21 after |
| Real run: `--selftest new-session-local` | `build/muxFinder.app/Contents/MacOS/muxFinder --selftest new-session-local` | 7/7 PASS (created and confirmed, buried, collision refused, detached in 9.8 s, the launch tab left, killed), exit 0; threads 22 after |
| Real run: app shell | `CFFIXED_USER_HOME=<mktemp -d> build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`, then `kill -TERM` after 4 s | exit 0; no child while running or after; the private home still empty; 7 status item windows, 2 other windows with only onboarding visible, 3 menus |
| Real run: `terminals list` | `swift run muxfinder-probe terminals list --user-directory <private empty folder, 0700>` from the repository root, counted with `jq` | exit 0: iTerm2, Terminal and Ghostty installed; iTerm2 running and `granted`, Terminal and Ghostty not running (`targetNotRunning`); 2 built-in definitions, both meeting their minimum version; 0 problems |
| Real run: `local-clients` | `swift run muxfinder-probe local-clients --user-directory <the same folder>` | exit 0, `ok`: 1 session, 1 client attributed to iTerm2; 0 unmapped; local attachments 1 without the index, 0 with it |
| Real check: `attach --help` and the gate | `.build/debug/muxfinder-probe attach --help`; `attach --local --session '$999' --terminal terminal --user-directory <private empty folder>` | exit 0, usage only; exit 2 "the terminal app is not running …", before any discovery: nothing written, no Apple event, Terminal not launched |
| Leftovers | the launch folder; `DynamicProfiles/`; `/private/tmp/mfx.*`; `tmux list-sessions` filtered for `muxfinder-test-`; `iterm2 list-sessions` (counted); `pgrep -x Terminal`, `pgrep -x ghostty` | launch folder empty (its one stale result swept by the self-tests); `DynamicProfiles/` 0 entries before and after; no `mfx.*` folder; no test session; neither run's launch tab in a tab or `buried_sessions` (1 buried session, not the runs'); Terminal and Ghostty 0 processes before and after; iTerm2 threads 18 at the end |

Existing tests whose wiring changed (no expectation edited): `AttachUITestSupport.swift` (the
harness's maker returns `ITerm2TerminalBackend` over the same coordinator; since the review
fixes its `MemoryLaunchStore` can also play a helper that took the request and one that ended,
off by default),
`PopoverPlacementTests.swift` (the inert environment's `makeTerminalBackend` is `nil`, the
field renamed from `makeAttachCoordinator`), and `AttachFlowTests.swift`
(`FailureMessageTests.caseIndex` gained `unsupportedSessionName` so its exhaustive switch
compiles; its 20 samples and counts unchanged).

**Owed:** the plain real runs (I-12c3b's `e2e-plain` under *Unattended-run rules* 8) and the
picker and strings (I-12d).

### Phase I-12c3b — the plain runs (2026-11-06)

`muxfinder-probe e2e-plain --terminal <id> --local | --ssh saturno-m4` (PLAN.md D38 *The
plain runs (I-12c3b)*): the real run of the plain backend in a terminal app other than
iTerm2, its gate (*Unattended-run rules* 8) first, its steps, its cleanup that closes only its
own windows by recorded id once their process ended. The arguments, the gate, the steps and the
cleanup are the core's (`E2EPlainOptions`, `E2EPlainRun`), so they are tested hermetically;
the probe wires the real parts. At the run's time neither Terminal nor Ghostty was running, so
their real runs are owed to the user (below; `docs/MANUAL-CHECKLIST.md` item 26): the real
runs here are the gate's two refusals and iTerm2's `e2e-*` runs as regression (requirement 12).
No Apple event was sent to Terminal or Ghostty and neither was launched.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1177 core tests in 127 suites (19 new in 9 suites, below, 8 of them in 5 suites for the review's findings) and 497 UI tests in 48 suites; before 1158 + 497; no existing expectation edited (one full run first failed `FolderSearchTransportTests.answersAndEndsAtEndOfInput`'s 2 s bound under the parallel load, a file not touched here; it passed alone and the whole suite passed on the rerun) |
| `E2EPlainOptionsTests` (5) | `swift test --filter E2EPlainOptionsTests` | `--help` (three spellings) contacts nothing; `--terminal terminal --local`, `--ssh saturno-m4 --terminal ghostty` and both definition folders parse; 15 refusals (no arguments, no host, no terminal, `iterm2` (the message names iTerm2's own runs), an invalid or empty id, another host (`sirio-m5`), both hosts in either order, an option twice, a missing value, an unknown option, `--session`, `--help` with more). The run's name and the owed command (`swift run muxfinder-probe e2e-plain …`, folders single-quoted; its arguments parse back to the same run). An id no loaded definition has is refused with the load's counts. Exit statuses: 0 only when all 9 passed and the steps finished, 1 a failed step or a signal, 3 the watchdog, 2 the gate's |
| `E2EPlainGateTests` (1) | `swift test --filter E2EPlainGateTests` | Six refusals over fake facts, each exit 2 with the reason and the owed command and nothing contacted: Terminal not running; running with its permission `denied`, `notDetermined`, another status (-1) and `targetNotRunning`; an `exec` definition's app not running. In each: no tmux call (not even `-V`), no discovery, no control client asked for, no launch folder created, no window opened, focused or closed, no run policy check, 0 steps passed |
| `E2EPlainCloseOrderTests` (1) | `swift test --filter E2EPlainCloseOrderTests` | Over the fake window layer and a fake process table: while the helper (named by its early report) runs, nothing is closed and the window is left (`helperStillRuns`) after the wait; once it ended the window is closed by its id, once; a window whose helper has neither report nor result is left (`helperUnknown`) and closed once its result names a helper that is gone; a window the terminal already closed (-1728) is left as it is; a close the gate's recheck refuses leaves the window and is noted as the gate's |
| `E2EPlainUnreadableProcessTests` (2) | `swift test --filter E2EPlainUnreadableProcessTests` | Review B1. The report's helper reading unreadable at the first look (no start time recorded yet): left open (`helperUnreadable`), nothing closed; then running: `helperStillRuns`; unreadable again after its start time was recorded: still left; its pid with another start time: closed by its id. A pid whose process started after the report's attach child is not taken for the helper nor for its end: left; absent: closed. With the fix reverted (an unreadable reading counted as ended) the first test fails: the window is closed at the first look |
| `E2EPlainHelperShutdownTests` (1) | `swift test --filter E2EPlainHelperShutdownTests` | Review S1, over fakes, through the whole cleanup: a helper that ends on SIGTERM is asked once and only then its window is closed; one that keeps running is asked again (every second within `helperShutdown`) and left, reported as still running with its window; one whose process cannot be read is never signalled and reported as unreadable; every SIGTERM names the run's helper executable. With the fix reverted no helper is asked and the first window stays open |
| `E2EPlainHelpersByTokenTests` (1) | `swift test --filter E2EPlainHelpersByTokenTests` | Review S2, over fakes, through the whole cleanup: an open that ended `malformedReply` (no window published) but whose helper wrote its early report: the helper is recorded by launch token, asked to stop while its report still exists, and the report removed only once it ended; the launch is reported as a window with no recorded id, with what to do by hand. An open whose call failed after its Apple event (`scriptFailed`, -1712) with no helper file is reported too; one the gate refused before anything was sent is not. With the fix reverted (helpers only through windows, no such report) no helper is asked, its report is removed while it runs and nothing is reported |
| `E2EPlainSessionAbsenceTests` (2) | `swift test --filter E2EPlainSessionAbsenceTests` | Review S3, the whole run over a tmux whose `new-session` loses its reply: when `list-sessions` also fails (ssh's exit 255, tmux's own error, a timeout), step 1 fails and cleanup fails with "whether the test session is gone could not be established" and a line to look for the session by hand (`list-sessions` asked 3 times: step 1, the kill, the check; no kill sent); tmux's "no server running", its "error connecting to … (No such file or directory)" and a listing without the session are genuine absences: cleanup passes. With the fix reverted the failed listings pass cleanup |
| `E2EPlainKernelProcessesTests` (1) | `swift test --filter E2EPlainKernelProcessesTests` | The real `E2EPlainKernelProcesses` on a `/bin/sleep` child of the test's: it reads `running` with the kernel's start time; SIGTERM is refused for an earlier start time and for another executable (the child still runs), then sent for its own (it ends by SIGTERM); once reaped its pid reads `absent`; a pid below 1 reads `unreadable` and is never signalled |
| `E2EPlainStepsTests` (5) | `swift test --filter E2EPlainStepsTests` | The run itself on This Mac, no terminal app: a private tmux server (`-f /dev/null`, private `HOME` and `TMUX_TMPDIR`), a private launch folder, the built `muxfinder-launch attach-plain` started by I-12c1's fake window layer on a pseudo-terminal of the test's (drained, never kept; `MUXFINDER_LAUNCH_NO_WAIT=1`), whose close refuses, as busy, a window whose helper has not exited; real discovery, readings, bound commands and `tmux -u -C` control clients; the age guard's minimum 1 s. **All steps:** 9 of 9 PASS, exit 0, in about 3 s: 2 windows opened and both closed after their helper exited 0, 3 focuses, 2 run policy checks, nothing left (no launch file, session, control client or helper). **The gate's recheck refusing the move here's request:** steps 1–5 PASS, step 6 FAIL naming the gate, nothing more opened, cleanup PASS (its control client ended, the session killed), the line saying the run stopped, exit 1, nothing left. **SIGTERM after the first close:** step 6 interrupted, cleanup PASS, exit 1, nothing left. **SIGTERM right after the move here's window opened:** the move here cancelled, cleanup closes that window only after its helper ended (named by its result), PASS, exit 1, nothing left. **A helper that failed and waits for Return** (review S1; the helper started without `MUXFINDER_LAUNCH_NO_WAIT`, its request withdrawn right before it ran, so it writes its result `requestMissing` and waits on its pseudo-terminal, where nobody types): step 3 fails, cleanup leaves the window while the helper waits, kills the session, asks the helper to stop (SIGTERM, which finishes its wait) and then closes the window: PASS, exit 1, nothing left, in about 5 s; with the fix reverted cleanup fails ("left open: its helper still runs", "1 helper(s) of the run still running") and the helper is left for the test's own cleanup. **Not reached hermetically:** a terminal app's windows (the fake opens a pseudo-terminal, focuses and closes nothing), the app's facts (a fake inspector) and the remote path (the token reading and the control clients over ssh) |
| Repeated runs | the nine suites 3 times | 19 tests passed every time, about 4.8 s |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| `--help` | `swift run muxfinder-probe e2e-plain --help` | exit 0, usage only (30 lines); nothing read or contacted |
| Facts at the run | `pgrep -x Terminal`; `pgrep -x ghostty`; `muxfinder-probe terminals list --user-directory <private empty folder, 0700>` (counted with `jq`) | no process of either; iTerm2 running and `granted`, Terminal and Ghostty not running (`targetNotRunning`); 2 built-in definitions, 0 problems |
| Real run: the gate refuses Terminal | `muxfinder-probe e2e-plain --terminal terminal --local --user-directory <the same folder>` (`TMUX_TMPDIR` unset) | exit 2: "not run: the terminal app is not running, and the run must never launch it (Unattended-run rules 8); its real run is owed to the user", then "nothing was created, written, discovered or sent" and the owed command |
| Real run: the gate refuses Ghostty | `muxfinder-probe e2e-plain --terminal ghostty --local --user-directory <the same folder>` | exit 2, the same two lines for Ghostty |
| The gate again after the review's fixes | both refusals with `--builtin-directory Resources/Terminals --user-directory <a private empty folder, 0700>` | exit 2 each, the same lines; `pgrep -x Terminal` and `pgrep -x ghostty` empty before and after; the folder still empty (then removed) |
| After the refusals | `pgrep -x Terminal`; `pgrep -x ghostty`; the private folder; the launch folder; `tmux list-sessions` filtered for `muxfinder-test-` | no process of either (the same as before); the private folder still empty (then removed); the launch folder empty; no test session |
| Gate for iTerm2's runs | `.build/debug/muxfinder-probe iterm2 status`; iTerm2's thread count (`ps -M -p <pid> \| wc -l`) before each run | exit 0, connected (protocol 1.23) each time; 23 before the first run |
| Leftovers before | the launch folder; `DynamicProfiles/`; `/private/tmp/mfx.*`; `muxfinder-test-*` sessions on Neptuno and Saturno; `iterm2 list-sessions` (counted) | 0 files; 0 entries; none; 0 and 0; 2 windows, 2 tabs, 1 buried session (not a run's) |
| Real run: `e2e-local` | `.build/debug/muxfinder-probe e2e-local` (`TMUX_TMPDIR` unset) | 16 of 16 PASS in 65.7 s, exit 0. Threads 23 → 44; they held at 44 for about 1 h 45 min (60 s samples) and then fell to 18 in one step, as in Phase 12b |
| Real run: `e2e-remote saturno-m4` | `.build/debug/muxfinder-probe e2e-remote saturno-m4` | First run: exit 1, 15 of 17: step 15 "new session" failed `helperEnded` after 3.2 s (tmux ended normally before its connection was seen; the created session survived and cleanup killed it), so step 16 did not run; cleanup PASS with nothing left. No code on that path changed in this phase (the coordinator and the helper are untouched). Rerun at once: 17 of 17 PASS in 120.7 s, exit 0 (step 15 confirmed in its normal way). Threads 18 → 20 → 17 |
| Real run: `e2e-bury --local` | `.build/debug/muxfinder-probe e2e-bury --local` | 13 of 13 PASS in 72.4 s, exit 0 (step 7: the bury and the detach released together, attempt 1 of 3); threads 17 → 16 |
| Real run: `e2e-detach-others --local` | `.build/debug/muxfinder-probe e2e-detach-others --local` | 9 of 9 PASS in 14.2 s, exit 0; threads 16 → 17 |
| Leftovers after each run | as before | every time: the launch folder empty, `DynamicProfiles/` 0 entries, no `mfx.*` folder, no test session on Neptuno or Saturno, `iterm2 list-sessions` as before (2 windows, 2 tabs, the same 1 buried session; none of the runs' launch tabs in a tab or `buried_sessions`); at the end Terminal and Ghostty still 0 processes |

Changed outside the probe, additively: `PlainTerminalWindows` conforms to the new
`PlainTerminalWindowClosing` (its `close(_:of:)` unchanged), and `FakePlainTerminalWindowLayer`
gained `close(_:of:)` (recorded, refusing a window it did not open as the real layer does) with
`closes`, `closed`, `closeFailure` and `onClose`. No existing test changed.

**Owed** (to the user, `docs/MANUAL-CHECKLIST.md` item 26; *Unattended-run rules* 8): with the
app open and `swift run muxfinder-probe terminals list` showing it `running` and `granted`,
from the repository root after `swift build`, `TMUX_TMPDIR` unset, in an iTerm2 shell:

1. `swift run muxfinder-probe e2e-plain --terminal terminal --local`
2. `swift run muxfinder-probe e2e-plain --terminal terminal --ssh saturno-m4`
3. `swift run muxfinder-probe e2e-plain --terminal ghostty --local`
4. `swift run muxfinder-probe e2e-plain --terminal ghostty --ssh saturno-m4`

Each should print 9 PASS lines and exit 0. They also settle what Phase I-12a's *Owed* list
asks of each app (what `do script` returns, Ghostty's ids, a plain attach in its window), for
the built-in scripts as they are; that list's raw `osascript` checks stay owed only for what
the scripts do not use (Ghostty's `environment variables`, `direct:`, its AppleScript turned
off).

### Phase I-12d1 — other terminals: Settings, onboarding and SSH setup (2026-11-06)

Settings › General's terminal picker, the strings that follow the choice, "Set up SSH" in a
plain terminal's window, the Persistent profiles tab's persistent work commands, Diagnostics
and onboarding's steps (PLAN.md D38 *The UI (I-12d1)*). Everything is hermetic: a fake
inspector answers LaunchServices and the Automation permission per app, the plain window
layer is I-12c1's fake (or the real layer over its fakes), the setting is in memory, iTerm2 is
a counting fake. No terminal app was launched or sent an Apple event, no permission was read
for real, nothing was opened: `pgrep -x Terminal` and `pgrep -x ghostty` were empty before and
after.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1182 core tests in 128 suites (5 new in 1 suite) and 517 UI tests in 49 suites (20 new in 1 suite); before 1177 + 497; no existing test or expectation changed (after the review's fixes the phase's own `TerminalPickerTests` wait for the now asynchronous reading: `readingFinished()` after "Check again" and after onboarding's opening, and their in-place reading helper reads through `TerminalAppFacts.read`) |
| `TerminalPickerTests` (20) | `swift test --filter TerminalPickerTests` | **Rows:** nothing read before a window opens (0 permission reads after launch); at Settings' opening iTerm2 3.7.7 first, then the sample `exec` definition ("Not needed") and Terminal 2.15 ("Not asked yet"), by display name, Ghostty 1.2 left out; plain rows carry "Plain tmux: windows and panes stay inside one terminal window.", iTerm2's its own note and no permission; only "Not asked yet" and "Not allowed" offer "Allow in System Settings…", which opens the Automation pane's URL through the seam. Ghostty 1.2 stored: unavailable, listed and selected with "Ghostty 1.2 is older than 1.3." (Ghostty 1.3.1 is listed as any other). Every permission label (6) from its `Automation`. Every unavailable reason of the current choice: not installed, too old (with and without the installed version), version unknown, an unknown id (a row named "“warp”"), iTerm2 gone; no iTerm2 row without iTerm2. While the setting is read: no row, nothing selected; then the loader's problem by file name and reason. **Choosing:** Terminal saved and applied (the wording follows); a refused save (`fileNotUsable`) shows the store's sentence and keeps Terminal, stored and applied. A change while an Open is held: selected at once with "Applies when the current action ends.", the strings still iTerm2's until it ends. The apps are read again only on "Check again" (2 permission reads per reading, none in between). **Resolved again** (review): Ghostty 1.2 stored, upgraded to 1.3.1, then "Check again": applied as Ghostty, no reason, 0 saves; downgraded again: unavailable with "Ghostty 1.2 is older than 1.3.", still selected; iTerm2 stored and gone: still iTerm2; Ghostty 1.2 chosen while an Open is held, upgraded and checked again: still waiting, now Ghostty, with its note, applied once the Open ends. **Off the main actor** (review): with the permission read held, "Check again" returns at once and the picker still shows "Reading the terminal setting…" while the test, on the main actor, looks; 0 permission reads on the main thread, 0 held past 1 s; a reading that ends after a newer "Check again", or after the last picker window closed, is dropped (the newer reading stays shown). **Strings:** iTerm2's are the earlier ones exactly; Terminal's "Set up SSH in Terminal…", "… first", "window"; "Used only with iTerm2."; unknown id "the chosen terminal"; `unresolved` iTerm2's. **Set up SSH:** with Terminal chosen, the Settings, popover and onboarding owners each write D24's request and open exactly one window of Terminal through the window layer (its token the request's id), the line naming Terminal; 0 calls to iTerm2 or its opener; a refused window withdraws its request and offers "Open Automation settings". While the setting is read the line is "Still reading the terminal setting. Try again in a moment." (cleared once it is known); an unavailable Ghostty refuses with its own line; no opener asked. **Persistent work:** the command `exec '<helper>' 'profile-plain' '<host id>'` (lowercase id), a helper path with `'` refused; one line per saved host with its persistent profile on, in order; none for an unsaved list or no opted-in host, a missing helper's sentence; where to paste for Terminal (Run command), Ghostty (“command = ”) and another terminal; iTerm2's line with Remove only while installed. In the app: Copy puts the command on the pasteboard seam, Install is refused (0 writes). **Diagnostics:** "Terminal 2.15; permission: Not asked yet" and "Not used with Terminal"; the report's line 6 "iTerm2 check: not used with Terminal" and line 8 the `Terminal:` line; with iTerm2 neither. **Onboarding:** no iTerm2 installed → Terminal by default, steps Terminal, hosts, good to know, plain mode with the permission line ("macOS asks once, the first time muxFinder opens a Terminal window."), no iTerm2 row, 0 iTerm2 calls; iTerm2 → the Python API step; the `exec` sample → no permission line; the fixtures likewise |
| `PlainSSHSetupLauncherTests` (5) | `swift test --filter PlainSSHSetupLauncherTests` | Over the fake window layer and a real launch store in a temporary folder: one request (`sshSetup`, the destination, the host id) and one window open with the helper path and that request's id, one run policy check, `openedWindow`, the log naming neither destination nor path; a failed open withdraws the request; a cancellation that lands while the open waits for the main actor (review: the store holds the main actor 0.3 s right after the write, then cancels the launcher's task there) answers `cancelled` with no window opened, the request withdrawn and the outcome logged `cancelled`; This Mac, `-oProxyCommand=x`, a missing helper and a run policy refusal write and open nothing. The real `PlainTerminalWindows` over its fakes: Terminal's `muxfinder_open` gets `exec '<helper>' 'ssh-setup' '<token>'` and the window is recorded; an `exec` definition's argv carries `ssh-setup`; a `denied` permission refuses with nothing compiled or sent |
| Never contact | `swift test --filter TerminalSeamTests` | `aPlainChoiceNeverContactsITerm2` and the other 10 pass unchanged (their harness wires no plain opener, so a plain choice's "Set up SSH" keeps the earlier refusal there) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| Review fixes, reverted one at a time | each fix undone by an edit, its tests run, the fix put back | the re-resolution hook off: `checkAgainResolvesTheStoredChoiceAgain` and `aChoiceResolvedAgainWaitsForAPendingAction` fail (Ghostty stays unavailable); the main-actor check before the open removed: `aCancellationWhileTheOpenWaitsForTheMainActorOpensNothing` fails (a window opened, the request left); the permissions read on the main actor: `aSlowPermissionReadLeavesTheMainActorFree` and `aStaleReadingIsDropped` fail (main-thread reads, held reads timed out); each passes again with its fix |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0; exit 0 |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery settings\|onboarding --appearance light\|dark --preview-snapshot docs/screenshots/<name>.png` | 4 PNGs written (Settings 2264×10246, onboarding 3248×2977, at the display's 1× backing scale) and looked at: the picker's states (iTerm2; Terminal allowed, not allowed with a `Not needed` user row and Ghostty unknown, not asked yet without iTerm2, checked when running, unknown; Ghostty; too old; problems with an unknown stored id; a change waiting; a refused save), the host editor, two Persistent work tabs and Diagnostics with a plain choice; onboarding without iTerm2 and with Ghostty; every existing state; legible in both appearances |
| Terminal apps | `pgrep -x Terminal`; `pgrep -x ghostty` before and after the work | no process of either, both times |

**Owed** (`docs/MANUAL-CHECKLIST.md` item 27): the picker's real permission states (each read
by macOS for muxFinder itself), "Allow in System Settings…" and "Check again" after a change;
"Set up SSH in Terminal…" and "… in Ghostty…" (a real ssh login in a real window, an Apple
event; never unattended); pasting the persistent work command into Terminal's Run command and
Ghostty's config file.

### Phase I-12d2 — other terminals: the popover, the switcher and the session states (2026-11-07)

The session rows' actions, states and errors per terminal (PLAN.md D38 *The UI (I-12d2)*):
"Open in Terminal", "Show window", the pending and result lines, every plain failure line, the
"earlier launch pending" refusal naming its holder, "Open in Terminal on this Mac" with "Show
in Terminal", "Detach (opened in <terminal>)", and "Detach other clients…" stopped partway.
Everything is hermetic: the model runs over the I-12c3a seam harness (a counting iTerm2, the
plain backend's fakes, the setting in memory) with scripted backends that record every call.
No terminal app was launched or sent an Apple event, no permission was read for real, nothing
was opened: `pgrep -x Terminal` and `pgrep -x ghostty` were empty before and after.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1183 core tests in 129 suites (1 new in 1 suite) and 541 UI tests in 54 suites (24 new in 5 suites); before 1182 + 517. Three expectations of `TerminalSeamTests` (I-12c3a's plain placeholders) now hold the plain wording: a plain focus is `.focusedWindow(Sample terminal)`, the name refusal and the "earlier launch pending" refusal held by Sample terminal's launch name Sample terminal; no iTerm2 expectation changed |
| `TerminalSessionWordingTests` (5) | `swift test --filter "Terminal session wording"` | iTerm2's wording equals the old literals for every new entry point (Open, the hint, "Show tab", Detach's and Detach other clients' help, Quit's, the four row states, New session's creating line, the two host problems, "earlier launch pending", the helper prefix, both panels' explanations, "including 2 in this Mac's iTerm2"); the old entry points (`attach`, `detach`, `detachOtherClients`, `activity(after:)`, `focusNote`, `HostProblemText`, the panels, `SessionActivity(_:)`) equal their iTerm2-worded forms over every existing sample; for Terminal, Ghostty and a user definition every string names the terminal and "window", none says iTerm2 or "tab", all distinct; the plain states map to `waitingForTerminal`, `stillConnectingInWindow` (with "Show window" and its window), `confirmedInTerminal`, `focusedWindow`, `focusedApp`, with their flags; apps named from the definitions, one row entry per app (bundle identifiers without case) |
| `TerminalErrorMappingTests` (5) | `swift test --filter "Terminal error mapping"` | Every `PlainTerminalWindowError` (19 cases, an exhaustive `caseIndex`) and 6 script variants: 25 distinct lines, none the generic one (its core message with "Try again"), each a sentence naming the app; not installed → "Open Settings", not allowed → "Open System Settings…" and "Try again", not running → "Terminal isn't running and couldn't be opened", a refused launch command → no recovery, -600 → not opened with its number, -1708 → Ghostty's AppleScript turned off only for Ghostty (both numbers, with `macos-applescript = false`; from muxFinder's own script, the default: a user definition's is `TerminalReviewFixTests`'), the same line whatever wording calls it. Every `AttachFailure` (25 cases, an exhaustive category switch): the plain ones name Terminal and differ from iTerm2's, the neutral keep the core's, iTerm2's own keep iTerm2's; "Show window" on a timeout, a helper failure, the wait limit and no terminal device when the window is known. Each window error's focus note. The unavailable choice: "The chosen terminal, Ghostty, isn't installed.", "… is older than 1.3.", the unreadable version, an unknown id keeping the core's sentence, "Open Settings" |
| `PlainDetachWordingTests` (3) | `swift test --filter "Plain detach wording"` | "Stopped after detaching 2 other clients: this Mac's Terminal window …", "muxFinder detached no other client: …" (0, known), "Stopped detaching the session's other clients. Some may have been detached: … At least 1 other client was." (a detach that may have run), "Stopped after detaching 3 other clients: a detach could not be sent." (not run), "Stopped after detaching 1 other client: muxFinder could not read …"; over every plain outcome and count "no other client" appears only when `mayHaveSent` is false. A plain Detach's lines name the Terminal window; `cancelled` keeps iTerm2's |
| `TerminalSessionModelTests` (7) | `swift test --filter "Terminal session model"` | A window of Sample terminal kept after choosing the second terminal: the row offers "Detach (opened in Sample terminal)" and no Detach or "Show window" of its own; it runs only that backend's `detach` (calls `attach`, `detach`, then `detach` again through "Try again" after `notClosed`), the chosen terminal's backend is never built, the record goes. iTerm2's record with a plain choice: "Detach (opened in iTerm2)" through iTerm2's backend only. "Earlier launch pending" held by Sample terminal's launch names it with iTerm2 chosen (nothing asked of iTerm2's backend); iTerm2's own keeps the old line. iTerm2 chosen, a session open in Sample terminal here: "Open in Sample terminal on this Mac" with "Show in Sample terminal", focused through iTerm2's backend as an `.app` handle, and Open still attaches in iTerm2. The plain results: a confirmed window whose focus failed keeps "Confirmed…" with its note, a failed window focus and a refused app activation show their problems, an activated app "Already open in Sample terminal on this Mac — brought it forward", "Show window" focuses the launch's window through the chosen backend. "Open System Settings…" opens the Automation URL through the seam; an uninstalled choice's line names Sample terminal. Every existing popover, attach, New session and switcher fixture's content is what the old parameters build (requirement 12) |
| `TerminalSessionFixtureTests` (4) | `swift test --filter "Terminal session fixtures"` | The fixtures' Terminal and Ghostty decode as the built-ins (no script read); the galleries show iTerm2, Terminal and Ghostty chosen and each unavailable, every plain state, sessions open in another app, a window here; the attach gallery shows every window error's line, "Stopped after detaching 2", "Some may have been detached", the unavailable line, and the two plain context menus ("Show window", "Show in iTerm2", "Detach (opened in iTerm2)", "Show in Terminal", "Detach (opened in Terminal)"); ids unique per gallery, hosts `*.example`, the fake socket |
| `TerminalReviewFixTests` (7; review fixes) | `swift test --filter TerminalReviewFixTests` | The three should-fix findings of `docs/reviews/phase-I-12d2.md`: every test fails with its fix reverted (the five written first also failed on the code before the fixes). A window Sample terminal's backend recorded offers "Move here…"; the move goes to the backend: a stale record (it confirms a second window) replaces the record, a live one is refused with "This session is already open in a Sample terminal window…", "Bring forward" and "Detach from this Mac", the record kept; Terminal's gallery menu offers "Move here…" beside "Show window", iTerm2's rows dim it only while the index shows the session. "Detach (opened in Sample terminal)" with the second terminal chosen, Sample terminal chosen while it runs (the choice waits), `notClosed`: "Try again" repeats it on Sample terminal's backend (calls `attach`, `detach`, `detach`), the second backend never built; the same for iTerm2's record ("Detach (opened in iTerm2)", then iTerm2 chosen) and for a "Detach from this Mac" in Sample terminal while the second terminal was chosen meanwhile. Ghostty's open answering -1708 through a user definition: "… may have no “muxfinder_open” handler, or Ghostty's AppleScript may be turned off …" with "Try again" and "Open Settings", never "is turned off"; -10004 from it and -1708 through the built-in definition keep "Ghostty's AppleScript is turned off"; a user definition for Terminal names the handler only; an override is a user's; focus and close, -600 and iTerm2's wording unchanged; both new lines distinct from every window error's |
| `TerminalPublicInitTests` (1, core) | `swift test --filter "Terminal public initializers"` | Without `@testable`: `LoadedTerminalDefinition(definition:source:fileName:script:)` and `TerminalDefinitionCatalog(definitions:problems:)` keep their values, the catalog finds by id; `PlainTerminalWindowError.reason(of:)` reads " (No such file or directory)" |
| Never contact | `swift test --filter TerminalSeamTests` | `aPlainChoiceNeverContactsITerm2` passes unchanged (with the other 10) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0; exit 0 |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery popover\|attach\|switcher --appearance light\|dark --preview-snapshot docs/screenshots/<name>.png` | 6 PNGs written at 1× (popover 2336×1969, attach 1568×5506, switcher 1724×1855) and looked at: every existing state, then per terminal the rows' states (8 popover states, 5 switcher states) and the attach states (window errors, launch failures, refusals, iTerm2's earlier launch held elsewhere, Detach, Detach other clients stopped, the plain Move here and Detach other clients confirmations, the unavailable choice, not brought forward; each card at most 3 rows so none scrolls) and the Terminal and Ghostty context menus; legible in both appearances |
| Terminal apps | `pgrep -x Terminal`; `pgrep -x ghostty` before and after the work | no process of either, both times |
| Review fixes (2026-11-07) | `swift build`; `swift build -Xswiftc -warnings-as-errors`; `swift format lint -r Sources Tests`; `swift test`; `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app`; the attach gallery's two `--preview-snapshot`s; `pgrep -x Terminal`, `pgrep -x ghostty` before and after | all exit 0; 1183 core tests in 129 suites and 548 UI tests in 55 suites (7 new in 1 suite); one expectation of this phase's `anotherTerminalsRecordDetachesThroughItsOwnBackend` now expects "Move here…" offered beside a window (the finding), no other expectation changed; attach 1568×5506 light and dark, Terminal's context menu card now with "Move here…" not dimmed; no process of either app |

**Owed** (`docs/MANUAL-CHECKLIST.md` item 28): a real Open, "Show window", Detach, Move here and
"Detach other clients…" in Terminal and Ghostty (Apple events, real windows); the real lines of
a denied permission and of Ghostty's AppleScript turned off (its error number is a guess:
-1708 or -10004), "Show in Terminal" for a session open there, "Detach (opened in …)" after
a change of terminal, and Move here beside a window that is still attached (refused) and one
whose client was detached in tmux (moves here).

### Phase I-12e — other terminals, the docs (2026-11-07)

Documents only (PLAN.md Phase I-12, its I-12e calls; D38 *The docs (I-12e)*): the new
`docs/TERMINALS.md`, the addendum at the end of `docs/REQUIREMENTS.md` (the brief above it
unchanged), and README, `docs/ARCHITECTURE.md`, the matrix above, `docs/MANUAL-CHECKLIST.md`,
`CLAUDE.md` and D38 brought up to date. Every fact was taken from D38, D3's extension, the code
in `Sources/MuxFinderCore/Terminals/` and the UI wording, the built-ins in
`Resources/Terminals/` and the probe commands' `--help`. No file under `Sources/`, `Tests/`,
`Resources/` or `scripts/` changed, so no test, gallery, self-test or `e2e-*` run was due; no
real run of any kind, nothing contacted iTerm2, Terminal or Ghostty.

| Check | Command | Observed result |
|---|---|---|
| Terminal apps before | `pgrep -x Terminal`; `pgrep -x ghostty` | exit 1 each, no output |
| The worked `exec` example loads | `mktemp -d /private/tmp/mfx.XXXXXX`, then `chmod 700` it; `docs/TERMINALS.md`'s example written into it as `example-term.json`; `swift run muxfinder-probe terminals list --builtin-directory Resources/Terminals --user-directory <that folder>` from the repository root | exit 0: under `definitions`, `example-term` with source `user`, open `exec`, focus `app`, its app not installed (`notInstalled`, permission `notNeeded`), beside the built-ins `ghostty` and `terminal` (`builtIn`, minimum version `meets`, `targetNotRunning`); `problems` empty. The folder was removed afterwards; the real `~/Library/Application Support/muxFinder/terminals/` was never created (still absent) |
| Terminal apps after | `pgrep -x Terminal`; `pgrep -x ghostty` | exit 1 each, no output: no change |
| `--help` of the commands documented | `swift run muxfinder-probe local-clients --help`, `plain-proof --help`, `attach --help`, `e2e-plain --help`, `terminals list --help`; `.build/debug/muxfinder-launch --help` | usage only, nothing contacted; exit 0 each, except `terminals list --help`, which prints the usage after a usage error and exits 64 (`--help` is read as an option of `list`; `terminals --help` exits 0) |
| Build | `swift build` | exit 0 |

Two earlier documents disagreed with the code and were corrected, the code winning:
`docs/MANUAL-CHECKLIST.md` item 28 said a plain window's helper "explains and waits" after
"Detach from this Mac", but the helper explains and waits for Return only after a failure (a
clean detach ends it, and the terminal's own setting decides whether the window closes); and
`CLAUDE.md` read as if `attach-plain` ignored `testLaunchDelaySeconds`, which it honors in test
mode, and as if the helper never ended younger than 10 s on a terminal, which `attach-plain`
does without `keepsMinimumLifetime` (`LaunchHelperPlain.swift`). The checklist gained item 29 (onboarding on a Mac without
iTerm2) and, in item 28, Open, Detach and Move here with Ghostty chosen and on Saturno's
session, which the specification's acceptance asks for.

### Phase I-13a — the update check, core (2026-11-07)

The check's core (PLAN.md D39, Phase I-13 *The orchestrator's calls for I-13a*): versions and
tags, the bounded parser of `releases/latest`, the transport and its `URLSession`
implementation, the 304 rule, `update-state.json`, the `checkForUpdatesAutomatically` toggle,
the scheduler and the probe's `update check`. No download, no install, no UI, and nothing in
the app creates the scheduler yet (I-13c). **No request was sent to GitHub or any other
server** (*Unattended-run rules* 3): `URLSessionUpdateTransport` was exercised only through
`UpdateStubProtocol`, registered as the only protocol class on each session's configuration
and claiming every request (a mutation that follows every redirect was caught: the stub saw
the foreign URL and the test failed); the scheduler and the probe ran over
`FakeUpdateTransport`; every body is synthetic JSON written by hand (no GitHub answer was
pasted). Store tests ran on private folders only: the real
`~/Library/Application Support/muxFinder/` holds no `update-state.json` and its
`preferences.json` is unchanged (last modified 2026-10-24).

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1263 core tests in 137 suites (80 new in 8 suites, 4 of them the review fix's) and 548 UI tests in 55 suites (unchanged); before 1183 + 548. No existing expectation changed |
| `UpdateVersionTests` (5) | `swift test --filter UpdateVersionTests` | `0.2.0`, `10.20.30` and 9-digit parts parse; refused: missing or extra parts, leading zeros (`0.02.0`), signs, spaces, a line feed, suffixes, full-width and Arabic-Indic digits, 10-digit and 20-digit parts, `0x1`, `1e3`; tags only with a lowercase `v` (`V0.3.0`, `0.3.0`, `vv0.3.0`, `v0.3.0-rc1` refused); numeric order (`0.10.0` > `0.9.0`); the URLs built from the compiled-in owner and repository |
| `UpdateReleaseParserTests` (13) | `swift test --filter UpdateReleaseParserTests` | The hand-written body gives v0.3.0, its page, the asset with the digest lowercased and its size; newer only when strictly greater, never for an equal, older or unparseable running version; a newer release without an asset offers its page only; drafts and prereleases offer nothing, a non-boolean flag is malformed; 11 odd tags `unrecognizedTag`; 19 foreign `html_url`s (http, other hosts, other owner or case, another page, `..`, `.`, `%2e%2e`, a port, a user, a query, a fragment, no scheme) `releasePageNotOurs`; over 1 MiB `tooLarge`, not JSON, not an object; no asset, a near name, two `muxFinder.zip` (none trusted); 8 foreign or mismatched download URLs and a non-string one; the digest missing, `null`, `sha512:`, `SHA256:`, 63 or 65 hex, a non-hex character; sizes 0, -1, 50 MiB + 1, a string, 1.5, `true`, `null`, `1e7` refused, 1 and 50 MiB accepted; `state` other than `uploaded` |
| `UpdateTransportTests` (13) | `swift test --filter UpdateTransportTests` | The request: `GET`, timeout 15 s, headers exactly `Accept: application/vnd.github+json`, `Accept-Language: en` (a constant, so the system adds none from the user's languages) and `User-Agent: muxFinder/0.2.0`, plus `If-None-Match` when given; no `Cookie`, no `Authorization`; a `Set-Cookie` answer leaves the next request without a cookie; the configuration: no cookie, cache or credential storage, 15 s and 30 s, no extra headers, no waiting for connectivity, the stub as the only protocol class; an `ETag` over 256 characters or with a control character neither kept nor sent; 304 `notModified`; 403, 404, 429, 500, 502 `httpStatus`; rate limits by `x-ratelimit-remaining: 0` + `x-ratelimit-reset` and by `retry-after` on 403 and 429 (a past reset is now, both forms: the later, `retry-after` on 503 is a status); bodies over 1 MiB with and without `Content-Length` `tooLarge`, exactly 1 MiB read; offline, timed out and other errors; redirects to 6 foreign or non-`https` targets not followed (the 302 is the answer, the stub saw only the first URL), one within `https://api.github.com` followed; an `http` URL never sent |
| `UpdateCheckTests` (7) | `swift test --filter UpdateCheckTests` | A 200 keeps the release and its `ETag` and clears a rate limit; a draft keeps neither; an unreadable 200 drops the `ETag` and keeps the earlier release, a failure; a 304 with a kept release is a success worked out against the running version (newer for 0.2.0, up to date for 0.3.0); a 304 with none drops the `ETag` and fails; a rate limit recorded at most 24 h ahead and never before now; statuses and failures change nothing; a recorded rate limit is in force only up to 24 h ahead |
| `UpdateStateStoreTests` (9) | `swift test --filter UpdateStateStoreTests` | The probe's `existingPrivate` policy refuses a folder that is not private and changes no folder's mode (the review fix's regression); no folder or file: never checked, nothing created; a round trip (0600, folder 0700, ISO 8601 with milliseconds, the digest lowercase); 18 invalid files (not JSON, another schema, a bad date, `ETag`, version, tag, page, asset URL, digest, size, asset problem, neither asset nor problem) read as never checked and are replaced with no backup; a file readable by others or over 64 KiB is not trusted and is replaced by a private one; a symbolic link, a folder and a FIFO at the name are never read (the FIFO does not block) and refuse the save, the link's target unchanged; a linked folder is never used |
| `UpdateCheckPreferenceTests` (6) | `swift test --filter UpdateCheckPreferenceTests` | On with no file, no key, `null`, `0`, `"false"` or `{}`; `false` reads as off; off writes `false` under the lock (0600) and on writes `true`, the other keys kept; on with no file creates nothing, the value the file holds writes nothing; a non-boolean value is kept by other changes and replaced by the toggle's save; an unusable file refuses the change; the in-memory store |
| `UpdateSchedulerTests` (19) | `swift test --filter UpdateSchedulerTests` | Nothing armed or sent before `start`; nothing armed or sent while the state is still loading (a suspended load: a wake and a toggle after 5 s wait for it, then the loaded throttling and rate limit apply, and a manual check waits for the load too; the review fix's regressions); the first check 5 s after it, not at 4.999 s; then nothing for 24 h (not at 24 h - 1 s), the next with `If-None-Match`, a 304 keeping the release; a failure retried after exactly 1 h; a 304 with nothing kept refetches an hour later without the `ETag`; a rate limit holds every automatic check until its date, a manual check during it answers "rate limited until" without sending; automatic checks off: nothing armed or sent over 4 days of wakes, then on: one check; a manual check with them off (and before `start`) sends one; a manual check joins the automatic one in flight, and manual checks never overlap (one request each time); a last check in the future counts as due, and so after the clock is set back while running; the clock set back before the first check still gets it 5 s later (a regression of this phase's own: without the gate's settling it never came); waking past the due time checks at once; the next launch keeps the schedule (23 h left after an hour); the offer follows the running version; `stop` arms and sends nothing more; the published stream shows checking, then the outcome; a state that cannot be saved still schedules. Six runs in a row of the scheduler and transport suites: all passed |
| `UpdateProbeTests` (8) | `swift test --filter UpdateProbeTests` | `--help` in 6 positions: usage, exit 0, no transport made; 14 unusable argument sets (no subcommand, unknown ones, a bad or repeated `--running-version`, `--state` relative, a link, a file, missing, with `..`, `/tmp`): exit 64, no transport; a `--state` folder that is not already private (modes 755, 750, 705, 770, 701, or an ACL entry): exit 64, no transport, its mode and ACL left as they were (the review fix's regression); the JSON of a newer release (exit 0, version and `User-Agent` `0.0.0`), up to date, without an asset, a draft, 6 failures and a rate limit (exit 1); with `--state` on a private folder: the file written there only (0600), the `ETag` sent back, a 304 reusing the kept release, a recorded rate limit sending nothing |
| Probe help | `swift run muxfinder-probe update --help`; `swift run muxfinder-probe update check --help`; `swift run muxfinder-probe update check --running-version 0.2` | usage, exit 0; usage, exit 0; usage error, exit 64 (no transport made in any) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |

**Owed** (`docs/MANUAL-CHECKLIST.md` item 30): the real `update check`, which sends one request
to `api.github.com`: the answer for the published release, the `ETag` round trip with
`--state`, and that nothing else is contacted.

### Phase I-13b1 — the update's download and verification, core (2026-11-07)

From a release offer to a verified `muxFinder.app` in a private staging folder (PLAN.md D39
*The download and verification (I-13b1)*, Phase I-13 *The orchestrator's calls for I-13b1*):
the staging folder's rules, the download and its `URLSession` transport, the archive check,
`ditto` under its watchdog, the shape, the code check with notarization, the versions, the
pipeline's verdicts, cleanup and identity binding, and the probe's `update verify`. No eligibility, swap, relaunch or UI (I-13b2, I-13c). **No request
was sent to GitHub or any other server** (*Unattended-run rules* 3):
`URLSessionUpdateDownloadTransport` was exercised only through `UpdateStubProtocol`, the only
protocol class on its sessions (it now also routes release download URLs by their tag and can
hold an answer half sent, for Cancel); the probe's latest mode ran only over fakes. Every zip
was built with `ditto -c -k` in a private temporary folder, and every signature was ad hoc
(`codesign -s - --force` on stubs, no `--timestamp`, no keychain identity, no `notarytool` or
`stapler`). Nothing was written outside private folders under `/private/tmp` and the
repository: the real `~/Library/Application Support/muxFinder/` holds no `update-state.json`,
and `build/muxFinder.app` was not touched.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build`; `swift build -Xswiftc -warnings-as-errors` | exit 0, no warnings; exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1319 core tests in 144 suites (56 new in 7 suites) and 548 UI tests in 55 suites (unchanged); before 1263 + 548. No existing expectation changed |
| `UpdateDownloadTests` (14) | `swift test --filter UpdateDownloadTests` | One `GET` of the exact asset URL with headers exactly `Accept: application/octet-stream`, `Accept-Encoding: identity`, `Accept-Language: en`, `User-Agent: muxFinder/0.2.0`, timeout 30 s, no cookies; the file in the staging folder 0600 with the same bytes, progress rising to the declared size; the configuration (ephemeral, nothing stored, 30 s and 20 min, TLS 1.2, the stub only); a byte past the declared size `tooLarge`, a short body `incomplete`, a `Content-Length` other than the declared size stopped before reading (no progress), a digest mismatch, each leaving nothing; redirects to `objects.githubusercontent.com` and `release-assets.githubusercontent.com` followed, 7 others refused with their reason and never requested (`http`, `example.com`, a look-alike suffix, `api.github.com`, a user, port 8443, `ftp`), a sixth redirect refused; an `http` asset never sent, three foreign asset URLs and a release without an asset refused before anything is created; 404, 500, 403, 206, timed out, offline (three kinds) and a TLS failure mapped; Cancel mid-transfer: `cancelled`, the partial file deleted; the sink's bound; the zip mode's copy (the bytes, an existing `muxFinder.zip` never replaced or removed, a mismatch, a missing file, a link, a folder, an empty file and a 50 MiB + 1 sparse file refused); reasons lowercase with no host or path |
| `UpdateArchiveTests` (7) | `swift test --filter UpdateArchiveTests` | A zip like the real one (`._` entries for a file and two folders, a link inside) passes the archive check (its entry count and declared bytes) and every step, the `._` entries becoming extended attributes with no `._` file left; refused before `ditto` runs (the runner never called) with nothing left: a 16 MiB run of zeros (`ratioTooHigh` with the standard bounds; `tooLarge`, `entryTooLarge`, `tooManyEntries` with lower ones) and an entry whose declared size was raised to 300 MiB (`entryTooLarge`); 13 malformed archives (truncated, entry count, directory offset, a local name differing from its record, bytes no entry lists, a packed size, a ZIP64 end record and extra field, encryption, bzip2, a FIFO, a wrong comment length, empty); 9 names (`..`, absolute, `.`, an empty component, a backslash, outside the app, under `__MACOSX` but not the app, a duplicate differing only in case, below a link); a zip whose directory and data descriptor declare twice the packed size for an entry that unpacks to 64 MiB passes the archive check, then fails the extraction `expansionExceeded` (`ditto` ran once) with nothing left; a stand-in for `ditto` writing 2 MiB past a 1 MiB budget, or more entries than the bound, stopped by the watchdog while it waits (cancelled, within 10 s), nothing left; the name rules and the standard bounds |
| `UpdateExtractionTests` (9) | `swift test --filter UpdateExtractionTests` | A well-formed stub with two links inside passes (8 entries, 2 links), leaving only `extracted`; refused by the archive check before `ditto` (`outsideApp`): two apps, only a file, only a folder, `MuxFinder.app`, `Other.app`, an extra top-level file; refused at the shape step: `muxFinder.app` as a file and as a link, an absolute link, a link out by `..`, a link out through another link (`MacOS/up → ..`, `escape → MacOS/up/../..`); nothing left in each case; the shape's top level in hand-made trees (two apps and an extra file `extraEntries`, another name `wrongName`); the bounds (more than 5 entries, more than 1,000 bytes, folders nested deeper than 2); a FIFO in a hand-made tree refused unopened; nothing unpacked `noApp`, an empty zip an extraction failure; the link rule's cases; `ditto`'s argv (`-x -k <zip> <folder>`), `PATH`-only environment, 120 s bound, and its exit, signal, timeout, cancellation and start failure mapped, a missing destination refused before it runs; bytes that are not a zip refused by the archive check (`malformed`), nothing left |
| `UpdateCodeCheckTests` (7) | `swift test --filter UpdateCodeCheckTests` | Team IDs: 3 accepted, 15 refused (empty, 9 and 11 characters, lowercase, a space, a quote, `É`, a hyphen, a line feed, NUL, a full-width letter, an injection attempt, a backslash); the full requirement's exact text, every clause compiles; the flags include strict, all architectures, nested code, the two restrictions, and neither revocation nor network access; an ad hoc signed stub with our identifier `notDeveloperID`, with another identifier `notOurs`; the `notarized` clause alone fails for an ad hoc stub while its identifier clause passes; an unsigned stub and a tampered one (a sealed resource changed after signing) not valid, a missing path unreadable; through the verifier with the real checker, an ad hoc stub in a zip fails the signature step ("the app isn't signed with a Developer ID certificate"), notarization and versions not run, nothing left |
| `UpdateBundleVersionsTests` (3) | `swift test --filter UpdateBundleVersionsTests` | The happy path (and build 1 over running build 0, 9-digit builds); identifier missing, differently cased, longer, empty or a number; short versions unparseable (7) or another version (3); 13 unparseable builds (`0`, `03`, signs, spaces, `3.0`, 10 digits, an Arabic-Indic digit, `0x3`, a number); 7 unparseable running builds; equal and smaller builds `buildNotNewer`; `Info.plist` over 256 KiB, an array, a link and a linked `Contents` not read; through the verifier (a passing fake checker), each problem fails the versions step after notarization with nothing left, and the release's own version keeps only `extracted/muxFinder.app` |
| `UpdateVerifierTests` (10) | `swift test --filter UpdateVerifierTests` | The staging folder: relative, `..`, `//`, missing, `/tmp` (a link), a file, a link, mode 750 (left 750), an ACL (left), another owner refused; replaced after the check: refused at the next use, nothing written; success: all seven steps passed in order, only `extracted` (0700) left, the zip deleted, the bundle's identity that of `extracted/muxFinder.app`; the bundle replaced during the code check (by the checker), or replaced or turned into a link to the original before the code check or before the versions are read: `bundleChanged` at the signature or versions step, nothing after it run, nothing left; a digest mismatch stops everything (the checker never asked); the checker's answers mapped to the signature and notarization steps; an `extracted` folder that was there before is never removed or written into; a read-only folder unpacked from the zip is still removed; a download through a fake transport verified, and one through the `URLSession` transport over the stub (via `release-assets.githubusercontent.com`) passing every step up to the versions; transfer failures and a cancelled task stop at the download with nothing left |
| `UpdateVerifyProbeTests` (6) | `swift test --filter UpdateVerifyProbeTests` | `--help` in 4 positions: usage, exit 0, no transport; 25 unusable argument sets (missing options, bad Team IDs, mixed modes, a relative or missing zip, a bad digest or version, bad running builds, repeats, unknown options, `--into` missing, `/tmp`, relative or another user's): exit 64, no transport, nothing written, the Team ID never echoed; `--into` not empty or not private refused and left as it was; the zip mode passing (exit 0, every step passed, the bundle's relative path, version and build, no Team ID, home or `--into` path printed, the zip deleted); its failures at the digest, signature (`otherTeam`), notarization and versions steps (exit 1, code and reason, nothing left); the latest mode over a fake check and a fake download (exit 0, check and download made with 0.0.0), and a failed check, a release without an asset and a draft stopping before any download |
| Notarization proof | Security.framework on a copy of `build/muxFinder.zip` unpacked with `ditto` in a private folder, with the code check's flags; `codesign --verify --strict --deep -R` alongside | The `notarized` clause, alone and joined to the full requirement, passed the stapled 0.2.0 bundle (status 0) and failed an ad hoc re-signed copy (`errSecCSReqFailed`); every other clause also failed for that copy. With the stapled ticket removed the clause still passed with network access disabled (the system had recorded the ticket for that code). `notarized` joins the requirement; `spctl` is not used |
| Real zip mode, the release copy | `swift run muxfinder-probe update verify --into <empty private folder> --team-id <the copy's Team ID> --zip <copy of build/muxFinder.zip> --sha256 <shasum -a 256 of the copy> --expect-version 0.2.0 --running-build 1` | exit 0, `verdict` `verified`: download, digest, extraction, shape (14 entries, 19,216,378 bytes, no link), signature, notarization and versions passed; bundle `extracted/muxFinder.app` 0.2.0 build 2; zip size 6,124,209; `cleanedUp` true, only `extracted` left in the folder |
| Real zip mode, one byte changed | the same with a copy whose byte at offset 3,000,000 was inverted, the untouched copy's digest | exit 1, `failedStep` `digest`, `code` `digestMismatch`, "the download doesn't match the release's checksum"; download passed, the rest not run; the folder empty afterwards |
| Real zip mode, another Team ID | the untouched copy with the well-formed Team ID `ZZZZZZZZZ9` (checked to differ from the real one) | exit 1, `failedStep` `signature`, `code` `otherTeam`, "the app is signed by another developer"; download to shape passed, notarization and versions not run; the folder empty afterwards |
| Real zip mode after the review fixes | the release-copy command again on a fresh copy (the archive check, the watchdog and the identity binding in place) | exit 0, `verdict` `verified`: every step passed; shape 14 entries, 19,216,378 bytes, no link; bundle 0.2.0 build 2; zip size 6,124,209; `cleanedUp` true, only `extracted` left |
| Watchdog on real `ditto` (a one-off, not in the suite) | `lyingDirectoryIsStoppedDuringExtraction` with the entry at 512 MiB, twice | both times `ditto` was stopped mid-run by the watchdog (the runner's run cancelled), the extraction `expansionExceeded`, nothing left; at 64 MiB `ditto` can finish within one 50 ms interval, so the suite's test is caught mid-run or by the measure at `ditto`'s end |
| Probe help | `swift run muxfinder-probe update verify --help` | usage, exit 0, nothing contacted |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |

The Team ID was read into a private file of the run's folder and passed on the command line;
it appears in no output, log or document. Every private folder (the copies, the proof's
unpacked and ad hoc copies, the `--into` folders) was removed afterwards. **Owed**
(`docs/MANUAL-CHECKLIST.md` item 30): the real `update verify --latest`, which asks GitHub for
the latest release and downloads its `muxFinder.zip`.

### Phase I-13b2 — the update's eligibility and install, core (2026-11-07)

The running app's update eligibility, the update folder and its run folders, the swap bound by
device and inode with its rollback, the relauncher, the leftover cleanup, the old helpers'
compatibility and the pipeline I-13c drives (PLAN.md D39 *Eligibility and install (I-13b2)*,
Phase I-13 *The orchestrator's calls for I-13b2*), plus the read-only
`--report-update-eligibility` flag. No UI and nothing wired into the app (I-13c). **No request
was sent to any server**; no swap touched `/Applications`, `~/Applications` or `build/`; no
test or run used `/usr/bin/open` (the relauncher's opener was always a stand-in script); every
signature was ad hoc. Swaps, rollbacks, cleanups and relaunches ran only in private folders
under `/private/tmp`, all removed; the real `~/Library/Application Support/muxFinder/` has no
`update` folder.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1360 core tests in 151 suites (41 new in 7 suites) and 549 UI tests in 56 suites (1 new in 1 suite); before 1319 + 548. No existing expectation changed |
| `UpdateEligibilityTests` (9) | `swift test --filter UpdateEligibilityTests` | An eligible copy records the team, path, identity, build and version (a missing update folder on the same device too); 18 refusing facts give their reasons in the decision's order (signature unreadable, not Developer ID with and without a Team ID, Developer ID without one, translocated, three bundle problems, read-only volume, not owned, bundle or parent not writable, three unparseable builds, an unusable update folder, another device for an existing or a missing one), each phrase starting in lowercase with no path or Team ID; the signature decided first; the report's lines (eligible and not, the Team ID only present or absent, never its value or a path); the reader on this process (`SecCodeCopySelf`): read, not Developer ID; on an unsigned and an ad hoc stub: not Developer ID, no Team ID; a missing path unreadable; the bundle facts on a stub (identity, owner, write access, versions, the executable inside), an executable elsewhere or unknown, another owner, a link on the path, a missing bundle, a relative path, a foreign identifier, translocation by component; over stub folders: eligible, then not writable once the parent is 0500, nothing created; `readsAReleaseCopy` runs only with `MUXFINDER_TEST_RELEASE_BUNDLE` (skipped otherwise) |
| `UpdateStagingRootTests` (8) | `swift test --filter UpdateStagingRootTests` | Looking creates nothing (missing with the base's device, then usable once made 0700); another owner, mode 750 (left 750), an ACL (left), a link on the path, a file on the path and a relative path unusable; an update creates the support and update folders 0700 and refuses a 755 one (left 755), a link (its target untouched) and a path two levels missing (nothing created); run folders fresh, `run-` and 16 hex digits, 0700, I-13b1's staging folder, `run.lock` held until released, another device refused before anything is made; the cleanup: one unused run folder deleted (with a read-only folder and a link to an outside folder inside, the outside file kept), one kept while a real child (an ad hoc copy of `/bin/sleep`) runs from inside it, one kept while locked, `update.lock`, a file and a link named like a run folder ignored (counts 1 removed, 1 in use, 1 locked, 3 ignored, 0 failed), then both deleted once the child ended and the lock was released; nothing touched without an update folder (none created), with a 755 one, or while another holder keeps `update.lock` (`busy` after the wait); every count read over repeated cleanups while one reports more locked folders than the test holds (a lock just released can look held while a child another test spawns is starting); the review's regression: a live update holds a run folder's lock, a scan taken then sees nothing in it, and right after that scan the update swaps the old bundle in and releases the lock: kept as locked (no scan made), then in use (one scan, after the lock); recovery markers (a file, a folder, a link) keep their run folders on every cleanup with no scan, an unmarked one beside them deleted; an incomplete scan (the list failing, a list that stays full, a running process's path unreadable, over the injected table) keeps both run folders as unverified with the problem, and a complete one then deletes them |
| `UpdateSwapTests` (9) | `swift test --filter UpdateSwapTests` | `RENAME_SWAP` exchanges two folders in different parents of a private folder (identities and contents exchanged; a missing path `ENOENT`); a swap with everything in place installs the new stub and leaves the old in the run folder, the code check asked about the verified bundle; a quit's cancel during the code check stops before the exchange (`cancelled`, no exchange call, both places unchanged); refused with nothing changed: the installed stub replaced, a link on its path, the download replaced, the code check failing (signature, notarization), the installed stub replaced during the code check; an exchange failing with `EXDEV` (`swapFailed`, nothing to undo) or reporting success without exchanging (`swapUnconfirmed`, nothing to undo); the review's regression: the installed path replaced right after the exchange: nothing exchanged back (one exchange call), the replacement left installed untouched, the old stub in the run folder, `recoveryRequired` and the run folder marked; `recoveryRequired` and marked too: the run folder's old stub taken away after the exchange, the download replaced after a failed exchange, and the installed path replaced between the reverse's checks and the reverse exchange (the old stub back, the other folder in the run folder); a reverse exchange failing (`EIO`) or only reporting success after a successful swap: `failed`, the swap's state unchanged, no marker; the phrase (lowercase, no path) and the codes; a successful swap undone (`rolledBack`), then nothing to undo |
| `UpdateRelauncherTests` (3) | `swift test --filter UpdateRelauncherTests` | The argv exactly `/bin/sh -c <script> muxfinder-relaunch <pid> <opener> <bundle> 60`, the script constant holding none of the values, the environment only `PATH=/usr/bin:/bin`; 9 unusable argument sets refused (pid 0 or negative, relative opener or bundle, `-a.app`, a line break or NUL, waits 0 and 601) and a spawn of anything but the shell; a real run: its own session, still waiting after 1.2 s with nothing opened while the `sleep` child runs, then the stand-in opener run exactly once with the bundle path and exit 0 once the child ended; a 1 s wait that runs out: exit 75 after at least 0.9 s, nothing opened, the child untouched; a relative opener and a pid `12x` given to the script exit 64, nothing opened |
| `UpdatePipelineTests` (6) | `swift test --filter UpdatePipelineTests` | End to end over a stub installed app, a synthetic zip, I-13b1's real verifier with a fake code checker, the real exchange and the real relauncher with the stand-in opener: states `downloading` from 0 to the size, then `checking`, then `installing` and `relaunching`; the run folder locked while prepared; the new build installed and the old (with the recorded identity) in the run folder, released; nothing opened while the `sleep` child runs, then the installed path opened once and exit 0; a second install `alreadyUsed`; the next cleanup removes the run folder (only `update.lock` left). Discard removes the run folder once. A development signature refused with no folder created; a digest mismatch refused with the run folder removed; a cancel during the download `cancelled` with the run folder removed; the code check failing again at install (`signature.otherTeam`, nothing to undo) and a relauncher that cannot start (`relaunchNotStarted`, `rolledBack`, the old build back) both leave the old stub and remove the run folder; the review's regression end to end: the installed path replaced right after the exchange: `swapUnconfirmed` with `recoveryRequired`, one exchange, no relauncher, the replacement installed untouched, the old stub in the run folder with the marker, released, and two later cleanups keep it (kept for recovery) |
| `UpdateProcessScanTests` (5) | `swift test --filter UpdateProcessScanTests` | Over an injected process table: every path read is complete (pid 0 left out, the list asked with the estimate plus 64); the estimate failing, the list failing and an empty list `listFailed`; a list filling its buffer read again with twice the room (74, 148, 296), one that stays full `listTruncated` after 4 attempts; a pid whose path cannot be read makes it incomplete (`pathUnreadable`) with `kill` 0 or `EPERM` while alive or its state unreadable (`ENOENT` too when the state cannot be read), and is passed over when `kill` answers `ESRCH`, `sysctl` no longer lists it, it is a zombie or exiting, or it is alive with `ENOENT`; on the real kernel: complete with this process's executable, a real zombie child (`proc_pidpath` `ESRCH`, `kill` 0) and a running ad hoc copy of `zsh` whose file was deleted once it ran (`ENOENT`, alive) leave it complete, the deleted one not listed |
| `UpdateOldHelperCompatibilityTests` (2) | `swift test --filter UpdateOldHelperCompatibilityTests` | A request in the 0.2.0/0.3.0 shape (no `terminal`, a Move here) decodes as a well-formed iTerm2 attach with no plain field; the current result has exactly those releases' fields and round-trips |
| `UpdateEligibilityFlagTests` (1, UI) | `swift test --filter UpdateEligibilityFlagTests` | `--report-update-eligibility` alone is its own mode (no profile rewrite, no shortcut), with `--appearance` too; combined with each of 7 other modes in either order a usage error; its usage line in the usage text |
| `RENAME_SWAP` proof | a small C program calling `renamex_np(new, installed, RENAME_SWAP)` on `Applications/muxFinder.app` and `support/update/run1/extracted/muxFinder.app` in a `mktemp -d /private/tmp/mfx.XXXXXX` folder (APFS) | returned 0; each path then held the other folder (inodes exchanged, device unchanged, each marker file moved with its folder); the folder removed |
| Signature reader, the release copy | a copy of `build/muxFinder.zip` (0.2.0, Developer ID, stapled) unpacked with `ditto -x -k` in a `mktemp -d /private/tmp/mfx.XXXXXX` folder; `MUXFINDER_TEST_RELEASE_BUNDLE=<copy>/muxFinder.app swift test --skip-build --filter readsAReleaseCopy` | passed: Developer ID, and the Team ID equal to the one `codesign -dv` reports for the copy (compared in the test, never printed); `codesign -dvv` showed one Developer ID Application authority and one well-formed Team ID line (counted, not printed); the folder removed |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0 (Apple Development); exit 0; `build/muxFinder.zip` still there (6,124,209 bytes) |
| The flag | `ls -la ~/Library/Application\ Support/muxFinder/`; `build/muxFinder.app/Contents/MacOS/muxFinder --report-update-eligibility`; the listing again | exit 0: `not eligible (notDeveloperID: this copy isn't signed with a Developer ID)`, Developer ID no, Team ID present, translocated no, app folder usable, read-only volume no, writable yes (app folder, enclosing folder, owned), update folder not created yet, same volume yes, running version 0.2.0 build 2; the listings identical, no `update` folder |
| The flag with another mode | `… --report-update-eligibility --report-login-item-status` | exit 2, the usage error and the usage lines |
| Process table facts | small Swift programs (read-only, no signal sent but `kill(pid, 0)`) in a `mktemp -d /private/tmp/mfx.XXXXXX` folder, removed | about 1360 pids: every executable path readable except a zombie unreaped for days (`proc_pidpath` `ESRCH`, `kill` 0, `p_stat` `SZOMB`) and a running process whose executable had been replaced (`ENOENT`); a running ad hoc copy of `sleep`: `ENOENT` once its file was deleted, the new path once its folder was renamed; the programs' own zombie: `ESRCH`, `kill` 0, `SZOMB`, then `kill` `ESRCH` once reaped; under spawn load (four shells running `true` and `sleep 0` in loops, 3908 scans in 8 s) the only other unreadable paths were exiting processes (`ESRCH`, `kill` 0, `P_WEXIT`), 295 times; a lock file opened close-on-exec, locked and closed while four threads spawned `true` still looked locked to a fresh open 512 times in 20000 (a child being spawned holds every open file until its image starts) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |

A copy of a platform binary (`/bin/sleep`) run from a private folder is killed with SIGKILL on
this Mac (exit 137); the cleanup test signs its copy ad hoc first. **Owed** (I-13c's checklist
item): the real update from a published release to a newer one, including whether `open`
started by the relauncher, with only `PATH` in its environment, opens the new copy.

### Phase I-13c1 — the update notice in the app (2026-11-07)

The update check wired into the app in normal mode only, the popover's notice with "What's
new", the menu bar icon's dot and label, the seen version, and Settings › General's toggle,
button and status line (PLAN.md D39 *The notice (I-13c1)*, Phase I-13 *The orchestrator's
calls for I-13c1*). **No request was sent to any server, and the app was never launched in
normal mode** (it would send the check 5 s later) nor through `open`: every check ran over
injected fakes, galleries or the diagnostic modes, none of which creates the update machinery.
The real `update-state.json` and `preferences.json` were never read or written.

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0 |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | exit 0: 1365 core tests in 152 suites (5 new in 1 suite) and 567 UI tests in 57 suites (18 new in 1 suite); before 1360 + 549. No existing expectation changed. An earlier full run hit the known flaky `answersAndEndsAtEndOfInput` under load; it passed alone and in the final run |
| `UpdateModelTests` (18, UI) | `swift test --filter UpdateModelTests` | The mode gate: `[]`, `--appearance dark` and a `-psn_` argument create the machinery; 26 other argument lists (every preview gallery, the snapshot, both key view loops, every `--report-*` flag, the self-tests with and without keep, the removal with and without `--dry-run`, five unusable lists) create none, through the property and the pure function; the placement diagnostic's environment has none and its model and a fixture's are inert. Over a scripted transport, an in-memory state and preferences store, a manual clock and a private notification centre: toggle on, no request at 4.999 s, one at 5 s, none at 24 h − 1 s, the second at 24 h, none after `stop()`; toggle off, none in two days, one on "Check for updates…" (button disabled and "Checking for updates…" while it is held, then "muxFinder 0.3.0 is available" and "Last checked just now"); the toggle saved to the store then the first check armed, a refused save puts it back with "Couldn't save the setting"; toggle changes made while a suspended setting read is pending win over the stale value it returns (off over a saved on; off then on over a saved off, the first check 5 s later; a refused change back to the value read), the toggle, the store and the scheduler's automatic checks alike; a wake runs a check that came due while the wall clock moved; `AppModel` starts the update model with itself, shares it with Settings, marks the notice seen when the popover shows and stops the scheduler at shutdown (a later `checkNow()` answers cancelled, nothing sent). The notice: newer only (running 0.3.0, 0.4.0, `dev` and none, `upToDate`, `nothingOffered`, no offer show none), and through the scheduler for 0.3.0 against running 0.3.0, 0.4.0, 0.2.0 and the tags `v0.3` and `0.3.0`. The dot: shown with none or an older seen version, not for an equal or newer one, labels "muxFinder, update available" and "muxFinder"; a kept 0.3.0 shows the dot at launch, the popover shown records 0.3.0 in the store and clears it (the notice stays), a check offering 0.4.0 brings it back and the next showing records 0.4.0; a failed seen write leaves the dot and the store unchanged. "What's new" opens exactly the release page through the injected opener (a fixture's opens nothing). Every status line phrase (not checked yet, checking, up to date with version and build, newer, the seven failures, the rate limit's `HH:mm`, both nothing-offered phrases, a kept offer, "Last checked 2 min ago" and "2 hr ago"); the Settings fixtures (checking disabled, the toggle off, no section without a fixture). The dot drawn into an 18 pt template: still a template of the same size, opaque at the dot's centre, clear elsewhere; without the dot the base itself |
| `UpdateNoticeSeenTests` (5) | `swift test --filter UpdateNoticeSeenTests` | `markNoticeSeen(_:)` records 0.3.0, refuses 0.3.0 and 0.2.9 (one save), records 0.4.0 keeping the release, publishes it, sends nothing; a failing save keeps 0.2.5 and counts the failure, then records once the store works; through `UpdateStateStore` on a private folder the file is a regular 0600 file reading back 0.3.0, and after `stop()` nothing is recorded; with the mark's save held and a manual check offering 0.4.0 started, the pending mark is never in the status, and the check's saves wait for it: a failing save leaves the status, the last published status and the store without the mark (the check's `etag` and release saved), a succeeding one leaves the mark and the check's fields in the store, all three saves in order keeping the mark |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0 (Apple Development); exit 0 |
| Galleries | `build/muxFinder.app/Contents/MacOS/muxFinder --preview-fixtures --preview-gallery popover\|settings --appearance light\|dark --preview-snapshot docs/screenshots/<name>.png` | four snapshots written (popover 2336 × 2318, settings 2264 × 11790): the icon row (the dot with its clear ring, light and dark), "Update available: the notice", and the eight Settings update states |
| App shell | `CFFIXED_USER_HOME=$(mktemp -d /private/tmp/mfx.XXXXXX) build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`, after 4 s `pgrep -P <pid>` and `kill -TERM <pid>` | as before: 5 status-item windows, onboarding the only visible other window; no child; exit 0; the private home still empty (no `update-state.json`, `update` folder, `hosts.json` or `preferences.json`); removed |
| Popover placement | `CFFIXED_USER_HOME=$(mktemp -d /private/tmp/mfx.XXXXXX) build/muxFinder.app/Contents/MacOS/muxFinder --report-popover-placement &`, `pgrep -P <pid>` | as before: no child, "after-fix check: passed", exit 0; the private home still empty; removed |
| Eligibility | `build/muxFinder.app/Contents/MacOS/muxFinder --report-update-eligibility` | exit 0, as in I-13b2 (not eligible: not Developer ID; update folder not created yet; 0.2.0 build 2) |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |

**Owed** (`docs/MANUAL-CHECKLIST.md` item 31): the real notice and dot after a real check on an
older installed copy, the dot clearing once the popover showed it, "What's new" opening the
browser, the Settings line after a real check, and the toggle off.

### Phase I-13c2a — the update flow, model and wiring (2026-11-07)

The one-click update flow behind the notice: the offer, prepare with Cancel, failures, the ask
before quitting, install and the quit after `relaunchScheduled`, a quit's bounded waits and the
leftover cleanup at launch (PLAN.md D39 *The update flow (I-13c2a)*, Phase I-13 *The
orchestrator's calls for I-13c2a*). No visible change: the notice shows no Update, Download or
progress yet (I-13c2b). **No request was sent to any server, the app was never launched in
normal mode nor through `open`, `/usr/bin/open` was never run, and no installed or `build/` app
was swapped**: the flow ran only over a fake pipeline that records its calls. The real `update`
folder, `update-state.json` and `preferences.json` were never read or written;
`~/Library/Application Support/muxFinder/` listed the same before and after (no `update`
folder).

| Check | Command | Observed result |
|---|---|---|
| Build | `swift build` | exit 0, no warnings |
| Unit tests | `swift test` (with `TMUX_TMPDIR` unset) | UI: 583 tests in 58 suites (16 new in 1 suite; the mode test extended); core: 1365 tests in 152 suites, unchanged. An earlier full run hit the known flaky `answersAndEndsAtEndOfInput` under load (core, untouched); it passed alone and in the final full run |
| `UpdateFlowTests` (20, UI) | `swift test --filter UpdateFlowTests` | The offer: `.reading`, then `.update` when eligible; eligibility read once per notice version (the same version again reads nothing, a newer one reads again); no notice clears the offer. Not eligible: Download with the ineligibility's phrase, Update does nothing, Download opens exactly the release page. No asset: Download with "the release has no installable download" and no eligibility read. The inert flow offers, cleans and runs nothing. Prepare: downloading 40 of 100 (percent 40), a second Update starts no second prepare, checking, a late downloading ignored, then (nothing unsaved) installing and `relaunchScheduled`, the terminator called once with the state already `relaunchScheduled`. Percent and "Downloading… 40%" / "Downloading…" (unknown total). Cancel while downloading and while checking: the prepare sees cancellation, back to idle with Update offered, nothing installed. A prepare failure: "Couldn't update: <reason>", Update offered again and a second prepare runs; an eligibility refusal at prepare turns the offer into Download. The ask: both kinds of unsaved work named; Not now keeps it (`deferred`, Update not offered); Install and relaunch asks again; Quit and install installs and quits. Not now, then Install and relaunch with nothing unsaved installs without asking. `AppModel`'s source: nothing unsaved by default, a draft name with no New session window shown is not unsaved. Install failures: rolled back (the failure's phrase), `recoveryRequired` (the rollback's phrase), a failed rollback ("…, and the change couldn't be undone"), no path in any, no terminator, Update offered again. A quit while preparing cancels it (nothing installed, no terminator, no Update after). A quit once the swap began waits for a 1.2 s swap to end uncancelled, however long, then calls no terminator; a quit before the swap stops the install there (`cancelled`, nothing swapped, no terminator, editing still refused). While installing, the New session draft, Settings' host editor and directory list and opening a New session window refuse changes; a failed install restores editing. A cleared notice, then the same version: its offer is back with no second read. A newer notice during a prepare is shown after the cancel; one during the ask never changes what is installed (`preparedRelease`). A prepared update kept by Not now is discarded at quit. Cleanup: a live model with a flow runs it once at start and keeps its report; a model without a flow, a fixture's and the inert one have none |
| Mode test | `swift test --filter onlyTheNormalLaunchCreatesUpdateMachinery` | For the 3 normal argument lists `AppEnvironment.production(checksForUpdates: createsUpdateMachinery)` has the update flow (pipeline and cleanup); for the 26 others and every gallery it has none |
| App bundle | `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app` | exit 0 (Apple Development); exit 0 |
| Eligibility | `build/muxFinder.app/Contents/MacOS/muxFinder --report-update-eligibility` | exit 0, as before (not eligible: not Developer ID; update folder not created yet; 0.2.0 build 2) |
| App shell | `CFFIXED_USER_HOME=$(mktemp -d /private/tmp/mfx.XXXXXX) build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`, after 4 s `pgrep -P <pid>` and `kill -TERM <pid>` | no child; exit 0; the private home still empty (no `update-state.json` or `update` folder); removed |
| Popover placement | `CFFIXED_USER_HOME=$(mktemp -d /private/tmp/mfx.XXXXXX) build/muxFinder.app/Contents/MacOS/muxFinder --report-popover-placement &`, `pgrep -P <pid>` | no child, "after-fix check: passed", exit 0; the private home still empty; removed |
| Format lint | `swift format lint -r Sources Tests` | exit 0, no output |

**Owed:** the real update (a Developer ID copy older than a published release: Update, the
download, the checks, the ask, the swap, the quit and the relaunch) is the user's, with I-13c2b's
views and checklist item; the real cleanup at a normal launch is the user's too (a normal launch
sends the check).
