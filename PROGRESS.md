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

### Queued

| Phase | Title | Specification | Position |
|---|---|---|---|
| I-10 | New session: search the host's folders by name (Spotlight over noninteractive SSH, live as you type; "Folders on <host>" section, home/whole-disk setting, "Missing a folder?") — high, to be split I-10a (core: remote script, channel, escaping, parsing, probe `folders`) and I-10b (UI: section, setting, explanation, galleries) | `autoclaude/processed/100-folder-search-spotlight.md` | next (nothing else queued) |

**Inbox**: 2026-11-04 17:12, one item triaged, `40-empty-settings-window-at-launch.md` →
queued as I-4 (triage commit `3804a78`), now complete. 2026-11-04 17:47 (after I-4's commit),
two items triaged: `50-switcher-single-click-activates.md` → I-5,
`60-new-session-tab-between-fields.md` → I-6, both queued, routine as proposed, now complete.
2026-11-04 19:03 (start of the iteration after I-6's commit), one item triaged:
`70-new-session-directory-list-filter.md` → I-7, queued, routine as proposed (no instruction
to the run in it; its user decisions are recorded in the item itself), now complete.
2026-11-04 19:05 (I-7's iteration, before selection): `list` empty. 2026-11-05 22:01 (start of
the iteration), one item triaged: `80-new-session-host-picker-keyboard.md` → I-8, queued,
routine as proposed (no instruction to the run in it; its user decision, follow macOS's
keyboard navigation setting, is recorded in the item; triage commit `f9e2b04`), now complete.
2026-11-05 22:31 (after I-8's commit), two items triaged: `90-new-session-own-window.md` →
I-9, queued, high as proposed (no instruction to the run in it); `99-release-publish-install.md`
→ **deferred**, needs the user (*Open risks*). 2026-11-05 23:37 (I-9b's iteration, before
selection): `list` empty; after I-9b's review `count` 0. 2026-11-06 07:25 (start of the
iteration), one item triaged: `100-folder-search-spotlight.md` → I-10, queued, high as
proposed (no instruction to the run in it; its user decisions, and the user's own 2026-11-06
edit of PLAN.md rule 3 and `CLAUDE.md` allowing read-only Spotlight queries on Saturno and this
Mac, are recorded in the item and in commit `f1b11ac`).

## Current phase

Phases 1–14, I-1 (a, b), I-2 (a, b), I-3 (a, b), I-4 to I-8 and I-9 (a, b) are complete and
reviewed. **Phase I-9b — New session window: the folder drop, galleries and docs (routine):
complete** 2026-11-06 (`docs/progress-archive/i-9b.md`; D34 extended). The user released
0.2.0 (build 2) in `f1b11ac`. **Queued: I-10** (folder search, from the inbox; *Next action*
0). Also remaining: the manual checklist (the user's) and the three `CLAUDE.md` notes owed
(*Open risks*). Phase 13's settled design is **D29**; real facts in `PLAN.md` *Verified facts* "Phase 13a
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
- Phases 14–I-3b: all criteria met, 2026-10-24 (14 the popover's look; I-1a/I-1b placement,
  `--report-popover-placement` exit 0 after the fix; I-2a/I-2b directory list; I-3a
  `--report-hotkey-registration` 8/8; I-3b the switcher, 815 core + 324 UI tests); the real
  presses, clicks and keys owed (checklist 15–18) — `docs/progress-archive/{14,i-1a,i-1b,
  i-2a,i-2b,i-3a,i-3b}.md`.
- Phases I-4 to I-9a: all criteria met, 2026-11-04 to 2026-11-05 (I-9a: 815 core + 406 UI
  tests, `--selftest new-session-local` 7/7); real presses, clicks and windows owed
  (checklist 19–22) — verbatim in `docs/progress-archive/head-i-4-i-9a.md`.
- Phase I-9b: all criteria met, 2026-11-06 — `FolderDrop.outcome(for:home:)` with the
  specification's cases and more (package, sibling prefix, zero items, non-file URL, trailing
  slash); the fill closes the list without reopening it; 25 new UI tests, 2 changed (recorded
  in `docs/TESTING.md` *Phase I-9b*; 815 core + 431 UI pass); `--preview-gallery new-session`
  13 states incl. the 7 required, light and dark, inspected; attach and switcher screenshots
  regenerated; checklist 23 new, 17, 18, 20–22 updated; real drags owed (checklist 23) —
  `docs/progress-archive/i-9b.md`.

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
- Phases I-4 to I-9: new **D33** (I-4, plain `NSApplication`) and **D34** (I-9a, the New
  session window); D30–D32 edited by I-5 to I-8; I-9 split into I-9a/I-9b with the
  orchestrator's calls in `PLAN.md` *Phase I-9* — verbatim in
  `docs/progress-archive/head-i-4-i-9a.md`.
- Phase I-9b: the orchestrator's calls in `PLAN.md` *Phase I-9* ("calls for I-9b"): the drop
  target is the Directory row only (the user's "onto Directory"); one non-package folder URL,
  everything else refused with no "+"; the path as dropped, `~` by whole components; the fill
  a pick. The worker's route: an invisible AppKit drop view in front of the field and its
  field editor, registered for every type the field editor takes, clicks passing through. The
  switcher's `formFiltered`/`formNoMatches` fixtures retired as duplicates of the window's
  states. `docs/REQUIREMENTS.md` left as it is (the verbatim brief, never inline) —
  `docs/progress-archive/i-9b.md`.

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
- I-4: **`CLAUDE.md` note owed** — once the user has committed their own `CLAUDE.md` edit, its
  `--report-menu-bar-item` note should say the check also prints every other window, the
  launch event and the main menu, and that only onboarding may be visible (exact wording in
  `docs/progress-archive/i-4.md`). Real Finder/login launches and the Edit shortcuts in the real
  panels are checklist 19. A closed stdout still raises `SIGPIPE` in the shell check (as
  before; not ignored, since children would inherit it). One worker run named a nonexistent
  `CFFIXED_USER_HOME`; nothing real was read or written — `docs/progress-archive/i-4.md`.
- I-5: a real double click (long and short lists, a session already open here) is checklist
  18's. A ⌘-Tab right after an activating click leaves the switcher up for the rest of the
  double-click interval. The popover's panel carries the unused `minimumContentHeight` —
  `docs/progress-archive/i-5.md`.
- I-6: real Tab presses are checklist 20's. **Second `CLAUDE.md` note owed**: its
  `--preview-fixtures` paragraph should say `--preview-key-view-loop popover|switcher` shows a
  real panel and makes it key for ~10 s (exits 0/1/2/3) — wording in
  `docs/progress-archive/i-6.md`. The stalled-pipe case of the review fix was not run.
- I-7: a button-opened list with text in the field shows only the matches (the spec's pure
  rule). "Sessions on <host>" is capped at 10 before filtering. VoiceOver says nothing on a host
  change and was never on in a check; real typing, keys and VoiceOver are checklist 21's —
  `docs/progress-archive/i-7.md`.
- I-8: what ↑/↓ and ⌥↓ do on a closed picker, whether the menu's tracking notifications fire
  for it in the non-activating panel, and VO-Space are unverified until a real press
  (checklist 22). Tests pick a host through the picker's binding, not the real menu (SwiftUI
  builds no pop-up button in a never-shown panel) — `docs/progress-archive/i-8.md`.
- I-9a: no real window shown, moved, typed into or dragged (floating, Spaces, full screen, key
  without activation, ⌘W, height growth: I-9b's checklist item). ⌘R/⌘F in the window beep;
  ⌘N is swallowed. The committed attach and switcher screenshots show the inline form until
  I-9b. One first `swift test` run had 1 core-suite issue (core untouched), not reproduced in
  three reruns. A **third `CLAUDE.md` note owed**: the `--preview-fixtures` paragraph should
  add `--preview-gallery new-session` (every New session window state) to its gallery list
  and `new-session-states-*.png` to its screenshot list (made concrete by I-9b) —
  `docs/progress-archive/i-9a.md`, `i-9b.md`.
- I-9b: no real drag was made; that the drop view gets drags ahead of the field editor in the
  real window rests on one throwaway probe of the worker's (deleted; the shipped code uses no
  private API) — checklist 23. The popover gallery's committed screenshot predates I-6 (32 px
  shorter than it renders now; not regenerated, I-9 did not change it). The worker ran one
  read-only `git log`, against its brief — `docs/progress-archive/i-9b.md`.

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
- Phase I-9b: Codex wrote the file (`autoclaude-review.sh`, 15 min) → `ship`, 0 findings (not
  verified: checklist 23's real drags, click-through, keys and VoiceOver while Directory is
  being edited) — `docs/reviews/phase-I-9b.md`.

## Next action

0. **Phase I-10 (queued, high).** Split it into I-10a (core) and I-10b (UI) in `PLAN.md`
   before the first worker, with the next free decision number (D36; D35 is the user's
   version rule), then run I-10a. Specification: `autoclaude/processed/100-folder-search-spotlight.md`.
1. The `CLAUDE.md` notes I-4, I-6 and I-9a owe (*Open risks*) can now be applied:
   `CLAUDE.md` holds no uncommitted edit of the user's since `f1b11ac`.
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
   `iterm2 list-sessions`). iTerm2 was at 20 threads after I-9a's self-test (2026-11-05 ~23:15).

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
  One click (I-5): `clickSwitcherItem(_:)` and `SwitcherClickSequence` in
  `Model/AppModelSwitcher.swift`, the mouse monitor in `Views/SessionSwitcher.swift`,
  `holdForClick()` in `Model/SwitcherController.swift`; tests
  `Tests/MuxFinderUITests/SwitcherClickTests.swift`.
- App shell (D33, I-4): main menu `Sources/MuxFinderUI/Views/MainMenu.swift`, shell report
  `Sources/MuxFinderUI/Model/AppShellReport.swift`, entry `Sources/MuxFinderApp/{MuxFinderMenuBarApp,
  AppDelegate}.swift`; tests `Tests/MuxFinderUITests/{MainMenu,AppShellReport}Tests.swift`.
- Panel key routing (I-8): `PanelKeyRoute`, `PanelFirstResponder`, `MenuTrackingObserver` in
  `Sources/MuxFinderUI/Model/PanelKeyRouting.swift`, used by `PanelKeyTrackingView`
  (`Views/PopoverWindowBridge.swift`); diagnostic `Preview/KeyViewLoopReport.swift`; tests
  `Tests/MuxFinderUITests/HostPickerKeyboardTests.swift`.
- New session window (I-9a, D34): model `Sources/MuxFinderUI/Model/AppModelNewSession.swift`,
  placement and sizing `Model/NewSessionWindowController.swift`, the panel
  `Views/NewSessionWindow.swift` (built by the app shell only); inline-form fixtures kept for
  I-9b in `Preview/AttachFixtures.swift` and `Preview/SwitcherFixtures.swift`; tests
  `Tests/MuxFinderUITests/NewSessionWindowTests.swift`. Folder drop (I-9b): pure
  `Model/FolderDrop.swift`, drop view `Views/FolderDropView.swift` (over the Directory row in
  `Views/DirectoryPickerViews.swift`), gallery `Preview/NewSessionGallery.swift`
  (`--preview-gallery new-session`, `docs/screenshots/new-session-states-*.png`); tests
  `Tests/MuxFinderUITests/FolderDropTests.swift`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (latest; earlier phases' are in their archives)

- Phase I-8 (final tree, orchestrator, 2026-11-05): `swift build` exit 0; `swift test` 815
  core tests in 81 suites passed and `swift test --filter MuxFinderUITests` 390 UI tests in 39
  suites passed; `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0,
  `codesign --verify --deep --strict build/muxFinder.app` exit 0 —
  `docs/progress-archive/i-8.md`.
- Phase I-9a (final tree, orchestrator, 2026-11-05): `swift build` exit 0; `swift test` exit
  0, 815 core tests in 81 suites and 406 UI tests in 40 suites; `swift format lint -r Sources
  Tests` exit 0; `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict
  build/muxFinder.app` exit 0; `--report-menu-bar-item` under an empty private home exit 0, no
  child, home empty. Worker: `--report-popover-placement` exit 0 (passed), `--selftest
  new-session-local` 7/7 (iTerm2 17 → 20 threads) — `docs/progress-archive/i-9a.md`.
- Phase I-9b (final tree, orchestrator, 2026-11-06): `swift build` exit 0; `swift test` exit
  0, 815 core tests in 81 suites; `swift test --filter MuxFinderUITests` exit 0, 431 UI tests
  in 43 suites; `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0;
  `codesign --verify --deep --strict build/muxFinder.app` exit 0. Worker: `swift build
  -warnings-as-errors` exit 0, `--report-menu-bar-item` under a private home exit 0, no child,
  home empty; no real run — `docs/progress-archive/i-9b.md`.
- Phases 1–I-7: each phase's final-tree verification is in `docs/progress-archive/<phase>.md`.

## Git state

- All phases through 10b are committed and pushed to `origin/main`: 1 `bb086c9`, 2 `c1ee43d`,
  3a `745e36e`, 3b `0d3b65f`, 4a `1f5a3be`, 4b `f888a2c`, 4c `e631641`, 5a `5b47e14`, 5b
  `6b1aedc` + `dca1228`, 6a `0210999` + `e0fcbdd`, 7a `228f8da`, 7b `d512f47`, 6b `ce26808`
  (closure `cb855c0`, summary `880470f`), 8 `dc1935d`, 9a `ac1b9ee`, 9b `94cc960`, 10a
  `d6fe103`, 10b `ec402ce` (pushed; `origin/main` at `ec402ce` before Phase 11a). From 3b on,
  commit messages carry no AI attribution trailer (user's global rule).
- Later phases, all pushed: 11a `289b7f4`, 11b `a5ca9e0`, 11c `930994e`, 12a `520b7e3`, 12b
  `6f56399` (then `92e354a`, icons and notarized release flow), Phase 13 planning `d03e146`
  (the user's edits, verbatim), 13a `0284b84`, 13b `c3e2948`, 13c `d5955ff` (summary
  `a9532fa`), 14 `6750a1b`, I-1a `72e635a`, I-1b `adf79ec`, I-2a `3feab0e`, I-2b `e36e471`,
  I-3a `29bb362`. Inbox triage commits: I-1/I-2 `bd9aed6`, I-3 `2fdfc87`.
- Phase I-3b: `d5fa941`, pushed. Inbox triage (I-4): `3804a78`.
- Phase I-4: `d428822`, pushed. Inbox triage (I-5, I-6): `d1f445a`; phase summary `3b2603d`.
- Phase I-5: `8f08b99`, pushed. Phase I-6: `26cef52`, pushed. Inbox triage (I-7): `79bea34`,
  pushed. Phase I-7: `84a0adf`, pushed. Inbox triage (I-8): `f9e2b04`. Phase I-8: `b8ffe91`,
  pushed. Inbox triage (I-9 queued, item 99 deferred): `8588893`; phase summaries `223ab3a`,
  `99c224f`, pushed. Phase I-9a: `da48655`, pushed. Phase I-9b: the commit carrying this
  checkpoint ("Phase I-9b: drop a Finder folder on New session's Directory"), pushed (SHA
  and push result in the run's status line and the next checkpoint).
- The runner's preflight file for the I-4 run names `CLAUDE.md` (the user's NonameDownloads
  note) and `nonamedownloads.json`: the user's, left uncommitted and untouched.
