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

No phase is queued: every phase of `PLAN.md` is complete and reviewed.

## Current phase

Phases 1–14, I-1 (a, b), I-2 (a, b) and I-3 (a, b) are complete and reviewed. **Phase I-3b —
Switcher panel (routine): complete** 2026-10-24 (`docs/progress-archive/i-3b.md`; **D32**
extended, D22 and D30 edited). **The plan is finished**; what remains is the user's manual
checklist. Phase 13's settled design is **D29**; real facts in `PLAN.md` *Verified facts* "Phase 13a
spike" and "Phase 13c real runs". Earlier splits: 6 into 6a/6b, 7 into 7a/7b, 9 into 9a/9b, 10
into 10a/10b, 11 into 11a/11b/11c, 12 into 12a/12b, 13 into 13a/13b/13c, I-1 into I-1a/I-1b,
I-2 into I-2a/I-2b, I-3 into I-3a/I-3b.

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
- Phases 14, I-1a, I-1b: all criteria met, 2026-10-24. 14: the popover's look, with screenshots
  inspected and the real popover owed (checklist 15). I-1a: the placement diagnostic exits 4
  "not openable in process" on the old scene; the cause is inferred. I-1b: after the fix,
  `--report-popover-placement` exit 0 three times; keys and real clicks owed (checklist 16).
  Evidence in `docs/progress-archive/{14,i-1a,i-1b}.md`.
- Phases I-2a, I-2b, I-3a: all criteria met, 2026-10-24. I-2a: real `discover` on both hosts
  parsed every start folder, self-test 7/7 with no `directories.json`. I-2b: galleries
  inspected, install-script check 35/35, the real keys owed (checklist 17). I-3a:
  `--report-hotkey-registration` 8/8 in the signed bundle, uninstall removes
  `preferences.json`, a real press owed (checklist 18). Evidence in
  `docs/progress-archive/{i-2a,i-2b,i-3a}.md`.
- Phase I-3b: all criteria met, 2026-10-24 — content, keys, visibility-rule, carry-over and
  hotkey-glue tests pass (815 core + 324 UI tests; 32 new UI). Three I-3a tests that asserted
  the interim popover toggle now assert the switcher, and one `arrowsMoveWithoutWrapping` line
  follows review fix 1; no other test changed. The switcher gallery (9 states) was rendered
  light and dark and inspected. `--report-menu-bar-item` behaves as before; bundle and
  `codesign` exit 0. A press, the real panel, opening, creating and Esc are owed (checklist
  18) — `docs/progress-archive/i-3b.md`.

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
- Phase 13 planning: the user's uncommitted `PLAN.md`/`PROGRESS.md`/`PROGRESS.json` edits
  (listed in the runner's preflight file) were the plan for Phases 13 and 14; committed verbatim
  as `d03e146` before any phase work so the run could checkpoint. The preflight file still
  names those three paths; they are committed, and the tree was clean when 13b started.
- Phases 13a–13c: new **D29** (bury after confirmation and `.activated`, race closed by
  order, helper restore with DSR acknowledgment, buried-tab list in memory only, recovery 15 s
  after a clean result; `e2e-bury` through the coordinator; harness judgements in
  `Attach/LaunchTabChecks.swift`) — `docs/progress-archive/13{a,b,c}.md`.
- Phase 14: D22 gained a *Look* bullet (opaque fixed per-scheme palette in
  `Views/PopoverStyle.swift`, because the system window background resolves differently
  inside a real window; new `HostStatusLabel.Tone.muted` for `.unreachable` only; row state
  "attached, location unknown" whenever the iTerm2 attachment check did not work, so a row is
  "elsewhere" only on a working check). The app shell check runs under an empty
  `CFFIXED_USER_HOME` now that the user's real `hosts.json` exists (`CLAUDE.md` edited) —
  `docs/progress-archive/14.md`.
- Phase I-1: split into I-1a/I-1b in `PLAN.md` before the first worker. An in-process
  `performClick(_:)` on muxFinder's own button is not UI scripting (bounded: ≤ 3 s open, a few
  runs, never through `open`); SwiftUI private internals and synthesized mouse events stay out.
  So the current `MenuBarExtra` popover cannot be opened unattended: the before-frame is
  deferred for good, and I-1b must measure the after-frame through its own button action
  (exit 0). Recommended for I-1b (*Verified facts*): own `NSStatusItem` + `NSPanel`, anchored
  at the click point, snapping to the button's rect — `docs/progress-archive/i-1a.md`.
- Phase I-1b: new **D30** (own `NSStatusItem` + borderless non-activating `NSPanel`, because
  `MenuBarExtra` gives no position hook and its button takes no action; the anchor rule; the
  toggle rules with press identity by the hardware press count; `PopoverHeightLimit`; D22 and
  D28 edited). The SwiftUI `App` keeps only the main menu (empty `Settings` scene, its menu item
  removed) — `docs/progress-archive/i-1b.md`.
- Phase I-2: split into I-2a/I-2b in `PLAN.md` before the first worker. New **D31**
  (`directories.json` apart from `hosts.json`, under its own `directories.lock`; every mutation
  refuses an unusable file and leaves it untouched, the specification's "left as it is"; the
  `path` record framed by a per-run nonce passed as data; a path over 4,096 bytes printed
  empty by tmux and dropped; discovery's stdout cap sized to the parser's limit, stderr 1 MiB;
  recording on `onCreated` only; the self-tests' in-memory store). The lock and backup helpers
  moved into `PrivateStorage`, shared with `hosts.json` and `profiles.lock` —
  `docs/progress-archive/i-2a.md`.
- Phase I-2b: **D31** extended. The list is drawn inside the popover, not a `Menu`/`NSMenu`,
  so its keys go through `PopoverKey.openList` and `AppModel.handle(_:)` and the galleries can
  render it. Settings' Save is a three-way `mergeSaved` run by the store under its lock, and
  list rows compare byte for byte. `--preview-snapshot` fits the window to its content first.
  Step 26 of the install-script check matches the readers' pids — `docs/progress-archive/i-2b.md`.
- Phase I-3: split into I-3a/I-3b in `PLAN.md` before the first worker, with three calls:
  `--report-hotkey-registration` allowed (own-process Carbon registration posts no event, so it
  is not UI scripting; bounded); the shortcut in `preferences.json` under the support folder,
  not the defaults domain (`CLAUDE.md`'s ownership rule, hermetic tests, `CFFIXED_USER_HOME`);
  the recorder applies at once. New **D32** (I-3a part): ⌥-only shortcuts warn instead of being
  refused, since macOS 27.2 registered them; a failed unregistration keeps the hotkey and its
  handle; an unusable file found by a save turns the hotkey off with "Try again" —
  `docs/progress-archive/i-3a.md`.
- Phase I-3b: **D32** extended. The switcher reuses the popover's `PopoverPanelWindow` at the
  floating level: 540 pt wide, centered on the display with the focus, top 18 % down. The
  popover's panel host, observers and key view are shared, not copied. The popover reports a
  new visibility before its panel shows, so a swap is never a close to the engine. The interim
  popover toggle is removed, and `.shortcut` became `.switcherOpened`. D22's visibility rule
  and D30 are edited — `docs/progress-archive/i-3b.md`.

## Open risks / deviations

- Phases 13–I-2a: their open risks and deviations moved verbatim to
  `docs/progress-archive/open-risks-13-i-2a.md` (iTerm2's auto-hide setting's "on" branch only
  proven by 13a's old harness; the real popover, its keys, focus and clicks unseen, checklist
  15–16; load-sensitive private-server tests; the race's dangerous order unforced).
- I-2b: the list highlight drops on a field edit, not on a click back into the field.
  `NewSessionDraft.directory`'s observer still compares with `String ==`. Real keys in the
  non-activating panel and creating from each source are unverified (checklist 17). The full
  `swift test` fails in private-tmux-server suites under extreme machine load (~500, another
  project's simulator run). Install-script step 35 can fail while the user's installed app
  writes its `launch/` folder — `docs/progress-archive/i-2b.md`.
- I-3a: no key was pressed, so whether a real press fires the Carbon handler (dispatcher
  target, registration on the application target) and whether macOS 27.2 delivers ⌥-only
  shortcuts are checklist 18's. The flag briefly registers the plain-letter ⌥J and ⌥⇧J
  system-wide. Leaving the General tab mid-recording is tested in the model only. The
  uninstall dry-run text does not name `preferences.json` — `docs/progress-archive/i-3a.md`.
- I-3b: no press and no real panel (checklist 18). A press on another display's copy of the
  status item, when its outside close comes first, still sends a closed/opened pair. A creation
  failure that comes during an unconfirmed Move here closes that confirmation when the switcher
  opens. "Detach from this Mac" on a pinned row whose host is gone does nothing. Beyond the spec:
  a key-hint footer — `docs/progress-archive/i-3b.md`.

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
- Phase I-2a: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 3 should-fix (recording replaced an unusable file; concurrent writers lost
  updates; path records could overflow the 1 MiB discovery cap), fixed by a review-fix worker
  (refusal, `directories.lock`, producer bound and cap) with regressions failing on the old
  code, re-verified by the orchestrator with real reruns — `docs/reviews/phase-I-2a.md`.
- Phase I-2b: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 1
  blocker (Settings Save overwrote picker additions made meanwhile) + 2 should-fix (Return on
  a stale highlight after a field edit; Unicode spellings collapsed in list identity). A
  review-fix worker fixed all three (`mergeSaved` under the store's lock; the highlight
  dropped on edit; byte identity), each with regressions failing with the fix reverted;
  re-verified by the orchestrator — `docs/reviews/phase-I-2b.md`.
- Phase I-3a: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 3 should-fix (a failed unregistration lost its handle; an unusable file found by a
  save blocked recovery; leaving General kept recording). A review-fix worker fixed all three,
  each regression failing with its fix reverted; re-verified by the orchestrator —
  `docs/reviews/phase-I-3a.md`.
- Phase I-3b: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 4 should-fix: a refresh moved the automatic selection; a pinned row the engine did
  not list could not be retried; a creation failure during Move here was dropped; a status-item
  handoff sent a closed/opened pair. A review-fix worker fixed all four, each regression failing
  with its fix reverted; re-verified by the orchestrator — `docs/reviews/phase-I-3b.md`.

## Next action

1. **None for a run: the plan is finished.** A new iteration polls the inbox
   (`~/.claude/scripts/autoclaude-inbox.sh list`). If an item is there it is triaged into a new
   phase; if not, it confirms `DONE`.
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
   `iterm2 list-sessions`). iTerm2 was at 19 threads after I-2b's self-test (2026-10-24 ~18:45).

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`.
- Core library:
  `Sources/MuxFinderCore/{Process,Shell,Config,Diagnostics,Tmux,ITerm2,Launch,Attach,Concurrency}/`.
- Launch helper: `Sources/muxfinder-launch/` (`muxfinder-launch attach <uuid>`); remote argv
  and D3 string: `Sources/MuxFinderCore/Launch/RemoteLaunch.swift` (D17).
- Attachment index: `Sources/MuxFinderCore/Attach/AttachmentIndex.swift` (D16).
- Refresh engine: `Sources/MuxFinderCore/Refresh/` (`RefreshCoordinator`, `HostSnapshot`,
  `RefreshSystemEvents`; D20); host list: `Sources/MuxFinderCore/Config/` (D19).
- New session directories (D31, I-2a): `Sources/MuxFinderCore/Config/{DirectoryLists,
  DirectoryStore}.swift`, path record in `Tmux/{ProbeScript,ProbeReport}.swift`, recording in
  `Sources/MuxFinderUI/Model/AppModelSessions.swift`; tests
  `Tests/MuxFinderCoreTests/{DirectoryStore,ProbeSessionPath}Tests.swift`,
  `Tests/MuxFinderUITests/DirectoryRecordingTests.swift`. Picker and Settings tab (I-2b):
  `Sources/MuxFinderUI/Model/{DirectoryPicker,AppModelDirectories,SettingsModelDirectories}.swift`,
  `Views/{DirectoryPickerViews,Settings/DirectoriesSettingsView}.swift`; tests
  `Tests/MuxFinderUITests/{DirectoryPicker,SettingsDirectories}Tests.swift`.
- Session creation: `Sources/MuxFinderCore/Tmux/TmuxCommands.swift`, `Tmux/CreatedSession.swift`
  (D18); `createAndAttach` in `Attach/AttachCoordinator.swift`; probe
  `Sources/muxfinder-probe/NewSessionCommand.swift`.
- Move here (D21): `moveHere(_:confirmation:)` in `Attach/AttachCoordinator.swift`,
  `MoveHereConfirmation` in `Attach/AttachModels.swift`, `moveHereScript` in
  `Launch/RemoteLaunch.swift`; e2e plain control client `Sources/muxfinder-probe/E2EControlClient.swift`.
- Menu bar app (D22): `Sources/MuxFinderUI/` (`Model/AppModel.swift`, `PopoverContent.swift`,
  `Views/`, `Preview/PreviewFixtures.swift`), `Sources/MuxFinderApp/` (entry point, app
  delegates); tests `Tests/MuxFinderUITests/`; bundle script `scripts/build-app.sh` →
  `build/muxFinder.app`; screenshots `docs/screenshots/`.
- Settings window (D23): `Sources/MuxFinderUI/Model/{SettingsModel,SettingsEnvironment,
  HostDraft,SettingsResults,LoginItem,FixIt,DiagnosticsReport}.swift`, `Views/Settings/`
  (`SettingsWindowController`), `Preview/{SettingsFixtures,SettingsGallery}.swift`; tests
  `Tests/MuxFinderUITests/{HostEditorTests,SettingsGeneralTests}.swift`.
- Onboarding and SSH setup (D24): `Sources/MuxFinderUI/Model/{OnboardingModel,
  SSHSetupActions}.swift`, `Views/Onboarding/`, `Preview/Onboarding{Fixtures,Gallery}.swift`;
  `Sources/MuxFinderCore/Launch/SSHSetup.swift`, `Attach/{LaunchTab,SSHSetupLauncher}.swift`;
  probe `Sources/muxfinder-probe/SSHSetupCommand.swift`; tests
  `Tests/MuxFinderCoreTests/SSHSetupTests.swift`, `Tests/MuxFinderUITests/OnboardingTests.swift`.
- Attach UX (D25): `Sources/MuxFinderUI/Model/{AppModelSessions,SessionProblem,
  SessionPanels}.swift`, `Views/SessionPanelViews.swift`, `Preview/Attach{Fixtures,
  Gallery}.swift`; self-tests `Sources/MuxFinderUI/SelfTest/{SelfTestDriver,
  SelfTestSeams}.swift`, `Sources/MuxFinderApp/SelfTestAppDelegate.swift`; tests
  `Tests/MuxFinderUITests/{AttachFlowTests,SelfTestDriverTests}.swift`.
- Persistent profiles (D26): `Sources/MuxFinderCore/Profiles/{PersistentProfiles,
  PersistentProfileInstaller,ITerm2ProfileSnapshot,PersistentProfileRun}.swift`, helper mode
  `Sources/MuxFinderCore/Launch/{ProfileLaunch,LaunchHelperProfile,LoginShell}.swift`, probe
  `Sources/muxfinder-probe/{ProfilesCommand,E2EProfileCommand}.swift`; golden files
  `Tests/MuxFinderCoreTests/Fixtures/profiles/`. Settings side (11c):
  `Sources/MuxFinderUI/Model/{PersistentProfileFiles,PersistentProfilesContent,
  SettingsModelProfiles}.swift`, `Views/Settings/ProfilesSettingsView.swift`; tests
  `Tests/MuxFinderUITests/PersistentProfilesSettingsTests.swift`.
- Probe CLI: `Sources/muxfinder-probe/` (`discover`, `iterm2 status | list-sessions |
  list-connections | list-profiles | attachments`, `attach --local|--ssh <dest> --session`,
  `detach --connection --gateway`, `e2e-local`, `e2e-remote <dest>`, `hosts show |
  suggestions`, `refresh --once`; shared harness
  `E2ERun.swift`).
- Launch tab bury (D29, 13a): client `Sources/MuxFinderCore/ITerm2/ITerm2Property.swift`
  (`setBuried`, `buryLaunchTab`, `sessionProperty`); helper restore
  `Sources/MuxFinderCore/Launch/{TerminalStatusRequest,NonBlockingTerminal,
  TerminalReturnReader}.swift` and `LaunchHelper.swift`; spike harness
  `Sources/muxfinder-probe/E2EBury{Command,Run,Support}.swift` (`e2e-bury --local | --ssh
  saturno-m4`); tests `Tests/MuxFinderCoreTests/LaunchTabRestoreTests.swift`.
- Coordinator bury and recovery (D29, 13b): `Sources/MuxFinderCore/Attach/
  AttachCoordinatorBurial.swift` (step 10, race check, buried-tab watch, `BuriedTabTimer`),
  `AttachResult.burial` / `LaunchTabBurial` in `Attach/AttachModels.swift`,
  `LaunchRequestStore.peekResult` in `Launch/LaunchStore.swift`, e2e recorder
  `Sources/MuxFinderCore/ITerm2/RecordingITerm2Integration.swift`; tests
  `Tests/MuxFinderCoreTests/{LaunchTabBurialTests,RecordingITerm2IntegrationTests}.swift`.
  13c harness judgements: `Sources/MuxFinderCore/Attach/LaunchTabChecks.swift`
  (`BuryRaceOutcome`, `KilledLaunchTabWatch`, `GatewayPlace`), tests `LaunchTabChecksTests`;
  shared "left by itself" check `checkLaunchTabLeft` in `Sources/muxfinder-probe/E2ESupport.swift`.
- Popover placement (I-1a): `Sources/MuxFinderUI/Model/{PopoverPlacement,
  PopoverWindowIdentification,NonblockingLineWriter}.swift`, diagnostic
  `Sources/MuxFinderApp/PopoverPlacement{Report,Inspection}.swift`; tests
  `Tests/MuxFinderUITests/{PopoverPlacement,PopoverWindowIdentification,
  NonblockingLineWriter}Tests.swift`.
- Menu bar item and popover panel (D30, I-1b): `Sources/MuxFinderUI/Model/{PopoverAnchoring,
  PopoverController}.swift`, `Views/{MenuBarPopover,MenuBarIcon}.swift` (`PopoverHeightLimit`
  in `MenuBarPopover.swift`); tests `Tests/MuxFinderUITests/{PopoverAnchoring,
  PopoverController,PopoverHeightLimit}Tests.swift`.
- Popover look (D22 *Look*, 14): palette, contrast helpers and state marks
  `Sources/MuxFinderUI/Views/PopoverStyle.swift`; row-state mapping in
  `Model/PopoverContent.swift`; tests `Tests/MuxFinderUITests/{PopoverStyleTests,
  PopoverContentTests}.swift`.
- Integration proof (local and over SSH, final): `docs/INTEGRATION-PROOF.md`.
- Packaging (D27): `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/lib/app-copies.sh`,
  hermetic check `scripts/dev/test-install-scripts.sh`; app flag `--remove-persistent-profiles`
  (`Sources/MuxFinderCore/Profiles/PersistentProfileRemoval.swift`). User docs: `README.md`,
  `docs/ARCHITECTURE.md`, `docs/MANUAL-CHECKLIST.md`, matrix at the top of `docs/TESTING.md`.
- Global shortcut (D32, I-3a): `Sources/MuxFinderCore/Config/{GlobalShortcut,
  PreferencesStore}.swift`, `Sources/MuxFinderUI/Model/{GlobalShortcutLabel,HotkeyRegistrar,
  GlobalShortcutModel}.swift`, `Views/Settings/ShortcutRecorderView.swift`, flag
  `Sources/MuxFinderApp/HotkeyRegistrationReport.swift`; tests
  `Tests/MuxFinderCoreTests/{GlobalShortcut,PreferencesStore}Tests.swift`,
  `Tests/MuxFinderUITests/{GlobalShortcutModel,GlobalShortcutApp}Tests.swift`.
- Session switcher (D32, I-3b): `Sources/MuxFinderUI/Model/{SwitcherContent,SwitcherController,
  AppModelSwitcher}.swift`, `Views/{SwitcherView,SessionSwitcher}.swift`, gallery
  `Preview/Switcher{Fixtures,Gallery}.swift` (`--preview-gallery switcher`,
  `docs/screenshots/switcher-states-*.png`); tests
  `Tests/MuxFinderUITests/{SwitcherContent,SwitcherController,SwitcherModel}Tests.swift`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (latest; earlier phases' are in their archives)

- Phase I-3b (final tree, orchestrator, 2026-10-24): `swift build` exit 0, no warnings;
  `swift test` 815 core tests in 81 suites + 324 UI tests in 30 suites passed; `swift format
  lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0, `codesign --verify --deep
  --strict build/muxFinder.app` exit 0; `--report-menu-bar-item` (empty `CFFIXED_USER_HOME`)
  SIGTERM exit 0, no child, private home empty — `docs/progress-archive/i-3b.md`.
- Phases 1–I-3a: each phase's final-tree verification is in `docs/progress-archive/<phase>.md`.

## Git state

- All phases through 10b are committed and pushed to `origin/main`: 1 `bb086c9`, 2 `c1ee43d`,
  3a `745e36e`, 3b `0d3b65f`, 4a `1f5a3be`, 4b `f888a2c`, 4c `e631641`, 5a `5b47e14`, 5b
  `6b1aedc` + `dca1228`, 6a `0210999` + `e0fcbdd`, 7a `228f8da`, 7b `d512f47`, 6b `ce26808`
  (closure `cb855c0`, summary `880470f`), 8 `dc1935d`, 9a `ac1b9ee`, 9b `94cc960`, 10a
  `d6fe103`, 10b `ec402ce` (pushed; `origin/main` at `ec402ce` before Phase 11a). From 3b on,
  commit messages carry no AI attribution trailer (user's global rule).
- Phase 11a: `289b7f4`, pushed (`origin/main` at `289b7f4` before Phase 11b).
- Phase 11b: `a5ca9e0`, pushed (`origin/main` at `a5ca9e0` before Phase 11c).
- Phase 11c: `930994e`, pushed (`origin/main` at `930994e` before Phase 12a).
- Phase 12a: `520b7e3`, pushed (`origin/main` at `520b7e3` before Phase 12b).
- Phase 12b: `6f56399`, pushed; then `92e354a` (app icon, menu bar icon, notarized release
  flow), pushed.
- Phase 13 planning (the user's edits, verbatim): `d03e146`, pushed.
- Phase 13a: `0284b84`, pushed (`origin/main` at `0284b84` before Phase 13b).
- Phase 13b: `c3e2948`, pushed. Inbox triage (I-1, I-2): `bd9aed6`.
- Phase 13c: `d5955ff`, pushed. Inbox triage (I-3): `2fdfc87`; phase summary `a9532fa`.
- Phase 14: `6750a1b`, pushed.
- Phase I-1a: `72e635a`, pushed.
- Phase I-1b: `adf79ec`, pushed (`origin/main` at `adf79ec` before Phase I-2a).
- Phase I-2a: `3feab0e`, pushed (`origin/main` at `3feab0e` before Phase I-2b).
- Phase I-2b: `e36e471`, pushed (`origin/main` at `e36e471` before Phase I-3a).
- Phase I-3a: `29bb362`, pushed (`origin/main` at `29bb362` before Phase I-3b).
- Phase I-3b: the commit after `29bb362` (switcher, review fixes, gallery, docs, review, archive
  and checkpoint); its SHA and push result are in the run's final status line.
- The runner's preflight file still names `PLAN.md`, `PROGRESS.json` and `PROGRESS.md` (the
  user's Phase 13 edits, committed as `d03e146`); the tree was clean when I-3b started.
