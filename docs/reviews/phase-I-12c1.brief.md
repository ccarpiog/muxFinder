# Review brief — Phase I-12c1 (other terminals, the plain backend)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14). Review the
  **uncommitted** working tree against `HEAD` (`06f7d6e`).
- **Phase and goal:** I-12c1 adds `PlainTerminalBackend`, a `TerminalBackend` conformance for
  plain-mode terminals (Terminal.app, Ghostty, user definitions): it writes a plain launch
  request, opens a window through `PlainTerminalWindows`, confirms the attach only from evidence
  (the helper's early report plus tmux's client list locally, the launch token in the remote
  client's parent shell arguments over ssh), detaches and moves here only through D38's bound
  tmux commands, and keeps its attachments in memory. Nothing in the app, self-tests, probe or
  refresh engine uses it yet. The binding spec is `PLAN.md` *Phase I-12*, block "Calls for
  I-12c1"; the record is D38's sub-bullet "Plain backend (I-12c1)"; background D14 *Plain
  modes*, D15, D17, D18, D21, D37, D38.
- **Changed files:** new `Sources/MuxFinderCore/Terminals/{PlainTerminalBackend,PlainTerminalBackendDetach,PlainTerminalBackendModels,PlainTmuxCommands,PlainTerminalBackendFakes}.swift`,
  `Sources/MuxFinderCore/Attach/AttachSharedSteps.swift` (revalidation, current session and
  creation factored out of `AttachCoordinator`); changed `Attach/{AttachCoordinator,AttachModels,DetachOtherClientsModels}.swift`,
  `Launch/PlainBoundCommands.swift` (`PlainClientDetach.condition(of:in:)` split out),
  `Terminals/{PlainTerminalWindows,TerminalBackend}.swift` (a `PlainTerminalWindowLayer`
  protocol), `Sources/MuxFinderUI/Model/{SessionActivity,AppModelSessions,SessionProblem}.swift`
  (exhaustive switches); tests `Tests/MuxFinderCoreTests/PlainTerminalBackend{,Detach,EndToEnd}Tests.swift`,
  `PlainTerminalBackendTestSupport.swift`, `Tests/MuxFinderUITests/AttachFlowTests.swift` (four
  new cases added to a case-index switch, nothing else edited); records `PLAN.md`,
  `docs/TESTING.md` *Phase I-12c1*.
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources Tests`
  exit 0; `swift test` exit 0, 1090 core tests in 107 suites and 486 UI tests in 47 suites
  (baseline 1058 + 485). No real run: nothing is rewired, no terminal app, no iTerm2.
- **Risks to probe hardest:**
  1. **Confirmation soundness.** Can anything other than the launch's own client confirm? Local:
     exactly one client with `client_tty` = report's terminal path AND `client_pid` = the
     report's attach child, that child alive with the report's kernel start time; a report with
     no terminal path never confirms; two candidates never confirm; a malformed/oversized report
     never confirms. Remote: exactly one client whose parent shell's arguments end with the
     launch token. Check the ordering of reads (stale reads, pid reuse, a helper result racing
     the confirmation).
  2. **The coordinator's behaviour unchanged** after `AttachSharedSteps` was factored out
     (revalidation, current session by name, creation): any change in order, failures mapped,
     or published states for iTerm2 is a blocker. Same for `PlainClientDetach`'s split: the
     bound detach command's text must be identical.
  3. **Result types extended additively**: every iTerm2 value and `kind` string unchanged; plain
     states never overload iTerm2's connection or session ids; `isConfirmed`/`isFocused`/
     `isAttached` for plain; UI switches treat plain like the iTerm2 counterpart with no
     iTerm2 behaviour change.
  4. **Detach, move here, detach others** only through bound tmux commands (D38, D37's checks
     and 10 s age guard, the kept client being the record's); never a window close; no record
     → nothing run; a stale D21 confirmation runs nothing. Never shell/tmux source built from
     runtime values (argv arrays; D3 for remote).
  5. **Concurrency:** coalescing of one key's attaches, the unresolved-earlier-launch refusal
     (the worker made it stricter than the coordinator: an attach also waits out an earlier
     plain attach), actor reentrancy across the main-actor window layer hops, records dropped
     when the helper's result appears or the client is gone.
  6. **Tests:** the end-to-end test runs the built helper on a pty against a private tmux server
     (`-f /dev/null`, private `HOME`/`TMUX_TMPDIR`); confirm it can never touch the user's
     server, sessions or terminal apps, and that the hermetic tests would fail on the bugs
     they claim to cover.
  7. The worker's open question: a session name containing `{`, `[` or `]` cannot be checked
     or detached by the bound commands (fails `notWritable`); judge whether that is handled
     safely (nothing wrong attached or detached).
- **Review file:** `docs/reviews/phase-I-12c1.md`.
- **Time budget:** 20 minutes.
