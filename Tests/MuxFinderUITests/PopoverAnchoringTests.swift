import CoreGraphics
import Foundation
import Testing

@testable import MuxFinderUI

/// The anchor rule, the toggle rules and the after-fix check of muxFinder's popover (PLAN.md
/// D30): pure values over this Mac's two displays as Phase I-1a recorded them (a 3072 × 1728
/// main display with a 30 pt menu bar, a portrait 1080 × 1920 display right of it), the real
/// button's rectangle and the replica windows' placeholder frames.
@Suite("Popover anchoring")
struct PopoverAnchoringTests {
  /// Shorthand.
  typealias Anchoring = PopoverAnchoring
  /// Shorthand.
  typealias Rules = PopoverPressRules

  /// The main display: Dock at the left, menu bar bottom 1698.
  static let main = PopoverPlacement.Screen(
    frame: CGRect(x: 0, y: 0, width: 3072, height: 1728),
    visibleFrame: CGRect(x: 63, y: 0, width: 3009, height: 1698),
    backingScaleFactor: 2, menuBarThickness: 22)
  /// The portrait display right of it: menu bar bottom 2139.
  static let portrait = PopoverPlacement.Screen(
    frame: CGRect(x: 3072, y: 249, width: 1080, height: 1920),
    visibleFrame: CGRect(x: 3072, y: 249, width: 1080, height: 1890),
    backingScaleFactor: 2, menuBarThickness: 22)
  /// Both, in `NSScreen.screens` order.
  static let screens = [main, portrait]

  /// The real button's rectangle in screen coordinates (window 0's button, middle x 1430).
  static let button = CGRect(x: 1413, y: 1702, width: 34, height: 22)
  /// The replica status-bar windows' placeholder frames.
  static let replicas = [
    CGRect(x: 0, y: -30, width: 34, height: 30), CGRect(x: 4152, y: 2139, width: 34, height: 30),
  ]

  /// A press on the button, anywhere in its column of the menu bar (also on the bar's top row
  /// and its bottom edge), anchors at the button's rectangle; a press elsewhere, on either
  /// display, anchors at the press.
  @Test func mousePressAnchorsAtTheButtonOnlyWhenOnIt() {
    for click in [
      CGPoint(x: 1430, y: 1713), CGPoint(x: 1413, y: 1728), CGPoint(x: 1447, y: 1698),
    ] {
      let decision = Anchoring.decide(
        click: click, buttonRect: Self.button, pointer: .zero, screens: Self.screens)
      #expect(decision == .init(anchor: .rect(Self.button), source: .button), "\(click)")
    }
    let beside = CGPoint(x: 1460, y: 1713)
    #expect(
      Anchoring.decide(
        click: beside, buttonRect: Self.button, pointer: .zero, screens: Self.screens)
        == .init(anchor: .point(beside), source: .click))
    let onPortrait = CGPoint(x: 3900, y: 2160)
    let decision = Anchoring.decide(
      click: onPortrait, buttonRect: Self.button, pointer: .zero, screens: Self.screens)
    #expect(decision == .init(anchor: .point(onPortrait), source: .click))
    #expect(PopoverPlacement.screenIndex(for: decision.anchor, in: Self.screens) == 1)
    let belowTheBar = CGPoint(x: 1430, y: 1600)
    #expect(!Anchoring.isPress(belowTheBar, onButton: Self.button, screens: Self.screens))
  } // End of func mousePressAnchorsAtTheButtonOnlyWhenOnIt()

  /// A display stacked above the button's at the same x: a press there in the button's column
  /// is on that display's menu bar, not on the button.
  @Test func pressInTheButtonsColumnOnAnotherDisplayIsNotOnIt() {
    let above = PopoverPlacement.Screen(
      frame: CGRect(x: 0, y: 1728, width: 3072, height: 1728),
      visibleFrame: CGRect(x: 0, y: 1728, width: 3072, height: 1698))
    let screens = [Self.main, above]
    let click = CGPoint(x: 1430, y: 3440)
    #expect(!Anchoring.isPress(click, onButton: Self.button, screens: screens))
    #expect(
      Anchoring.decide(click: click, buttonRect: Self.button, pointer: .zero, screens: screens)
        .source == .click)
  }

  /// No mouse event (`performClick(_:)`, VoiceOver): the button's rectangle; without a usable
  /// one, the pointer; a replica's placeholder frame is never usable, so never the anchor.
  @Test func noMouseEventAnchorsAtTheButtonElseThePointer() {
    let pointer = CGPoint(x: 900, y: 500)
    #expect(
      Anchoring.decide(click: nil, buttonRect: Self.button, pointer: pointer, screens: Self.screens)
        == .init(anchor: .rect(Self.button), source: .button))
    #expect(
      Anchoring.decide(click: nil, buttonRect: nil, pointer: pointer, screens: Self.screens)
        == .init(anchor: .point(pointer), source: .pointer))
    for replica in Self.replicas {
      #expect(!Anchoring.isUsableButtonRect(replica, screens: Self.screens), "\(replica)")
      #expect(
        Anchoring.decide(click: nil, buttonRect: replica, pointer: pointer, screens: Self.screens)
          .source == .pointer)
      let click = CGPoint(x: replica.midX, y: replica.midY)
      #expect(
        Anchoring.decide(click: click, buttonRect: replica, pointer: pointer, screens: Self.screens)
          == .init(anchor: .point(click), source: .click))
    } // End of loop over the replica frames
    #expect(Anchoring.isUsableButtonRect(Self.button, screens: Self.screens))
    let inTheDesktop = CGRect(x: 1413, y: 900, width: 34, height: 22)
    #expect(!Anchoring.isUsableButtonRect(inTheDesktop, screens: Self.screens))
    #expect(!Anchoring.isUsableButtonRect(.zero, screens: Self.screens))
  } // End of func noMouseEventAnchorsAtTheButtonElseThePointer()

  /// `screenIndex(holding:in:)` has no nearest-display fallback; `screenIndex(for:in:)` keeps
  /// it.
  @Test func holdingHasNoNearestFallback() {
    let below = CGPoint(x: 17, y: -15)
    #expect(PopoverPlacement.screenIndex(holding: below, in: Self.screens) == nil)
    #expect(PopoverPlacement.screenIndex(for: .point(below), in: Self.screens) == 0)
    #expect(PopoverPlacement.screenIndex(holding: CGPoint(x: 1430, y: 1728), in: Self.screens) == 0)
  }

  /// The toggle rules in a box, so a test can call their mutating methods inside `#expect`.
  final class Box {
    /// The rules.
    var rules = Rules()

    /// A button press at `click` (`nil`: no mouse event) on display `screen`, with the popover
    /// open on display `open` (`nil`: closed), at uptime `now`, with the system's press count
    /// `count`.
    func press(
      _ click: CGPoint?, on screen: Int?, open: Int? = nil, count: UInt64, at now: TimeInterval
    ) -> Rules.Action {
      rules.buttonAction(
        isOpen: open != nil, openScreenIndex: open, click: click, clickScreenIndex: screen,
        pressCount: count, now: now)
    }

    /// An outside close with a mouse button held at `held` (`nil`: none held), the popover on
    /// display `open`, at uptime `now`, with the system's press count `count`; whether it
    /// closes.
    func outside(_ held: CGPoint?, open: Int, count: UInt64, at now: TimeInterval) -> Bool {
      rules.outsideClose(heldLocation: held, openScreenIndex: open, pressCount: count, now: now)
    }
  } // End of class Box

  /// On the main display's icon.
  static let icon = CGPoint(x: 1430, y: 1713)
  /// On the portrait display's menu bar.
  static let onPortrait = CGPoint(x: 3900, y: 2160)

  /// Open: a press on the same display (or with no mouse event) closes, one on another display
  /// moves; closed, a press opens.
  @Test func pressWhileOpenClosesOrMoves() {
    let box = Box()
    #expect(box.press(Self.icon, on: 0, open: 0, count: 1, at: 10) == .close)
    #expect(box.press(Self.onPortrait, on: 1, open: 0, count: 2, at: 20) == .move)
    #expect(box.press(nil, on: nil, open: 1, count: 2, at: 30) == .close)
    #expect(box.press(nil, on: nil, count: 2, at: 40) == .open)
  }

  /// The toggle bug, outside close first: the press that closed the popover from outside (the
  /// same press count) does not reopen it on the same display, opens it on another, and a
  /// later or distant press opens it as usual.
  @Test func outsideCloseThenTheSamePressesAction() {
    let box = Box()
    let icon = Self.icon
    #expect(box.outside(icon, open: 0, count: 1, at: 100))
    #expect(box.press(CGPoint(x: 1432, y: 1712), on: 0, count: 1, at: 100.2) == .ignore)
    #expect(box.rules.lastOutsideClose == nil, "one press is matched once")
    #expect(box.press(icon, on: 0, count: 1, at: 100.3) == .open)
    #expect(box.outside(icon, open: 1, count: 2, at: 200))
    #expect(
      box.press(icon, on: 0, count: 2, at: 200.1) == .open,
      "the popover was on the other display: the press moves it here")
    #expect(box.outside(icon, open: 0, count: 3, at: 300))
    #expect(box.press(icon, on: 0, count: 3, at: 300 + Rules.samePressInterval + 0.01) == .open)
    #expect(box.outside(icon, open: 0, count: 4, at: 400))
    let distant = CGPoint(x: icon.x + Rules.samePressDistance + 1, y: icon.y)
    #expect(box.press(distant, on: 0, count: 4, at: 400.1) == .open)
    #expect(box.outside(nil, open: 0, count: 4, at: 500))
    #expect(
      box.press(icon, on: 0, count: 4, at: 500.1) == .open,
      "a close with no mouse button held (an app switch from the keyboard) is no press's")
  } // End of func outsideCloseThenTheSamePressesAction()

  /// The toggle bug, button action first: the outside close for the press the action just
  /// handled (the same press count) is ignored; another press, or the same spot later, closes.
  @Test func buttonActionThenTheSamePressesOutsideClose() {
    let box = Box()
    #expect(box.press(Self.onPortrait, on: 1, open: 0, count: 1, at: 10) == .move)
    #expect(!box.outside(Self.onPortrait, open: 1, count: 1, at: 10.05))
    #expect(box.outside(CGPoint(x: 3500, y: 1200), open: 1, count: 1, at: 10.1))
    #expect(box.outside(Self.onPortrait, open: 1, count: 1, at: 11))
    _ = box.press(nil, on: nil, count: 1, at: 20)
    #expect(box.rules.lastButtonPress == nil, "no mouse event: nothing to match")
    #expect(box.outside(Self.onPortrait, open: 1, count: 1, at: 20.05))
    box.rules.forgetPresses()
    #expect(box.rules.lastButtonPress == nil && box.rules.lastOutsideClose == nil)
  }

  /// Rapid separate presses, outside close first: a press on a neighboring menu bar item
  /// closes the popover from outside, and a press on muxFinder's icon right after it, near it,
  /// is a new press (a higher count), so it opens the popover, on either display; only the
  /// same count is the same press.
  @Test func separatePressAfterAnOutsideCloseActsOnItsOwn() {
    let box = Box()
    let neighbor = CGPoint(x: Self.icon.x + 20, y: Self.icon.y)
    #expect(box.outside(neighbor, open: 0, count: 7, at: 100))
    #expect(
      box.press(Self.icon, on: 0, count: 8, at: 100.15) == .open,
      "0.15 s and 20 pt apart, but another press")
    #expect(box.outside(neighbor, open: 1, count: 9, at: 200))
    #expect(box.press(Self.icon, on: 0, count: 10, at: 200.1) == .open)
    #expect(box.outside(neighbor, open: 0, count: 11, at: 300))
    #expect(box.press(Self.icon, on: 0, count: 11, at: 300.15) == .ignore)
  } // End of func separatePressAfterAnOutsideCloseActsOnItsOwn()

  /// Rapid separate presses, button action first: a press on muxFinder's icon, then a press on
  /// a neighboring menu bar item right after it, near it: the second is a new press (a higher
  /// count), so its outside close closes the popover.
  @Test func separatePressAfterTheButtonsActionClosesFromOutside() {
    let box = Box()
    #expect(box.press(Self.icon, on: 0, count: 3, at: 10) == .open)
    let neighbor = CGPoint(x: Self.icon.x - 20, y: Self.icon.y)
    #expect(box.outside(neighbor, open: 0, count: 4, at: 10.15), "another press closes")
    #expect(box.press(Self.icon, on: 0, count: 5, at: 20) == .open)
    #expect(!box.outside(neighbor, open: 0, count: 5, at: 20.15), "the same press does not")
  }

  /// The after-fix check: centered and at the menu bar passes; a middle off by more than 2 pt
  /// fails unless the clamp moved it; a top off by more than 1 pt fails.
  @Test func afterFixCheck() {
    let anchor = PopoverPlacement.Anchor.rect(Self.button)
    let placed = PopoverPlacement.frame(
      contentSize: CGSize(width: 360, height: 168), anchor: anchor, screen: Self.main)
    #expect(placed == CGRect(x: 1250, y: 1530, width: 360, height: 168))
    let check = PopoverPlacementCheck(frame: placed, anchor: anchor, screen: Self.main)
    #expect(check.middleOffset == 0 && check.topOffset == 0 && !check.isClamped && check.passes)
    let off = PopoverPlacementCheck(
      frame: placed.offsetBy(dx: 3, dy: 0), anchor: anchor, screen: Self.main)
    #expect(off.middleOffset == 3 && !off.middlePasses && off.topPasses && !off.passes)
    let low = PopoverPlacementCheck(
      frame: placed.offsetBy(dx: 0, dy: -1.5), anchor: anchor, screen: Self.main)
    #expect(low.middlePasses && !low.topPasses && !low.passes)
    let nearEdge = PopoverPlacement.Anchor.point(CGPoint(x: 4140, y: 2160))
    let clamped = PopoverPlacement.frame(
      contentSize: CGSize(width: 360, height: 168), anchor: nearEdge, screen: Self.portrait)
    let edgeCheck = PopoverPlacementCheck(frame: clamped, anchor: nearEdge, screen: Self.portrait)
    #expect(edgeCheck.isClamped && edgeCheck.middleOffset < -2 && edgeCheck.passes)
    #expect(clamped.maxY == 2139)
  } // End of func afterFixCheck()
}
