import CoreGraphics
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// `SwitcherController` and `SwitcherPlacement` (PLAN.md D32, Phase I-3b) over a fake panel and
/// a fake system: the shortcut toggles the switcher, which opens centered on the display with
/// the keyboard focus in its upper part, closes for each reason, reports its visibility once
/// per change (before the panel shows), keeps its top edge when its content changes size, and
/// through a click's double-click interval keeps its frame and holds back a success close
/// (Phase I-5 review). No window, panel, event or real time is involved.
@Suite("Session switcher controller")
@MainActor
struct SwitcherControllerTests {
  /// The system's state, set by each test.
  @MainActor
  final class FakeSystem {
    /// The displays.
    var screens = PopoverAnchoringTests.screens
    /// The display with the keyboard focus.
    var focused: Int? = 1
    /// The double-click interval, in seconds.
    var doubleClickInterval: TimeInterval = 0.42
    /// The delayed actions not run yet, with their delays, in the order asked.
    var delayed: [(delay: TimeInterval, action: @MainActor () -> Void)] = []

    /// The delays of the actions not run yet.
    var delays: [TimeInterval] { delayed.map(\.delay) }

    /// The controller's view of it.
    var system: SwitcherSystem {
      SwitcherSystem(
        screens: { self.screens }, focusedScreenIndex: { _ in self.focused },
        doubleClickInterval: { self.doubleClickInterval },
        runAfter: { self.delayed.append((delay: $0, action: $1)) })
    }

    /// Their time passed: runs every delayed action asked so far, in order.
    func runDelayed() {
      let actions = delayed
      delayed = []
      for entry in actions { entry.action() }
    }

    /// The first one's time passed: runs it alone.
    func runFirstDelayed() {
      guard !delayed.isEmpty else { return }
      delayed.removeFirst().action()
    }
  } // End of class FakeSystem

  /// A controller over fresh fakes, and what it reported.
  @MainActor
  final class Harness {
    /// The panel (the popover's fake, with the switcher's width).
    let panel = PopoverControllerTests.FakePanel()
    /// The system.
    let system = FakeSystem()
    /// Every visibility reported, with whether the panel showed at that moment.
    var reports: [(isVisible: Bool, panelShown: Bool)] = []
    /// How many times it opened.
    var opens = 0
    /// The controller.
    lazy var controller = SwitcherController(
      panel: panel, system: system.system,
      onVisibilityChange: { [unowned self] in
        self.reports.append((isVisible: $0, panelShown: self.panel.isShown))
      },
      onOpen: { [unowned self] in self.opens += 1 })

    /// Every visibility reported.
    var visibility: [Bool] { reports.map(\.isVisible) }

    /// A harness whose content is 540 × 300 points.
    init() {
      panel.naturalSize = CGSize(width: 540, height: 300)
    }
  }

  /// On the portrait display (index 1): centered on its visible frame (middle x 3612), the top
  /// 18 % of its visible height (1890) below the visible top (2139), on the pixel grid.
  static let onSecondDisplay = CGRect(x: 3342, y: 1499, width: 540, height: 300)
  /// On the main display: middle x 1567.5, top at 1392.5.
  static let onMainDisplay = CGRect(x: 1297.5, y: 1092.5, width: 540, height: 300)

  /// The shortcut opens the switcher on the focused display, reporting it visible before the
  /// panel shows (so the model can close the popover first), limiting the content to the room
  /// below its top edge, and focusing the search field after it shows; again, it closes.
  @Test func togglesOnTheFocusedDisplay() {
    let harness = Harness()
    harness.controller.toggle()
    #expect(harness.controller.isOpen)
    #expect(harness.panel.shownFrames == [Self.onSecondDisplay])
    #expect(harness.reports.count == 1)
    #expect(harness.reports.first?.isVisible == true && harness.reports.first?.panelShown == false)
    #expect(harness.panel.maximumContentHeight == CGFloat(1799 - (249 + 8)))
    #expect(harness.opens == 1)
    harness.controller.toggle()
    #expect(!harness.controller.isOpen && harness.controller.lastCloseReason == .shortcut)
    #expect(harness.visibility == [true, false] && harness.panel.hideCount == 1)
    harness.system.focused = 0
    harness.controller.open()
    harness.controller.open()
    #expect(harness.panel.shownFrames == [Self.onSecondDisplay, Self.onMainDisplay])
    #expect(harness.visibility == [true, false, true] && harness.opens == 2)
  } // End of func togglesOnTheFocusedDisplay()

  /// Every close reason closes it once and is remembered; closing while closed does nothing;
  /// no display, or an unusable focused index, never crashes (the first display then).
  @Test func closesForEachReason() {
    let reasons: [SwitcherController.CloseReason] = [
      .escape, .pressOutside, .appSwitch, .resignedKey, .displaysChanged, .shortcut,
      .popoverOpened, .actionSucceeded,
    ]
    let harness = Harness()
    for reason in reasons {
      harness.controller.open()
      harness.controller.close(reason)
      harness.controller.close(.escape)
      #expect(harness.controller.lastCloseReason == reason)
    }
    #expect(
      harness.visibility == Array(repeating: [true, false], count: reasons.count).flatMap { $0 })
    harness.system.focused = 7
    harness.controller.open()
    #expect(harness.panel.shownFrames.last == Self.onMainDisplay)
    harness.controller.close(.escape)
    harness.system.screens = []
    harness.controller.open()
    #expect(!harness.controller.isOpen)
  } // End of func closesForEachReason()

  /// Full occlusion reports it hidden and back; occlusion while closed changes nothing.
  @Test func occlusionReportsVisibility() {
    let harness = Harness()
    harness.controller.occlusionChanged(isVisible: false)
    #expect(harness.visibility.isEmpty)
    harness.controller.open()
    harness.controller.occlusionChanged(isVisible: false)
    harness.controller.occlusionChanged(isVisible: false)
    harness.controller.occlusionChanged(isVisible: true)
    harness.controller.close(.escape)
    #expect(harness.visibility == [true, false, true, false])
  }

  /// A change of the content's size places the panel again with the same top edge; no change,
  /// or a change while closed, moves nothing.
  @Test func contentSizeChangeKeepsTheTop() {
    let harness = Harness()
    harness.controller.contentSizeChanged()
    harness.controller.open()
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames.isEmpty)
    harness.panel.naturalSize.height = 180
    harness.controller.contentSizeChanged()
    let frame = CGRect(x: 3342, y: 1619, width: 540, height: 180)
    #expect(harness.panel.setFrames == [frame] && harness.controller.frame == frame)
    #expect(frame.maxY == Self.onSecondDisplay.maxY)
  }

  // MARK: - A click's hold (Phase I-5 review)

  /// The switcher on the second display at 180 points, its top kept (the New session form).
  static let shrunk = CGRect(x: 3342, y: 1619, width: 540, height: 180)

  /// A click's hold keeps the frame from before the click through the double-click interval:
  /// the content lays itself out no shorter, so a shrink (the New session form replacing a
  /// taller list) moves nothing until the interval ends, then is applied. Closed, a hold is
  /// never made.
  @Test func aClickHoldsAShrinkUntilTheIntervalEnds() {
    let harness = Harness()
    harness.controller.holdForClick()
    #expect(!harness.controller.isHoldingForClick && harness.system.delayed.isEmpty)
    harness.controller.open()
    harness.controller.holdForClick()
    #expect(harness.controller.isHoldingForClick && harness.system.delays == [0.42])
    #expect(harness.panel.minimumContentHeight == 300)
    harness.panel.naturalSize.height = 180
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames.isEmpty && harness.controller.frame == Self.onSecondDisplay)
    harness.system.runDelayed()
    #expect(!harness.controller.isHoldingForClick && harness.panel.minimumContentHeight == nil)
    #expect(harness.panel.setFrames == [Self.shrunk] && harness.controller.frame == Self.shrunk)
    #expect(harness.controller.isOpen && harness.visibility == [true])
  } // End of func aClickHoldsAShrinkUntilTheIntervalEnds()

  /// Growth during a hold is applied at once; a shrink after it goes back only to the frame
  /// from before the click until the interval ends.
  @Test func growthDuringAHoldIsAppliedAtOnce() {
    let harness = Harness()
    harness.controller.open()
    harness.controller.holdForClick()
    harness.panel.naturalSize.height = 420
    harness.controller.contentSizeChanged()
    let taller = CGRect(x: 3342, y: 1379, width: 540, height: 420)
    #expect(harness.panel.setFrames == [taller] && harness.controller.frame == taller)
    harness.panel.naturalSize.height = 180
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames == [taller, Self.onSecondDisplay])
    harness.system.runDelayed()
    #expect(harness.panel.setFrames == [taller, Self.onSecondDisplay, Self.shrunk])
  }

  /// While a hold lasts, a close for the action's success, another app becoming active or the
  /// panel resigning key waits for its end, which makes the first one asked (one visibility
  /// change); Esc, the shortcut, a press outside, a display change and the popover opening
  /// close at once, ending the hold and dropping the close that waited.
  @Test func aSuccessCloseWaitsForTheHold() {
    let harness = Harness()
    harness.controller.open()
    harness.controller.holdForClick()
    harness.controller.close(.actionSucceeded)
    harness.controller.close(.appSwitch)
    harness.controller.close(.resignedKey)
    #expect(harness.controller.isOpen && harness.panel.isShown && harness.visibility == [true])
    #expect(harness.controller.pendingClose == .actionSucceeded)
    harness.system.runDelayed()
    #expect(!harness.controller.isOpen && harness.controller.lastCloseReason == .actionSucceeded)
    #expect(harness.visibility == [true, false] && harness.panel.hideCount == 1)
    let immediate: [SwitcherController.CloseReason] = [
      .escape, .shortcut, .pressOutside, .displaysChanged, .popoverOpened,
    ]
    for reason in immediate {
      harness.controller.open()
      harness.controller.holdForClick()
      harness.controller.close(.appSwitch)
      harness.controller.close(reason)
      #expect(!harness.controller.isOpen && harness.controller.lastCloseReason == reason)
      #expect(!harness.controller.isHoldingForClick && harness.panel.minimumContentHeight == nil)
    } // End of loop over the closes made at once
    harness.system.runDelayed()
    #expect(!harness.controller.isOpen && harness.panel.setFrames.isEmpty)
    #expect(
      harness.visibility
        == Array(repeating: [true, false], count: immediate.count + 1).flatMap { $0 })
  } // End of func aSuccessCloseWaitsForTheHold()

  /// A switcher closed during a hold and opened again inherits nothing of it: no close waits,
  /// a shrink is applied at once, and the old hold's end neither closes it nor resizes it; a
  /// later click's hold ends at its own interval, not an earlier one's.
  @Test func aReopenedSwitcherInheritsNoHold() {
    let harness = Harness()
    harness.controller.open()
    harness.controller.holdForClick()
    harness.controller.close(.actionSucceeded)
    harness.controller.close(.escape)
    #expect(harness.controller.lastCloseReason == .escape)
    harness.controller.open()
    #expect(!harness.controller.isHoldingForClick && harness.controller.pendingClose == nil)
    #expect(harness.panel.minimumContentHeight == nil)
    harness.panel.naturalSize.height = 180
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames == [Self.shrunk])
    harness.system.runDelayed()
    #expect(harness.controller.isOpen && harness.controller.lastCloseReason == nil)
    #expect(harness.panel.setFrames == [Self.shrunk] && harness.visibility == [true, false, true])
    harness.panel.naturalSize.height = 300
    harness.controller.contentSizeChanged()
    harness.controller.holdForClick()
    harness.controller.holdForClick()
    harness.panel.naturalSize.height = 180
    harness.controller.contentSizeChanged()
    harness.system.runFirstDelayed()
    #expect(harness.controller.isHoldingForClick)
    #expect(harness.panel.setFrames == [Self.shrunk, Self.onSecondDisplay])
    harness.system.runFirstDelayed()
    #expect(!harness.controller.isHoldingForClick)
    #expect(harness.panel.setFrames == [Self.shrunk, Self.onSecondDisplay, Self.shrunk])
  } // End of func aReopenedSwitcherInheritsNoHold()

  /// The placement: centered and in the upper part, narrowed and shortened to fit a small
  /// display, and the display with the keyboard focus chosen by the focused window's area, then
  /// `NSScreen.main`, then the pointer, then the first.
  @Test func placementRules() {
    let small = PopoverPlacement.Screen(
      frame: CGRect(x: 0, y: 0, width: 400, height: 300),
      visibleFrame: CGRect(x: 0, y: 0, width: 400, height: 276), backingScaleFactor: 1)
    let top = SwitcherPlacement.top(on: small)
    #expect(top == (276 - 276 * SwitcherPlacement.topFraction).rounded())
    let frame = SwitcherPlacement.frame(contentSize: CGSize(width: 540, height: 900), screen: small)
    #expect(frame.width == 400 - 16 && frame.minX == 8)
    #expect(frame.maxY == top && frame.minY == 8)
    #expect(SwitcherPlacement.availableHeight(on: small) == top - 8)
    let screens = PopoverAnchoringTests.screens
    let pointerOnMain = CGPoint(x: 100, y: 100)
    #expect(
      SwitcherPlacement.screenIndex(
        focusedWindow: CGRect(x: 2900, y: 300, width: 600, height: 400), mainScreen: nil,
        pointer: pointerOnMain, in: screens) == 1)
    #expect(
      SwitcherPlacement.screenIndex(
        focusedWindow: CGRect(x: 2700, y: 300, width: 600, height: 400), mainScreen: nil,
        pointer: pointerOnMain, in: screens) == 0)
    #expect(
      SwitcherPlacement.screenIndex(
        focusedWindow: CGRect(x: -900, y: -900, width: 10, height: 10),
        mainScreen: screens[1].frame, pointer: pointerOnMain, in: screens) == 1)
    #expect(
      SwitcherPlacement.screenIndex(
        focusedWindow: nil, mainScreen: nil, pointer: CGPoint(x: 3500, y: 1000), in: screens) == 1)
    #expect(
      SwitcherPlacement.screenIndex(
        focusedWindow: nil, mainScreen: nil, pointer: CGPoint(x: -50, y: -50), in: screens) == 0)
    #expect(
      SwitcherPlacement.screenIndex(
        focusedWindow: nil, mainScreen: nil, pointer: .zero, in: []) == nil)
  } // End of func placementRules()
}
