# Phase I-3b — Switcher panel (routine)

Closed 2026-10-24 under `/autoclaude-opus`. Worker model: opus (implementation worker and
review-fix worker); the orchestrator ran the verification, inspected the gallery, re-ran the
app shell check and wrote the records. Specification:
`autoclaude/processed/30-global-hotkey-session-switcher.md` (Design 5–10, Safety and checks,
Acceptance — the I-3b parts); plan: `PLAN.md` "### Phase I-3", the I-3b bullet (its
*Outcome* is the full account); decision **D32** extended, D22 and D30 edited.

## Acceptance criteria (set before the worker) and evidence

- New unit tests cover the switcher's content (stale sessions left out, order, filter, the New
  session row's text and prefill, selection kept across updates, empty and no-hosts states),
  its keys, the visibility rule (one opened/closed pair per change of "either one is
  visible"; opening one closes the other), a failure after the panel closed shown at the next
  opening and on the popover row, and the hotkey glue from the fake registrar — **met**: 25 new
  UI tests (`SwitcherContentTests`, `SwitcherControllerTests`, `SwitcherModelTests`), 7 more
  from the review fixes.
- Existing UI tests pass unchanged — **met with a recorded deviation**: three
  `GlobalShortcutAppTests` asserted I-3a's interim popover toggle, which the plan replaces, and
  now assert the switcher; one line of `arrowsMoveWithoutWrapping` expects the remembered first
  row (review finding 1 asked for exactly that behavior). No other test changed.
- `swift build` (no warnings), `swift test`, `swift format lint -r Sources Tests` — **met**,
  exit 0 each; 815 core + 324 UI tests pass on the final tree.
- `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` — **met**,
  exit 0 on the final tree.
- Gallery rendered light and dark and inspected — **met**:
  `docs/screenshots/switcher-states-{light,dark}.png`, 9 states (sessions, filtered, New
  session with a name, form, opening, failure, failure since the last opening, no hosts,
  hosts checking or unreachable); the orchestrator looked at the light sheet: legible, muted
  host lines, no red outside the D25 failure mark. The Settings gallery was regenerated for the
  General tab's new note.
- `--report-menu-bar-item` as before — **met**: under an empty `CFFIXED_USER_HOME`, SIGTERM
  exit 0, no child, the private home empty (worker and orchestrator runs).
- Docs — **met**: `README.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md` matrix,
  `docs/MANUAL-CHECKLIST.md` (checklist 18 extended), `CLAUDE.md` gallery note, `PLAN.md` D32,
  D22, D30 and the I-3b *Outcome*.

## What was built

- **Panel.** The popover's non-activating `PopoverPanelWindow` at the floating level, 540 pt
  wide, centered on the display with the keyboard focus, its top 18 % of the visible height
  down (`SwitcherController`, `Views/{SwitcherView,SessionSwitcher}.swift`). It closes on Esc,
  the shortcut, a click outside, an app switch, losing the focus, a display change, the popover
  opening, or a successful open/create. The popover's panel host, observers and key view became
  shared (`PanelHost`, `PanelObservers`, `PanelKeyTrackingView`).
- **Content.** `SwitcherContent`: live sessions in the popover's order with the popover's
  filter, pinned failure rows, the "New session…" row taking a valid unused name, muted lines
  for hosts checking or unreachable, the no-hosts placeholder with "Open Settings".
- **Keys and actions.** `handleSwitcherKey(_:)` over `PopoverKey`; Return opens like the
  popover (D25), Return on the New session row or ⌘N shows the popover's New session form with
  I-2b's directory list, ⌘R refreshes, ⌘, opens Settings, Esc leaves the form or closes.
  `AppModel.globalShortcutPressed()` toggles the switcher; the interim
  `PopoverController.shortcutPressed()` and `AppModel.togglePopover` are gone, and the popover's
  close reason `.shortcut` became `.switcherOpened`.
- **Engine.** The two visibilities are combined (`AppModel`), so `.popoverOpened` /
  `.popoverClosed` are each sent once per change of "either one is visible";
  `PopoverController` now reports a new visibility before its panel shows, so a swap between the
  panels never reaches the engine as a close.

## Review (Codex, `docs/reviews/phase-I-3b.md`) and fixes

`ship-with-fixes`, 0 blockers, 4 should-fix, all real, fixed by a review-fix worker, each with
regressions that fail with the fix reverted (the second handoff test passes either way: that
order already worked):

1. The automatically selected row was not persisted, so a refresh inserting a session above it
   moved Return's target → remembered at each opening, filter change and before each engine
   update (`aRefreshKeepsTheAutomaticSelection`).
2. A pinned failure row absent from the snapshot did nothing on retry → it opens through its
   retained target on its host as enabled now (coordinator revalidation kept), or shows that its
   host is no longer turned on (`aPinnedRetryAttachesThroughItsRetainedTarget`,
   `aPinnedRetryOnAHostTurnedOffShowsWhy`). "Show tab" was never affected (it uses the launch
   tab id).
3. A creation failure arriving while the popover's Move here confirmation was open was dropped
   → held and shown once that ends or at the next switcher opening
   (`aCreationFailureHeldBackByMoveHereShowsOnceItEnds`,
   `aCreationFailureHeldBackByMoveHereShowsAtTheNextOpening`).
4. A status-item press delivering the outside close before the button action sent a spurious
   closed/opened pair → that close is left to the popover the press opens
   (`statusItemHandoffWithTheOutsideCloseFirst`, `statusItemHandoffWithTheButtonActionFirst`).

## Open risks / deviations

- No hotkey was pressed and the real panel was never shown (no synthesized events): a press
  from another app and over a full-screen app, filter and open with iTerm2 coming forward,
  create, and Esc returning the focus are checklist 18's.
- A press on another display's copy of the status item is not recognized as the status item
  (macOS gives that copy a placeholder frame); if its outside close arrives first, the engine
  still gets a closed/opened pair (documented in D32; a delayed close signal was not added).
- If a creation fails while the popover's Move here is unconfirmed and the switcher then opens,
  the switcher shows the form and that unconfirmed Move here confirmation closes (nothing had
  run).
- "Detach from this Mac" on a pinned row whose host is gone still does nothing (outside the
  retry fix's scope).
- Additions beyond the specification: a key-hint footer; the New session name field takes the
  focus in the switcher.

## Verification (final tree, orchestrator)

- `swift build` exit 0, no warnings; `swift test` 815 core tests in 81 suites + 324 UI tests in
  30 suites passed; `swift format lint -r Sources Tests` exit 0.
- `scripts/build-app.sh` exit 0 (Apple Development, not notarized); `codesign --verify --deep
  --strict build/muxFinder.app` exit 0.
- `--report-menu-bar-item` under `CFFIXED_USER_HOME=$(mktemp -d)`: SIGTERM exit 0, no child,
  private home empty (before the review fixes; the fixes touched only model and controller
  code covered by the unit tests).
- No `e2e-*`, self-test or `--report-hotkey-registration` run: the attach path is unchanged.
