import AppKit
import CoreGraphics

/// Where muxFinder's popover goes (PLAN.md Phase I-1): its top edge at the bottom of the
/// clicked display's menu bar, horizontally centered on the menu bar icon, clamped inside that
/// display's visible frame with `screenInset` to spare, no arrow.
///
/// Everything is in points, in AppKit's global screen coordinates (origin at the bottom left of
/// the primary display, y growing upwards; a display left of or below the primary one has
/// negative coordinates). A pure value computation: tests describe displays with `Screen`
/// values and never need an `NSScreen`.
public enum PopoverPlacement {
  /// The room kept between the popover and the left, right and bottom edges of the display's
  /// visible frame, in points. 8 pt keeps a clamped popover visibly apart from the display's
  /// edge (and from a Dock at the side), about the gap system menu bar extras leave.
  public static let screenInset: CGFloat = 8

  /// A reserved menu bar height below this many points counts as no menu bar (hidden or
  /// auto-hiding): AppKit then reports a visible frame reaching the display's top.
  static let hiddenMenuBarTolerance: CGFloat = 1

  /// A display as the placement needs it: frames in points, the scale (for the pixel grid
  /// only), and what to assume when its menu bar reserves no room.
  public struct Screen: Sendable, Hashable {
    /// The whole display (`NSScreen.frame`).
    public var frame: CGRect
    /// The part windows may use (`NSScreen.visibleFrame`): without the menu bar and the Dock.
    public var visibleFrame: CGRect
    /// Pixels per point (`NSScreen.backingScaleFactor`); used only to put the popover's left
    /// edge on a whole pixel. Any value below 1 counts as 1.
    public var backingScaleFactor: CGFloat
    /// The menu bar's height when it reserves no room in `visibleFrame`
    /// (`NSStatusBar.system.thickness`).
    public var menuBarThickness: CGFloat
    /// The top safe-area inset (`NSScreen.safeAreaInsets.top`, nonzero on a display with a
    /// camera housing); an auto-hiding menu bar is at least this tall there.
    public var safeAreaTop: CGFloat

    /// Describes a display from its parts.
    public init(
      frame: CGRect,
      visibleFrame: CGRect,
      backingScaleFactor: CGFloat = 2,
      menuBarThickness: CGFloat = 24,
      safeAreaTop: CGFloat = 0
    ) {
      self.frame = frame
      self.visibleFrame = visibleFrame
      self.backingScaleFactor = backingScaleFactor
      self.menuBarThickness = menuBarThickness
      self.safeAreaTop = safeAreaTop
    } // End of init(frame:visibleFrame:backingScaleFactor:menuBarThickness:safeAreaTop:)

    /// The room the menu bar reserves at the top of the display:
    /// `frame.maxY − visibleFrame.maxY` (0 when it auto-hides).
    public var reservedMenuBarHeight: CGFloat {
      max(0, frame.maxY - visibleFrame.maxY)
    }

    /// Whether the menu bar reserves no room here: it auto-hides (or this display has none,
    /// as a second display does when displays share one Space).
    public var isMenuBarHidden: Bool {
      reservedMenuBarHeight < PopoverPlacement.hiddenMenuBarTolerance
    }

    /// The y of the menu bar's bottom edge: `frame.maxY − (frame.maxY − visibleFrame.maxY)`,
    /// which is `visibleFrame.maxY`; when the menu bar reserves no room, where it ends once
    /// shown: `menuBarThickness` (at least `safeAreaTop`) below the display's top.
    public var menuBarBottom: CGFloat {
      if isMenuBarHidden {
        return frame.maxY - max(menuBarThickness, safeAreaTop)
      }
      return frame.maxY - reservedMenuBarHeight
    }
  } // End of struct Screen

  /// What the popover hangs from.
  public enum Anchor: Sendable, Hashable {
    /// The menu bar icon's rectangle in screen coordinates.
    case rect(CGRect)
    /// A point, such as the click (`NSEvent.mouseLocation`).
    case point(CGPoint)

    /// The x the popover is centered on.
    public var midX: CGFloat {
      switch self {
      case .rect(let rect): rect.midX
      case .point(let point): point.x
      }
    }

    /// The point that decides which display the anchor is on: the rectangle's center, or the
    /// point itself.
    public var referencePoint: CGPoint {
      switch self {
      case .rect(let rect): CGPoint(x: rect.midX, y: rect.midY)
      case .point(let point): point
      }
    }
  } // End of enum Anchor

  /// The popover's frame on `screen` for content of `contentSize`, hanging from `anchor`.
  ///
  /// - The top edge is exactly at `screen.menuBarBottom`.
  /// - The horizontal middle is `anchor.midX`, with the left edge put on the display's pixel
  ///   grid, then moved as little as needed to keep `screenInset` from the visible frame's left
  ///   and right edges.
  /// - Content wider than the visible frame minus both insets is narrowed to fit; content
  ///   taller than the room between the menu bar and the visible frame's bottom inset is
  ///   shortened, keeping its top edge (the caller scrolls or resizes the content).
  public static func frame(contentSize: CGSize, anchor: Anchor, screen: Screen) -> CGRect {
    let visible = screen.visibleFrame
    let top = min(screen.menuBarBottom, visible.maxY)
    let width = max(0, min(contentSize.width, visible.width - 2 * screenInset))
    let height = max(0, min(contentSize.height, top - (visible.minY + screenInset)))
    let scale = max(1, screen.backingScaleFactor)
    let centered = ((anchor.midX - width / 2) * scale).rounded() / scale
    let lowest = visible.minX + screenInset
    let highest = visible.maxX - screenInset - width
    let x = max(lowest, min(centered, highest))
    return CGRect(x: x, y: top - height, width: width, height: height)
  } // End of static func frame(contentSize:anchor:screen:)

  /// The index in `screens` of the display `anchor` is on: the first whose frame holds its
  /// reference point counting the top edge and not the bottom one (AppKit's pointer location
  /// on a display's top row, where its menu bar is, is exactly `frame.maxY`, which is also the
  /// bottom edge of a display stacked above it); else the first whose frame contains it the
  /// usual way; else the nearest. `nil` only for no displays.
  public static func screenIndex(for anchor: Anchor, in screens: [Screen]) -> Int? {
    let point = anchor.referencePoint
    if let topInclusive = screens.firstIndex(where: { screen in
      let frame = screen.frame
      return point.x >= frame.minX && point.x < frame.maxX && point.y > frame.minY
        && point.y <= frame.maxY
    }) {
      return topInclusive
    }
    if let inside = screens.firstIndex(where: { $0.frame.contains(point) }) {
      return inside
    }
    return screens.indices.min { first, second in
      distance(from: point, to: screens[first].frame)
        < distance(from: point, to: screens[second].frame)
    }
  } // End of static func screenIndex(for:in:)

  /// The distance from `point` to the nearest point of `rect` (0 inside).
  static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
    let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
    let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
    return (dx * dx + dy * dy).squareRoot()
  }
}

extension PopoverPlacement.Screen {
  /// Describes `screen` as AppKit reports it, with the system menu bar's thickness.
  @MainActor
  public init(_ screen: NSScreen) {
    self.init(
      frame: screen.frame,
      visibleFrame: screen.visibleFrame,
      backingScaleFactor: screen.backingScaleFactor,
      menuBarThickness: NSStatusBar.system.thickness,
      safeAreaTop: screen.safeAreaInsets.top)
  }
}
