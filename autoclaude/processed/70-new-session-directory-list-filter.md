# New session: typing in Directory filters the directory list

Proposed phase, queued after the plan's remaining work (after the Tab item,
`60-new-session-tab-between-fields.md`, which touches the same form's keys). Suggested risk:
**routine** (the directory list's content and keys; the store, discovery, creation and attach do
not change).

## User request (2026-11-04, verbatim)

> in the New session window, when adding a directory from the list, search should work (maybe
> trimming down the list of options as you type)

## User decisions (2026-11-04, asked while planning)

- **The Directory field is the search.** Combo-box style: what is typed in "Directory
  (optional)" filters the open list. With no row picked, the typed text stays the directory, as
  today. No separate search field.
- **Typing opens the list by itself while something matches**, and it closes again when nothing
  matches. Esc closes it and keeps the text. The pull-down button and ⌥↓ still open it too.

## Findings (2026-11-04, from the code; nothing was run)

- The list is D31's in-popover list (`DirectoryFieldView` and `DirectoryListView`,
  `Sources/MuxFinderUI/Views/DirectoryPickerViews.swift`), shared by the popover's and the
  switcher's New session form. Its content is the pure `DirectoryPickerContent`
  (`Sources/MuxFinderUI/Model/DirectoryPicker.swift:219`): sections Recent, Saved and "Sessions on
  <host>" (at most 10 folders), empty sections hidden, "Nothing to pick yet" when all are empty,
  then the actions "Save this directory" and "Clear recent directories on <host>". It already
  receives the field's text (`field:`), but only to decide "Save this directory"; nothing filters.
- The model side is `Sources/MuxFinderUI/Model/AppModelDirectories.swift`:
  `directoryPickerContent`, `openDirectoryList(highlightingFirst:)`, `closeDirectoryList()`,
  `moveDirectoryHighlight(down:)`, `pickDirectoryItem(_:)`, `handleDirectoryListKey(_:)`, and
  `directoryFieldChanged(from:)` (any edit drops the highlight, so Return creates from the field
  rather than picking a row highlighted before the edit; I-2b review fix).
- The popover's session search rule is `PopoverContent.matches(_:query:)`
  (`Sources/MuxFinderUI/Model/PopoverContent.swift:276`): case- and diacritic-insensitive
  substring, surrounding spaces ignored.

## Requirements

1. **Filtering (pure, in `DirectoryPickerContent`).** With field text (trimmed) empty, the list
   is as today. Otherwise each section keeps only the entries that match, in their order; a
   section left empty is hidden. Matching: reuse the popover's rule (case- and
   diacritic-insensitive substring) against the entry as stored and as shown. Decide and record
   whether a leading `~` in the field also matches the home folder spelled out and the reverse
   (the saved list is shared across hosts, so a remote home is unknown: if supported, only for
   This Mac); keep the rule simple and documented. An entry equal to the field's text, byte for
   byte, still shows (picking it changes nothing, but hiding it would be confusing).
2. **Actions stay.** "Save this directory" and "Clear recent directories on <host>" are never
   filtered away and keep today's enabled rules (Save works from the typed text). When the
   filter hides every entry but an action is on, the list shows "No matching directories" above
   the actions, distinct from "Nothing to pick yet".
3. **Auto-open and auto-close.** A user edit of the Directory field (not a pick, not a host
   change, not the draft being reset) opens the list when at least one entry matches, and closes
   it when none does (unless the user opened it with the button or ⌥↓, in which case it stays
   open showing "No matching directories" and the actions). Esc closes the list and keeps the
   text; the next edit may open it again. Opening from typing highlights nothing (Return still
   creates from the field); ↓ (or ⌥↓) highlights the first match, ↑/↓ move within the filtered
   rows only, Return picks the highlighted row, the pointer highlights as today.
   `directoryFieldChanged(from:)` keeps dropping the highlight on every edit.
4. **Picking ends the filter.** Picking an entry fills the field and closes the list (as today);
   that fill is not an edit, so it must not reopen the list.
5. **Busy and other states:** nothing opens while the draft is busy or with no host; a host
   change re-filters for the new host's entries and keeps the field (D31).
6. **Accessibility:** VoiceOver hears the number of matches when the filter changes (an
   announcement or the list's value), and the field's accessibility hint mentions that typing
   filters the list.
7. Edit **D31** (the list's content and keys), `README.md` where it describes the field,
   `docs/ARCHITECTURE.md` if it names the content rules.

## Acceptance

- Unit tests over `DirectoryPickerContent`: empty field → unchanged; a query that matches some
  entries in several sections; case and diacritics; no match with actions on (the "No matching
  directories" state) and with nothing at all; an exact match still shown; actions never
  filtered; the `~` rule as decided.
- UI tests over the model: typing that matches opens the list without a highlight; typing that
  matches nothing closes a list opened by typing but not one opened by the button; Esc keeps the
  text and closes; ↓ highlights the first match; ↑/↓ stay within the filtered rows; Return with
  no highlight creates from the field; picking fills the field and does not reopen; a host
  change re-filters; busy → nothing opens. Existing `DirectoryPickerTests` pass unchanged or
  with recorded changes.
- Preview galleries (popover and attach, and switcher if it shows the form) gain a filtered
  state and a "No matching directories" state, rendered light and dark through
  `--preview-snapshot` and inspected; `docs/screenshots/` regenerated for the changed galleries.
- `docs/MANUAL-CHECKLIST.md` gains an item (popover and switcher): type part of a saved, a recent
  and a session folder and see the list trim down; ↓ and Return pick; Esc keeps the text; with
  VoiceOver, the match count is announced.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`),
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` pass. No
  `e2e-*` run is needed; `--selftest new-session-local` only if the creation path is touched,
  with the thread-count caution. No real `directories.json` is read or written by any check.
