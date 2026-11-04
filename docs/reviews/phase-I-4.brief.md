# Review brief: phase I-4 — no empty "muxFinder Settings" window at launch

- Repo: `/Users/ccarpio/Developer/Utils/muxFinder` (native macOS menu bar app, Swift 6, SwiftPM,
  macOS 14 target). Conventions and binding safety rules: `CLAUDE.md`. Review the
  **uncommitted** tree.
- Task statement: `autoclaude/processed/40-empty-settings-window-at-launch.md`. At every normal
  launch the app showed SwiftUI's empty `Settings` scene window ("muxFinder Settings").
- Goal: a normal launch shows no window except onboarding (only without `hosts.json`), by
  removing the openable SwiftUI scene, not by hiding a window; the main menu's behavior is
  otherwise unchanged; the app shell check (`--report-menu-bar-item`) now prints every other
  window (title, class, visibility, level), the launch Apple event and the main menu.
- Changed files: `Sources/MuxFinderApp/{MuxFinderMenuBarApp,AppDelegate}.swift`,
  `Sources/MuxFinderUI/Model/AppLaunchOptions.swift`, new
  `Sources/MuxFinderUI/Views/MainMenu.swift`, new `Sources/MuxFinderUI/Model/AppShellReport.swift`,
  new `Tests/MuxFinderUITests/{MainMenu,AppShellReport}Tests.swift`, `PLAN.md` (new D33, D22 and
  D30 edited, Phase I-4 verified facts), `docs/{ARCHITECTURE,MANUAL-CHECKLIST,TESTING}.md`.
  `CLAUDE.md` and `nonamedownloads.json` hold the **user's** uncommitted edits: out of scope,
  not part of this phase. `PROGRESS.json` is the workflow's marker.
- Verification run by the orchestrator, all exit 0: `swift build` (no warnings); `swift test`
  815 core tests in 81 suites + 336 UI tests in 32 suites; `swift format lint -r Sources Tests`;
  `scripts/build-app.sh`; `codesign --verify --deep --strict build/muxFinder.app`; the shell
  check under an empty `CFFIXED_USER_HOME` showed only the hidden popover panel and the
  onboarding window, SIGTERM exit 0, no child, the home still empty. The worker also ran the
  shell check with a home holding a hosts-off `hosts.json`, `--report-popover-placement` once,
  preview snapshots and `--selftest bogus-name` (exit 2).
- Risks to probe:
  - The main menu now hand-built on a plain `NSApplication`: Quit through `terminate:` and
    `applicationShouldTerminate`'s orderly shutdown; Edit commands reaching SwiftUI text fields
    in the non-activating popover and switcher panels, Settings and onboarding; ⌘W closing
    Settings and onboarding but not breaking the panels; ⌘, behavior unchanged (it was never a
    main-menu item; the popover and switcher handle it).
  - Launch-mode dispatch: every other mode (`--preview-fixtures`, `--selftest`, `--report-*`,
    `--remove-persistent-profiles`) still starts the same way with its own menu; the
    accessory activation policy; SIGTERM/SIGINT handling; anything the SwiftUI `App` lifecycle
    used to provide (delegate adaptor, scene phase, environment, `@main`) that is now lost.
  - The shell report: bounded output, no window contents or user data, never blocking.
  - Docs and `PLAN.md` D33 match the code; tests assert something real.
- Review file: `docs/reviews/phase-I-4.md`. Time budget: 15 minutes.
