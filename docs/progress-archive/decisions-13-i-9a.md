# Decisions, Phase 13 planning to I-9a (moved verbatim from `PROGRESS.md`, 2026-11-06)

- Phase 13 planning: the user's uncommitted `PLAN.md`/`PROGRESS.md`/`PROGRESS.json` edits
  (listed in the runner's preflight file) were the plan for Phases 13 and 14; committed verbatim
  as `d03e146` before any phase work so the run could checkpoint. The preflight file still
  names those three paths; they are committed, and the tree was clean when 13b started.
- Phases 13a–13c: new **D29** (bury after confirmation and `.activated`, race closed by
  order, helper restore with DSR acknowledgment, buried-tab list in memory only, recovery 15 s
  after a clean result; `e2e-bury` through the coordinator; harness judgements in
  `Attach/LaunchTabChecks.swift`) — `docs/progress-archive/13{a,b,c}.md`.
- Phase 14: D22 gained a *Look* bullet (opaque fixed per-scheme palette in
  `Views/PopoverStyle.swift`, because the system window background resolves differently
  inside a real window; new `HostStatusLabel.Tone.muted` for `.unreachable` only; row state
  "attached, location unknown" whenever the iTerm2 attachment check did not work, so a row is
  "elsewhere" only on a working check). The app shell check runs under an empty
  `CFFIXED_USER_HOME` now that the user's real `hosts.json` exists (`CLAUDE.md` edited) —
  `docs/progress-archive/14.md`.
- Phase I-1: split into I-1a/I-1b in `PLAN.md` before the first worker. An in-process
  `performClick(_:)` on muxFinder's own button is not UI scripting (bounded: ≤ 3 s open, a few
  runs, never through `open`); SwiftUI private internals and synthesized mouse events stay out.
  So the current `MenuBarExtra` popover cannot be opened unattended: the before-frame is
  deferred for good, and I-1b must measure the after-frame through its own button action
  (exit 0). Recommended for I-1b (*Verified facts*): own `NSStatusItem` + `NSPanel`, anchored
  at the click point, snapping to the button's rect — `docs/progress-archive/i-1a.md`.
- Phase I-1b: new **D30** (own `NSStatusItem` + borderless non-activating `NSPanel`, because
  `MenuBarExtra` gives no position hook and its button takes no action; the anchor rule; the
  toggle rules with press identity by the hardware press count; `PopoverHeightLimit`; D22 and
  D28 edited). The SwiftUI `App` keeps only the main menu (empty `Settings` scene, its menu item
  removed) — `docs/progress-archive/i-1b.md`.
- Phase I-2: split into I-2a/I-2b in `PLAN.md` before the first worker. New **D31**
  (`directories.json` apart from `hosts.json`, under its own `directories.lock`; every mutation
  refuses an unusable file and leaves it untouched, the specification's "left as it is"; the
  `path` record framed by a per-run nonce passed as data; a path over 4,096 bytes printed
  empty by tmux and dropped; discovery's stdout cap sized to the parser's limit, stderr 1 MiB;
  recording on `onCreated` only; the self-tests' in-memory store). The lock and backup helpers
  moved into `PrivateStorage`, shared with `hosts.json` and `profiles.lock` —
  `docs/progress-archive/i-2a.md`.
- Phase I-2b: **D31** extended. The list is drawn inside the popover, not a `Menu`/`NSMenu`,
  so its keys go through `PopoverKey.openList` and `AppModel.handle(_:)` and the galleries can
  render it. Settings' Save is a three-way `mergeSaved` run by the store under its lock, and
  list rows compare byte for byte. `--preview-snapshot` fits the window to its content first.
  Step 26 of the install-script check matches the readers' pids — `docs/progress-archive/i-2b.md`.
- Phase I-3: split into I-3a/I-3b in `PLAN.md` before the first worker, with three calls:
  `--report-hotkey-registration` allowed (own-process Carbon registration posts no event, so it
  is not UI scripting; bounded); the shortcut in `preferences.json` under the support folder,
  not the defaults domain (`CLAUDE.md`'s ownership rule, hermetic tests, `CFFIXED_USER_HOME`);
  the recorder applies at once. New **D32** (I-3a part): ⌥-only shortcuts warn instead of being
  refused, since macOS 27.2 registered them; a failed unregistration keeps the hotkey and its
  handle; an unusable file found by a save turns the hotkey off with "Try again" —
  `docs/progress-archive/i-3a.md`.
- Phase I-3b: **D32** extended. The switcher reuses the popover's `PopoverPanelWindow` at the
  floating level: 540 pt wide, centered on the display with the focus, top 18 % down. The
  popover's panel host, observers and key view are shared, not copied. The popover reports a
  new visibility before its panel shows, so a swap is never a close to the engine. The interim
  popover toggle is removed, and `.shortcut` became `.switcherOpened`. D22's visibility rule
  and D30 are edited — `docs/progress-archive/i-3b.md`.
- Phases I-4 to I-9: new **D33** (I-4, plain `NSApplication`) and **D34** (I-9a, the New
  session window); D30–D32 edited by I-5 to I-8; I-9 split into I-9a/I-9b with the
  orchestrator's calls in `PLAN.md` *Phase I-9* — verbatim in
  `docs/progress-archive/head-i-4-i-9a.md`.
