# Review brief — Phase I-12b2 (helper plain mode)

- **Repo**: `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 menu bar app
  attaching tmux sessions in iTerm2; Phase I-12 adds Terminal.app and Ghostty through plain
  `tmux attach`). Review the **uncommitted** working tree against `HEAD`.
- **Phase and goal**: I-12b2 — the launch helper's `attach-plain <uuid>` and `profile-plain
  <host id>` modes, the attach request's `terminal` field (and `keepsMinimumLifetime` on plain
  requests), and the early report file `<uuid>.report.json` (helper pid, terminal path, attach
  child pid and start time). The binding spec is `PLAN.md`, block "Calls for I-12b2 (helper
  plain mode; 2026-11-06, before its worker)" under `### Phase I-12`; background in D38 ("The
  plain attach, bound to the recorded session", "Confirmation on This Mac", and the new
  "Helper plain mode (I-12b2)"), D14 (launch protocol, exit codes, 10 s hold; new *Plain
  modes*), D17 (remote attach over ssh), D26 (`profile` mode). Conventions and safety rules:
  `CLAUDE.md`. Nothing in the app or coordinator writes a plain request yet (I-12c).
- **Changed files**: `Sources/MuxFinderCore/Launch/{LaunchHelper,LaunchHelperPath,LaunchHelperProfile,LaunchModels,LaunchStore,PlainLaunch,ProfileLaunch,TerminalChildRunner}.swift`,
  new `Sources/MuxFinderCore/Launch/{LaunchHelperPlain,PlainLaunchReport}.swift`,
  `Sources/MuxFinderCore/Terminals/TerminalDefinitionParser.swift` (`isValidID`),
  `Sources/muxfinder-launch/main.swift`; tests: new
  `Tests/MuxFinderCoreTests/{LaunchHelperPlainTests,PlainLaunchReportTests,LaunchHelperProfilePlainTests,LaunchHelperPlainBinaryTests,PlainLaunchTestSupport}.swift`,
  modified `LaunchModelsTests.swift`; docs `PLAN.md` (the calls, D14, D38), `docs/TESTING.md`
  *Phase I-12b2*, `CLAUDE.md` (launch helper line). `PROGRESS.json` is a workflow record.
- **Verification run (orchestrator, final tree)**: `swift build` exit 0; `swift format lint -r
  Sources Tests` exit 0; `swift test` exit 0 (1022 core tests in 101 suites, 485 UI in 47);
  `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict build/muxFinder.app` exit
  0; regression against real iTerm2: `swift run muxfinder-probe e2e-local` 16/16 and
  `e2e-bury --local` 13/13; nothing left behind. The worker's real plain attach is a `swift
  test` test (`realPlainAttachOnAPseudoTerminal`, a pty and a private tmux server).
- **Risks to look at hardest**:
  1. `attach`, `profile`, `ssh-setup` must be byte-identical in behaviour (argv, bytes written
     to the terminal, exit codes, timings, the 10 s hold). Look at every shared path the
     worker refactored in `LaunchHelper`, `LaunchHelperProfile`, `TerminalChildRunner`
     (new `standardInput:` requirement with a default that ignores it).
  2. The `terminal` field: missing reads as `iterm2`; cross-mode refusals (exit 72, nothing
     run) in both directions; `keepsMinimumLifetime` on an iTerm2 request refused; the id rule.
  3. The plain attach argv must come only from `PlainLaunch` builders over values the guard
     checked (no shell/tmux source built from values; D3); move here (`detachOtherClients`)
     → `-d` / `remoteMoveHereScript`; the token as the remote script's sixth argument.
  4. The child's stdin reopened read-write on the helper's terminal: fd handling, leaks, what
     happens when stdin is not a terminal.
  5. The early report: atomic 0600 write under `LaunchStore`'s directory rules, the child's
     kernel start time, peek never deleting, removal paths (it is deliberately *not* removed by
     `discardRequest`), malformed/oversized → typed failure, races with the sweep.
  6. `profile-plain` keeps `profile`'s 10 s hold (no request to carry the flag) — is that
     right per the calls?
  7. Tests: do they fail on the old code / would they catch a regression; are the real-pty
     tests hermetic (private server, never `kill-server`, cleanup on every path)?
- **Review file**: `docs/reviews/phase-I-12b2.md`.
- **Time budget**: 20 minutes.
