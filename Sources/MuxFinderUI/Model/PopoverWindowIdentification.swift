import Foundation

/// Which of the app's windows is the popover, for the popover placement diagnostic
/// (`--report-popover-placement`, PLAN.md Phase I-1). A pure decision over `Window` values, so
/// tests describe windows without AppKit; the diagnostic uses it both to find the popover and
/// to choose what to close on its way out.
///
/// - **Never a status-bar window.** A window whose class is `NSStatusBarWindow` (or a subclass,
///   such as the one key-value observing makes), or that holds a status item button, is never
///   the popover: neither the real item's window nor the replicas AppKit keeps for the other
///   menu bars, which hold no button (PLAN.md *Verified facts*, Phase I-1a).
/// - **Positive identification first.** The window holding the live `PopoverView` (its
///   `PopoverWindowTrackingView`, `LivePopoverLookup`) is the popover at any level, since the
///   window muxFinder opens for it may sit at or above the status-bar level.
/// - **Fallback.** Otherwise the first newly visible window below the status-bar level.
///
/// In both cases the window must be visible now and must not have been visible right before
/// the click.
public enum PopoverWindowIdentification {
  /// AppKit's status-bar window level (`NSWindow.Level.statusBar`, `kCGStatusWindowLevel`).
  public static let statusBarLevel = 25
  /// The class of AppKit's status item windows: the real item's and the replicas'.
  public static let statusBarWindowClassName = "NSStatusBarWindow"

  /// One of the app's windows, as the identification needs it.
  public struct Window: Sendable, Hashable {
    /// The window's runtime class name, then its superclasses' names, nearest first.
    public var classNames: [String]
    /// Its level (`NSWindow.level.rawValue`).
    public var level: Int
    /// Whether it is visible now.
    public var isVisible: Bool
    /// Whether it was visible right before the click.
    public var wasVisibleBeforeClick: Bool
    /// Whether its content holds a status item button (`NSStatusBarButton`).
    public var holdsStatusItemButton: Bool
    /// Whether its content holds the live `PopoverView` (`LivePopoverLookup`).
    public var holdsLivePopover: Bool

    /// Describes a window from its parts.
    public init(
      classNames: [String],
      level: Int,
      isVisible: Bool,
      wasVisibleBeforeClick: Bool,
      holdsStatusItemButton: Bool,
      holdsLivePopover: Bool
    ) {
      self.classNames = classNames
      self.level = level
      self.isVisible = isVisible
      self.wasVisibleBeforeClick = wasVisibleBeforeClick
      self.holdsStatusItemButton = holdsStatusItemButton
      self.holdsLivePopover = holdsLivePopover
    } // End of the Window initializer
  } // End of struct Window

  /// How the popover window was recognized.
  public enum Match: Sendable, Hashable {
    /// It holds the live `PopoverView`.
    case livePopover
    /// It is newly visible below the status-bar level and holds no live popover (the
    /// fallback).
    case newlyVisible
  }

  /// Whether `window` is a status-bar window: an `NSStatusBarWindow` (or a subclass), or one
  /// holding a status item button.
  public static func isStatusBarWindow(_ window: Window) -> Bool {
    window.classNames.contains(statusBarWindowClassName) || window.holdsStatusItemButton
  }

  /// How `window` counts as the popover, or `nil` when it cannot be the popover: hidden,
  /// visible before the click, a status-bar window, or at or above the status-bar level
  /// without the live popover.
  public static func match(_ window: Window) -> Match? {
    guard window.isVisible, !window.wasVisibleBeforeClick, !isStatusBarWindow(window) else {
      return nil
    }
    if window.holdsLivePopover { return .livePopover }
    return window.level < statusBarLevel ? .newlyVisible : nil
  }

  /// The popover among `windows`: the first holding the live popover, else the first matched
  /// by the fallback; `nil` when none can be the popover.
  public static func popover(in windows: [Window]) -> (index: Int, match: Match)? {
    let matches = windows.enumerated().compactMap { entry in
      match(entry.element).map { (index: entry.offset, match: $0) }
    }
    return matches.first { $0.match == .livePopover } ?? matches.first
  }
}
