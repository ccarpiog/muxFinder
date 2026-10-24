# Phase I-1b — Place the popover under the icon (high)

Closed 2026-10-24. Worker model: opus (impl worker, review-fix worker); orchestrator record
edits (`docs/TESTING.md` *Phase I-1b* final-tree run, `PLAN.md` Phase I-1 outcome). Parent:
I-1 (popover under the menu bar icon, from the inbox; specification
`autoclaude/processed/10-popover-under-menu-bar-icon.md`; split into I-1a and I-1b in
`PLAN.md` before I-1a's worker).

## What was built

- **D30** (`PLAN.md` *Decisions*; D22 and D28 edited): SwiftUI's `MenuBarExtra(.window)` is
  gone. muxFinder owns its `NSStatusItem` (D28's template image, `Views/MenuBarIcon.swift`,
  replacing `MenuBarIconLabel.swift`) and a borderless, non-activating `NSPanel` at the pop-up
  menu level on all Spaces and over full-screen apps, hosting `PopoverView`
  (`Views/MenuBarPopover.swift`). The SwiftUI `App` stays only for the standard main menu; its
  one scene is an empty `Settings` whose menu item is removed; `applicationShouldHandleReopen`
  returns false.
- Pure rules (`Model/PopoverAnchoring.swift`): the anchor (a mouse press: the screen holding
  it, the real button's rect when the press is inside it, else the press's x; no mouse event
  such as `performClick(_:)` or VoiceOver: the button's rect; replica `NSStatusBarWindow`
  placeholders never), toggle, move to another display, close, and the classic toggle bug in
  both orders. `PopoverController` (`Model/PopoverController.swift`) drives them over
  protocols and is the only source of `popoverVisibilityChanged` (open and not occluded);
  `PopoverWindowBridge` keeps only the key monitor. Outside clicks: a global mouse-down
  monitor active only while open.
- Review fixes: one press is identified by the hardware press count
  (`CGEventSource.counterForEventType` on the HID state; public, read-only) on top of the
  0.5 s / 40 pt limits, so a click on a neighbouring item followed quickly by muxFinder's icon
  opens the popover; `PopoverHeightLimit` replaces `.fixedSize()`: the controller passes the
  display's room below the menu bar (`PopoverPlacement.availableHeight(on:)`), content that
  fits keeps its natural size, taller content gets the limit and only the host list shrinks
  and scrolls (search field and footer stay visible).
- The diagnostic `--report-popover-placement` now opens the panel through the button's own
  action and prints the controller's placement and an explicit after-fix check.
- Docs: `CLAUDE.md` (popover placement and app shell notes), `README.md`,
  `docs/ARCHITECTURE.md`, `docs/TESTING.md` (*Phase I-1b*), `docs/MANUAL-CHECKLIST.md` item 16.

## Acceptance (all met, with the by-hand items in checklist 16)

- Placement and controller tests over fakes: `PopoverAnchoringTests`, `PopoverControllerTests`,
  `PopoverHeightLimitTests`, `PopoverPlacementTests`, `MenuBarIconTests.statusItemImage`;
  existing UI tests unchanged and passing.
- After-fix diagnostic, exit 0, three runs: twice by the impl worker with the screen locked
  (panel {{1250, 1530}, {360, 168}} then {{1251, 1530}, …}: middle on the button's, top 1698
  on the menu bar's bottom, offsets 0); once by the orchestrator on the final tree, unlocked,
  screen 1 main: the real button at screen 1's right edge {4118, 2139}, the panel
  {{3784, 1971}, {360, 168}} clamped 8 pt inside the display, top 2139 on the menu bar's
  bottom, "after-fix check: passed". No child, private homes empty.
- `--report-menu-bar-item` on the final tree: 7 windows, exit 0 after SIGTERM, no child, no
  `hosts.json`.
- `scripts/build-app.sh` exit 0, `codesign --verify --deep --strict` exit 0.

## Verification (orchestrator, final tree)

`swift build` exit 0; `swift test` 745 core (74 suites) + 220 UI (21 suites) pass; `swift
format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0; `codesign --verify --deep
--strict build/muxFinder.app` exit 0; shell check and diagnostic as above. No iTerm2 contact,
no `e2e-*` or self-test (attach path unchanged).

## Review

Codex (`autoclaude-review.sh`, 20 min) wrote `docs/reviews/phase-I-1b.md`: `ship-with-fixes`,
0 blockers, 2 should-fix — (1) distinct clicks mistaken for one press by proximity and time
(fixed: hardware press count; 4 rapid-press regressions fail with it reverted, toggle-bug tests
still pass); (2) a clamped panel clipped content with no way to reach it (fixed:
`PopoverHeightLimit`; the shrink, root and controller-limit regressions fail with it
reverted; natural height 501 pt unchanged). Both fixed by a review-fix worker, re-verified by
the orchestrator.

## Open risks

- Unverified for real (checklist 16): the panel becoming key, search-field focus, the keys
  (↑/↓, Return, ⌘F, ⌘R, ⌘N, ⌘,), Edit-menu equivalents in the field, Esc / outside click / app
  switch on the real panel, a press on the other display's icon, after a ⌘-drag, a full-screen
  Space, the panel resizing when content changes.
- Whether the system draws the icon where AppKit reports the real button (screen 1's right
  edge when screen 1 is main) is unchecked; a real press outside that rect anchors at the press.
- Reading the hardware press count inside the app is unverified (if it never changed, the
  rules behave as before the fix); two quick posted clicks still match only by time and
  distance; a display with under 82 pt below the menu bar would still clip (none exists).
- The action fires on mouse-down; the panel closes when the display setup changes.
