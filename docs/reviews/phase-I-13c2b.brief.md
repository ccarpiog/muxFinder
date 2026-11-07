# Review brief: Phase I-13c2b — the update views

- **Repository:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14 menu bar
  app). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase and goal:** I-13c2b (routine). The popover's update notice renders I-13c2a's update
  flow (`UpdateModel.flow`, whose behaviour must not change): one pure, tested mapping of the
  shown release, `UpdateFlow.offer` and `UpdateFlow.state` into the notice's lines and buttons
  (shown, enabled); per state Update / Download with the reason, "Downloading… 40%" with a bar
  and Cancel, "Checking the download…", the ask (what is unsaved, "Attached tmux sessions are
  not affected.", Quit and install / Not now), Install and relaunch, "Installing…",
  "Relaunching…", the failure line with a Release page link and Update again or Download;
  VoiceOver labels, the bar's value, announcements for a failure and the ask; 13 synthetic
  `popover` gallery states and regenerated screenshots; docs.
- **Specification:** `PLAN.md` *Phase I-13*, "The orchestrator's calls for I-13c2b" (just
  before "## Deferred"); D39's "The notice (I-13c1)", "The update flow (I-13c2a)" and the new
  "The update views (I-13c2b)" parts, and its "Not yet" line; the spec
  `autoclaude/processed/120-update-check-github.md` (*UI*).
- **Changed files (uncommitted):** `Sources/MuxFinderUI/Model/UpdateNoticeContent.swift` (new),
  `Sources/MuxFinderUI/Model/UpdateModel.swift`, `Sources/MuxFinderUI/Model/AppModel.swift`,
  `Sources/MuxFinderUI/Views/UpdateViews.swift`, `Sources/MuxFinderUI/Views/PopoverView.swift`,
  `Sources/MuxFinderUI/Preview/UpdateFixtures.swift`,
  `Tests/MuxFinderUITests/UpdateNoticeContentTests.swift` (new),
  `Tests/MuxFinderUITests/UpdateNoticeViewTests.swift` (new), `PLAN.md` (D39),
  `docs/TESTING.md`, `docs/MANUAL-CHECKLIST.md` (item 32),
  `docs/screenshots/popover-states-{light,dark}.png`. `PROGRESS.md` and `PROGRESS.json` are
  workflow records, not under review.
- **Verification run (orchestrator, final tree):** `swift build` exit 0; `swift format lint -r
  Sources Tests` exit 0; `env -u TMUX_TMPDIR swift test`: 601 UI tests in 60 suites and 1366
  core tests in 152 suites passed; `codesign --verify --deep --strict build/muxFinder.app` exit
  0 (bundle built after the last source edit). The worker also ran `scripts/build-app.sh`, both
  `--preview-snapshot` galleries, `--report-menu-bar-item` and `--report-popover-placement` on
  private homes (exit 0, homes left empty); the real support folder has no `update` folder or
  `update-state.json`.
- **Worker's declared deviation:** `canUpdate` gates only the Update button; Download shows
  whenever the offer is Download (the calls read literally would never show "failed with
  Download", since `canUpdate` is false for a Download offer). Recorded in D39 — check that
  reading is sound and nothing offers Update when it should not.
- **Risks to look at hardest:**
  1. The mapping's completeness and correctness: every state × offer combination, which
     buttons show and are enabled (no Update while a prepare runs, none while installing or
     relaunching, Update again only while `canUpdate`), the version line and What's new kept
     except while installing or relaunching; `prepared` and `reading` without buttons.
  2. Do the views really render only through the mapping (no second source of truth), and does
     each button call exactly its flow method? Is the Release page always opened through the
     injected opener with the release's `html_url`, never through `NSWorkspace` or a URL in a
     line?
  3. Announcements: a failure and the ask announced once when they appear, not repeatedly on
     every re-render or state echo, and never in the switcher; no announcement leaking from the
     gallery or tests.
  4. Did the view seam for fixtures (`UpdateFlowFixture`) change `UpdateFlow`'s behaviour or
     let a fixture reach a pipeline, scheduler or request?
  5. Fit: long reasons and two-item unsaved lists wrap, buttons never truncate, the popover
     stays within `PopoverHeightLimit`; the switcher still shows no notice.
  6. Strings: sentence case, no path, URL, host or header in any line; VoiceOver labels name
     the action and the version.
  7. Docs (D39 part and "Not yet", TESTING section, checklist item 32) match the code.
- **Review file:** `docs/reviews/phase-I-13c2b.md`.
- **Time budget:** 20 minutes.
