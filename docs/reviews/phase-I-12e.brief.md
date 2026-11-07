# Review brief — Phase I-12e (other terminals, the docs)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (macOS menu bar app, Swift 6, SwiftPM).
  Review the **uncommitted** working tree against `HEAD`.
- **Phase and goal:** I-12e, routine, documents only. Document Phase I-12 (Terminal.app and
  Ghostty beside iTerm2 in plain `tmux attach` mode) for users and agents. The binding scope is
  "Calls for I-12e" in `PLAN.md` (just above `## Deferred`); the specification is
  `autoclaude/processed/110-other-terminal-apps.md` (requirement 13, *User decisions*,
  *Acceptance* › `docs/MANUAL-CHECKLIST.md`).
- **Changed files:** new `docs/TERMINALS.md`; `docs/REQUIREMENTS.md` (an appended addendum
  only), `README.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`, `docs/MANUAL-CHECKLIST.md`,
  `CLAUDE.md`, `PLAN.md` (the "Calls for I-12e" block and D38's new "The docs (I-12e)"
  paragraph). `PROGRESS.json` is a workflow record; ignore it. No file under `Sources/`,
  `Tests/`, `Resources/` or `scripts/` changed.
- **Verification run (orchestrator):** `git diff --stat -- Sources Tests Resources scripts`
  empty; `git diff --numstat docs/REQUIREMENTS.md` → 23 added, 0 removed; `swift build` exit
  0; `swift format lint -r Sources Tests` exit 0. Worker: the `docs/TERMINALS.md` worked `exec`
  example loaded through `swift run muxfinder-probe terminals list --builtin-directory
  Resources/Terminals --user-directory <private 0700 folder>` (source `user`, no problems);
  `pgrep -x Terminal` / `pgrep -x ghostty` unchanged (none running).
- **Risks to check — accuracy is the whole phase:**
  1. Every factual claim in `docs/TERMINALS.md`'s "Adding a terminal" (schema 1 keys, open /
     command / focus kinds, placeholders, minimum version, user folder rules, override by id,
     problems) matches the code: `Sources/MuxFinderCore/Terminals/TerminalDefinition*.swift`,
     `TerminalLaunchCommand.swift`, `JSONDuplicateNameScanner.swift`, and the built-ins in
     `Resources/Terminals/`. A user following it must get a definition that loads.
  2. README, ARCHITECTURE and TERMINALS agree with D38 in `PLAN.md` and with the UI strings in
     `Sources/MuxFinderUI/Model/TerminalWording*.swift` / `PersistentWorkContent.swift`
     (choice resolution, the permission states, where to paste the persistent work command,
     plain mode's limits). Existing iTerm2 text must still be true.
  3. The worker corrected three existing statements as wrong against the code: in `CLAUDE.md`,
     that `attach-plain` ignores `testLaunchDelaySeconds` (it honors it in test mode) and that
     the helper never exits younger than 10 s on a terminal (`attach-plain` may when
     `keepsMinimumLifetime` is off); in `docs/MANUAL-CHECKLIST.md` item 28, that the helper
     "explains and waits" after a Detach (only after a failure). Check each correction against
     `Sources/MuxFinderCore/Launch/` (`LaunchHelperPlain.swift` and neighbours).
  4. `docs/REQUIREMENTS.md`: the brief above the addendum byte for byte unchanged; the addendum
     quotes *User decisions* verbatim.
  5. `CLAUDE.md` safety rules and `PLAN.md` *Unattended-run rules* 1 and 8: nothing relaxed.
  6. Public repository: no new host names, user paths or anything about a private download
     site.
- **Review file:** `docs/reviews/phase-I-12e.md`.
- **Time budget:** 15 minutes.
