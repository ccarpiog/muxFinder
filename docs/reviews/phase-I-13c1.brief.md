# Review brief: Phase I-13c1 (update UI: the notice)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (native macOS menu bar app, Swift 6,
  SwiftPM). The change is the **uncommitted working tree** against `HEAD` (`53702db`).
- **Phase and goal:** I-13c1, risk high. Wire the existing update-check core
  (`Sources/MuxFinderCore/Update/`, I-13a) into the app **in normal launch mode only**, and add
  the popover notice "muxFinder <version> is available" with "What's new", the menu bar icon's
  dot (drawn at runtime into the template image) and accessibility label, the seen version
  written through a new scheduler actor method, and Settings › General's toggle "Check for
  updates automatically", the "Check for updates…" button and a status line; gallery states
  and regenerated screenshots. No download or install flow (that is I-13c2).
- **Spec (binding):** `PLAN.md` "The orchestrator's calls for I-13c1" (search that phrase), D39
  (search `**D39 —`, its new "The notice (I-13c1)" part and the "Not yet" line), the user's
  specification `autoclaude/processed/120-update-check-github.md` (*UI*), and `CLAUDE.md`'s
  safety rules (no request to any server in a test or run; no diagnostic mode creates the
  update transport, scheduler or state store).
- **Changed files:** `Sources/MuxFinderCore/Update/UpdateScheduler.swift`,
  `Sources/MuxFinderApp/AppDelegate.swift`, `Sources/MuxFinderUI/Model/{AppLaunchOptions,
  AppEnvironment,AppModel,SettingsModel,UpdateModel}.swift`, `Sources/MuxFinderUI/Views/{MenuBarIcon,
  MenuBarPopover,PopoverView,UpdateViews}.swift`, `Sources/MuxFinderUI/Views/Settings/GeneralSettingsView.swift`,
  `Sources/MuxFinderUI/Preview/{PreviewFixtures,PreviewGallery,SettingsFixtures,SettingsGallery,UpdateFixtures}.swift`,
  tests `Tests/MuxFinderUITests/UpdateModelTests.swift`,
  `Tests/MuxFinderCoreTests/UpdateNoticeSeenTests.swift`; docs `PLAN.md` (the I-13c split and
  calls are the orchestrator's; D39's I-13c1 part is the worker's), `CLAUDE.md`,
  `docs/TESTING.md`, `docs/MANUAL-CHECKLIST.md`, four `docs/screenshots/*-states-*.png`.
  `PROGRESS.json` is a workflow record, not part of the change.
- **Verification run (orchestrator, exit 0 each):** `swift build`; `swift format lint -r
  Sources Tests`; `env -u TMUX_TMPDIR swift test` (566 UI tests in 57 suites, 1363 core tests
  in 152 suites, all passed); `scripts/build-app.sh`; `codesign --verify --deep --strict
  build/muxFinder.app`. The worker also ran `--report-menu-bar-item` and
  `--report-popover-placement` on private homes (no update state left) and the four
  `--preview-snapshot` runs.
- **Risks to probe:** (1) any path by which a non-normal mode (preview, any `--report-*`,
  `--selftest*`, removal) or a test could create `URLSessionUpdateTransport`, the real
  `UpdateStateStore` or a started scheduler, or read/write `update-state.json`; (2) the
  scheduler started more than once, never stopped, or blocking launch; toggle changes not
  reaching `setAutomaticChecks`; (3) the notice or dot shown for an equal, older or malformed
  version, the kept release not counted at launch, or the dot not clearing/returning per the
  seen-version rule; races in `markNoticeSeen` versus the scheduler's own state writes
  (lost update of `etag`/`keptRelease`), and a seen version written when the notice was not
  actually shown; (4) the template image with the dot no longer a template or not legible;
  (5) "What's new" opening anything other than the parser-validated `html_url`, or opening in
  tests/galleries; (6) Settings toggle saved through anything but `PreferencesStore`'s rules,
  or the button not disabled while checking; status phrases leaking URLs/headers; (7) Swift 6
  concurrency issues (main-actor isolation of the `updates()` observer, task lifetime); (8)
  convention gaps: `///` doc comments on every function and type, closing-brace comments on
  functions/loops over 10 lines, sentence case UI strings.
- **Review file:** `docs/reviews/phase-I-13c1.md`.
- **Time budget:** 20 minutes.
