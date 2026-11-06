# Review brief — Phase I-12d1 (other terminals: Settings, onboarding and SSH setup)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS menu bar app).
  Review the **uncommitted** working tree against `HEAD` (`git diff` plus the untracked files).
- **Phase goal:** the UI half of PLAN.md *Phase I-12* for Settings and onboarding. The
  specification is PLAN.md "Calls for I-12d (the UI" — the common bullets and the **I-12d1**
  block; what was built and the worker's own calls are in D38 "The UI (I-12d1)" in PLAN.md
  *Decisions*. User requirements 8–11: `autoclaude/processed/110-other-terminal-apps.md`.
- **Changed files:** new `Sources/MuxFinderCore/Terminals/PlainSSHSetupLauncher.swift`,
  `Sources/MuxFinderUI/Model/{TerminalWording,TerminalPicker,PersistentWorkContent}.swift`,
  `Sources/MuxFinderUI/Views/Settings/TerminalPickerView.swift`,
  `Sources/MuxFinderUI/Preview/TerminalPickerFixtures.swift`, tests
  `Tests/MuxFinderCoreTests/PlainSSHSetupLauncherTests.swift`,
  `Tests/MuxFinderUITests/TerminalPickerTests.swift`; modified core `PlainTerminalWindows.swift`,
  `PlainTerminalFakes.swift`, `PlainTerminalBackendFakes.swift`, `TerminalChoice.swift`,
  `Attach/SSHSetupLauncher.swift`, probe `SSHSetupCommand.swift`; UI models `SSHSetupActions`,
  `SettingsEnvironment`, `AppEnvironment`, `AppModel`, `AppModelTerminal`, `SettingsModel`,
  `SettingsModelProfiles`, `SettingsResults`, `OnboardingModel`, `DiagnosticsReport`; views
  `GeneralSettingsView`, `HostEditorView`, `ProfilesSettingsView`, `OnboardingView`,
  `HostSectionView`; previews; docs (`PLAN.md`, `docs/TESTING.md`, `docs/MANUAL-CHECKLIST.md`,
  `CLAUDE.md`, four screenshots).
- **Verification run (orchestrator, final tree):** `swift build` exit 0; `swift format lint -r
  Sources Tests` exit 0; `swift test` passed, 1181 core tests in 128 suites and 513 UI tests in
  49 suites, no existing test file edited; `scripts/build-app.sh` and `codesign --verify --deep
  --strict build/muxFinder.app` exit 0; `pgrep -x Terminal` / `pgrep -x ghostty` empty before
  and after. No real Terminal or Ghostty run (the binding *Unattended-run rules* 8).
- **Risks to probe hardest:**
  1. **iTerm2 regression (requirement 12):** with iTerm2 chosen, is any existing string, state
     or behaviour changed (Settings, onboarding, "Set up SSH in iTerm2…", persistent profiles,
     diagnostics)?
  2. **Never contacting iTerm2 with a plain or `unresolved` choice** (D38 *Onto the seam*):
     does the new SSH setup path, onboarding's new Terminal step, the Profiles tab's Remove or
     the diagnostics row reach iTerm2 (API, profile list, `DynamicProfiles` write) when iTerm2
     is not the choice?
  3. **Plain SSH setup** (`PlainSSHSetupLauncher`): request written and withdrawn correctly on
     every failure path, the window layer's facts gate and unattended policy still applied, one
     window only, the helper started in `ssh-setup` mode with a well-formed argv (D3/D38: no
     runtime value inserted into shell or AppleScript source), no request left behind.
  4. **The persistent work command** (`PersistentWorkContent`): quoting of the helper path and
     host id for a shell "run command" setting and for Ghostty's `command =` (is the text safe
     and correct for both? D3), which hosts get a line, and that nothing writes another
     terminal's settings.
  5. **Permission reads never prompt** (`AEDeterminePermissionToAutomateTarget` with no
     prompt), only at window opening and on "Check again", never on a timer or a main-thread
     stall; the "Allow in System Settings…" link opens a URL only.
  6. **The picker's rules**: rows (Ghostty below its minimum left out unless current),
     unavailable choice kept and never replaced, refused save keeps the old choice, the pending
     note, user definition names shown safely (printable text only).
  7. Conventions in `CLAUDE.md` (doc comments, closing-brace comments) and tests that would
     fail on a broken implementation rather than mirror it.
- **Review file:** `docs/reviews/phase-I-12d1.md` (verdict `ship`, `ship-with-fixes` or
  `do-not-ship`, then BLOCKERS / SHOULD-FIX / NITS with file:line).
- **Time budget:** 20 minutes.
