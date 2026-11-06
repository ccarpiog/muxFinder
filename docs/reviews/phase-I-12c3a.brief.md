# Review brief: Phase I-12c3a — other terminals, onto the seam

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 menu bar app).
  Review the **uncommitted** working tree against `HEAD`.
- **Phase and goal:** the app (`AppModel`, `AppEnvironment`), Settings and onboarding's iTerm2
  contacts, the self-tests, the refresh engine's attributor and the probe's one-off commands
  move onto `TerminalBackend`, picked from a new `terminal` key in `preferences.json` (typed
  resolution: default iTerm2 when installed, else `terminal`; an unavailable choice is a typed
  failure, never silently replaced). With a plain choice the app must never contact iTerm2.
  With iTerm2 chosen every behaviour must be unchanged (requirement 12). New probe option
  `attach --terminal <id>` with its own permission gate.
- **Spec:** `PLAN.md` → *Phase I-12* → "Calls for I-12c3a" (`rg -n 'Calls for I-12c3a'
  PLAN.md`); the worker's own calls in D38 "Onto the seam (I-12c3a)"; requirements 7, 8, 12 of
  `autoclaude/processed/110-other-terminal-apps.md`. Conventions and safety rules: `CLAUDE.md`.
- **Changed files:** `git status --short` / `git diff`. New: `Sources/MuxFinderCore/Terminals/
  {TerminalChoice,AttachCommandOptions}.swift`, `Sources/MuxFinderUI/Model/{TerminalEnvironment,
  AppModelTerminal}.swift`, tests `Tests/MuxFinderCoreTests/{TerminalChoice,TerminalSeamCore}Tests.swift`,
  `Tests/MuxFinderUITests/TerminalSeamTests.swift`. Modified: `PreferencesStore`,
  `RefreshCoordinator` (`setAttachmentChecksEnabled`), `PlainTerminalBackend` (name refusal),
  `AppEnvironment`, `AppModel*`, `SettingsModel*`, `SSHSetupActions`, `SelfTestDriver`, probe
  `AttachCommand`/`NewSessionCommand`, three UI test files (wiring only, claimed).
- **Verification already run (orchestrator, final tree):** `swift build` exit 0; `swift format
  lint -r Sources Tests` exit 0; `swift test` exit 0, 1152 core + 493 UI tests (was 1134 +
  486). Worker's real runs: `--selftest attach-local` 8/8, `--selftest new-session-local` 7/7,
  `--report-menu-bar-item` with a private home exit 0, `terminals list`, `local-clients`,
  `attach --terminal terminal` with Terminal not running → exit 2, nothing sent.
- **Risks to probe hardest:**
  1. Any path that still contacts iTerm2 (API client creation/connection, attachment index,
     profile list, Settings diagnostics, onboarding API check, D26 rewrite, SSH setup) when the
     resolved choice is plain — including after a choice change at runtime, and at launch
     before the first action.
  2. Regressions with iTerm2 chosen: any changed behaviour, state, string or timing in the
     model's session actions; existing tests' expectations edited (only wiring may change).
  3. The pending-change rule (a choice change while an action is pending) and the per-id
     backend cache: races, a lost record, two coordinators on one iTerm2.
  4. `PreferencesStore`'s new key: D32's lock, refusal of unusable files, merging save, and
     unknown-key handling unchanged; resolution correctness for every unavailable reason.
  5. The refresh engine's `setAttachmentChecksEnabled` toggle: stale index results surviving a
     switch, concurrency with an in-flight refresh.
  6. The probe's `attach --terminal` gate (rule 8): no Apple event or file written unless the
     app is running and permission reads `granted`; `--help` contacts nothing.
  7. Code conventions: `///` doc comments, closing-brace comments on >10-line functions/loops,
     no shell/AppleScript source built from runtime values.
- **Review file:** `docs/reviews/phase-I-12c3a.md` (overwrite).
- **Time budget:** 20 minutes. Do not run real e2e runs or self-tests (they open real iTerm2
  windows); hermetic `swift test` and reading code only.
