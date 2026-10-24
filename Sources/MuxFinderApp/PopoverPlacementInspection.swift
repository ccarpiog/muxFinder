import AppKit
import CoreGraphics
import Foundation
import MuxFinderUI
import SwiftUI

/// What `PopoverPlacementReport` reads from AppKit, read-only: the app's status-bar windows and
/// buttons, the status item, other processes' status-bar window frames, and the popover
/// content's size off screen; plus its text formatting.
extension PopoverPlacementReport {
  /// The app's status-bar-level windows.
  static func statusBarWindows() -> [NSWindow] {
    NSApp.windows.filter { $0.level == .statusBar }
  }

  /// Every status item button in the app's status-bar-level windows.
  static func statusBarButtons() -> [NSStatusBarButton] {
    statusBarWindows().flatMap { buttons(in: $0.contentView) }
  }

  /// The status item buttons in `view` and its subviews.
  static func buttons(in view: NSView?) -> [NSStatusBarButton] {
    guard let view else { return [] }
    let own = (view as? NSStatusBarButton).map { [$0] } ?? []
    return own + view.subviews.flatMap { buttons(in: $0) }
  }

  /// The status item of a status-bar window, if the window answers AppKit's `statusItem`
  /// getter (checked with `responds(to:)` first, so nothing is called that does not exist).
  static func statusItem(of window: NSWindow) -> NSStatusItem? {
    guard window.responds(to: NSSelectorFromString("statusItem")) else { return nil }
    return window.value(forKey: "statusItem") as? NSStatusItem
  }

  /// The first status item a status-bar window exposes whose button exists.
  static func reachableStatusItem() -> NSStatusItem? {
    statusBarWindows().lazy.compactMap { statusItem(of: $0) }.first { $0.button != nil }
  }

  /// The button to click when no status item is reachable: the first one in a visible window
  /// on the main display, else the first in a visible window, else the first.
  static func preferredButton(_ buttons: [NSStatusBarButton]) -> NSStatusBarButton? {
    buttons.first { $0.window?.isVisible == true && $0.window?.screen == NSScreen.main }
      ?? buttons.first { $0.window?.isVisible == true } ?? buttons.first
  }

  /// The views under `view`, depth first, at most `maximumDepth` levels: each one's class and
  /// frame, indented by depth.
  static func viewTree(_ view: NSView?, depth: Int = 0, maximumDepth: Int = 4) -> [String] {
    guard let view, depth <= maximumDepth else { return [] }
    let own =
      String(repeating: "  ", count: depth) + "\(className(view)) \(NSStringFromRect(view.frame))"
    return [own]
      + view.subviews.flatMap { viewTree($0, depth: depth + 1, maximumDepth: maximumDepth) }
  }

  /// The key paths observed on `object` through key-value observing, read from its
  /// `observationInfo` description (key paths only; observers are not named).
  static func observedKeyPaths(_ object: NSObject) -> [String] {
    guard let info = object.observationInfo else { return [] }
    let text = String(describing: Unmanaged<AnyObject>.fromOpaque(info).takeUnretainedValue())
    return text.components(separatedBy: "Key path: ").dropFirst().compactMap { part in
      part.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ">" }).first.map(String.init)
    }
  }

  /// The frames, in AppKit's screen coordinates, of the on-screen windows of other processes
  /// at the status-bar layer (`kCGStatusWindowLevel`, 25). Window names and owners are not
  /// read.
  static func otherProcessesStatusBarFrames() -> [CGRect] {
    guard
      let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID)
        as? [[String: Any]],
      let primaryHeight = NSScreen.screens.first?.frame.height
    else { return [] }
    let ownPID = Int(getpid())
    return list.compactMap { info in
      guard (info[kCGWindowLayer as String] as? Int) == Int(CGWindowLevelForKey(.statusWindow)),
        (info[kCGWindowOwnerPID as String] as? Int) != ownPID,
        let bounds = info[kCGWindowBounds as String] as? NSDictionary,
        let rect = CGRect(dictionaryRepresentation: bounds), rect.width > 0
      else { return nil }
      return CGRect(
        x: rect.minX, y: primaryHeight - rect.maxY, width: rect.width, height: rect.height)
    }
  } // End of static func otherProcessesStatusBarFrames()

  /// The popover content's natural size for `model`: `PopoverView` (not live: no window
  /// tracking) in an `NSHostingView` that is never put in a window.
  static func offScreenContentSize(_ model: AppModel) -> CGSize {
    let host = NSHostingView(rootView: PopoverView(model: model, isLive: false))
    host.layoutSubtreeIfNeeded()
    return host.fittingSize
  }

  /// The CoreGraphics display id of `screen`.
  static func displayID(_ screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
  }

  /// The index of `screen` in `screens`, matched by display id.
  static func index(of screen: NSScreen, in screens: [NSScreen]) -> Int? {
    guard let id = displayID(screen) else { return nil }
    return screens.firstIndex { displayID($0) == id }
  }

  /// An optional index as text.
  static func text(_ index: Int?) -> String {
    index.map(String.init) ?? "none"
  }

  /// A number in points: whole numbers without decimals, others with two.
  static func number(_ value: CGFloat) -> String {
    guard value.isFinite else { return "\(value)" }
    return value == value.rounded() ? String(Int(value)) : String(format: "%.2f", Double(value))
  }

  /// A duration in whole milliseconds.
  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }

  /// The Objective-C runtime class name of `object`.
  static func className(_ object: AnyObject) -> String {
    String(cString: object_getClassName(object))
  }

  /// The runtime class name of `object`, then its superclasses' names, nearest first (so an
  /// `NSStatusBarWindow` subclass, such as the one key-value observing makes, still names it).
  static func classNames(_ object: AnyObject) -> [String] {
    var names: [String] = []
    var current: AnyClass? = object_getClass(object)
    while let type = current {
      names.append(String(cString: class_getName(type)))
      current = class_getSuperclass(type)
    }
    return names
  }

  /// `window` as `PopoverWindowIdentification` needs it, read-only; `visibleBefore` holds the
  /// windows that were visible right before the click.
  static func identificationWindow(_ window: NSWindow, visibleBefore: Set<ObjectIdentifier>)
    -> PopoverWindowIdentification.Window
  {
    PopoverWindowIdentification.Window(
      classNames: classNames(window),
      level: window.level.rawValue,
      isVisible: window.isVisible,
      wasVisibleBeforeClick: visibleBefore.contains(ObjectIdentifier(window)),
      holdsStatusItemButton: !buttons(in: window.contentView).isEmpty,
      holdsLivePopover: LivePopoverLookup.holdsLivePopover(window.contentView))
  } // End of static func identificationWindow(_:visibleBefore:)
}
