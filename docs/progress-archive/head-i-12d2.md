# Head lines of Phase I-12d2, moved verbatim from `PROGRESS.md` (2026-11-07)

Moved when Phase I-12e closed, to keep `PROGRESS.md` under its size budget. The phase's full
narrative is `docs/progress-archive/i-12d2.md`.

## Acceptance

- Phase I-12d2: all criteria met, 2026-11-07 — every I-12d2 bullet of `PLAN.md` implemented
  through `TerminalWording`, iTerm2's strings and expectations unchanged; each plain error
  mapped by exhaustive switches; hermetic (1183 core in 129 suites + 548 UI in 55 suites pass;
  `aPlainChoiceNeverContactsITerm2` passes); popover, attach and switcher screenshots replaced,
  light and dark, through `--preview-snapshot`; no real terminal-app run (`pgrep` empty before
  and after). One existing test file changed: three plain-mode placeholder expectations of
  I-12c3a in `TerminalSeamTests.swift` (this phase's charter), no iTerm2 expectation —
  `docs/progress-archive/i-12d2.md`.

## Decisions

- Phase I-12d2: one worker, per "Calls for I-12d" in `PLAN.md`. The workers' calls — a row's
  lines name the terminal whose backend ran the action, menus follow the current choice;
  host-problem, Test connection, Detect, "Creating…" and Quit's help follow the choice too;
  three core initialisers / `reason(of:)` made public for the fixtures; Move here dimmed only
  by iTerm2's attachment index (the plain backend checks its own record at the move);
  a detach retry keeps its terminal's record and backend; -1708 from a user definition worded
  as a possibility (missing handler or AppleScript off) — D38 "The UI (I-12d2)",
  `docs/progress-archive/i-12d2.md`.

## Open risks / deviations

- I-12d2 (**for the user**): every new line was seen only over stand-ins and in the galleries
  (no real terminal-app run, neither app running) — real Open, Show window, Detach, Move here,
  Detach other clients and the permission / AppleScript-off lines in Terminal and Ghostty are
  checklist 28. Ghostty's AppleScript-off error numbers (-1708, -10004) are unverified; a user
  definition's -1708 is worded as a possibility. "Detach (opened in iTerm2)" contacts iTerm2
  while a plain terminal is chosen (an explicit user action). The plain popover fixtures show an
  empty Saturno host (cosmetic) — `docs/progress-archive/i-12d2.md`.

## Reviews

- Phase I-12d2: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers + 3 should-fix (stale plain-window records dimming Move here permanently; a detach's
  "Try again" lost after a change of terminal; a missing script handler's -1708 read as
  Ghostty's AppleScript turned off); a review-fix worker fixed all three (and the same retry bug
  in plain "Detach from this Mac"), each regression failing with its fix reverted; re-verified
  by the orchestrator — `docs/reviews/phase-I-12d2.md`.

## Verification

- Phase I-12d2 (final tree, orchestrator, 2026-11-07): `swift build` exit 0; `swift format
  lint -r Sources Tests` exit 0; `swift test` passed, 1183 core tests in 129 suites and 548 UI
  tests in 55 suites; `codesign --verify --deep --strict build/muxFinder.app` exit 0 (bundle
  from the review-fix worker's `scripts/build-app.sh`, exit 0); `pgrep -x Terminal` and `pgrep
  -x ghostty` empty before and after — `docs/progress-archive/i-12d2.md`.
