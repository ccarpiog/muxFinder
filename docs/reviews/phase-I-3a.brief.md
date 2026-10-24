# Review brief — Phase I-3a

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (native macOS menu bar app, Swift 6,
  SwiftPM). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase:** I-3a — Shortcut, storage, registrar, Settings recorder (routine). The first half
  of I-3 (global hotkey: session switcher). The switcher panel itself is I-3b and out of scope.
- **Goal:** a user-recorded global shortcut (no default) stored in
  `~/Library/Application Support/muxFinder/preferences.json`, registered system-wide through
  Carbon `RegisterEventHotKey` in normal mode only, recorded in Settings > General with a
  hand-written recorder that applies at once; its press reaches one entry point
  (`AppModel.globalShortcutPressed()`), which toggles the existing popover panel as an interim
  until I-3b; plus a read-only `--report-hotkey-registration` launch flag.
- **Binding specification:** `autoclaude/processed/30-global-hotkey-session-switcher.md`
  (Design 1–4, 9–11, Safety and checks, Acceptance — the I-3a parts). The orchestrator's three
  calls (flag allowed with bounds; a file, not the defaults domain; the recorder applies at
  once) and the split are in `PLAN.md` "### Phase I-3"; the design is recorded as **D32** in
  `PLAN.md` *Decisions* (D23 edited).
- **Changed files:** the uncommitted tree (`git status --short`, `git diff`). New:
  `Sources/MuxFinderCore/Config/{GlobalShortcut,PreferencesStore}.swift`,
  `Sources/MuxFinderUI/Model/{GlobalShortcutLabel,HotkeyRegistrar,GlobalShortcutModel}.swift`,
  `Sources/MuxFinderUI/Views/Settings/ShortcutRecorderView.swift`,
  `Sources/MuxFinderApp/HotkeyRegistrationReport.swift`, tests
  `Tests/MuxFinderCoreTests/{GlobalShortcut,PreferencesStore}Tests.swift`,
  `Tests/MuxFinderUITests/{GlobalShortcutModel,GlobalShortcutApp}Tests.swift`,
  `GlobalShortcutTestSupport.swift`. Modified: `AppDelegate`, `MuxFinderMenuBarApp`,
  `AppEnvironment`, `AppLaunchOptions`, `AppModel`, `DiagnosticsReport`, `PopoverController`,
  `SettingsModel`, `SettingsFixtures`, `SettingsGallery`, `MenuBarPopover`,
  `GeneralSettingsView`, `SettingsWindowController`; docs `PLAN.md`, `CLAUDE.md`, `README.md`,
  `docs/{ARCHITECTURE,TESTING,MANUAL-CHECKLIST}.md`, `docs/screenshots/settings-states-*.png`.
- **Verification run (orchestrator, final tree):** `swift build` exit 0; `swift test` 815 core
  tests in 81 suites + 288 UI tests in 27 suites passed (20 + 25 new; no existing test
  changed per the worker); `swift format lint -r Sources Tests` exit 0;
  `scripts/build-app.sh` exit 0 and `codesign --verify --deep --strict build/muxFinder.app`
  exit 0; `build/muxFinder.app/Contents/MacOS/muxFinder --report-hotkey-registration` exit 0,
  8 checks as expected, nothing left registered. Worker: `--report-menu-bar-item` under an
  empty `CFFIXED_USER_HOME` unchanged (exit 0, no child, no `hosts.json`/`preferences.json`);
  `scripts/dev/test-install-scripts.sh` 35/35.
- **Risks to probe (please check these hardest):**
  1. Carbon glue: the event handler is installed on the event *dispatcher* target while
     registration uses the application target; handler lifetime, `Unmanaged` context, Swift 6
     isolation (callback hopping to the main actor), hotkey-id → shortcut matching, and that
     nothing stays registered after clear, change, quit or a failed re-registration (old
     shortcut kept or dropped — which, and is the UI honest about it?).
  2. Lifecycle gating: self-tests, preview modes, every `--report-*` flag and
     `--remove-persistent-profiles` must never read `preferences.json` nor register. Find any
     path that does.
  3. The recorder: Esc cancels, Delete clears, "Clear" button; the current hotkey suspended
     while recording and restored on cancel / window close / app deactivation; the ⌘-one-key
     warning before taking it; refusals (no modifier besides ⇧ unless F1–F20; ⌘Space, ⌘Tab,
     ⌘⇧3/4/5); "taken" shown beside it, never an alert; a key monitor left installed after the
     Settings window closes.
  4. Storage: `PrivateStorage` safety as D19/D31 (0600, safe publication, size cap, lock,
     unknown keys preserved, loading never writes, an unusable file refused by writes and left
     as it is); writes only on record/clear.
  5. The diagnostic flag's bounds (`PLAN.md` Phase I-3): it also registers ⌥J and ⌥⇧J briefly
     to test the ⌥-only rule — is a plain letter combination acceptable under "fixed test
     combinations unlikely to be in use", or should those checks use F-keys only? Every
     registration undone on every way out (SIGTERM/SIGINT)? No preferences read?
  6. Deviation: ⌥-only / ⌥⇧-only combinations get a warning instead of a refusal, because macOS
     27.2 registered them without error (whether a press arrives is a manual check). Is that
     reasoning sound and documented?
  7. Label: modifier order, the layout seam, dead keys / keys the layout prints empty, special
     key names.
  8. `CLAUDE.md` conventions: `///` doc comments everywhere, closing-brace comments on
     functions/loops over 10 lines, sentence-case UI text, no third-party dependency.
- **Review file:** `docs/reviews/phase-I-3a.md` (write the full report there; verdict line
  `ship`, `ship-with-fixes` or `do-not-ship`, then BLOCKERS / SHOULD-FIX / NITS).
- **Time budget:** 20 minutes. Read-only: run no real-world checks, no `e2e-*`, no self-tests,
  no flag runs, and never launch the app through `open`.
