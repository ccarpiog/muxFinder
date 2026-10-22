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

## Current phase

**None in flight. Phase 5 is split into 5a and 5b (`PLAN.md` "### Phase 5", *Split*); 5a is
complete, 5b is next.** `muxfinder-probe iterm2 status` connects (exit 0, last checked
2026-10-22 10:35, after the final `e2e-local` run).

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
  and lint pass. Evidence in `docs/progress-archive/5a.md` and *Verification* below.

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

## Next action

1. `swift build`, then check `.build/debug/muxfinder-probe iterm2 status` connects (exit 0). If
   it times out (exit 75), iTerm2 is blocked by a modal: stop as `BLOCKED`, never UI-script.
   Check `.build/debug/muxfinder-probe discover --ssh saturno-m4` answers; if Saturno is
   unreachable, record it and stop as `BLOCKED` rather than skipping the remote proof.
2. Start **Phase 5b — remote attach over SSH** (risk `high`) per `PLAN.md` "### Phase 5" and
   its *Split* paragraph: the remote path in the coordinator and the helper
   (`/usr/bin/ssh -t -- <dest> <D3 string>`, interactive, no BatchMode, the helper's 10 s hold
   kept when ssh fails fast), the 20 s budget to `confirmed` with `stillWaiting` past it,
   `AttachmentIndex` mapping for remote hosts and `detach(session:on:)` for them, and
   `muxfinder-probe e2e-remote saturno-m4` (create test session, discover, attach, tabs and
   splits, detach, survive, reattach, second attach focuses, cleanup; exit 0, run twice).
   Hermetic tests for the remote argv, the budget and `stillWaiting`. The worker reads D3, D4,
   D12, D14, D15, D16, *Verified facts*, Unattended-run rules, `docs/TESTING.md`,
   `docs/INTEGRATION-PROOF.md` and `docs/progress-archive/5a.md` *Consequences*. Remote: only
   `saturno-m4`, only `muxfinder-test-*` sessions, no remote file writes. Never let a created
   tab end within 3 s; give the e2e index a filter limited to the run's own launch tabs. One
   worker, then its own review.

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`.
- Core library: `Sources/MuxFinderCore/{Process,Shell,Config,Diagnostics,Tmux,ITerm2,Launch,Attach}/`.
- Launch helper: `Sources/muxfinder-launch/` (`muxfinder-launch attach <uuid>`).
- Attachment index: `Sources/MuxFinderCore/Attach/AttachmentIndex.swift` (D16).
- Probe CLI: `Sources/muxfinder-probe/` (`discover`, `iterm2 status | list-sessions |
  list-connections | list-profiles | attachments`, `attach --local --session`, `detach
  --connection --gateway`, `e2e-local`).
- Integration proof (local, final): `docs/INTEGRATION-PROOF.md`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (Phase 5a, final tree after the review fixes)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 382 tests in 36 suites.
- `swift format lint -r Sources Tests` → exit 0, no output.
- `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` → exit 0, 10 of 10 PASS in 42.2 s
  (focus existing 89 ms, detach by session 10.0 s).
- `.build/debug/muxfinder-probe iterm2 status` → exit 0 (connected, protocol 1.21);
  `iterm2 list-connections` → 0 before the run.
- `tmux -u ls` → no server running; launch directory empty, no `test-mode` marker; no
  `/private/tmp/mfx.*` left.

## Git state

- Phase 1: `bb086c9`, pushed. Phase 2: `c1ee43d`, pushed. Phase 3a: `745e36e`, pushed.
  Phase 3b: `0d3b65f`, pushed.
- Phase 4a: `1f5a3be`, pushed.
- Phase 4b: `f888a2c`, pushed.
- Phase 4c: `e631641`, pushed.
- Phase 5a committed on `main` as `5b47e14` (parent `a2ee915`), pushed to `origin/main`
  (`a2ee915..5b47e14`, success). This SHA/push record is a follow-up checkpoint commit on top;
  tree clean after it. From 3b on, commit messages carry no AI attribution trailer (user's
  global rule); earlier pushed commits are left as they are.
