# Review brief — Phase I-3b (switcher panel)

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6, SwiftPM, macOS 14+ menu bar app,
  SwiftUI + AppKit). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase and goal:** I-3b of `PLAN.md` "### Phase I-3" — the global hotkey's session switcher:
  a non-activating, floating, Spotlight-like `NSPanel` (540 pt wide, centered on the screen
  with the keyboard focus, top 18% down) listing live sessions in the popover's order with the
  popover's filter, a "New session…" row that prefills a valid unused name, muted lines for
  checking/unreachable hosts, the no-hosts placeholder, Open / New session form (I-2b
  directory picker) inside the panel, ⌘N/⌘R/⌘,/Esc, failure carry-over to the next opening
  and the popover row, and a combined popover-or-switcher visibility rule so the engine gets
  one `.popoverOpened`/`.popoverClosed` per change. `AppModel.globalShortcutPressed()` now
  toggles the switcher (it toggled the popover as an I-3a interim). Specification (binding,
  Design items 5–10 and Acceptance; item 2's defaults storage was superseded by I-3a's
  `preferences.json`): `autoclaude/processed/30-global-hotkey-session-switcher.md`. Decisions:
  `PLAN.md` D32 (I-3b part added), D22 (visibility rule edited), D30, D25.
- **Changed files (uncommitted tree):** new
  `Sources/MuxFinderUI/Model/{SwitcherContent,SwitcherController,AppModelSwitcher}.swift`,
  `Sources/MuxFinderUI/Views/{SwitcherView,SessionSwitcher}.swift`,
  `Sources/MuxFinderUI/Preview/{SwitcherFixtures,SwitcherGallery}.swift`,
  `Tests/MuxFinderUITests/{SwitcherContent,SwitcherController,SwitcherModel}Tests.swift`,
  `docs/screenshots/switcher-states-{light,dark}.png`; modified
  `Sources/MuxFinderUI/Model/{AppModel,AppModelSessions,PopoverController,AppLaunchOptions}.swift`,
  `Sources/MuxFinderUI/Views/{MenuBarPopover,PopoverWindowBridge,SessionPanelViews}.swift`,
  `Views/Settings/ShortcutRecorderView.swift`, `Preview/PreviewFixtures.swift`,
  `Sources/MuxFinderApp/{AppDelegate,PreviewAppDelegate}.swift`,
  `Tests/MuxFinderUITests/GlobalShortcutAppTests.swift`, `PLAN.md`, `README.md`, `CLAUDE.md`,
  `docs/{ARCHITECTURE,TESTING,MANUAL-CHECKLIST}.md`, Settings gallery PNGs. `PROGRESS.json` is
  a workflow record.
- **Verification run (orchestrator, exit 0 each):** `swift build` (no warnings); `swift test`
  815 core + 317 UI tests pass (25 new UI); `swift format lint -r Sources Tests`;
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app`;
  `--report-menu-bar-item` under an empty `CFFIXED_USER_HOME` exits 0 on SIGTERM, no child, no
  file created. Gallery PNGs inspected. No hotkey press, real panel or `e2e-*` run (no
  synthesized events are allowed; a person checks a press, checklist 18).
- **Known deviations from the worker:** three `GlobalShortcutAppTests` changed from the interim
  popover toggle to the switcher (`PopoverController.shortcutPressed()` and
  `AppModel.togglePopover` removed); the popover close reason `.shortcut` renamed
  `.switcherOpened`; the popover now reports visible just *before* its panel shows (so a swap
  between the panels never reaches the engine as a close); a key-hint footer added; a creation
  failure stays hidden if the popover's Move here confirmation is open at that moment.
- **Risks to probe:** the combined visibility rule (double opened/closed, a swap emitting a
  close, a close never sent if one panel is torn down abnormally, D22 cookie rule); whether
  "only one shows at a time" holds in every path (hotkey while popover open, status item click
  while switcher open, Settings opening); the switcher's key monitor vs the popover's (keys
  leaking to the wrong panel, marked-text/IME composition, Esc in the form vs the list);
  selection stability across refresh updates and filter changes; New session row prefill
  validity and exact-name matching; failure carry-over correctness (shown once at next opening?
  cleared when? never silent); Open's focus-vs-attach behavior parity with the popover;
  regressions in the popover's existing behavior (D30 toggle rules, close reasons, engine
  visibility timing change); conventions (`///` docs, closing-brace comments past 10 lines,
  sentence case); docs accuracy against the code.
- **Review file:** `docs/reviews/phase-I-3b.md`.
- **Time budget:** 20 minutes.
