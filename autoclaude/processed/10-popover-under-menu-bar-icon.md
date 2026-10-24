# Popover under the menu bar icon

Proposed phase, queued after Phase 14. Suggested risk: **high** (the app shell may change, macOS
27's placement is unverified, and no unattended run can click the real icon).

## User request (2026-10-24, verbatim)

> I'd love the menu when clicking on the menubar item to appear right below the menubar item,
> instead of the far right

## Goal

Clicking muxFinder's menu bar icon opens the popover directly below the icon, the way menu bar
extras normally open. Today it opens at the far right of the screen.

## Findings so far (2026-10-24, from code and docs only; nothing was run)

- muxFinder places nothing itself. The popover is SwiftUI's
  `MenuBarExtra { PopoverView(…) } label: { MenuBarIconLabel() }.menuBarExtraStyle(.window)`
  in `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`; `PopoverWindowBridge`
  (`Sources/MuxFinderUI/Views/PopoverWindowBridge.swift`) only follows that window for
  visibility and keys.
- On macOS 26 and later (Neptuno runs 27.2), third-party menu bar items are drawn outside the
  app's process (PLAN.md D22, *Menu bar item check*). `CGWindowListCopyWindowInfo` lists no
  window under the app's pid, while `NSApp.windows` still holds the app's status-bar-level
  windows. Phase 12b's shell check (`--report-menu-bar-item`) found 7 of them on two displays,
  each 34 × 30 pt.
- Hypotheses, **to test, not facts**: (a) SwiftUI places the window from an in-process
  status-bar window whose frame is a placeholder or stale, and the screen clamp pushes it to
  the right edge; (b) it picks another display's item window, or the wrong one of several;
  (c) the system shows the item somewhere (an overflow or a Control Center–managed area) the
  in-process frame does not describe.
- Phase 14 (queued before this) makes the popover opaque and keeps the `.window` style. This
  phase keeps Phase 14's look.

## Requirements

1. **Diagnose first, and record the cause in PLAN.md *Verified facts*.** Add a read-only
   diagnostic launch flag modelled on `--report-menu-bar-item` (for example
   `--report-popover-placement`). It uses an in-memory empty host list like the self-tests (no
   `hosts.json` read or written, no refresh engine, no iTerm2 contact). It opens muxFinder's
   own popover by calling its own status item's API in-process (for example its button's
   `performClick(_:)`). That is not an event posted to the system and not accessibility
   scripting. If the orchestrator judges it to be UI scripting under `CLAUDE.md`, drop the
   opening step: report the frames only, and leave the open to the manual checklist. It prints
   the item's frame as AppKit reports it (each status-bar window with its screen,
   `button.window.frame`, `convertToScreen`), the popover window's frame and screen, and every
   `NSScreen`'s `frame` and `visibleFrame`. It closes the popover and exits 0. It never
   changes the status item's visibility or writes the app's defaults (D22, *The app's own
   defaults*).
2. **Placement.** The popover's top edge sits just below the menu bar, centered horizontally
   on the icon, on the display whose menu bar was clicked. It is clamped to stay fully inside
   that display's visible frame, with the usual small inset. No arrow. The width, sizing and
   look stay as they are, Phase 14's opaque background included.
3. **Approach.** Prefer keeping `MenuBarExtra(.window)` if the cause has a fix there. If not,
   replace it with an AppKit `NSStatusItem` (D28's template image) and a borderless panel that
   muxFinder owns. That panel is an `NSPanel` at the menu-bar pop-up level, hosting
   `PopoverView` in an `NSHostingView` and anchored to the status item's button. If step 1
   shows AppKit's button frame cannot be trusted, anchor at the click instead:
   `NSEvent.mouseLocation` in the button's action, on the screen that contains it, below that
   screen's menu bar (`frame.maxY − (frame.maxY − visibleFrame.maxY)`, or
   `NSStatusBar.system.thickness` when the menu bar auto-hides). Record the choice and its
   reason as a new decision (the next free D number), and edit D22 and D28 where they change.
4. **Placement is a pure function with tests.** For example
   `PopoverPlacement.frame(contentSize:anchor:screen:)` (the name is illustrative). Unit tests
   cover:
   - centered below the icon;
   - clamped at the left and right edges;
   - a second display left of or above the main one (negative coordinates);
   - an auto-hiding menu bar;
   - two displays with different scale factors (points, not pixels).
5. **Unchanged behavior:**
   - Clicking the icon toggles the popover. Clicking elsewhere, Esc, or switching apps
     closes it.
   - ↑/↓, Return, ⌘F, ⌘R, ⌘N and ⌘, still reach `AppModel.handle(_:)` before the search
     field, except while an input method is composing.
   - The search field has the focus when the popover opens.
   - `popoverVisibilityChanged` still follows the window. iTerm2 attachment checks run only
     while the popover is visible and are cancelled when it closes (D20, D22).
   - It opens on the active Space and over full-screen apps, like other menu bar extras.
   - Only one popover at a time: a click on another display's icon moves it there.
   - The template icon looks right in light and dark, and on a tinted or transparent menu
     bar.
   - The Settings and onboarding windows, the attach state machine, and quitting
     (`AppTermination`, the 15 s deadline) are unaffected.
   - `--preview-fixtures` still creates no status item. `--selftest` still creates no menu bar
     item.
6. **Conventions:** `///` doc comments, closing-brace comments past 10 lines, sentence case,
   no third-party dependency.

## Acceptance

- Unit tests for the placement function. If the scene changes, also for the status-item
  controller's toggle, close and visibility glue over fakes. The existing UI tests pass
  unchanged.
- The diagnostic's output on this Mac's displays, recorded in `docs/TESTING.md`:
  - **Before the fix:** where the popover opened, and why.
  - **After the fix:** the popover's horizontal middle is within 2 pt of the icon's (unless
    clamped), and its top edge is at the bottom of the menu bar ± 1 pt.
  - If the screen is locked or the display asleep (as in earlier runs), the record says what
    could and could not be measured.
- `scripts/build-app.sh` exits 0 and `codesign --verify --deep --strict build/muxFinder.app`
  passes.
- `--report-menu-bar-item` still shows the item, exits 0 after SIGTERM, leaves no child
  process and creates no `hosts.json`.
- If the scene changed: `docs/ARCHITECTURE.md`, `README.md` (if it describes the popover) and
  the `CLAUDE.md` command notes for any new flag.
- `docs/MANUAL-CHECKLIST.md` gains an item. Click the icon on each display, and after moving
  it with ⌘-drag: the popover opens directly below it. Esc, clicking outside and switching
  apps close it. The keyboard shortcuts work. It also opens over a full-screen app's Space.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`).
  No iTerm2 window is opened, and no `e2e-*` run or self-test is needed unless the change
  touches the attach path.
