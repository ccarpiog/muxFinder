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
| 7a | Host configuration: `HostStore`, invariants, defaults, SSH config suggestions | routine | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-7a.md` | `docs/progress-archive/7a.md` |
| 7b | Refresh engine: `RefreshCoordinator`, `HostSnapshot`, attachment merge, `refresh --once` | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-7b.md` | `docs/progress-archive/7b.md` |

## Current phase

None in progress. Phase 7b (refresh engine) closed; Phases 1–7b are done. Next: **Phase 6b —
Move here** if iTerm2's thread count allows, else **Phase 8** (*Next action*). Phase 6 was split
into 6a/6b and Phase 7 into 7a/7b in `PLAN.md`; 6b is the only earlier phase still queued.

## Acceptance

- Phase 1: all criteria met; evidence in `docs/progress-archive/1.md`.
- Phase 2: all criteria met (fixture, hostile-name, malformed-input and classifier tests; every
  real check in `docs/TESTING.md` observed as specified; no leftover sessions). Evidence in
  `docs/progress-archive/2.md`.
- Phase 3a: all criteria met (byte-for-byte request encodings against `api_pb2` fixtures,
  response decodes, malformed-input typed errors, no fixture drift on regeneration, synthetic
  values only). Evidence in `docs/progress-archive/3a.md`.
- Phase 3b: all criteria met (hermetic fake-socket tests for fragmentation, partial reads,
  ping/pong, close, 16 MiB cap, timeouts, id matching; live `iterm2 status`, `list-connections`,
  `list-sessions`, `list-profiles` exit 0 with no prompt; nothing in iTerm2 or tmux touched).
  Evidence in `docs/progress-archive/3b.md`.
- Phase 4a: all criteria met (0700 dir / 0600 files / TTL / delete-on-read / ACL stripping
  asserted by tests; guard gone, changed, tmux-missing, no-server, stalled-check and signal
  cases against real tmux on a private `TMUX_TMPDIR`; data only as argv; nothing in iTerm2 or
  the user's tmux touched). Evidence in `docs/progress-archive/4a.md`.
- Phase 4b (acceptance narrowed by the 4b/4c split): coordinator with distinct states,
  single-flight, typed failures, owned-connection detach and a 10 s minimum launch-tab age, all
  covered by hermetic tests; probe `attach`, `detach`, `e2e-local` built; draft
  `docs/INTEGRATION-PROOF.md`; build, 339 tests and lint pass — met. The two passing real
  `e2e-local` runs were **not** met and are Phase 4c's acceptance. Evidence in
  `docs/progress-archive/4b.md`.
- Phase 4c: all criteria met — `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` exit 0
  with 9/9 PASS in four separate real runs (two by the worker, two by the orchestrator, the last
  on the final tree after the review fix); `iterm2 status` exit 0 after each; no leftover test
  session, launch file or marker; `docs/INTEGRATION-PROOF.md` final; build, 346 tests and lint
  pass. Evidence in `docs/progress-archive/4c.md`.
- Phase 5a: all criteria met — hermetic tests for mapped, unknown, ambiguous, stale and
  `nonUTF8` connections, the per-connection timeout, the focus path, index failure and
  `detach(session:on:)`; real `e2e-local` exit 0 with 10/10 PASS including focus existing (no
  tab or window opened) in five runs, the last on the final tree; no leftovers; build, 382 tests
  and lint pass. Evidence in `docs/progress-archive/5a.md`.
- Phase 5b: all criteria met — hermetic tests for the remote argv/D3 string, the 20 s budget,
  `stillWaiting`, remote index mapping, remote detach and focus, the ssh-fails-fast hold and
  the test launch delay; on the final tree `e2e-remote saturno-m4` exit 0 with 11/11 PASS
  twice (focus existing included, step 10 with no login) and `e2e-local` 10/10 PASS; no
  leftovers; build, 427 tests and lint pass. Evidence in `docs/progress-archive/5b.md`.
- Phase 6a: all criteria met — hermetic create/collision/name/ssh-class tests; real
  `e2e-local` 15/15 and `e2e-remote saturno-m4` 16/16 on the final tree; no leftovers.
  Evidence in `docs/progress-archive/6a.md`.
- Phase 7a: all criteria met — hermetic tests for the round trip, 0600/0700 with ACLs
  stripped, load writing nothing, backups of invalid and concurrently replaced files (fail on
  the old code), the This Mac switch, defaults and every suggestion rule; real read-only `hosts
  show` / `hosts suggestions` left the support directory and `~/.ssh` unchanged; build, 505
  tests and lint pass. Evidence in `docs/progress-archive/7a.md`.
- Phase 7b: all criteria met — every plan test (slow host, coalescing, late stale result,
  config edit and removed host, backoff, stale marking, no leaked tasks or processes after
  `stop()` with a real process group, same name on two hosts) plus limit 3, sleep/wake, network
  change, attachment merge and the three review regressions; real final-tree `refresh --once`
  against a private This Mac + Saturno `hosts.json` exit 0, both `live`; build, 534 tests and
  lint pass. Evidence in `docs/progress-archive/7b.md`.

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

## Reviews

- Phase 1: Codex → `ship-with-fixes`, 0 blockers, 1 should-fix fixed; `docs/reviews/phase-1.md`.
- Phase 2: Codex → `ship-with-fixes`, 0 blockers, 3 should-fix (unbounded in-shell stderr
  capture, cancelled-task test cleanup, strict harness inheriting `ControlPath`) — all fixed by
  a fix worker with regression tests and re-verified; `docs/reviews/phase-2.md`.
- Phase 3a: Codex → `ship-with-fixes`, 0 blockers, 2 should-fix (unknown fields replacing a
  decoded envelope response; repeated embedded messages not merged per proto2) — both fixed by a
  fix worker with reference-backed regression fixtures and re-verified; `docs/reviews/phase-3a.md`.
- Phase 3b: Codex → `ship-with-fixes`, 1 blocker (cancelled/expired requests still sent later),
  2 should-fix (`disconnect()` ignoring an in-flight connect; malformed close payloads accepted)
  — all fixed by a fix worker with deterministic regression tests and re-verified;
  `docs/reviews/phase-3b.md`.
- Phase 4a: Codex → `ship-with-fixes`, 1 blocker (extended ACLs bypass the 0700/0600
  boundary), 2 should-fix (forwarded signals orphan guard subprocesses; unbounded pre-attach
  checks) — all fixed by a fix worker (ACL stripping/refusal; two-child design with a 10 s
  process-group-bounded check, then tmux spawned directly) with regression tests and
  re-verified; `docs/reviews/phase-4a.md`.
- Phase 4b: Codex → `ship-with-fixes`, 3 blockers (identity-failure detach bypassing a minimum
  tab age; detach by cached short connection id could hit a user attachment after an iTerm2
  restart; harness rediscovery by `$id` alone could target a user session), 2 should-fix (an
  older cancelled flight overwriting newer state; cancellation during `new-session` skipping
  cleanup) — all fixed by a fix worker with regression tests and re-verified;
  `docs/reviews/phase-4b.md`.
- Phase 4c: Codex → `ship-with-fixes`, 0 blockers, 1 should-fix (SIGINT/SIGTERM bypassed the
  helper's 10 s minimum lifetime) — fixed by a fix worker (only SIGHUP restored to default in
  the waits; `LaunchWaitGate`; new pseudo-terminal suite that fails on the old behavior),
  re-verified with a fourth real `e2e-local` run; `docs/reviews/phase-4c.md`.
- Phase 5a: Codex → `ship-with-fixes`, 1 blocker (unknown tab age measured from call entry, so
  a tab created during discovery could be detached seconds after opening), 2 should-fix
  (identity assumed tab separators survive non-UTF-8 clients; focus activated by the reusable
  connection id alone) — all fixed by a fix worker with regressions that fail on the old
  behavior, re-verified with a real `e2e-local` run on the final tree; `docs/reviews/phase-5a.md`.
- Phase 5b: Codex → `ship-with-fixes`, 0 blockers, 3 should-fix: unbounded stderr pumping and
  blocking terminal writes in `TerminalChildRunner`; the still-waiting step not awaiting its
  attach before cleanup; the real invalid-user login. A fix worker fixed all three: a bounded,
  non-blocking relay; `withAwaitedTask`; and the test-mode launch delay. Each fix has
  regressions (the relay and await tests fail on the old code; the delay tests cover new
  behavior). Re-verified hermetically, then with three real runs on the final tree once
  iTerm2's API answered again; `docs/reviews/phase-5b.md`.
- Phase 6a: Codex → `ship-with-fixes`, 1 blocker (the harness's identity check and kill were
  separate tmux calls, so a restarted server reusing `$N` could lose a user session), 2
  should-fix (a trailing `;` is a tmux command separator even in argv; ssh exit 255 after a
  successful create reported as "nothing created"). A fix worker fixed all three: one
  `if-shell -F` check-and-kill, `\;` escaping in the static script, a `connectionLost` class.
  Regressions fail on the old code; private tmux server checks reproduced the `$0` reuse race
  and the `work;` mis-parse. Re-verified hermetically and with real final-tree `e2e-local`
  and `e2e-remote` runs. `docs/reviews/phase-6a.md`.
- Phase 7a: Codex → `ship-with-fixes`, 1 blocker (a save examined and backed up `hosts.json`,
  then renamed over it unconditionally, so a file replaced in between was lost) — fixed by a
  fix worker (swap publication, the displaced file kept), six regressions that fail on the old
  code, re-verified; `docs/reviews/phase-7a.md`.
- Phase 7b: Codex → `ship-with-fixes`, 0 blockers, 3 should-fix (sleep let a suspended
  `refreshOnce` round submit its attachment check; an edited host's retired probe did not block
  a second probe for the same host; `RefreshSystemEvents` start/stop could leave observers
  installed) — all fixed by a fix worker (work epoch, retired probes in the per-host guard,
  generation under a lock), each regression failing on the old code, re-verified;
  `docs/reviews/phase-7b.md`.

## Next action

1. **Phase 6b — Move here** (`PLAN.md` "### Phase 6", the *Split* 6b bullet; risk `high`),
   which opens real iTerm2 windows. First check iTerm2's thread count (item 3): run 6b's real
   checks only at **25 or lower**. If it stays above 25, run **Phase 8** (menu bar app and
   popover, `PLAN.md` "### Phase 8"; routine; no real iTerm2 windows; it consumes D20's
   `RefreshCoordinator.updates()` and wires `RefreshSystemEvents`) meanwhile. If nothing
   window-free is left and the count is still above 25, stop as `BLOCKED` and ask the user
   whether to restart iTerm2 or accept a higher baseline.
2. Then whichever of 6b and 8 is left, then Phase 9.
3. Before and after every real run: `swift build` first, then
   `.build/debug/muxfinder-probe iterm2 status` (exit 0, or stop as `BLOCKED`) and iTerm2's
   thread count, read-only: `ps -M -p <pid> | wc -l`, with the pid from
   `ps -axo pid,comm | rg 'MacOS/iTerm2$'` (`pgrep -x iTerm2` finds nothing on this Mac). Stop
   if `status` times out or the count keeps growing across runs (*Open risks*, iTerm2 thread
   ratchet). Leftover checks: `ls -A` of the launch directory, `ls -A /private/tmp | rg
   '^mfx\.'`, and `muxfinder-test-*` sessions on Neptuno and Saturno (`fd` is not installed).

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

- Phase 7b (final tree): `swift build -Xswiftc -warnings-as-errors` exit 0; `swift format lint
  -r Sources Tests` exit 0; `swift test` exit 0, 534 tests in 52 suites, 6 consecutive runs;
  real `env -u TMUX_TMPDIR swift run muxfinder-probe refresh --once --config
  <mktemp dir>/hosts.json` exit 0, both hosts `live` (`noServer`); private folder removed, no
  `/private/tmp/mfx.*` left — `docs/progress-archive/7b.md`.

## Git state

- Phase 1: `bb086c9`, pushed. Phase 2: `c1ee43d`, pushed. Phase 3a: `745e36e`, pushed.
  Phase 3b: `0d3b65f`, pushed.
- Phase 4a: `1f5a3be`, pushed.
- Phase 4b: `f888a2c`, pushed.
- Phase 4c: `e631641`, pushed.
- Phase 5a: `5b47e14`, pushed. From 3b on, commit messages carry no AI attribution trailer
  (user's global rule); earlier pushed commits are left as they are.
- Phase 5b: code, review and fixes `6b1aedc` (parent `9a81b33`), pushed. Closing records
  (final-tree runs, archive, checkpoint) `dca1228` (parent `60d55ea`), pushed to `origin/main`
  (`60d55ea..dca1228`, success). This SHA/push record is a follow-up commit on top; tree clean
  after it.
- Phase 6a: code, review and fixes `0210999` (parent `96c6ac8`), pushed. Closing records
  (final-tree remote run, archive, checkpoint) `e0fcbdd` (parent `228f8da`), pushed to
  `origin/main`.
- Phase 7a: code, review fix and checkpoint `228f8da` (parent `7fda73e`), pushed to
  `origin/main` (`7fda73e..228f8da`, success).
- Phase 7b: code, review fixes and checkpoint in the commit after `e0fcbdd`; its SHA and push
  result are recorded by the next commit.
