# Review brief: Phase I-12a — other terminals, proof and decision

- **Repo**: /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS menu bar app; read
  `CLAUDE.md` for conventions and the binding safety rules).
- **Phase and goal**: first sub-phase of I-12 (Terminal.app and Ghostty with plain `tmux attach`
  beside iTerm2's control mode; task statement `autoclaude/processed/110-other-terminal-apps.md`).
  I-12a proves plain-mode confirmation, detach and Move here with pty-hosted clients (no terminal
  app), adds a read-only `muxfinder-probe terminals list`, and records D38 and D3's extension. No
  app, coordinator or `muxfinder-launch` behavior change is allowed in this phase. The
  orchestrator's binding calls are in `PLAN.md` "Phase I-12" (search for "calls for I-12a").
- **Changed files (uncommitted tree)**: new `Sources/MuxFinderCore/Launch/PlainLaunch.swift`,
  `Sources/MuxFinderCore/Terminals/{AutomationPermission,TerminalCommandText}.swift`,
  `Sources/muxfinder-probe/{TerminalsCommand,PlainProofCommand,PlainProofRun,PlainProofTerminal}.swift`,
  tests `Tests/MuxFinderCoreTests/{PlainLaunchTests,TerminalCommandTextTests,AutomationPermissionTests}.swift`;
  modified `Sources/muxfinder-probe/{main,E2EControlClient}.swift`, `PLAN.md` (I-12 section,
  unattended-run rules 1 and 8, D3 extension, D38, verified facts), `docs/TESTING.md`,
  `CLAUDE.md`. Use `git diff` and `git status --short`.
- **Verification run by the orchestrator**: `swift build` exit 0; `swift format lint -r Sources
  Tests` exit 0; `swift test` 925 core (91 suites) + 485 UI (47 suites) passed; `swift run
  muxfinder-probe terminals list` exit 0 (iTerm2 granted; Terminal and Ghostty not running,
  -600); no `muxfinder-test-*` session left on Neptuno or Saturno. Worker: `plain-proof --local`
  9/9, `plain-proof --ssh saturno-m4` 9/9, SIGTERM cleanup exit 143 with nothing left.
- **Risks to check**:
  1. `PlainLaunch.swift` remote script: is it static, with every runtime value (session id,
     token) passed as POSIX single-quoted arguments per D3/D17, never interpolated into script
     source? Is the token validated before use?
  2. Remote identification (token in the parent shell's argv, read with `ps` by `client_pid`):
     can it confirm the wrong client (pid reuse, a token that is a substring of another, two
     candidates), and does it refuse with two candidates? Same for the local `client_tty` match
     (the worker notes pty paths are reused once the controlling process exits).
  3. `TerminalCommandText`: quoting and refusals (`'`, `\`, control characters, `!`, anything
     fish or csh reads differently inside single quotes); can any accepted helper path or token
     change the meaning of the shell source?
  4. `AutomationPermission`: can `terminals list` ever prompt or launch an app (only
     `AEDeterminePermissionToAutomateTarget` with askUserIfNeeded false is allowed)? Is the
     OSStatus mapping right?
  5. The harness (`PlainProof*`): bounded waits, cleanup on every exit path including signals,
     kills only its own `muxfinder-test-*` sessions, never `kill-server`, pty output discarded
     (never logged), no iTerm2 contact.
  6. Records: does D38 claim anything the runs did not prove (the Terminal/Ghostty window runs
     are owed, not done)? Do `CLAUDE.md` and `docs/TESTING.md` match the code's actual flags
     and exit codes?
- **Review file**: `docs/reviews/phase-I-12a.md`
- **Time budget**: 15 minutes.
