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

## Current phase

**Phase 4c — real local proof: blocked on the user.** Phase 4 is split into 4a, 4b and 4c
(recorded in `PLAN.md` "### Phase 4"). 4a and 4b are complete. 4c has not started: e2e run 1
(in 4b) detached ~1 s after attaching, iTerm2 opened its modal "session ended very soon after
starting" warning in the launch window the test created, and while it is open iTerm2's API
answers nothing (`.build/debug/muxfinder-probe iterm2 status` → exit 75 `timedOut`, last checked
2026-10-22 01:39). Only a person can dismiss it; run rule 6 forbids UI scripting.

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
  `docs/progress-archive/4b.md` and *Verification* below.

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
- 4a: the helper has run only under a `script` pseudo-terminal on a private tmux server, never
  inside iTerm2; 4b's e2e run is the first real one. 4b must create the `launch/test-mode`
  marker through `LaunchStore.createTestModeMarker()` and remove it in cleanup.
- 4a: dev build products live in `.build/out/Products/Debug/` (`.build/debug` links there).
- 4b: **iTerm2 is blocked** by the short-lived-session warning in the launch window e2e run 1
  created (the only leftover; none of the user's windows were touched). Anything that ends a
  launch tab or detaches within seconds of opening it raises that modal again.
- 4b: the review-fix harness changes (owned-connection detach, full `CreatedSession` identity on
  rediscovery and kill, recovery of a session created during cancellation) are hermetically
  tested at the helper level only and have never run for real; 4c is their first real run.
- 4b: unverified whether discovery's socket path equals the one `new-session -P` prints; a
  mismatch makes 4c step 2 fail safely (nothing attached).
- 4b: `muxfinder-probe detach` needs `--gateway` and always waits 10 s; an identity failure
  reports ~10 s after the tab opened; the app pays the 10 s wait for tabs opened before a
  restart. Phase 11's profile could silence the warning (product decision left open).

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

## Next action

1. **User action (required first):** click OK on iTerm2's "session ended very soon after
   starting" warning in the launch window the e2e test opened (a window holding only that
   tab). Nothing else is needed from the user.
2. Check `.build/debug/muxfinder-probe iterm2 status` (after `swift build`) connects (exit 0).
   If it still times out, stop again as blocked; never use UI scripting.
3. Start **Phase 4c — real local proof** (risk `high`) per `PLAN.md` "### Phase 4" (the Split
   paragraph's 4c bullet, the `e2e-local` steps and the Acceptance line): run `swift run
   muxfinder-probe e2e-local` (with `TMUX_TMPDIR` unset) until it passes twice, fixing what the
   runs reveal; finalize `docs/INTEGRATION-PROOF.md` (versions, per-step timings, behaviors).
   Read D14, D15, "Verified in Phase 4b", Unattended-run rules, `docs/TESTING.md` and
   `docs/progress-archive/4b.md` *Consequences*. Only `muxfinder-test-*` sessions; never touch
   tabs the test did not create; nothing may detach or end a launch tab before it is 10 s old.
   Spawn one worker; its own review at the end.

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`.
- Core library: `Sources/MuxFinderCore/{Process,Shell,Config,Diagnostics,Tmux,ITerm2,Launch,Attach}/`.
- Launch helper: `Sources/muxfinder-launch/` (`muxfinder-launch attach <uuid>`).
- Probe CLI: `Sources/muxfinder-probe/` (`discover`, `iterm2 status | list-sessions |
  list-connections | list-profiles`, `attach --local --session`, `detach --connection
  --gateway`, `e2e-local`).
- Integration proof (draft until 4c): `docs/INTEGRATION-PROOF.md`.
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (Phase 4b, final tree after review fixes)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 339 tests in 33 suites.
- `swift format lint -r Sources Tests` → exit 0, no output.
- No `muxfinder-test-*` session on the default tmux server (no server running); launch
  directory empty, no `test-mode` marker.
- `.build/debug/muxfinder-probe iterm2 status` → exit 75 `timedOut` (iTerm2 blocked).

## Git state

- Phase 1: `bb086c9`, pushed. Phase 2: `c1ee43d`, pushed. Phase 3a: `745e36e`, pushed.
  Phase 3b: `0d3b65f`, pushed.
- Phase 4a committed on `main` as `1f5a3be` (parent `a70e94c`), pushed to `origin/main`
  (`a70e94c..1f5a3be`, success). This SHA/push record is a follow-up checkpoint commit on top;
  tree clean after it. From 3b on, commit messages carry no AI attribution trailer
  (user's global rule); earlier pushed commits are left as they are.
