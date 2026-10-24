# New session: pick the directory

Proposed phase, queued after Phase 14 and after the popover placement item
(`10-popover-under-menu-bar-icon.md`). Suggested split, each part with its own verification,
review and commit:

- **a — Core (high, hermetic):** session folders in discovery (probe, parser, snapshot) and
  the directory store.
- **b — UI (routine):** the picker in New session, the saved list in Settings, previews and
  documents.

## User request (2026-10-24, verbatim)

> When creating a new session, the Directory should be selectable. Maybe allow adding a list
> of paths or selecting on the last few used paths.

## User decisions (2026-10-24, asked while planning)

- **Saved directories:** one list shared by all computers. `~/…` paths resolve on each host.
- **Recent directories:** remembered separately for each host.
- **Session folders:** also suggest the start folders of the sessions already on that host.
- **Out of scope:** a Finder "Choose…" panel and browsing folders over SSH. The user did not
  pick either.

## Findings (2026-10-24, from the code)

- **The field today.** `NewSessionPanelView` (`Sources/MuxFinderUI/Views/SessionPanelViews.swift`)
  has a free text field, "Directory (optional)", bound to `NewSessionDraft.directory`
  (`Sources/MuxFinderUI/Model/SessionPanels.swift`) and checked by
  `Validation.workingDirectory(_:)`. Empty means the host's home folder.
- **Resolving it on the host.** D18's static script does this: `~/rest` is under `$HOME`, a
  relative path is relative to `$HOME`, and a folder it cannot enter exits 81
  (`directoryMissing`).
- **Discovery.** `Sources/MuxFinderCore/Tmux/ProbeScript.swift` runs `list-sessions -F` with
  `#{session_name}` as the last field (free text, "the rest of the line"). It does not report
  `#{session_path}`.
- **Keys in panels.** While a panel is open, `AppModel.handle(_:)` swallows ↑/↓
  (`case (.up, _), (.down, _), …: break`), so a pull-down list needs its own keyboard path.
- **Order.** Phase 14 restyles the panels; this phase builds on its look.

## Design (record it as the next free D number; names are illustrative)

1. **Store.** A new file, `~/Library/Application Support/muxFinder/directories.json`, schema 1:
   `{"schemaVersion": 1, "saved": ["~/…", …], "recent": {"<host id>": ["…", …]}}`.
   - It is loaded and written the way D19 treats `hosts.json`: `PrivateStorage`, 0600, safe
     publication, a size cap, unknown keys ignored, and loading never writes. An invalid or
     unsafe file gives empty lists and a notice, and the file is left as it is.
   - It is kept apart from `hosts.json` because recents change on every creation, and usage
     state must never race with, or create backups of, the host list (D19
     `save(_:expecting:)`).
   - Every entry passes `Validation.workingDirectory`; entries that fail are dropped when
     loading, and the notice counts them.
   - Caps: at most 50 saved entries, and at most 8 recent ones per host (newest first).
     Duplicates collapse by exact string. The app cannot know a remote home folder, so `~/x`
     and `/Users/…/x` stay distinct.
   - `scripts/uninstall.sh` already removes the support folder. Confirm it; no change is
     expected.
2. **Recording a recent.** Only a creation that made the session records one (the
   `createAndAttach` `onCreated` path), even if the attach fails afterwards.
   - The directory is recorded for that host as checked. An empty field (the home folder) is
     not recorded.
   - A collision, a failed creation or `mayHaveCreated` records nothing.
   - A host removed in Settings loses its recents at the next write.
   - A failed write is logged by kind only and never blocks or fails the creation.
3. **Session folders in discovery.**
   - The probe adds each session's `#{session_path}` in a way that a path holding tabs or
     newlines cannot break the line framing. For example, a separate record kind keyed by
     session id, with the path as the last field. The parser drops a path that holds control
     characters, or one it cannot frame.
   - The probe and the parser change together, since the app sends the script on every run.
     The golden fixtures and parser tests are updated.
   - The session model (or `HostSnapshot`) gains an optional start folder. It is display data
     only: it reaches a command only when the user picks it into the field, and it is then
     checked like typed text.
   - A stale snapshot keeps its last folders.
   - `discover` and `refresh --once` print it. Docs and fixtures use synthetic paths only.
4. **The picker.** The Directory field stays a text field (typing, pasting, `~/…`), with a
   pull-down button at its trailing edge. For the selected host, the button lists:
   - "Recent" (that host's recents);
   - "Saved" (the shared list);
   - "Sessions on <host>" (the distinct start folders of that host's listed sessions, sorted,
     at most 10).

   Rules for the list:
   - Each section shows only when it is not empty. With all three empty, the button says
     there is nothing to pick yet.
   - Picking an entry fills the field.
   - Long paths are truncated in the middle. The full path is in the help text and the
     accessibility label.
   - Changing the host updates the list and keeps what is in the field.

   Below the sections:
   - "Save this directory" adds the field's current value. It is disabled when the field is
     empty, invalid or already saved.
   - "Clear recent directories on <host>".
5. **Editing the saved list in Settings.** Add a "Directories" section, under General or in a
   tab of its own. It can add (checked inline), remove and reorder entries. It follows the
   Settings window's Save/Revert pattern (D23) unless a recorded reason says otherwise.
6. **Keyboard.**
   - The list opens from the keyboard, for example ⌥↓ in the Directory field, or Tab to the
     button and then Space.
   - ↑/↓ work inside the open list.
   - Return in the field still means "Create".
   - Esc closes the list first, then the panel.
   - `PopoverKey` and `AppModel.handle(_:)` gain what this needs. The rest of the popover's
     shortcuts do not change.
7. **Self-tests and checks.** `--selftest new-session-local` and the preview modes never read
   or write the real `directories.json`. They use an in-memory or private store, the same way
   the self-tests use an in-memory This Mac.
8. **Privacy and safety.**
   - Directories are user data. They never go into logs, diagnostics or the operation log
     (kinds and counts only), or into committed fixtures (use synthetic paths such as
     `~/projects/site`).
   - Screenshots come from the preview fixtures only.
   - Every path that reaches a `NewSessionRequest` goes through `Validation.workingDirectory`,
     whatever its source, and stays data (D3, D18).
9. **Conventions:** `///` doc comments, closing-brace comments past 10 lines, sentence-case UI
   text ("Save this directory", "Clear recent directories on Saturno"), and no third-party
   dependency.

## Acceptance

- **Unit tests** cover:
  - The store: a missing file, invalid JSON, an unsafe or oversized file, unknown keys,
    invalid entries dropped, the caps, duplicates, and order.
  - The recording rules: created → recorded; a collision or failure → not recorded; an empty
    field → not recorded; an attach failure after creation → recorded.
  - The parser's session-folder record: spaces, Unicode, `#`, `;`, and tabs or newlines or
    control characters refused or dropped, plus a report with no such record.
  - The picker's content per host: the sections, their order, the caps, and hidden empty
    sections.
  - Picking an entry, which fills and checks the draft.
  - The new keys.
  - The existing tests pass unchanged, or with recorded additions.
- **Preview galleries.** The New session states, with the list showing recents, saved
  entries and session folders, plus the empty case, and a Settings state for the saved list.
  All synthetic, rendered light and dark with `--preview-snapshot`, and committed to
  `docs/screenshots/`.
- **Real read-only check**, gated like any discovery run: `swift run muxfinder-probe discover
  --local` and `discover --ssh saturno-m4` report session folders that parse. Record counts
  only; never paste paths into the docs.
- **Builds and scripts.** `scripts/build-app.sh` exits 0 and `codesign --verify --deep
  --strict` passes. The hermetic install-script check passes. If 7 changes the self-test's
  path, `--selftest new-session-local` passes, with the thread-count gate as usual.
- **Documents.** `README.md` (usage), `docs/ARCHITECTURE.md` (the new file and the probe
  record), and `docs/MANUAL-CHECKLIST.md`: create a session from a recent directory, a saved
  one and a session folder, on This Mac and on Saturno.
- **Shared verification** (`swift build`, `swift test`, `swift format lint -r Sources Tests`).
