# Phase I-2b — Picker, keys, Settings "Directories", galleries and documents (routine)

Closed 2026-10-24 under `/autoclaude-opus`. Worker model: opus (implementation worker and
review-fix worker); the orchestrator ran the verification and the real self-test, made one
inline fix to the install-script check, and wrote the records. Specification:
`autoclaude/processed/20-new-session-directory-picker.md` (Design 4, 5, 6, 8, 9); plan:
`PLAN.md` "### Phase I-2", the I-2b bullet; decision **D31** (extended).

## What was built

- **The list.** New session's Directory field keeps its text field and gains a pull-down at
  its trailing edge. The list is drawn inside the popover, not a SwiftUI `Menu`/`NSMenu`: a
  menu runs its own tracking loop, so its keys would bypass `PopoverKey` and
  `AppModel.handle(_:)`, it cannot be opened by a key from the field, unit tests cannot drive
  it, and `--preview-snapshot` cannot render it (recorded in D31). The pure
  `DirectoryPickerContent` (`Sources/MuxFinderUI/Model/DirectoryPicker.swift`) builds the
  sections for the selected host: Recent, Saved, "Sessions on <host>" (distinct, sorted, at
  most 10), empty sections hidden, "Nothing to pick yet". It also holds the rule for when
  "Save this directory" is off (empty, invalid per `Validation.workingDirectory`, already
  saved, list full, unusable file). "Clear recent directories on <host>" sits below. Long
  paths are shortened in the middle, with the full path in help and the accessibility label.
  Picking fills and checks the draft; a host change keeps the field.
- **Keys.** ⌥↓ (`PopoverKey.openList`) opens the list; ↑/↓ move inside; Return picks the
  highlighted row, otherwise creates; Esc closes the list, then the panel. ⌥↓ elsewhere
  returns the new `.ignored` result, so every other shortcut is unchanged.
- **Store use.** `AppModel` runs every load and change on one store queue
  (`Model/AppModelDirectories.swift`). Failures show in the list and are logged by code only.
  Self-tests and previews inject an in-memory store.
- **Settings.** A Directories tab (`Views/Settings/DirectoriesSettingsView.swift`,
  `Model/SettingsModelDirectories.swift`) adds entries (checked inline), removes them and moves
  them up or down, with Save and Revert (D23). It shares the `DirectoryStore` with the
  popover. An unusable file shows its notice and offers no edits.
- **Galleries.** Four New session list states in the attach gallery and two Directories states
  in the Settings gallery, all synthetic, light and dark. `--preview-snapshot` now sizes the
  window to its content first, because the taller attach gallery had been squeezed to the
  screen's height (`Sources/MuxFinderApp/PreviewAppDelegate.swift`; `CLAUDE.md` and D31 say
  so).
- **Documents.** `README.md`, `docs/ARCHITECTURE.md`, `docs/TESTING.md` (matrix row and
  *Phase I-2b*), `docs/MANUAL-CHECKLIST.md` item 17 (create from a recent, a saved and a session
  folder on This Mac and Saturno; the keys; the Settings tab), and D31 with the I-2b outcome in
  `PLAN.md`.

## Acceptance

- The specification's tests for the picker, picking and keys pass:
  `DirectoryPickerContentTests`, `DirectoryPickerModelTests` and `SettingsDirectoriesTests`
  (34 new UI tests in all), plus 2 new core tests in `DirectoryStoreTests`. No existing test
  changed. **Met.**
- Galleries regenerated light and dark and inspected; the orchestrator also looked at
  `attach-states-light.png`. **Met.**
- Hermetic install-script check: 35/35, exit 0, after the step 26 fix below. **Met.**
- Shared verification, `scripts/build-app.sh` and `codesign --verify --deep --strict`: exit 0.
  **Met.**
- Self-test path: opening its panel now reads the in-memory store, so the real
  `--selftest new-session-local` was run: 7/7. **Met.**

## Review

Codex wrote `docs/reviews/phase-I-2b.md` (`autoclaude-review.sh`, 20 min), with the brief in
`docs/reviews/phase-I-2b.brief.md`. Verdict `ship-with-fixes`: 1 blocker and 2 should-fix. A
review-fix worker fixed all three, each with regressions that fail when the fix is reverted:

- **Blocker: Settings Save overwrote picker changes made in the meantime.** Save is now a
  three-way merge, `DirectoryListChange.mergeSaved(base:edited:)` in `DirectoryLists.swift`.
  It takes the tab's list (order, additions, removals), drops entries removed elsewhere since
  the tab loaded, and appends entries added elsewhere since. The store runs it on the file as
  it is, under `directories.lock`, in the same call as the write. Save never touches recents.
  Regressions: `saveKeepsWhatNewSessionChangedMeanwhile`, `saveMergesAnotherMuxFindersChange`.
- **Should-fix: Return used a stale highlight after a field edit.** Any byte-level edit of the
  field now drops the highlight, so Return creates from the field. A row highlighted afterwards
  is still picked. Regression: `editingTheFieldDropsTheHighlight`.
- **Should-fix: byte-distinct Unicode spellings collapsed.** List rows and sections now use
  section plus UTF-8 bytes for identity, and `DirectoryLists ==` compares byte for byte.
  Regressions: `twoSpellingsAreTwoRows`, `keysMoveThroughBothSpellings`,
  `aRespelledEntryReachesTheView`, core `equalityIsByteForByte`.

## Orchestrator fix (after the review, trivial)

`scripts/dev/test-install-scripts.sh` step 26 ("uninstall: never signalled, and no muxFinder
warning for a reader of another copy") had `log_lacks "also running from"`. That also matched
the uninstall script's correct warning about the user's installed muxFinder running from
`/Applications`, so the step failed on every run while that app ran. The step now checks that
no warning names either reader's pid (the warning prints `(pid N)`). Mutation check: with the
uninstall script's executable-identity test removed for a moment (backup and restore, no git),
step 26 failed (1 of 35). With it restored: 35/35. `scripts/uninstall.sh` is unchanged.

## Verification (final tree, orchestrator)

- `swift build`: exit 0, no warnings.
- `swift test`: exit 0, 795 core tests in 79 suites and 263 UI tests in 25 suites.
- `swift format lint -r Sources Tests`: exit 0.
- `scripts/build-app.sh`: exit 0. `codesign --verify --deep --strict build/muxFinder.app`:
  exit 0.
- `scripts/dev/test-install-scripts.sh`: exit 0, 35 steps.
- `env -u TMUX_TMPDIR build/muxFinder.app/Contents/MacOS/muxFinder --selftest
  new-session-local`: exit 0, 7/7. Gate: `iterm2 status` connected, iTerm2 at 17 threads
  (19 after). Nothing was left behind: no `muxfinder-test-*` session, the `launch/` folder
  empty, no `directories.json` in the real support folder.
- An earlier full `swift test` (before the review) failed only in the private-tmux-server core
  suites, while another project's iOS simulator run held the load average near 500. No core
  file had changed at that point; with the load near 25, every test passed.

## Open risks / deviations

- The list highlight is dropped when the field is edited, not when the field is only clicked
  again. `NewSessionDraft.directory`'s observer in `SessionPanels.swift` (an earlier phase)
  still compares with `String ==`.
- Only the preview renders and unit tests have exercised the picker. These are owed to a
  person (checklist 17): the real keys in the non-activating panel (⌥↓, Tab then Space,
  ↑/↓, Esc), creating from each source on This Mac and Saturno, and the Settings tab.
- The review-fix worker changed core `DirectoryLists.swift` (the `mergeSaved` case), because
  an atomic check-and-write needs the merge inside the store's locked `apply`.
- Step 35 of the install-script check (the real folders untouched) can still fail if the
  user's installed app writes its own `launch/` folder during a run.
