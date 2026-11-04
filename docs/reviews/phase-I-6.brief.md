# Review brief — Phase I-6: New session, Tab moves from Name to Directory

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 menu bar app).
  Conventions and binding safety rules: `CLAUDE.md`.
- **Phase and goal:** Phase I-6 (routine), from the inbox. Specification (user's report
  verbatim, findings, requirements, acceptance):
  `autoclaude/processed/60-new-session-tab-between-fields.md`. In the New session form (shared
  by the popover and the session switcher panels) Tab from Name must reach "Directory
  (optional)" and ⇧Tab go back; with keyboard navigation on, also the host picker, the list
  button, Cancel and Create; Tab never leaves the panel, closes it or reaches the list behind
  the form; the directory list keeps its keys; marked text goes to the input method.
- **Review the uncommitted tree** (`git diff` plus untracked files). Ignore `CLAUDE.md` and
  `nonamedownloads.json`: the user's own uncommitted edits, not this phase's. `PROGRESS.json`
  is the workflow's.
- **Cause found (worker's diagnosis, in-process, no synthesized events):** `PopoverPanelWindow`
  never recalculated its key view loop (AppKit's default off); the loop built when the panel
  first showed its list was never redone, so after the form replaced the list the Name field's
  next key view was a SwiftUI host that takes no focus. **Route: native** —
  `autorecalculatesKeyViewLoop = true` in `Sources/MuxFinderUI/Views/MenuBarPopover.swift`.
  Tab with the directory list open moves on and leaves the list open (its rows are not key
  views). No `PopoverKey` maps Tab.
- **Changed files:** `Sources/MuxFinderUI/Views/{MenuBarPopover,SessionPanelViews,DirectoryPickerViews}.swift`
  (the fix; placeholder constants extracted), new diagnostic
  `Sources/MuxFinderUI/Preview/KeyViewLoopReport.swift` with
  `Sources/MuxFinderUI/Model/AppLaunchOptions.swift` and `Sources/MuxFinderApp/PreviewAppDelegate.swift`
  (`--preview-fixtures --preview-key-view-loop popover|switcher`: the real panel over fixtures,
  made key for ~10 s, prints the key view loop, exit 0/1/2; the preview app no longer quits on
  its last window closing in that mode), new `Tests/MuxFinderUITests/NewSessionTabOrderTests.swift`
  (4 tests, one suite serialized); docs `PLAN.md` (D30, D31, D32, *Verified facts* "Phase I-6",
  Phase I-6 section), `README.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md` (key view chain
  before and after), `docs/MANUAL-CHECKLIST.md` (new item 20).
- **Verification run (orchestrator, final tree):** `swift build` exit 0; `swift test` 815 core
  (81 suites) + 354 UI (34 suites) passed; `swift format lint -r Sources Tests` exit 0;
  `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict build/muxFinder.app` exit 0;
  attach gallery snapshot exit 0 (worker: popover, attach, switcher galleries light and dark,
  unchanged). No real key press (forbidden; checklist 20).
- **Risks to probe:**
  1. Is the diagnosis right, and does `autorecalculatesKeyViewLoop` alone give the required
     order in both panels (Name → Directory → list button → Cancel → Create → Host → Name),
     with keyboard navigation off (text fields only) and on? Can Tab reach the switcher's or
     popover's list behind the form, its search field, or leave the panel? Does the popover's
     list view (not the form) change Tab behavior in a way that matters (search field, rows)?
  2. Does recalculating the loop interfere with the panels' existing key routing
     (`PanelKeyTrackingView`, ⌥↓/↑/↓/Return/Esc, ⌘F/⌘N/⌘R/⌘,), the search field's initial
     focus, the switcher's `.task` Name focus, or Phase I-5's click hold?
  3. The diagnostic flag: read-only and bounded as `CLAUDE.md` requires of diagnostics? It
     makes a non-activating panel key for ~10 s (takes the focus from the frontmost app); any
     posted event, engine, host list, iTerm2 contact or file write? Exit paths and signal
     handling; the quit-on-last-window change limited to that mode?
  4. Are the new tests meaningful (do they fail with the fix reverted, as the worker says two
     do) and hermetic (no window shown on screen where avoidable, no focus taken)?
  5. Docs true to the code; the Tab-while-list-open decision recorded.
- **Review file:** `docs/reviews/phase-I-6.md`.
- **Time budget:** 12 minutes.
