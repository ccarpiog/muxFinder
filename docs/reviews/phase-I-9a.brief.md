# Review brief — phase I-9a

- **Repo:** `/Users/ccarpio/Developer/Utils/muxFinder` (native macOS menu bar app, Swift 6,
  SwiftPM, SwiftUI + AppKit). Conventions and binding safety rules: `CLAUDE.md`.
- **Phase:** I-9a — New session in its own window: the model and the window (risk: high).
- **Goal:** New session's state leaves the shared `panel`; New session opens in one titled,
  floating, non-activating "New session" `NSPanel` from both the popover and the session
  switcher (which close as it opens); the popover and switcher stop showing the form inline;
  Move here stays an inline confirmation and can show together with the window. Creating and
  attaching do not change.
- **Specification:** `autoclaude/processed/90-new-session-own-window.md` (requirements 1–5 and
  the decision part of 7; requirement 6, the folder drop, and the window's gallery,
  screenshots, checklist and README/ARCHITECTURE/REQUIREMENTS are phase I-9b, not this one).
  The orchestrator's binding calls (activation, level, Spaces/full screen, position and size,
  keys, ending, failure after close, self-tests and previews): `PLAN.md`, section
  `### Phase I-9 — New session in its own always-on-top window, with folder drop (high)`.
  The recorded design: `PLAN.md` decision **D34** (and edits to D22, D25, D30–D33).
- **Changed files:** the uncommitted tree (`git status --short`, `git diff`). New:
  `Sources/MuxFinderUI/Model/NewSessionWindowController.swift`,
  `Sources/MuxFinderUI/Model/AppModelNewSession.swift`,
  `Sources/MuxFinderUI/Views/NewSessionWindow.swift`,
  `Tests/MuxFinderUITests/NewSessionWindowTests.swift`. Modified: model
  (`AppModel*.swift`, `SessionPanels.swift`, `PopoverController.swift`,
  `SwitcherController.swift`, `PanelKeyRouting.swift`, `DirectoryPicker.swift`,
  `AppLaunchOptions.swift`), views (`MenuBarPopover.swift`, `SessionSwitcher.swift`,
  `PopoverWindowBridge.swift`, `PopoverView.swift`, `SwitcherView.swift`,
  `SessionPanelViews.swift`, `DirectoryPickerViews.swift`), previews and the self-test driver,
  app delegates, 11 UI test files, `PLAN.md`, `docs/TESTING.md`. **Not part of the phase:**
  `CLAUDE.md` and `nonamedownloads.json` (the user's own uncommitted edits) and
  `PROGRESS.json` (workflow record).
- **Verification run (orchestrator, final tree):** `swift build` exit 0; `swift test` — first
  run 1 issue in the core suite (core sources untouched by the phase; not reproduced), the next
  two runs exit 0 with 815 core tests in 81 suites and 405 UI tests in 40 suites; `swift format
  lint -r Sources Tests` exit 0; `scripts/build-app.sh` exit 0; `codesign --verify --deep
  --strict build/muxFinder.app` exit 0; `--report-menu-bar-item` under an empty private home
  exit 0 on SIGTERM, no child, home left empty, windows listed: the hidden popover panel and
  onboarding only. Worker-reported: `--report-popover-placement` exit 0 ("after-fix check:
  passed"); `--preview-key-view-loop popover|switcher` exit 0 each; `--selftest
  new-session-local` 7/7 PASS (iTerm2 at 17 threads before, 20 after, nothing left behind).
- **Risks to probe:**
  1. Every former user of `panel = .newSession`, `switcherShowsNewSession`,
     `switcherCreation`/`closesOnSuccess`, `switcherCreationFailed(_:)` and
     `showDeferredCreationFailure()`: is any guarantee lost? In particular the failure-after-close
     rule (a collision or failure of a creation whose window was closed brings the window back,
     not key, with the submitted draft, from either entry point), and the switcher's tracking of
     the new session's attach.
  2. The draft rules: Cancel/Esc/⌘W/close drop the draft, except a running creation keeps its
     draft for its outcome; reopening while shown leaves the draft and position alone; the
     switcher's prefill only fills an empty fresh draft; opening/closing the popover or switcher
     never touches the window or its draft.
  3. Window behaviour versus the calls: non-activating, floating, all Spaces + full-screen
     auxiliary, never closing on resign key / outside click / app activation, one at a time,
     placement (top centre at the source's top centre, clamped) and height growth with the top
     edge fixed; ⌘W through D33's Close (`validateMenuItem` must allow it for this class only);
     the window built only by the app shell (self-tests and preview mode never show it).
  4. Keys in the window: Return, Esc (list first, then the window), ⌥↓, ↑/↓, Tab/⇧Tab key view
     loop recalculation, I-8's `PanelKeyRoute` (focused pop-up button, tracking menu, marked
     text), ⌘, opening Settings, ⌘N swallowed; that the key monitor only acts for its own
     window and does not leak keys to or from the popover/switcher.
  5. Retained objects and observation: the window controller's lifetime, observers removed,
     no retain cycle between the model and the controller; shutdown/quit with the window open.
  6. Tests that were changed or removed (listed in `docs/TESTING.md`, *Phase I-9a*): does each
     change keep the old assertion's intent?
- **Review file:** `docs/reviews/phase-I-9a.md`.
- **Time budget:** 20 minutes. Read-only: do not run real checks that open iTerm2 windows, do
  not read or write the real `hosts.json`, `directories.json` or `preferences.json`.
