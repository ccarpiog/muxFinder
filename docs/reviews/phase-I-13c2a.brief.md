# Review brief: Phase I-13c2a — the update flow (model and wiring)

- **Repository:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14 menu bar
  app). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase and goal:** I-13c2a (high). The one-click update's flow in the model, wired into the
  app in normal mode only, with no visible UI change: the offer (eligibility read once per
  notice version off the main actor; Update or Download with a reason phrase), prepare with
  progress and Cancel, the failure state, the ask before quitting over unsaved work (New
  session draft text, unsaved Settings edits), install, quit through an injected terminator
  after `relaunchScheduled`, quit during prepare or install, a prepared update discarded at
  quit, leftover cleanup at launch only when `createsUpdateMachinery`.
- **Specification:** `PLAN.md` *Phase I-13*, "I-13c2 split" and "The orchestrator's calls for
  I-13c2a" (just before "## Deferred"); D39's "Eligibility and install (I-13b2)", "The notice
  (I-13c1)" and the new "The update flow (I-13c2a)" parts; the spec
  `autoclaude/processed/120-update-check-github.md` (*Update*, *UI*).
- **Changed files (uncommitted):** `Sources/MuxFinderUI/Model/UpdateFlow.swift` (new),
  `Sources/MuxFinderUI/Model/UpdateModel.swift`, `Sources/MuxFinderUI/Model/AppModel.swift`,
  `Sources/MuxFinderUI/Model/AppModelNewSession.swift`,
  `Tests/MuxFinderUITests/UpdateFlowTests.swift` (new),
  `Tests/MuxFinderUITests/UpdateModelTests.swift`, `PLAN.md`, `docs/TESTING.md`, `CLAUDE.md`.
  `PROGRESS.json` is a workflow record, not under review.
- **Verification run (orchestrator, final tree):** `swift build` exit 0; `swift format lint -r
  Sources Tests` exit 0; `env -u TMUX_TMPDIR swift test`: 583 UI tests in 58 suites and 1365
  core tests in 152 suites passed. Worker also ran `scripts/build-app.sh`, `codesign --verify`,
  `--report-update-eligibility`, `--report-menu-bar-item` and `--report-popover-placement` on
  private homes (exit 0, homes left empty); the real support folder has no `update` folder.
- **Risks to look at hardest:**
  1. Quitting: the terminator only after `relaunchScheduled`; a quit while installing never cuts
     the swap in half (bounded wait), a quit while preparing cancels, a never-installed
     prepared update discarded (bounded) — and none of this can hang `applicationShouldTerminate`
     / `AppModel.shutdown()` past the relauncher's wait.
  2. Concurrency and reentrancy on the main actor: one prepare at a time, Cancel racing a
     finishing prepare, Update tapped twice, Not now then Install and relaunch with unsaved work
     appearing or vanishing, a newer notice version arriving mid-flow, eligibility read results
     arriving for an outdated notice version.
  3. The normal-mode gate: no pipeline, no cleanup, no staging root created in any non-normal
     mode (previews, every `--report-*`, `--selftest*`, `--remove-persistent-profiles`); the
     cleanup never creating the root when absent; never blocking launch.
  4. The real composition: `/usr/bin/open` and the absolute installed path passed to the
     relauncher only in the real app; tests never reach `/usr/bin/open`, a real swap, a server
     or the real support folder.
  5. Unsaved-work detection: does it really see a New session window with text and Settings'
     dirty state (both its host editor and directory list), and nothing else?
  6. Failure phrases: each typed reason mapped, no path, host or Team ID in a phrase.
  7. Docs (D39 part, TESTING section, CLAUDE.md line) match the code.
- **Review file:** `docs/reviews/phase-I-13c2a.md`.
- **Time budget:** 20 minutes.
