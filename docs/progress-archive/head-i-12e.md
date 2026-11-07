# PROGRESS.md head lines for Phase I-12e (moved verbatim at I-13a, 2026-11-07)

## Acceptance

- Phase I-12e: all criteria met, 2026-11-07 — documents only (`git diff --stat -- Sources
  Tests Resources scripts` empty); `docs/REQUIREMENTS.md` 23 lines added, 0 removed;
  `docs/TERMINALS.md` covers every item of its call, the Ghostty sentence verbatim; its worked
  `exec` example loads through `terminals list --user-directory <private 0700 folder>` (source
  `user`, no problems); `pgrep -x Terminal` / `ghostty` none before and after; `swift build`
  and lint exit 0 — `docs/progress-archive/i-12e.md`.

## Decisions

- Phase I-12e: "Calls for I-12e" written in `PLAN.md` at selection (documents only, every fact
  from D38, the code or `--help`, one read-only probe run for the example); D38 gains "The docs
  (I-12e)"; the worked example is a fictional `exec` terminal (no real candidate installed) —
  `docs/progress-archive/i-12e.md`.

## Open risks / deviations

- I-12e: `terminals list --help` exits 64 after printing the usage (`terminals --help` 0; both
  contact nothing; code out of scope); `docs/TESTING.md`'s "Unit tests" row still points to
  Phase I-8's counts; onboarding on a Mac without iTerm2 is checklist 29 —
  `docs/progress-archive/i-12e.md`.

## Reviews

- Phase I-12e: Codex wrote the file (`autoclaude-review.sh`, 15 min) → `ship-with-fixes`, 0
  blockers + 1 should-fix (`docs/TERMINALS.md` said Open still opens in the chosen terminal for
  a session with a local client in another app; with a plain choice the backend brings that
  app forward and opens nothing); fixed inline by the orchestrator against
  `PlainTerminalBackend.swift` — `docs/reviews/phase-I-12e.md`.

## Verification

- Phase I-12e (final tree, orchestrator, 2026-11-07): `git diff --stat -- Sources Tests
  Resources scripts` empty; `swift build` exit 0; `swift format lint -r Sources Tests` exit 0;
  no test suite run (no code, test or resource changed; the last full run, I-12d2's: 1183 core
  + 548 UI pass) — `docs/progress-archive/i-12e.md`.

## Git state

- Phase I-12e: the commit carrying this checkpoint ("Phase I-12e: other terminals, the docs"),
  pushed (SHA and push result in the run's status line and the next checkpoint). The tree was
  clean when this iteration started (empty preflight file).
