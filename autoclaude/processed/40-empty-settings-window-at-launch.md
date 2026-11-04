# No empty "muxFinder Settings" window at launch

Proposed phase, queued after the plan's remaining work. Suggested risk: **routine** (the app
shell changes; the attach, tmux and iTerm2 paths do not).

## User request (2026-11-04, verbatim)

> When started, muxFinder always shows this empty window.

The screenshot shows a plain, empty, resizable window titled **"muxFinder Settings"** (capital
S), with no tabs and no content.

## Findings (2026-11-04, from the code; nothing was run)

- **It is SwiftUI's placeholder scene, not muxFinder's Settings window.** muxFinder's own
  Settings window is titled "muxFinder settings" (sentence case,
  `Sources/MuxFinderUI/Views/Settings/SettingsWindowController.swift:39`). "<App> Settings" is
  the title SwiftUI gives a `Settings` scene's window.
- `MuxFinderMenuBarApp` (`Sources/MuxFinderApp/MuxFinderMenuBarApp.swift:79-92`) is a SwiftUI
  `App` whose one scene is `Settings { EmptyView() }` with `CommandGroup(replacing:
  .appSettings) {}`. Its doc comment says it exists only for SwiftUI's standard main menu
  (Edit commands for the text fields, Quit, Close) and that "nothing ever opens it". On this
  Mac (macOS 27.x) something does open it at every launch.
- `AppDelegate.applicationShouldHandleReopen(_:hasVisibleWindows:)` already returns `false`,
  so a reopen is not the path; the window appears at launch.
- The window appears in the user's normal launches (Finder, login item, LaunchServices).
  Whether a launch of the bundle binary from the shell shows it too is not known. Find out
  with the app shell check below; never launch through `open`/LaunchServices in an unattended
  run.
- `--report-menu-bar-item` prints only status-bar-level windows, so it could not have caught
  this.

## Requirements

1. **Diagnose first.** Confirm that the window is the `Settings` scene's (for example by
   listing `NSApp.windows` with their titles, classes and visibility in the app shell check),
   and record what opens it in PLAN.md *Verified facts*, or record that a shell launch does
   not reproduce it and why.
2. **No window at launch.** A normal launch shows no window except onboarding (only when
   there is no `hosts.json`). Remove the dependency on a SwiftUI scene that can be opened
   rather than hiding the window after it appears. Two candidates, the worker picks and
   records the reason as a decision (or edits D22/D30):
   - run the menu bar app on a plain `NSApplication` with a hand-built main menu (App menu
     with Quit, Edit with Undo, Redo, Cut, Copy, Paste, Paste and Match Style, Delete and
     Select All, Window with Close and Minimize), as `PreviewAppDelegate` and
     `SelfTestAppDelegate` already run on a plain `NSApplication`; or
   - keep the SwiftUI `App` with a scene that macOS 14+ never opens by itself. This counts
     only if the reason it never opens is documented API behavior, not observed luck, and
     it works on the macOS 14 deployment target.
3. **Nothing else changes.** ⌘C/⌘V/⌘X/⌘A/⌘Z in every text field (popover search, New session
   name and directory, Settings, onboarding, the switcher), ⌘W closes Settings and onboarding,
   ⌘Q and `applicationShouldTerminate`'s orderly shutdown, ⌘, opens muxFinder's own Settings
   window, the accessory activation policy, SIGTERM/SIGINT handling, every launch mode
   (`--preview-fixtures`, `--selftest`, `--report-*`, `--remove-persistent-profiles`).
4. **The shell check sees it.** Extend `--report-menu-bar-item` (or add a line to its output)
   so it also prints the app's other visible windows (title and class, never content), so an
   unexpected window at launch is caught from now on. Update the `CLAUDE.md` command note.

## Acceptance

- The app shell check (`CFFIXED_USER_HOME=$(mktemp -d)
  build/muxFinder.app/Contents/MacOS/muxFinder --report-menu-bar-item &`) lists the menu bar
  item and the onboarding window only, no "muxFinder Settings" window; with a private home
  holding a valid `hosts.json` with every host turned off, no window at all. `kill -TERM`
  exits 0, no child left, no `hosts.json` or `preferences.json` created. Recorded in
  `docs/TESTING.md` before and after the fix.
- Unit tests for any new main-menu builder (the items, their key equivalents and actions).
  Existing tests pass unchanged or with recorded changes.
- Preview galleries and the self-tests still start (their main menu, if they had one, is
  unchanged).
- `docs/MANUAL-CHECKLIST.md` gains an item: launch from Finder and at login, and no window
  appears; the Edit shortcuts work in the popover's search field and in Settings; ⌘Q quits.
- `docs/ARCHITECTURE.md` and the `MuxFinderMenuBarApp` doc comment describe the new shell.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`),
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` pass.
  No iTerm2 window is opened; no `e2e-*` run or self-test is needed (the attach path is
  unchanged).
