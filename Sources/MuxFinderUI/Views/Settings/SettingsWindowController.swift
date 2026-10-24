import AppKit
import SwiftUI

/// The Settings window (PLAN.md D23): one window, made on first use and reused. `show(_:)`
/// brings it to the front, activating muxFinder (an accessory app, so it has no Dock icon and
/// would otherwise stay behind the active app); opening a closed window tells the model, which
/// loads the host list afresh in a task it owns, and closing it tells the model too, which
/// cancels that task and the probes. The window is not restored at launch and its frame is not
/// saved.
@MainActor
public final class SettingsWindowController: NSObject, NSWindowDelegate {
  /// The app's controller.
  public static let shared = SettingsWindowController()

  /// The window, once made.
  private var window: SettingsWindow?
  /// The model the window shows.
  private var model: SettingsModel?

  /// Shows the window for `model`, making it if needed, and brings it to the front.
  public func show(_ model: SettingsModel) {
    let window = self.window ?? makeWindow(for: model)
    if !window.isVisible {
      window.center()
      Task { await model.windowDidOpen() }
    }
    NSApp.activate()
    window.makeKeyAndOrderFront(nil)
  }

  /// Makes the window over `model`.
  private func makeWindow(for model: SettingsModel) -> SettingsWindow {
    let hosting = NSHostingView(rootView: SettingsView(model: model))
    let window = SettingsWindow(
      contentRect: NSRect(origin: .zero, size: SettingsView.defaultSize),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false)
    window.title = "muxFinder settings"
    window.contentView = hosting
    window.contentMinSize = SettingsView.minimumSize
    window.isReleasedWhenClosed = false
    window.isRestorable = false
    window.tabbingMode = .disallowed
    window.delegate = self
    self.window = window
    self.model = model
    return window
  } // End of func makeWindow(for:)

  /// The window closed: the model stops its checks and forgets unsaved changes.
  public func windowWillClose(_ notification: Notification) {
    model?.windowDidClose()
  }

  /// The window came forward: launch at login may have changed in System Settings meanwhile.
  public func windowDidBecomeKey(_ notification: Notification) {
    model?.refreshLoginItemStatus()
  }

  /// The window lost the focus: the shortcut recorder stops listening (PLAN.md D32).
  public func windowDidResignKey(_ notification: Notification) {
    model?.windowDidResignKey()
  }
}

/// The Settings window. Its text fields get the standard editing keys (⌘X, ⌘C, ⌘V, ⌘A, ⌘Z,
/// ⇧⌘Z) and ⌘W closes it, whether or not the app's main menu has those items: a menu bar app
/// shows no main menu, and its key equivalents are not guaranteed.
final class SettingsWindow: NSWindow {
  /// Lets the window's views try first, then handles the editing keys and ⌘W.
  override func performKeyEquivalent(with event: NSEvent) -> Bool {
    if super.performKeyEquivalent(with: event) { return true }
    guard event.type == .keyDown else { return false }
    let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
    guard flags == .command || flags == [.command, .shift] else { return false }
    let key = event.charactersIgnoringModifiers?.lowercased() ?? ""
    if key == "w", flags == .command {
      performClose(nil)
      return true
    }
    guard let action = Self.editingAction(key: key, shift: flags.contains(.shift)) else {
      return false
    }
    return NSApp.sendAction(action, to: nil, from: self)
  } // End of func performKeyEquivalent(with:)

  /// The responder action of an editing key, if `key` (with or without ⇧) is one.
  static func editingAction(key: String, shift: Bool) -> Selector? {
    switch (key, shift) {
    case ("x", false): return #selector(NSText.cut(_:))
    case ("c", false): return #selector(NSText.copy(_:))
    case ("v", false): return #selector(NSText.paste(_:))
    case ("a", false): return #selector(NSText.selectAll(_:))
    case ("z", false): return Selector(("undo:"))
    case ("z", true): return Selector(("redo:"))
    default: return nil
    }
  } // End of static func editingAction(key:shift:)
}
