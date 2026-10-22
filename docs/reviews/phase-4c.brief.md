# Review brief — Phase 4c (real local proof)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS menu bar app).
  Conventions and binding safety rules: `CLAUDE.md`. Review the **uncommitted** working tree
  against `HEAD`.
- **Phase and goal:** Phase 4c of `PLAN.md` "### Phase 4" — make `muxfinder-probe e2e-local`
  pass against the real iTerm2 and the real default tmux server, fix what the real runs reveal,
  and finalize `docs/INTEGRATION-PROOF.md`. Key constraint: iTerm2 shows a modal
  "session ended very soon after starting" warning (threshold 3 s) when a tab's process exits
  quickly, and while it is open the iTerm2 API answers nothing; no tab the app or test creates
  may end within that window, and nothing detaches or ends a launch tab before it is 10 s old.
- **Changed files:** `Sources/MuxFinderCore/Launch/LaunchHelper.swift` (helper never exits
  before its tab is 10 s old, writes its result first), `Sources/MuxFinderCore/Attach/AttachCoordinator.swift`
  (doc comments only), `Sources/muxfinder-probe/E2ELocalCommand.swift`,
  `Sources/muxfinder-probe/E2ESupport.swift` (step 8 fails if the refused tab closes by itself;
  launch-tab age recorded per step), `Tests/MuxFinderCoreTests/LaunchHelperTests.swift`,
  `Tests/MuxFinderCoreTests/LaunchTestSupport.swift`, `PLAN.md` (D14, D15, *Verified facts*),
  `CLAUDE.md`, `docs/INTEGRATION-PROOF.md`, `docs/TESTING.md`. `PROGRESS.json` is a workflow
  record — ignore it.
- **Verification run:** `swift build -Xswiftc -warnings-as-errors` exit 0; `swift test` exit 0,
  342 tests in 33 suites; `swift format lint -r Sources Tests` exit 0; three real
  `env -u TMUX_TMPDIR swift run muxfinder-probe e2e-local` runs, each exit 0 with 9/9 PASS
  (~42.5 s); `muxfinder-probe iterm2 status` exit 0 after each; no tmux server, empty launch
  directory, no `test-mode` marker afterwards. Do NOT run `e2e-local`, `attach` or `detach`
  yourself (they open real iTerm2 windows on the user's machine); `swift build`/`swift test`/lint
  are fine.
- **Risks to probe:**
  1. The helper's 10 s minimum-age wait (`LaunchHelper.swift`): correctness under signals
     (SIGHUP/SIGTERM when iTerm2 closes the tab), under the wait-for-Return failure path, and
     when stdin is not a TTY; result-file ordering (written before the wait); any path that
     can still exit early or hang forever.
  2. Step 8's forced close of the refused launch tab: it must only close the tab the test
     created (by the iTerm2 session id it reported), never a user tab, and never before 10 s.
  3. Abort/failure/signal cleanup paths in `e2e-local` — never ran for real; could they end a
     young tab, leave a test session behind, or touch a non-test session?
  4. Product trade-off: a user detach within 10 s of attaching keeps the launch window open
     until 10 s elapse — check it is documented (D14/D15) and does not break the coordinator's
     state machine or single-flight.
  5. Docs accuracy: `INTEGRATION-PROOF.md` and `TESTING.md` match the code; no user data,
     terminal contents or window titles in docs/fixtures; `CLAUDE.md`/`PLAN.md` edits describe
     present state.
  6. Conventions: `///` doc comments, closing-brace comments on >10-line functions/loops, no
     shell/AppleScript source built from runtime values.
- **Review file:** `docs/reviews/phase-4c.md`.
- **Time budget:** 15 minutes.
