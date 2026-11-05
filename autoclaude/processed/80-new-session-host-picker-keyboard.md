# New session: change the host from the keyboard

Proposed phase, queued after the plan's remaining work. Suggested risk: **routine** (key
routing and focus in the New session form; creation, the directory store and attach do not
change).

## User request (2026-11-05, verbatim)

> In this screen, Shift-Tab from the Name field should take you back to the Host dropdown menu

The screenshot shows the New session form as the session switcher shows it (540 pt wide):
the Host picker with a host chosen, the Name field with the focus ring and the caret,
"Directory (optional)" with its pull-down button, then Cancel and Create.

Asked what ⇧Tab from Name does today, the user answered (verbatim):

> It gets you back to the Host dropdown menu, but you can't change the Host using the keyboard

And then, to settle it (verbatim):

> The actual issue was not Shift+Tab not getting back to Host, it was being unable to use the
> dropdown menu with the keyboard

So the request is: **once the focus is on Host, the keyboard must be able to open the host
menu and change the host.** The Tab and ⇧Tab order already works (Phase I-6) and is not to be
changed.

## User decisions (2026-11-05, asked while queuing)

- **Follow macOS's keyboard navigation setting.** With keyboard navigation on, ⇧Tab from Name
  reaches Host, as Phase I-6 already arranged. With it off, macOS skips pop-up menus and Tab
  moves only between Name and Directory. muxFinder does not force Host into the loop.

## Findings (2026-11-05, from the code and read-only checks; no key pressed, nothing launched)

- The installed `/Applications/muxFinder.app` binary dates from 2026-11-04 19:45. That is after
  Phase I-7's commit (19:37), so it has I-6's recalculated key view loop. macOS keyboard
  navigation is on (`defaults read -g AppleKeyboardUIMode`: 2, read only). This matches the
  user's report that ⇧Tab from Name reaches Host (I-6's loop: Name → Directory → the list's
  button → Cancel → Create → Host picker → Name).
- The Host picker is a default-style SwiftUI `Picker`
  (`Sources/MuxFinderUI/Views/SessionPanelViews.swift:90`). On macOS that is a pop-up button.
- **Likely cause (unverified): the panel's key routing swallows the arrows while a panel
  shows.** `AppModel.handle(_:)` (`Sources/MuxFinderUI/Model/AppModel.swift:793`) returns
  `.handled` for `.up` and `.down` whenever `panel` is set ("the arrows … do nothing", line
  804). `PanelKeyTrackingView`'s local monitor
  (`Sources/MuxFinderUI/Views/PopoverWindowBridge.swift`) therefore consumes ↑ and ↓ before
  the focused pop-up button sees them. The same goes for ⌥↓, which opens the *directory* list
  (line 799) wherever the focus is, and for Return, which creates the session (line 798).
  With the directory list open, `handleDirectoryListKey(_:)`
  (`Sources/MuxFinderUI/Model/AppModelDirectories.swift:171`) takes ↑/↓/⌥↓/Return/Esc first,
  also wherever the focus is.
- Space is no `PopoverKey`, so it should reach the pop-up button. Nobody knows yet whether
  Space opens the host menu in this borderless, non-activating panel of an accessory app, or
  whether the menu's own keys (↑/↓, Return, Esc, type-to-select) work there during menu
  tracking.

## Requirements

1. **Diagnose first** and record the cause in PLAN.md *Verified facts*. Stay within the run
   rules: no synthesized or posted key events, in process or not, and no UI scripting.
   Allowed: in-process reads of the first responder after AppKit's own
   `selectPreviousKeyView(_:)` from Name (I-6's `--preview-key-view-loop` diagnostic can grow
   for this), the routing decision the monitor would make for ↑, ↓, ⌥↓, Space, Return and Esc
   with that first responder (a pure function, unit-testable), and the preview galleries.
2. **With Host focused** (keyboard navigation on), in the popover's form and the switcher's:
   the keys macOS gives a focused pop-up button open the host menu. That is Space, plus ↑/↓
   (and ⌥↓) as AppKit handles them; check AppKit's actual behavior and record it. Inside the
   open menu, ↑/↓ move, Return or Space picks, type-to-select works as AppKit gives it, and
   Esc closes the menu without closing the panel. A host picked this way acts exactly like a
   click: the draft's host changes, the directory list re-filters for that host (D31), Name
   and Directory keep their text, and the picker stays disabled while the draft is busy.
3. **Key routing:** while the first responder is the Host picker (or the open host menu), the
   panel's monitor leaves ↑, ↓ and ⌥↓ to it instead of mapping them. Return with the menu
   closed still presses Create (the default button), and Esc with the menu closed still
   closes the panel, as now. ⌘R, ⌘, and the rest are unchanged. With the focus in Name,
   Directory or the list's button, nothing changes. Decide what happens when the directory
   list is open and ⇧Tab moves the focus to Host (I-6 left the list open on Tab): either
   close the list when the focus leaves Directory and its button, or let the list keep its
   keys only while the focus is there. Record the choice in D31. Prefer AppKit's own
   pop-up-button behavior over re-implementing it in the model.
4. **Keyboard navigation off:** no change. Host is not in the loop (user decision above).
5. Input methods keep getting keys first while composing (`hasMarkedText()`), and VoiceOver
   can still reach and operate the picker (VO-Space).
6. Edit **D30/D31/D32** where they describe the panel's keys, `README.md` if it lists the
   form's keys, and `docs/ARCHITECTURE.md` if the key routing changes.

## Acceptance

- Unit tests over the routing decision: with Host focused, ↑/↓/⌥↓ go to the focused view,
  and Return/Esc behave as above. With Name or Directory focused, they behave as today. With
  the directory list open and the focus on Host, they follow the rule decided in requirement
  3. Existing `NewSessionTabOrderTests` and directory-list tests pass unchanged or with
  recorded changes.
- The in-process diagnostic's output (first responder after ⇧Tab from Name, and the routing
  for those keys), before and after the fix, recorded in `docs/TESTING.md`.
- The popover, attach and switcher galleries still render. Regenerate screenshots only if a
  state's look changed.
- `docs/MANUAL-CHECKLIST.md` gains an item, or item 20 is extended, covering both the
  popover's and the switcher's form with keyboard navigation on: ⇧Tab from Name to Host;
  Space opens the host menu; ↓ and Return pick another host (the directory list's "Sessions
  on <host>" section follows); ↑/↓ on the closed picker as AppKit handles them; Esc closes
  the menu, not the panel; then Tab back to Name, type `muxfinder-test-host`, press Return,
  and the session is created on the host picked. With keyboard navigation off, ⇧Tab from
  Name goes to Directory (Host skipped). Real key presses are the user's.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`),
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` pass. No
  `e2e-*` run is needed. Run `--selftest new-session-local` only if the creation path is
  touched, with the thread-count caution. No real `hosts.json` or `directories.json` is read
  or written by any check.
