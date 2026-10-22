# Review brief — Phase 10b (real self-tests)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6 macOS menu bar app; conventions
  in `CLAUDE.md`, plan in `PLAN.md`, checkpoint in `PROGRESS.md`).
- **Phase and goal:** `PLAN.md` "### Phase 10", the "Split" paragraph, sub-phase **10b**: run
  both app self-tests (`--selftest attach-local`, `--selftest new-session-local`) from the
  shell against the real iTerm2 and local tmux, each exiting 0; run the quit-leaves-work-running
  check (`--selftest attach-local --selftest-keep`, SIGTERM, the tmux session and the iTerm2
  connection persist, then clean up); fix what the runs call for. Design: `PLAN.md` D25.
- **Changed files (uncommitted):** `docs/TESTING.md` (new "### Phase 10b — real self-tests"
  section at the end), `PROGRESS.json` (phase status only). No source file changed: the real
  runs all passed and called for no fix.
- **Verification run (orchestrator):** `swift build` exit 0; `scripts/build-app.sh` exit 0;
  `codesign --verify --deep --strict build/muxFinder.app` exit 0; `muxfinder-probe iterm2
  status` exit 0 before and after; both self-tests exit 0 (6/6 and 5/5 steps); keep mode
  exit 0 after SIGTERM, session and connection persisted, cleanup detach exit 0 and kill exit
  0; `swift format lint -r Sources Tests` exit 0; `swift test` exit 0 (590 core tests in 58
  suites + 138 UI tests in 11 suites). The exact observations are in the new TESTING.md
  section.
- **What to review:**
  1. Whether the new TESTING.md section is accurate and complete against the code that ran:
     the self-test step lists and output format (`Sources/MuxFinderUI/SelfTest/
     SelfTestDriver.swift`, `SelfTestSeams.swift`, `Sources/MuxFinderApp/
     SelfTestAppDelegate.swift`), the probe `detach` semantics (`clean` false without
     `--launch-id`: `Sources/muxfinder-probe/AttachCommand.swift`, `isClean` in
     `Sources/MuxFinderCore/Attach/AttachModels.swift`).
  2. The claim that the orphaned `<launch id>.result.json` left after the keep-mode check is
     by design (D14: the sweep before the next launch removes files older than the 120 s TTL)
     and not a defect: check the sweep in `Sources/MuxFinderCore/Launch/` really runs before
     every launch (attach, new session, move here, ssh setup) and covers result files.
  3. Whether the Phase 10 acceptance in `PLAN.md` is genuinely met by these runs, or whether
     something the acceptance asks for was not exercised (for example, does the keep mode
     really quit through the app's normal termination path, D22's `AppTermination`, and is
     there any way the "quit leaves work running" result could be a false pass?).
  4. Anything in the self-test code paths that the real runs revealed only by luck (races,
     timing assumptions) and that should be recorded as a risk.
- **Known risks / out of scope:** Show tab against the real iTerm2 is still unverified (local
  attaches never reach "still waiting"); the 9b "Set up SSH in iTerm2…" real round trip is
  recorded as owed to the user because it needs an interactive ssh login on Saturno, outside
  the run rules. Do not run anything that contacts iTerm2, tmux or ssh: this review reads code
  and docs only.
- **Review file:** `docs/reviews/phase-10b.md`.
- **Time budget:** 10 minutes.
