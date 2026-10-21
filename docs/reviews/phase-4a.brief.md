# Review brief — Phase 4a: launch layer and helper

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6 / SwiftPM, macOS 14 menu bar
  app). Conventions and binding safety rules: `CLAUDE.md`. Review the **uncommitted** working
  tree against `HEAD`.
- **Phase and goal:** `PLAN.md` "### Phase 4", the "Split" paragraph's **4a** bullet. Hand an
  attach request from the app to a launch helper that iTerm2 runs inside a new tab
  (`muxfinder-launch attach <uuid>`), through private request/result files, and check the tmux
  session is unchanged (D4) before `exec tmux -u -CC attach-session`. Local host kind only (ssh
  is Phase 5). Relevant decisions: D2, D3, D4 (edited this phase), D5, D8, D12, and the new
  **D14** in `PLAN.md` *Decisions*.

## Changed files

- New: `Sources/MuxFinderCore/Launch/` (`LaunchModels`, `LaunchFailure`, `LaunchStore`,
  `LaunchGuard`, `LaunchHelperPath`, `LaunchArgvDigest`, `TerminalChildRunner`,
  `LaunchHelper`).
- Modified: `Sources/muxfinder-launch/main.swift`, `Sources/MuxFinderCore/Process/ProcessSupervisor.swift`,
  `Sources/MuxFinderCore/Process/ProcessSupervisorIO.swift`,
  `Sources/MuxFinderCore/Diagnostics/DiagnosticsLog.swift`.
- New tests: `Tests/MuxFinderCoreTests/Launch{Guard,HelperBinary,HelperPath,Helper,Models,Store}Tests.swift`,
  `LaunchTestSupport.swift`, `TerminalChildRunnerTests.swift`.
- Docs: `PLAN.md` (split paragraph, D4 edit, D14, verified facts), `docs/TESTING.md`,
  `CLAUDE.md`. `PROGRESS.json` is a workflow record, not a deliverable.

## Verification already run (orchestrator, this tree)

- `swift build -Xswiftc -warnings-as-errors` → exit 0.
- `swift test` → exit 0, 282 tests in 29 suites (224 before).
- `swift format lint -r Sources Tests` → exit 0, no output.
- No tmux server or `muxfinder-test-*` session left on the user's default socket.

## Risks to focus on

1. **Launch file security:** 0700 directory (symlink / foreign owner / loose mode handling),
   0600 files, atomic writes, `O_NOFOLLOW`/`O_EXCL` use, TOCTOU between check and open, uuid
   validation before it becomes a file name, delete-on-read really happening before use, TTL
   (2 min) and the sweep never deleting something it should not (e.g. the `test-mode` marker,
   a request still in its TTL).
2. **Guard script correctness (D3/D4/D5/D12):** static text, data only via argv, correct
   quoting of `"$id"` etc.; gone (64) vs changed (65) vs tmux missing (66) vs other tmux errors;
   tmux 3.8 `display-message -t '$99'` exits 0 with empty fields for a missing id (the worker's
   finding) — check the parse is robust; no-server counts as gone; override semantics.
3. **Helper process handling:** the child must inherit the PTY (not piped) so `tmux -CC` talks
   to iTerm2; signal forwarding (helper ignores SIGHUP/SIGINT/SIGTERM for its lifetime and
   forwards them) — can it orphan tmux or hang forever? Result file always written? Return
   wait only on a TTY. Changes to `ProcessSupervisor` must not alter the discovery runner's
   process-group kill semantics (Phase 1/2 guarantees).
4. **Exit-code → failure mapping:** completeness and the signal case.
5. **Test hygiene:** real-tmux tests must use a private `TMUX_TMPDIR`/socket only, never the
   user's server, and clean up on failure; no `kill-server` against the default socket.
6. **Logging:** no terminal contents or user-data command lines in logs; the argv digest
   reveals only lengths/hashes (and the uuid).

## Output

- Write the full report to `docs/reviews/phase-4a.md` (overwrite it).
- Verdict one of `ship`, `ship-with-fixes`, `do-not-ship`; list BLOCKERS and SHOULD-FIX
  separately with file:line and a concrete failure scenario.
- Time budget: 15 minutes. Do not run anything that touches iTerm2, ssh or the user's tmux
  server; `swift build` / `swift test` are fine.
