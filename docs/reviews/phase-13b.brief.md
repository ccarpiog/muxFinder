# Review brief — Phase 13b (coordinator, race and recovery)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS menu bar app that
  attaches tmux sessions in iTerm2 via `tmux -CC`). Review the **uncommitted** working tree
  against `HEAD` (`0284b84`, Phase 13a).
- **Phase goal:** once an attach is confirmed and step 9 returned `.activated(tabID:)`, the
  attach coordinator buries the launch tab (tmux gateway) it opened, once per launch, for
  `attach`, `createAndAttach` and `moveHere`; closes the race with the helper's own restore by
  order (bury → non-consuming peek at the helper's result + ownership check → `setBuried(false)`
  when either holds); remembers buried tabs (latest 64, memory only) and recovers them on a 2 s
  timer and on attach/detach/attachment checks (restore; forced `Close` of a clean dead tab with
  statuses and absence checked; a failed one left visible; a swept result restored and left
  visible); `showLaunchTab` restores before activating and never overlaps a bury of the same
  tab; fakes gain buried state; `e2e-local` / `e2e-remote` assert buried after confirmation and
  gone by itself after each detach, cleanup checks every `Close`.
- **Spec:** `PLAN.md` *Phase 13* (design items 2, 3, 5, 6, 7; the 13b bullet; source facts
  S1–S8) and **D29** (edited by this phase), plus D14/D15/D25 edits. Conventions and binding
  safety rules: `CLAUDE.md`.
- **Changed files:** `Sources/MuxFinderCore/Attach/{AttachCoordinator,AttachModels,AttachSeams}.swift`,
  new `Sources/MuxFinderCore/Attach/AttachCoordinatorBurial.swift`,
  `Sources/MuxFinderCore/Launch/LaunchStore.swift` (`peekResult`),
  `Sources/MuxFinderCore/ITerm2/FakeITerm2Integration.swift`,
  `Sources/muxfinder-probe/{E2ERun,E2ESupport,E2EBurySupport,E2EBuryRun,AttachCommand}.swift`,
  tests `Tests/MuxFinderCoreTests/{AttachTestSupport,AttachCoordinatorTests,ShowLaunchTabTests,
  LaunchStoreTests,PersistentProfileRunTests,CreateAndAttachTests,AttachFocusTests}.swift`, new
  `Tests/MuxFinderCoreTests/LaunchTabBurialTests.swift`,
  `Tests/MuxFinderUITests/{AttachUITestSupport,AttachFlowTests}.swift`, `PLAN.md`.
  (`PROGRESS.json` is a workflow record, not part of the review.)
- **Verification run (orchestrator, exit 0 each):** `swift build` (no warnings); `swift test`
  731 core tests in 72 suites + 163 UI tests in 14 suites; `swift format lint -r Sources Tests`.
  No real run (hermetic phase; 13c runs `e2e-*` and the self-tests for real).
- **Worker-declared deviations to judge:**
  1. Recovery waits 15 s (`buriedTabCloseDelay`) after a clean result before treating a
     still-listed tab as dead and closing it (the helper can live ~12 s after a clean result).
  2. A swept result (older than D14's 120 s TTL) is detected only through connection listings
     the coordinator already makes (existing-attachment check, `detach(session:on:)`), and only
     when no connection was filtered out — not the refresh engine's checks.
  3. New `Configuration.buriesLaunchTabs` (default on), turned off for `e2e-bury` because the
     spike buries by itself; 13c must turn it back on.
  4. Bury and Show tab wait on each other both ways; a refused restore ends Show tab with
     nothing activated; probe attach JSON gains `burial` and `timingsMs.buried`.
- **Risks to probe hardest:**
  - Race correctness: every interleaving of bury answer / timeout, helper result write, peek,
    `detach` taking the result, `sweep()` deleting it. Can a bury be left in place after the
    helper's last restore (a stranded dead buried session)? Can the peek consume or race the
    result `detach` needs?
  - Can recovery or cleanup ever `Close` or restore a session muxFinder did not open, or a live
    tab (a user's work)? Is the forced `Close` bound to the coordinator's own launch tab id?
  - Bury exactly once per launch with coalesced callers; never for focused, `.noTab`, failed
    activation, failed/unconfirmed attach.
  - Timer lifecycle: does the 2 s timer stop when the list empties, avoid leaking tasks, and
    stay off iTerm2 until a result exists? Does app shutdown / quit deadline still hold (D22)?
  - Actor reentrancy across awaits in the coordinator; Swift 6 sendability.
  - `e2e-local` / `e2e-remote` new assertions and cleanup: bounded waits, only the run's own
    tabs, a stranded gateway fails the step before cleanup; cleanup still never closes a tmux
    tab to detach.
  - Do the unit tests actually exercise the race orders and fail without the code?
  - Conventions: `///` doc comments everywhere, closing-brace comments on >10-line
    functions/loops, no user data in logs/diagnostics.
- **Review file:** `docs/reviews/phase-13b.md`.
- **Time budget:** 20 minutes. Do not run any `e2e-*`, `--selftest`, `iterm2 …`, `attach`,
  `detach` or anything that contacts iTerm2, ssh or a real tmux server; `swift build` /
  `swift test` are fine.
