# Phase I-3a — Shortcut, storage, registrar, Settings recorder (routine)

Closed 2026-10-24 under `/autoclaude-opus`. Worker model: opus (implementation worker and
review-fix worker); the orchestrator made the three pre-worker calls, ran the verification
and the third flag run, added one checklist step and wrote the records. Specification:
`autoclaude/processed/30-global-hotkey-session-switcher.md` (Design 1–4, 9–11, Safety and
checks, Acceptance — the I-3a parts); plan: `PLAN.md` "### Phase I-3", the I-3a bullet;
decision **D32** (D23 edited).

## Calls made before the worker (recorded in `PLAN.md` Phase I-3)

- `--report-hotkey-registration` is allowed: Carbon registration on muxFinder's own event
  target in its own process posts no event and touches no other app, so it is not UI
  scripting; bounded (fixed test combinations only, never the user's shortcut, no
  `preferences.json`, everything undone on every way out, a few runs per sub-phase).
- Storage is `~/Library/Application Support/muxFinder/preferences.json`, not the
  `cc.carpio.muxfinder` defaults domain: `CLAUDE.md` binds the app to owning only its support
  folder and `DynamicProfiles/muxFinder.json`; tests run on private folders; the shell check's
  empty `CFFIXED_USER_HOME` isolates it without relying on `cfprefsd`.
- The recorder applies at once (D23's launch-at-login pattern), since "taken" is only known by
  registering.

## What was built

- **The value.** `GlobalShortcut` (`Sources/MuxFinderCore/Config/GlobalShortcut.swift`): key
  code + modifiers; refuses a combination without ⌃, ⌥ or ⌘ (F1–F20 excepted) and macOS's own
  (⌘Space, ⌘Tab, ⌘⇧3/4/5); warns before ⌘ plus one key and before ⌥-only / ⌥⇧-only.
- **The label.** `GlobalShortcutLabel` (`Sources/MuxFinderUI/Model/`): ⌃⌥⇧⌘ symbols plus the key
  as the current layout prints it (layout seam; tests use a fake Spanish layout), fixed names
  for special keys.
- **Storage.** `PreferencesStore` (`Sources/MuxFinderCore/Config/PreferencesStore.swift`):
  `preferences.json` schema 1 through `PrivateStorage` with D31's rules (own
  `preferences.lock`, 0600, safe publication, size cap, unknown keys kept, loading never
  writes, an unusable file left as it is with the hotkey off); written only on record or
  clear; an in-memory store for self-tests and previews.
- **Registrar.** `HotkeyRegistering` seam with a Carbon implementation (exclusive
  registration, `eventHotKeyExistsErr` → "taken"; handler on the event dispatcher target) and
  a fake; `GlobalShortcutModel` owns the lifecycle in normal mode only (register after
  launching, again on a change, unregister on clear and at quit; suspended while recording).
  Self-tests, previews, every `--report-*` flag and `--remove-persistent-profiles` never read
  the file or register.
- **Settings › General.** A "Session switcher" section with the hand-written
  `ShortcutRecorderView` (click, type; Esc cancels, Delete clears, "Clear"; messages beside
  it, never an alert); diagnostics report the registration state by kind.
- **Interim action.** Presses reach `AppModel.globalShortcutPressed()`, which toggles the
  popover panel (D30) until I-3b switches it to the switcher.
- **Flag.** `--report-hotkey-registration` (`Sources/MuxFinderApp/HotkeyRegistrationReport.swift`)
  prints `muxFinder hotkey registration: …` lines: register ⌃⌥⇧⌘F19, the same again refused as
  taken, unregister, register again, and ⌥F19, ⌥⇧F19, ⌥J, ⌥⇧J (each unregistered at once).
- **Galleries.** `docs/screenshots/settings-states-{light,dark}.png` regenerated with five
  recorder states; General frames are now 420 pt tall.

## Deviation

- **⌥-only shortcuts warn, not refuse.** The specification expected macOS 15+ to refuse
  combinations whose only modifiers are ⌥ or ⌥⇧; the flag's run on macOS 27.2 registered ⌥F19,
  ⌥⇧F19, ⌥J and ⌥⇧J without error, so D32 warns instead. Whether such a press reaches the app
  is owed by hand (checklist 18, step 4); D32 refuses them if it does not.

## Acceptance

All met, 2026-10-24: shortcut, label, storage (private folders) and registrar tests pass (20
new core, 29 new UI tests; no existing test changed); the flag in the signed bundle exit 0
with 8 checks as expected and nothing left registered (three runs in all: the worker's first
exited 1 on the ⌥-only expectation, which led to the deviation, then 0 twice);
`--report-menu-bar-item` under an empty `CFFIXED_USER_HOME` as before (worker: exit 0, no
child, no `hosts.json`/`preferences.json`); install-script check 35/35; uninstall removes the
whole support folder, `preferences.json` with it (its dry-run text does not name the file);
shared verification and bundle + `codesign` pass.

## Review

Codex (`autoclaude-review.sh`, 20 min) → `ship-with-fixes`, 0 blockers, 3 should-fix,
`docs/reviews/phase-I-3a.md`. A review-fix worker fixed all three, each with a regression that
failed with its fix reverted:

1. A failed `UnregisterEventHotKey` dropped the only handle: the registrar and model now keep
   it until Carbon confirms, the hotkey stays on and working, and the failure shows beside the
   recorder and in diagnostics (`carbonRegistrarKeepsAFailedUnregistration`,
   `aFailedUnregistrationKeepsTheHotkey`; Carbon calls behind an injectable struct).
2. An unusable `preferences.json` found by a save re-registered the old shortcut and blocked
   recovery: the hotkey now goes off as at launch, the file is left as it is, and "Try again"
   reloads once it is fixed or removed (`anUnusableFileFoundBySavingCanBeRetried`, real store
   on a private folder; D32 records it).
3. Leaving General while recording kept the key monitor and the hotkey suspended: another tab
   or the recorder disappearing now cancels recording (`settingsStopsRecordingOnAnotherTab`).
   The orchestrator added the by-hand step for it to checklist 18 (step 8).

## Verification (final tree, orchestrator)

`swift build` exit 0; `swift test` 815 core tests in 81 suites + 292 UI tests in 27 suites
passed; `swift format lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0,
`codesign --verify --deep --strict build/muxFinder.app` exit 0;
`scripts/dev/test-install-scripts.sh` 35/35 PASS; `--report-hotkey-registration` (before the
review fixes, which did not touch it) exit 0, 8/8.

## Open risks

- No press was made (no synthesized keystrokes): whether a real press fires the Carbon handler
  (installed on the dispatcher target, registration on the application target) is checklist
  18's.
- The flag briefly registers ⌥J and ⌥⇧J system-wide (microseconds each); a plain-letter
  combination, unlike the F19 ones.
- Switching Settings tabs mid-recording is tested in the model only (checklist 18 step 8).
- The uninstall dry-run text ("host list, launch folder, lock file") does not name
  `preferences.json`.
