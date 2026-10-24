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

Queued from the inbox (specification in `autoclaude/processed/`; position after Phase 14, in
this order):

| Phase | Title | Specification | Position |
|---|---|---|---|
| I-1 | Popover under the menu bar icon (diagnose, then place; suggested risk high) | `autoclaude/processed/10-popover-under-menu-bar-icon.md` | after Phase 14 |
| I-2 | New session: pick the directory (split I-2a core, high; I-2b UI, routine) | `autoclaude/processed/20-new-session-directory-picker.md` | after I-1 |
| I-3 | Global hotkey: session switcher (split I-3a shortcut and Settings; I-3b switcher panel; both routine) | `autoclaude/processed/30-global-hotkey-session-switcher.md` | after I-2 |

## Current phase

**Phase 13 — Hide the launch tab once attached (high), added 2026-10-24: complete** (13a
client, helper and spike; 13b coordinator, race and recovery; 13c real runs and documents).
Phases 1–13c are complete and reviewed. The settled design is **D29**; real facts are in
`PLAN.md` *Verified facts* "Phase 13a spike" and "Phase 13c real runs".
**Phase 14 — Popover readability (routine), added 2026-10-24, next.** It comes
from the user's review of the real popover: a bounded section per host, attach state at a
glance, a readable "Open in iTerm2 here", a muted unreachable host, footer spacing, and an
opaque popover so the preview gallery matches the menu bar. It is independent of Phase 13 and
needs no real run. **Inbox** (2026-10-24, before 13c): two items triaged, both queued after
Phase 14 — I-1 (popover placement) and I-2 (New session directory picker); neither carried
`priority: next`. I-1's in-process `performClick(_:)` opening step needs the orchestrator's
call against the no-UI-scripting rule when it runs. **Inbox** (2026-10-24, after 13c): one
item, queued as I-3 (global hotkey session switcher) after I-2; its optional
`--report-hotkey-registration` flag needs the same no-UI-scripting call. Earlier splits: 6 into 6a/6b, 7 into 7a/7b, 9 into 9a/9b, 10 into
10a/10b, 11 into 11a/11b/11c, 12 into 12a/12b.

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
- Phase 13a: all criteria met, 2026-10-24. Client, conformers, golden fixtures, helper restore
  and `e2e-bury` are in place; spike (a)–(e) answered locally and on Saturno (12/12 each, nothing
  left behind); D29 written. One deviation: this Mac's iTerm2 then had its auto-hide setting
  on, so the default-preference branch was emulated by the harness (closed by 13c's runs).
  `docs/progress-archive/13a.md`.
- Phase 13b: all criteria met hermetically, 2026-10-24 (bury call site and outcome, race by
  order, recovery, Show tab, buried fakes, e2e assertions as code; every 13b-bullet unit test
  plus the review's three regressions); its e2e assertions then passed for real in 13c.
  `docs/progress-archive/13b.md`.
- Phase 13c: all criteria met, 2026-10-24. `e2e-bury` runs through the coordinator (13 steps)
  and both self-tests assert the buried launch tab; real runs all exit 0, every step PASS —
  `e2e-local` 16/16, `e2e-remote saturno-m4` 17/17, `e2e-bury --local` and `--ssh saturno-m4`
  13/13 each (rerun after the review fixes), `--selftest attach-local` 8/8, `new-session-local`
  7/7, `e2e-profile --local` 14/14; gate and leftover checks clean, `profiles hashes`
  identical; documents updated. iTerm2's auto-hide setting was at its default (off) for these
  runs, so the default branch is now proven for real. `docs/progress-archive/13c.md`.

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
- Phase 13a: new **D29**: bury after confirmation and `.activated`; the race closed by order
  (peek at the result, then `setBuried(false)`); the helper's restore with a line feed, a
  second restore when unanswered and the DSR acknowledgment; the coordinator's list of buried
  tabs kept **in memory only**, because the helper alone recovered every abnormal end tried.
  D14 gains *Launch tab restore*; D15 and D25 were edited — `docs/progress-archive/13a.md`.
- Phase 13b: D29 now states what exists: the bury is step 10 with `AttachResult.burial`;
  recovery waits 15 s (`buriedTabCloseDelay`) after a clean result before closing a still-listed
  tab (the helper lives up to ~12 s after it); swept results are seen only through the
  coordinator's own connection listings, each counting only against tabs watched before it
  started; `Configuration.buriesLaunchTabs` (default on) is off in `e2e-bury`; e2e coordinators
  run through `RecordingITerm2Integration` so "left by itself" is proven —
  `docs/progress-archive/13b.md`.
- Phase 13c: `e2e-bury` dropped the spike's own bury and runs through the coordinator (no
  caller turns `buriesLaunchTabs` off any more; the switch stays); spike cases (b)/(d) became
  step 9, a real check of recovery; step 7 releases the bury and the detach together and never
  counts an ownership refusal as the race; pure judgements in
  `Sources/MuxFinderCore/Attach/LaunchTabChecks.swift` so the probe's checks have unit tests —
  `docs/progress-archive/13c.md`.

## Open risks / deviations

- **13: iTerm2's auto-hide setting** ("Automatically bury the tmux client session after
  connecting", read only, never written) was on for 13a's spike and at its default (off) for
  13c's runs (iTerm2 exited between 12:15 and 12:24 on 2026-10-24, not the run's doing, and
  came back without the key). So the default branch is proven for real; the "on" branch only by
  the 13a spike's old harness, never by the 13c harness.
- 13a: "Return works" after an abnormal end is inferred from an answered DSR, never typed (no
  synthesized keystrokes); it is in `docs/MANUAL-CHECKLIST.md` item 14. A SIGHUP or SIGKILL of
  the helper in the middle of its exchange cannot restore raw mode (the tab ends with it).
  iTerm2 sources (`v3.7.6`) were downloaded to `/tmp/mfx-iterm2-src` for reading only.
- 13b/13c: the refresh engine's attachment checks do not feed recovery (only the coordinator's
  own listings do). The race's dangerous order (bury landing after the helper's restore) was
  not forced for real — on both hosts the bury landed first; forcing it needs a seam inside
  `ITerm2APIClient.buryLaunchTab`; 13b's unit tests cover the order. Step 7's retry path ran
  only in unit tests. `CreatedSessionTests.killsOnlyTheRecordedSessionOnAPrivateServer` (6a)
  failed once with `scripts/build-app.sh` running in parallel, then passed alone and 3/3
  isolated — another load-sensitive private-server test. `CLAUDE.md` / `docs/TESTING.md` say
  about 123 s for `e2e-remote` (13c: 120.4 s). The user's own muxFinder.app had attachments
  open during 13c's runs; every check left them out — `docs/progress-archive/13c.md`.

- Process-runner tests use an armed-timeout helper to survive very high machine load; if they
  flake, look there first.
- Two classifier rows ("No route to host", "Network is unreachable") are standard OpenSSH
  wording, not real captures (marked in `ErrorClassifierTests`).
- The "host key changed" real check predates the `ControlMaster=no` / `ControlPath=none`
  harness options; the "unknown" check was re-run with them (same result).
- The probe uses `head -c` (POSIX.1-2024, present on macOS); fine for the Mac-only host set.
- Discovery creates the `tmux-<uid>` socket directory if missing (any tmux command does);
  recorded in `PLAN.md` *Verified facts*.
- 3a decoder is more lenient than Python in two spots: invalid UTF-8 → U+FFFD, and a oneof member
  superseded by a later member is skipped undecoded (corruption inside it goes unreported).
- iTerm2 Python module 2.11 quirks (Activate sends `ignoring_other_apps=true` with any app
  option; `rpc.async_create_tab(command=…)` raises) — later phases must not rely on them.
- 3b: `authRejected` (401) and `notRunning` are covered only by hermetic tests (run rules forbid
  bogus cookies and quitting iTerm2). What a real tmux tab carries in `ListSessions` is
  unverified until Phase 4 (ordinary tabs: `tmux_window_id = "-1"`, no connection id). While a
  LaunchServices Automation prompt shows, the main thread waits on `NSAppleScript`.
- 3b: a cancelled request throws `CancellationError` without saying whether its frame was sent.
- 4a: `~/Library/Application Support/muxFinder` itself keeps any inherited ACL (only `launch/`
  and its files are stripped) — handle when Phase 7 writes `hosts.json` there.
- 4a: dev build products live in `.build/out/Products/Debug/` (`.build/debug` links there).
- **iTerm2 modal hazard (all later phases):** any tab the app or a test creates that ends within
  3 s of opening raises iTerm2's modal "session ended very soon after starting" warning, and
  the whole iTerm2 API then answers nothing until a person clicks OK (blocked this run once, in
  4b). The helper now holds every visible launch tab ≥10 s; Phase 5's ssh path must keep that
  (ssh failing fast must still end through the helper's hold).
- 4b: `muxfinder-probe detach` needs `--gateway` and always waits 10 s; an identity failure
  reports ~10 s after the tab opened; the app pays the 10 s wait for tabs opened before a
  restart. Phase 11's profile could silence the warning (product decision left open).
- 4c: `swift run muxfinder-probe` does not rebuild `muxfinder-launch`; run `swift build` before
  any real run or iTerm2 launches a stale helper (documented, no automatic guard).
- 4c: abort / failed-step / signal cleanup in `e2e-local` and recovery of a session created
  during cancellation have run only hermetically (an aborted real run was not risked).
- 4c: a user detach within 10 s of attaching leaves the launch window open until 10 s pass; a
  Ctrl-C in the instant between the failure prompt appearing and the wait arming is ignored;
  `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` is test-only by convention but would also apply to a
  real launch if present in iTerm2's environment.
- 5a: probe `attach` and `iterm2 attachments` send the read-only identity `display-message` to
  every tmux connection, the user's included; unattended, run them only when `iterm2
  list-connections` shows none of the user's (`e2e-local` filters to its own launch tabs).
- 5a: a non-UTF-8 control client whose host or socket path contains `_` or `:` stays unmapped
  (`nonUTF8`), so attaching that session can open a duplicate; a connection silent for 3 s does
  not block an attach either (duplicate only if it showed the same session).
- 5a: `focused` is published after activation (up to 5 s late if no tab appears yet); the
  owned-connection `detach` still counts tab age from the call.
- **iTerm2 API stall (all later real runs).** It happened in real `e2e-remote` run 3, step 10:
  GCD worker starvation in iTerm2 (64 workers in `NSAnimation _runBlocking`), no modal dialog
  as far as the read-only sample shows. It cleared within about two hours without a restart,
  and the three final-tree runs after it left iTerm2 at 14–18 threads, so no growth was seen.
  The cause is unknown. Before and after every real run, check `iterm2 status` and the thread
  count (read-only, `ps -M -p <pid> | wc -l`); stop as `BLOCKED` on a timeout or if the count
  keeps growing.
- 5b: the earlier real `e2e-remote` runs used the old still-waiting design. That design made
  one real login attempt per run to `saturno-m4` as `nonexistent-muxfinder`, three in total.
  The review flagged it as outside the run rules, and it is gone now.
- 5b: `withAwaitedTask` has no time limit of its own; it relies on the coordinator's 10 s
  request timeouts and cancellable sleeps. On macOS, `poll` reports `/dev/null` as unsupported,
  so the relay writes such devices directly.
- **iTerm2 thread ratchet (gates every real run).** Each real e2e run adds about 12 iTerm2
  threads (GCD workers stuck in `-[NSAnimation _runBlocking]`, the 5b stall pattern at 64).
  They decay with no restart, but slowly and unevenly: during 6a the count sat at 34–35 for
  over an hour, then was back to 15 about two hours later. The final-tree `e2e-remote` took
  it from 16 to 26. Restarting iTerm2 is the user's call, never the run's.
- 6a: name edge cases (`$…`, a client's terminal name, `#[`), the harness-only
  `NewSessionRequest.command`, the never-run-for-real probe `new-session`, and the
  "server not responding" class split — `docs/progress-archive/6a.md`.
- 7a: the 4a ACL risk is only partly closed (a launch request that creates the `muxFinder`
  directory first leaves its inherited ACL until the next host-list save); saves refuse a
  symlinked, non-regular or >16 MiB `hosts.json`; no fallback where `RENAME_SWAP` is
  unsupported; more in `docs/progress-archive/7a.md`.
- 7a: the 5b test `aSilentRemoteConnectionIsStale()` flaked about once in 18 runs (a wait-
  condition race); fixed with a cancelled-sleep count on `GatedAttachClock`, 20/20 runs since.
- 7b: `doesNotBlockTheMainActor` (Phase 1) failed 2 of 12 runs under load and is now a
  deterministic handshake; `keepsTrailingSemicolonsOnAPrivateServer` (6a) failed about 1 in 20
  under heavy load in the worker's runs, unseen in the orchestrator's 14 — look there first if
  the suite flakes. `refresh --once --attachments` never ran for real (it queries the user's
  iTerm2 tmux connections); remote sessions through the engine were not seen (Saturno had no
  server); more in `docs/progress-archive/7b.md`.
- 6b: a launch that never settles (a tab left waiting for a password) makes later conflicting
  calls for that session fail `earlierLaunchPending` until the tab ends or attaches; an
  `unknown` connection whose answer names another server or session does not block a move
  here. Thread growth per real run varies widely: the worker's `e2e-local` took iTerm2 from
  25 to 42 (it stayed near 40 for hours), the closure runs only 16 → 16 → 19.
- 8: the real popover (open, keys, Esc) never ran (needs a click; covered by model tests);
  `screencapture -l` fails while the screen is locked (in-app `--preview-snapshot` used); the
  worker deleted preference sets its own early preview runs created; a cancelled caller can
  still let one iTerm2 connection open (no request sent on it); `createsOnAPrivateServer()`
  (6a) failed once (`pane_current_path` race under load), then passed — look there first if the
  suite flakes. Details in `docs/progress-archive/8.md`.
- 9a: owed to a person (needs clicks): the real launch-at-login round trip on an installed
  bundle, the fix-it buttons opening System Settings, the window coming to the front, ⌘C/⌘V in
  its fields. Shutdown does not wait for a save already in progress; the changed-file banner
  has no preview fixture — `docs/progress-archive/9a.md`.
- 9b: the real ssh-setup round trip (tab, interactive ssh, hold) is **owed to the user**
  (Phase 10b decision: an interactive login on Saturno is outside the run rules; probe
  `ssh-setup --ssh <dest>` exists, but cannot close its own tab); a destination saved in
  Settings does not clear the popover's pending ssh-setup line; clicking through onboarding is
  owed to a person — `docs/progress-archive/9b.md`.
- 10a: Show tab is unverified against the real iTerm2 (local attaches never reach "still
  waiting"); the app's own Open asks every tmux connection (only the self-tests filter to their
  own tabs); a rename between the fresh listing and the attach is not caught; quit can take up
  to 15 s with an attach in flight; self-test cleanup kills nothing while an action is still
  running and prints the `tmux kill-session` to run — `docs/progress-archive/10a.md`.
- 10b: Show tab is still unverified for real; after keep mode the helper's `*.result.json`
  stays in the launch directory until the next launch's sweep (D14, 120 s TTL); the keep
  line's cleanup prints `tmux` without a path — `docs/progress-archive/10b.md`.
- 11b (11a's owed items, the rest confirmed by the real runs): still unverified — a non-modal
  "Dynamic Profiles Error" alert during the atomic write (needs a person's glance; the
  dot-file skip is seen only indirectly), the unknown-parent fallback, `-A` target-syntax
  cases on a real server, a login shell exiting within 3 s. iTerm2 went 22 → 35 threads over
  six runs (1–4 per run) — `docs/progress-archive/11b.md`.
- 11c: the parent-inheritance warning and the second-tab note are copy only (iTerm2 not run);
  owed to the user: a real Install / Remove from an installed bundle, making a profile the
  default, a second tab of the same profile, a launch after moving the app; an outside removal
  in the instant after the locked check reports `fileChanged` (nothing created) —
  `docs/progress-archive/11c.md`.
- 12a: `shellcheck` not installed (only `bash -n`); neither script has run on the real
  `/Applications`, `~/Applications`, `DynamicProfiles/` or support folder (a real install /
  uninstall is the user's, in `docs/MANUAL-CHECKLIST.md`); the README's Gatekeeper statement
  for quarantined copies is untried; the no-symlink rule holds in test mode only —
  `docs/progress-archive/12a.md`.

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
- Phase 13a: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix: the restore exchange could block past its 2 s bound (a live Return
  reader taking the reply; blocking writes). A review-fix worker fixed it (one deadline,
  non-blocking descriptors of its own, `TerminalReturnReader` joined before the final exchange),
  with two regressions that fail on the old code; re-verified, then `e2e-bury --local` 12/12;
  `docs/reviews/phase-13a.md`.
- Phase 13b: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 1
  blocker (a result taken by `detach` during an in-flight bury was dropped, so a failed
  post-bury restore stranded the tab), 2 should-fix (a stale attachment snapshot applied to a
  tab buried meanwhile; the e2e "left by itself" wait could be met by the 15 s recovery
  `Close`). One review-fix worker fixed all three, each regression failing with its fix
  reverted; re-verified — `docs/reviews/phase-13b.md`, summary in
  `docs/progress-archive/13b.md`.
- Phase 13c: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 2 should-fix: `e2e-bury` step 7 counted an ownership refusal as the bury race;
  step 11 accepted a killed child's tab that appeared once. A review-fix worker fixed both
  (real race, refusal reported and retried; `childSignaled(9)`, helper alive, tab visible past
  the minimum lifetime), with hermetic negative cases (`LaunchTabChecksTests`), then real
  reruns 13/13 on both hosts; re-verified — `docs/reviews/phase-13c.md`.

## Next action

1. **Start Phase 14** (`PLAN.md` *Phase 14*, "Popover readability", routine; hermetic UI work,
   no real run): select it, write its acceptance criteria, spawn one worker. Then the queued
   inbox phases I-1 (popover under the menu bar icon) and I-2 (New session directory picker,
   split I-2a / I-2b), in that order (table under *Completed*; add each to `PLAN.md` when it is
   selected; I-1's in-process `performClick(_:)` step needs the orchestrator's call against the
   no-UI-scripting rule). Then I-3 (global hotkey session switcher, I-3a / I-3b).
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
   `iterm2 list-sessions`). iTerm2 was at 17 threads after 13c's last run (2026-10-24 ~13:40).

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
- Integration proof (local and over SSH, final): `docs/INTEGRATION-PROOF.md`.
- Packaging (D27): `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/lib/app-copies.sh`,
  hermetic check `scripts/dev/test-install-scripts.sh`; app flag `--remove-persistent-profiles`
  (`Sources/MuxFinderCore/Profiles/PersistentProfileRemoval.swift`). User docs: `README.md`,
  `docs/ARCHITECTURE.md`, `docs/MANUAL-CHECKLIST.md`, matrix at the top of `docs/TESTING.md`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (latest; earlier phases' are in their archives)

- Phase 13c (final tree, orchestrator, 2026-10-24): `swift build` exit 0; `swift test` 745
  core tests in 74 suites + 166 UI tests in 14 suites passed (one load flake, see *Open
  risks*); `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0,
  `codesign --verify --deep --strict build/muxFinder.app` exit 0. Real runs (workers, gated):
  as in *Acceptance* — `docs/progress-archive/13c.md`.
- Phases 1–13b: each phase's final-tree verification is in `docs/progress-archive/<phase>.md`.

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
- Phase 13c: the commit after `bd9aed6` (code, tests, docs, review, archive and checkpoint);
  its SHA and push result are in the run's final status line.
