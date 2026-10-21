# muxFinder progress checkpoint

Live head of the `/autoclaude-opus` run over `PLAN.md`. Closed phases keep one row here; their
narrative lives in `docs/progress-archive/<phase-id>.md`. `PROGRESS.json` is derived from this
file.

## Completed

| Phase | Title | Risk | Worker model | Review | Narrative |
|---|---|---|---|---|---|
| 1 | Package skeleton, process runner, quoting and validation | routine | opus | Codex, ship-with-fixes, `docs/reviews/phase-1.md` | `docs/progress-archive/1.md` |
| 2 | tmux discovery: probe, parser, identity, error classification | high | opus (impl + fix worker) | Codex, ship-with-fixes, `docs/reviews/phase-2.md` | `docs/progress-archive/2.md` |

## Current phase

None in progress. Phase 2 closed; Phase 3 not started.

## Acceptance

- Phase 1: all criteria met; evidence in `docs/progress-archive/1.md`.
- Phase 2: all criteria met (fixture, hostile-name, malformed-input and classifier tests; every
  real check in `docs/TESTING.md` observed as specified; no leftover sessions). Evidence in
  `docs/progress-archive/2.md` and *Verification* below.

## Decisions

- Phase 1 decisions: `docs/progress-archive/1.md`.
- Phase 2: new **D12** (`tmux -u` on every tmux call — without a UTF-8 locale tmux mangles
  non-ASCII and tab separators); D3, D5 and D11 edited in `PLAN.md`; details in
  `docs/progress-archive/2.md`.

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

## Reviews

- Phase 1: Codex → `ship-with-fixes`, 0 blockers, 1 should-fix fixed; `docs/reviews/phase-1.md`.
- Phase 2: Codex → `ship-with-fixes`, 0 blockers, 3 should-fix (unbounded in-shell stderr
  capture, cancelled-task test cleanup, strict harness inheriting `ControlPath`) — all fixed by
  a fix worker with regression tests and re-verified; `docs/reviews/phase-2.md`.

## Next action

Start **Phase 3 — Native iTerm2 API client** (risk `high`) per `PLAN.md` "### Phase 3". Read
only that section plus the shared sections (Architecture, Decisions — especially D1: hand-written
client, no SwiftProtobuf, never copy iTerm2's Python module — Verified facts, Unattended-run
rules); spawn one worker.

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`.
- Core library: `Sources/MuxFinderCore/{Process,Shell,Config,Diagnostics,Tmux}/`.
- Probe CLI: `Sources/muxfinder-probe/` (`discover`).
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`).
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (Phase 2, final tree)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 101 tests in 11 suites.
- `swift format lint -r Sources Tests` → exit 0, no output.
- `swift run muxfinder-probe discover --ssh saturno-m4 --strict-known-hosts <empty temp file>`
  → `hostKeyProblem(unknown)`; `discover --ssh saturno-m4` → `noServer`.

## Git state

- Phase 1: `bb086c9`, pushed. Phase 2: committed on `main` with this checkpoint; its SHA and
  push result are recorded in the follow-up checkpoint commit (or in `PROGRESS.json`'s
  `commit` field) — see `git log`.
