import AppKit
import SwiftUI

/// muxFinder's session switcher panel (PLAN.md D32, Phase I-3b): a borderless, non-activating
/// `NSPanel` at the floating level hosting the live `SwitcherView`, opened and closed by
/// `SwitcherController` (the session switcher shortcut toggles it). This type is only the
/// AppKit wiring; every decision is the controller's or the model's (tested over fakes).
///
/// - **Panel:** the popover's panel window (`PopoverPanelWindow`) at the floating level: on
///   every Space and over full-screen apps, key without activating the app, so the frontmost
///   app keeps its menu bar and gets the focus back when the switcher closes; rounded and
///   opaque (Phase 14's palette); its accessibility title "Session switcher".
/// - **Closing from outside:** Esc (through the key monitor of `SwitcherWindowBridge`), a mouse
///   press another process receives, another app becoming active (iTerm2 coming forward), the
///   panel resigning key and the displays changing (`PanelObservers`).
/// - **Size:** the hosted view lays itself out no taller than the controller's limit and
///   reports changes of its natural size, and the controller places the panel again.
///
/// Created only by the menu bar app in normal mode with the session switcher shortcut
/// (`AppLaunchOptions.registersGlobalShortcut`); never in a preview, a self-test or a
/// `--report-*` mode.
@MainActor
public final class SessionSwitcher {
  /// Opens and closes the panel.
  public let controller: SwitcherController
  /// The panel's wiring.
  private let host: PanelHost<SwitcherPanelRoot>
  /// The panel's notification observers.
  private var observers: PanelObservers?

  /// The switcher's panel.
  public var panel: NSPanel { host.panel }

  /// Builds the panel over `model` and connects it (`SwitcherController.make`); nothing shows
  /// until the shortcut is pressed.
  public init(model: AppModel) {
    let host = PanelHost<SwitcherPanelRoot>(level: .floating) { onSizeChange in
      SwitcherPanelRoot(model: model, onSizeChange: onSizeChange)
    }
    host.panel.title = SwitcherView.accessibilityTitle
    host.panel.setAccessibilityTitle(SwitcherView.accessibilityTitle)
    let controller = SwitcherController.make(for: model, panel: host, system: .appKit)
    self.host = host
    self.controller = controller
    host.panel.closeRequest = { [weak controller] in controller?.close(.escape) }
    host.onPressOutside = { [weak controller] in controller?.close(.pressOutside) }
    host.onContentSizeChange = { [weak controller] in controller?.contentSizeChanged() }
    observers = PanelObservers(
      panel: host.panel,
      resignedKey: { [weak controller] in controller?.close(.resignedKey) },
      occlusionChanged: { [weak controller] in controller?.occlusionChanged(isVisible: $0) },
      displaysChanged: { [weak controller] in controller?.close(.displaysChanged) },
      otherAppActivated: { [weak controller] in controller?.close(.appSwitch) })
  } // End of init(model:)
}

extension SwitcherSystem {
  /// AppKit's: `NSScreen.screens`, and the display with the keyboard focus from the frontmost
  /// app's frontmost window (`frontmostWindowFrame()`), `NSScreen.main` and the pointer
  /// (`SwitcherPlacement.screenIndex(focusedWindow:mainScreen:pointer:in:)`).
  public static var appKit: SwitcherSystem {
    SwitcherSystem(
      screens: { NSScreen.screens.map { PopoverPlacement.Screen($0) } },
      focusedScreenIndex: { screens in
        SwitcherPlacement.screenIndex(
          focusedWindow: frontmostWindowFrame(), mainScreen: NSScreen.main?.frame,
          pointer: NSEvent.mouseLocation, in: screens)
      })
  } // End of static var appKit

  /// The frame, in AppKit's screen coordinates, of the frontmost app's frontmost normal window
  /// on screen, or `nil`. Read-only: `CGWindowListCopyWindowInfo` gives every window's owner,
  /// layer and bounds without any permission; only those are read, never a window's title or
  /// contents, and nothing is logged.
  @MainActor
  static func frontmostWindowFrame() -> CGRect? {
    guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
      let primary = NSScreen.screens.first?.frame,
      let windows = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
    else { return nil }
    for window in windows {
      guard (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == pid,
        (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
        let bounds = window[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 0, rect.height > 0
      else { continue }
      return CGRect(
        x: rect.minX, y: primary.maxY - rect.maxY, width: rect.width, height: rect.height)
    } // End of loop over the windows on screen, front to back
    return nil
  } // End of static func frontmostWindowFrame()
}

/// The switcher panel's root view: the live `SwitcherView` at its natural size, but no taller
/// than `maximumHeight` (`PopoverHeightLimit`; its list shrinks and scrolls), reporting each
/// change of that size.
struct SwitcherPanelRoot: PanelRootView {
  /// The switcher's model.
  let model: AppModel
  /// The tallest the switcher lays itself out, in points (`nil`: no limit); the controller sets
  /// the room below its top edge.
  var maximumHeight: CGFloat?
  /// Called when the switcher's natural size changed.
  let onSizeChange: @MainActor () -> Void

  /// The switcher, at its natural size within the limit.
  var body: some View {
    PopoverHeightLimit(maximumHeight: maximumHeight) {
      SwitcherView(model: model, isLive: true)
    }
    .onGeometryChange(for: CGSize.self) { geometry in
      geometry.size
    } action: { _ in
      onSizeChange()
    }
  }
}

/// Connects the real switcher to its window: its keys (`PopoverKey`) go to
/// `AppModel.handleSwitcherKey(_:)` before the focused view (the search field) sees them, as
/// the popover's do (`PanelKeyTrackingView`). Whether the switcher shows is
/// `SwitcherController`'s to report.
struct SwitcherWindowBridge: NSViewRepresentable {
  /// The model told about keys.
  let model: AppModel

  /// Creates the tracking view.
  func makeNSView(context: Context) -> SwitcherWindowTrackingView {
    SwitcherWindowTrackingView(model: model)
  }

  /// Nothing to update: the view follows its window by itself.
  func updateNSView(_ nsView: SwitcherWindowTrackingView, context: Context) {}

  /// Stops tracking when SwiftUI removes the view.
  static func dismantleNSView(_ nsView: SwitcherWindowTrackingView, coordinator: ()) {
    nsView.stopTracking()
  }
}

/// The switcher's window tracking view: its keys go to `AppModel.handleSwitcherKey(_:)`.
final class SwitcherWindowTrackingView: PanelKeyTrackingView {
  /// Creates the view for `model`.
  init(model: AppModel) {
    super.init { [weak model] key in model?.handleSwitcherKey(key) ?? .ignored }
  }

  /// Not used: the view is only created in code.
  required init?(coder: NSCoder) {
    return nil
  }
}
