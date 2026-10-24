import AppKit
import SwiftUI

/// Connects the real popover to its window (PLAN.md D22): it tells the model when the
/// menu bar extra's window becomes visible or hidden, and hands the popover's keys
/// (`PopoverKey`) to the model before the focused view (the search field) sees them.
struct PopoverWindowBridge: NSViewRepresentable {
  /// The model told about visibility and keys.
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

/// An invisible view that follows the window it is in.
///
/// - **Visibility:** the popover counts as open while its window is visible and not fully
///   occluded. It is checked when the window becomes or stops being key, when its occlusion
///   changes and (as closed) when it closes; the model ignores repeats.
/// - **Keys:** a local key-down monitor sees the popover window's key events first. A key the
///   model handles goes no further, so ↑/↓ and Return work while the search field has the
///   focus; anything else reaches the focused view. While an input method is composing text,
///   every key goes to the text field.
final class PopoverWindowTrackingView: NSView {
  /// The model told about visibility and keys.
  private let model: AppModel
  /// The window followed.
  private weak var trackedWindow: NSWindow?
  /// The window notification observers.
  private var observers: [any NSObjectProtocol] = []
  /// The key-down monitor.
  private var keyMonitor: Any?

  /// Creates the view for `model`.
  init(model: AppModel) {
    self.model = model
    super.init(frame: .zero)
  }

  /// Not used: the view is only created in code.
  required init?(coder: NSCoder) {
    return nil
  }

  /// Follows the new window, or reports the popover closed when the view left its window.
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window !== trackedWindow else { return }
    stopTracking()
    guard let window else {
      model.popoverVisibilityChanged(false)
      return
    }
    track(window)
  }

  /// Observes `window` and installs the key monitor.
  private func track(_ window: NSWindow) {
    trackedWindow = window
    let center = NotificationCenter.default
    let names = [
      NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
      NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
    ]
    for name in names {
      let observer = center.addObserver(forName: name, object: window, queue: .main) {
        [weak self] notification in
        let isClosing = notification.name == NSWindow.willCloseNotification
        MainActor.assumeIsolated { self?.windowChanged(isClosing: isClosing) }
      }
      observers.append(observer)
    } // End of loop over the window notifications
    keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
      let press = KeyPress(event)
      let used = MainActor.assumeIsolated { self?.handle(press) ?? false }
      return used ? nil : event
    }
    updateVisibility()
  } // End of func track(_:)

  /// Removes the observers and the key monitor.
  func stopTracking() {
    for observer in observers { NotificationCenter.default.removeObserver(observer) }
    observers = []
    if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
    keyMonitor = nil
    trackedWindow = nil
  }

  /// A window notification arrived: closing means hidden; anything else is checked now and,
  /// since the panel may be ordered out just after it resigns key, once more on the next turn
  /// of the main loop.
  private func windowChanged(isClosing: Bool) {
    if isClosing {
      model.popoverVisibilityChanged(false)
      return
    }
    updateVisibility()
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated { self?.updateVisibility() }
    }
  } // End of func windowChanged(isClosing:)

  /// Tells the model whether the window is on screen.
  private func updateVisibility() {
    guard let window = trackedWindow else { return }
    model.popoverVisibilityChanged(window.isVisible && window.occlusionState.contains(.visible))
  }

  /// Hands a key press in the popover window to the model; returns whether it was used.
  private func handle(_ press: KeyPress) -> Bool {
    guard let window = trackedWindow, press.windowNumber == window.windowNumber,
      window.isKeyWindow
    else { return false }
    if let editor = window.firstResponder as? NSTextView, editor.hasMarkedText() { return false }
    guard
      let key = PopoverKey(
        keyCode: press.keyCode, modifierFlags: press.modifierFlags,
        charactersIgnoringModifiers: press.characters)
    else { return false }
    switch model.handle(key) {
    case .handled:
      return true
    case .closePopover:
      window.close()
      return true
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
