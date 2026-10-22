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

## Current phase

None in progress. Phases 1–10b are done; next is **Phase 11** (*Next action*). Phase 6 was
split into 6a/6b, Phase 7 into 7a/7b, Phase 9 into 9a/9b and Phase 10 into 10a/10b in
`PLAN.md`.

## Acceptance

- Phases 1–9b: all criteria met, with the recorded deviations and the real runs owed to a
  person listed under *Open risks*; criteria and evidence in `docs/progress-archive/<phase>.md`.
- Phase 10a: all criteria met hermetically, the real self-test runs being 10b's — per-session
  state machine (5 clicks → 1 launch, focus when open here, confirmed only after the core),
  Show tab refusing tabs the app did not open, pairwise-distinct failure messages, Move here
  confirmation, Detach for this Mac only, New session sheet with a fresh-listing "Open
  existing", banners, `--selftest attach-local | new-session-local [--selftest-keep]` driver
  tests; 590 core + 138 UI tests, build, lint, bundle, codesign, shell check (no `hosts.json`);
  attach screenshots via `--preview-snapshot`. Evidence in `docs/progress-archive/10a.md`.
- Phase 10b: all criteria met — real `--selftest attach-local` exit 0 (6/6: 5 clicks → 1
  launch, focus, detach, kill) and `--selftest new-session-local` exit 0 (5/5); keep mode quit
  by SIGTERM exit 0 with the session and its iTerm2 connection still there, then cleaned up;
  iTerm2 threads 15 → 21, `iterm2 status` exit 0 throughout; no fix needed (590 core + 138 UI
  tests, lint). Evidence in `docs/progress-archive/10b.md`, records in `docs/TESTING.md`.

## Decisions

- Phase 1 decisions: `docs/progress-archive/1.md`.
- Phase 2: new **D12** (`tmux -u` on every tmux call — without a UTF-8 locale tmux mangles
  non-ASCII and tab separators); D3, D5 and D11 edited in `PLAN.md`; details in
  `docs/progress-archive/2.md`.
- Phase 3a: Phase 3 split into 3a/3b; proto2 merge semantics and oneof last-member-wins in the
  decoder; decoder leniency choices; Python module quirks — all in `docs/progress-archive/3a.md`.
- Phase 3b: new **D13** (requests never retried automatically; `notSent(reason)` = frame never
  written, safe to retry; plain error = outcome unknown); `authRejected` = HTTP 401 per the
  Python module; connection-attempt generations — details in `docs/progress-archive/3b.md`.
- Phase 4a: Phase 4 split into 4a/4b; D4 edited (guard reads
  `#{session_id}:#{pid}:#{start_time}:#{session_created}`; check-then-attach window); new
  **D14** (launch protocol: exit codes 64/65/66/73/75/128+n, file and ACL rules, two-child
  check-then-attach design, signal handling, test-mode argv digest) — `docs/progress-archive/4a.md`.
- Phase 4b: 4b split again into 4b (code) and 4c (real proof), because iTerm2 is blocked until
  a person dismisses its warning; new **D15** (attach coordinator: launch tab in a new window,
  seams, single flight with generations, failure handling, identity command, activation without
  `select_session`, owned-connection commands, 10 s minimum launch-tab age before any
  `detach-client`) — `docs/progress-archive/4b.md`.
- Phase 4c: D14 edited — the helper never exits before it is 10 s old while its tab is visible
  (result written first); during that hold and the failure prompt only SIGHUP ends it, SIGINT/
  SIGTERM end the prompt like Return but not the hold; test-only
  `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS`. D15 and *Verified facts* edited with the real
  behavior (iTerm2 warning threshold 3 s, `Command` split into 3 argv, each tmux window opens as
  its own iTerm2 window) — `docs/progress-archive/4c.md`.
- Phase 5: split into 5a (local detection, focus, detach by session) and 5b (remote attach over
  SSH), recorded in `PLAN.md` before the first worker.
- Phase 5a: new **D16** (attachment index: host/socket/pid/start-time matching, unmapped kinds,
  3 s per-connection timeout, owner-bound focus, index-failure policy, `detach(session:on:)`,
  e2e filter to the run's own connections); identity line now
  `#{client_utf8}:#{n:host}:#{host}:…` with length prefixes; D12, D15, *Verified facts* edited
  — `docs/progress-archive/5a.md`.
- Phase 5b: new **D17**, the remote attach design. It covers ssh argv with `ConnectTimeout=10`
  and no BatchMode, the remote guard then `exec` tmux, exit 255 classified from relayed stderr,
  the 20 s budget, `stillWaiting` with a once-a-second watch that may still confirm, and
  `waitLimitReached` at 300 s. The remote check has no deadline of its own (a hang shows as
  `stillWaiting`). The stderr relay is bounded at 64 KiB per round with non-blocking writes;
  excess goes undisplayed but stays in the 16 KiB capture. Also in D17: the test-mode-only
  `testLaunchDelaySeconds` (1–120). D14, D15, D16 and *Verified facts* edited (iTerm2 ends ssh
  about 5.2 s after a forced close, so the coordinator waits 10 s for the helper's result after
  a waiting tab closes). The new `withAwaitedTask` cancels and awaits an unstructured task on
  every exit — `docs/progress-archive/5b.md`.
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

## Reviews

- Phases 1–7b: Codex reviewed each (`ship-with-fixes`); blockers and should-fix items and their
  fixes (each regression failing on the old code) are summarized in
  `docs/progress-archive/<phase>.md`, reports in `docs/reviews/phase-<phase>.md`.
- Phase 6b: Codex → `ship-with-fixes`, 2 blockers (failed identification bypassed the
  already-attached check, so `-d` could detach this Mac's own connection; a cancelled move
  could run after a newer attach), 0 should-fix — both fixed by a fix worker
  (`possiblyAttachedHere`; proof-based launch tracking with a bounded wait), each regression
  failing on the old code, re-verified hermetically, then by the real final-tree runs;
  `docs/reviews/phase-6b.md`.
- Phase 8: Codex → `ship-with-fixes`, 1 blocker (closing the popover did not cancel a pending
  attachment pass, so cookie/connection/identity requests could reach iTerm2 after close), 0
  should-fix — fixed by a fix worker (engine cancels the pass and drops its follow-up; client
  attempt stops before cookie and connect when all callers cancelled; index checks
  cancellation), 8 regressions (7 fail on the old code, the 8th guards against a second
  cookie), re-verified; `docs/reviews/phase-8.md`.

- Phase 9a: Codex → `ship-with-fixes`, 1 blocker (Settings saved over a `hosts.json` changed
  since it loaded, even malformed, without Replace consent), 3 should-fix (Settings probes
  escaped app shutdown; closing during the window's opening let profile loading go on; a slow
  removal reset a newer selection and draft) — all fixed by a fix worker (`save(_:expecting:)`
  with a changed-file banner, `SettingsModel.shutdown()`, an owned and cancelled opening task
  with window generations, preserve-on-remove), five regressions failing on the old code,
  re-verified; `docs/reviews/phase-9a.md`.
- Phase 9b: Codex → `ship-with-fixes`, 0 blockers, 2 should-fix (closing a window dropped
  in-flight ssh-setup task handles so quit could not await them; an edit during an opening
  request let the old destination's result show under the edited host) — both fixed by a fix
  worker (requests owned until they end and awaited on quit; per-host request link dropped on
  edit/close), each regression failing on the old code, re-verified;
  `docs/reviews/phase-9b.md`.
- Phase 10a: Codex → `ship-with-fixes`, 1 blocker (shutdown awaited session actions before
  stopping other subsystems, so the 5 s reply could cut cleanup off silently), 3 should-fix (a
  new session's live progress and Show tab were dropped; a failed activation showed as focus;
  "Open existing" trusted a cached name) — all fixed by a fix worker (concurrent bounded
  shutdown with a 15 s deadline; created-session hook; distinct activation-failure message;
  fresh exact-name lookup), each regression failing with the fix reverted, re-verified;
  `docs/reviews/phase-10a.md`.
- Phase 10b: Codex → `ship`, 0 findings (records match the code; keep mode quits through
  `AppTermination`/`AppModel.shutdown`; all four launch paths sweep stale results);
  `docs/reviews/phase-10b.md`.

## Next action

1. **Phase 11** (Persistent Work profiles; `PLAN.md` "### Phase 11"; high). Read only that
   section and the decisions it touches (D3, D14, D22–D24). Split it **before the first
   worker**, recorded in `PLAN.md` like 6/7/9/10: **11a** hermetic (the `Profiles/` generator
   and atomic installer for the app-owned `DynamicProfiles/muxFinder.json`, helper mode
   `profile <hostUUID>` with the nesting guard and login-shell fallback, the Settings section
   and its copy, unit tests, the hash-identity check of other `DynamicProfiles/*` files and of
   `New Bookmarks` from `defaults export com.googlecode.iterm2 -` — read-only, never `defaults
   write`) and **11b** real (`ListProfiles` shows the GUID; `CreateTab(profile_name=…)` gets a
   confirmed control-mode connection to `muxfinder-test-profile` locally and on Saturno, then
   cleanup). The profile file is the only iTerm2 file the app may write (CLAUDE.md safety
   rules); never write iTerm2 preferences or other profiles.
2. Owed to the user, not to a run: the 9b "Set up SSH in iTerm2…" real round trip (an
   interactive ssh login on Saturno, outside the run rules). Phase 12's manual checklist must
   list it.
3. Before and after every real run: `swift build` first, then
   `.build/debug/muxfinder-probe iterm2 status` (exit 0, or stop as `BLOCKED`) and iTerm2's
   thread count, read-only: `ps -M -p <pid> | wc -l`, with the pid from
   `ps -axo pid,comm | rg 'MacOS/iTerm2$'` (`pgrep -x iTerm2` finds nothing on this Mac). Stop
   if `status` times out or the count keeps growing across runs (*Open risks*, iTerm2 thread
   ratchet). Leftover checks: `ls -A` of the launch directory, `ls -A /private/tmp | rg
   '^mfx\.'`, and `muxfinder-test-*` sessions on Neptuno and Saturno (`fd` is not installed).
   Real runs only with iTerm2 at **38 threads or lower**; if it stays above 38, stop as
   `BLOCKED` and ask the user whether to restart iTerm2 or accept a higher baseline. iTerm2
   was at 21 threads after Phase 10b's runs (2026-10-23 00:00).

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
- Probe CLI: `Sources/muxfinder-probe/` (`discover`, `iterm2 status | list-sessions |
  list-connections | list-profiles | attachments`, `attach --local|--ssh <dest> --session`,
  `detach --connection --gateway`, `e2e-local`, `e2e-remote <dest>`, `hosts show |
  suggestions`, `refresh --once`; shared harness
  `E2ERun.swift`).
- Integration proof (local and over SSH, final): `docs/INTEGRATION-PROOF.md`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (latest; earlier phases' are in their archives)

- Phase 10b (final tree, orchestrator): `swift build` exit 0; `scripts/build-app.sh` and
  `codesign --verify --deep --strict build/muxFinder.app` exit 0; `iterm2 status` exit 0
  before and after each run; `--selftest attach-local` exit 0 (6/6), `--selftest
  new-session-local` exit 0 (5/5), keep mode exit 0 after SIGTERM, cleanup detach and kill exit
  0; `swift format lint -r Sources Tests` exit 0; `swift test` (pipefail) exit 0, 590 core
  tests in 58 suites + 138 UI tests in 11 suites — `docs/progress-archive/10b.md`.

- Phase 10a (final tree, orchestrator): `swift build -Xswiftc -warnings-as-errors` exit 0;
  `swift format lint -r Sources Tests` exit 0; `swift test` (pipefail) exit 0, 590 core tests
  in 58 suites + 138 UI tests in 11 suites; `scripts/build-app.sh` and `codesign --verify
  --deep --strict build/muxFinder.app` exit 0; `--selftest bogus` exit 2; shell check SIGTERM
  exit 0, no child, support folder only `launch/` — `docs/progress-archive/10a.md`.

- Phases 1–9b: each phase's final-tree verification is in `docs/progress-archive/<phase>.md`.

## Git state

- All phases through 10a are committed and pushed to `origin/main`: 1 `bb086c9`, 2 `c1ee43d`,
  3a `745e36e`, 3b `0d3b65f`, 4a `1f5a3be`, 4b `f888a2c`, 4c `e631641`, 5a `5b47e14`, 5b
  `6b1aedc` + `dca1228`, 6a `0210999` + `e0fcbdd`, 7a `228f8da`, 7b `d512f47`, 6b `ce26808`
  (closure `cb855c0`, summary `880470f`), 8 `dc1935d`, 9a `ac1b9ee`, 9b `94cc960`, 10a
  `d6fe103` (parent `94cc960`, pushed, `origin/main` at `d6fe103` before Phase 10b). From 3b
  on, commit messages carry no AI attribution trailer (user's global rule).
- Phase 10b: real-run records, review and checkpoint: the commit after `d6fe103`; its SHA
  and push result are recorded by the next commit.
