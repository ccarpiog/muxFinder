# Review brief — Phase 11c (Settings section and launch-time rewrite)

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (native macOS menu bar app, Swift 6,
  SwiftPM). Conventions and binding safety rules: `CLAUDE.md`. Plan: `PLAN.md` — read the
  "### Phase 11" section and **D26** (persistent work profiles; its 11c rules were added in this
  phase), plus D23 (Settings window) where relevant.
- **Phase goal:** Settings UI over Phase 11a's per-host persistent-profile fields (on/off,
  default session name, parent profile) with validation; a "Persistent profiles" Settings tab
  with install status and "Install profiles" / "Remove profiles" through
  `PersistentProfileInstaller` behind a `SettingsEnvironment` seam; the copy (Set as Default
  path, shells elsewhere not adopted into tmux, parent-inheritance warning, second-tab note);
  rewriting an installed, stale `DynamicProfiles/muxFinder.json` at normal-mode app launch and
  after a Settings save; preview fixtures (fakes only) and regenerated
  `docs/screenshots/settings-states-{light,dark}.png`.
- **Changed files (uncommitted tree; review `git diff` and the untracked files):**
  - New: `Sources/MuxFinderUI/Model/{PersistentProfileFiles,PersistentProfilesContent,SettingsModelProfiles}.swift`,
    `Sources/MuxFinderUI/Views/Settings/ProfilesSettingsView.swift`,
    `Tests/MuxFinderUITests/PersistentProfilesSettingsTests.swift`.
  - Modified: `Sources/MuxFinderCore/Profiles/{PersistentProfiles,PersistentProfileInstaller}.swift`
    (new `isGenerated(_:)`, `replaceGenerated` policy, `remove(onlyIfGenerated:)`,
    `notMuxFinders` status, `fileNotMuxFinders` error),
    `Sources/MuxFinderCore/Diagnostics/DiagnosticsLog.swift`,
    `Sources/MuxFinderUI/Model/{HostDraft,SettingsModel,SettingsEnvironment,AppEnvironment,AppModel,AppLaunchOptions}.swift`,
    `Sources/MuxFinderUI/Views/Settings/{HostEditorView,SettingsView}.swift`,
    `Sources/MuxFinderUI/Preview/{SettingsFixtures,SettingsGallery}.swift`,
    `Sources/MuxFinderApp/AppDelegate.swift`, tests in `Tests/MuxFinderUITests/SettingsTestSupport.swift`,
    `Tests/MuxFinderCoreTests/{PersistentProfilesTests,PersistentProfileInstallerTests}.swift`;
    docs `PLAN.md` (D26), `docs/TESTING.md`, `CLAUDE.md`. `PROGRESS.json` is a workflow record.
- **Verification already run (orchestrator, final tree):** `swift build -Xswiftc
  -warnings-as-errors` exit 0; `swift test` exit 0 (670 core tests in 66 suites, 155 UI tests in
  13 suites); `swift format lint -r Sources Tests` exit 0; `codesign --verify --deep --strict
  build/muxFinder.app` exit 0; `swift run muxfinder-probe profiles hashes` unchanged from the
  phase start; real `DynamicProfiles/` empty. No real iTerm2 or e2e runs in this phase (by
  design).
- **Risks to focus on:**
  1. **The app writing iTerm2's folder when it must not.** The launch-time rewrite must run
     only in normal mode (never `--preview-fixtures`, `--selftest`, `--report-*`), only with a
     `saved` host list, only when a muxFinder-generated file is already installed and stale;
     never create the file on its own; never touch a file `isGenerated` rejects. Same for the
     save-triggered reinstall. Check every path that can reach the real installer, including
     preview/gallery environments and tests (must be fakes or private `mktemp -d` folders).
  2. **`isGenerated(_:)` and the new policies.** Is the ownership check sound (a user's file
     with a look-alike GUID; a file from an earlier build; an empty `Profiles` array; mixed
     entries)? Does it run under the lock on the same bytes the identity checks protect? Did
     11a's `createOnly` / `replaceExisting` / `expecting:` behavior stay unchanged?
  3. **Concurrency:** installer calls off the main actor (lock wait up to 5 s), one operation at
     a time, results applied to the current state (no stale result overwriting a newer one;
     Settings window closed/reopened mid-operation; launch rewrite racing a Settings save).
  4. **Host editor validation/round trip:** `Validation.persistentSessionName` /
     `Validation.profileName` applied exactly as `HostList` does (trimmed, first-scalar rule);
     a host without the fields saves back byte for byte; invalid values block Save.
  5. **Copy accuracy** against D26 (Set as Default path, inheritance warning, shells
     elsewhere, second tab), sentence case, English; no user data (host names, paths) in
     diagnostics logs.
  6. Project conventions: `///` on every function/type, closing-brace comments on >10-line
     functions/loops, no third-party deps.
- **Review file:** `docs/reviews/phase-11c.md` (write the full report there).
- **Time budget:** 15 minutes.
