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

### Queued

| Phase | Title | Specification | Position |
|---|---|---|---|
| I-11 | Detach other clients (high): proof of the command through iTerm2's tmux connection first (local and Saturno), a coordinator call bound to a session-key confirmation, the popover's "Detach other clients…" item and its confirmation, an e2e step, galleries, new D number, docs | `autoclaude/processed/105-detach-other-clients.md` | next; before I-12 (the user's order) |
| I-12 | Other terminal apps (high, a group): Terminal.app and Ghostty in plain tmux beside iTerm2's control mode, terminal seam, JSON definitions, helper plain mode, confirmation, Settings › General "Terminal", strings, onboarding without iTerm2, docs; split into sub-phases (the item suggests a–e) in `PLAN.md` before its first worker | `autoclaude/processed/110-other-terminal-apps.md` | after I-11 (last) |

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
Mac, are recorded in the item and in commit `f1b11ac`). 2026-11-06 09:21 (start of the
iteration), two items triaged: `105-detach-other-clients.md` → I-11, `110-other-terminal-apps.md`
→ I-12, both queued, high as proposed, I-11 ahead of I-12 as the user asked (no instruction to
the run in either; their user decisions are recorded in the items).

## Current phase

Phases 1–14, I-1 (a, b), I-2 (a, b), I-3 (a, b), I-4 to I-8, I-9 (a, b) and I-10 (a, b)
are complete and reviewed. The user released 0.2.0 (build 2) in `f1b11ac`. **Phase I-10b —
folder search UI (routine): complete** 2026-11-06 (`docs/progress-archive/i-10b.md`).
**Queued: I-11** (Detach other clients; *Next action* 0), then **I-12** (other terminal apps,
a group to split first). Also remaining: the manual checklist (the user's). Phase
13's settled design is **D29**; real facts in `PLAN.md` *Verified facts* "Phase 13a
spike" and "Phase 13c real runs". Earlier splits: 6 into 6a/6b, 7 into 7a/7b, 9 into 9a/9b, 10
into 10a/10b, 11 into 11a/11b/11c, 12 into 12a/12b, 13 into 13a/13b/13c, I-1 into I-1a/I-1b,
I-2 into I-2a/I-2b, I-3 into I-3a/I-3b, I-9 into I-9a/I-9b, I-10 into I-10a/I-10b.

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
- Phase I-10a: all criteria met, 2026-11-06 — the core types and probe `folders`; 64 hermetic
  folder-search tests (escaping, parser incl. a newline in a name, the noise rule, limit and
  end records through the real script with stub `mdfind`/`mdutil`, the channel with a fake
  transport and clock, the scope preference), 879 core + 431 UI pass; real `--count-only`
  runs on this Mac and Saturno recorded in `docs/TESTING.md` *Phase I-10a* (open channel
  0.12–0.46 s per query after the fixes; opening 0.8–0.9 s on Saturno), nothing left running;
  D36 recorded; the three owed `CLAUDE.md` notes applied — `docs/progress-archive/i-10a.md`.
- Phase I-10b: all criteria met, 2026-11-06 — the section's states, de-dup, pick, the `/` and
  <2 rules, unusable paths dropped, the channel's lifetime, the scope per query, announcements
  and This Mac's `unchecked` argument under hermetic tests (37 new UI tests, 2 core; 881 core +
  468 UI pass); one real read-only local `folders --count-only` (header "not checked", no child
  left); galleries light and dark inspected; checklist 24 new; real search on Saturno, This
  Mac's privacy prompt and VoiceOver owed — `docs/progress-archive/i-10b.md`.

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
- Phase I-9b: the orchestrator's calls in `PLAN.md` *Phase I-9* ("calls for I-9b"): the drop
  target is the Directory row only (the user's "onto Directory"); one non-package folder URL,
  everything else refused with no "+"; the path as dropped, `~` by whole components; the fill
  a pick. The worker's route: an invisible AppKit drop view in front of the field and its
  field editor, registered for every type the field editor takes, clicks passing through. The
  switcher's `formFiltered`/`formNoMatches` fixtures retired as duplicates of the window's
  states. `docs/REQUIREMENTS.md` left as it is (the verbatim brief, never inline) —
  `docs/progress-archive/i-9b.md`.
- Phase I-10: split into I-10a/I-10b in `PLAN.md` before the first worker, with the
  orchestrator's calls there: one static script for This Mac and SSH hosts (not
  `NSMetadataQuery`); the channel carries only id, scope and escaped name text, the script
  builds the fixed predicate; the fixed noise rule (a)–(d) in the script, tested through the
  real script with stub tools; at most 50 folders; the scope in `preferences.json`. New
  **D36** (D3, D11, D32 edited) adds the worker's and the review's: refusal of unescaped
  `" * ? \`, a 4 s host-side deadline per query (worst-case host lifetime after a disconnect
  about 4–5 s), the explicit stop at the limit, an 8-event transport queue —
  `docs/progress-archive/i-10a.md`.
- Phase I-10b: the orchestrator's calls in `PLAN.md` *Phase I-10* ("calls for I-10b"): This
  Mac runs no readability check (a fixed `unchecked` script argument; the note only for SSH
  hosts); unusable paths dropped before they are offered; text with `/` or under 2 characters
  sends no query; the section last, counting for I-7's open rule; one channel per window and
  host; the scope read per query; announcements as I-7's. The worker's: folder search only in
  normal mode; earlier matching results kept while a new text is searched (same host and scope
  only, after the review); a model-owned scope save awaited at shutdown —
  `docs/progress-archive/i-10b.md`.

## Open risks / deviations

- Phases 13–I-2a: their open risks and deviations moved verbatim to
  `docs/progress-archive/open-risks-13-i-2a.md` (iTerm2's auto-hide setting's "on" branch only
  proven by 13a's old harness; the real popover, its keys, focus and clicks unseen, checklist
  15–16; load-sensitive private-server tests; the race's dangerous order unforced).
- I-2b to I-9a: their open risks moved verbatim to
  `docs/progress-archive/open-risks-i-2b-i-9a.md` (real keys, clicks, presses, drags and
  windows unverified, checklist 15–23; load-sensitive private-server tests). The three
  `CLAUDE.md` notes owed there by I-4, I-6 and I-9a were applied by I-10a.
- I-9b: no real drag was made; that the drop view gets drags ahead of the field editor in the
  real window rests on one throwaway probe of the worker's (deleted; the shipped code uses no
  private API) — checklist 23. The popover gallery's committed screenshot predates I-6 (32 px
  shorter than it renders now; not regenerated, I-9 did not change it). The worker ran one
  read-only `git log`, against its brief — `docs/progress-archive/i-9b.md`.
- I-10a: to verify the escaping by counts the worker mounted its own 16 MB scratch disk image
  with Spotlight indexing on, queried synthetic folders, then detached and deleted it (none
  left mounted, `hdiutil info`): beyond rule 3's "read-only queries", no folder of the user's
  touched — noted for the user. Handed to I-10b: the readability check may raise a macOS
  access prompt on This Mac (decide whether to skip it locally); paths with a newline must pass
  `Validation.workingDirectory` before being offered; a mid-word `'` finds nothing; an
  unreachable host shows its problem after up to ~10 s. One fix-worker `swift test` run had 3
  `PopoverHeightLimitTests` failures, not reproduced. The fix worker ran one read-only `git
  diff --stat` — `docs/progress-archive/i-10a.md`. Those handovers were settled by I-10b's
  calls.
- I-10b: rows of the previous scope can show for the few milliseconds before the channel
  announces a new search; 2 of the worker's 7 full `swift test` runs had one load-sensitive
  core process test over its bound (passing alone 15 times; the orchestrator's final runs
  passed); owed to the user, checklist 24 (real Saturno search, This Mac's privacy prompt,
  protected folders on This Mac, the links, VoiceOver) — `docs/progress-archive/i-10b.md`.

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

- Phase I-10a: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 1
  blocker (a blocked remote search outliving the ssh close → 4 s host deadline) + 2
  should-fix (limit stop without SIGPIPE; bounded event queue); a review-fix worker fixed all
  three, each regression failing with its fix reverted; re-verified by the orchestrator —
  `docs/reviews/phase-I-10a.md`.
- Phase I-10b: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 2 should-fix (previous results kept across a scope change; an untracked scope save
  lost at quit); a review-fix worker fixed both, each regression failing with its fix
  reverted; re-verified by the orchestrator — `docs/reviews/phase-I-10b.md`.

## Next action

0. **Phase I-11 (queued, high): Detach other clients.** Poll the inbox first. Then add a
   `### Phase I-11` section to `PLAN.md` (before *Deferred*) from
   `autoclaude/processed/105-detach-other-clients.md`; it is high and has a real-run proof
   requirement (1) before the UI, so split it before the first worker, e.g. **I-11a** proof +
   core (the command through iTerm2's tmux connection on This Mac and Saturno, option (a)
   `attach-session -d -t <id>` vs (b) per-client `detach-client -t <name>` bound by
   `client_pid`/session, the new D number, the coordinator call with its session-key
   confirmation and typed results, the e2e step) and **I-11b** UI (the popover's "Detach other
   clients…" item and the D25-style confirmation, galleries, docs, checklist). Real runs follow
   the gate in item 3. Then I-12 (`autoclaude/processed/110-other-terminal-apps.md`, split
   a–e as it suggests, in `PLAN.md` before its first worker).
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
   `iterm2 list-sessions`). iTerm2 was at 20 threads after I-9a's self-test (2026-11-05 ~23:15).

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
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (latest; earlier phases' are in their archives)

- Phase I-10b (final tree, orchestrator, 2026-11-06): `swift build` exit 0; `swift format
  lint -r Sources Tests` exit 0; `swift test` 881 core tests in 87 suites and 468 UI tests in
  46 suites passed, no failure; `scripts/build-app.sh` exit 0; `codesign --verify --deep
  --strict build/muxFinder.app` exit 0; no `mdfind` or probe process left. Workers:
  `-warnings-as-errors` builds exit 0; one real local `folders --count-only` —
  `docs/progress-archive/i-10b.md`.
- Phase I-10a (final tree, orchestrator, 2026-11-06): `swift build` exit 0; `swift format
  lint -r Sources Tests` exit 0; `swift test` 879 core tests in 87 suites and 431 UI tests in
  43 suites passed; `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict
  build/muxFinder.app` exit 0; no `mdfind` or probe process left. Workers: `-warnings-as-errors`
  builds exit 0; real `folders --count-only` on this Mac and Saturno — `docs/progress-archive/i-10a.md`.
- Phases 1–I-9b: each phase's final-tree verification is in `docs/progress-archive/<phase>.md`.

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
- Phase I-10b: the commit carrying this checkpoint ("Phase I-10b: folder search UI"), pushed
  (SHA and push result in the run's status line and the next checkpoint).
