# Review brief — Phase 6b (Move here)

- Repo: /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS menu bar app; see
  `CLAUDE.md` for conventions and binding safety rules).
- Phase and goal: `PLAN.md` "### Phase 6", Split bullet "6b — Move here". `moveHere` on the
  attach coordinator runs `tmux -CC attach-session -d` through the existing launch flow (guard,
  launch tab, connection confirmation, 10 s minimum tab age, single flight, typed failures),
  local and remote over ssh, reachable only with an explicit confirmation value. A session
  already attached in this Mac's iTerm2 fails `alreadyAttachedHere` and runs nothing. New
  decision **D21** in `PLAN.md`; D14–D17 edited.
- Changed files (uncommitted tree): `Sources/MuxFinderCore/Attach/{AttachCoordinator,
  AttachModels}.swift`, `Sources/MuxFinderCore/Launch/{LaunchModels,LaunchGuard,RemoteLaunch,
  LaunchHelper,LaunchArgvDigest}.swift`, `Sources/muxfinder-probe/{E2ERun,E2ESupport,
  E2ELocalCommand,E2EControlClient}.swift`, `Tests/MuxFinderCoreTests/{LaunchTestSupport,
  MoveHereLaunchTests,MoveHereCoordinatorTests}.swift`, `PLAN.md`, `CLAUDE.md`,
  `docs/TESTING.md`, `docs/INTEGRATION-PROOF.md`.
- Verification run: `swift build -Xswiftc -warnings-as-errors` exit 0; `swift test` exit 0
  (557 tests, 54 suites); `swift format lint -r Sources Tests` exit 0; real `e2e-local` exit 0,
  16/16 (new step 15 = Move here). Real `e2e-remote saturno-m4` not yet run (iTerm2 thread
  gate) — do not run it, nor any real e2e/iTerm2 command; the review is static plus hermetic
  tests only.
- Risks to probe:
  1. Can `attach` (non–move-here) ever produce `-d`, locally or remotely? Is the confirmation
     really unavoidable (no default, no path that builds a move-here request without it)?
  2. D3: is the remote move-here script fully static, arguments single-quoted, no runtime text
     spliced into shell source? Does the remote guard run before `exec tmux … -d`?
  3. Request-file backward compatibility (field absent ⇒ normal attach) and the helper's
     handling of the field; the test-mode argv digest truthfully reflecting `-d`.
  4. `alreadyAttachedHere` check: race and failure-policy interplay with the D16 index (index
     failure, unknown/unmapped/ambiguous connections) — could `-d` detach our own iTerm2
     connection or a user's iTerm2 connection on this Mac?
  5. Single flight between attach and moveHere for the same session (generations, cancellation,
     state published to the right caller).
  6. E2E harness safety: the plain control client (local and over ssh) is always ended on every
     failure path, bounded timeouts, only `muxfinder-test-*` sessions touched, no terminal
     contents logged, no remote file writes, ssh options noninteractive.
- Review file: `docs/reviews/phase-6b.md` (verdict line `ship`, `ship-with-fixes` or
  `do-not-ship`, then BLOCKERS and SHOULD-FIX with file:line).
- Time budget: 15 minutes.
