# New session in its own always-on-top window, with folder drop

Proposed phase, queued after the plan's remaining work and **after
`80-new-session-host-picker-keyboard.md`**: both change the New session form's key routing, and
this one has to carry 80's rule into the new window. Suggested risk: **high**. New session's
state stops living in the shared `panel`, which the switcher's creation follow-up, the deferred
creation failure and Move here all depend on. Creating and attaching do not change. Consider a
split: (a) the model and the window, (b) the folder drop, galleries and docs.

## User request (2026-11-05, verbatim)

> Sometimes I make this window appear but I have to go elsewhere to find the path I want to
> use. When I do this, the window disappears without trace. Would it be possible to make it
> behave like any other window, maybe just with "always on top" behaviour?

"This window" is the New session form (the same form as in items 60, 70 and 80; the user's
screenshots showed the switcher's).

## User decisions (2026-11-05, asked while queuing)

- **Always on top.** New session opens in its own titled, movable window that floats above
  other apps' windows. It stays open until Create succeeds, Cancel, Esc, or its close button
  ends it. muxFinder has no Dock icon and no ⌘Tab entry, so a window that went behind other
  apps would be hard to find again.
- **Both entry points.** ⌘N or the New session button or row, from the popover or from the
  session switcher, opens the same window. The popover or switcher closes as the window opens.
- **Extra: drag a folder in.** A folder dropped from Finder onto Directory fills in its path.
- **Not wanted:** a "Choose…" folder picker button, and keeping the draft after the close
  button. The close button acts like Cancel.

## Findings (2026-11-05, from the code; nothing was run)

- **Why it disappears.** The popover and the switcher are `PopoverPanelWindow`s
  (`Sources/MuxFinderUI/Views/MenuBarPopover.swift:352`): borderless, non-activating, not
  movable, `.transient`. Both close on any of three triggers, wired in `PanelObservers`
  (`MenuBarPopover.swift:80`): resigning key, a click outside (a global mouse-down monitor in
  `show(at:)`, line 304), or another app activating (`NSWorkspace.didActivateApplication`).
  Switching to Finder to look for a folder trips all three. The wiring is in
  `MenuBarPopover.swift:64-71` and `SessionSwitcher.swift:48-55`.
- **Why it leaves no trace.** `switcherDidClose()`
  (`Sources/MuxFinderUI/Model/AppModelSwitcher.swift:167`) calls `cancelPanel()` for an idle
  New session form, so the draft is gone. `switcherDidOpen()` does the same (line 150).
  `popoverDidClose()` (`AppModel.swift:679`) leaves `panel` alone, so the popover may show the
  form again when reopened. That asymmetry is invisible to the user, since the form vanished
  either way.
- **State shared through `panel`.** New session is `panel = .newSession`
  (`AppModelSessions.swift:237`, `AppModelSwitcher.swift:335`). `PopoverPanel` holds either
  Move here or New session, so today they exclude each other. Other code builds on that:
  `switcherShowsNewSession`, `newSessionFromSwitcher()` (name prefilled from the switcher's
  filter, line 278), `switcherCreation.closesOnSuccess`, `switcherCreationFailed(_:)` and
  `showDeferredCreationFailure()` (the form comes back with a failure the user did not see,
  line 317-336), and `cancelPanel()` (a creation in progress goes on; "Open existing" stops
  looking). `SelfTestDriver.swift:371` calls `cancelPanel()` too.
- **Keys.** The panels' keys come from `PanelKeyTrackingView`'s local monitor
  (`PopoverWindowBridge.swift`) through `AppModel.handle(_:)` (`AppModel.swift:793`): Return
  creates, Esc closes the directory list and then the form, ⌥↓ opens the list, ↑/↓ move in it.
  Tab uses AppKit's key view loop, which the panel recalculates (Phase I-6). The new window
  needs all of this, plus item 80's rule for a focused Host picker.
- **Patterns to reuse.** The Settings window (`Views/Settings/SettingsWindowController.swift`)
  is the app's titled-window pattern in an accessory app (D33: plain `NSApplication`). The
  directory list (D31) is drawn inside the form, so a window that grows with its content
  keeps it.

## Requirements

1. **The window.** One New session window at a time. It is titled "New session" and movable,
   with a close button, and floats above other apps' windows (floating level). It does not
   hide when muxFinder is inactive. It never closes because another app activated or a click
   landed elsewhere. Clicking into it makes it key without taking the frontmost app's place,
   if a non-activating panel allows that; otherwise it activates muxFinder, as Settings does.
   Decide and record which. It opens on the screen of the popover or switcher it came from,
   in a position decided and recorded (for example, centered where the switcher shows). It
   grows and shrinks with the directory list. Decide whether it shows over full-screen apps
   and on every Space, as the panels do, and record the choice.
2. **Opening.** From the popover (⌘N, the New session button) or the switcher (⌘N, the New
   session row, name prefilled from the filter as today): the window opens, and the popover or
   switcher closes. If the window already shows, it comes to the front with its draft
   untouched; the switcher's prefill does not overwrite a draft. The popover and switcher no
   longer show the form inline. Move here stays an inline confirmation in the popover.
3. **Ending.** Create: the window shows the progress as the form does now. On success the
   window closes and the attach goes on as today (its row shows it). On a collision or
   failure the window stays, showing it, with "Open existing" as now. Cancel, Esc (once the
   directory list is closed), and the close button all act as `cancelPanel()` does today for
   New session: the draft is dropped, a creation in progress goes on and shows its result on
   its row, and "Open existing" stops looking. If the window was closed while creating and the
   creation then fails, the failure must not be silent: bring the window back with it, or show
   it on the row, and record which. Retire the switcher-only deferred-failure path where the
   window makes it unnecessary, keeping its guarantee.
4. **Model.** New session's state no longer lives in `panel`, so a Move here confirmation in
   the popover and the New session window can both show. Re-check every user of
   `switcherShowsNewSession`, `switcherCreation` and `showDeferredCreationFailure()`, and the
   self-test driver. Opening and closing the popover or switcher never touches the window or
   its draft.
5. **Keys in the window.** The same as the form today: Return creates, Esc closes the list
   and then the window, ⌥↓ opens the list, ↑/↓ move in it, Tab and ⇧Tab follow the key view
   loop with keyboard navigation's rule (recalculated as views change), item 80's Host picker
   rule applies, and input methods compose first. ⌘W closes the window like Cancel. The
   popover's and switcher's own keys (⌘F, ⌘R, ⌘,) are not the window's; decide whether ⌘, and
   ⌘R work there.
6. **Folder drop.** Dropping a single folder from Finder onto the Directory field (or
   anywhere on the window, decide which) fills the field with its path. Under This Mac's home
   folder the path is shortened to `~/…`, which also carries over to a remote host with the
   same layout. Elsewhere it is absolute. It works for every host: the text then goes through
   D31's checks like typed text. The fill counts as a pick, not an edit: the directory list
   closes and does not auto-open (I-7). Files, several items and non-file drags are refused
   (the drag shows no "+"). Only the dropped URL is read, never the folder's contents, and the
   path is never logged. Drag feedback (a highlight on the field) and VoiceOver: the field's
   hint mentions dropping a folder.
7. **Decision and docs.** Record the window as **D34** (next after D33), and edit D30, D31
   and D32 where they describe the inline form, its keys and the switcher's New session
   follow-up. Update `README.md`, `docs/ARCHITECTURE.md` and `docs/REQUIREMENTS.md` if it
   describes the form inline.

## Acceptance

- Unit tests over the model: opening from the popover and from the switcher (both close,
  the window shows, prefill only into an empty draft); opening again brings it to the front
  with its draft; Cancel, Esc and close drop the draft; success closes the window; collision
  and failure keep it; a failure after closing during creation follows the decided rule; a
  Move here confirmation and the window at the same time; the switcher and popover opening
  and closing leave the window alone. The folder drop is a pure function from dropped URLs
  and This Mac's home to the field's new text or a refusal: a folder under home, a folder
  outside, the home folder itself, a file, two folders, a path needing no change. Its fill
  does not reopen the list. Existing tests pass, or the changes are recorded.
- Preview fixtures: a gallery for the window's states (editing, list open, filtered, busy,
  collision, failure, drop highlight), rendered light and dark through `--preview-snapshot`
  and inspected. The popover and switcher galleries drop their inline form states.
  `docs/screenshots/` is regenerated for the changed galleries.
- `docs/MANUAL-CHECKLIST.md` gains an item, and items 20 and 21 plus 80's are updated for
  the window. Open New session from the popover and then from the switcher; switch to Finder,
  browse, and see the window stay on top; drag a folder onto Directory and see `~/…`; press
  Return and see the session created there and opened. Then close with the button and with
  Esc and see the draft gone on reopen; and ⌘N with the window open brings it forward
  unchanged. Real drags and key presses are the user's.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`),
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` pass.
  `--selftest new-session-local` must pass, since the model behind New session changes; run
  it with the thread-count caution. `--report-menu-bar-item` and `--report-popover-placement`
  must still pass, with a private home. No `e2e-*` run is needed. No real `hosts.json`,
  `directories.json` or `preferences.json` is read or written by any check.
