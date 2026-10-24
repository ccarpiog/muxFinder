# Phase I-1a — Diagnose: placement diagnostic, placement function (high)

Closed 2026-10-24. Worker model: opus (impl worker, review-fix worker); orchestrator edits to
the lock-state wording in `PLAN.md` and `docs/TESTING.md`. Parent: I-1 (popover under the menu
bar icon, from the inbox; specification `autoclaude/processed/10-popover-under-menu-bar-icon.md`;
split into I-1a and I-1b in `PLAN.md` before the first worker).

## What was built

- `--report-popover-placement` (app binary; `Sources/MuxFinderApp/PopoverPlacementReport.swift`,
  `PopoverPlacementInspection.swift`; `AppEnvironment.placementDiagnostic()`; parsing in
  `AppLaunchOptions`). Runs the normal menu bar scene over a never-started model with an empty
  in-memory host list (no `hosts.json`, no refresh, no iTerm2, no defaults written, no
  profile rewrite). Prints the lock state, every `NSScreen` (frame, visible frame, scale, menu
  bar bottom, auto-hide fallback), every status-bar window with its view tree, the button and
  its click wiring, the off-screen content size and the placement function's frame. Opens the
  popover with the button's `performClick(_:)` only when the button has an action or a menu.
  Exit codes: 0 measured, 1 clicked but no popover, 2 usage, 3 interrupted or watchdog, 4 not
  openable in process (no action and no menu, or no button).
- `PopoverPlacement.frame(contentSize:anchor:screen:)` and `screenIndex(for:in:)`
  (`Sources/MuxFinderUI/Model/PopoverPlacement.swift`): top at the menu bar's bottom, centered
  on the anchor (rect or click point), clamped inside the visible frame with an 8 pt inset.
  9 tests in `PopoverPlacementTests` (the five specification cases plus wide content, point vs
  rect, screen edges, the flag).
- Review fixes: `PopoverWindowIdentification` (pure; a status-bar window is never the popover;
  a positive match on the live `PopoverView` through `LivePopoverLookup` in
  `PopoverWindowBridge.swift`, else a newly visible window below level 25) with 4 tests;
  `NonblockingLineWriter` (own queue, bounded, drops counted, `SIGPIPE` ignored) with 3
  tests; a background watchdog that exits 3 one second after the 10 s deadline (no unit test).

## Diagnosis (PLAN.md *Verified facts*, "Phase I-1a placement diagnostic"; numbers in
`docs/TESTING.md`, *Phase I-1a*)

- Seven `NSStatusBarWindow`s, level 25, 34 × 30 pt. Only window 0 holds the button, at
  {1413, 1698} on the main display (menu bar bottom 1698). Six replica windows have no
  button and placeholder frames: four at {0, −30}, two at {4152, 2139}, the second display's
  right edge at its menu bar's bottom.
- SwiftUI's `MenuBarExtra` button has no action, target, menu or gesture recognizer, so
  `performClick(_:)` sends nothing and no popover window is created. **The pre-fix popover
  frame is unmeasured**; the cause (SwiftUI anchoring at a replica's placeholder frame, then
  clamped to the screen's right edge, {{3784, 1971}, …}) is an inference, and the user's own
  report is the only observation of the before state.
- Recommendation recorded for I-1b: muxFinder's own `NSStatusItem` and a borderless `NSPanel`,
  anchored at the click point (`NSEvent.mouseLocation`), snapping to the real button's rect
  when the click falls inside it or no mouse event exists.

## Acceptance (PLAN.md Phase I-1, I-1a)

- Placement tests pass (all five specification cases): met (`PopoverPlacementTests`, 9).
- The diagnostic exits cleanly with no child left, no window open and no `hosts.json`: met,
  with exit 4 on the current scene (the "not openable in process" outcome the I-1a
  acceptance now records); private home empty; no process left (orchestrator re-run on the
  final tree).
- Cause, or what could not be measured and why, recorded: met (inferred cause, labeled as
  inference; unmeasured before-frame and why).
- `--report-menu-bar-item` unchanged: met (worker runs: same seven windows, exit 0 after
  SIGTERM, no child, no `hosts.json`).
- Shared verification, `scripts/build-app.sh` and `codesign --verify --deep --strict`: met.

## Decisions

- In-process `performClick(_:)` on the app's own button is not UI scripting (PLAN.md Phase I-1
  records the bounds). Private SwiftUI internals and synthesized mouse events, in process or
  not, stay out of the rules, so the current scene's popover cannot be opened unattended.
- The before-fix measurement is deferred for good (the before state disappears with I-1b); I-1b's
  acceptance now requires the after-fix diagnostic to open the popover through muxFinder's own
  button action and measure it (exit 0), with a by-eye check in `docs/MANUAL-CHECKLIST.md`.

## Review

Codex (`autoclaude-review.sh`, 15 min) → `ship-with-fixes`, `docs/reviews/phase-I-1a.md`:
- BLOCKER `PopoverPlacementReport.swift:154`, the only opening mechanism is a no-op →
  resolved by the reviewer's "if unavailable, explicitly defer" branch: the diagnostic checks
  for an action or a menu first and exits 4 without clicking; records say the before-frame is
  unmeasured and why; I-1b's acceptance requires the real measurement.
- SHOULD-FIX `:214`, replicas could be reported or closed as the popover → fixed
  (`PopoverWindowIdentification`; regressions fail with the old predicate).
- SHOULD-FIX `:435`, blocked stdout disabled the deadlines and signal cleanup → fixed
  (`NonblockingLineWriter`, popover closed before the termination line, background watchdog;
  the stalled-pipe regression fails with the old synchronous write).

## Verification (final tree, orchestrator)

`swift build` exit 0; `swift test` exit 0 (745 core tests in 74 suites, 194 UI tests in 18
suites); `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0;
`codesign --verify --deep --strict build/muxFinder.app` exit 0;
`CFFIXED_USER_HOME=<mktemp -d> build/muxFinder.app/Contents/MacOS/muxFinder
--report-popover-placement` → "the popover cannot be opened in process …; not clicking",
exit 4, private home empty, no process left.

## Open risks

- The before-frame is unmeasured and the cause inferred; whether window 0's x 1413 is where the
  system draws the icon was not checked (no other process's status-bar window listed).
- Lock state disagreed between runs: the review-fix worker reported its two runs unlocked, the
  orchestrator's re-run (about 15:25) locked with both displays asleep; frames were identical.
- The watchdog has no unit test; exit 4 also covers "no status item button found" (was 1).
- A window above level 25 counts as the popover only when it holds the live `PopoverView`
  (so I-1b's own panel, possibly at the pop-up menu level, is found).
