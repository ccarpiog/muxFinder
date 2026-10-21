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

## Current phase

None in progress. Phase 3 is split into 3a and 3b (recorded in `PLAN.md` "### Phase 3"); 3a
closed, 3b not started.

## Acceptance

- Phase 1: all criteria met; evidence in `docs/progress-archive/1.md`.
- Phase 2: all criteria met (fixture, hostile-name, malformed-input and classifier tests; every
  real check in `docs/TESTING.md` observed as specified; no leftover sessions). Evidence in
  `docs/progress-archive/2.md`.
- Phase 3a: all criteria met (byte-for-byte request encodings against `api_pb2` fixtures,
  response decodes, malformed-input typed errors, no fixture drift on regeneration, synthetic
  values only). Evidence in `docs/progress-archive/3a.md` and *Verification* below.

## Decisions

- Phase 1 decisions: `docs/progress-archive/1.md`.
- Phase 2: new **D12** (`tmux -u` on every tmux call — without a UTF-8 locale tmux mangles
  non-ASCII and tab separators); D3, D5 and D11 edited in `PLAN.md`; details in
  `docs/progress-archive/2.md`.
- Phase 3a: Phase 3 split into 3a/3b; proto2 merge semantics and oneof last-member-wins in the
  decoder; decoder leniency choices; Python module quirks — all in `docs/progress-archive/3a.md`.

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
  option; `rpc.async_create_tab(command=…)` raises) — 3b must not rely on them.

## Reviews

- Phase 1: Codex → `ship-with-fixes`, 0 blockers, 1 should-fix fixed; `docs/reviews/phase-1.md`.
- Phase 2: Codex → `ship-with-fixes`, 0 blockers, 3 should-fix (unbounded in-shell stderr
  capture, cancelled-task test cleanup, strict harness inheriting `ControlPath`) — all fixed by
  a fix worker with regression tests and re-verified; `docs/reviews/phase-2.md`.
- Phase 3a: Codex → `ship-with-fixes`, 0 blockers, 2 should-fix (unknown fields replacing a
  decoded envelope response; repeated embedded messages not merged per proto2) — both fixed by a
  fix worker with reference-backed regression fixtures and re-verified; `docs/reviews/phase-3a.md`.

## Next action

Start **Phase 3b — iTerm2 transport and client** (risk `high`) per `PLAN.md` "### Phase 3"
(its "Split" paragraph assigns 3b the WebSocket client, `CookieProvider`, lifecycle and error
cases, `ITerm2APIClient`, `ITerm2Integration` + `FakeITerm2Integration`, the `muxfinder-probe
iterm2 …` subcommands and the real checks). Read only that section plus the shared sections
(Architecture, Decisions — D1 — Verified facts, Unattended-run rules); the 3a codec and messages
live in `Sources/MuxFinderCore/ITerm2/`. Spawn one worker.

## Key paths

- Plan: `PLAN.md`; brief: `docs/REQUIREMENTS.md`; conventions: `CLAUDE.md`; real checks:
  `docs/TESTING.md`.
- Core library: `Sources/MuxFinderCore/{Process,Shell,Config,Diagnostics,Tmux,ITerm2}/`.
- Probe CLI: `Sources/muxfinder-probe/` (`discover`).
- Tests: `Tests/MuxFinderCoreTests/` (fixtures in `Fixtures/discovery/`, `Fixtures/iterm2/`).
- iTerm2 fixture generator (dev only, `-I`): `scripts/dev/gen-iterm2-fixtures.py`.
- Reviews: `docs/reviews/`; archive: `docs/progress-archive/`.

## Verification (Phase 3a, final tree)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 137 tests in 14 suites.
- `swift format lint -r Sources Tests` → exit 0, no output.
- `"$HOME/Library/Application Support/iTerm2/iterm2env-3.14/versions/3.14.0/bin/python3" -I
  scripts/dev/gen-iterm2-fixtures.py` then `diff -r` against a snapshot → no drift (31 files).

## Git state

- Phase 1: `bb086c9`, pushed. Phase 2: `c1ee43d`, pushed.
- Phase 3a committed on `main` as `745e36e` (parent `19db777`), pushed to `origin/main`
  (`19db777..745e36e`, success). This SHA/push record is a follow-up checkpoint commit on top.
  Tree clean after it.
