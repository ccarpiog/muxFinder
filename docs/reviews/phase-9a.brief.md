# Review brief — Phase 9a, Settings window

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14 menu bar app).
  Conventions and safety rules: `CLAUDE.md`. Plan: `PLAN.md` "### Phase 9" (with its 9a/9b split)
  and the new decision **D23**; related D19 (host list, `HostStore`), D20 (refresh engine), D22
  (menu bar app, `AppModel`, preview fixtures).
- **Phase and goal:** 9a adds the Settings window (Hosts, General, Diagnostics tabs) opened from
  the popover's `openSettings()` and ⌘,; a host editor (name, mode, exclusive "This Mac" with
  D19 demotion, destination with SSH config suggestions, tmux path override with Detect, iTerm2
  profile picker with free-text fallback, enabled toggle, remove with confirmation, Test
  connection with classified status) saving only through `HostStore`; an `invalid` host list
  file kept untouched until the user explicitly chooses "Replace…"; launch at login through a
  seam over `SMAppService.mainApp` with every status mapped; a diagnostics list with "Copy
  diagnostics" (no terminal contents, window titles, command lines, destinations or session
  names); fix-it buttons for Automation-denied and API-disabled errors; Settings preview
  fixtures and screenshots; a read-only `--report-login-item-status` flag. 9b (onboarding,
  "Set up SSH in iTerm2…") is out of scope.
- **Changed files (uncommitted tree):** new `Sources/MuxFinderUI/Model/{SettingsModel,
  SettingsEnvironment,HostDraft,SettingsResults,LoginItem,FixIt,DiagnosticsReport}.swift`,
  `Sources/MuxFinderUI/Views/Settings/`, `Sources/MuxFinderUI/Preview/{SettingsFixtures,
  SettingsGallery}.swift`, `Tests/MuxFinderUITests/{HostEditorTests,SettingsGeneralTests,
  SettingsTestSupport}.swift`; modified `AppModel`, `AppEnvironment`, `AppLaunchOptions`,
  `PopoverContent`, `SessionActivity`, `PreviewFixtures`, popover views, `Sources/MuxFinderApp/`
  entry point and preview delegate, `DiagnosticsLog.swift`, `AppModelTests`, `PLAN.md`,
  `CLAUDE.md`, `docs/TESTING.md`, screenshots. `PROGRESS.json` is a workflow record — ignore.
- **Verification run (orchestrator):** `swift build -Xswiftc -warnings-as-errors` exit 0; `swift
  format lint -r Sources Tests` exit 0; `swift test` exit 0 twice (569 core tests in 55 suites,
  76 UI tests in 6 suites); `codesign --verify --deep --strict build/muxFinder.app` exit 0;
  real support folder still holds only `launch/`.
- **Risks to probe:**
  - Save path: could any flow overwrite an `invalid` or concurrently changed `hosts.json`
    without explicit consent, or bypass `HostStore`'s backup rule? Does Replace keep the old
    file as a backup? Does a save reach the refresh engine with a new config revision?
  - This Mac exclusivity and the "SSH host without a valid destination cannot be enabled"
    invariant: can the draft/editor produce a host list `HostStore` would reject, or silently
    drop edits (unsaved draft lost on selection change without confirmation)?
  - Detect / Test connection: do they use the draft's values without saving, run off the main
    actor, cancel on window close or host change, and never build shell strings from runtime
    values (CLAUDE.md, D3)? A late result applied to a different host?
  - Launch at login: any path that calls register/unregister without a user action; status
    mapping correctness; errors swallowed.
  - Copy diagnostics: any leak of destinations, session names, tmux paths, window titles or
    command lines (CLAUDE.md data rule).
  - Fix-it: correct System Settings URL; no URL built from runtime values.
  - Window management: one reusable window, no duplicate windows, no leaks when reopened;
    the popover's earlier behavior (D22: no iTerm2/cookie at launch, popover close cancels
    the attachment check) unchanged.
  - Profile picker: does opening Settings contact iTerm2 (cookie / Automation prompt) when the
    user did not ask for it, contrary to D22's "iTerm2/cookie only on popover open or attach"?
  - Swift 6 concurrency: `@MainActor` isolation, `Sendable` seams, tasks not leaked.
- **Review file:** `docs/reviews/phase-9a.md`.
- **Time budget:** 12 minutes.
