# Session switcher: one click activates a row

Proposed phase, queued after the plan's remaining work. Suggested risk: **routine** (a view
gesture and its documents; the attach path does not change).

## User request (2026-11-04, verbatim)

> When opening the selection window with the shortcut key, clicking on "New session" doesn't
> work, I have to use Command + N.

The screenshot shows the switcher with "No live sessions.", the "New session…" row selected
(the selection outline drawn) after the click, and the form not shown.

## User decision (2026-11-04, asked while planning)

- **A single click activates every row** in the switcher: a session row opens it (D25's Open,
  as Return does), the "New session…" row shows the New session form (as ⌘N does). This is
  how the popover already behaves (`SessionRowView.swift:66`: `.onTapGesture {
  model.open(row.key) }`) and how Spotlight behaves. The double-click handler goes away.

## Findings (2026-11-04, from the code; nothing was run)

- The click works as designed, and the design is what the user does not want. PLAN.md D32
  (the switcher's *Keys* item) says "A click selects a row, a double-click activates it."
- `Sources/MuxFinderUI/Views/SwitcherView.swift`: session rows at lines 292-293 and the New
  session row at lines 362-363 have `.onTapGesture(count: 2) { model.activateSwitcherItem(…) }`
  followed by `.onTapGesture { model.selectSwitcherItem(…) }`. A single click only selects.
- `README.md` (around line 214, "press Return (or double-click)") and
  `docs/MANUAL-CHECKLIST.md` item 18 (around lines 383 and 414, "double-click another
  session", "the double-click show 'Opening…'") describe the double-click.

## Requirements

1. One click (a single tap) on a session row or the New session row calls
   `model.activateSwitcherItem(_:)` for that item. Make sure the selection then shows that row
   (select first, then activate, if the model needs it), so the row that shows "Opening…" or
   the activity is the one clicked.
2. No double-click handler is left behind, so a click is never delayed waiting for a second
   one. A fast double click must not open the same session twice or show the form and then
   act on it: the second click lands after the first one changed the view (the form) or
   started the Open; check that `activateSwitcherItem` on a row already opening is harmless
   (D25's in-flight rules) and add a test that proves it.
3. Everything else stays: hover highlight, the context menu (right-click: "Show tab" and a
   failure's recoveries), Return, ↑/↓, ⌘N, Esc, the accessibility actions and hints, pinned
   rows, the failure carry-over, closing on success.
4. Edit D32's *Keys* item ("A click activates a row, as in the popover"), `README.md`,
   `docs/ARCHITECTURE.md` if it says it, and checklist item 18.

## Acceptance

- UI tests over the model: activating the New session item shows the form with the draft
  as ⌘N does; activating a session item starts the same Open as Return; activating an item
  that is already opening starts nothing new. Existing tests pass unchanged or with recorded
  changes.
- `--preview-gallery switcher` still renders (light and dark through `--preview-snapshot`);
  regenerate `docs/screenshots/switcher-states-*.png` only if a state's look changed.
- `docs/MANUAL-CHECKLIST.md` item 18: one click on "New session…" shows the form; one click on
  a session opens it; a quick double click opens it once.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`),
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` pass. No
  `e2e-*` run or self-test is needed (the Open path is unchanged); no UI scripting or
  synthesized clicks.
