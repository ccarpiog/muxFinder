import AppKit
import MuxFinderCore
import SwiftUI

/// `--preview-fixtures --preview-key-view-loop popover|switcher` (PLAN.md Phase I-6): a
/// read-only diagnostic of the New session form's keyboard focus in muxFinder's real panel.
///
/// It builds the panel the app uses (`PanelHost` with `PopoverPanelRoot` or
/// `SwitcherPanelRoot`, the live view and its key monitor included) over a synthetic fixture
/// (`AttachFixtures.newSession`, `SwitcherFixtures.form`; no engine, host list, directory list,
/// hotkey or iTerm2), shows it in the middle of the main display and makes it key (the
/// frontmost app stays frontmost; the panel may take the key focus for about ten seconds, as
/// `--report-popover-placement` does), first with the list, then with the form replacing it,
/// as ⌘N does in the app. It prints one `muxFinder key view loop:` line per finding: the
/// window's key state and key view loop settings, macOS's keyboard navigation setting (read,
/// never changed), the first responder, the panel's key views (numbered in view tree order)
/// with their links, the `nextValidKeyView` and `previousValidKeyView` chains from the Name
/// field, and where the focus goes, step by step from Name, for Tab and ⇧Tab, with the
/// directory list closed and open. A step is what the key does without its event: with a field
/// editor first, the action message its key binding sends (`insertTab(_:)`,
/// `insertBacktab(_:)`, through `doCommand(by:)`), else the window's own
/// `selectNextKeyView(_:)` or `selectPreviousKeyView(_:)`, which `NSWindow` runs for a Tab the
/// responder chain leaves. Then, for each list state, the Host picker (PLAN.md Phase I-8): the
/// first responder after the window's own step back from Name (`selectKeyView(preceding:)`,
/// with `selectPreviousKeyView(_:)` and `insertBacktab(_:)` as cross-checks; its class,
/// whether it is an `NSPopUpButton`, its menu's item count and which key binding messages it
/// answers; never a title) and where the panel's key monitor would send ↑, ↓, ⌥↓, Space,
/// Return and Esc with it, and with the focus in Name (`PanelKeyRoute`). No event is made or
/// posted and no menu is opened. Views are named by their class, kind, placeholder or
/// accessibility label, all synthetic.
@MainActor
public final class KeyViewLoopReport {
  /// How long the panel settles (layout, the switcher's focus request) before a look.
  static let settleDelay: Duration = .milliseconds(1_000)
  /// How long the focus settles after each step.
  static let stepDelay: Duration = .milliseconds(250)
  /// The most links a chain or a walk follows.
  static let maximumSteps = 10

  /// Which panel.
  private let kind: AppLaunchOptions.KeyViewLoopPanel
  /// The fixture model the form edits.
  private let model: AppModel
  /// The panel's window.
  private let window: NSWindow
  /// The panel, as its controller drives it.
  private let surface: any PopoverPanelSurface
  /// Writes one line.
  private let write: (String) -> Void
  /// The panel's key views at the last listing, numbered from 1 in that order.
  private var numbered: [ObjectIdentifier: Int] = [:]

  /// A report on `kind`'s panel over its fixture, the form not shown yet; `write` gets each
  /// line.
  private init(kind: AppLaunchOptions.KeyViewLoopPanel, write: @escaping (String) -> Void) {
    self.kind = kind
    self.write = write
    switch kind {
    case .popover:
      let model = AppModel(fixture: AttachFixtures.newSession)
      model.panel = nil
      let host = PopoverPanelHost(model: model)
      (self.model, window, surface) = (model, host.panel, host)
    case .switcher:
      let model = AppModel(fixture: SwitcherFixtures.form)
      model.panel = nil
      let host = PanelHost<SwitcherPanelRoot>(level: .floating) { onSizeChange in
        SwitcherPanelRoot(model: model, onSizeChange: onSizeChange)
      }
      (self.model, window, surface) = (model, host.panel, host)
    }
  } // End of init(kind:write:)

  /// Runs the report on `kind`'s panel, writing each line to `write`; returns whether the
  /// form's Name and Directory fields were found (the exit status is 0 then, else 1).
  public static func run(
    _ kind: AppLaunchOptions.KeyViewLoopPanel, write: @escaping (String) -> Void
  ) async -> Bool {
    let report = KeyViewLoopReport(kind: kind, write: write)
    let found = await report.inspect()
    report.surface.hide()
    return found
  }

  /// The steps: shows the panel with the list, then the form, and looks at the form with the
  /// directory list closed, then open.
  private func inspect() async -> Bool {
    show()
    try? await Task.sleep(for: Self.settleDelay)
    line(
      "panel \(kind.rawValue) key \(yesNo(window.isKeyWindow)) app active "
        + "\(yesNo(NSApp.isActive)) keyboard navigation "
        + "\(NSApp.isFullKeyboardAccessEnabled ? "on" : "off") autorecalculatesKeyViewLoop "
        + "\(yesNo(window.autorecalculatesKeyViewLoop))")
    line(
      "with the list: initialFirstResponder \(name(window.initialFirstResponder)); "
        + "first responder \(name(window.firstResponder))")
    model.panel = .newSession
    try? await Task.sleep(for: Self.stepDelay)
    surface.setFrame(frame())
    try? await Task.sleep(for: Self.settleDelay)
    line(
      "with the form: initialFirstResponder \(name(window.initialFirstResponder)); "
        + "first responder \(name(window.firstResponder))")
    guard let nameField = textField(prompt: NewSessionPanelView.namePrompt),
      textField(prompt: DirectoryFieldView.prompt) != nil
    else {
      line("the form's Name and Directory fields were not found")
      return false
    }
    await walk(from: nameField, listOpen: false)
    await hostPicker(from: nameField, listOpen: false)
    model.openDirectoryList(highlightingFirst: false)
    try? await Task.sleep(for: Self.stepDelay)
    surface.setFrame(frame())
    try? await Task.sleep(for: Self.stepDelay)
    await walk(from: nameField, listOpen: true)
    await hostPicker(from: nameField, listOpen: true)
    return true
  } // End of func inspect()

  /// The chains from `nameField`, the Tab and ⇧Tab walks from it, then the key views with
  /// their links and the chains again (AppKit recalculates a loop it was told to only when the
  /// window is next asked for a key view), with the directory list as `listOpen` says.
  private func walk(from nameField: NSTextField, listOpen: Bool) async {
    let state = "list \(listOpen ? "open" : "closed")"
    line("\(state): directory list shows \(yesNo(model.directoryPicker.isOpen))")
    let views = keyViews()
    numbered = Dictionary(
      uniqueKeysWithValues: views.enumerated().map { (ObjectIdentifier($1), $0 + 1) })
    chains(from: nameField, state: "\(state), before the steps")
    for forward in [true, false] {
      let key = forward ? "Tab" : "⇧Tab"
      await focus(nameField, state: state)
      for step in 1...Self.maximumSteps {
        let how = press(forward: forward)
        try? await Task.sleep(for: Self.stepDelay)
        line(
          "\(state): \(key) \(step) (\(how)): \(name(window.firstResponder)); list shows "
            + yesNo(model.directoryPicker.isOpen))
        if isEditing(nameField) || !window.isVisible { break }
      } // End of loop over the key's steps
    } // End of loop over Tab and ⇧Tab
    for view in views {
      line(
        "\(state): view \(name(view)) at \(position(of: view)) canBecomeKeyView "
          + "\(yesNo(view.canBecomeKeyView)) next \(name(view.nextKeyView))")
    }
    chains(from: nameField, state: "\(state), after the steps")
  } // End of func walk(from:listOpen:)

  /// The Host picker (PLAN.md Phase I-8), from Name: the window's own
  /// `selectPreviousKeyView(_:)` with Name's field editor first (which is no key view), then
  /// the window's own step back from the Name field itself (`selectKeyView(preceding:)`, what
  /// ⇧Tab's `insertBacktab(_:)` asks of the window) and what has the focus then, with the key
  /// monitor's routes for it and for Name, then ⇧Tab's action message to Name's field editor as
  /// a cross-check. The directory list is as `listOpen` says. Nothing is pressed and no menu
  /// opened: only the pop-up button's item count is read, never a title.
  private func hostPicker(from nameField: NSTextField, listOpen: Bool) async {
    let state = "host picker, list \(listOpen ? "open" : "closed")"
    await focus(nameField, state: state)
    routes(state: "\(state), focus in Name")
    window.selectPreviousKeyView(nil)
    try? await Task.sleep(for: Self.stepDelay)
    line(
      "\(state): after the window's selectPreviousKeyView with Name's field editor first: "
        + name(window.firstResponder))
    await focus(nameField, state: state)
    window.selectKeyView(preceding: nameField)
    try? await Task.sleep(for: Self.stepDelay)
    let responder = window.firstResponder
    line(
      "\(state): after the window's selectKeyView(preceding: Name): \(name(responder)); "
        + "NSPopUpButton \(yesNo(responder is NSPopUpButton)); kind "
        + "\(PanelFirstResponder(responder)); list shows \(yesNo(model.directoryPicker.isOpen))")
    if let popUp = responder as? NSPopUpButton {
      let answers = ["moveUp:", "moveDown:", "moveForward:", "moveToEndOfParagraph:"].map {
        "\($0) \(yesNo(popUp.responds(to: NSSelectorFromString($0))))"
      }
      line(
        "\(state): pop-up button: \(popUp.numberOfItems) menu items, selected item "
          + "\(popUp.indexOfSelectedItem + 1), enabled \(yesNo(popUp.isEnabled)), pulls down "
          + "\(yesNo(popUp.pullsDown)); answers " + answers.joined(separator: ", "))
    }
    routes(state: "\(state), focus after selectKeyView(preceding: Name)")
    await focus(nameField, state: state)
    _ = press(forward: false)
    try? await Task.sleep(for: Self.stepDelay)
    line(
      "\(state): after ⇧Tab's insertBacktab from Name: \(name(window.firstResponder)); list "
        + "shows \(yesNo(model.directoryPicker.isOpen))")
  } // End of func hostPicker(from:listOpen:)

  /// The keys whose routes the Host picker section prints (PLAN.md Phase I-8), as a key-down
  /// event would carry them (the arrows with their own `numericPad` and `function` flags);
  /// values only, no event is made.
  static let routedKeys:
    [(label: String, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String)] = [
      ("↑", 126, [.numericPad, .function], "\u{F700}"),
      ("↓", 125, [.numericPad, .function], "\u{F701}"),
      ("⌥↓", 125, [.option, .numericPad, .function], "\u{F701}"),
      ("Space", 49, [], " "),
      ("Return", 36, [], "\r"),
      ("Esc", 53, [], "\u{1B}"),
    ]

  /// Where the panel's key monitor would send each of `routedKeys` with the window's first
  /// responder, menu tracking state, marked text and directory list as they are now.
  private func routes(state: String) {
    let responder = window.firstResponder
    let kind = PanelFirstResponder(responder)
    let marked = (responder as? NSTextView)?.hasMarkedText() ?? false
    let tracking = MenuTrackingObserver.shared.isTracking
    let listOpen = model.directoryPicker.isOpen
    let routes = Self.routedKeys.map { probe in
      let key = PopoverKey(
        keyCode: probe.keyCode, modifierFlags: probe.flags,
        charactersIgnoringModifiers: probe.characters)
      let route = PanelKeyRoute.decide(
        key, firstResponder: kind, menuTracking: tracking, hasMarkedText: marked,
        directoryListOpen: listOpen)
      return "\(probe.label) → \(Self.describe(route))"
    }
    line(
      "\(state) (kind \(kind), menu tracking \(yesNo(tracking)), marked text "
        + "\(yesNo(marked)), list open \(yesNo(listOpen))): " + routes.joined(separator: "; "))
  } // End of func routes(state:)

  /// A route in words.
  static func describe(_ route: PanelKeyRoute) -> String {
    switch route {
    case .menu: return "the open menu"
    case .inputMethod: return "the input method"
    case .focusedView: return "the focused view"
    case .directoryList(let key): return "the directory list's \(key)"
    case .model(let key): return "the panel's \(key)"
    }
  }

  /// The `nextValidKeyView` and `previousValidKeyView` chains from `nameField`.
  private func chains(from nameField: NSTextField, state: String) {
    line("\(state): nextValidKeyView from Name: " + chain(from: nameField, forward: true))
    line("\(state): previousValidKeyView from Name: " + chain(from: nameField, forward: false))
  }

  /// `view`'s top left corner in the panel, in points from the panel's top left.
  private func position(of view: NSView) -> String {
    let frame = view.convert(view.bounds, to: nil)
    let height = window.contentView?.bounds.height ?? 0
    return "(\(Int(frame.minX.rounded())), \(Int((height - frame.maxY).rounded())))"
  }

  /// What Tab (`forward`) or ⇧Tab does now, without its event: the key binding's action
  /// message to a field editor, else the window's own key view step. Returns which.
  private func press(forward: Bool) -> String {
    if let editor = window.firstResponder as? NSTextView, editor.isFieldEditor {
      editor.doCommand(
        by: forward
          ? #selector(NSResponder.insertTab(_:)) : #selector(NSResponder.insertBacktab(_:)))
      return forward ? "insertTab" : "insertBacktab"
    }
    if forward { window.selectNextKeyView(nil) } else { window.selectPreviousKeyView(nil) }
    return forward ? "selectNextKeyView" : "selectPreviousKeyView"
  }

  /// Puts the focus in `nameField` (as a click in the field does) and says where it is.
  private func focus(_ nameField: NSTextField, state: String) async {
    if !isEditing(nameField) { window.makeFirstResponder(nameField) }
    try? await Task.sleep(for: Self.stepDelay)
    line("\(state): focus in Name: \(name(window.firstResponder))")
  }

  /// Shows the panel, key, at `frame()`.
  private func show() {
    surface.show(at: frame())
  }

  /// The content's size in the middle of the main display.
  private func frame() -> CGRect {
    let size = surface.contentSize
    let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1_440, height: 900)
    return CGRect(
      x: (screen.midX - size.width / 2).rounded(), y: (screen.midY - size.height / 2).rounded(),
      width: size.width, height: size.height)
  }

  /// Whether `field` is being edited (the first responder is its field editor, or itself).
  private func isEditing(_ field: NSTextField) -> Bool {
    if window.firstResponder === field { return true }
    guard let editor = window.firstResponder as? NSTextView, editor.isFieldEditor else {
      return false
    }
    return editor.delegate === field
  }

  /// The panel's text field whose placeholder is `prompt`.
  private func textField(prompt: String) -> NSTextField? {
    Self.subviews(of: window.contentView).lazy.compactMap { $0 as? NSTextField }
      .first { $0.placeholderString == prompt }
  }

  /// The panel's views that take the focus or could (controls and views that accept the
  /// first responder), in view tree order.
  private func keyViews() -> [NSView] {
    Self.subviews(of: window.contentView).filter {
      $0 is NSControl || $0.acceptsFirstResponder || $0.canBecomeKeyView
    }
  }

  /// The `nextValidKeyView` (or `previousValidKeyView`) chain from `start`, up to
  /// `maximumSteps` links, marking where it comes back round.
  private func chain(from start: NSView, forward: Bool) -> String {
    var names = [name(start)]
    var seen: [ObjectIdentifier] = [ObjectIdentifier(start)]
    var current: NSView = start
    for _ in 0..<Self.maximumSteps {
      guard let next = forward ? current.nextValidKeyView : current.previousValidKeyView else {
        names.append("none")
        break
      }
      if seen.contains(ObjectIdentifier(next)) {
        names.append("back to \(name(next))")
        break
      }
      names.append(name(next))
      seen.append(ObjectIdentifier(next))
      current = next
    } // End of loop over the chain's links
    return names.joined(separator: " → ")
  } // End of func chain(from:forward:)

  /// Every view under `root` (itself included), depth first, in subview order.
  static func subviews(of root: NSView?) -> [NSView] {
    guard let root else { return [] }
    return [root] + root.subviews.flatMap { subviews(of: $0) }
  }

  /// `responder`'s name (`describe(_:)`), with its number in the last listing of key views.
  private func name(_ responder: NSResponder?) -> String {
    if let editor = responder as? NSTextView, editor.isFieldEditor {
      return "field editor of " + name(editor.delegate as? NSResponder)
    }
    guard let responder, let number = numbered[ObjectIdentifier(responder)] else {
      return Self.describe(responder)
    }
    return "#\(number) " + Self.describe(responder)
  }

  /// A responder's name: a field editor by its text field, a text field by its placeholder, a
  /// button by its title or accessibility label and its key equivalent (Return, Esc), anything
  /// else by its class and role.
  static func describe(_ responder: NSResponder?) -> String {
    guard let responder else { return "none" }
    if let editor = responder as? NSTextView, editor.isFieldEditor {
      return "field editor of " + describe(editor.delegate as? NSResponder)
    }
    let kind = String(describing: type(of: responder))
    switch responder {
    case let field as NSTextField:
      return "\(kind) text field “\(field.placeholderString ?? "")”"
    case is NSPopUpButton:
      return "\(kind) pop-up button"
    case let button as NSButton:
      let title = button.title.isEmpty ? (button.accessibilityLabel() ?? "") : button.title
      let keys = ["\r": " (Return)", "\u{1b}": " (Esc)"]
      return "\(kind) button “\(title)”" + (keys[button.keyEquivalent] ?? "")
    case let view as NSView:
      let role = view.accessibilityRole()?.rawValue ?? "no role"
      return "\(kind) (\(role))"
    case is NSWindow:
      return "the panel window"
    default:
      return kind
    }
  } // End of static func describe(_:)

  /// Writes `text` as one report line.
  private func line(_ text: String) {
    write("muxFinder key view loop: \(text)")
  }

  /// "yes" or "no".
  private func yesNo(_ value: Bool) -> String {
    value ? "yes" : "no"
  }
}
