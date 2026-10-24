# Review brief — Phase I-1b: place the popover under the menu bar icon

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14+, arm64 menu
  bar app). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase and goal:** I-1b (risk: high). Clicking muxFinder's menu bar icon must open the
  popover directly below the icon (it opened at the far right of the screen). SwiftUI's
  `MenuBarExtra(.window)` is replaced by muxFinder's own `NSStatusItem` and a borderless
  non-activating `NSPanel` hosting `PopoverView`, placed by the pure `PopoverPlacement` from
  I-1a, with an anchor rule (click point's screen; the real button's rect when the click falls
  in it or when there is no mouse event; never a replica status-bar window's placeholder frame).
- **Specification (binding):** `autoclaude/processed/10-popover-under-menu-bar-icon.md`,
  especially requirement 5 (unchanged behaviors) and the acceptance list. Plan: `PLAN.md` Phase
  I-1 (the I-1b bullet), *Verified facts* "Phase I-1a placement diagnostic", new decision
  **D30**, edited D22 and D28.
- **Changed files (uncommitted tree):** new `Sources/MuxFinderUI/Model/{PopoverAnchoring,
  PopoverController}.swift`, `Sources/MuxFinderUI/Views/{MenuBarPopover,MenuBarIcon}.swift`,
  `Tests/MuxFinderUITests/{PopoverAnchoringTests,PopoverControllerTests}.swift`; deleted
  `Sources/MuxFinderUI/Views/MenuBarIconLabel.swift`; modified
  `Sources/MuxFinderApp/{MuxFinderMenuBarApp,AppDelegate,PopoverPlacementReport}.swift`,
  `Sources/MuxFinderUI/Model/{PopoverPlacement,AppLaunchOptions}.swift`,
  `Sources/MuxFinderUI/Views/{PopoverWindowBridge,PopoverView,PopoverStyle}.swift`,
  `Tests/MuxFinderUITests/MenuBarIconTests.swift`; docs `PLAN.md`, `CLAUDE.md`, `README.md`,
  `docs/{ARCHITECTURE,TESTING,MANUAL-CHECKLIST}.md`. (`PROGRESS.json` is a workflow record.)
- **Verification already run (orchestrator, final tree):** `swift build` exit 0; `swift test`
  745 core (74 suites) + 211 UI (20 suites) pass; `swift format lint -r Sources Tests` exit 0;
  `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict build/muxFinder.app` exit
  0; app shell check (`--report-menu-bar-item` under an empty `CFFIXED_USER_HOME`): 7 windows,
  SIGTERM exit 0, no child, home empty; `--report-popover-placement` under an empty home: exit
  0, panel {{1251, 1530}, {360, 168}}, middle x 1431 = anchor 1431, top 1698 = menu bar bottom
  1698, both checks pass, no child, home empty. **The screen was locked and both displays
  asleep**, so the panel never became key: focus, keys and real clicks are unverified (manual
  checklist item 16).
- **Risks to probe:**
  1. Requirement 5 regressions: toggle (the resign-key-then-reopen bug, both orders), Esc,
     click outside (global mouse-down monitor: installed only while open, removed on every
     close path, no Accessibility permission needed), app switch, a click on another
     display's icon moves the panel rather than closing it, one panel at a time.
  2. Keys and focus in a non-activating `NSPanel`: can it become key (`canBecomeKey`), does the
     search field get focus on open, do ↑/↓, Return, ⌘F, ⌘R, ⌘N, ⌘, still reach
     `AppModel.handle(_:)` before the search field, except while an input method is composing;
     do Edit-menu key equivalents (⌘C/⌘V/⌘A) still work in the text field for an accessory app;
     can the empty SwiftUI `Settings` scene ever open a blank window (⌘, through the main menu,
     reopen, `applicationShouldHandleReopen`).
  3. `popoverVisibilityChanged` now driven by the controller (open and not occluded): iTerm2
     attachment checks must run only while visible and be cancelled on close (D20, D22); no
     path that leaves the model thinking it is visible after the panel closed (Esc, outside
     click, screen change, quit).
  4. Placement: the anchor rule in pure code, the button rect vs a replica's placeholder frame,
     clamping, multiple displays with negative coordinates, auto-hiding menu bar; the panel
     following content size changes; screen-parameter changes.
  5. Spaces and levels: collection behavior for all Spaces and full-screen apps; level.
  6. Lifecycle: `--preview-fixtures` and `--selftest` create no status item; quitting
     (`AppTermination`, the 15 s deadline) unchanged; the status item retained; no retain
     cycles in event monitors and notification observers; Swift 6 main-actor isolation.
  7. The diagnostic: still read-only (no `hosts.json`, engine, iTerm2, defaults, status item
     visibility change), bounded (≤ 3 s open, 10 s deadline, watchdog), its exit codes, and
     that its click goes through muxFinder's own button action (no synthesized events, no
     private API).
  8. Records: D30 and the D22/D28 edits accurate; `CLAUDE.md` notes describe present state
     (no stale "Under `MenuBarExtra`…" sentences); TESTING "after the fix" matches the numbers
     above; doc comments and closing-brace comments per the conventions.
- **Do not** run the app, `e2e-*`, `--selftest`, or anything that contacts iTerm2 or opens
  windows; reading code and running `swift build` / `swift test` is fine.
- **Review file:** `docs/reviews/phase-I-1b.md` (overwrite).
- **Time budget:** 20 minutes.
