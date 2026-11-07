# muxFinder progress checkpoint

Live head of the `/autoclaude-opus` run over `PLAN.md`. Closed phases keep one row here; their
narrative lives in `docs/progress-archive/<phase-id>.md`. `PROGRESS.json` is derived from this
file.

## Completed

| Phase | Title | Risk | Worker model | Review | Narrative |
|---|---|---|---|---|---|
| 1 | Package skeleton, process runner, quoting and validation | routine | opus | Codex, ship-with-fixes, `docs/reviews/phase-1.md` | `docs/progress-archive/1.md` |
| 2 | tmux discovery: probe, parser, identity, error classification | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-2.md` | `docs/progress-archive/2.md` |
| 3a | iTerm2 wire layer: protobuf codec, typed messages, golden fixtures | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-3a.md` | `docs/progress-archive/3a.md` |
| 3b | iTerm2 transport and client: WebSocket, cookie, API client, probe | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-3b.md` | `docs/progress-archive/3b.md` |
| 4a | Launch layer and helper: request files, guard, muxfinder-launch | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-4a.md` | `docs/progress-archive/4a.md` |
| 4b | Attach coordinator and probe commands | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-4b.md` | `docs/progress-archive/4b.md` |
| 4c | Real local proof: e2e-local passing, final integration proof | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-4c.md` | `docs/progress-archive/4c.md` |
| 5a | Existing-attachment detection, local | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-5a.md` | `docs/progress-archive/5a.md` |
| 5b | Remote attach over SSH | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-5b.md` | `docs/progress-archive/5b.md` |
| 6a | New session and vanished sessions | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-6a.md` | `docs/progress-archive/6a.md` |
| 6b | Move here: `moveHere`, `-d` only on confirmation, real runs closed | high | opus (impl + fix worker); closure runs: none (orchestrator) | Codex, ship-with-fixes, `docs/reviews/phase-6b.md` | `docs/progress-archive/6b.md` |
| 7a | Host configuration: `HostStore`, invariants, defaults, SSH config suggestions | routine | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-7a.md` | `docs/progress-archive/7a.md` |
| 7b | Refresh engine: `RefreshCoordinator`, `HostSnapshot`, attachment merge, `refresh --once` | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-7b.md` | `docs/progress-archive/7b.md` |
| 8 | Menu bar app and popover: `MuxFinderUI`, `AppModel`, `build-app.sh`, preview fixtures | routine | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-8.md` | `docs/progress-archive/8.md` |
| 9a | Settings window: host editor, launch at login, diagnostics, fix-its | routine | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-9a.md` | `docs/progress-archive/9a.md` |
| 9b | Onboarding window and "Set up SSH in iTerm2…" (`ssh-setup` helper mode) | routine | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-9b.md` | `docs/progress-archive/9b.md` |
| 10a | Attach UX in the app: state machine, row actions, Move here, Detach, New session, banners, self-test flags | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-10a.md` | `docs/progress-archive/10a.md` |
| 10b | Real self-tests: `attach-local`, `new-session-local`, quit leaves work running | high | none (orchestrator ran the real checks; no code change) | Codex, ship, `docs/reviews/phase-10b.md` | `docs/progress-archive/10b.md` |
| 11a | Profile core, helper `profile` mode, probe `profiles` / `e2e-profile` (hermetic) | high | opus (impl + fix worker); one inline orchestrator fix | Codex, ship-with-fixes, `docs/reviews/phase-11a.md` | `docs/progress-archive/11a.md` |
| 11b | Real profile runs: `e2e-profile` local and Saturno 14/14, iTerm2 `New Bookmarks` mirror handled | high | opus (snapshot fix, docs and review-fix workers); real runs by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-11b.md` | `docs/progress-archive/11b.md` |
| 11c | Settings "Persistent profiles" tab, host-editor fields, launch-time and after-save rewrite | routine | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-11c.md` | `docs/progress-archive/11c.md` |
| 12a | Install and uninstall scripts, hermetic check, README, ARCHITECTURE, testing matrix, manual checklist | routine | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-12a.md` | `docs/progress-archive/12a.md` |
| 12b | Acceptance run: every unit test, all `e2e-*` locally and on Saturno, both self-tests, clean-`build/` reproduction, recorded | routine | opus (docs worker); real runs by the orchestrator | Codex, ship, `docs/reviews/phase-12b.md` | `docs/progress-archive/12b.md` |
| 13a | Client, helper and spike: SetProperty/GetProperty, `buryLaunchTab`, helper restore (result → `Disinter` → DSR, bounded), `e2e-bury` spike local and Saturno, D29 | high | opus (impl, spike and review-fix workers) | Codex, ship-with-fixes, `docs/reviews/phase-13a.md` | `docs/progress-archive/13a.md` |
| 13b | Coordinator bury (step 10, `AttachResult.burial`), race by order (`peekResult`), in-memory recovery, Show tab restore, buried fakes, e2e assertions (hermetic) | high | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-13b.md` | `docs/progress-archive/13b.md` |
| 13c | Real runs and documents: `e2e-bury` through the coordinator, self-tests assert the buried tab, all `e2e-*` and self-tests real, docs | high | opus (code, real-run, documents and review-fix workers) | Codex, ship-with-fixes, `docs/reviews/phase-13c.md` | `docs/progress-archive/13c.md` |
| 14 | Popover readability: opaque popover, bounded host sections, per-row attach state, readable badge, muted unreachable host, footer spacing | routine | opus (impl + review-fix worker); one inline orchestrator edit | Codex, ship-with-fixes, `docs/reviews/phase-14.md` | `docs/progress-archive/14.md` |
| I-1a | Diagnose: `--report-popover-placement`, `PopoverPlacement` with tests, cause inferred (pre-fix frame unmeasured) | high | opus (impl + review-fix worker); orchestrator record edits | Codex, ship-with-fixes, `docs/reviews/phase-I-1a.md` | `docs/progress-archive/i-1a.md` |
| I-1b | Own `NSStatusItem` + non-activating `NSPanel` placed by `PopoverPlacement` (D30), anchor and toggle rules, press identity, height limit | high | opus (impl + review-fix worker); orchestrator record edits | Codex, ship-with-fixes, `docs/reviews/phase-I-1b.md` | `docs/progress-archive/i-1b.md` |
| I-2a | `directories.json` store (D31) with lock and refusal of unusable files, nonce-framed `path` probe record, recording on `onCreated`, in-memory store for self-tests | high | opus (impl + review-fix worker); real checks and records by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-2a.md` | `docs/progress-archive/i-2a.md` |
| I-2b | Directory list in New session (in-popover, ⌥↓/↑/↓/Return/Esc), Settings › Directories with a merging Save, galleries, docs | routine | opus (impl + review-fix worker); self-test and one test-harness fix by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-2b.md` | `docs/progress-archive/i-2b.md` |
| I-3a | Global shortcut: `GlobalShortcut`, `preferences.json` store, Carbon registrar, Settings › General recorder, `--report-hotkey-registration`, interim popover toggle (D32) | routine | opus (impl + review-fix worker); one checklist step by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-3a.md` | `docs/progress-archive/i-3a.md` |
| I-3b | Session switcher panel: 540 pt floating non-activating panel, live sessions with filter and New session row, Open / New session form, failure carry-over, combined engine visibility (D32, D22) | routine | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-I-3b.md` | `docs/progress-archive/i-3b.md` |
| I-4 | No empty "muxFinder Settings" window at launch: plain `NSApplication` with a hand-built main menu (D33), shell check lists every window (spec `autoclaude/processed/40-empty-settings-window-at-launch.md`) | routine | opus (impl worker); review fix inline by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-4.md` | `docs/progress-archive/i-4.md` |
| I-5 | Session switcher: one click activates a row, the rest of its click sequence dropped, the panel held through the double-click interval (D32 *Keys* edited; spec `autoclaude/processed/50-switcher-single-click-activates.md`) | routine | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-I-5.md` | `docs/progress-archive/i-5.md` |
| I-6 | New session: Tab moves from Name to Directory — panels recalculate their key view loop (native fix), read-only `--preview-key-view-loop` diagnostic (spec `autoclaude/processed/60-new-session-tab-between-fields.md`) | routine | opus (impl worker); review fix inline by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-6.md` | `docs/progress-archive/i-6.md` |
| I-7 | New session: typing in Directory filters the directory list — combo-box style, opens while something matches, "No matching directories", `~` rule on This Mac, match count announced (D31 edited; spec `autoclaude/processed/70-new-session-directory-list-filter.md`) | routine | opus (impl worker) | Codex, ship, `docs/reviews/phase-I-7.md` | `docs/progress-archive/i-7.md` |
| I-8 | New session: change the host from the keyboard — `PanelKeyRoute` leaves ↑/↓/⌥↓ to a focused pop-up button, every key to a tracking menu (D30–D32 edited; spec `autoclaude/processed/80-new-session-host-picker-keyboard.md`) | routine | opus (impl worker) | Codex, ship, `docs/reviews/phase-I-8.md` | `docs/progress-archive/i-8.md` |
| I-9a | New session window: the model and the window — one titled floating non-activating "New session" panel from the popover and the switcher, draft out of `panel`, failure after close brings it back (D34; D22, D25, D30–D33 edited; spec `autoclaude/processed/90-new-session-own-window.md`) | high | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-I-9a.md` | `docs/progress-archive/i-9a.md` |
| I-9b | New session window: the folder drop — pure `FolderDrop`, a drop view over the Directory row ahead of the field editor, `~/…` under This Mac's home, files/packages/several refused; `--preview-gallery new-session`, screenshots, checklist 23 (D34 extended) | routine | opus (impl worker) | Codex, ship, `docs/reviews/phase-I-9b.md` | `docs/progress-archive/i-9b.md` |
| I-10a | Folder search core: one static Spotlight script for This Mac and SSH hosts (header, folder-name queries on stdin, noise rule, 50 limit, 4 s host deadline, end records), escaping, bounded parser, streaming transport, channel state machine, scope in `preferences.json`, probe `folders`; real `--count-only` runs here and on Saturno (D36; D3, D11, D32 edited; spec `autoclaude/processed/100-folder-search-spotlight.md`) | high | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-I-10a.md` | `docs/progress-archive/i-10a.md` |
| I-10b | Folder search UI: "Folders on <host>" section in New session's directory list (states, de-dup, pick, `/` and <2 rules, unusable paths dropped), one channel per window and host, This Mac's `unchecked` script argument, Settings › Directories scope and "Missing a folder?", VoiceOver, galleries, checklist 24 (D3, D31, D32, D34, D36 edited) | routine | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-I-10b.md` | `docs/progress-archive/i-10b.md` |
| I-11a | Detach other clients, proof and core: `attach-session -d` rejected on real runs (iTerm2 reopens windows), per-client checked `detach-client`, `detachOtherClients(of:confirmation:)` with typed results and 10 s age guard, `tmuxCommandFailed` at the API boundary, `e2e-detach-others` 9/9 on both hosts (D37) | high | opus (impl + review-fix worker); orchestrator regression run and one `CLAUDE.md` edit | Codex, ship-with-fixes, `docs/reviews/phase-I-11a.md` | `docs/progress-archive/i-11a.md` |
| I-11b | Detach other clients, the UI: popover item and offer rule, in-popover confirmation, pending row, results through `SessionProblem`, refresh, row hint "also attached elsewhere", VoiceOver, galleries; switcher offers no "Try again" for popover-only confirmations (D25, D32, D37 edited) | routine | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-I-11b.md` | `docs/progress-archive/i-11b.md` |
| I-12a | Other terminals, proof and decision: `terminals list` (permission read without a prompt), `plain-proof` 9/9 on both hosts (pty-hosted plain clients, remote token identification, `attach-session -d` Move here, bound attach and detach), Terminal's command text, D38 and D3 extended; Terminal and Ghostty window runs owed (neither running) | high | opus (impl + review-fix worker); split, calls and safety rules by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12a.md` | `docs/progress-archive/i-12a.md` |
| I-12b1 | Other terminals, definitions: strict schema 1 (unknown and duplicate keys refused), loader under D19's rules with per-file problems, built-in Terminal and Ghostty definitions and scripts in `Resources/Terminals/` (bundled, signed), `shellText`/`words`/`exec` command forms, `NSAppleScript` handler runner seam, app facts without a prompt, `terminals list` extended; no built-in script compiled (D38 extended) | high | opus (impl + review-fix worker); split and calls by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12b1.md` | `docs/progress-archive/i-12b1.md` |
| I-12b2 | Other terminals, helper plain mode: `attach-plain` / `profile-plain` mode words, the request's `terminal` field (exit 72 cross refusals, `keepsMinimumLifetime` on plain requests only), the bound plain attach from `PlainLaunch` (stdin reopened read-write), no OSC 1337 / status report / bury, early report `<uuid>.report.json`, real pty test (D14, D38 extended; I-12b2 split from I-12b3) | high | opus (impl worker); split, calls and the review fix inline by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12b2.md` | `docs/progress-archive/i-12b2.md` |
| I-12b3 | Other terminals, terminal seam: `TerminalBackend` at the coordinator's session operations, `ITerm2TerminalBackend` wrapping `AttachCoordinator` unchanged, `PlainTerminalWindows` (facts gate, compile once, `muxfinder_open`/`focus`/`close`, `exec` spawn with a reaper, windows bound to their opening definition); nothing rewired (D38 extended) | high | opus (impl + review-fix worker); calls by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12b3.md` | `docs/progress-archive/i-12b3.md` |
| I-12c1 | Other terminals, the plain backend: `PlainTerminalBackend` conforming to `TerminalBackend` (plain request, open through the window layer, confirmation from the early report + `client_tty`/`client_pid`/start time or the remote token, bound tmux detach, move here and detach others, in-memory records), result types extended by new cases, `AttachSharedSteps` factored out; nothing rewired (D38 extended; I-12c split into c1–c3) | high | opus (impl + review-fix worker); split and calls by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12c1.md` | `docs/progress-archive/i-12c1.md` |
| I-12c2 | Other terminals, open on this Mac: discovery's nonce-framed `tty` record (`client_tty`, `client_created`), read-only process table and `LocalClientAttributor` (iTerm2 and its job server, definitions' apps, pid reuse refused, SSH never), per-session local attachments, optional refresh attributor, `.app` focus by activation, plain backend's attach focusing an attributed app, probe `local-clients`; nothing rewired (D38 extended) | high | opus (impl + review-fix worker); calls by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12c2.md` | `docs/progress-archive/i-12c2.md` |
| I-12c3a | Other terminals, onto the seam: `terminal` key in `preferences.json` with a typed resolution (default iTerm2 when installed, else Terminal; unavailable never replaced, `unresolved` until read), the app, Settings, onboarding, SSH setup and self-tests onto `TerminalBackend` (cached per terminal id), every iTerm2 contact gated on the choice, refresh attributor wired, plain-only `{`/`[`/`]` refusal, probe `attach --terminal` with a rule-8 gate rechecked at the side-effect boundary (D38, D32, D26 edited; I-12c3 split into c3a/c3b) | high | opus (impl + review-fix worker); split, calls and regression self-tests by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12c3a.md` | `docs/progress-archive/i-12c3a.md` |
| I-12c3b | Other terminals, the plain runs: `e2e-plain --terminal <id> --local \| --ssh saturno-m4` (rule-8 gate first and at every side-effect boundary, 9 steps through `PlainTerminalBackend`, cleanup closing windows only on positive evidence their helper ended), hermetic on a private tmux server, gate refusals real, plain real runs owed (neither app running), iTerm2's four `e2e-*` real as regression (D38 extended) | high | opus (impl and real-run worker, review-fix worker); calls by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12c3b.md` | `docs/progress-archive/i-12c3b.md` |
| I-12d1 | Other terminals, Settings, onboarding and SSH setup: the Terminal picker (permission states read without a prompt, off the main actor; unavailable choice kept; problems; "Check again" re-resolves), `TerminalWording`, SSH setup in a plain terminal (`PlainSSHSetupLauncher`), per-host persistent work command with Copy, onboarding without iTerm2, galleries (D38 extended; I-12d split into d1/d2) | routine | opus (impl + review-fix worker); split and calls by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12d1.md` | `docs/progress-archive/i-12d1.md` |
| I-12d2 | Other terminals, the popover, the switcher and the session states: every action, state and failure line through `TerminalWording` (iTerm2 unchanged), each plain error mapped exhaustively, "earlier launch pending" naming its holder, local attachments in another app, detach-others "Stopped after detaching N" / "Some may have been detached", "Detach (opened in <terminal>)" through that terminal's cached backend, galleries per terminal (D38 extended) | routine | opus (impl + review-fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-I-12d2.md` | `docs/progress-archive/i-12d2.md` |
| I-12e | Other terminals, the docs: `docs/TERMINALS.md` ("Adding a terminal" with a worked `exec` example that loads, later candidates, the Ghostty control-mode note), `docs/REQUIREMENTS.md` addendum, README, ARCHITECTURE, TESTING, MANUAL-CHECKLIST (item 29), `CLAUDE.md` corrected against the code; documents only | routine | opus (docs worker); review fix and two README corrections inline by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-12e.md` | `docs/progress-archive/i-12e.md` |
| I-13a | Update check, the check core: `UpdateVersion`, the bounded `releases/latest` parser, the transport and its `URLSession` implementation (hermetic, `URLProtocol` stub only), the 304 rule, `update-state.json`, the `checkForUpdatesAutomatically` toggle, the scheduler over an injected clock, probe `update check` (real run the user's); rule 3 now forbids any request to a server in a run (D39; I-13 split into a/b/c) | high | opus (impl + review-fix worker); split, calls and one TESTING count fix by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-13a.md` | `docs/progress-archive/i-13a.md` |
| I-13b1 | Install pipeline, download and verification: download with redirect allowlist, exact size and streaming SHA-256, zip pre-check before `ditto` and a watchdog during it, shape walk, Security.framework check (Developer ID, Team ID, `notarized` proven on the stapled 0.2.0 bundle), versions through the checked bundle, result bound to its device and inode, probe `update verify` real in zip mode (D39 extended; I-13b split into b1/b2) | high | opus (impl + review-fix worker); split, calls and one real zip-mode run by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-13b1.md` | `docs/progress-archive/i-13b1.md` |
| I-13b2 | Install pipeline, eligibility and install: eligibility from the running app's own signature (typed reasons), staging root `…/muxFinder/update/` with locked run folders, `RENAME_SWAP` bound by device and inode with re-check and both-identity rollback (`recoveryRequired`), detached relauncher (constant script), lock-first cleanup over a complete process scan, old helpers compatible, prepare/install/discard pipeline, `--report-update-eligibility` (D39 extended) | high | opus (impl + review-fix worker); calls and old-source copies by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-13b2.md` | `docs/progress-archive/i-13b2.md` |
| I-13c1 | Update UI, the notice: one pure mode gate (`createsUpdateMachinery`, normal launch only), scheduler wired (start, wake, toggle, manual check, stop), popover notice with "What's new", runtime dot in the template icon and its label, `markNoticeSeen` (publish after save), Settings › General "Updates" (toggle, button, status line), galleries and screenshots (D39 extended; I-13c split into c1/c2/c3) | high | opus (impl + review-fix worker); split, calls and verification by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-13c1.md` | `docs/progress-archive/i-13c1.md` |
| I-13c2a | Update UI, the update flow: `UpdateFlow` behind a pipeline seam (offer with eligibility per notice version, Update or Download, prepare with percent and Cancel, failure phrases, the ask before quitting over unsaved work, Not now / Install and relaunch, install, quit after `relaunchScheduled`, edits locked while installing, a quit never mid-swap), cleanup at launch in normal mode only; no visible change but the lock (D39 extended; I-13c2 split into c2a/c2b) | high | opus (impl + review-fix worker); split and calls by the orchestrator | Codex, ship-with-fixes, `docs/reviews/phase-I-13c2a.md` | `docs/progress-archive/i-13c2a.md` |

### Queued

| Phase | Title | Specification | Position |
|---|---|---|---|
| I-13c2b | Update UI, the update views (routine): the notice's Update / Download with the reason, "Downloading… 40%" with Cancel, "Checking the download…", "Installing…", "Couldn't update: <reason>" with the release page, the ask (attached tmux sessions not affected), Install and relaunch, VoiceOver, popover gallery states for every flow state, screenshots, checklist item | `PLAN.md` *Phase I-13* "I-13c2 split"; D39 "The update flow (I-13c2a)"; `autoclaude/processed/120-update-check-github.md` (*UI*) | next |
| I-13c3 | Update UI, the documents (routine): README, ARCHITECTURE, TESTING summary, MANUAL-CHECKLIST real update end to end, release contract on `CLAUDE.md`'s release line and in D35, D39's last "Not yet" | same | last |

**Inbox**: every triage through 2026-11-06 (items 40 to 120, item 99 deferred and then resolved
by the user) is logged verbatim in `docs/progress-archive/inbox-log.md`. The standing note on
GitHub requests was settled at I-13's selection (`PLAN.md` *Phase I-13* "The run rule": no run
sends a request to any server; the real GETs are the user's). 2026-11-07 01:37 (start of
I-13a's iteration): `list` empty. 2026-11-07 02:27 (start of I-13b1's iteration): `list`
empty. 2026-11-07 03:45 (start of I-13b2's iteration): `list` empty. 2026-11-07 05:33 (start
of I-13c1's iteration): `list` empty. 2026-11-07 06:17 (start of I-13c2a's iteration): `list`
empty. 2026-11-07 06:56 (record only, no phase): `list` empty. 2026-11-07 06:59 (I-13c2b's
calls only): `list` empty.

## Current phase

Phases 1–14, I-1 (a, b), I-2 (a, b), I-3 (a, b), I-4 to I-8, I-9 (a, b), I-10 (a, b) and
I-11 (a, b), I-12a and I-12b (b1, b2, b3) are complete and reviewed. The user released 0.2.0
(build 2) in `f1b11ac`. **Phase I-12 (other terminal apps) is split into I-12a–e**, and
**I-12b into I-12b1/I-12b2/I-12b3**, in `PLAN.md` *Phase I-12*; **I-12a** (proof and
decision), **I-12b1** (definitions, loader, AppleScript runner), **I-12b2** (helper plain
mode) and **I-12b3** (terminal seam) complete 2026-11-06
(`docs/progress-archive/{i-12a,i-12b1,i-12b2,i-12b3}.md`). **I-12c is split into
I-12c1/I-12c2/I-12c3**, and **I-12c3 into I-12c3a/I-12c3b**; **I-12c1** (the plain backend),
**I-12c2** (open on this Mac), **I-12c3a** (onto the seam) and **I-12c3b** (the plain runs)
complete 2026-11-06 (`docs/progress-archive/{i-12c1,i-12c2,i-12c3a,i-12c3b}.md`). **I-12d is
split into I-12d1/I-12d2**; **I-12d1** (Settings, onboarding, SSH setup) complete 2026-11-06
and **I-12d2** (popover, switcher, session states) complete 2026-11-07
(`docs/progress-archive/{i-12d1,i-12d2}.md`). **I-12e** (the docs) complete 2026-11-07
(`docs/progress-archive/i-12e.md`), so **Phase I-12 is complete**. **Phase I-13** (update
check) is split into **I-13a/I-13b/I-13c** in `PLAN.md` *Phase I-13*; **I-13a** (the check
core) complete 2026-11-07 (`docs/progress-archive/i-13a.md`). **I-13b is split into
I-13b1/I-13b2**; **I-13b1** (download and verification) and **I-13b2** (eligibility and
install) complete 2026-11-07 (`docs/progress-archive/{i-13b1,i-13b2}.md`). **I-13c is split
into I-13c1/I-13c2/I-13c3** (`PLAN.md` *Phase I-13* "I-13c split"); **I-13c1** (the notice)
complete 2026-11-07 (`docs/progress-archive/i-13c1.md`). **I-13c2 is split into
I-13c2a/I-13c2b** (`PLAN.md` "I-13c2 split"); **I-13c2a** (the update flow, model and wiring)
complete 2026-11-07 (`docs/progress-archive/i-13c2a.md`). **Next: I-13c2b** (the update
views; *Next action* 0), then I-13c3 (the documents), the last queued phase. **I-13c2b is
selected and its calls are written** (`PLAN.md` *Phase I-13* "The orchestrator's calls for
I-13c2b", 2026-11-07 07:01), but **no worker has run and no code changed**: the 2026-11-07
06:59 iteration began 24 min before the run's 24 h cap, too short for a worker, verification
and review, so it stopped after the calls. Its row is `in_progress` ("calls written, no
worker yet"). The 06:56 iteration before it moved the I-13 head lines to
`docs/progress-archive/head-i-13a-i-13c2a.md`.
Also remaining:
the manual checklist (the user's). Phase
13's settled design is **D29**; real facts in `PLAN.md` *Verified facts* "Phase 13a
spike" and "Phase 13c real runs". Earlier splits: 6 into 6a/6b, 7 into 7a/7b, 9 into 9a/9b, 10
into 10a/10b, 11 into 11a/11b/11c, 12 into 12a/12b, 13 into 13a/13b/13c, I-1 into I-1a/I-1b,
I-2 into I-2a/I-2b, I-3 into I-3a/I-3b, I-9 into I-9a/I-9b, I-10 into I-10a/I-10b, I-11 into
I-11a/I-11b, I-12 into I-12a–e.

## Acceptance

- Phases 1–12a: all criteria met, with the recorded deviations and the real runs owed to a
  person listed under *Open risks*; criteria and evidence in `docs/progress-archive/<phase>.md`.
- Phase 12b (the plan's acceptance bar): all criteria met on the final tree, 2026-10-23 — 680
  core + 159 UI tests, lint and a warnings-free build exit 0; clean-`build/` bundle signed
  (Apple Development, not notarized), `codesign --verify` exit 0; install-script check 35/35;
  `e2e-local` 16/16, `e2e-remote saturno-m4` 17/17, `e2e-profile --local` and `--ssh
  saturno-m4` 14/14 each, `--selftest attach-local` 6/6, `--selftest new-session-local` 5/5,
  keep-mode quit check (row 12) exit 0; every brief bullet in `docs/TESTING.md` mapped to
  evidence or to the manual checklist; nothing left behind, `profiles hashes` identical.
  `docs/progress-archive/12b.md`.
- Phases 13a–13c: all criteria met, 2026-10-24 (13a spike 12/12 on both hosts, D29; 13b
  hermetic; 13c real runs all PASS: `e2e-local` 16/16, `e2e-remote saturno-m4` 17/17,
  `e2e-bury` 13/13 on both hosts, self-tests 8/8 and 7/7, `e2e-profile --local` 14/14) —
  `docs/progress-archive/13{a,b,c}.md`.
- Phases 14–I-3b: all criteria met, 2026-10-24 (14 the popover's look; I-1a/I-1b placement,
  `--report-popover-placement` exit 0 after the fix; I-2a/I-2b directory list; I-3a
  `--report-hotkey-registration` 8/8; I-3b the switcher, 815 core + 324 UI tests); the real
  presses, clicks and keys owed (checklist 15–18) — `docs/progress-archive/{14,i-1a,i-1b,
  i-2a,i-2b,i-3a,i-3b}.md`.
- Phases I-4 to I-9a: all criteria met, 2026-11-04 to 2026-11-05 (I-9a: 815 core + 406 UI
  tests, `--selftest new-session-local` 7/7); real presses, clicks and windows owed
  (checklist 19–22) — verbatim in `docs/progress-archive/head-i-4-i-9a.md`.
- Phases I-9b, I-10a, I-10b: all criteria met, 2026-11-06 (I-9b the folder drop, real drags
  owed, checklist 23; I-10a folder search core, real `--count-only` runs on both hosts; I-10b
  folder search UI, 881 core + 468 UI, real Saturno search owed, checklist 24) —
  `docs/progress-archive/{i-9b,i-10a,i-10b}.md`.
- Phases I-11a to I-12c2: all criteria met, 2026-11-06 — verbatim in
  `docs/progress-archive/head-i-11a-i-12c2.md` and each phase's archive.
- Phases I-12c3a to I-12d1: all criteria met, 2026-11-06 — verbatim in
  `docs/progress-archive/head-i-12a-i-12d1.md` and each phase's archive.
- Phase I-12d2: all criteria met, 2026-11-07 — verbatim in
  `docs/progress-archive/head-i-12d2.md` and `i-12d2.md`.
- Phase I-12e: all criteria met, 2026-11-07 — verbatim in
  `docs/progress-archive/head-i-12e.md` and `i-12e.md`.
- Phases I-13a to I-13c2a: all criteria met, 2026-11-07 — verbatim in
  `docs/progress-archive/head-i-13a-i-13c2a.md` and each phase's archive.

## Decisions

- Phases 1–12b, one line each (details in `docs/progress-archive/<phase>.md` and `PLAN.md`
  *Decisions*): splits 3 → 3a/3b, 4 → 4a/4b/4c, 5 → 5a/5b, 6 → 6a/6b, 7 → 7a/7b, 9 → 9a/9b,
  10 → 10a/10b, 11 → 11a/11b/11c, 12 → 12a/12b, each recorded in `PLAN.md` before its first
  worker. New decisions: **D12** `tmux -u` everywhere; **D13** no automatic request retries;
  **D14** launch protocol, exit codes, 10 s hold; **D15** attach coordinator; **D16**
  attachment index; **D17** remote attach over ssh (5b); **D18** session creation (6a);
  **D19** `hosts.json` schema and safe publication (7a); **D20** refresh engine (7b); **D21**
  Move here (6b); **D22** menu bar app (8); **D23** Settings window (9a); **D24** onboarding and
  `ssh-setup` (9b); **D25** attach UX and self-tests (10a); **D26** persistent profiles
  (11a–11c, incl. iTerm2's `New Bookmarks` mirror handling); **D27** install / uninstall
  (12a). 10b and 12b changed no code: the orchestrator ran the real checks; the 9b "Set up SSH
  in iTerm2…" real round trip is owed to the user (interactive login outside the run rules).
- Phase 13 planning to I-9a: their decision lines moved verbatim to
  `docs/progress-archive/decisions-13-i-9a.md` (D29 to D34; the splits of 13, I-1, I-2, I-3
  and I-9).
- Phases I-9b, I-10 (split a/b, D36) and I-10b: the orchestrator's calls are in `PLAN.md`
  *Phase I-9* and *Phase I-10*, the workers' in their archives —
  `docs/progress-archive/{i-9b,i-10a,i-10b}.md`.
- Phases I-11 to I-12c2: their decision lines moved verbatim to
  `docs/progress-archive/head-i-11a-i-12c2.md` (D37, D38; the splits of I-11, I-12, I-12b,
  I-12c).
- Phases I-12c3a to I-12d1 (the I-12d split among them): their decision lines moved verbatim
  to `docs/progress-archive/head-i-12a-i-12d1.md`.
- Phase I-12d2: verbatim in `docs/progress-archive/head-i-12d2.md` (D38 "The UI (I-12d2)").
- Phase I-12e: verbatim in `docs/progress-archive/head-i-12e.md`.
- Phase I-13 (at selection) to I-13c2a: their decision lines (the splits of I-13, I-13b,
  I-13c and I-13c2; *Unattended-run rules* 3 tightened; D39) moved verbatim to
  `docs/progress-archive/head-i-13a-i-13c2a.md`.

## Open risks / deviations

- Phases 13–I-2a: their open risks and deviations moved verbatim to
  `docs/progress-archive/open-risks-13-i-2a.md` (iTerm2's auto-hide setting's "on" branch only
  proven by 13a's old harness; the real popover, its keys, focus and clicks unseen, checklist
  15–16; load-sensitive private-server tests; the race's dangerous order unforced).
- I-2b to I-9a: their open risks moved verbatim to
  `docs/progress-archive/open-risks-i-2b-i-9a.md` (real keys, clicks, presses, drags and
  windows unverified, checklist 15–23; load-sensitive private-server tests). The three
  `CLAUDE.md` notes owed there by I-4, I-6 and I-9a were applied by I-10a.
- I-9b, I-10a, I-10b: their open risks are in their archives (real drags, checklist 23; the
  I-10a scratch disk image, noted for the user; real Saturno search, This Mac's privacy prompt
  and VoiceOver, checklist 24) — `docs/progress-archive/{i-9b,i-10a,i-10b}.md`.
- I-11a (**for the user**): the review's blocker could only be narrowed (D37). Within one round
  trip between the check and `detach-client`, a checked client that switches sessions is
  detached from its new session, and one that ends makes `detach-client` fail, which on
  iTerm2 3.7.7 shows a "tmux Reported a Problem" alert and ends the kept attachment (read from
  iTerm2's source, not triggered for real). Nothing is killed. The review-fix worker's first
  private-server probe used `kill-server` on its own private socket (against the rule, nothing
  of the user's touched). The age guard can be shortened by a wall clock jump on the tmux
  host — `docs/progress-archive/i-11a.md`.
- I-11b: no real click, menu, key or VoiceOver check (checklist 25, with D37's residual race);
  the switcher's badge shows the hint too, unshown in its gallery; the implementation worker
  ran one read-only `git status --short`, against its brief — `docs/progress-archive/i-11b.md`.
- I-12a to I-12d1: their open risks moved verbatim to
  `docs/progress-archive/head-i-12a-i-12d1.md`. **For the user** there: the real Terminal and
  Ghostty window runs (I-12a), the four plain real runs `e2e-plain --terminal
  terminal|ghostty --local | --ssh saturno-m4` (I-12c3b; `docs/TESTING.md` *Phase I-12c3b,
  Owed*, checklist 26), the picker's real permission states, "Set up SSH" in Terminal and
  Ghostty and pasting the persistent work command (I-12d1, checklist 27); load-sensitive
  folder search / directory store timing tests that fail once under load.
- I-12d2 (**for the user**): real Open, Show window, Detach, Move here, Detach other clients
  and the permission / AppleScript-off lines in Terminal and Ghostty, checklist 28; Ghostty's
  AppleScript-off error numbers unverified — verbatim in `docs/progress-archive/head-i-12d2.md`.
- I-12e: verbatim in `docs/progress-archive/head-i-12e.md` (`terminals list --help` exits 64;
  TESTING's "Unit tests" row's old counts; checklist 29).
- I-13a to I-13c2a: their open risks moved verbatim to
  `docs/progress-archive/head-i-13a-i-13c2a.md`. **For the user** there: the real `update
  check` and `update verify --latest` (checklist 30); the real notice, dot, Settings line
  and toggle (checklist 31); the real update end to end on a Developer ID build (I-13c3's
  checklist). **Release numbering**: `v0.3.0` (build 3) came from branch `release/0.3.0`
  (`1c037ea`), not `main` (still 0.2.0 build 2), so the next release from `main` needs a
  build above 3 (D35). Flaky runs seen: one full `swift test` hang (killed),
  `panelRootIsNoTallerThanItsLimit` and `answersAndEndsAtEndOfInput` once each.

- **Deferred inbox item, resolved by the user**: `autoclaude/processed/99-release-publish-install.md`
  (release 0.2.0 build 2) was deferred because an inbox item cannot relax `CLAUDE.md`'s
  release, publish and install rules. The user released it themselves in `f1b11ac` ("Release
  0.2.0 (build 2)", 2026-11-06: version in `scripts/build-app.sh`, new **D35** version rule,
  `CLAUDE.md` publish note, `nonamedownloads.json` committed). Nothing is owed for it.

- Phases 1–12a: their open risks and deviations moved verbatim to
  `docs/progress-archive/open-risks-1-12a.md`. Standing hazards for any real run there: the
  **iTerm2 modal hazard** (a tab ending within 3 s blocks the API until a person clicks OK),
  the **iTerm2 API stall** at 64 workers and the **thread ratchet** (about 12 threads per real
  e2e run, slow decay) — the gate is in *Next action* 3; and `swift run muxfinder-probe` does
  not rebuild `muxfinder-launch` (run `swift build` first).

## Reviews

- Phases 1–7b: Codex reviewed each (`ship-with-fixes`); blockers and should-fix items and their
  fixes (each regression failing on the old code) are summarized in
  `docs/progress-archive/<phase>.md`, reports in `docs/reviews/phase-<phase>.md`.
- Phases 6b–10b: Codex reviewed each (6b, 8, 9a, 9b, 10a `ship-with-fixes`; 10b `ship`);
  every blocker and should-fix was fixed by a fix worker with a regression failing on the old
  code — summaries in `docs/progress-archive/<phase>.md`, reports in
  `docs/reviews/phase-<phase>.md`.
- Phases 11a–12a: Codex reviewed each (`ship-with-fixes`): 11a 1 blocker + 2 should-fix
  (installer rollback, `e2e-profile` cleanup, combining-mark guard), 11b 2 should-fix (mirror
  exclusion, absolute deadline), 11c 1 blocker + 1 should-fix (empty-document install on
  reload, recreating a removed file), 12a 3 blockers (mapped readers, test-root containment,
  deletion bound to the inspected folder). All fixed by a fix worker, each regression failing
  with its fix reverted, re-verified — summaries in `docs/progress-archive/<phase>.md`, reports
  in `docs/reviews/phase-<phase>.md`.
- Phase 12b: Codex → `ship`, 0 findings (record matches the run logs, all 13 bullets mapped,
  signing distinguished from notarization); `docs/reviews/phase-12b.md`.
- Phases 13a–13c: Codex wrote each file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`
  (13a 1 should-fix, 13b 1 blocker + 2 should-fix, 13c 2 should-fix); all fixed by review-fix
  workers with regressions failing on the old code, re-verified (13c with real reruns) —
  `docs/reviews/phase-13{a,b,c}.md`, summaries in `docs/progress-archive/13{a,b,c}.md`.
- Phases 14, I-1a, I-1b: Codex wrote each file (`autoclaude-review.sh`), all
  `ship-with-fixes`. 14: 1 should-fix ("attached, location unknown"). I-1a: 1 blocker
  (resolved by deferring the before-frame) + 2 should-fix. I-1b: 2 should-fix (hardware press
  count; `PopoverHeightLimit`). Review-fix workers fixed all of them, with regressions that
  fail on the old code — `docs/reviews/phase-{14,I-1a,I-1b}.md`.
- Phases I-2a, I-2b, I-3a, I-3b: Codex wrote each file (`autoclaude-review.sh`, 20 min), all
  `ship-with-fixes` (I-2a 3 should-fix, I-2b 1 blocker + 2 should-fix, I-3a 3 should-fix, I-3b
  4 should-fix). Review-fix workers fixed all of them, each regression failing with its fix
  reverted; re-verified by the orchestrator — `docs/reviews/phase-I-{2a,2b,3a,3b}.md`, summaries
  in `docs/progress-archive/i-{2a,2b,3a,3b}.md`.
- Phases I-4 to I-9a: Codex wrote each file (`autoclaude-review.sh`, 12–20 min): I-4, I-5,
  I-6 and I-9a `ship-with-fixes` (one should-fix each, all fixed and re-verified), I-7 and I-8
  `ship` — verbatim in `docs/progress-archive/head-i-4-i-9a.md`, reports in
  `docs/reviews/phase-I-{4,5,6,7,8,9a}.md`.
- Phases I-9b, I-10a, I-10b: Codex wrote each file (`autoclaude-review.sh`): I-9b `ship`; I-10a
  `ship-with-fixes` (1 blocker + 2 should-fix), I-10b `ship-with-fixes` (2 should-fix), all
  fixed with regressions failing on the old code — `docs/reviews/phase-I-{9b,10a,10b}.md`.
- Phases I-11a to I-12c2: Codex wrote each file, all `ship-with-fixes`, every finding fixed —
  verbatim in `docs/progress-archive/head-i-11a-i-12c2.md`.
- Phases I-12c3a to I-12d1: Codex wrote each file, all `ship-with-fixes`, every finding fixed —
  verbatim in `docs/progress-archive/head-i-12a-i-12d1.md`.
- Phase I-12d2: Codex → `ship-with-fixes`, 3 should-fix, all fixed — verbatim in
  `docs/progress-archive/head-i-12d2.md`, report `docs/reviews/phase-I-12d2.md`.
- Phase I-12e: Codex → `ship-with-fixes`, 1 should-fix, fixed — verbatim in
  `docs/progress-archive/head-i-12e.md`, report `docs/reviews/phase-I-12e.md`.
- Phases I-13a to I-13c2a: Codex wrote each file (`autoclaude-review.sh`), all
  `ship-with-fixes`, every finding fixed — verbatim in
  `docs/progress-archive/head-i-13a-i-13c2a.md`, reports `docs/reviews/phase-I-13{a,b1,b2,c1,c2a}.md`.

## Next action

0. **Phase I-13c2b (in progress, routine; calls written, no worker yet): the update views.**
   Poll the inbox first. The calls are already in `PLAN.md` *Phase I-13* ("The orchestrator's
   calls for I-13c2b"): re-read them with D39's "The notice (I-13c1)", "The update flow
   (I-13c2a)" and "Not yet" parts and the specification
   `autoclaude/processed/120-update-check-github.md` (*UI*), adjust them only if the code
   shows one is wrong (recording why), then write the acceptance criteria and spawn the
   worker. In short, render
   `UpdateModel.flow` (`Sources/MuxFinderUI/Model/UpdateFlow.swift`) in the popover notice
   (`Views/UpdateViews.swift`): **Update** or **Download** with the reason's phrase,
   "Downloading… 40%" (no percent without a total) with **Cancel**, "Checking the
   download…", "Installing…", "Couldn't update: <reason>" with the release page link and
   Update again, the ask naming what is unsaved with "Attached tmux sessions are not
   affected", **Quit and install** / **Not now**, then **Install and relaunch**; VoiceOver
   labels for every line and button; synthetic `UpdateFixture` states for each in the
   `popover` gallery (no pipeline); `docs/screenshots/popover-states-{light,dark}.png`
   regenerated with `--preview-snapshot`; `docs/MANUAL-CHECKLIST.md` gains the real Update,
   Download, Cancel, failure line and the ask; D39 and TESTING a Phase I-13c2b part. Real
   runs as in I-13c1's calls (galleries, the report flags on private homes); never
   `/usr/bin/open`, a real swap, `scripts/release.sh`, `install.sh`, a normal launch or a
   request to any server. Then **I-13c3** (routine, the documents; `PLAN.md` "I-13c split"),
   which also owes the real update end to end in the checklist. Release numbering:
   `v0.3.0` (build 3) came from `release/0.3.0`, so the next release from `main` needs a
   build above 3 (D35).
1. Owed to nobody now: the `CLAUDE.md` notes of I-4, I-6 and I-9a were applied by I-10a.
2. Owed to the user, not to a run: every item of `docs/MANUAL-CHECKLIST.md` (the 9b "Set up SSH
   in iTerm2…" round trip, a real install and uninstall, clicks in the real popover and
   Settings, Sirio, the LaunchServices Automation prompt, launch at login from
   `/Applications`, and the items *Open risks* lists).
3. If a later change calls for real runs again, the gate stands: `swift build` first, then
   `.build/debug/muxfinder-probe iterm2 status` (exit 0) and iTerm2's thread count read-only,
   `ps -M -p <pid> | wc -l` with the pid from `ps -axo pid,comm | rg 'MacOS/iTerm2$'`; real
   runs only at **38 threads or lower**, and leftover checks after each (launch directory,
   `DynamicProfiles/`, `/private/tmp` `mfx.*`, `muxfinder-test-*` sessions on Neptuno and
   Saturno; since 13a also no run session left in tabs or `buried_sessions` of
   `iterm2 list-sessions`). I-12c3b's `e2e-local` took iTerm2 from 23 to 44 threads, held for
   about 1 h 45 min before falling to 18 (2026-11-06); later runs left it at 16–20.

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`; overview: `docs/ARCHITECTURE.md`.
- Phases 1 to I-9b: their key paths moved verbatim to
  `docs/progress-archive/key-paths-1-i-9b.md`.
- Phases I-10a to I-12e: their key paths moved verbatim to
  `docs/progress-archive/key-paths-i-10a-i-12e.md` (folder search, detach other clients, other
  terminals).
- Phases I-13a to I-13b2 (check core, download and verification, eligibility and install):
  their key paths moved verbatim to `docs/progress-archive/head-i-13a-i-13c2a.md`.
- The notice (I-13c1, D39): `Sources/MuxFinderUI/Model/UpdateModel.swift`,
  `Sources/MuxFinderUI/Views/UpdateViews.swift`, `Sources/MuxFinderUI/Preview/UpdateFixtures.swift`,
  the gate `AppLaunchOptions.createsUpdateMachinery` and `AppEnvironment.update`, the dot in
  `Views/MenuBarIcon.swift`, `UpdateScheduler.markNoticeSeen(_:)`; tests
  `Tests/MuxFinderUITests/UpdateModelTests.swift`, `Tests/MuxFinderCoreTests/UpdateNoticeSeenTests.swift`.
- The update flow (I-13c2a, D39): `Sources/MuxFinderUI/Model/UpdateFlow.swift` (`UpdateFlow`,
  `UpdateFlowPipeline`; `UpdateModel.flow`), the unsaved-work source and edit lock in
  `AppModel.swift`, `AppModelNewSession.swift`, `SettingsModel.swift`,
  `SettingsModelDirectories.swift`, the quit wait in `Sources/MuxFinderApp/AppDelegate.swift`,
  pre-swap cancellation in `Sources/MuxFinderCore/Update/UpdateSwap.swift`; tests
  `Tests/MuxFinderUITests/UpdateFlowTests.swift`, `UpdateSwapTests`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/` (inbox log: `inbox-log.md`).

## Verification (latest; earlier phases' are in their archives)

- Phase I-13c2a (final tree, orchestrator, 2026-11-07): `swift build` exit 0 (no warnings);
  `swift format lint -r Sources Tests` exit 0; `env -u TMUX_TMPDIR swift test`: 587 UI tests
  in 58 suites + 1366 core tests in 152 suites passed; `scripts/build-app.sh` exit 0 and
  `codesign --verify --deep --strict build/muxFinder.app` exit 0; the real support folder
  unchanged, no `update` folder — `docs/progress-archive/i-13c2a.md`.
- Phases 1–I-13c1: each phase's final-tree verification is in
  `docs/progress-archive/<phase>.md`.

## Git state

- Phases 1 to I-12e: every commit, all pushed to `origin/main`, moved verbatim to
  `docs/progress-archive/git-state-1-i-12e.md` (the last, I-12e `3d47e6e`). Commit messages
  carry no AI attribution trailer (the user's global rule).
- Phase I-13a: `9d2f1f2`; Phase I-13b1: `177aea5`; Phase I-13b2: `53702db`; all pushed to
  `origin/main`.
- Phase I-13c1: `cd45b50`, pushed to `origin/main`.
- Phase I-13c2a: `3011bd6`, pushed to `origin/main` (`main...origin/main`, checked
  2026-11-07 06:57).
- 2026-11-07 06:56 iteration (record only, no phase): the tree was clean at start (empty
  preflight file). This checkpoint is committed on its own ("Checkpoint: …"), against the
  base file's leave-uncommitted rule for record-only iterations. The reason: the iteration's
  deadline is the run's 24 h cap, so no later iteration of this run would pick up an
  uncommitted checkpoint, and a new run would count it among the user's dirty paths. SHA and
  push result in the run's status line.
- 2026-11-07 06:59 iteration (I-13c2b's calls only, no code): the tree was clean at start
  (empty preflight file). It commits `PLAN.md`'s calls with this checkpoint and
  `PROGRESS.json` as "Plan: …", for the same reason as above (the run's 24 h cap is this
  iteration's deadline). SHA and push result in the run's status line.
