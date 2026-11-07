# Review brief — Phase I-12d2

- **Repo:** /Users/ccarpio/Developer/Utils/muxFinder (Swift 6 SwiftPM macOS menu bar app; conventions in `CLAUDE.md`).
- **Phase:** I-12d2 — other terminals: the popover, the switcher and the session states (routine).
- **Goal:** every session action, state and failure line follows the chosen terminal (iTerm2,
  Terminal, Ghostty, a user definition) through one wording source (`TerminalWording`), with
  iTerm2's strings and every existing iTerm2 test expectation unchanged. Specification: the
  **I-12d2** block of `PLAN.md` *Phase I-12* "Calls for I-12d (the UI" (about lines
  7889–8000), plus the common bullets above it. Decision record written by this phase: D38
  "The UI (I-12d2)" in `PLAN.md` *Decisions*. Narrative: `docs/progress-archive/i-12d2.md`.
- **Changed files (uncommitted tree; `git status --short` / `git diff`):** core
  `Sources/MuxFinderCore/Terminals/{PlainTerminalWindowError,TerminalChoice,TerminalDefinitionLoader}.swift`
  (initialisers and `reason(of:)` made public, additive); UI model
  `Sources/MuxFinderUI/Model/{AppModel,AppModelSessions,AppModelSwitcher,AppModelTerminal,HostStatusLabel,PopoverContent,SessionActivity,SessionPanels,SessionProblem,SettingsModel,SettingsResults,SwitcherContent,TerminalEnvironment}.swift`
  and new `{AppModelTerminalSessions,SessionProblemTerminal,TerminalWordingFailures,TerminalWordingSessions}.swift`;
  views `Sources/MuxFinderUI/Views/{PopoverParts,SessionPanelViews,SessionRowView,SwitcherView}.swift`;
  previews `Sources/MuxFinderUI/Preview/{AttachGallery,PreviewFixtures,PreviewGallery,SwitcherGallery}.swift`
  and new `{TerminalAttachFixtures,TerminalSessionFixtures}.swift`; tests new
  `Tests/MuxFinderUITests/{TerminalSessionModelTests,TerminalSessionWordingTests}.swift`,
  `Tests/MuxFinderCoreTests/TerminalPublicInitTests.swift`, edited
  `Tests/MuxFinderUITests/TerminalSeamTests.swift` (three plain-mode expectations reworded);
  docs `PLAN.md`, `docs/TESTING.md`, `docs/MANUAL-CHECKLIST.md`, six screenshots.
- **Verification already run by the orchestrator (final tree):** `swift build` exit 0;
  `swift format lint -r Sources Tests` exit 0; `swift test` 1183 core tests in 129 suites and
  541 UI tests in 54 suites pass; `codesign --verify --deep --strict build/muxFinder.app` exit 0;
  `pgrep -x Terminal` / `pgrep -x ghostty` empty before and after. No real terminal-app or
  iTerm2 run was made (none is allowed for this phase).
- **Risks to look at hardest:**
  1. **iTerm2 regression (requirement 12):** any iTerm2-chosen string, state, menu item or
     action that changed — compare old literals in the diff with new `TerminalWording` output
     for the iTerm2 case; every existing test expectation must be unchanged under iTerm2.
  2. **Error mappings:** every `PlainTerminalWindowError` case and every plain `AttachFailure`
     / result case gets its own specific line through exhaustive switches (no `default:`), and
     none falls to a generic line; Ghostty's "AppleScript is turned off" mapping is keyed on
     guessed OSA error numbers (-1708, -10004) — check that a wrong guess cannot mislabel a
     different real failure in a harmful way.
  3. **Detach others wording:** "Stopped after detaching N" only when N is proven, "Some may
     have been detached" when not, never "none detached" when unproven.
  4. **"Detach (opened in <terminal>)":** routed only through that non-chosen terminal's cached
     backend, nothing else of it used; with a plain choice the only iTerm2 contact must be this
     explicit user action (the never-contact proof `aPlainChoiceNeverContactsITerm2` must still
     hold for everything else).
  5. **Row attribution:** lines name the terminal whose backend ran the action (not the current
     choice) — check a choice change mid-action and stale records.
  6. **Local attachments in another app** ("Open in Terminal on this Mac", "Show in Terminal")
     with iTerm2 chosen: Open must still open in iTerm2.
  7. Conventions: `///` doc comments, closing-brace comments on >10-line functions, sentence
     case, no runtime values in shell/AppleScript source.
- **Review file:** `docs/reviews/phase-I-12d2.md`.
- **Time budget:** 20 minutes.
