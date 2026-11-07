# Review brief — Phase I-13b2 (install pipeline, eligibility and install)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14 menu bar
  app). Review the **uncommitted** working tree against `HEAD`.
- **Phase and goal:** I-13b2 — the self-update's second core half (no UI, nothing wired into
  the normal app): the running app's update eligibility (its own Developer ID signature and
  Team ID, App Translocation, read-only volume, writable bundle and parent, owned by the user,
  same volume as the staging root), the staging root
  `~/Library/Application Support/muxFinder/update/` with a locked run folder per update, the
  swap of the installed bundle with the verified one (`renamex_np` `RENAME_SWAP`) bound by
  device and inode, with the identity and code check re-run right before it and rollback,
  the detached relauncher (constant `/bin/sh` script, values only as argv), leftover cleanup
  (a run folder deleted only when no process runs from inside it and no update holds its
  lock), the old-helper compatibility analysis (0.2.0 / 0.3.0 helpers vs current, D14), the
  pipeline type (prepare / install / discard) for I-13c, and a read-only app flag
  `--report-update-eligibility`.
- **Spec:** `PLAN.md` *Phase I-13*, block "The orchestrator's calls for I-13b2" (just before
  `## Deferred`), and D39 (search `- **D39 —`), its new part "Eligibility and install
  (I-13b2)". Product spec: `autoclaude/processed/120-update-check-github.md` *Update (only
  after the click)*. Conventions and safety rules: `CLAUDE.md`.
- **Changed files:** new `Sources/MuxFinderCore/Update/{UpdateEligibility,UpdateEligibilityReader,UpdateStagingRoot,UpdateSwap,UpdateRelauncher,UpdatePipeline}.swift`;
  modified `Sources/MuxFinderUI/Model/AppLaunchOptions.swift`,
  `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`; new tests
  `Tests/MuxFinderCoreTests/{UpdateEligibilityTests,UpdateStagingRootTests,UpdateSwapTests,UpdateRelauncherTests,UpdatePipelineTests,UpdateOldHelperCompatibilityTests,UpdateInstallTestSupport}.swift`,
  `Tests/MuxFinderUITests/UpdateEligibilityFlagTests.swift`; docs `PLAN.md` (the calls block
  and D39), `CLAUDE.md`, `docs/TESTING.md`. `PROGRESS.json` is a workflow record.
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources
  Tests` exit 0; `env -u TMUX_TMPDIR swift test`: 1349 core tests in 150 suites + 549 UI tests
  in 56 suites passed; `scripts/build-app.sh` (worker) and `codesign --verify --deep --strict
  build/muxFinder.app` exit 0; `build/muxFinder.app/Contents/MacOS/muxFinder
  --report-update-eligibility` exit 0, "not eligible (notDeveloperID …)" (Apple Development
  build), same volume yes, no `update` folder created in the real support folder. Worker: the
  `RENAME_SWAP` proof on a private folder, the signature reader on a private unpacked copy of
  the stapled 0.2.0 release (Developer ID, Team ID equal to `codesign -dv`'s).
- **Risks to probe (high-risk phase: the app replaces its own bundle):**
  1. The swap: can any path leave `/Applications/muxFinder.app` missing, or the wrong folder
     swapped in or out (identity checks before and after, the re-check of the verified
     bundle's identity and code right before the swap, rollback correctness, a rollback that
     itself fails)? Is a TOCTOU window between the re-check and the swap left open that the
     private 0700 staging folder does not close?
  2. Eligibility: is the running app's Developer ID and Team ID read correctly from
     `SecCodeCopySelf` (requirement text, flags; no revocation/network flags)? Can a
     non-Developer-ID, translocated, read-only or foreign-owned copy be judged eligible?
  3. The relauncher: is the script truly constant, are values only argv, is it detached
     (setsid, `/dev/null` streams, no inherited descriptors), bounded, and does it open
     nothing on timeout? Does any test or code path run `/usr/bin/open` for real?
  4. Cleanup: can it delete a run folder a process still runs from (the old bundle under a
     buried tab's `muxfinder-launch`), one an update in progress holds, or follow a link out
     of the root? Is the `proc_pidpath` scan sound (buffer sizes, pids that vanish, errors
     treated as "in use")?
  5. The staging root and run folders: created only when an update starts, never by
     eligibility or the flag; refusal of links, non-folders, foreign or non-private folders,
     ACLs; device comparison.
  6. The pipeline: cancellation and failure always remove the run folder; discard; states as
     specified; the old bundle never deleted in the same run.
  7. Safety rules: no test or code touches real `/Applications`, `~/Applications`,
     `build/muxFinder.app` or the real support folder; no network; only ad hoc signing; no
     shell source built from runtime values; the flag writes and contacts nothing.
  8. Conventions: `///` doc comments on every function/type, closing-brace comments on
     functions/loops over 10 lines, English, sentence case in user-facing text, reasons free
     of paths, hosts and Team IDs.
- **Review file:** `docs/reviews/phase-I-13b2.md`.
- **Time budget:** 20 minutes.
