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

### Queued

| Phase | Title | Specification | Position |
|---|---|---|---|
| I-12c3b, I-12d, I-12e | Other terminal apps, the rest of the group as split in `PLAN.md` *Phase I-12*: c3b `e2e-plain --terminal terminal\|ghostty --local \| --ssh saturno-m4` (real runs only through the rule-8 gate, else owed) and iTerm2's `e2e-*` as regression (high), d UI (routine), e docs (routine) | `autoclaude/processed/110-other-terminal-apps.md` | next (c3b first) |
| I-13 | Update check (high, a group): GitHub `releases/latest` check at launch and daily (toggle on by default), popover notice and icon dot, one-click Update (download, SHA-256, `ditto`, Developer ID + notarization check, D27-style swap, relaunch), hand-written, no Sparkle; split a (core) / b (UI) in `PLAN.md` before its first worker | `autoclaude/processed/120-update-check-github.md` | after I-12 (last) |

**Inbox**: every triage through 2026-11-06 (items 40 to 120, item 99 deferred and then resolved
by the user) is logged verbatim in `docs/progress-archive/inbox-log.md`. Standing note: at
I-13's selection settle first whether *Unattended-run rules* 3 ("no other host") lets a run
make the item's read-only GitHub GETs (`update check`, `update verify`); if not, those real
runs are owed to the user. 2026-11-06 18:31 (start of I-12c3a's iteration): `list` empty.

## Current phase

Phases 1–14, I-1 (a, b), I-2 (a, b), I-3 (a, b), I-4 to I-8, I-9 (a, b), I-10 (a, b) and
I-11 (a, b), I-12a and I-12b (b1, b2, b3) are complete and reviewed. The user released 0.2.0
(build 2) in `f1b11ac`. **Phase I-12 (other terminal apps) is split into I-12a–e**, and
**I-12b into I-12b1/I-12b2/I-12b3**, in `PLAN.md` *Phase I-12*; **I-12a** (proof and
decision), **I-12b1** (definitions, loader, AppleScript runner), **I-12b2** (helper plain
mode) and **I-12b3** (terminal seam) complete 2026-11-06
(`docs/progress-archive/{i-12a,i-12b1,i-12b2,i-12b3}.md`). **I-12c is split into
I-12c1/I-12c2/I-12c3**, and **I-12c3 into I-12c3a/I-12c3b**; **I-12c1** (the plain backend),
**I-12c2** (open on this Mac) and **I-12c3a** (onto the seam) complete 2026-11-06
(`docs/progress-archive/{i-12c1,i-12c2,i-12c3a}.md`). **Next: I-12c3b** (the plain runs;
*Next action* 0), then I-12d, I-12e, then **I-13** (update check, a group to split a/b).
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
- Phase I-12c3a: all criteria met, 2026-11-06 — the resolution, the seam, the never-contact
  proof, the pending-change rule, the name refusal and the probe gate hermetic (1158 core + 497
  UI pass; no existing expectation edited, three UI test files rewired); real runs on the final
  tree: `--selftest attach-local` 8/8 and `--selftest new-session-local` 7/7 through the seam,
  bundle signed and `codesign --verify` exit 0; the worker's `--report-menu-bar-item`,
  `terminals list`, `local-clients` and `attach --terminal terminal` (Terminal not running →
  exit 2, nothing sent) — `docs/progress-archive/i-12c3a.md`.

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
- Phase I-12c3a: **I-12c3 split** into c3a (onto the seam) and c3b (the plain runs) in
  `PLAN.md` *Phase I-12*, with the calls for c3a ("Calls for I-12c3a": the `terminal` key and
  its typed resolution, backends cached per id, every iTerm2 contact gated on the choice, D26's
  rewrite only with iTerm2, the `{`/`[`/`]` refusal, no ancestry in the iTerm2 attach,
  self-tests forced to iTerm2, `attach --terminal` gated). The workers': `versionUnknown`;
  `TerminalSettingStoring`; `setAttachmentChecksEnabled(_:)` instead of rebuilding the engine;
  Install/Remove profile buttons left for I-12d; and the review fixes (unresolved launches
  checked across backends, `unresolved` choice at startup, unattended run policy in the window
  layer, records per terminal and session) — D38 "Onto the seam (I-12c3a)",
  `docs/progress-archive/i-12c3a.md`.

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
- I-12a (**for the user**): the real Terminal and Ghostty window runs are owed (open, confirm,
  focus, detach, Move here; what `do script` returns, Ghostty's ids, whether its `environment
  variables` reach `command` and whether `direct:` works through AppleScript) —
  `docs/TESTING.md` *Phase I-12a, Owed*. I-12b and I-12c must design for either answer. The
  `detach-client` target is picked by name only (the bound command checks it is unique); the
  remote bound attach's refusal is tested only through the local builder. One `swift test` run
  made beside other commands failed a folder search transport timing bound (load-sensitive,
  untouched code); alone it passed.
- I-12b1: compiling and calling the built-in Terminal and Ghostty scripts is owed to a real
  run (their fit with the dictionaries checked only against `sdef`); the same folder search
  timing test failed once in a worker's full run (2.018 s against 2 s) and passed in every
  later run — `docs/progress-archive/i-12b1.md`.
- I-12b2: the remote plain attach tested only through its argv (real run: I-12c's
  `e2e-plain`); no terminal app has run the plain modes; one worker full run failed one
  "Directory store" test (untouched code), passing alone and in every later run —
  `docs/progress-archive/i-12b2.md`.
- I-12b3: nothing uses the seam yet (I-12c); the "unrecognised permission status goes ahead"
  call is for I-12c/I-12d to keep or revisit with the real runs; a facts read that wrongly
  says a running app stopped would only leave a window open — `docs/progress-archive/i-12b3.md`.
- I-12c1: nothing uses the plain backend yet (I-12c3); a session name with `{`, `[` or `]`
  cannot be checked or detached by the bound commands (fails `notWritable`, nothing wrong
  touched; I-12c3/I-12d decide whether to refuse it up front); a detach-others stopped
  partway says "none detached" though some may have been (I-12d's wording) —
  `docs/progress-archive/i-12c1.md`.
- I-12c2: no client in Terminal or Ghostty traced for real (Ghostty's chain unverified); nothing
  calls the attributor yet (I-12c3); an app found by ancestry is focused by activation only, and
  macOS 14's cooperative activation may refuse it (recorded, never failing an attach); the review
  fix extended one existing test's input and expectations — `docs/progress-archive/i-12c2.md`.
- I-12c3a: no plain real run yet (I-12c3b); the "earlier launch pending" refusal across
  backends covers Open and Move here only, its message still names iTerm2 (I-12d), and an iTerm2
  launch whose helper died without a result keeps that session refused in other terminals for
  the app's life; Detach from another terminal's records is not offered while it is not chosen;
  an SSH-setup click before the choice resolves shows "not used with this terminal"; the known
  load-sensitive folder search timing test failed once in a worker run; Ghostty is now installed
  on this Mac — `docs/progress-archive/i-12c3a.md`.

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
- Phase I-12c3a: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 3
  blockers (unresolved-launch protection lost across backend switches; iTerm2 contactable
  before the choice resolves at startup; the probe's rule-8 gate checked only before
  discovery) + 1 should-fix (one attachment handle per session across backends); a review-fix
  worker fixed all four, each regression failing with its fix reverted; re-verified by the
  orchestrator with both self-tests real — `docs/reviews/phase-I-12c3a.md`.

## Next action

0. **Phase I-12c3b (queued, high): Other terminals, the plain runs.** Poll the inbox first.
   Then read `PLAN.md` *Phase I-12* ("I-12c3 split, and the orchestrator's calls": the I-12c3b
   bullet; "Calls for I-12c3a" for context), D38's sub-bullets "Plain backend (I-12c1)", "Open
   on this Mac (I-12c2)" and "Onto the seam (I-12c3a)", *Unattended-run rules* 8, and the
   acceptance of `autoclaude/processed/110-other-terminal-apps.md` (the `e2e-plain` bullet).
   Write "Calls for I-12c3b" in `PLAN.md` before its worker: `e2e-plain --terminal
   terminal|ghostty --local | --ssh saturno-m4` (its own `muxfinder-test-*` sessions and its
   own windows only; the unattended run policy I-12c3a added; open, confirm, focus, detach, Move
   here; cleanup closes only its own windows by recorded id after their process ended), real
   runs only when `terminals list` shows the app `running` and `granted` (else owed to the user
   with the exact command; Ghostty is now installed on this Mac — still never launch it), then
   iTerm2's `e2e-local`, `e2e-remote saturno-m4`, `e2e-bury --local` and `e2e-detach-others
   --local` as regression under the gate in item 3 (let threads fall back between runs). Then
   I-12d, I-12e. After I-12, **I-13** (`autoclaude/processed/120-update-check-github.md`, split a core / b
   UI; first settle the GitHub GETs question, see the *Inbox* note).
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
   `iterm2 list-sessions`). iTerm2 was at 37 threads after I-12b2's `e2e-local` (2026-11-06
   ~15:52), then ran `e2e-bury --local`; let it fall back before the next real run.

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`; overview: `docs/ARCHITECTURE.md`.
- Phases 1 to I-9b: their key paths moved verbatim to
  `docs/progress-archive/key-paths-1-i-9b.md`.
- Folder search core (I-10a, D36): `Sources/MuxFinderCore/FolderSearch/` (`FolderSearchText`
  escaping, `FolderSearchScript` the static script, `FolderSearchOutput` the parser,
  `FolderSearchTransport`, `FolderSearchChannel`, `FakeFolderSearchTransport`),
  `Sources/MuxFinderCore/Process/StreamingProcess.swift`, the scope in
  `Config/PreferencesStore.swift`, probe `Sources/muxfinder-probe/FoldersCommand.swift`; tests
  `Tests/MuxFinderCoreTests/FolderSearch*Tests.swift` and `FolderSearchTestSupport.swift`.
- Folder search UI (I-10b): `Sources/MuxFinderUI/Model/{FolderSearchSection,AppModelFolderSearch,SettingsModelFolderSearch}.swift`,
  `Views/DirectoryPickerViews.swift`, `Views/Settings/DirectoriesSettingsView.swift`,
  `Preview/FolderSearchFixtures.swift`; tests
  `Tests/MuxFinderUITests/{FolderSearchSectionTests,FolderSearchModelTests,SettingsFolderSearchTests,FolderSearchUITestSupport}.swift`.
- Detach other clients (I-11a, D37): `Sources/MuxFinderCore/Attach/{AttachCoordinatorDetachOthers,DetachOtherClientsModels}.swift`,
  `ITerm2/ITerm2APIClient.swift` (`commandOutput(of:)`), probe
  `Sources/muxfinder-probe/E2EDetachOthers{Command,Run}.swift`; tests
  `Tests/MuxFinderCoreTests/DetachOtherClientsTests.swift`.
- Detach other clients UI (I-11b): `Sources/MuxFinderUI/Model/{AppModelSessions,SessionPanels,SessionProblem,SwitcherContent}.swift`,
  `Views/{SessionPanelViews,SessionRowView,SwitcherView}.swift`, `Preview/AttachFixtures.swift`;
  tests `Tests/MuxFinderUITests/DetachOtherClientsUITests.swift`.
- Other terminals (I-12a, D38): `Sources/MuxFinderCore/Launch/{PlainLaunch,PlainBoundCommands}.swift`,
  `Sources/MuxFinderCore/Terminals/{AutomationPermission,TerminalCommandText}.swift`, probe
  `Sources/muxfinder-probe/{TerminalsCommand,PlainProofCommand,PlainProofRun,PlainProofTerminal}.swift`;
  tests `Tests/MuxFinderCoreTests/{PlainLaunch,PlainBoundCommands,TerminalCommandText,AutomationPermission}Tests.swift`.
- Terminal definitions (I-12b1): `Sources/MuxFinderCore/Terminals/{TerminalDefinition,TerminalDefinitionParser,TerminalDefinitionProblem,TerminalDefinitionLoader,TerminalLaunchCommand,AppleScriptRunner,TerminalScriptCalls,TerminalAppFacts,JSONDuplicateNameScanner}.swift`,
  built-ins `Resources/Terminals/`; tests
  `Tests/MuxFinderCoreTests/{TerminalDefinition,TerminalDefinitionLoader,TerminalLaunchCommand,AppleScriptRunner}Tests.swift`.
- Helper plain mode (I-12b2): `Sources/MuxFinderCore/Launch/{LaunchHelperPlain,PlainLaunchReport,LaunchModels,LaunchStore,TerminalChildRunner}.swift`;
  tests `Tests/MuxFinderCoreTests/{LaunchHelperPlain,PlainLaunchReport,LaunchHelperProfilePlain,LaunchHelperPlainBinary}Tests.swift`.
- Terminal seam (I-12b3): `Sources/MuxFinderCore/Terminals/{TerminalBackend,ITerm2TerminalBackend,PlainTerminalWindows,PlainTerminalWindowError,PlainTerminalSeams,PlainTerminalFakes}.swift`;
  tests `Tests/MuxFinderCoreTests/{ITerm2TerminalBackend,PlainTerminalWindows,PlainTerminalSeams}Tests.swift`.
- Plain backend (I-12c1): `Sources/MuxFinderCore/Terminals/{PlainTerminalBackend,PlainTerminalBackendDetach,PlainTerminalBackendModels,PlainTmuxCommands,PlainTerminalBackendFakes}.swift`,
  `Sources/MuxFinderCore/Attach/AttachSharedSteps.swift`; tests
  `Tests/MuxFinderCoreTests/PlainTerminalBackend{,Detach,EndToEnd}Tests.swift`,
  `PlainTerminalBackendTestSupport.swift`.
- Open on this Mac (I-12c2): `Sources/MuxFinderCore/Terminals/{ProcessTable,ProcessTableFakes,LocalClientAttribution}.swift`,
  discovery's `tty` record in `Tmux/{ProbeScript,ProbeReport}.swift`, `Refresh/RefreshCoordinator.swift`
  (`localClients:`), probe `Sources/muxfinder-probe/LocalClientsCommand.swift`; tests
  `Tests/MuxFinderCoreTests/{ProbeClientFields,LocalClientAttribution,LocalClientsReal,RefreshLocalAttachments,PlainTerminalBackendOpenHere}Tests.swift`.
- Onto the seam (I-12c3a): `Sources/MuxFinderCore/Terminals/{TerminalChoice,AttachCommandOptions}.swift`,
  `Config/PreferencesStore.swift` (`terminal`), `Sources/MuxFinderUI/Model/{TerminalEnvironment,AppModelTerminal,AppEnvironment,AppModelSessions}.swift`,
  `SelfTest/SelfTestDriver.swift`, probe `Sources/muxfinder-probe/AttachCommand.swift`; tests
  `Tests/MuxFinderCoreTests/{TerminalChoice,TerminalSeamCore}Tests.swift`,
  `Tests/MuxFinderUITests/TerminalSeamTests.swift`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/` (inbox log: `inbox-log.md`).

## Verification (latest; earlier phases' are in their archives)

- Phase I-12c3a (final tree, orchestrator, 2026-11-06): `swift build` exit 0; `swift format
  lint -r Sources Tests` exit 0; `swift test` exit 0, 1158 core tests in 118 suites and 497
  UI tests in 48 suites; `scripts/build-app.sh` exit 0, `codesign --verify --deep --strict`
  exit 0; `iterm2 status` connected, threads 17 → 25; `--selftest attach-local` 8/8 and
  `--selftest new-session-local` 7/7; leftovers clean (no test session, 0 buried before and
  after, launch folder empty) — `docs/progress-archive/i-12c3a.md`.
- Phases 1–I-12c2: each phase's final-tree verification is in
  `docs/progress-archive/<phase>.md`.

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
  `99c224f`, pushed. Phase I-9a: `da48655`, pushed. Phase I-9b: `c32558c`, pushed.
- The user's release commit `f1b11ac` ("Release 0.2.0 (build 2)", 2026-11-06) committed their
  `CLAUDE.md` and `nonamedownloads.json`; the tree was clean when this run started (empty
  preflight file). Inbox triage (I-10): `faa47a6`.
- Phase I-10a: `267dc0b`, pushed. Inbox triage (I-11, I-12): `f03de09`.
- Phase I-10b: `6f4aec2`, pushed.
- Phase I-11a: `53f2d95`, pushed. Inbox triage (I-13): `5dfb622`.
- Phase I-11b: `148da51`, pushed.
- Phase I-12a: `59e2306`, pushed.
- Phase I-12b1: `e60149d`, pushed.
- Phase I-12b2: `d008435`, pushed.
- Phase I-12b3: `06f7d6e`, pushed.
- Phase I-12c1: `73718f1`, pushed.
- Phase I-12c2: `e2c0ea8`, pushed.
- Phase I-12c3a: the commit carrying this checkpoint ("Phase I-12c3a: other terminals, onto the
  seam"), pushed (SHA and push result in the run's status line and the next checkpoint). The
  tree was clean when this iteration started (empty preflight file).
