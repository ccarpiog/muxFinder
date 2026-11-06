# Review brief — Phase I-12c2 (other terminals, open on this Mac)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14). Review the
  **uncommitted** working tree against `HEAD` (`73718f1`).
- **Phase and goal:** I-12c2 is the core of requirement 7 of
  `autoclaude/processed/110-other-terminal-apps.md` ("open on this Mac", D16 generalized):
  discovery's `list-clients` record gains `#{client_tty}` and `#{client_created}` (still
  read-only and static, D6, D12); a read-only process table (`sysctl` `KERN_PROC_PID`,
  `proc_pidpath`, `NSRunningApplication(processIdentifier:)`) walks a local client's parent
  chain to the terminal app it runs in (iTerm2, including its job server
  `~/Library/Application Support/iTerm2/iTermServer-*`, or a loaded definition's bundle id),
  refusing reused pids; per-session local attachments for This Mac only (SSH clients never
  attributed); an optional attributor in `RefreshCoordinator` (nil changes nothing); a new
  `.app` focus handle that activates a running app only; the plain backend's attach focusing
  the app a session is already open in instead of opening a duplicate (`appFocused`); a new
  read-only probe `muxfinder-probe local-clients`. Nothing in the app is rewired (I-12c3). The
  binding spec is `PLAN.md` *Phase I-12*, block "Calls for I-12c2"; the record is D38's
  sub-bullet "Open on this Mac (I-12c2)"; background D16, D38 "Plain backend (I-12c1)".
- **Changed files:** new `Sources/MuxFinderCore/Terminals/{ProcessTable,ProcessTableFakes,LocalClientAttribution}.swift`,
  `Sources/muxfinder-probe/LocalClientsCommand.swift`; changed
  `Sources/MuxFinderCore/Tmux/{ProbeScript,ProbeReport,ErrorClassifier,TmuxModels}.swift`,
  `Refresh/{HostSnapshot,RefreshCoordinator}.swift`, `Attach/AttachModels.swift`,
  `Terminals/{TerminalBackend,PlainTerminalBackend,ITerm2TerminalBackend,PlainTerminalSeams}.swift`,
  `muxfinder-probe/main.swift`, `Sources/MuxFinderUI/Model/{SessionActivity,AppModelSessions}.swift`
  (one case each in exhaustive switches); tests
  `Tests/MuxFinderCoreTests/{ProbeClientFields,LocalClientAttribution,LocalClientsReal,RefreshLocalAttachments,PlainTerminalBackendOpenHere}Tests.swift`,
  `PlainTerminalBackendTestSupport.swift`; records `PLAN.md`, `docs/TESTING.md` *Phase I-12c2*,
  `CLAUDE.md` (the `local-clients` command). `PROGRESS.json` is a workflow record.
- **Verification run (orchestrator):** `swift build` exit 0; `swift format lint -r Sources
  Tests` exit 0; `swift test` exit 0, 1130 core tests in 112 suites and 486 UI tests in 47
  suites (baseline 1098 + 486). Real read-only runs by the worker: `local-clients` (1 session,
  1 control-mode client traced to iTerm2), `discover --local` and `--ssh saturno-m4`.
- **Risks to probe hardest:**
  1. **Attribution soundness.** Can a client be attributed to the wrong app, or a reused pid be
     attributed at all? Check the tty device comparison (`e_tdev` vs `stat(client_tty).st_rdev`,
     including `NODEV` / no controlling terminal), the start-time rule against
     `client_created` (units, rounding, clock), the 64-step bound, cycle detection, a process
     vanishing mid-walk, a parent that started after its child, and the iTermServer rule (name
     prefix and folder: could any other process named `iTermServer-*` or any path outside the
     real home's `Library/Application Support/iTerm2/` match; symbolic links, `..`, case).
  2. **Parser robustness.** The client line's new fields: a tab or odd bytes in `client_tty`,
     an empty tty, a non-canonical or huge `client_created`, old five-field lines; nothing may
     fail a session or host, and the creation time must never shift.
  3. **No regression with iTerm2 (requirement 12).** `AttachCoordinator` and the iTerm2
     backend's attach unchanged; D16's mapping and unmapped kinds unchanged when the index ran
     (control-mode iTerm2-attributed clients left to it); `RefreshCoordinator` with a nil
     attributor byte-for-byte the old behaviour; existing tests' expectations unedited.
  4. **The plain backend's new check.** Order (own record first, then attribution, before any
     request is written); unmapped clients and an unreadable table never block; app not
     running opens nothing; SSH hosts never attributed; nothing written or opened on the focus
     path; concurrency with the existing flights, waiters and `earlierLaunchPending`.
  5. **Safety.** Activation only of a running app (no `NSWorkspace` open, no launch, no Apple
     event); the probe contacts no iTerm2, activates nothing, and prints no session names; no
     user data in logs, fixtures or docs (counts only in `docs/TESTING.md`).
  6. **Conventions.** `///` on every declaration, closing-brace comments past 10 lines, no
     shell built from runtime values.
- **Review file:** `docs/reviews/phase-I-12c2.md`.
- **Time budget:** 20 minutes.
