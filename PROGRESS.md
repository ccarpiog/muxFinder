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

## Current phase

None in progress. Phases 1–12a are done; next is **Phase 12b**, the acceptance run (*Next
action*). Phase 6 was split into 6a/6b, 7 into 7a/7b, 9 into 9a/9b, 10 into 10a/10b, 11 into
11a/11b/11c and 12 into 12a/12b in `PLAN.md`.

## Acceptance

- Phases 1–11b: all criteria met, with the recorded deviations and the real runs owed to a
  person listed under *Open risks*; criteria and evidence in `docs/progress-archive/<phase>.md`.
- Phase 11c: all criteria met hermetically — host editor fields validated and round-tripped;
  Settings "Persistent profiles" tab with status, Install / Remove through the seam and the
  copy; automatic updates (normal-mode launch, after a save) only rewrite muxFinder's own
  installed file and never create it; gallery from fakes, screenshots regenerated; real
  `DynamicProfiles/` untouched (`profiles hashes` identical). 672 core + 158 UI tests.
  `docs/progress-archive/11c.md`.
- Phase 12a: all criteria met hermetically — `scripts/install.sh` / `uninstall.sh` with dry run
  and private-folder test overrides, `scripts/dev/test-install-scripts.sh` 35/35 PASS; clean
  `build/` reproduces a signed (Apple Development, not notarized) bundle; README,
  ARCHITECTURE, TESTING matrix (fresh-run column "owed" for 12b), MANUAL-CHECKLIST; real
  install locations, `DynamicProfiles/` and support folder untouched. 680 core + 159 UI tests.
  `docs/progress-archive/12a.md`.

## Decisions

- Phases 1–5b: splits (3 → 3a/3b, 4 → 4a/4b/4c, 5 → 5a/5b) and decisions **D12** (`tmux -u`
  everywhere), **D13** (no automatic request retries; `notSent` vs unknown outcome), **D14**
  (launch protocol, exit codes, 10 s helper hold), **D15** (attach coordinator), **D16**
  (attachment index) and **D17** (remote attach over ssh, `stillWaiting`, test launch delay),
  with edits to D3–D5 and D11 — each phase's details in `docs/progress-archive/<phase>.md`.
- Phase 6: split into 6a (new session, vanished sessions) and 6b (Move here), recorded in
  `PLAN.md` before the first worker. On Saturno the directory check uses an existing directory
  with a space and a missing Unicode one (no remote file writes).
- Phase 6a: new **D18** (session creation: static script, `has-session` then `new-session -d
  -P -F`, `#`/`;` escaping, ssh 255 classes, `createAndAttach` skipping the existing-attachment
  check, `if-shell -F` check-and-kill in the harness) — `docs/progress-archive/6a.md`.
- Phase 7: split into 7a (host configuration) and 7b (refresh engine), recorded in `PLAN.md`
  before the first worker; both run while 6a's remote check waits on iTerm2.
- Phase 7a: new **D19** (`hosts.json` schema v1; load never writes; publication by
  `RENAME_SWAP`/`RENAME_EXCL` with the *displaced* file kept as a backup unless it is valid and
  identical to what the store last loaded or wrote; This Mac switch demotes the previous one to
  SSH, disabled; suggestion rules). The launch layer's ACL/safe-write code moved to
  `Config/PrivateStorage.swift` and `Config/ExtendedACL.swift`, shared by both stores —
  `docs/progress-archive/7a.md`.
- Phase 7b: new **D20** (refresh engine: actor with `HostDiscovering`/`AttachClock`/
  `AttachmentIndexing` seams and an `updates()` stream; limit 3 with retired probes keeping
  their slot and blocking only their own host; one follow-up per busy host rather than joining;
  generation + revision + work-epoch discard; cadence and background-only backoff; attachment
  checks only while the popover is visible; probe `refresh --once` with opt-in
  `--attachments`) — `docs/progress-archive/7b.md`.
- Phase 6b: new **D21** (Move here: `MoveHereConfirmation.detachOtherClients(of:)`, request
  field `detachOtherClients`, static `moveHereScript` remotely, `alreadyAttachedHere` /
  `possiblyAttachedHere` refusals, proof-based tracking of launches that may still attach,
  `earlierLaunchPending` after the confirmation budget); D14–D17 edited —
  `docs/progress-archive/6b.md`.
- Phase 8: new **D22** (menu bar app: `MuxFinderUI` library + thin executable, `AppModel` over
  `AppEnvironment`, iTerm2/cookie only on popover open or attach, popover close cancels the
  attachment check, placeholder intents for Phases 9/10, quit via `AppTermination.request()`,
  preview fixtures with no menu bar item, helper bundled in `Contents/MacOS/`); D11, D13, D20
  edited — `docs/progress-archive/8.md`.
- Phase 9: split into 9a (Settings window) and 9b (onboarding and SSH setup), recorded in
  `PLAN.md` before the first worker.
- Phase 9a: new **D23** (Settings window: one reusable AppKit window, `SettingsEnvironment`
  seams, explicit Save/Revert drafts, This Mac demotion on save, changed-file and
  unusable-file banners with Reload/Replace, diagnostics by display name and id only, profiles
  never launch iTerm2, `--report-login-item-status`); D19 gained `save(_:expecting:)` (a save
  refuses a file changed since it was loaded); D22 edited — `docs/progress-archive/9a.md`.
- Phase 9b: new **D24** (onboarding only for `notSavedYet`, saved through
  `save(_:expecting:)`; `sshSetup` request kind, attach files unchanged; helper mode
  `ssh-setup` running `/usr/bin/ssh -- <dest>`, any exit but 255 a success; `LaunchTab`
  factored out of `AttachCoordinator`; `SSHSetupLauncher`); D14, D15, D22, D23 edited —
  `docs/progress-archive/9b.md`.
- Phase 10: split into 10a (attach UX, hermetic) and 10b (real self-tests), recorded in
  `PLAN.md` before the first worker.
- Phase 10a: new **D25** (attach UX: per-session state machine over the coordinator seam, row
  actions and in-popover panels, `showLaunchTab(_:)`, self-test design and safety, keep mode);
  D22 edited (placeholders gone; concurrent shutdown, session actions awaited at most 12 s,
  quit deadline 15 s, was 5 s); D18 edited (created-session hook on `createAndAttach`,
  `currentSession(named:on:)`) — `docs/progress-archive/10a.md`.
- Phase 10b: the orchestrator ran the real checks itself (no code changed); the 9b "Set up SSH
  in iTerm2…" real round trip is owed to the user, since an interactive ssh login on Saturno
  is outside the remote-host run rules — `docs/progress-archive/10b.md`.
- Phase 11: split into 11a (hermetic core, helper mode, probe), 11b (real profile runs) and
  11c (Settings section, launch-time rewrite), recorded in `PLAN.md` before the first worker;
  real runs come before the UI so the profile format meets iTerm2 first.
- Phase 11a: new **D26** (host fields `persistentProfileEnabled` / default session `main` /
  per-host parent, schema still 1; pure generator, `Command` refused for unsafe helper paths;
  installer with `flock` on `muxFinder/profiles.lock` and identity-checked rollback; helper
  `profile <host id>` with nesting guard, login-shell fallback, `MUXFINDER_LAUNCHED=1` set by
  every helper mode; test host list only in test mode for its own id; `e2e-profile` design);
  D8, D11, D14, D19 edited; session-name and ssh-destination checks now on Unicode scalars —
  `docs/progress-archive/11a.md`.
- Phase 11b: iTerm2 3.7.6 mirrors each loaded dynamic profile into its saved `New Bookmarks`
  and drops it ~0.25 s after the file goes (*Verified facts*, D26). The snapshot leaves out
  only a provable muxFinder mirror (generated GUID, exactly the owned `muxFinder.json` path,
  in the harness the run's GUID with every written key unchanged), counted in
  `excludedMuxFinderEntries`; step 1 waits 5 s for a stale mirror or fails; step 13 waits by
  an absolute 30 s deadline from the removal — `docs/progress-archive/11b.md`.
- Phase 11c: D26 gained the 11c rules — own Settings tab; "installed" is sticky (the app writes
  `muxFinder.json` only on "Install profiles" or over its own generated file, never creating
  it by itself); install from the saved list; a save while installed updates at once; launch
  rewrite only in normal mode with a saved list; `isGenerated(_:)` ownership check with
  `replaceGenerated` (button) and `updateExistingGenerated` (automatic) policies;
  operations capture their host list at the start — `docs/progress-archive/11c.md`.
- Phase 12: split into 12a (scripts and documents, hermetic) and 12b (acceptance run), recorded
  in `PLAN.md` before the first worker.
- Phase 12a: new **D27** (install/uninstall: `ditto` + verify + bound-identity rename swap;
  only a copy's own `muxFinder` is stopped, by SIGTERM, matched by the kernel's executable
  path, helpers left; profile file removed only through the bundled binary's
  `--remove-persistent-profiles`, run only on a copy declaring `MuxFinderScriptInterface 1`
  with a valid signature; preferences domain `cc.carpio.muxfinder` deleted only for real;
  test overrides confined to physical private folders) — `docs/progress-archive/12a.md`.

## Open risks / deviations

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
- Phase 11a: Codex → `ship-with-fixes`, 1 blocker (installer rollback could delete a newer
  concurrent update), 2 should-fix (`e2e-profile` cleanup could force-close a tab still holding
  a gateway; combining marks bypassed the leading target-character guard) — all fixed by a fix
  worker (cross-process `flock` + identity-checked rollback; reconcile and detach through
  bindings, never close a tab that may hold one; first-scalar check), each regression failing
  with its fix reverted, re-verified; `docs/reviews/phase-11a.md`.
- Phase 11b: Codex → `ship-with-fixes`, 0 blockers, 2 should-fix (the mirror exclusion was too
  loose; step 13's 30 s was not an absolute deadline) — both fixed by a review-fix worker
  (strict ownership rule; absolute deadline with capped exports and pauses), each regression
  failing with its fix reverted, then re-verified hermetically and by final-tree real runs 5
  and 6; `docs/reviews/phase-11b.md`.
- Phase 11c: Codex → `ship-with-fixes`, 1 blocker (a Settings reload during the after-save
  update could install an empty document and delete installed profiles), 1 should-fix
  (automatic updates could recreate a concurrently removed file) — both fixed by a review-fix
  worker (saved list carried into the update, lists captured at the press;
  `updateExistingGenerated` under the lock), each regression failing with its fix reverted,
  re-verified; `docs/reviews/phase-11c.md`.
- Phase 12a: Codex → `ship-with-fixes`, 3 blockers (mapped readers taken for running copies;
  test roots not containing destructive operations; deletion not bound to the inspected
  folder), 0 should-fix — all fixed by a review-fix worker (kernel executable check via
  `codesign -dv <pid>`; physical private roots and containment checks; device/inode-bound
  rename-aside before delete), each regression failing with its fix reverted, re-verified;
  `docs/reviews/phase-12a.md`.

## Next action

1. **Phase 12b** (acceptance run; routine, real runs; `PLAN.md` "### Phase 12", *Split*). On
   the final tree: `swift build`, `swift test`, `swift format lint -r Sources Tests`,
   `rm -rf build && scripts/build-app.sh` + `codesign --verify --deep --strict`,
   `scripts/dev/test-install-scripts.sh`, then the real runs one at a time with the item 2
   gate between them: `swift run muxfinder-probe e2e-local`, `e2e-remote saturno-m4`,
   `e2e-profile --local`, `e2e-profile --ssh saturno-m4`, and the self-tests
   `build/muxFinder.app/Contents/MacOS/muxFinder --selftest attach-local` and `--selftest
   new-session-local` (with `TMUX_TMPDIR` unset). Record date, command and exit status of each
   in `docs/TESTING.md`'s matrix ("12b fresh run" column, now "owed" on every row) and fix
   what the runs call for. Then Phase 12 is complete and the plan is done.
2. Before and after every real run: `swift build` first, then
   `.build/debug/muxfinder-probe iterm2 status` (exit 0, or stop as `BLOCKED`) and iTerm2's
   thread count, read-only: `ps -M -p <pid> | wc -l`, with the pid from
   `ps -axo pid,comm | rg 'MacOS/iTerm2$'` (`pgrep -x iTerm2` finds nothing on this Mac). Stop
   if `status` times out or the count keeps growing across runs (*Open risks*, iTerm2 thread
   ratchet). Leftover checks: `ls -A` of the launch directory and of `DynamicProfiles/`,
   `ls -A /private/tmp | rg '^mfx\.'`, and `muxfinder-test-*` sessions on Neptuno and Saturno
   (`fd` is not installed). Real runs only with iTerm2 at **38 threads or lower**; if it stays
   above 38, stop as `BLOCKED` and ask the user whether to restart iTerm2 or accept a higher
   baseline. iTerm2 was at 36 threads at 11c's close (2026-10-23 03:45); 12a ran no real check.
3. Owed to the user, not to a run: every item of `docs/MANUAL-CHECKLIST.md` (the 9b "Set up SSH
   in iTerm2…" round trip, a real install/uninstall, and the items *Open risks* lists).

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
- Integration proof (local and over SSH, final): `docs/INTEGRATION-PROOF.md`.
- Packaging (D27): `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/lib/app-copies.sh`,
  hermetic check `scripts/dev/test-install-scripts.sh`; app flag `--remove-persistent-profiles`
  (`Sources/MuxFinderCore/Profiles/PersistentProfileRemoval.swift`). User docs: `README.md`,
  `docs/ARCHITECTURE.md`, `docs/MANUAL-CHECKLIST.md`, matrix at the top of `docs/TESTING.md`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (latest; earlier phases' are in their archives)

- Phase 12a (final tree, orchestrator): `swift build -Xswiftc -warnings-as-errors` exit 0;
  `swift test` (pipefail) exit 0, 680 core tests in 67 suites + 159 UI tests in 13 suites;
  `swift format lint -r Sources Tests` exit 0; `bash -n` on all five scripts exit 0;
  `scripts/dev/test-install-scripts.sh` exit 0 (35/35 PASS); `rm -rf build &&
  scripts/build-app.sh` exit 0 and `codesign --verify --deep --strict build/muxFinder.app`
  exit 0; `profiles hashes` identical to the phase start — `docs/progress-archive/12a.md`.
- Phases 1–11c: each phase's final-tree verification is in `docs/progress-archive/<phase>.md`.

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
- Phase 12a: scripts, docs, D27, review and checkpoint: the commit after `930994e`; its SHA and
  push result are recorded by the next commit.
