# Review brief — Phase I-10b (folder search UI)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS menu bar app).
  Conventions and safety rules: `CLAUDE.md`.
- **Phase and goal:** I-10b wires the I-10a folder search core (`FolderSearchChannel`, D36)
  into New session's directory list as a "Folders on <host>" section, adds Settings ›
  Directories "Search folders in: Home folder / Whole disk" and the "Missing a folder?"
  explanation, VoiceOver announcements, galleries and docs. Specification:
  `autoclaude/processed/100-folder-search-spotlight.md` (requirements 3–9, UI acceptance).
  Binding decisions: `PLAN.md` *Phase I-10*, "The orchestrator's calls for I-10b" and
  "Outcome of I-10b"; D31, D34, D36 in *Decisions*.
- **Changed files (uncommitted tree; review `git diff` plus the untracked files):**
  - Core: `Sources/MuxFinderCore/FolderSearch/{FolderSearchScript,FolderSearchOutput,FolderSearchTransport}.swift`
    (new fixed script argument `unchecked` that turns This Mac's readability checks off),
    `Sources/muxfinder-probe/FoldersCommand.swift`.
  - UI (new): `Sources/MuxFinderUI/Model/{FolderSearchSection,AppModelFolderSearch,SettingsModelFolderSearch}.swift`,
    `Sources/MuxFinderUI/Preview/FolderSearchFixtures.swift`.
  - UI (modified): `AppModel`, `AppModelDirectories`, `AppEnvironment`, `SettingsEnvironment`,
    `SettingsModel`, `DirectoryPicker`, `Views/DirectoryPickerViews`,
    `Views/Settings/DirectoriesSettingsView`, `Preview/{PreviewFixtures,SettingsFixtures,NewSessionGallery}`.
  - Tests: `Tests/MuxFinderUITests/{FolderSearchSectionTests,FolderSearchModelTests,SettingsFolderSearchTests,FolderSearchUITestSupport}.swift`
    (new), `Tests/MuxFinderCoreTests/FolderSearch*` (modified).
  - Docs: `PLAN.md`, `README.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md`,
    `docs/MANUAL-CHECKLIST.md` (item 24), `docs/screenshots/{new-session,settings}-states-*.png`.
- **Verification run by the orchestrator (all exit 0):** `swift build`; `swift format lint -r
  Sources Tests`; `swift test` (881 core tests in 87 suites passed); `swift test --filter
  MuxFinderUITests` (465 UI tests in 46 suites passed); `scripts/build-app.sh`; `codesign
  --verify --deep --strict build/muxFinder.app`. The worker also ran `swift build -Xswiftc
  -warnings-as-errors` and one real read-only `folders --local --count-only` (header "not
  checked", no child left). No iTerm2 or SSH run.
- **Risks to probe:**
  1. Channel lifetime: one channel per window and host; closed on window close, host change,
     quiet minute (60 s), app quit — any path that leaks a running `mdfind`/ssh process, or
     reopens forever, or keeps a closed window's channel alive.
  2. Stale answers: an answer for an older text, older host or older scope shown for the
     current text; results kept "while a new text is being searched" (the worker's choice:
     earlier results whose names still match stay listed) showing wrong folders.
  3. Unusable paths: every offered path must pass `Validation.workingDirectory` and the
     host's D31 checks; a pick must never fail New session's validation.
  4. Never delaying Recent/Saved/Sessions or the form; an SSH failure never blocking.
  5. `/` and fewer than 2 characters send no query; the scope is read per query through
     `PreferencesStore` (never `UserDefaults`); an unusable `preferences.json` means `home`;
     `--report-menu-bar-item` must still read no `preferences.json`.
  6. The core change: the `unchecked` argument is a fixed token, never an inserted runtime
     value (D3); SSH hosts unchanged.
  7. VoiceOver: "Searching…" once per search, the count when it changes.
  8. Privacy: no folder name logged, cached on disk, or in fixtures, docs or screenshots.
  9. Conventions: `///` doc comments, closing-brace comments on functions or loops over 10
     lines, sentence case, Swift 6 concurrency (main-actor isolation of the model vs channel
     callbacks).
- **Review file:** `docs/reviews/phase-I-10b.md` (verdict `ship`, `ship-with-fixes` or
  `do-not-ship`; blockers and should-fix items with file:line and a failing scenario).
- **Time budget:** 20 minutes. Do not run real iTerm2, SSH, e2e or self-test runs; hermetic
  commands only. Never run git commands that change state.
