# Phase 6a review brief

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS menu bar app that
  attaches tmux sessions in iTerm2 via `tmux -CC`). Review the **uncommitted** working tree
  against `HEAD`.
- **Phase:** 6a — new session and vanished sessions (risk: high). Spec: `PLAN.md` *Phase 6* and
  its 6a/6b split; design recorded as new decision **D18** in `PLAN.md` *Decisions*, plus Phase 6a
  entries in *Verified facts*. Conventions and binding safety rules: `CLAUDE.md`, `PLAN.md`
  *Unattended-run rules*.
- **Goal:** `TmuxCommands` creates a named tmux session detached (collision check with
  `has-session -t '=<name>'` and tmux's duplicate-session error, `-c <dir>` with `~/` expansion
  on the target host, missing-directory error, `new-session -d -P -F` output parsed into the
  attach target), locally via argv and remotely via ssh with BatchMode running a static script
  with POSIX single-quoted arguments (D3/D6); `createAndAttach` through the existing guarded
  coordinator; `sessionGone`/`sessionChanged` marked refresh-triggering; probe
  `new-session --local | --ssh <dest> --name … [--dir …]`; new real e2e steps in `e2e-local`
  (15 steps) and `e2e-remote` (16 steps).
- **Changed files:** new `Sources/MuxFinderCore/Tmux/TmuxCommands.swift`,
  `Sources/muxfinder-probe/NewSessionCommand.swift`,
  `Tests/MuxFinderCoreTests/{TmuxCommandsTests,CreateAndAttachTests}.swift`; modified
  `Sources/MuxFinderCore/{Attach/AttachCoordinator,Attach/AttachModels,Launch/LaunchFailure,Process/ProcessRunner,Shell/Validation,Tmux/CreatedSession}.swift`,
  `Sources/muxfinder-probe/{E2ERun,E2ESupport,E2ELocalCommand,main}.swift`,
  `Tests/MuxFinderCoreTests/ValidationTests.swift`, `PLAN.md`, `docs/TESTING.md`, `CLAUDE.md`.
  (`PROGRESS.json` is a workflow record; ignore it.)
- **Verification already run:** `swift build -Xswiftc -warnings-as-errors` exit 0; `swift test`
  exit 0 (449 tests, 46 suites); `swift format lint -r Sources Tests` exit 0. Real runs by the
  worker on the final tree: `e2e-local` 15/15 and `e2e-remote saturno-m4` 16/16, no leftovers.
  Do **not** run the real e2e commands, the probe's `attach`/`new-session`/`detach`, or anything
  that touches iTerm2, the user's tmux servers or `saturno-m4`; hermetic `swift test` is fine.
- **Risks to probe hardest:**
  1. Shell injection / quoting in the remote static script and its arguments (names, directories
     with spaces, quotes, Unicode, leading `-`, `~` forms, `#` doubling for tmux format
     expansion in `-s`/`-c`). No runtime value may become shell source.
  2. Collision handling: can any path replace, attach to, modify or kill an existing session
     (`-A`, a TOCTOU between `has-session` and `new-session`, `=` exact-match targets, names
     starting with `$` or matching a client)? Is the duplicate-session stderr match robust?
  3. Invalid names rejected before any process runs; the new backslash rule in `Validation`.
  4. `createAndAttach`: a collision or create failure must never open a tab; skipping the
     existing-attachment lookup must be sound; the `mayHaveCreated` / ambiguous-outcome path.
  5. Strictness of the `-P -F` output parser and how it builds the attach target and server
     identity (D5/D11), so the guard (D4) cannot accept a different session.
  6. e2e harness safety: only `muxfinder-test-*` sessions created/killed, cleanup on every
     failure path, bounded timeouts, no remote file writes, no touching iTerm2 objects it did not
     create; the `NewSessionRequest.command` field (unvalidated, harness-only) — can it leak into
     product paths?
  7. The `ProcessRunner` change and its effect on existing callers.
- **Review file:** `docs/reviews/phase-6a.md` (overwrite).
- **Time budget:** 15 minutes.
