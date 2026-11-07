# Head material moved from PROGRESS.md at I-12d2 closure (verbatim): acceptance, decisions and reviews of I-12c3a to I-12d1, open risks of I-12a to I-12d1

## Acceptance

- Phase I-12c3a: all criteria met, 2026-11-06 (1158 core + 497 UI; both self-tests real
  through the seam) — `docs/progress-archive/i-12c3a.md`.
- Phase I-12c3b: all criteria met, 2026-11-06 — `e2e-plain` with its gate, steps and cleanup,
  hermetic on a private tmux server with the real helper (1177 core in 127 suites + 497 UI pass,
  no existing test file edited); real: the gate refuses Terminal and Ghostty (exit 2, nothing
  created, `pgrep` unchanged); iTerm2 regression `e2e-local` 16/16, `e2e-remote saturno-m4`
  17/17 (after one 15/17 flake on unchanged code), `e2e-bury --local` 13/13,
  `e2e-detach-others --local` 9/9, leftovers clean; the plain real runs owed to the user —
  `docs/progress-archive/i-12c3b.md`.
- Phase I-12d1: all criteria met, 2026-11-06 — the picker, wording, plain SSH setup,
  persistent work command, onboarding without iTerm2 and galleries, hermetic (1182 core + 517
  UI pass, no existing test file edited; `aPlainChoiceNeverContactsITerm2` passes); Settings
  and onboarding screenshots replaced; no real terminal-app run (neither running) —
  `docs/progress-archive/i-12d1.md`.

## Decisions

- Phase I-12c3a: the I-12c3 split and its calls in `PLAN.md` *Phase I-12*; the workers'
  decisions (Install/Remove profile buttons left for I-12d among them) in
  `docs/progress-archive/i-12c3a.md`.
- Phase I-12c3b: "Calls for I-12c3b" in `PLAN.md` *Phase I-12* (the harness, the gate first,
  the steps, real runs only through the gate). The workers': the run's logic in
  `Sources/MuxFinderCore/E2EPlain/` (tests import only libraries; nothing in the app calls it),
  a signal exits 1, and the review fixes (three-state process reading, bounded SIGTERM of own
  helpers checked by start time and executable, helpers tracked by launch token, a failed
  session listing is "unknown") — D38 "The plain runs (I-12c3b)",
  `docs/progress-archive/i-12c3b.md`.
- Phase I-12d: split into I-12d1 (Settings, onboarding, SSH setup) and I-12d2 (popover,
  switcher, session states) at selection, because one worker could not cover every surface and
  gallery coherently; "Calls for I-12d" in `PLAN.md` *Phase I-12*. I-12d1's workers' calls
  (persistent work lines only for hosts with their profile on; permission reads off the main
  actor; "Check again" re-resolves the same terminal only) — D38 "The UI (I-12d1)",
  `docs/progress-archive/i-12d1.md`.

## Open risks / deviations

- I-12a (**for the user**): the real Terminal and Ghostty window runs are owed (open, confirm,
  focus, detach, Move here; what `do script` returns, Ghostty's ids, whether its `environment
  variables` reach `command` and whether `direct:` works through AppleScript) —
  `docs/TESTING.md` *Phase I-12a, Owed*. I-12b and I-12c must design for either answer. The
  `detach-client` target is picked by name only (the bound command checks it is unique); the
  remote bound attach's refusal is tested only through the local builder. One `swift test` run
  made beside other commands failed a folder search transport timing bound (load-sensitive,
  untouched code); alone it passed.
- I-12b1: compiling and calling the built-in Terminal and Ghostty scripts is owed to a real
  run (their fit with the dictionaries checked only against `sdef`); the same folder search
  timing test failed once in a worker's full run (2.018 s against 2 s) and passed in every
  later run — `docs/progress-archive/i-12b1.md`.
- I-12b2: the remote plain attach tested only through its argv (real run: I-12c's
  `e2e-plain`); no terminal app has run the plain modes; one worker full run failed one
  "Directory store" test (untouched code), passing alone and in every later run —
  `docs/progress-archive/i-12b2.md`.
- I-12b3: nothing uses the seam yet (I-12c); the "unrecognised permission status goes ahead"
  call is for I-12c/I-12d to keep or revisit with the real runs; a facts read that wrongly
  says a running app stopped would only leave a window open — `docs/progress-archive/i-12b3.md`.
- I-12c1: nothing uses the plain backend yet (I-12c3); a session name with `{`, `[` or `]`
  cannot be checked or detached by the bound commands (fails `notWritable`, nothing wrong
  touched; I-12c3/I-12d decide whether to refuse it up front); a detach-others stopped
  partway says "none detached" though some may have been (I-12d's wording) —
  `docs/progress-archive/i-12c1.md`.
- I-12c2: no client in Terminal or Ghostty traced for real (Ghostty's chain unverified); nothing
  calls the attributor yet (I-12c3); an app found by ancestry is focused by activation only, and
  macOS 14's cooperative activation may refuse it (recorded, never failing an attach); the review
  fix extended one existing test's input and expectations — `docs/progress-archive/i-12c2.md`.
- I-12c3a (for I-12d): the "earlier launch pending" refusal across backends covers Open and
  Move here only and its message still names iTerm2; an iTerm2 launch whose helper died without
  a result keeps that session refused in other terminals for the app's life; Detach from
  another terminal's records is not offered while it is not chosen; an SSH-setup click before
  the choice resolves shows "not used with this terminal"; Ghostty is now installed on this Mac
  — `docs/progress-archive/i-12c3a.md`.
- I-12c3b (**for the user**): the four plain real runs `e2e-plain --terminal terminal|ghostty
  --local | --ssh saturno-m4` are owed (neither app was running; exact commands in
  `docs/TESTING.md` *Phase I-12c3b, Owed* and checklist 26); the harness's real-window, app
  facts and remote paths are proven only up to the window layer's fake. `e2e-remote saturno-m4`
  failed step 15 once (`helperEnded` after 3.2 s, unchanged code) and passed on the rerun; the
  folder search timing test failed once again; the review-fix worker ran one read-only `git
  diff --stat` against its brief — `docs/progress-archive/i-12c3b.md`.
- I-12d1 (**for the user**): the picker's real permission states, "Set up SSH" in Terminal and
  Ghostty, and pasting the persistent work command are owed (checklist 27; neither app was
  running). The cancellation regression holds the main actor 0.3 s to land its race (under load
  it may pass without exercising it, never fail falsely). Screenshots are now 1×, the old ones
  2× — `docs/progress-archive/i-12d1.md`.

## Reviews

- Phase I-12c3a: Codex → `ship-with-fixes`, 3 blockers + 1 should-fix, all fixed —
  `docs/reviews/phase-I-12c3a.md`, summary in `docs/progress-archive/i-12c3a.md`.
- Phase I-12c3b: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 1
  blocker (an unreadable process treated as exited, so a window could be closed while its helper
  ran) + 3 should-fix (failed helpers left running; helpers untracked after an open error; a
  failed session check read as absence); a review-fix worker fixed all four, each regression
  failing with its fix reverted; re-verified by the orchestrator —
  `docs/reviews/phase-I-12c3b.md`.
- Phase I-12d1: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers + 3 should-fix ("Check again" not re-resolving the choice; a cancellation between the
  launcher's check and the main-actor open; permission reads on the main actor); a review-fix
  worker fixed all three, each regression failing with its fix reverted; re-verified by the
  orchestrator — `docs/reviews/phase-I-12d1.md`.
