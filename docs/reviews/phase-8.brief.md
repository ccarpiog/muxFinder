# Phase 8 review brief — menu bar app and popover

- Repo: `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14, arm64).
  Review the **uncommitted** working tree against `HEAD` (`git diff` plus untracked files).
- Phase and goal: `PLAN.md` "### Phase 8 — Menu bar app and popover" — the popover from
  `docs/REQUIREMENTS.md` "Menu bar interface", wired to the core. Design recorded as **D22** in
  `PLAN.md` *Decisions*. Scope boundary: attach state machine and row actions' real effects are
  Phase 10, Settings/onboarding Phase 9; their `AppModel` intents are placeholders that must
  perform no attach, launch or save.
- Changed files:
  - New: `Sources/MuxFinderUI/` (Model: `AppModel.swift`, `AppEnvironment.swift`,
    `PopoverContent.swift`, `HostStatusLabel.swift`, `SessionActivity.swift`,
    `RelativeTime.swift`, `PopoverKey.swift`, `AppLaunchOptions.swift`; Views:
    `PopoverView.swift`, `HostSectionView.swift`, `SessionRowView.swift`, `PopoverParts.swift`,
    `PopoverWindowBridge.swift`; Preview: `PreviewFixtures.swift`, `PreviewGallery.swift`),
    `Sources/MuxFinderApp/AppDelegate.swift`, `Sources/MuxFinderApp/PreviewAppDelegate.swift`,
    `Tests/MuxFinderUITests/`, `scripts/build-app.sh`, `docs/screenshots/*.png`.
  - Modified: `Package.swift`, `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`, `PLAN.md`
    (D22; Architecture, D11, D20 edits), `CLAUDE.md`, `docs/TESTING.md`.
- Verification already run (orchestrator): `swift build -Xswiftc -warnings-as-errors` exit 0;
  `swift format lint -r Sources Tests` exit 0; `swift test` exit 0 (563 core + 44 UI tests);
  `scripts/build-app.sh` exit 0 (worker); `codesign --verify --deep --strict
  build/muxFinder.app` exit 0; entitlements show `com.apple.security.automation.apple-events`.
  Screenshots rendered in-app via `--preview-snapshot` (screen locked, `screencapture -l`
  failed). Real binary run from the shell: menu bar item reported by `--report-menu-bar-item`,
  SIGTERM exit 0, no `hosts.json` created.
- Risks to probe hardest:
  1. **iTerm2 cookie / contact timing**: no cookie request or any iTerm2 contact at launch;
     only when the popover opens while iTerm2 runs (or on an attach). Any path (start,
     refresh, Retry, preview mode, `--report-menu-bar-item`) that reaches iTerm2 or triggers
     the Automation prompt early is a blocker.
  2. **Engine lifecycle**: `AppModel.start()` / `shutdown()` vs `RefreshCoordinator` and
     `RefreshSystemEvents` (D20): double start, quit during start, observers or tasks left
     running, popover visibility toggling attachment checks correctly, `updates()` consumption
     on the main actor without races or leaks.
  3. **Quit path**: `AppTermination.request()`, SIGTERM/SIGINT sources, `applicationShouldTerminate`
     with `.terminateLater` and the 5 s deadline — hangs, double replies, or quitting that
     detaches/kills anything.
  4. **UI truthfulness**: "Open in iTerm2 here" only from `AttachmentIndex` (a client count
     never implies this Mac); stale marking; status mapping strings exactly as PLAN.md Phase 8
     lists; relative time strings; search filtering and keyboard selection across filtered rows.
  5. **Placeholders**: `open(_:)`, `newSession()`, `openSettings()` must not attach, launch,
     save `hosts.json` or write preferences.
  6. **Preview mode** must not start the engine, run tmux/ssh, read/write `hosts.json`, contact
     iTerm2, or create a menu bar item; `--appearance` affects only the app's windows.
  7. **build-app.sh** per D7: release arm64, Info.plist keys, helper bundled where the launch
     layer finds it, signing identity selection (by hash; identity name contains a non-ASCII
     character), hardened runtime, ad-hoc fallback warning, no notarization claim, `build/`
     git-ignored, no shell source built from runtime values.
  8. Conventions (`CLAUDE.md`): `///` on every declaration, closing-brace comments on >10-line
     functions/loops, sentence-case English UI text, no third-party dependencies.
- Constraints for the reviewer: read-only. Do not run the app, `open`, `osascript`, ssh,
  tmux, or anything that contacts iTerm2. `swift build` / `swift test` are fine.
- Review file: `docs/reviews/phase-8.md`.
- Time budget: 15 minutes.
