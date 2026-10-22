# Review brief — Phase 7a, host configuration

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (SwiftPM, Swift 6, macOS 14 menu bar app).
  Review the **uncommitted** working tree against `HEAD`.
- **Phase and goal:** Phase 7a of `PLAN.md` ("### Phase 7", its *Split* paragraph, the 7a
  bullet). Persist the configured hosts in `hosts.json` (schema v1) safely, enforce the
  host-list invariants, provide onboarding defaults and SSH-config host suggestions, plus two
  read-only probe commands. Design recorded as **D19** in `PLAN.md` *Decisions*.
- **Changed files:**
  - New: `Sources/MuxFinderCore/Config/{HostList,HostStore,SSHConfigSuggestions,PrivateStorage,ExtendedACL}.swift`,
    `Sources/muxfinder-probe/HostsCommand.swift`,
    `Tests/MuxFinderCoreTests/{HostList,HostStore,SSHConfigSuggestions}Tests.swift`.
  - Modified: `Sources/MuxFinderCore/Launch/LaunchStore.swift` (its ACL and safe-write code was
    factored out into `Config/PrivateStorage.swift` and `Config/ExtendedACL.swift`),
    `Sources/MuxFinderCore/Config/HostConfig.swift` (doc comment), `Sources/muxfinder-probe/main.swift`,
    `PLAN.md` (Phase 7 split, D19), `docs/TESTING.md`, `CLAUDE.md`.
  - Removed: `Sources/MuxFinderCore/Launch/ExtendedACL.swift` (moved).
  - `PROGRESS.json` is a workflow record; ignore it.
- **Verification already run (orchestrator):** `swift build -Xswiftc -warnings-as-errors` exit 0;
  `swift test` exit 0, 499 tests in 49 suites (457 before); `swift format lint -r Sources Tests`
  exit 0, no output; `muxfinder-probe hosts show` reported `notSavedYet` and the real
  `~/Library/Application Support/muxFinder/` listing was identical before and after.
- **Risks to look at hardest:**
  1. **Launch-layer regression.** `LaunchStore.swift` was refactored onto the shared
     `PrivateStorage`/`ExtendedACL` code. D14 (in `PLAN.md`) is the contract: 0700 directory,
     0600 files, ACL stripping/refusal, delete-on-read, 2-minute TTL, symlink and non-regular
     file handling. Any behaviour change there is a blocker.
  2. **Never silently discarding user data.** Loading must write nothing; an invalid, newer-schema
     or invariant-breaking file must be preserved byte for byte in a backup before any save
     replaces it. Look for paths where a save replaces it without the backup (races between
     load and save, a file that changes between the validity check and the rename, backup name
     collisions, failure half-way through).
  3. **Atomic write correctness:** temp file in the same directory, permissions set before data
     is visible, flush before rename, cleanup of the temp file on failure, symlink handling for
     both the directory and the file, `--config` path rules.
  4. **Invariants:** at most one This Mac, unique ids, no enabled SSH host without a valid
     destination; the This Mac switch (previous This Mac becomes SSH and disabled).
  5. **`SSHConfigSuggestions`:** must never write under `~/.ssh`; wildcard and negation
     exclusion; `Include` globbing, `~/` and relative paths, depth limit 16, cycle protection,
     size cap, quoted values, `Keyword=value`.
  6. Swift 6 concurrency (`HostStore` is an actor), and the project conventions in `CLAUDE.md`
     (doc comments, closing-brace comments, no runtime values in shell source, no user data in
     docs or fixtures).
- **Known, accepted by the worker (judge whether acceptable):** a launch request that creates
  the `muxFinder` directory first leaves its inherited ACL until the next host-list save;
  loading only reports a bad directory ACL/mode and never fixes it; a save refuses (does not
  replace) a `hosts.json` that is a symlink, non-regular or over 16 MiB; `--config` must be
  in a directory the user owns that is not a symlink.
- **Review file:** `docs/reviews/phase-7a.md`.
- **Time budget:** 10 minutes.
- **Rules:** read-only review. Do not run anything that touches iTerm2, ssh or the user's tmux
  server; `swift build` and `swift test` are fine.
