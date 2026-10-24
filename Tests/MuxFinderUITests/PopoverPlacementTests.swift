import CoreGraphics
import Foundation
import MuxFinderCore
import Testing

@testable import MuxFinderUI

/// The popover's placement (PLAN.md Phase I-1): `PopoverPlacement.frame(contentSize:anchor:screen:)`
/// puts the popover's top edge at the bottom of the menu bar, centered on the icon, clamped
/// inside the visible frame with an 8 pt inset, in points; `screenIndex(for:in:)` finds the
/// display an anchor is on. Pure values only: no `NSScreen`, window or status item.
@Suite("Popover placement")
struct PopoverPlacementTests {
  /// Shorthand.
  typealias Placement = PopoverPlacement

  /// The popover's usual content: 360 pt wide (as `PopoverView.width`), 320 pt tall.
  static let content = CGSize(width: 360, height: 320)

  /// A 2x main display, 1728 × 1117 pt, whose menu bar reserves 37 pt (bottom at 1080).
  static let main = Placement.Screen(
    frame: CGRect(x: 0, y: 0, width: 1728, height: 1117),
    visibleFrame: CGRect(x: 0, y: 0, width: 1728, height: 1080),
    backingScaleFactor: 2)

  /// A 1x display left of the main one (negative x), with a 25 pt menu bar.
  static let left = Placement.Screen(
    frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
    visibleFrame: CGRect(x: -1920, y: 0, width: 1920, height: 1055),
    backingScaleFactor: 1)

  /// A 1x display above the main one, reaching left of it (negative x, y above 1117).
  static let above = Placement.Screen(
    frame: CGRect(x: -400, y: 1117, width: 2560, height: 1440),
    visibleFrame: CGRect(x: -400, y: 1117, width: 2560, height: 1415),
    backingScaleFactor: 1)

  /// A 1x display right of the main one, with a 25 pt menu bar.
  static let right = Placement.Screen(
    frame: CGRect(x: 1728, y: 0, width: 2560, height: 1440),
    visibleFrame: CGRect(x: 1728, y: 0, width: 2560, height: 1415),
    backingScaleFactor: 1)

  /// A menu bar icon slot of 34 pt whose middle is `midX`, in the menu bar of `screen`.
  static func icon(midX: CGFloat, on screen: Placement.Screen) -> Placement.Anchor {
    .rect(
      CGRect(
        x: midX - 17, y: screen.menuBarBottom, width: 34,
        height: screen.frame.maxY - screen.menuBarBottom))
  }

  /// Centered below the icon: the middle on the icon's, the top edge at the menu bar's bottom,
  /// the content's size.
  @Test func centeredBelowTheIcon() {
    let frame = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 1017, on: Self.main), screen: Self.main)
    #expect(frame == CGRect(x: 837, y: 760, width: 360, height: 320))
    #expect(frame.midX == 1017)
    #expect(frame.maxY == Self.main.menuBarBottom)
    #expect(Self.main.menuBarBottom == 1080)
    #expect(Self.main.reservedMenuBarHeight == 37)
    #expect(!Self.main.isMenuBarHidden)
  }

  /// Near either edge the popover keeps the 8 pt inset from the visible frame, also from a
  /// Dock at the left, and keeps its top edge.
  @Test func clampedAtTheLeftAndRightEdges() {
    let atLeft = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 21, on: Self.main), screen: Self.main)
    #expect(atLeft == CGRect(x: 8, y: 760, width: 360, height: 320))
    let atRight = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 1707, on: Self.main), screen: Self.main)
    #expect(atRight == CGRect(x: 1728 - 8 - 360, y: 760, width: 360, height: 320))
    #expect(Self.main.visibleFrame.maxX - atRight.maxX == Placement.screenInset)
    var dockAtLeft = Self.main
    dockAtLeft.visibleFrame = CGRect(x: 64, y: 0, width: 1664, height: 1080)
    let besideDock = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 21, on: dockAtLeft), screen: dockAtLeft)
    #expect(besideDock.minX == 72)
    #expect(Placement.screenInset == 8)
  } // End of func clampedAtTheLeftAndRightEdges()

  /// A second display left of or above the main one: negative coordinates, its own menu bar's
  /// bottom, its own edges for the clamp; the anchor finds its display.
  @Test func secondDisplayWithNegativeCoordinates() {
    let onLeft = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: -585, on: Self.left), screen: Self.left)
    #expect(onLeft == CGRect(x: -765, y: 735, width: 360, height: 320))
    let leftEdge = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: -1900, on: Self.left), screen: Self.left)
    #expect(leftEdge.minX == -1912)
    #expect(Self.above.menuBarBottom == 2532)
    let onAbove = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 600, on: Self.above), screen: Self.above)
    #expect(onAbove == CGRect(x: 420, y: 2212, width: 360, height: 320))
    let aboveLeftEdge = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: -365, on: Self.above), screen: Self.above
    )
    #expect(aboveLeftEdge.minX == -392)
    #expect(aboveLeftEdge.maxY == 2532)
    let screens = [Self.main, Self.left, Self.above]
    #expect(Placement.screenIndex(for: Self.icon(midX: 1017, on: Self.main), in: screens) == 0)
    #expect(Placement.screenIndex(for: Self.icon(midX: -585, on: Self.left), in: screens) == 1)
    #expect(Placement.screenIndex(for: Self.icon(midX: -365, on: Self.above), in: screens) == 2)
  } // End of func secondDisplayWithNegativeCoordinates()

  /// An auto-hiding menu bar reserves no room: the popover hangs below where the menu bar
  /// shows (the system thickness, or the camera housing's safe area when that is taller).
  @Test func autoHidingMenuBar() {
    var hiding = Self.main
    hiding.visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    #expect(hiding.isMenuBarHidden)
    #expect(hiding.reservedMenuBarHeight == 0)
    #expect(hiding.menuBarBottom == 1093)
    let frame = Placement.frame(
      contentSize: Self.content, anchor: .point(CGPoint(x: 1017, y: 1110)), screen: hiding)
    #expect(frame == CGRect(x: 837, y: 1093 - 320, width: 360, height: 320))
    hiding.safeAreaTop = 38
    #expect(hiding.menuBarBottom == 1079)
    var thinner = hiding
    thinner.safeAreaTop = 0
    thinner.menuBarThickness = 22
    #expect(thinner.menuBarBottom == 1095)
    var shown = Self.main
    shown.safeAreaTop = 38
    #expect(shown.menuBarBottom == 1080, "a menu bar that reserves room is measured, not guessed")
  } // End of func autoHidingMenuBar()

  /// Two displays with different scale factors: the same content is the same size in points on
  /// both (never pixels), and only the left edge snaps to that display's pixel grid (half
  /// points at 2x, whole points at 1x).
  @Test func differentScaleFactorsUsePoints() {
    let onRetina = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 1017.25, on: Self.main),
      screen: Self.main)
    let onExternal = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 2417.25, on: Self.right),
      screen: Self.right)
    #expect(onRetina.size == Self.content)
    #expect(onExternal.size == Self.content)
    #expect(onRetina == CGRect(x: 837.5, y: 760, width: 360, height: 320))
    #expect(onExternal == CGRect(x: 2237, y: 1095, width: 360, height: 320))
    #expect(abs(onRetina.midX - 1017.25) <= 0.25)
    #expect(abs(onExternal.midX - 2417.25) <= 0.5)
    let screens = [Self.main, Self.right]
    #expect(Placement.screenIndex(for: Self.icon(midX: 2417.25, on: Self.right), in: screens) == 1)
    var zeroScale = Self.right
    zeroScale.backingScaleFactor = 0
    #expect(
      Placement.frame(
        contentSize: Self.content, anchor: Self.icon(midX: 2417.25, on: zeroScale),
        screen: zeroScale) == onExternal)
  } // End of func differentScaleFactorsUsePoints()

  /// Content wider than the visible frame is narrowed to it minus both insets; content taller
  /// than the room below the menu bar is shortened, keeping its top edge.
  @Test func contentLargerThanTheDisplay() {
    let narrow = Placement.Screen(
      frame: CGRect(x: 0, y: 0, width: 300, height: 600),
      visibleFrame: CGRect(x: 0, y: 0, width: 300, height: 575),
      backingScaleFactor: 1)
    let wide = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 150, on: narrow), screen: narrow)
    #expect(wide == CGRect(x: 8, y: 575 - 320, width: 284, height: 320))
    let tall = Placement.frame(
      contentSize: CGSize(width: 360, height: 2000), anchor: Self.icon(midX: 1017, on: Self.main),
      screen: Self.main)
    #expect(tall == CGRect(x: 837, y: 8, width: 360, height: 1072))
    #expect(tall.maxY == 1080)
    #expect(Placement.availableHeight(on: Self.main) == tall.height)
  } // End of func contentLargerThanTheDisplay()

  /// The room the content is limited to (PLAN.md D30): from the menu bar's bottom to 8 pt
  /// above the visible frame's bottom (a Dock at the bottom raises it), below an auto-hiding
  /// menu bar too, and never negative.
  @Test func availableHeightBelowTheMenuBar() {
    #expect(Placement.availableHeight(on: Self.main) == 1072)
    var dockBelow = Self.main
    dockBelow.visibleFrame = CGRect(x: 0, y: 70, width: 1728, height: 1010)
    #expect(Placement.availableHeight(on: dockBelow) == 1002)
    var hiding = Self.main
    hiding.visibleFrame = CGRect(x: 0, y: 0, width: 1728, height: 1117)
    #expect(Placement.availableHeight(on: hiding) == 1085)
    var none = Self.main
    none.visibleFrame = CGRect(x: 0, y: 1078, width: 1728, height: 2)
    #expect(Placement.availableHeight(on: none) == 0)
  } // End of func availableHeightBelowTheMenuBar()

  /// A click point and the icon's rectangle with the same middle give the same frame.
  @Test func anchorPointMatchesRect() {
    let fromRect = Placement.frame(
      contentSize: Self.content, anchor: Self.icon(midX: 1017, on: Self.main), screen: Self.main)
    let fromPoint = Placement.frame(
      contentSize: Self.content, anchor: .point(CGPoint(x: 1017, y: 1100)), screen: Self.main)
    #expect(fromRect == fromPoint)
    #expect(Placement.Anchor.point(CGPoint(x: 3, y: 4)).referencePoint == CGPoint(x: 3, y: 4))
    #expect(
      Placement.Anchor.rect(CGRect(x: 0, y: 0, width: 10, height: 20)).referencePoint
        == CGPoint(x: 5, y: 10))
  } // End of func anchorPointMatchesRect()

  /// A pointer on the main display's top row (`y == frame.maxY`, the bottom edge of the display
  /// above) is on the main display; a point on no display goes to the nearest; none for no
  /// displays.
  @Test func screenForEdgeAndOutsidePoints() {
    let screens = [Self.above, Self.main]
    #expect(Placement.screenIndex(for: .point(CGPoint(x: 1017, y: 1117)), in: screens) == 1)
    #expect(Placement.screenIndex(for: .point(CGPoint(x: 1017, y: 1118)), in: screens) == 0)
    #expect(Placement.screenIndex(for: .point(CGPoint(x: 0, y: 0)), in: [Self.main]) == 0)
    #expect(Placement.screenIndex(for: .point(CGPoint(x: 2000, y: -50)), in: screens) == 1)
    #expect(Placement.screenIndex(for: .point(CGPoint(x: 0, y: 3000)), in: screens) == 0)
    #expect(Placement.screenIndex(for: .point(.zero), in: []) == nil)
  }

  /// `--report-popover-placement` is its own mode: never a profile rewrite, a usage error with
  /// any other mode, and its environment never reads `hosts.json` (an empty in-memory list) and
  /// has no Settings seams or attach coordinator.
  @Test func diagnosticFlag() async throws {
    let options = AppLaunchOptions(arguments: ["--report-popover-placement"])
    #expect(options.reportsPopoverPlacement)
    #expect(options.usageError == nil)
    #expect(!options.rewritesProfilesAtLaunch)
    #expect(!AppLaunchOptions(arguments: []).reportsPopoverPlacement)
    let withAppearance = AppLaunchOptions(arguments: [
      "--report-popover-placement", "--appearance", "dark",
    ])
    #expect(withAppearance.usageError == nil && withAppearance.appearance == .dark)
    for other in [
      ["--preview-fixtures"], ["--report-menu-bar-item"], ["--report-login-item-status"],
      ["--selftest", "attach-local"], ["--remove-persistent-profiles"],
    ] {
      let combined = AppLaunchOptions(arguments: ["--report-popover-placement"] + other)
      #expect(combined.usageError != nil, "\(other)")
      #expect(!combined.rewritesProfilesAtLaunch, "\(other)")
      let reversed = AppLaunchOptions(arguments: other + ["--report-popover-placement"])
      #expect(reversed.usageError != nil, "\(other)")
    }
    #expect(AppLaunchOptions.usage.contains(AppLaunchOptions.popoverPlacementUsage))
    let environment = AppEnvironment.placementDiagnostic()
    let loaded = try await environment.loadHosts()
    #expect(loaded == .inMemory(HostList()))
    #expect(loaded.hosts.hosts.isEmpty)
    #expect(environment.settings == nil)
    #expect(environment.makeAttachCoordinator == nil)
    #expect(!environment.rewritesProfilesAtLaunch)
  } // End of func diagnosticFlag()
}
