# Phase I-9a — New session window: the model and the window

- **Risk class:** high. **Worker model:** opus (implementation worker; review-fix worker).
- **Date:** 2026-11-05. **Specification:** `autoclaude/processed/90-new-session-own-window.md`
  (requirements 1–5 and the decision part of 7). **Plan:** `PLAN.md`, *Phase I-9* (the split
  into I-9a/I-9b and the orchestrator's calls, made before the first worker), decision **D34**.

## Acceptance criteria and evidence

- New session's state is out of `panel`; one titled, floating, non-activating "New session"
  panel opens from the popover and the switcher, which close as it opens; Move here stays an
  inline confirmation and can show with the window — met: `AppModelNewSession.swift`,
  `NewSessionWindowController.swift`, `Views/NewSessionWindow.swift`; tests
  `NewSessionWindowTests` (`openingFromThePopover`,
  `openingFromTheSwitcherPrefillsOnlyAFreshDraft`, `openingAgainBringsItForwardWithItsDraft`,
  `moveHereAndTheWindowAtTheSameTime`, `thePopoverAndTheSwitcherLeaveTheWindowAlone`).
- Endings and drafts: Cancel, Esc, ⌘W and close drop the draft; a running creation keeps its
  draft; success closes; collision and failure stay; a collision or failure after closing
  brings the window back, not key, from either entry point (`cancelEscAndCloseDropTheDraft`,
  `aRunningCreationKeepsItsDraftAndSuccessCloses`, `aCollisionAndAFailureStayInTheWindow`, the
  parameterized failure-after-close test, `aFailureAfterClosingIsNotHeldBackByMoveHere`) — met.
- Keys (`theWindowsKeys`), click filter, the model needing no window (`theModelNeedsNoWindow`),
  placement and height as pure functions (`aFreshOpeningIsPlacedFromItsSource`,
  `aRequestsFrame`, `theHeightFollowsTheContent`, `theControllerResizesTheShownWindow`) — met.
- The switcher follows the attach of a draft it made, its "Open existing" included
  (`openExistingIsFollowedByTheDraftsSwitcher(_:)`, popover and switcher; fails with the fix
  reverted: 7 failed expectations in the switcher case) — met after the review fix.
- Existing tests pass or each change is recorded — met: `docs/TESTING.md`, *Phase I-9a* (two
  tests of the retired Move-here deferral removed, their guarantee covered by
  `aFailureAfterClosingIsNotHeldBackByMoveHere`).
- Shared verification, bundle, signature, shell check, placement check, self-test — met (below).

## Decisions

- The orchestrator's calls (activation, level, Spaces/full screen, position and size, keys,
  ending, failure after close, self-tests and previews) are in `PLAN.md` *Phase I-9*, D34.
- Worker's: the window's controller is created at its first opening by the app shell; the inline
  form states are kept as `AttachFixtures.newSessionStates` and
  `SwitcherFixtures.newSessionStates` for I-9b's gallery; `--preview-key-view-loop
  popover|switcher` now inspects the real window over that entry point's fixture (its step that
  showed the list before the form is gone); D22 and D25 were edited too, since they described
  the form as a popover panel.
- Review fix: `startAttach` reports whether it started; only then does `existingFound` call
  `switcherExistingOpened(_:target:)`; the switcher's bookkeeping is one helper,
  `followSwitcherAction`, shared with `switcherActionStarted` and `switcherSessionCreated`.

## Open risks / deviations

- No real window was shown, moved, typed into or dragged: floating over other apps, every Space
  and full-screen apps, key without activation, ⌘W and the close button, the height following
  the directory list are I-9b's checklist item (the user's).
- ⌘R and ⌘F in the window reach the focused field (a beep); ⌘N is swallowed silently.
- The committed attach and switcher screenshots still show the inline form until I-9b
  regenerates them.
- A popover-made draft's Open existing is still followed by the switcher if the switcher
  happens to show when the lookup returns, as any Open is.
- `CLAUDE.md` (the user's uncommitted edit; not touched): "with `--preview-gallery attach`
  every session-action state" no longer covers the New session form until I-9b's gallery.
- The first `swift test` run on the final tree reported 1 issue in the core suite (core sources
  untouched by the phase); the next three runs passed (load-sensitive suites, as recorded
  under I-2b).

## Review

- Codex (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0 blockers, 1 should-fix
  (preserve switcher ownership through "Open existing"). Fixed by a review-fix worker with a
  regression failing on the old code; re-verified by the orchestrator —
  `docs/reviews/phase-I-9a.md`.

## Verification (final tree, orchestrator)

- `swift build` exit 0; `swift test` exit 0, 815 core tests in 81 suites and 406 UI tests in 40
  suites; `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0;
  `codesign --verify --deep --strict build/muxFinder.app` exit 0.
- `--report-menu-bar-item` under an empty private home (before the review fix, which touched
  only the model): exit 0 on SIGTERM, no child, home left empty, windows: the hidden popover
  panel and onboarding only.
- Worker: `--report-popover-placement` exit 0, "after-fix check: passed", no child;
  `--preview-key-view-loop popover` and `switcher` exit 0; `--selftest new-session-local` 7/7
  PASS (iTerm2 17 threads before, 20 after; no `muxfinder-test-*` session, nothing of the run
  in tabs or `buried_sessions`).
