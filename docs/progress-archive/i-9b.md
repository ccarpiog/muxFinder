# Phase I-9b — New session window: the folder drop, galleries and docs

Risk class: routine. Worker model: opus (one implementation worker; no fix worker, the review
had no findings). Specification: `autoclaude/processed/90-new-session-own-window.md`
(requirement 6, the acceptance's gallery, screenshot and checklist bullets, requirement 7's
docs). Plan: `PLAN.md` "### Phase I-9", the orchestrator's calls for I-9b and "Outcome of
I-9b"; D34 gained "The folder drop" and "The gallery".

## Calls made before the worker (recorded in `PLAN.md`)

- Drop target: the Directory field's row only (the field and its list button), not the whole
  window; the field editor never inserts its own text for a dropped file.
- A folder is exactly one `file:` URL whose resource values say directory and not package (an
  `.app` or other bundle is refused like a file); a file, several items, a non-file drag or a
  promise without a URL is refused with no "+". Only the URL's own resource values are read.
  The path is used as dropped (standardized, trailing slash dropped, no symbolic link resolved).
- `~` rule: under This Mac's home by whole path components (`<home>2` is not under it) →
  `~/…`; the home itself → `~`; else absolute. This Mac's home is I-7's. D31's checks follow
  as for typed text, for every host.
- The fill is a pick (`fillDirectoryField(_:)`): the list closes and does not reopen, the
  highlight drops, the path is never logged.

## What was built

- `Sources/MuxFinderUI/Model/FolderDrop.swift`: `FolderDrop.outcome(for:home:)`, a pure
  function over dropped-item facts and the home path → the field's text or a refusal.
- `Sources/MuxFinderUI/Views/FolderDropView.swift`: an invisible AppKit view laid over the
  Directory row, in front of the field and its field editor, registered for every type that
  field editor accepts (so the field editor never takes a drop itself); clicks pass through;
  it reads only `isDirectory`/`isPackage` of the dropped URL. An accent ring around the field
  while an acceptable folder hovers. The Directory field's VoiceOver hint ends "Dropping a
  folder from Finder here fills in its path."
- Model wiring in `AppModelDirectories.swift` / `AppModelNewSession.swift` / `AppModel.swift`.
- `--preview-gallery new-session` (`Preview/NewSessionGallery.swift`, argument parsing in
  `Model/AppLaunchOptions.swift`, `Sources/MuxFinderApp/PreviewAppDelegate.swift`): 13 window
  states — editing, prefilled from the switcher's filter, invalid name, directory list,
  nothing to pick yet, saved already, unusable list, filtered, no matches, creating, name
  taken, creation failed, folder dragged over Directory.
- Screenshots: `docs/screenshots/new-session-states-{light,dark}.png` (new),
  `attach-states-*` and `switcher-states-*` regenerated (their inline form states left in
  I-9a); all six inspected by the worker, the light new-session sheet by the orchestrator.
- Tests: `Tests/MuxFinderUITests/FolderDropTests.swift` (25 new tests in 3 suites: the pure
  function's cases, the model's fill closing the list without reopening it, replacing text).
  Changed: `AttachFlowTests.attachFixturesCoverEveryState` and
  `DirectoryFilterModelTests.galleryFixturesCoverTheFilter` (the switcher's `formFiltered` and
  `formNoMatches` fixtures were retired as duplicates of the window's states); both recorded
  in `docs/TESTING.md`, *Phase I-9b*.
- Docs: `docs/MANUAL-CHECKLIST.md` item 23 (new) and items 17, 18, 20–22 for the window;
  `README.md`; `docs/ARCHITECTURE.md`; `docs/TESTING.md` *Phase I-9b*; `PLAN.md`.
  `docs/REQUIREMENTS.md` not edited: it is the verbatim brief and never describes the form
  inline.

## Acceptance

All met, 2026-11-06: the pure function with the specification's cases (folder under home,
outside, home itself, a file, two folders, a path needing no change) and more (package,
sibling prefix, zero items, non-file URL, trailing slash); its fill does not reopen the list;
the gallery's seven required states (editing, list open, filtered, busy, collision, failure,
drop highlight) rendered light and dark and inspected; the changed galleries' screenshots
regenerated; the checklist item and docs. Real drags from Finder, click-through, keys and
VoiceOver with the field being edited are checklist 23's.

## Verification (final tree, orchestrator, 2026-11-06)

- `swift build` exit 0.
- `swift test` exit 0, 815 core tests in 81 suites.
- `swift test --filter MuxFinderUITests` exit 0, 431 UI tests in 43 suites.
- `swift format lint -r Sources Tests` exit 0.
- `scripts/build-app.sh` exit 0 (Apple Development, not notarized); `codesign --verify --deep
  --strict build/muxFinder.app` exit 0.
- Worker: `swift build -warnings-as-errors` exit 0; `--report-menu-bar-item` under a private
  home exit 0, no child, home empty. No real run (no self-test, no `e2e-*`, no iTerm2 contact).

## Review

Codex (`autoclaude-review.sh`, 15 min) → `ship`, 0 findings. Not verified: checklist 23 (drops
while Directory is being edited, click-through, keyboard navigation, VoiceOver) —
`docs/reviews/phase-I-9b.md`.

## Open risks / deviations

- No real drag was made: whether the overlay receives drags ahead of the field editor in the
  real window was checked once by the worker with a throwaway probe in `/tmp` (a private AppKit
  method, deleted since; the shipped code uses no private API). Checklist 23.
- The popover gallery's committed screenshot predates I-6 and is 32 px shorter than it renders
  now (unchanged by I-9, so not regenerated).
- The worker ran one read-only `git log` on `docs/REQUIREMENTS.md`, against its brief; nothing
  was changed.
- `CLAUDE.md` (the user's uncommitted edit, untouched): its `--preview-gallery` list and its
  screenshot list should gain `new-session` (`--preview-gallery new-session` every New session
  window state; `new-session-states-*.png`) — the third note owed since I-9a, now concrete.
