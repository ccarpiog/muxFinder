import AppKit

/// The kind of view that has a muxFinder panel's keyboard focus, as the panels' key monitor
/// tells them apart (PLAN.md Phase I-8, D30): a pop-up button (`NSPopUpButton` or a subclass,
/// such as SwiftUI's `Picker`, New session's Host picker) or anything else (a text field's
/// editor, a button, the window itself, nothing).
public enum PanelFirstResponder: Sendable, Hashable {
  /// An `NSPopUpButton`: AppKit gives it ↑ and ↓ itself (`moveUp(_:)`, `moveDown(_:)`).
  case popUpButton
  /// Any other responder, or none.
  case other

  /// The kind of `responder` (a panel's first responder at the key press).
  public init(_ responder: NSResponder?) {
    self = responder is NSPopUpButton ? .popUpButton : .other
  }
}

/// Where a muxFinder panel's key monitor (`PanelKeyTrackingView`, the popover's and the session
/// switcher's) sends a key press: a pure decision (`decide(_:firstResponder:menuTracking:
/// hasMarkedText:directoryListOpen:)`) over the key, the kind of the panel's first responder,
/// whether a menu of the app is tracking, whether an input method is composing text and
/// whether New session's directory list is open (PLAN.md Phase I-8, D30, D31, D32).
public enum PanelKeyRoute: Sendable, Hashable {
  /// A menu of the app is tracking (open): the key goes on untouched, so the menu keeps its own
  /// ↑/↓, Return, Space, Esc and type-to-select (Esc closes only the menu).
  case menu
  /// An input method is composing text (marked text): the key goes on to it.
  case inputMethod
  /// The key goes on to the focused view: no panel key (Space, Tab, letters), or ↑, ↓ or ⌥↓
  /// while a pop-up button has the focus, which AppKit handles itself.
  case focusedView
  /// New session's open directory list's key: the panel's handler gets it and
  /// `AppModel.handleDirectoryListKey(_:)` takes it first (↑/↓/⌥↓ move the highlight, Return
  /// picks it or creates, Esc closes the list).
  case directoryList(PopoverKey)
  /// The panel's key: its handler gets it (`AppModel.handle(_:)` in the popover,
  /// `handleSwitcherKey(_:)` in the switcher), which may still leave it to the focused view
  /// (`PopoverKeyResult.ignored`).
  case model(PopoverKey)

  /// The keys a focused pop-up button keeps: ↑ and ↓ (AppKit's standard key bindings send it
  /// `moveUp(_:)` and `moveDown(_:)`, which `NSPopUpButton` implements) and ⌥↓.
  public static let popUpButtonKeys: Set<PopoverKey> = [.up, .down, .openList]

  /// The keys New session's open directory list takes (`AppModel.handleDirectoryListKey(_:)`
  /// answers them and leaves the rest, ⌘F, ⌘R, ⌘N and ⌘,, to the panel).
  public static let directoryListKeys: Set<PopoverKey> = [.up, .down, .openList, .open, .close]

  /// The key the panel's handler gets, or `nil` when the key goes on untouched.
  public var handlerKey: PopoverKey? {
    switch self {
    case .directoryList(let key), .model(let key): return key
    case .menu, .inputMethod, .focusedView: return nil
    }
  }

  /// Where a key press goes. `key` is the panel's command for it (`nil` when it has none, such
  /// as Space). In order: while a menu is tracking, every key goes on to it; while an input
  /// method composes text, every key goes on to it (as before Phase I-8); a key with no command
  /// goes on to the focused view; with a pop-up button focused, ↑, ↓ and ⌥↓ go on to it, so
  /// the directory list, open or not, never sees them (its highlight stays) while Return and Esc
  /// keep their meaning; with the directory list open, its keys are its own (through the
  /// handler); every other key is the panel's handler's, as before.
  public static func decide(
    _ key: PopoverKey?,
    firstResponder: PanelFirstResponder,
    menuTracking: Bool,
    hasMarkedText: Bool,
    directoryListOpen: Bool
  ) -> PanelKeyRoute {
    if menuTracking { return .menu }
    if hasMarkedText { return .inputMethod }
    guard let key else { return .focusedView }
    if firstResponder == .popUpButton, popUpButtonKeys.contains(key) { return .focusedView }
    if directoryListOpen, directoryListKeys.contains(key) { return .directoryList(key) }
    return .model(key)
  } // End of static func decide(_:firstResponder:menuTracking:hasMarkedText:directoryListOpen:)
}

/// Whether a menu of the app is tracking (open), from `NSMenu.didBeginTrackingNotification` to
/// `didEndTrackingNotification` (PLAN.md Phase I-8): while one is, the panels' key monitor
/// passes every key through (`PanelKeyRoute.menu`), so an open menu, such as New session's
/// host menu, keeps its own keys. AppKit documents that a local event monitor is not called for
/// events a menu's own tracking loop consumes (`NSEvent.h`), so this is a second guard, for any
/// key that still reaches `NSApplication.sendEvent(_:)` while a menu is open.
@MainActor
final class MenuTrackingObserver {
  /// The app's observer, which every panel's key monitor reads.
  static let shared = MenuTrackingObserver(center: .default)

  /// The menus tracking now, by identity (a notification with no object counts as one menu).
  private var trackingMenus: Set<ObjectIdentifier> = []
  /// The notification observers, removed when the observer goes (set once, in `init`).
  nonisolated(unsafe) private var tokens: [any NSObjectProtocol] = []
  /// The center observed.
  private nonisolated let center: NotificationCenter

  /// Whether a menu is tracking now.
  var isTracking: Bool { !trackingMenus.isEmpty }

  /// Observes `center` (the default center in the app; tests post on a private one).
  init(center: NotificationCenter) {
    self.center = center
    let began = center.addObserver(
      forName: NSMenu.didBeginTrackingNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let menu = Self.identity(of: notification.object)
      MainActor.assumeIsolated { self?.began(menu) }
    }
    let ended = center.addObserver(
      forName: NSMenu.didEndTrackingNotification, object: nil, queue: .main
    ) { [weak self] notification in
      let menu = Self.identity(of: notification.object)
      MainActor.assumeIsolated { self?.ended(menu) }
    }
    tokens = [began, ended]
  } // End of init(center:)

  /// Stops observing.
  deinit {
    for token in tokens { center.removeObserver(token) }
  }

  /// A menu began tracking.
  private func began(_ menu: ObjectIdentifier) {
    trackingMenus.insert(menu)
  }

  /// A menu ended tracking. An end for a menu whose beginning was never seen forgets every
  /// menu, so an unbalanced notification can never leave the panels' keys passing through.
  private func ended(_ menu: ObjectIdentifier) {
    if trackingMenus.remove(menu) == nil { trackingMenus.removeAll() }
  }

  /// A notification's menu, by identity (one fixed identity for a notification without one).
  nonisolated private static func identity(of object: Any?) -> ObjectIdentifier {
    guard let object else { return ObjectIdentifier(MenuTrackingObserver.self) }
    return ObjectIdentifier(object as AnyObject)
  }
}
