# Checkpoint head, Phases I-4 to I-9a (moved verbatim from `PROGRESS.md`)

Moved when Phase I-9b closed (2026-11-06) to keep `PROGRESS.md` within its size budget.

## Acceptance

- Phase I-4: all criteria met, 2026-11-04 — SwiftUI's `Settings` scene was the window; after
  the fix the shell check under an empty home lists only the hidden popover panel and
  onboarding; 12 new UI tests; checklist 19; the `CLAUDE.md` note owed — `docs/progress-archive/i-4.md`.
- Phase I-5: all criteria met, 2026-11-04 — one click on a session row opens it as Return
  does, on "New session…" shows the form as ⌘N does; a second activation of a row opening
  starts nothing; the rest of an activating click's sequence is dropped and the panel held
  (no shrink, success/app-switch/resign-key closes waiting) through the double-click
  interval; 14 new UI tests (815 core + 350 UI pass), no existing assertion changed; gallery
  unchanged; a real double click owed (checklist 18) — `docs/progress-archive/i-5.md`.
- Phase I-6: all criteria met, 2026-11-04 — diagnosed in process (the panels' key view loop
  was never recalculated after the form replaced the list); native fix; Tab order Name →
  Directory → list button → Cancel → Create → Host → Name and back, in both panels; 4 new UI
  tests (815 core + 354 UI pass); galleries unchanged; real presses owed (checklist 20) —
  `docs/progress-archive/i-6.md`.
- Phase I-7: all criteria met, 2026-11-04 — pure filter (10 content tests) and model behaviour
  (12 model tests: open on a match without a highlight, close only a typing-opened list, the
  clearing rule, Esc, arrows in filtered rows, Return creates, a pick does not reopen, host
  change, busy, announcement); 5 existing tests' field value changed, expectations kept; attach
  and switcher galleries gained the filtered and no-match states, screenshots regenerated and
  inspected; 815 core + 376 UI pass; real typing and VoiceOver owed (checklist 21) —
  `docs/progress-archive/i-7.md`.
- Phase I-8: all criteria met, 2026-11-05 — diagnosed in process (⇧Tab from Name reaches the
  Host picker, an `NSPopUpButton`, but the monitor took ↑/↓/⌥↓ wherever the focus was); pure
  `PanelKeyRoute.decide` wired into both panels' monitor, `MenuTrackingObserver`; diagnostic
  before/after in `docs/TESTING.md`; 14 new UI tests, no existing test changed (815 core + 390
  UI pass); galleries unchanged; real presses owed (checklist 22) — `docs/progress-archive/i-8.md`.
- Phase I-9a: all criteria met, 2026-11-05 — model tests for opening from both entry points,
  reopening, every ending, the failure-after-close rule from either entry point, Move here with
  the window, the panels leaving it alone, keys, placement and height (18 new UI tests, 815
  core + 406 UI pass; changed and removed tests in `docs/TESTING.md`, *Phase I-9a*);
  `--selftest new-session-local` 7/7; shell and placement checks pass; the real window owed
  (I-9b's checklist item) — `docs/progress-archive/i-9a.md`.

## Decisions

- Phase I-4: new **D33** — the menu bar app runs on a plain `NSApplication` with a hand-built
  main menu (`MainMenu`), because SwiftUI opens its `Settings` scene by itself at launch and no
  documented API keeps a SwiftUI scene closed; D22 and D30 edited. The `CLAUDE.md` command-note
  edit the item asked for was withheld: that file holds the user's uncommitted edit —
  `docs/progress-archive/i-4.md`.
- Phase I-5: **D32** *Keys* edited ("A click activates a row, as in the popover"). Two
  additions beyond the specification, both needed for its requirement 2: `SwitcherClickSequence`
  (a local mouse monitor drops the rest of an activating click's sequence in the switcher's
  window) and, from the review, `SwitcherController.holdForClick()` (the panel keeps its
  height and waits to close on success, app switch or resign key until
  `NSEvent.doubleClickInterval` has passed) — `docs/progress-archive/i-5.md`.
- Phase I-6: the native route (`PopoverPanelWindow.autorecalculatesKeyViewLoop = true`), not
  model-held focus, since AppKit's own loop gives the reading order once recalculated; Tab with
  the directory list open moves on and leaves it open (D31); D30, D32 edited —
  `docs/progress-archive/i-6.md`.
- Phase I-7: the orchestrator's `~` rule (field as typed; on This Mac each entry also with its
  home folder as `~` and its `~` spelled out; SSH hosts as stored) and clearing rule (empty
  text never opens, closes a typing-opened list), both in `PLAN.md` "### Phase I-7"; the
  "opened by" state `DirectoryPickerState.opening` (`request`/`typing`); a pick fills through
  `fillDirectoryField(_:)`, no edit; the announcement through `AppEnvironment.announce` —
  `docs/progress-archive/i-7.md`.
- Phase I-8: the orchestrator's calls in `PLAN.md` "### Phase I-8" — a generic rule (any
  `NSPopUpButton` first responder keeps ↑/↓/⌥↓; Return still creates, Esc still closes), every
  key passes through while a menu tracks, and with the directory list open and Host focused the
  list stays open and keeps Return/Esc (D31) — `docs/progress-archive/i-8.md`.
- Phase I-9: split into I-9a (high) and I-9b (routine), recorded in `PLAN.md` *Phase I-9* with
  the orchestrator's calls before the first worker: a non-activating titled `NSPanel` at the
  floating level on every Space and over full-screen apps; top centre at the source's top
  centre, clamped, no frame remembered across closes; ⌘W like Cancel, ⌘, opens Settings, ⌘R/⌘F
  not the window's; the draft dropped on every ending but a running creation's; **a failure or
  collision after close brings the window back, not key**, replacing the switcher-only
  deferred path. I-9a's review fix: the switcher follows "Open existing" of a draft it made,
  as it does the draft's creation — `docs/progress-archive/i-9a.md`, D34.

## Reviews

- Phase I-4: Codex wrote the file (`autoclaude-review.sh`, 15 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix (the extended shell report wrote stdout synchronously on the main
  actor). Fixed inline by the orchestrator through `NonblockingLineWriter`; re-verified; the
  full-pipe regression is not run (the report is ~5 KB) — `docs/reviews/phase-I-4.md`.
- Phase I-5: Codex wrote the file (`autoclaude-review.sh`, 12 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix (the New session form shrinks the panel, so a double click's second
  click reaches the app behind). Fixed by a review-fix worker (`holdForClick()`, covering a
  success close too), regressions failing with their fix reverted; re-verified by the
  orchestrator — `docs/reviews/phase-I-5.md`.
- Phase I-6: Codex wrote the file (`autoclaude-review.sh`, 12 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix (the diagnostic's synchronous stdout could strand its key panel).
  Fixed inline by the orchestrator (`NonblockingLineWriter`, bounded flush, 30 s watchdog exit
  3); re-verified — `docs/reviews/phase-I-6.md`.
- Phase I-7: Codex wrote the file (`autoclaude-review.sh`, 12 min) → `ship`, 0 findings (not
  verified: checklist 21's live checks) — `docs/reviews/phase-I-7.md`.
- Phase I-8: Codex wrote the file (`autoclaude-review.sh`, 12 min) → `ship`, 0 findings (not
  verified: checklist 22's live checks) — `docs/reviews/phase-I-8.md`.
- Phase I-9a: Codex wrote the file (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0
  blockers, 1 should-fix (preserve switcher ownership through "Open existing"). Fixed by a
  review-fix worker (`switcherExistingOpened`, `followSwitcherAction`), its regression failing
  with the fix reverted; re-verified by the orchestrator — `docs/reviews/phase-I-9a.md`.
