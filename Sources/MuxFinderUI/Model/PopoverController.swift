import CoreGraphics
import Foundation

/// The popover panel as `PopoverController` drives it: `PopoverPanelHost` in the app, a fake in
/// tests.
@MainActor
public protocol PopoverPanelSurface: AnyObject {
  /// The tallest the content lays itself out, in points (`nil`: no limit): content taller
  /// than this shrinks its host list, which scrolls, so the search field and the footer stay
  /// in the panel (PLAN.md D30). Set before `contentSize` is read.
  var maximumContentHeight: CGFloat? { get set }
  /// The content's natural size, in points (the hosted `PopoverView`'s fitting size), no
  /// taller than `maximumContentHeight` when the content can shrink that far.
  var contentSize: CGSize { get }
  /// Puts the panel at `frame`, in front, and makes it key; starts watching for presses
  /// outside it.
  func show(at frame: CGRect)
  /// Moves or resizes the shown panel.
  func setFrame(_ frame: CGRect)
  /// Takes the panel off screen; stops watching for presses outside it.
  func hide()
}

/// muxFinder's status item button as `PopoverController` reads it: `StatusItemButton` in the
/// app, a fake in tests.
@MainActor
public protocol PopoverStatusButton: AnyObject {
  /// The button's rectangle in screen coordinates (its bounds through its window), or `nil`
  /// while it has no window.
  var screenRect: CGRect? { get }
  /// Shows the button pressed while the popover is open.
  func setHighlighted(_ isHighlighted: Bool)
}

/// What `PopoverController` reads from the system, as closures so tests pass fixed values.
public struct PopoverSystem {
  /// The displays, in `NSScreen.screens` order.
  public var screens: @MainActor () -> [PopoverPlacement.Screen]
  /// The mouse press's location when the button's action comes from a mouse event (the current
  /// event is a recent mouse press or release; `NSEvent.mouseLocation`), else `nil`.
  public var pressLocation: @MainActor () -> CGPoint?
  /// The pointer's location now.
  public var pointerLocation: @MainActor () -> CGPoint
  /// The pointer's location while a mouse button is held, else `nil`.
  public var heldPointerLocation: @MainActor () -> CGPoint?
  /// How many mouse presses the system has seen: the same for every effect of one press (its
  /// button action, a close from outside), higher once another press began, so two quick
  /// presses close together are still told apart (`PopoverPressRules`).
  public var pressCount: @MainActor () -> UInt64
  /// The system uptime, in seconds (`ProcessInfo.systemUptime`).
  public var uptime: @MainActor () -> TimeInterval

  /// A system from its parts.
  public init(
    screens: @escaping @MainActor () -> [PopoverPlacement.Screen],
    pressLocation: @escaping @MainActor () -> CGPoint?,
    pointerLocation: @escaping @MainActor () -> CGPoint,
    heldPointerLocation: @escaping @MainActor () -> CGPoint?,
    pressCount: @escaping @MainActor () -> UInt64,
    uptime: @escaping @MainActor () -> TimeInterval
  ) {
    self.screens = screens
    self.pressLocation = pressLocation
    self.pointerLocation = pointerLocation
    self.heldPointerLocation = heldPointerLocation
    self.pressCount = pressCount
    self.uptime = uptime
  } // End of init(screens:pressLocation:pointerLocation:heldPointerLocation:pressCount:uptime:)
}

/// Opens, moves and closes muxFinder's popover panel from its status item button (PLAN.md D30),
/// over `PopoverPanelSurface`, `PopoverStatusButton` and `PopoverSystem`, so tests drive it with
/// fakes.
///
/// - **Pressing the button** toggles the popover (`PopoverPressRules`): it opens below the
///   icon (`PopoverAnchoring` for the anchor, `PopoverPlacement` for the frame, on the anchor's
///   display), closes when open, or moves to the press's display when that is another one.
/// - **Closing:** Esc (the panel's own close), a press outside the panel, another app becoming
///   active, the panel resigning key, and the displays changing close it; a close from outside
///   that is the button's own press is ignored, and the button's action for a press that
///   already closed it from outside does not reopen it.
/// - **Size:** the content lays itself out no taller than the anchor's display has room for
///   below the menu bar (`PopoverPlacement.availableHeight(on:)`, the host list shrinking and
///   scrolling), so the panel never cuts it off; while open, a change of the content's size
///   places the panel again (the top edge stays at the menu bar's bottom).
/// - **Visibility** (`onVisibilityChange`, the model's `popoverVisibilityChanged`): visible
///   while open and not fully occluded (a locked screen, a sleeping display); reported on
///   changes only, so the engine's attachment checks run only while it shows (PLAN.md D20,
///   D22).
@MainActor
public final class PopoverController {
  /// Why the popover closed.
  public enum CloseReason: String, Sendable, Hashable {
    /// The status item button was pressed while it was open on the same display.
    case button
    /// Esc, or anything else that closed the panel itself.
    case escape
    /// A mouse press another process received.
    case pressOutside
    /// Another app became active.
    case appSwitch
    /// The panel stopped being the key window.
    case resignedKey
    /// The displays changed (arrangement, resolution, one added or removed).
    case displaysChanged
    /// The session switcher shortcut was pressed while it was open (PLAN.md D32, until the
    /// switcher exists).
    case shortcut

    /// Whether this close comes from outside the popover, so it may be the button's own press
    /// (`PopoverPressRules`).
    var isOutside: Bool {
      switch self {
      case .pressOutside, .appSwitch, .resignedKey: true
      case .button, .escape, .displaysChanged, .shortcut: false
      }
    }
  }

  /// Where the open popover is.
  public struct Placement: Sendable, Hashable {
    /// The anchor and where it came from.
    public var decision: PopoverAnchoring.Decision
    /// The anchor's display, in the order of the displays when it opened.
    public var screenIndex: Int
    /// That display.
    public var screen: PopoverPlacement.Screen
    /// The panel's frame.
    public var frame: CGRect
  }

  /// Whether the popover is open.
  public private(set) var isOpen = false
  /// Where it is, or was when it last closed.
  public private(set) var placement: Placement?
  /// The visibility last reported.
  public private(set) var isReportedVisible = false
  /// Why it last closed.
  public private(set) var lastCloseReason: CloseReason?

  /// The panel.
  private let panel: any PopoverPanelSurface
  /// The status item button.
  private let button: any PopoverStatusButton
  /// The system's state.
  private let system: PopoverSystem
  /// Told when the popover becomes visible or hidden.
  private let onVisibilityChange: @MainActor (Bool) -> Void
  /// Called each time the popover opens, after the panel shows (the search field takes the
  /// focus).
  private let onOpen: @MainActor () -> Void
  /// The toggle rules' memory.
  private var rules = PopoverPressRules()
  /// Whether the open panel is fully occluded.
  private var isOccluded = false

  /// A controller over its parts; nothing shows until the button is pressed.
  public init(
    panel: any PopoverPanelSurface,
    button: any PopoverStatusButton,
    system: PopoverSystem,
    onVisibilityChange: @escaping @MainActor (Bool) -> Void,
    onOpen: @escaping @MainActor () -> Void = {}
  ) {
    self.panel = panel
    self.button = button
    self.system = system
    self.onVisibilityChange = onVisibilityChange
    self.onOpen = onOpen
  }

  /// The status item button's action: opens, closes, moves or does nothing, as
  /// `PopoverPressRules` decides.
  public func buttonPressed() {
    let screens = system.screens()
    let click = system.pressLocation()
    let clickScreen = click.flatMap { PopoverPlacement.screenIndex(for: .point($0), in: screens) }
    let action = rules.buttonAction(
      isOpen: isOpen, openScreenIndex: isOpen ? placement?.screenIndex : nil, click: click,
      clickScreenIndex: clickScreen, pressCount: system.pressCount(), now: system.uptime())
    switch action {
    case .open: open(click: click, screens: screens)
    case .move: move(click: click, screens: screens)
    case .close: close(.button)
    case .ignore: break
    }
  } // End of func buttonPressed()

  /// The session switcher shortcut (PLAN.md D32; the interim action until the switcher
  /// exists): closes the open popover, or opens it under the status item button, anchored at
  /// the button's rectangle as when the action comes from no mouse event (on the button's
  /// display; the pointer when the button has no usable rectangle).
  public func shortcutPressed() {
    if isOpen {
      close(.shortcut)
    } else {
      rules.forgetPresses()
      open(click: nil, screens: system.screens())
    }
  }

  /// Closes the popover for `reason`. A close from outside that is the press the button's
  /// action just handled is ignored. Does nothing while closed.
  public func close(_ reason: CloseReason) {
    guard isOpen else { return }
    if reason.isOutside {
      let closes = rules.outsideClose(
        heldLocation: system.heldPointerLocation(), openScreenIndex: placement?.screenIndex,
        pressCount: system.pressCount(), now: system.uptime())
      guard closes else { return }
    } else if reason != .button {
      rules.forgetPresses()
    }
    isOpen = false
    lastCloseReason = reason
    panel.hide()
    button.setHighlighted(false)
    updateVisibility()
  } // End of func close(_:)

  /// The content's size changed: while open, places the panel again for the new size, keeping
  /// its anchor and display.
  public func contentSizeChanged() {
    guard isOpen, let placement else { return }
    let frame = PopoverPlacement.frame(
      contentSize: panel.contentSize, anchor: placement.decision.anchor, screen: placement.screen)
    guard frame != placement.frame else { return }
    self.placement?.frame = frame
    panel.setFrame(frame)
  }

  /// The panel's occlusion changed: visible means some part of it shows.
  public func occlusionChanged(isVisible: Bool) {
    guard isOpen else { return }
    isOccluded = !isVisible
    updateVisibility()
  }

  /// Opens the popover below the anchor for `click`.
  private func open(click: CGPoint?, screens: [PopoverPlacement.Screen]) {
    guard let placement = place(click: click, screens: screens) else { return }
    self.placement = placement
    isOpen = true
    isOccluded = false
    lastCloseReason = nil
    panel.show(at: placement.frame)
    button.setHighlighted(true)
    updateVisibility()
    onOpen()
  }

  /// Puts the open popover below the anchor for `click`, on its display, and makes it key again.
  private func move(click: CGPoint?, screens: [PopoverPlacement.Screen]) {
    guard let placement = place(click: click, screens: screens) else { return }
    self.placement = placement
    panel.show(at: placement.frame)
  }

  /// The anchor, display and frame for `click` (`PopoverAnchoring`, `PopoverPlacement`), with
  /// the content limited to the room that display has below its menu bar first; `nil` with no
  /// display.
  private func place(click: CGPoint?, screens: [PopoverPlacement.Screen]) -> Placement? {
    let decision = PopoverAnchoring.decide(
      click: click, buttonRect: button.screenRect, pointer: system.pointerLocation(),
      screens: screens)
    guard let index = PopoverPlacement.screenIndex(for: decision.anchor, in: screens) else {
      return nil
    }
    let screen = screens[index]
    panel.maximumContentHeight = PopoverPlacement.availableHeight(on: screen)
    let frame = PopoverPlacement.frame(
      contentSize: panel.contentSize, anchor: decision.anchor, screen: screen)
    return Placement(decision: decision, screenIndex: index, screen: screen, frame: frame)
  } // End of func place(click:screens:)

  /// Reports the visibility when it changed: open and not fully occluded.
  private func updateVisibility() {
    let isVisible = isOpen && !isOccluded
    guard isVisible != isReportedVisible else { return }
    isReportedVisible = isVisible
    onVisibilityChange(isVisible)
  }
}
