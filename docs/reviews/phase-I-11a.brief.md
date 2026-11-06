# Review brief — Phase I-11a: Detach other clients, proof and core (high)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM; macOS menu bar app that
  attaches tmux sessions in iTerm2 through tmux control mode via a hand-written iTerm2 API client).
- **Review the uncommitted tree** (`git diff` plus untracked files).
- **Goal:** a coordinator call `AttachCoordinator.detachOtherClients(of:confirmation:)` that keeps
  this Mac's iTerm2 attachment of a tmux session and detaches the session's other clients (other
  Macs' iTerm2s, plain clients), sent through iTerm2's tmux connection only. Specification:
  `autoclaude/processed/105-detach-other-clients.md`; the orchestrator's calls and the outcome:
  `PLAN.md` "### Phase I-11"; the new decision **D37** in `PLAN.md` *Decisions*. No UI in this
  phase (I-11b).
- **Changed files:** new `Sources/MuxFinderCore/Attach/AttachCoordinatorDetachOthers.swift`,
  `Sources/MuxFinderCore/Attach/DetachOtherClientsModels.swift`,
  `Sources/muxfinder-probe/E2EDetachOthersCommand.swift`, `E2EDetachOthersRun.swift`,
  `Tests/MuxFinderCoreTests/DetachOtherClientsTests.swift`; modified `AttachCoordinator.swift`,
  `ITerm2/RecordingITerm2Integration.swift`, probe `main.swift`, `AttachTestSupport.swift`,
  `PLAN.md`, `docs/TESTING.md`, `docs/ARCHITECTURE.md`, `CLAUDE.md`.
- **What the proof settled:** option (a) `attach-session -d -t <id>` made iTerm2 3.7.7 close and
  reopen the session's windows (new tab ids locally; no tab remotely) → rejected. Option (b): per
  other client, a read-only `list-clients -f` check of name + pid + session, then
  `detach-client -t '<name>'`, each sent once; names and pids validated before insertion.
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources Tests`
  exit 0; `swift test` 900 core (88 suites) + 468 UI (46 suites) pass. Worker: warnings-as-errors
  build exit 0; real `e2e-detach-others --local` 9/9 and `--ssh saturno-m4` 9/9 on the final
  code; no leftover test sessions, temp folders or launch files (re-checked by the orchestrator).
- **Risks to look at hardest:**
  1. Can any path detach a client of another session, this Mac's kept attachment, or a client
     of the user's other sessions (name reuse between check and detach; the check's filter
     format; validation of names/pids; tmux quoting)? Could `-a`/`-s`/`attach-session -d` ever
     be sent?
  2. A confirmation for another key must run nothing (no listing, no iTerm2 request, no state).
  3. Identity re-check right before sending, as `detach(session:on:)` does; D13 send-once (no
     retries); reply pairing — one command per request.
  4. The kept attachment when several exist (the one `attach(_:)`/Show tab focuses); others
     counted; "not attached here", iTerm2 not running, listing failure mapping.
  5. Typed results and counts correct, including partial failure midway.
  6. `e2e-detach-others` safety: only its own `muxfinder-test-*` session, its own launch tabs
     and its own plain client; bounded waits; cleanup on every way out; `--help` contacts
     nothing; `RecordingITerm2Integration` change does not alter other harnesses' behavior.
  7. Hermetic tests actually exercise the above (would they fail on wrong code?).
  8. Conventions: `///` doc comments everywhere, closing-brace comments on >10-line
     functions/loops, no runtime values in shell source, no user data in docs/logs.
- **Do not** run real e2e commands, contact iTerm2 or ssh; read and run hermetic tests only.
- **Review file:** `docs/reviews/phase-I-11a.md`.
- **Time budget:** 20 minutes.
