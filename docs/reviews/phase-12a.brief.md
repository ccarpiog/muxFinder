# Phase 12a review brief

- Repo: `/Users/ccarpio/Developer/Utils/muxFinder` (native macOS menu bar app, Swift 6, SwiftPM).
  Conventions and binding safety rules: `CLAUDE.md`. Plan: `PLAN.md` "### Phase 12" (its
  "Split" paragraph defines 12a) and the new decision **D27**. Brief: `docs/REQUIREMENTS.md`.
- Phase: **12a — Scripts and documents (routine, hermetic).** Goal: install and uninstall
  scripts with a hermetic check, README, architecture doc, a tested vs expected-to-work matrix
  in `docs/TESTING.md` and a manual checklist for the user. Phase 12b (the fresh real
  acceptance run) comes later and is out of scope.
- Review the **uncommitted** working tree against `HEAD` (`930994e`).

## Changed files

- New: `scripts/install.sh`, `scripts/uninstall.sh`, `scripts/lib/app-copies.sh`,
  `scripts/dev/test-install-scripts.sh`, `Sources/MuxFinderCore/Profiles/PersistentProfileRemoval.swift`,
  `Tests/MuxFinderCoreTests/PersistentProfileRemovalTests.swift`, `README.md`,
  `docs/ARCHITECTURE.md`, `docs/MANUAL-CHECKLIST.md`.
- Modified: `scripts/build-app.sh` (Info.plist `MuxFinderScriptInterface`, truthful signer
  line), `Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`,
  `Sources/MuxFinderUI/Model/AppLaunchOptions.swift` (new `--remove-persistent-profiles
  [--dry-run]` flag), `Tests/MuxFinderUITests/{AppModelTests,PersistentProfilesSettingsTests}.swift`,
  `CLAUDE.md` (Commands), `PLAN.md` (D27, architecture tree, the 12a/12b split),
  `docs/TESTING.md` (matrix). `PROGRESS.json` is a workflow record, not a deliverable.

## Verification already run (orchestrator, final tree, all exit 0)

- `swift build -Xswiftc -warnings-as-errors`; `swift test` with pipefail: 680 core tests in 67
  suites + 159 UI tests in 13 suites; `swift format lint -r Sources Tests`.
- `bash -n` on every script (`shellcheck` is not installed).
- `scripts/dev/test-install-scripts.sh`: 26/26 PASS (private `mktemp -d` folders only).
- `rm -rf build && scripts/build-app.sh`, then `codesign --verify --deep --strict
  build/muxFinder.app`.
- `muxfinder-probe profiles hashes` identical before and after; no `/Applications/muxFinder.app`
  or `~/Applications/muxFinder.app`; real `DynamicProfiles/` empty; real
  `~/Library/Application Support/muxFinder/` still only `launch/` and `profiles.lock`.

## Risks to probe

- **Destructive scripts.** `uninstall.sh` deletes an app folder, `DynamicProfiles/muxFinder.json`
  and `~/Library/Application Support/muxFinder`; `install.sh` replaces an app folder. Look for
  any path where they delete or replace something not muxFinder's (wrong `$HOME`, an empty or
  unset variable, a symlink followed, a glob, a destination that is another app, a rename race),
  or where the test overrides (`MUXFINDER_TEST_HOME`, `MUXFINDER_TEST_APPLICATIONS`) leak to
  real paths.
- **Process stopping.** Matching by device/inode from `lsof`; only the copy's `muxFinder` is
  sent SIGTERM, `muxfinder-launch` helpers are left (they hold the user's iTerm2 tabs). Could
  the wrong process be signalled, or could the script proceed to delete a copy still running?
- **Profile-file ownership.** Removal goes through the bundled binary's
  `--remove-persistent-profiles`, i.e. `PersistentProfileInstaller` under the `flock` (D26).
  The script only runs a copy with `MuxFinderScriptInterface` in Info.plist and a valid
  signature, since an older binary would ignore the flag and start the menu bar app. Check
  the flag cannot start the normal app, contact iTerm2, or remove a non-generated file, and
  that its dry run writes nothing.
- **Preferences.** `defaults delete cc.carpio.muxfinder` only when the domain exists, never in
  dry run or test mode — check that guard.
- **Docs truthfulness.** Signing (development or ad hoc, never notarized; Gatekeeper claims),
  the matrix rows against `docs/REQUIREMENTS.md`'s acceptance bullets and the evidence in
  `docs/progress-archive/` and `docs/TESTING.md` (no invented results), CLAUDE.md commands
  accurate.
- Do not run either script outside private `mktemp -d` folders, do not launch the app, do not
  contact iTerm2 or ssh. Read-only review; the hermetic check script is safe to run.

## Output

- Review file: `docs/reviews/phase-12a.md` — verdict (`ship`, `ship-with-fixes`,
  `do-not-ship`), BLOCKERS, SHOULD-FIX, NITS, each with file and line.
- Time budget: 15 minutes.
