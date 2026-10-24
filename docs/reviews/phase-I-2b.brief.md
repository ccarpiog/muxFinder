# Review brief — Phase I-2b

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 menu bar app).
  Conventions and safety rules: `CLAUDE.md`. Review the **uncommitted** working tree against
  `HEAD` (`3feab0e`, Phase I-2a).
- **Phase and goal:** I-2b — the New session directory picker (Recent / Saved / "Sessions on
  <host>"), its keys, the Settings "Directories" section, preview gallery states and documents.
  Scope: `PLAN.md` "### Phase I-2", the I-2b bullet; decision **D31** (extended in this phase);
  binding specification `autoclaude/processed/20-new-session-directory-picker.md`, Design 4, 5,
  6, 8, 9 and its Acceptance. The core store (`Sources/MuxFinderCore/Config/DirectoryStore.swift`)
  was built and reviewed in I-2a and is unchanged here.
- **Changed files:** new `Sources/MuxFinderUI/Model/{DirectoryPicker,AppModelDirectories,
  SettingsModelDirectories}.swift`, `Sources/MuxFinderUI/Views/DirectoryPickerViews.swift`,
  `Sources/MuxFinderUI/Views/Settings/DirectoriesSettingsView.swift`,
  `Tests/MuxFinderUITests/{DirectoryPickerTests,SettingsDirectoriesTests}.swift`; modified
  `Sources/MuxFinderUI/Model/{AppModel,AppModelSessions,AppEnvironment,PopoverKey,
  SettingsEnvironment,SettingsModel}.swift`, `Sources/MuxFinderUI/Views/{PopoverWindowBridge,
  SessionPanelViews}.swift`, `Sources/MuxFinderUI/Views/Settings/SettingsView.swift`,
  `Sources/MuxFinderUI/Preview/{AttachFixtures,AttachGallery,PreviewFixtures,SettingsFixtures,
  SettingsGallery}.swift`, `Sources/MuxFinderApp/PreviewAppDelegate.swift`, `README.md`,
  `CLAUDE.md`, `PLAN.md`, `docs/{ARCHITECTURE,TESTING,MANUAL-CHECKLIST}.md`,
  `docs/screenshots/{attach,settings}-states-{light,dark}.png`. (`PROGRESS.json` is a workflow
  record; ignore it.)
- **Verification run so far (orchestrator):** `swift build` exit 0, no warnings; `swift test
  --filter MuxFinderUITests` 257 tests in 25 suites passed; `swift format lint -r Sources Tests`
  exit 0; `scripts/build-app.sh` exit 0; `codesign --verify --deep --strict build/muxFinder.app`
  exit 0; galleries inspected. The full `swift test` failed only in core private-tmux-server
  tests while the machine's load average was ~500 (another project's iOS simulator run); no
  core file changed in this phase; rerun pending. The hermetic install-script check and the real
  `--selftest new-session-local` are still to be run by the orchestrator. Do **not** run any
  real iTerm2 check, self-test, e2e, `install.sh` or `uninstall.sh`, and never launch the app
  through `open`; unit tests and builds are fine.
- **Design choice to scrutinize:** the list is drawn inside the popover, not a SwiftUI
  `Menu`/`NSMenu` (reason recorded in D31: a menu runs its own tracking loop, bypasses
  `PopoverKey`/`AppModel.handle(_:)`, cannot be opened by a key from the field, and is not
  rendered by `--preview-snapshot`).
- **Risks to check:**
  1. Keys: ⌥↓ (`PopoverKey.openList`) opens the list; ↑/↓ move inside; Return picks the
     highlighted row, else creates — is that consistent with the spec's "Return in the field
     still means Create"? Esc closes the list, then the panel. ⌥↓ elsewhere returns a new
     `.ignored` result — confirm every other popover shortcut behaves exactly as before
     (search, row navigation, panels, Return/Esc outside the New session panel).
  2. Picker content: sections only when non-empty, order Recent / Saved / Sessions, sessions
     distinct, sorted, capped at 10, for the **selected** host; host change refreshes the list
     and keeps the field text; stale snapshot folders; the "Save this directory" disabled rule
     (empty, invalid per `Validation.workingDirectory`, already saved, list full, unusable file).
  3. Store use: the popover and Settings share one `DirectoryStore`; loads and mutations on one
     queue. Look for lost updates or stale views when the picker saves or clears while Settings
     holds unsaved Directories edits (Save/Revert per D23), a Settings Save overwriting a
     picker change made meanwhile, and `fileNotUsable` handling (notice shown, no edits offered
     that cannot land, the file left untouched).
  4. Every path that reaches a `NewSessionRequest` still goes through
     `Validation.workingDirectory` and stays data (D3, D18); no path, directory or host name in
     logs, diagnostics, the operation log, fixtures or docs (kinds and counts only).
  5. Self-tests and previews never read or write the real `directories.json`
     (`AppEnvironment` / `SettingsEnvironment` injection); `newSession()` now starts a read of
     the store — confirm the self-test uses the in-memory store.
  6. `--preview-snapshot` now sizes the window to its content first (`PreviewAppDelegate`):
     any effect on the popover/settings/onboarding galleries or the normal app.
  7. Main-actor and Swift 6 concurrency correctness of the new async store calls; a store
     answer arriving after the panel closed or the host changed.
  8. Conventions: `///` on every function, method and type; closing-brace comments past 10
     lines; sentence-case UI text; documents describe present state.
- **Review file:** `docs/reviews/phase-I-2b.md` (verdict `ship` / `ship-with-fixes` /
  `do-not-ship`, then `BLOCKERS` and `SHOULD-FIX` with file:line and a failing scenario).
- **Time budget:** 20 minutes.
