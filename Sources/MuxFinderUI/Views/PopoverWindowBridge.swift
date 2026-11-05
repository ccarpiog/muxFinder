import AppKit
import SwiftUI

/// Connects the real popover to its window (PLAN.md D22, D30): it hands the popover's keys
/// (`PopoverKey`) to the model before the focused view (the search field) sees them, as
/// `PanelKeyRoute` decides (PLAN.md Phase I-8). Whether
/// the popover shows is `PopoverController`'s to report, since it opens and closes the panel.
struct PopoverWindowBridge: NSViewRepresentable {
  /// The model told about keys.
  let model: AppModel

  /// Creates the tracking view.
  func makeNSView(context: Context) -> PopoverWindowTrackingView {
    PopoverWindowTrackingView(model: model)
  }

  /// Nothing to update: the view follows its window by itself.
  func updateNSView(_ nsView: PopoverWindowTrackingView, context: Context) {}

  /// Stops tracking when SwiftUI removes the view.
  static func dismantleNSView(_ nsView: PopoverWindowTrackingView, coordinator: ()) {
    nsView.stopTracking()
  }
}

/// The popover's window tracking view: its keys go to `AppModel.handle(_:)`. The popover
/// placement diagnostic finds the live popover by this class (`LivePopoverLookup`).
final class PopoverWindowTrackingView: PanelKeyTrackingView {
  /// Creates the view for `model`.
  init(model: AppModel) {
    super.init(
      route: { [weak model] key in model?.handle(key) ?? .ignored },
      isDirectoryListOpen: { [weak model] in model?.directoryPicker.isOpen ?? false })
  }

  /// Not used: the view is only created in code.
  required init?(coder: NSCoder) {
    return nil
  }
}

/// An invisible view that follows the window it is in (a muxFinder panel: the popover's, or
/// the session switcher's, PLAN.md D32) for its keys.
///
/// A local key-down monitor sees the window's key events first. Where each goes is
/// `PanelKeyRoute.decide(_:firstResponder:menuTracking:hasMarkedText:directoryListOpen:)`
/// (PLAN.md Phase I-8), over the window's first responder at that moment: a key the handler
/// uses goes no further, so ↑/↓ and Return work while the search field has the focus; anything
/// else reaches the focused view. While a menu of the app is tracking (`MenuTrackingObserver`)
/// or an input method is composing text (marked text), every key goes on untouched; while a
/// pop-up button has the focus (New session's Host picker), ↑, ↓ and ⌥↓ go on to it. Esc
/// (`PopoverKeyResult.closePopover`) closes the window, which the panel turns into its
/// controller's close.
class PanelKeyTrackingView: NSView {
  /// Carries out a key and says what the window does next.
  private let route: @MainActor (PopoverKey) -> PopoverKeyResult
  /// Whether New session's directory list is open (the route's input; the handler asks the
  /// list itself).
  private let isDirectoryListOpen: @MainActor () -> Bool
  /// Whether a menu of the app is tracking.
  private let menuTracking: MenuTrackingObserver
  /// The window followed.
  private weak var trackedWindow: NSWindow?
  /// The key-down monitor.
  private var keyMonitor: Any?

  /// Creates the view; its window's keys go to `route`, `isDirectoryListOpen` says whether the
  /// directory list is open, and `menuTracking` whether a menu is tracking.
  init(
    route: @escaping @MainActor (PopoverKey) -> PopoverKeyResult,
    isDirectoryListOpen: @escaping @MainActor () -> Bool,
    menuTracking: MenuTrackingObserver = .shared
  ) {
    self.route = route
    self.isDirectoryListOpen = isDirectoryListOpen
    self.menuTracking = menuTracking
    super.init(frame: .zero)
  }

  /// Not used: the view is only created in code.
  required init?(coder: NSCoder) {
    return nil
  }

  /// Follows the new window, or stops when the view left its window.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window !== trackedWindow else { return }
    stopTracking()
    guard let window else { return }
    track(window)
  }

  /// Installs the key monitor for `window`.
  private func track(_ window: NSWindow) {
    trackedWindow = window
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let press = KeyPress(event)
      let used = MainActor.assumeIsolated { self?.handle(press) ?? false }
      return used ? nil : event
    }
  }

  /// Removes the key monitor.
  func stopTracking() {
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    trackedWindow = nil
  }

  /// Hands a key press in the followed window to the handler when its route says so
  /// (`PanelKeyRoute`, over the window's first responder now); returns whether it was used.
  private func handle(_ press: KeyPress) -> Bool {
    guard let window = trackedWindow, press.windowNumber == window.windowNumber,
      window.isKeyWindow
    else { return false }
    let responder = window.firstResponder
    let decision = PanelKeyRoute.decide(
      PopoverKey(
        keyCode: press.keyCode, modifierFlags: press.modifierFlags,
        charactersIgnoringModifiers: press.characters),
      firstResponder: PanelFirstResponder(responder),
      menuTracking: menuTracking.isTracking,
      hasMarkedText: (responder as? NSTextView)?.hasMarkedText() ?? false,
      directoryListOpen: isDirectoryListOpen())
    guard let key = decision.handlerKey else { return false }
    switch route(key) {
    case .handled:
      return true
    case .closePopover:
      window.close()
      return true
    case .ignored:
      return false
    }
  } // End of func handle(_:)
}

/// Finds the live popover in a view tree: the popover placement diagnostic's positive
/// identification of the popover window (`PopoverWindowIdentification`, PLAN.md Phase I-1).
public enum LivePopoverLookup {
  /// Whether `view` or any view under it is a live `PopoverView`'s window tracking view, so the
  /// window holding `view` holds the live popover. Read-only.
  @MainActor
  public static func holdsLivePopover(_ view: NSView?) -> Bool {
    guard let view else { return false }
    return view is PopoverWindowTrackingView || view.subviews.contains { holdsLivePopover($0) }
  }
}

/// The parts of a key-down event the popover reads (`NSEvent` itself is not `Sendable`).
struct KeyPress: Sendable {
  /// The event's window number.
  let windowNumber: Int
  /// The virtual key code.
  let keyCode: UInt16
  /// The modifier keys held.
  let modifierFlags: NSEvent.ModifierFlags
  /// The characters without modifiers.
  let characters: String?

  /// The parts of `event`.
  init(_ event: NSEvent) {
    windowNumber = event.windowNumber
    keyCode = event.keyCode
    modifierFlags = event.modifierFlags
    characters = event.charactersIgnoringModifiers
  }
}
