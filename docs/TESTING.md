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
| Unit tests | Tested hermetically | `swift test` (*Phase I-3b* for the latest counts). | `swift test`, 2026-10-23: exit 0, 680 tests in 67 suites (core) and 159 in 13 suites (UI). `swift build -Xswiftc -warnings-as-errors` and `swift format lint -r Sources Tests`: exit 0 each. |

Added after the brief (the user's reports of 2026-10-24, PLAN.md Phases 13 and 14):

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
| The session switcher: the shortcut toggles a non-activating panel centered on the display with the keyboard focus, in its upper part, over full-screen apps; a search field focused and empty at each opening; the live sessions in the popover's order (stale ones left out) with Phase 14's row look, filtered by the popover's rule; "New session…" last, naming the session from the filter; muted lines for hosts checking or unreachable; Return or a double-click opens as the popover does, Return on New session or ⌘N shows the form, ⌘R, ⌘, and Esc; it closes on success, keeps a failure on its row, and carries a failure that arrives once it closed to its next opening and the popover row; only one of it and the popover shows, and the engine hears one opened and one closed per change of "either one is visible" (PLAN.md Phase I-3b, D32, D22). | Tested hermetically and in the preview renders (both appearances); the app shell check as before. A press over a full-screen app, filtering and opening with iTerm2 coming forward, creating, and Esc giving the focus back: by a person (checklist 18). | Phase I-3b, 2026-10-24 (*Phase I-3b* below): `SwitcherContentTests`, `SwitcherControllerTests`, `SwitcherModelTests`, `GlobalShortcutAppTests.theShortcutTogglesTheSwitcher`; `docs/screenshots/switcher-states-*.png` rendered and inspected. |

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
  packed run; unknown enum values decode to `unknown`. Merge fixtures, which
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
  `tmuxRequestFailed`; a tmux reply without payload as an empty list; successful create tab,
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
  withdraws its request once iTerm2 answers. The New session sheet: This Mac by default, an
  empty or invalid name or directory reported inline with no creation, a valid name created
  (trimmed, directory kept, the user's shell) and attached with the sheet closed; for a remote
  host whose tab still waits, the new session's row shows "Still connecting — check the iTerm2
  tab" before the attach ended, "Show tab" activates that launch tab, a click starts nothing
  and quitting cancels it; a collision offering "Open existing", which resolves the name in a
  fresh listing of the host (the coordinator's discovery, while the engine's list is still the
  old one): the session that has the name now is opened, not the listed one that was renamed;
  with no session of that name any more, or a host that cannot be listed, the sheet says so and
  nothing is written or launched; another failure kept in the sheet until a field changes.
  Every failure path's message (each `AttachFailure`, each detach outcome, the Show tab notes,
  the missing helper, both focuses that did not bring the tab forward, the two "Open existing"
  outcomes that open nothing) is pairwise distinct and a sentence; every attach failure offers
  a recovery; the attach fixtures cover every state with synthetic data. In the core,
  `CreateAndAttachTests` checks that `onCreated` comes once, before the first state, and never
  for a failed creation, and that `currentSession(named:on:)` matches the exact name in a fresh
  listing (another case, a renamed session or no server is `sessionGone`).
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
  selection, Return picks, Esc closes the list and then the panel, ⌘F, ⌘N, ⌘R and ⌘, as
  before; ⌥↓ in the host list and in Move here is `ignored` (left to the focused view); the
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
  and an unusable file, with synthetic paths.
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
  showing the form with the filter's name for This Mac; Esc closing the directory list, then
  going back to the list, then closing; Return in the form creating, the created session's
  attach closing the switcher on success; ⌘R, ⌘, and ⌘F; a failure while it shows staying on
  its row; a failure after it closed (the launch held, then refused) on the popover row and
  pinned and selected at the next opening, once; a creation failure after the form was left
  putting the form back; the popover, then the switcher, then both, then neither giving one
  opened and one closed to the engine with each opening asking the other to close; both real
  controllers over fakes swapping; the fake registrar's press toggling the switcher with an
  empty, focused search field.
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
