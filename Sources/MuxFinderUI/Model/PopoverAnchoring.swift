import CoreGraphics
import Foundation

/// What the popover hangs from when muxFinder's status item button is pressed (PLAN.md D30): a
/// pure decision over points and `PopoverPlacement.Screen` values, so tests need no `NSEvent`,
/// window or status item.
///
/// - **A mouse press** (the action came from a mouse event): the button's rectangle when it is
///   usable and the press is on it, so the popover's middle is the icon's exactly; otherwise the
///   press's location (`NSEvent.mouseLocation`), on the display that holds it. A press on another
///   display's copy of the icon lands there, since AppKit's frames for those copies are
///   placeholders.
/// - **No mouse event** (`performClick(_:)`, VoiceOver): the button's rectangle when usable,
///   else the pointer.
/// - **Usable** means on a display's menu bar: the rectangle's middle is on a display (never the
///   nearest one) and no lower than that display's menu bar bottom. The replica status-bar
///   windows' placeholder frames (below the main display's bottom-left corner, at the second
///   display's right edge) fail this, so they are never anchors; the anchor never reads them
///   anyway, only the real button's rectangle.
public enum PopoverAnchoring {
  /// Where an anchor came from.
  public enum Source: String, Sendable, Hashable {
    /// The status item button's rectangle.
    case button
    /// The mouse press's location, which was not on the button's rectangle.
    case click
    /// The pointer's location: no mouse event and no usable button rectangle.
    case pointer
  }

  /// An anchor and where it came from.
  public struct Decision: Sendable, Hashable {
    /// What the popover hangs from.
    public var anchor: PopoverPlacement.Anchor
    /// Where it came from.
    public var source: Source

    /// A decision from its parts.
    public init(anchor: PopoverPlacement.Anchor, source: Source) {
      self.anchor = anchor
      self.source = source
    }
  }

  /// How far below its display's menu bar bottom a button rectangle's middle may sit and still
  /// count as in the menu bar, in points.
  static let menuBarTolerance: CGFloat = 1

  /// The anchor for a press on the status item button: `click` is the mouse press's location
  /// when the action came from a mouse event (else `nil`), `buttonRect` the button's rectangle in
  /// screen coordinates (`nil` without a window), `pointer` the pointer's location now.
  public static func decide(
    click: CGPoint?, buttonRect: CGRect?, pointer: CGPoint, screens: [PopoverPlacement.Screen]
  ) -> Decision {
    let usable = buttonRect.flatMap { isUsableButtonRect($0, screens: screens) ? $0 : nil }
    if let click {
      if let usable, isPress(click, onButton: usable, screens: screens) {
        return Decision(anchor: .rect(usable), source: .button)
      }
      return Decision(anchor: .point(click), source: .click)
    }
    if let usable { return Decision(anchor: .rect(usable), source: .button) }
    return Decision(anchor: .point(pointer), source: .pointer)
  } // End of static func decide(click:buttonRect:pointer:screens:)

  /// Whether `rect` can anchor the popover: not empty, its middle on a display (top edge
  /// counted, no nearest-display fallback) and no lower than that display's menu bar bottom.
  public static func isUsableButtonRect(_ rect: CGRect, screens: [PopoverPlacement.Screen])
    -> Bool
  {
    guard rect.width > 0, rect.height > 0 else { return false }
    let middle = CGPoint(x: rect.midX, y: rect.midY)
    guard let index = PopoverPlacement.screenIndex(holding: middle, in: screens) else {
      return false
    }
    return middle.y >= screens[index].menuBarBottom - menuBarTolerance
  }

  /// Whether a press at `click` is on the button at `buttonRect`: within the button's column
  /// (its left to right edge), in the menu bar of the button's display (from that menu bar's
  /// bottom up to the display's top). The whole height of the menu bar counts, since the
  /// button is shorter than the bar it sits in.
  public static func isPress(
    _ click: CGPoint, onButton buttonRect: CGRect, screens: [PopoverPlacement.Screen]
  ) -> Bool {
    let middle = CGPoint(x: buttonRect.midX, y: buttonRect.midY)
    guard click.x >= buttonRect.minX, click.x <= buttonRect.maxX,
      let buttonScreen = PopoverPlacement.screenIndex(holding: middle, in: screens),
      PopoverPlacement.screenIndex(holding: click, in: screens) == buttonScreen
    else { return false }
    return click.y >= screens[buttonScreen].menuBarBottom - menuBarTolerance
  }
}

/// What a press on muxFinder's status item button does, and whether something outside the
/// popover closes it (PLAN.md D30): a pure value, so the toggle rules are tested without
/// AppKit.
///
/// - A press while the popover is open closes it, unless it is on another display than the
///   popover's: then the popover moves there.
/// - **The classic toggle bug.** A mouse press on the icon can reach the app twice: as the
///   button's action, and as something outside the popover (the popover resigning key, a press
///   another process received, an app switch) that closes it. In either order, one press must
///   act once. So a close from outside made while a mouse button is held is remembered with the
///   press's count (`PopoverSystem.pressCount`: every effect of one press sees the same count,
///   the next press raises it), the pointer's location and the time, and a button action for
///   the same press (the same count, within `samePressInterval` and `samePressDistance`) leaves
///   the popover closed, or opens it on the press's display when the popover was on another
///   one. The other way round, an outside close for the press the button's action just handled
///   is ignored.
/// - **A separate press is never the same press**, however soon and close it follows (a
///   neighboring menu bar item, then muxFinder's icon): its count is higher, so it acts on its
///   own. The interval and the distance only bound the match; they never make two presses one.
public struct PopoverPressRules: Sendable, Hashable {
  /// What a button press does.
  public enum Action: Sendable, Hashable {
    /// Open the popover.
    case open
    /// Close the popover.
    case close
    /// Put the open popover on the press's display.
    case move
    /// Nothing: this press already closed the popover from outside.
    case ignore
  }

  /// One effect of a mouse press: which press (its count), when the effect came (system
  /// uptime, seconds) and where the pointer was (screen coordinates).
  public struct Press: Sendable, Hashable {
    /// The system's count of mouse presses when the effect came (`PopoverSystem.pressCount`):
    /// the same for every effect of one press, higher for any later press.
    public var count: UInt64
    /// When the effect came, as `ProcessInfo.systemUptime`.
    public var time: TimeInterval
    /// Where the pointer was.
    public var location: CGPoint

    /// A press from its parts.
    public init(count: UInt64, time: TimeInterval, location: CGPoint) {
      self.count = count
      self.time = time
      self.location = location
    }
  }

  /// A close from outside made while a mouse button was held.
  public struct OutsideClose: Sendable, Hashable {
    /// The press.
    public var press: Press
    /// The display the popover was on.
    public var screenIndex: Int?
  }

  /// How long after one of its effects the other effect of the same press may arrive, in
  /// seconds: longer than a click's press-to-release time and AppKit's delivery, shorter than
  /// a person clicking twice on purpose.
  public static let samePressInterval: TimeInterval = 0.5
  /// How far apart, in points on each axis, two locations of the same press may be: about one
  /// menu bar icon's width.
  public static let samePressDistance: CGFloat = 40

  /// The last button action that came from a mouse press.
  public private(set) var lastButtonPress: Press?
  /// The last close from outside made while a mouse button was held.
  public private(set) var lastOutsideClose: OutsideClose?

  /// Rules with nothing remembered.
  public init() {}

  /// Whether `later` is another effect of the press `earlier` is one of: the same press count,
  /// at most `samePressInterval` later and within `samePressDistance` on each axis.
  static func isSamePress(_ earlier: Press, as later: Press) -> Bool {
    let elapsed = later.time - earlier.time
    return later.count == earlier.count && elapsed >= 0 && elapsed <= samePressInterval
      && abs(later.location.x - earlier.location.x) <= samePressDistance
      && abs(later.location.y - earlier.location.y) <= samePressDistance
  }

  /// A press on the button: `click` is the mouse press's location (`nil` when the action came
  /// from no mouse event), `clickScreenIndex` its display, `openScreenIndex` the open popover's
  /// display, `pressCount` the system's count of mouse presses now. Remembers the press for
  /// `outsideClose(heldLocation:openScreenIndex:pressCount:now:)`.
  public mutating func buttonAction(
    isOpen: Bool, openScreenIndex: Int?, click: CGPoint?, clickScreenIndex: Int?,
    pressCount: UInt64, now: TimeInterval
  ) -> Action {
    let outside = lastOutsideClose
    lastOutsideClose = nil
    let press = click.map { Press(count: pressCount, time: now, location: $0) }
    lastButtonPress = press
    if isOpen {
      if let clickScreenIndex, let openScreenIndex, clickScreenIndex != openScreenIndex {
        return .move
      }
      return .close
    }
    guard let outside, let press, Self.isSamePress(outside.press, as: press) else {
      return .open
    }
    return outside.screenIndex == clickScreenIndex ? .ignore : .open
  } // End of func buttonAction(isOpen:openScreenIndex:click:clickScreenIndex:pressCount:now:)

  /// Something outside the popover would close it: the popover resigned key, another process
  /// received a mouse press, or another app became active. `heldLocation` is the pointer's
  /// location while a mouse button is held (`nil` when none is), `pressCount` the system's
  /// count of mouse presses now. Returns `false` when this is the press the button's action
  /// just handled (the popover stays); otherwise `true`, remembering the close for
  /// `buttonAction` when a mouse button is held.
  public mutating func outsideClose(
    heldLocation: CGPoint?, openScreenIndex: Int?, pressCount: UInt64, now: TimeInterval
  ) -> Bool {
    let press = heldLocation.map { Press(count: pressCount, time: now, location: $0) }
    if let press, let last = lastButtonPress, Self.isSamePress(last, as: press) {
      return false
    }
    lastOutsideClose = press.map { OutsideClose(press: $0, screenIndex: openScreenIndex) }
    return true
  } // End of func outsideClose(heldLocation:openScreenIndex:pressCount:now:)

  /// A close that is no press's (Esc, the panel's own close, the displays changing): forgets
  /// the remembered presses.
  public mutating func forgetPresses() {
    lastButtonPress = nil
    lastOutsideClose = nil
  }
}

/// The after-fix check of `--report-popover-placement` (PLAN.md Phase I-1): the popover's
/// horizontal middle against the anchor's (within `middleTolerance` unless the clamp moved it)
/// and its top edge against the menu bar's bottom (within `topTolerance`).
public struct PopoverPlacementCheck: Sendable, Hashable {
  /// The largest allowed distance between the popover's and the anchor's middles, in points.
  public static let middleTolerance: CGFloat = 2
  /// The largest allowed distance between the popover's top and the menu bar's bottom, in
  /// points.
  public static let topTolerance: CGFloat = 1

  /// The popover's horizontal middle minus the anchor's.
  public var middleOffset: CGFloat
  /// The popover's top edge minus the menu bar's bottom.
  public var topOffset: CGFloat
  /// Whether the popover centered on the anchor would leave the visible frame's inset, so the
  /// clamp moved it and its middle need not be the anchor's.
  public var isClamped: Bool

  /// The check of a popover at `frame` hanging from `anchor` on `screen`.
  public init(frame: CGRect, anchor: PopoverPlacement.Anchor, screen: PopoverPlacement.Screen) {
    middleOffset = frame.midX - anchor.midX
    topOffset = frame.maxY - screen.menuBarBottom
    let centered = anchor.midX - frame.width / 2
    let lowest = screen.visibleFrame.minX + PopoverPlacement.screenInset
    let highest = screen.visibleFrame.maxX - PopoverPlacement.screenInset - frame.width
    isClamped = centered < lowest || centered > highest
  }

  /// Whether the middle is within tolerance, or the popover was clamped.
  public var middlePasses: Bool {
    isClamped || abs(middleOffset) <= Self.middleTolerance
  }

  /// Whether the top edge is within tolerance.
  public var topPasses: Bool {
    abs(topOffset) <= Self.topTolerance
  }

  /// Whether both pass.
  public var passes: Bool {
    middlePasses && topPasses
  }
}
