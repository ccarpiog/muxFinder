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

## Current phase

None in progress. Phase 4 is split into 4a and 4b (recorded in `PLAN.md` "### Phase 4");
4a is complete, 4b not started.

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
  the user's tmux touched). Evidence in `docs/progress-archive/4a.md` and *Verification* below.

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

## Next action

Start **Phase 4b — attach coordinator and real local proof** (risk `high`) per `PLAN.md`
"### Phase 4" (the Split paragraph's 4b bullet plus the Requirements and `e2e-local` steps).
Read only that section plus the shared sections (Architecture, Decisions — D1, D2, D4, D13,
D14 — Verified facts, Unattended-run rules) and `docs/TESTING.md`. Building blocks:
`Sources/MuxFinderCore/Launch/` (store, guard, helper, failures), `ITerm2APIClient` in
`Sources/MuxFinderCore/ITerm2/`, the probe in `Sources/muxfinder-probe/`. The e2e run opens
real iTerm2 tabs: only `muxfinder-test-*` sessions, detach with `detach-client`, never touch
tabs the test did not create. Spawn one worker.

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`.
- Core library: `Sources/MuxFinderCore/{Process,Shell,Config,Diagnostics,Tmux,ITerm2,Launch}/`.
- Launch helper: `Sources/muxfinder-launch/` (`muxfinder-launch attach <uuid>`).
- Probe CLI: `Sources/muxfinder-probe/` (`discover`, `iterm2 status | list-sessions |
  list-connections | list-profiles`).
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (Phase 4a, final tree after review fixes)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 301 tests in 30 suites.
- `swift format lint -r Sources Tests` → exit 0, no output.
- No `muxfinder-test-*` session on the default tmux server (no server running).

## Git state

- Phase 1: `bb086c9`, pushed. Phase 2: `c1ee43d`, pushed. Phase 3a: `745e36e`, pushed.
  Phase 3b: `0d3b65f`, pushed.
- Phase 4a: committed on `main` on top of `a70e94c`; SHA and push result recorded by the
  follow-up checkpoint commit. From 3b on, commit messages carry no AI attribution trailer
  (user's global rule); earlier pushed commits are left as they are.
