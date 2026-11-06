# Review brief — Phase I-9b (routine)

- **Repo**: `/Users/ccarpio/Developer/Utils/muxFinder` (Swift 6, SwiftPM, macOS 14 menu bar app).
  Review the **uncommitted** working tree against `HEAD` (`da48655`, Phase I-9a).
- **Phase and goal**: I-9b — New session window: the folder drop, galleries and docs. A single
  Finder folder dropped on the New session window's Directory row fills the field (`~/…` under
  This Mac's home, else absolute), through a pure function; `--preview-gallery new-session`;
  regenerated screenshots; checklist and docs. Specification:
  `autoclaude/processed/90-new-session-own-window.md` (requirement 6, the acceptance's gallery,
  screenshot and checklist bullets). Binding calls: `PLAN.md` "### Phase I-9", the bullets
  "The orchestrator's calls for I-9b" (drop target = Directory row only; exactly one `file:` URL
  that is a directory and not a package; path as dropped, standardized, trailing slash removed,
  no symlink resolution; `~` by whole path components, home itself `~`; the fill is a pick via
  `fillDirectoryField(_:)`; the field editor never inserts its own text; path never logged).
- **Changed files**: new `Sources/MuxFinderUI/Model/FolderDrop.swift`,
  `Sources/MuxFinderUI/Views/FolderDropView.swift` (AppKit drop view laid over the Directory
  row), `Sources/MuxFinderUI/Preview/NewSessionGallery.swift`,
  `Tests/MuxFinderUITests/FolderDropTests.swift`, `docs/screenshots/new-session-states-*.png`;
  modified `Sources/MuxFinderUI/Model/{AppModel,AppModelDirectories,AppModelNewSession,
  AppLaunchOptions}.swift`, `Views/DirectoryPickerViews.swift`,
  `Preview/{PreviewFixtures,AttachFixtures,SwitcherFixtures}.swift`,
  `Sources/MuxFinderApp/PreviewAppDelegate.swift`,
  `Tests/MuxFinderUITests/{AttachFlowTests,DirectoryFilterTests}.swift`, attach and switcher
  screenshots, `README.md`, `docs/ARCHITECTURE.md`, `docs/MANUAL-CHECKLIST.md`,
  `docs/TESTING.md`, `PLAN.md`. Not part of the phase (the user's own uncommitted edits, ignore
  them): `CLAUDE.md`, `nonamedownloads.json`. `PROGRESS.json` is a workflow record.
- **Verification run (orchestrator, all exit 0)**: `swift build`; `swift test` (815 core tests);
  `swift test --filter MuxFinderUITests` (431 UI tests in 43 suites); `swift format lint -r
  Sources Tests`; `scripts/build-app.sh`; `codesign --verify --deep --strict
  build/muxFinder.app`. Worker: gallery snapshots light/dark inspected; `--report-menu-bar-item`
  under a private home exit 0.
- **Risks to probe**:
  1. The drop view over the Directory row: does it really receive drags before the field editor
     (`NSTextView`) when the field is being edited, and do clicks, text selection, the list
     button, the I-6 key view loop and VoiceOver still reach the field and button beneath it
     (hit testing passes through)? Any path where the field editor still inserts a file path?
  2. Drag validation: are a file, a package (`.app`), two items, a non-file drag and a file
     promise refused with no "+" (`NSDragOperation` none) in `draggingEntered`/`draggingUpdated`
     and refused again in `performDragOperation`? Is the highlight always cleared (exit, end,
     refusal, window close)?
  3. `FolderDrop` correctness: component-wise home prefix (`/Users/a2` vs `/Users/a`), home
     itself, trailing slashes, `..`/`.` standardization, root `/`, home with a trailing slash,
     non-ASCII paths; This Mac's home the same one I-7's `~` rule uses; no symlink resolution.
  4. The fill is a pick: the directory list closes and does not reopen through I-7's typing
     rule; a busy (creating) draft must not be changed by a drop; the drop works for every host.
  5. Only the URL's own resource values are read (no directory listing), and the path is never
     logged or announced with user data beyond the field itself.
  6. Gallery and fixtures: `--preview-gallery new-session` wiring, argument errors and help text;
     the removed switcher fixtures and the two changed tests (recorded in `docs/TESTING.md`);
     no test weakened.
  7. Conventions: `///` doc comments everywhere, closing-brace comments on >10-line functions
     and loops, no Title Case in UI strings, no private API in shipped code.
  8. Docs match the code (checklist items 17, 18, 20–23, D34 additions, TESTING.md *Phase I-9b*).
- **Review file**: `docs/reviews/phase-I-9b.md`.
- **Time budget**: 15 minutes.
