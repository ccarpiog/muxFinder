# New session: Tab moves from Name to Directory

Proposed phase, queued after the plan's remaining work. Suggested risk: **routine** (keyboard
focus in the New session form; creation and attach do not change).

## User request (2026-11-04, verbatim)

> In the "New session" window, after I tap the "Name", tabbing to get to the "Directory
> (optional)" field doesn't work

The screenshot shows the New session form as the session switcher shows it (the switcher's
540 pt width): Host picker, Name field with the focus ring and the caret, "Directory
(optional)" field with its pull-down button, Cancel and Create.

## Findings (2026-11-04, from the code; nothing was run)

- The form is `NewSessionPanelView` (`Sources/MuxFinderUI/Views/SessionPanelViews.swift`),
  shared by the popover and the switcher (D32). Name is a plain SwiftUI `TextField` with
  `.focused($isNameFocused)` (line 128; the switcher sets the focus in `.task`, line 109).
  Directory is a plain SwiftUI `TextField` in `DirectoryFieldView`
  (`Sources/MuxFinderUI/Views/DirectoryPickerViews.swift:24`) with its pull-down `Button`.
  `DirectoryFieldView`'s doc comment already promises "Space on the button once Tab reaches
  it (with macOS's keyboard navigation on)".
- **Ruled out: the key monitor.** `PanelKeyTrackingView`'s local key-down monitor
  (`Sources/MuxFinderUI/Views/PopoverWindowBridge.swift:78`) passes on every key
  `PopoverKey(keyCode:modifierFlags:charactersIgnoringModifiers:)` does not map, and it maps no
  Tab (only ↑, ↓, Return, keypad Enter, Esc, ⌥↓ and ⌘F/⌘R/⌘N/⌘,). Nothing else in
  `MuxFinderUI` handles Tab.
- **Unverified suspects:** the hosting setup of the borderless, non-activating
  `PopoverPanelWindow` (`MenuBarPopover.swift`; the `NSHostingView` is a subview of
  `PopoverPanelContentView`, not the window's content view; `canBecomeKey` true,
  `canBecomeMain` false), the window's key view loop (`autorecalculatesKeyViewLoop`,
  `initialFirstResponder`), SwiftUI's focus system in such a panel of an inactive accessory
  app, or the user's "Keyboard navigation" setting (which should not stop Tab between two text
  fields). Whether the popover's form has the same problem as the switcher's is not known.

## Requirements

1. **Diagnose first** and record the cause in PLAN.md *Verified facts*. Checks within the run
   rules only: no synthesized key events, in process or not, and no UI scripting. Allowed:
   reading the panel's view hierarchy and key view loop in process (for example a read-only
   diagnostic or a preview-fixture mode that prints `nextValidKeyView` chains and the first
   responder), calling AppKit's own `selectNextKeyView(_:)` on muxFinder's own window in
   process, and the preview galleries.
2. **Tab order** in the form, in the popover and in the switcher: Tab from Name goes to
   Directory and ⇧Tab goes back; with macOS keyboard navigation on, Tab also reaches the Host
   picker, the pull-down button, Cancel and Create in reading order. Tab never leaves the
   panel or closes it, and never reaches the switcher's or popover's list behind the form.
3. Prefer the native fix (SwiftUI or AppKit focus working in the panel). If the panel cannot
   carry native Tab navigation, handle Tab and ⇧Tab in the panel's key routing (a new
   `PopoverKey` case, used only while the New session form shows, falling through elsewhere)
   with the focused field held by the model and bound with `@FocusState`, so the order is
   unit-testable. Record which one and why as a decision (D31/D32 edited).
4. The directory list (D31) keeps its keys: ⌥↓ opens it, ↑/↓ move inside it, Return still
   creates, Esc closes the list first. Tab while the list is open closes it or moves on;
   decide which and record it.
5. Input methods: Tab during marked text goes to the input method, as every other key does
   (`hasMarkedText()` check).

## Acceptance

- If the model-held focus route is taken: unit tests for Tab and ⇧Tab over the model (Name →
  Directory → … and back, nothing outside the form, the list open and closed, marked text
  left alone). If the native route is taken: the in-process diagnostic's key view chain
  before and after the fix, recorded in `docs/TESTING.md`. Existing tests pass unchanged or
  with recorded changes.
- The popover, attach and switcher galleries still render; regenerate screenshots only if a
  state's look changed.
- `docs/MANUAL-CHECKLIST.md` gains an item, in both the popover's and the switcher's form:
  Tab from Name to Directory and ⇧Tab back, with keyboard navigation off and on; then type a
  directory and press Return to create. (Real key presses are the user's; they cannot be
  synthesized under the run rules.)
- `README.md` if it lists the form's keys; `docs/ARCHITECTURE.md` if the key routing changes.
- Shared verification (`swift build`, `swift test`, `swift format lint -r Sources Tests`),
  `scripts/build-app.sh` and `codesign --verify --deep --strict build/muxFinder.app` pass. No
  `e2e-*` run is needed; if the creation path is touched, `--selftest new-session-local` with
  the thread-count caution.
