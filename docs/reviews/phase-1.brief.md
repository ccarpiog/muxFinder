# Review brief — Phase 1

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (SwiftPM, Swift 6 language mode, macOS 14,
  arm64). Review the **uncommitted** working tree against `HEAD`.
- **Phase:** Phase 1 — Package skeleton, process runner, quoting and validation (risk: routine).
- **Goal:** the foundation every later phase uses for running commands safely. Spec: `PLAN.md`
  section "### Phase 1" plus *Decisions* D3, D5, D6, D11 and *Unattended-run rules*. Conventions:
  `CLAUDE.md`.

## Changed files

- Modified: `.gitignore`
- New: `Package.swift`, `.swift-format`
- New: `Sources/MuxFinderCore/Process/{ProcessRunner,ProcessEnvironment,PosixSpawnProcessRunner,ProcessSupervisor,ProcessSupervisorIO}.swift`
- New: `Sources/MuxFinderCore/Shell/{ShellQuoting,Validation}.swift`
- New: `Sources/MuxFinderCore/Config/AppPaths.swift`, `Sources/MuxFinderCore/Diagnostics/DiagnosticsLog.swift`
- New placeholders: `Sources/muxfinder-launch/main.swift`, `Sources/muxfinder-probe/main.swift`,
  `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`
- New tests: `Tests/MuxFinderCoreTests/*.swift`
- Ignore `PROGRESS.json` (workflow record).

## Verification already run (all exit 0)

- `swift build -Xswiftc -warnings-as-errors` — clean.
- `swift test` — 54 tests in 6 suites pass in ~0.5 s.
- `swift format lint -r Sources Tests` — clean (`.swift-format` only sets
  `spacesBeforeEndOfLineComments: 1` so `} // End of …` comments lint clean).

## Risks to probe

1. **Process runner correctness** (`ProcessSupervisor*.swift`, `PosixSpawnProcessRunner.swift`):
   pipe deadlocks, fd leaks into children (missing CLOEXEC / file actions), double-close, races
   between `waitpid`, timeout and cancellation, signalling a reaped/reused pgid (killing an
   unrelated process group after the leader is reaped), threads blocked forever, 1 MiB cap
   honoured while still draining, SIGTERM→SIGKILL 2 s escalation, grandchildren surviving.
   Behaviour choice to judge: after a *normal* exit the group is not signalled, and the runner
   waits at most 500 ms for pipes held by leftover grandchildren.
2. **Swift 6 concurrency**: any `@unchecked Sendable`, unsafe pointer lifetimes across
   `posix_spawn`, main-thread blocking.
3. **Quoting / D3**: `posixSingleQuote` and `remoteCommand(script:args:)` must be injection-proof;
   the static-script type must not allow runtime values into script source.
4. **Validation** vs the plan's rules (session name ≤ 100 chars, no control chars, no `:`/`.`,
   no leading `-`, trimmed; SSH destination; executable path; working directory with `~/`).
5. **AppPaths** permissions (0700 dirs) and test override; **DiagnosticsLog** never logging
   command lines with user data or terminal output.
6. Conventions from `CLAUDE.md`: `///` doc comment on every function/method/type, closing-brace
   comments on functions/loops > 10 lines, no third-party deps.
7. Test hermeticity: no ssh/tmux/iTerm2, no flakiness (timing-sensitive asserts).

## Output

- Review file: `docs/reviews/phase-1.md`
- Time budget: 10 minutes.
