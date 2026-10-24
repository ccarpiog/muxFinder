# Review brief — Phase I-1a (muxFinder)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14+ menu bar app).
  Conventions and binding safety rules: `CLAUDE.md`. Review the **uncommitted** working tree.
- **Phase:** I-1a — "Diagnose: placement diagnostic, placement function" (risk high). Plan:
  `PLAN.md` section "### Phase I-1 — Popover under the menu bar icon (high)" (the split, the
  I-1a deliverables and acceptance, and the orchestrator's decision allowing an in-process
  `performClick(_:)` on the app's own button). Full specification:
  `autoclaude/processed/10-popover-under-menu-bar-icon.md`.
- **Goal:** a read-only launch flag `--report-popover-placement` that reports screens, the
  app's status-bar windows, the button's frame and the popover's frame (opening it through
  its own button in-process); a pure placement function
  `PopoverPlacement.frame(contentSize:anchor:screen:)` with unit tests; the diagnosed cause of
  "the popover opens at the far right" recorded in PLAN.md *Verified facts* and
  `docs/TESTING.md`. The app's normal popover must be unchanged in this phase.
- **Changed files:** `Sources/MuxFinderUI/Model/PopoverPlacement.swift` (new),
  `Sources/MuxFinderApp/PopoverPlacementReport.swift` (new),
  `Sources/MuxFinderApp/PopoverPlacementInspection.swift` (new),
  `Tests/MuxFinderUITests/PopoverPlacementTests.swift` (new),
  `Sources/MuxFinderApp/AppDelegate.swift`, `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`,
  `Sources/MuxFinderUI/Model/AppLaunchOptions.swift`,
  `Sources/MuxFinderUI/Model/AppEnvironment.swift`,
  `Tests/MuxFinderUITests/PersistentProfilesSettingsTests.swift`, `PLAN.md`,
  `docs/TESTING.md`, `CLAUDE.md`. (`PROGRESS.json` is a workflow record; ignore it.)
- **Verification run by the orchestrator:** `swift build` exit 0; `swift test` exit 0 (745
  core tests in 74 suites, 187 UI tests in 16 suites); `swift format lint -r Sources Tests`
  exit 0; `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict
  build/muxFinder.app` exit 0; `CFFIXED_USER_HOME=$(mktemp -d)
  build/muxFinder.app/Contents/MacOS/muxFinder --report-popover-placement` exit 1 (popover
  never appeared: SwiftUI's status button has no action/target, so `performClick(_:)` sends
  nothing; screen locked, displays asleep), private home left empty, no process left.
- **Known deviations:** the diagnostic cannot open the popover, so the cause is inferred from
  the window frames (only window 0 holds the real button, at {1415, 1698} on the main
  display; six replica windows sit at placeholder frames, two at the second display's right
  edge {4118/4152, 2139}, four at {0, −30}), not from a measured popover frame. Exit code 3
  (interrupted) was added beyond the spec's 0/1/2.
- **Risks to probe:**
  1. Does `--report-popover-placement` really stay read-only and inert: no `hosts.json` read
     or written, no refresh engine started, no iTerm2 contact, no defaults written, no status
     item visibility change, no persistent profile rewrite, no onboarding window? Check
     `AppEnvironment.placementDiagnostic()`, the delegate path, and that the model is never
     started (could the popover's visibility glue start attachment checks if it did open?).
  2. Bounded waits, the 3 s open limit, the overall deadline, SIGTERM/SIGINT handling: can it
     hang, exit leaving the popover open, or race on the main actor?
  3. Placement math: top edge at the menu bar's bottom, centered on the anchor, clamped with
     the inset inside `visibleFrame`, negative-coordinate displays, auto-hidden menu bar
     fallback (`NSStatusBar.system.thickness`), content wider than the visible frame, screen
     selection for an anchor between or outside screens. Do the tests actually pin each case?
  4. Is the recorded cause supported by the output, or overstated? Is the I-1b
     recommendation (own `NSStatusItem` + `NSPanel`, anchor at the click point snapping to
     the button's rect) sound given the replica windows?
  5. Launch-option parsing: the new flag combined with other mode flags → exit 2; existing
     flags unchanged; `--report-menu-bar-item` unchanged.
  6. Conventions: `///` on every function/type, closing-brace comments past 10 lines,
     sentence case, no user data in docs, CLAUDE.md edited in place (present state).
- **Review file:** `docs/reviews/phase-I-1a.md`.
- **Time budget:** 15 minutes.
