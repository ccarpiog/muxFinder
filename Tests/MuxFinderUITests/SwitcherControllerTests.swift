import CoreGraphics
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// `SwitcherController` and `SwitcherPlacement` (PLAN.md D32, Phase I-3b) over a fake panel and
/// a fake system: the shortcut toggles the switcher, which opens centered on the display with
/// the keyboard focus in its upper part, closes for each reason, reports its visibility once
/// per change (before the panel shows), and keeps its top edge when its content changes size.
/// No window, panel or event is involved.
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

    /// The controller's view of it.
    var system: SwitcherSystem {
      SwitcherSystem(screens: { self.screens }, focusedScreenIndex: { _ in self.focused })
    }
  }

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
