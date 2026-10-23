# Review brief — Phase 11a (profile core, helper mode and probe)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS menu bar app; MIT).
- **Phase and goal:** Phase 11a of `PLAN.md` "### Phase 11 — Persistent Work profiles" (read its
  "Split (2026-10-23…)" paragraph and the new decision **D26**). Hermetic part: host-list fields
  for persistent profiles (opt-in, default session name, parent profile), a pure generator and an
  atomic installer/remover for the app-owned iTerm2 Dynamic Profile file `muxFinder.json`, helper
  mode `muxfinder-launch profile <hostUUID>` (nesting guard on `TMUX`/`MUXFINDER_LAUNCHED`,
  login-shell fallback, local tmux `-CC new-session -A`, SSH via the D3/D17 static script), and
  probe commands `profiles show | hashes` and the `e2e-profile` harness for the real runs of 11b.
- **Review the uncommitted tree** (`git status`, `git diff`, plus the untracked files).
- **Changed files:** `Sources/MuxFinderCore/Profiles/*` (new), `Sources/MuxFinderCore/Launch/
  {ProfileLaunch,LaunchHelperProfile,LoginShell}.swift` (new), `Tmux/TmuxWord.swift` (new),
  `Sources/muxfinder-probe/{ProfilesCommand,E2EProfileCommand}.swift` (new); modified
  `Config/{HostConfig,HostList,HostStore,PrivateStorage}.swift`, `Launch/{LaunchHelper,
  LaunchFailure,LaunchGuard,LaunchStore,LaunchArgvDigest,LaunchHelperPath}.swift`,
  `Shell/Validation.swift`, `Tmux/TmuxCommands.swift`, `Process/ProcessSupervisorIO.swift`,
  `MuxFinderUI/Model/HostDraft.swift`, `muxfinder-launch/main.swift`, `muxfinder-probe/
  {main,E2ELocalCommand}.swift`; tests (8 new files, golden fixtures in
  `Tests/MuxFinderCoreTests/Fixtures/profiles/`); `PLAN.md` (D26, D8/D11/D14/D19 edits),
  `CLAUDE.md`, `docs/TESTING.md`.
- **Verification already run (orchestrator, all exit 0):** `swift build -Xswiftc
  -warnings-as-errors`; `swift test` three times (649 core tests in 66 suites + 139 UI tests in
  11 suites); `swift format lint -r Sources Tests`; `scripts/build-app.sh`; `codesign --verify
  --deep --strict build/muxFinder.app`; read-only `swift run muxfinder-probe profiles hashes`.
  Nothing was run against the real iTerm2; that is 11b.
- **Risks to probe hardest:**
  1. **Command construction:** the profile `Command` string is parsed by iTerm2, not a shell.
     Can a helper path or host id reach it unescaped? Are unrepresentable paths refused? No shell
     or AppleScript source may be built from runtime values (CLAUDE.md, D3).
  2. **Remote script quoting** (D3): static script, POSIX single-quoted arguments; session name
     and tmux path validation; the `-A` target-lookup restriction on leading characters.
  3. **Nesting guard and fallback:** every failure path ends in an exec of a login shell, never a
     fast exit (D14's 10 s minimum lifetime — a tab ending within 3 s raises a modal iTerm2
     warning that blocks the whole API); `MUXFINDER_LAUNCHED` set for children in all modes.
  4. **Installer safety:** atomic write, only `muxFinder.json` ever written/removed, symlink and
     non-regular refusal, no clobbering of other `DynamicProfiles/*` files, identical-content
     no-op, stale detection.
  5. **Test-only seams:** the e2e test host list must be honored only in test mode and only for
     its own host id; the production command must stay exactly `<helper> profile <uuid>`; the
     real `hosts.json` is never written; `e2e-profile` refuses when a `muxFinder.json` already
     exists and removes only its own file; it only touches `muxfinder-test-*` sessions and only
     its own iTerm2 tabs' connections (detach via `detach-client`, never closing tabs).
  6. **Compatibility:** old `hosts.json` files load and save back unchanged; the Settings draft
     keeps the new fields.
  7. `profiles hashes` must be read-only (`defaults export`, never `defaults write`) and must not
     print profile contents.
- **Review file:** `docs/reviews/phase-11a.md` (verdict line first: `ship`, `ship-with-fixes` or
  `do-not-ship`; then BLOCKERS and SHOULD-FIX with file:line and a failure scenario each).
- **Time budget:** 20 minutes.
