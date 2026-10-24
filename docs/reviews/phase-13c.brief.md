# Review brief — Phase 13c (real runs and documents)

- Repo: `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6 SwiftPM macOS menu bar app that
  attaches tmux sessions in iTerm2 via `tmux -CC`). Conventions and binding safety rules:
  `CLAUDE.md`. Review the **uncommitted** working tree against `HEAD`.
- Phase: 13c of Phase 13 "Hide the launch tab once attached" (`PLAN.md` *Phase 13*, the 13c
  bullet near line 3190; design **D29** in *Decisions*; 13a/13b narratives in
  `docs/progress-archive/13a.md`, `13b.md`).
- Goal: run the coordinator's launch-tab bury for real and document it. `e2e-bury` was
  reworked to go through the coordinator's bury (13 steps: attach then buried, detach within
  10 s, after 10 s, timed at the bury, no-`Disinter` recovery, attach child SIGKILLed); both
  self-tests gained "launch tab buried" / "launch tab left" steps; one harness fix from the
  real runs (`takeNewArgvDigests()` in `E2ERun.swift`); documents updated.

## Changed files

- Code: `Sources/muxfinder-probe/{E2EBuryRun,E2EBuryCommand,E2EBurySupport,E2ESupport,E2ERun}.swift`,
  `Sources/MuxFinderCore/ITerm2/RecordingITerm2Integration.swift` (new `setBeforeBury(_:)`
  hook), `Sources/MuxFinderCore/Attach/{AttachCoordinator,AttachModels}.swift` (doc comments),
  `Sources/MuxFinderUI/SelfTest/{SelfTestDriver,SelfTestSeams}.swift`.
- Tests: `Tests/MuxFinderCoreTests/RecordingITerm2IntegrationTests.swift`,
  `Tests/MuxFinderUITests/{SelfTestDriverTests,AttachUITestSupport}.swift`.
- Docs: `README.md`, `CLAUDE.md`, `PLAN.md` (D29, *Verified facts* "Phase 13c real runs"),
  `docs/{ARCHITECTURE,TESTING,INTEGRATION-PROOF,MANUAL-CHECKLIST}.md`.
- Workflow records (not the product): `PROGRESS.md`, `PROGRESS.json`.

## Verification already run (orchestrator, final tree)

`swift build` exit 0; `swift test` 737 core tests (73 suites) + 166 UI tests (14 suites)
passed; `swift format lint -r Sources Tests` exit 0; `codesign --verify --deep --strict
build/muxFinder.app` exit 0. Real runs (worker, gated, after the fix): `e2e-local` 16/16,
`e2e-remote saturno-m4` 17/17, `e2e-bury --local` 13/13, `e2e-bury --ssh saturno-m4` 13/13,
`--selftest attach-local` 8/8, `--selftest new-session-local` 7/7, `e2e-profile --local` 14/14;
leftovers none; `profiles hashes` identical. Logs (read them, they are evidence for the docs'
numbers): `/tmp/muxfinder-13c-logs/` (`gate.log`, `<n>-<name>.log`). Do **not** rerun any real
check (they open iTerm2 windows on the user's live machine); hermetic commands are fine.

## Risks to look at

1. Safety of the reworked `e2e-bury` and self-tests: do they touch only their own
   `muxfinder-test-*` session and their own launch tabs, ask no other tmux connection, bound
   every wait, and clean up on every way out (including the SIGKILL step's pid check, which must
   never match by name)? Could the `setBeforeBury` hook delay or block a real (non-harness)
   attach, or leak into production code paths?
2. Correctness of the harness assertions: can a step pass when the behavior is wrong (e.g. the
   "left by itself" check satisfied by the recovery's `Close`, the "detach at the bury" step
   accepting too much, the auto-hide branch report)? Does `takeNewArgvDigests()` hide a real
   failure?
3. Self-test changes: step counts, keep mode stopping after the buried step, cleanup unchanged
   (detach through the core, never close a tab).
4. Documents: do README/ARCHITECTURE/TESTING/INTEGRATION-PROOF/MANUAL-CHECKLIST/CLAUDE.md/D29
   match the code and the logs (step counts, durations, auto-hide default off, `buriesLaunchTabs`
   on everywhere)? Any user data (session names, titles, ssh host names beyond `saturno-m4` /
   `neptuno-m4` / `sirio-m5`)?
5. Known context: iTerm2 restarted between 12:15 and 12:24 (not the run's doing) and came back
   with its auto-hide key absent (default off); 13a's spike ran with it on.

## Output

Review file: `docs/reviews/phase-13c.md`. Time budget: 20 minutes.
