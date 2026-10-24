# Global hotkey: session switcher

Proposed phase, queued after the directory picker item (`20-new-session-directory-picker.md`,
I-2). Suggested risk: **routine**. The attach, tmux and iTerm2 protocol paths do not change;
the new system pieces are a Carbon hotkey and a panel. Suggested split, each part with its own
verification, review and commit:

- **a — Shortcut and Settings (routine):** the shortcut value, its storage, the hotkey
  registrar, and the recorder in Settings > General.
- **b — Switcher panel (routine):** the panel, its content and keys, the engine's visibility
  rule, previews and documents.

## User request (2026-10-24, verbatim)

> I'd like to be able to have a global hotkey: it should show a window with a (selectable) list
> of currently live sessions and the option to create a new one. Add it to autoclaude (maybe to
> 14 "Popover readability" if it makes sense there)

## User decisions (2026-10-24, asked while planning)

- **A switcher panel of its own**, not the menu bar popover. It is Spotlight-like and
  keyboard-first, centered on the active screen.
- **No default shortcut.** The hotkey is off until the user records one in Settings > General.
- **Not part of Phase 14.** The user asked whether it fits there. It does not: Phase 14 is a
  restyle, and its requirements keep behavior and keyboard navigation unchanged. This phase
  reuses Phase 14's row look (state indicators, the readable badge, the muted unreachable
  host).
- **Position:** after I-1 and I-2. I-1 may replace `MenuBarExtra` with an `NSStatusItem` and a
  panel muxFinder owns; this phase can reuse that panel and key plumbing. I-2 adds the
  directory picker to New session, which the switcher's form reuses.

## Findings (2026-10-24, from the code and docs; nothing was run)

- **The popover cannot be opened from code.** It is SwiftUI's `MenuBarExtra(.window)`
  (`Sources/MuxFinderApp/MuxFinderMenuBarApp.swift`), which has no public API for that. The
  switcher does not depend on it.
- **Popover state lives in `AppModel`.** `AppModel` (`Sources/MuxFinderUI/Model/AppModel.swift`)
  holds one `searchText`, one `selection` and one `panel` for the popover. `handle(_:)` maps
  `PopoverKey`. `PopoverWindowBridge` installs a local key-down monitor and reports visibility
  through `popoverVisibilityChanged(_:)`. That sends `.popoverOpened` and `.popoverClosed` to
  the engine: a refresh now and every 15 s, with attachment checks only while the popover is
  visible (D20, D22).
- **New session.** `newSession()` starts a draft for This Mac (or the first enabled host), and
  `createSession()` runs `createAndAttach`. The form is `NewSessionPanelView`
  (`Sources/MuxFinderUI/Views/SessionPanelViews.swift`) over `NewSessionDraft`.
- **Session rows.** `PopoverContent` already computes rows with `isStale`, `isOpenInITerm2Here`
  and the activity. The search rule (case, diacritics and surrounding spaces ignored) lives
  there too.
- **Preferences.** The app stores no preferences today (no `UserDefaults` use).
  `scripts/uninstall.sh` already removes the app's preferences domain (D27). Settings > General
  has a "Startup" section and an "About muxFinder" section.
- **The hotkey API.** Carbon's `RegisterEventHotKey` (HIToolbox) registers a system-wide
  hotkey without the Accessibility or Input Monitoring permission. It returns
  `eventHotKeyExistsErr` when another app holds the combination.
  `NSEvent.addGlobalMonitorForEvents` needs Accessibility and cannot consume the key, so it
  does not fit. These come from Apple's documentation and common practice; verify them at run
  time.
- **The panel.** An `NSPanel` with `.nonactivatingPanel` can take the keyboard focus without
  activating muxFinder (an accessory app). Closing it then returns the focus to the previous
  app, and opening a session lets iTerm2 come forward as it does today. This also needs
  verifying.

## Design (record it as the next free D number and edit D22 and D23; names are illustrative)

1. **The shortcut value.** `GlobalShortcut` holds a key code and modifiers.
   - It needs at least one modifier other than ⇧ (F1–F20 may go without).
   - The recorder warns before taking ⌘ plus one key, because that shortcut would stop working
     in every app.
   - A combination macOS uses itself (⌘Space, ⌘Tab, ⌘⇧3/4/5) is refused, or shows as taken
     when registration fails.
   - The stored value is the key code. Its label shows the modifier symbols, plus the key as
     the current keyboard layout prints it (the user types on a non-US layout).
2. **Storage.** One key in the app's defaults domain (`cc.carpio.muxfinder`), written only when
   the user records or clears a shortcut. If it is missing or unreadable, the hotkey is off.
   Self-tests, the preview modes, the `--report-*` flags and `--remove-persistent-profiles`
   never read it, register a hotkey, or write it. A file under Application Support with D19's
   safe writes would also work; record the choice and the reason.
3. **The registrar.** Use a seam (for example `HotkeyRegistering`) with the Carbon
   implementation and a fake for tests.
   - Normal mode only: register once launching has finished, register again when the shortcut
     changes, and unregister on clear and at quit.
   - A failed registration (taken or invalid) shows in Settings next to the recorder (for
     example "Another app uses this shortcut. Choose another.") and in diagnostics (by kind
     only). It never raises an alert.
4. **Settings > General.** A new section with "Show session switcher" and a recorder.
   - Click the recorder, then type the combination. Esc cancels and Delete clears; "Clear" is a
     button.
   - While recording, the current hotkey is suspended, so pressing it records instead of
     opening the switcher.
   - It follows D23's pattern: it applies at once like the launch-at-login toggle, or through
     Save/Revert. Record which.
5. **The panel.** A non-activating `NSPanel`: borderless, rounded, opaque (Phase 14's
   background) and at a floating level. It joins the active Space and shows over full-screen
   apps.
   - It is centered horizontally on the screen with the keyboard focus, in its upper part.
     Record its width in the decision.
   - The hotkey toggles it. Esc, a click outside, losing the focus or switching apps close it.
   - Opening it closes the popover. Only one of the two shows at a time.
6. **Content.**
   - A search field at the top, focused and empty on every opening.
   - A flat list of **live** sessions in the popover's order (host order, then session order).
     Stale sessions are left out, so an unreachable host lists nothing.
   - Each row shows the session name, the host name, Phase 14's state indicator and the detail
     text ("4 windows · 1 client", "Open in iTerm2 here").
   - The filter applies the popover's search rule to session and host names.
   - The last row is always there: "New session…". When the filter text is a valid session
     name and no session has exactly that name, the row reads "New session “<text>”…" and
     fills in the name.
   - Hosts still checking or unreachable get a muted line under the list (for example
     "Saturno: checking…" or "Sirio: unreachable"), so missing sessions are explained. No red
     (Phase 14).
   - With no host turned on, the panel shows the popover's placeholder with "Open Settings".
   - The first row is selected on opening. The selection stays on the same session when
     updates arrive. ↑ and ↓ move it, without wrapping, like the popover.
7. **Actions.**
   - **Open a session.** Return or a double-click does what the popover's Open does: it
     focuses a session already open here, and otherwise attaches it through D25's state
     machine.
   - **Create one.** Return on the New session row, or ⌘N, shows the New session form inside
     the panel (`NewSessionPanelView` and `NewSessionDraft` reused). Its host defaults to This
     Mac, and it gets I-2's directory picker when that exists. Return creates the session,
     and Esc goes back to the list.
   - **Other keys.** ⌘R refreshes and ⌘, opens Settings. Move here and Detach stay in the
     popover.
   - **After Open or Create.** The panel shows the row's activity until the action ends or
     iTerm2 takes the focus, and closes on success. On a failure it stays open with the same
     text and recoveries as the popover row. If the panel had already closed, the failure
     shows on the popover row and at the top of the next switcher opening. A failure is never
     silent.
8. **Engine.** While the switcher is visible, the engine runs as it does with the popover open:
   a refresh now and every 15 s, with attachment checks so "Open in iTerm2 here" is current.
   The two visibilities are combined, so `.popoverOpened` and `.popoverClosed` are each sent
   once whenever "either one is visible" changes. D22's cookie rule gains the switcher.
9. **Keys in the panel.** A local key monitor like `PopoverWindowBridge`'s; an input method's
   composition goes to the text field. Reuse `PopoverKey`, or add a sibling enum.
10. **Accessibility.** Rows are labelled like the popover's ("<name> on <host>", with the state
    in the value). The panel's accessibility title is "Session switcher".
11. **Conventions:** `///` doc comments, closing-brace comments past 10 lines, sentence-case UI
    text, and no third-party dependency (hand-write the recorder; no shortcut package).

## Safety and checks

- No unattended run can press the hotkey (no synthesized keystrokes). Tests check the glue
  from hotkey to panel through the fake registrar's callback, and a person checks it by hand.
- A read-only diagnostic flag may prove that registration works in the signed bundle (for
  example `--report-hotkey-registration`). It registers and unregisters a fixed test
  combination unlikely to be in use (never the user's saved shortcut), prints the status and
  exits, leaving nothing registered. It calls muxFinder's own API in-process and posts no
  events. If the orchestrator judges that to be UI scripting under `CLAUDE.md`, drop it and
  leave the check to the manual checklist.
- Opening a session from the switcher goes through the existing coordinator. No `e2e-*` run
  is needed unless the attach path changes, and the self-tests stay as they are.

## Acceptance

- **Unit tests** cover:
  - Shortcut validation, the label (with a fake layout), and the storage round trip on a
    private defaults suite (never the real domain).
  - The registrar: a saved shortcut is registered at launch, and nothing is without one. It is
    registered again on a change and unregistered on clear and at quit. A taken combination
    shows its message.
  - The switcher's content: stale sessions left out, the order, the filter, the New session
    row's text and prefill, the selection kept across updates, the empty state and the
    no-hosts state.
  - The panel's keys.
  - The visibility rule: popover, then switcher, then both, then neither gives one
    opened/closed pair per change of "either one is visible".
  - A failure after the panel closed shows at the next opening.
  - The existing UI tests pass unchanged.
- **Preview galleries**, rendered light and dark with `--preview-snapshot` and committed to
  `docs/screenshots/`:
  - `--preview-gallery switcher`: the list, a filtered list, the New session row with the
    prefill, the form, an action in progress, a failure, no hosts, and an unreachable-host
    line.
  - Settings > General with the recorder: empty, recording, set and taken.
- **Builds and scripts.** `scripts/build-app.sh` exits 0, and `codesign --verify --deep
  --strict build/muxFinder.app` passes. `--report-menu-bar-item` behaves as before. The
  hermetic install-script check passes. Confirm that uninstalling removes the stored shortcut.
- **Documents.** `README.md` (setting the shortcut, using the switcher),
  `docs/ARCHITECTURE.md`, the `docs/TESTING.md` matrix, and the `CLAUDE.md` command notes for
  any new flag. `docs/MANUAL-CHECKLIST.md` gains items:
  - record a shortcut;
  - press it from another app and over a full-screen app;
  - filter, then open a session (iTerm2 comes forward with the right focus);
  - create a session;
  - Esc returns the focus to the previous app;
  - a taken shortcut shows its message;
  - "Clear" turns the hotkey off;
  - the shortcut survives a relaunch;
  - the label is right on the user's keyboard layout.
- **Shared verification** (`swift build`, `swift test`, `swift format lint -r Sources Tests`).
