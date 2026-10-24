import CoreGraphics
import Foundation
import Testing

@testable import MuxFinderUI

/// `PopoverController` (PLAN.md D30) over a fake panel, a fake status item button and a fake
/// system: the button toggles the popover below the icon, Esc, a press outside, an app switch,
/// the panel resigning key and the displays changing close it, a press on another display
/// moves it, one press acts once whichever of its two effects comes first, the content's size
/// places it again, and the model hears of every visibility change once. No window, status item
/// or event is involved.
@Suite("Popover controller")
@MainActor
struct PopoverControllerTests {
  /// The panel as the controller drives it: records what it was asked.
  @MainActor
  final class FakePanel: PopoverPanelSurface {
    /// The content's natural size with no limit.
    var naturalSize = CGSize(width: 360, height: 168)
    /// The limit the controller set.
    var maximumContentHeight: CGFloat?
    /// The limit in effect at each read of `contentSize`.
    private(set) var limitsAtSizeReads: [CGFloat?] = []
    /// Whether it shows.
    private(set) var isShown = false
    /// Every frame it was shown at.
    private(set) var shownFrames: [CGRect] = []
    /// Every frame it was moved or resized to while shown.
    private(set) var setFrames: [CGRect] = []
    /// How many times it was hidden.
    private(set) var hideCount = 0

    /// The natural size, no taller than the limit (the host list shrinks, down to nothing);
    /// records the limit in effect.
    var contentSize: CGSize {
      limitsAtSizeReads.append(maximumContentHeight)
      let height = min(naturalSize.height, maximumContentHeight ?? .infinity)
      return CGSize(width: naturalSize.width, height: height)
    }

    /// Shows at `frame`.
    func show(at frame: CGRect) {
      isShown = true
      shownFrames.append(frame)
    }

    /// Records the frame.
    func setFrame(_ frame: CGRect) {
      setFrames.append(frame)
    }

    /// Hides.
    func hide() {
      isShown = false
      hideCount += 1
    }
  }

  /// The status item button: a fixed rectangle; records its highlight.
  @MainActor
  final class FakeButton: PopoverStatusButton {
    /// The button's rectangle in screen coordinates.
    var screenRect: CGRect? = PopoverAnchoringTests.button
    /// Every highlight it was given.
    private(set) var highlights: [Bool] = []

    /// Records the highlight.
    func setHighlighted(_ isHighlighted: Bool) {
      highlights.append(isHighlighted)
    }
  }

  /// The system's state, set by each test.
  @MainActor
  final class FakeSystem {
    /// The displays.
    var screens = PopoverAnchoringTests.screens
    /// The current event's press location, if the action comes from a mouse event.
    var press: CGPoint?
    /// The pointer.
    var pointer = CGPoint(x: 900, y: 500)
    /// The pointer while a mouse button is held.
    var held: CGPoint?
    /// The system's count of mouse presses: raised once per new press, kept for every effect
    /// of the same press.
    var pressCount: UInt64 = 0
    /// The uptime.
    var now: TimeInterval = 1_000

    /// The controller's view of it.
    var system: PopoverSystem {
      PopoverSystem(
        screens: { self.screens }, pressLocation: { self.press },
        pointerLocation: { self.pointer }, heldPointerLocation: { self.held },
        pressCount: { self.pressCount }, uptime: { self.now })
    }
  }

  /// A controller over fresh fakes, and what it reported.
  @MainActor
  final class Harness {
    /// The panel.
    let panel = FakePanel()
    /// The button.
    let button = FakeButton()
    /// The system.
    let system = FakeSystem()
    /// Every visibility reported.
    var visibility: [Bool] = []
    /// How many times it opened.
    var opens = 0
    /// The controller.
    lazy var controller = PopoverController(
      panel: panel, button: button, system: system.system,
      onVisibilityChange: { [unowned self] in self.visibility.append($0) },
      onOpen: { [unowned self] in self.opens += 1 })

    /// Presses the button with a mouse at `location` (`nil`: no mouse event; a mouse press is a
    /// new press, so it raises the press count) and advances the clock past the same-press
    /// interval first.
    func press(at location: CGPoint?) {
      system.now += 1
      if location != nil { system.pressCount += 1 }
      system.press = location
      system.held = location
      controller.buttonPressed()
    }

    /// A new mouse press at `location` that another process receives first (a neighboring
    /// menu bar item), `after` seconds from now: the global monitor's close from outside.
    func pressOutside(at location: CGPoint, after interval: TimeInterval) {
      system.now += interval
      system.pressCount += 1
      system.held = location
      controller.close(.pressOutside)
    }
  }

  /// On the main display's icon, as Phase I-1a measured it.
  static let icon = CGPoint(x: 1430, y: 1713)
  /// On the portrait display's menu bar, where the system draws its copy of the icon.
  static let portraitIcon = CGPoint(x: 3900, y: 2160)
  /// The frame below the icon for the fake content.
  static let belowIcon = CGRect(x: 1250, y: 1530, width: 360, height: 168)

  /// A press on the icon opens the panel below it (middle on the icon's, top at the menu bar's
  /// bottom), highlights the button, reports it visible and asks for the search field's focus;
  /// a second press on the same display closes it, and reports it hidden.
  @Test func pressTogglesBelowTheIcon() {
    let harness = Harness()
    harness.press(at: Self.icon)
    #expect(harness.controller.isOpen)
    #expect(harness.panel.shownFrames == [Self.belowIcon])
    #expect(harness.controller.placement?.decision.source == .button)
    #expect(harness.controller.placement?.screenIndex == 0)
    #expect(harness.button.highlights == [true])
    #expect(harness.visibility == [true])
    #expect(harness.opens == 1)
    harness.press(at: Self.icon)
    #expect(!harness.controller.isOpen)
    #expect(harness.panel.hideCount == 1)
    #expect(harness.button.highlights == [true, false])
    #expect(harness.visibility == [true, false])
    #expect(harness.controller.lastCloseReason == .button)
    harness.press(at: Self.icon)
    #expect(harness.controller.isOpen && harness.opens == 2)
  } // End of func pressTogglesBelowTheIcon()

  /// `performClick(_:)` or VoiceOver (no mouse event): anchored at the button's rectangle; a
  /// second one closes. A button with a placeholder rectangle is never the anchor: the
  /// pointer is.
  @Test func noMouseEventAnchorsAtTheButton() {
    let harness = Harness()
    harness.press(at: nil)
    #expect(harness.panel.shownFrames == [Self.belowIcon])
    #expect(
      harness.controller.placement?.decision
        == .init(anchor: .rect(PopoverAnchoringTests.button), source: .button))
    harness.press(at: nil)
    #expect(!harness.controller.isOpen)
    let placeholder = Harness()
    placeholder.button.screenRect = CGRect(x: 4152, y: 2139, width: 34, height: 30)
    placeholder.press(at: nil)
    #expect(placeholder.controller.placement?.decision.source == .pointer)
    #expect(placeholder.panel.shownFrames.first?.midX == 900)
    #expect(placeholder.panel.shownFrames.first?.maxY == 1698)
  } // End of func noMouseEventAnchorsAtTheButton()

  /// A press on the other display's copy of the icon opens there, below its menu bar, centered
  /// on the press; while open, a press on the other display moves the panel there (shown again,
  /// so it takes the keys), with no visibility change, and a press there again closes it.
  @Test func pressOnAnotherDisplayOpensOrMovesThere() {
    let harness = Harness()
    harness.press(at: Self.portraitIcon)
    #expect(harness.controller.placement?.decision.source == .click)
    #expect(harness.controller.placement?.screenIndex == 1)
    #expect(harness.panel.shownFrames == [CGRect(x: 3720, y: 1971, width: 360, height: 168)])
    harness.press(at: Self.icon)
    #expect(harness.controller.isOpen)
    #expect(harness.controller.placement?.screenIndex == 0)
    #expect(harness.panel.shownFrames.last == Self.belowIcon)
    #expect(harness.panel.hideCount == 0)
    #expect(harness.visibility == [true])
    #expect(harness.opens == 1)
    harness.press(at: Self.icon)
    #expect(!harness.controller.isOpen)
  } // End of func pressOnAnotherDisplayOpensOrMovesThere()

  /// Esc (the panel's own close), a press another process received, another app becoming
  /// active, the panel resigning key and the displays changing each close it; afterwards a
  /// press opens it again.
  @Test func everyCloseFromOutsideOrEsc() {
    let reasons: [PopoverController.CloseReason] = [
      .escape, .pressOutside, .appSwitch, .resignedKey, .displaysChanged,
    ]
    for reason in reasons {
      let harness = Harness()
      harness.press(at: Self.icon)
      harness.system.now += 1
      harness.system.held = reason == .pressOutside ? CGPoint(x: 600, y: 900) : nil
      harness.controller.close(reason)
      #expect(!harness.controller.isOpen, "\(reason)")
      #expect(harness.controller.lastCloseReason == reason)
      #expect(harness.panel.hideCount == 1)
      #expect(harness.button.highlights == [true, false])
      #expect(harness.visibility == [true, false])
      harness.controller.close(reason)
      #expect(harness.panel.hideCount == 1, "closing again does nothing")
      harness.press(at: Self.icon)
      #expect(harness.controller.isOpen, "\(reason): opens again")
    } // End of loop over the close reasons
  } // End of func everyCloseFromOutsideOrEsc()

  /// The classic toggle bug, outside close first: a press on the icon makes the panel resign
  /// key (or another process see the press) before the button's action; the action for that
  /// press leaves it closed. On the other display's icon, the same order moves it there.
  @Test func pressThatClosedFromOutsideDoesNotReopen() {
    let harness = Harness()
    harness.press(at: Self.icon)
    harness.system.now += 1
    harness.system.pressCount += 1
    harness.system.held = Self.icon
    harness.controller.close(.resignedKey)
    #expect(!harness.controller.isOpen)
    harness.system.now += 0.1
    harness.system.press = Self.icon
    harness.controller.buttonPressed()
    #expect(!harness.controller.isOpen, "the same press toggled it closed")
    #expect(harness.panel.shownFrames.count == 1)
    #expect(harness.visibility == [true, false])
    harness.press(at: Self.icon)
    #expect(harness.controller.isOpen, "the next press opens it")
    harness.system.now += 1
    harness.system.pressCount += 1
    harness.system.held = Self.portraitIcon
    harness.controller.close(.pressOutside)
    #expect(!harness.controller.isOpen)
    harness.system.now += 0.1
    harness.system.press = Self.portraitIcon
    harness.controller.buttonPressed()
    #expect(harness.controller.isOpen)
    #expect(harness.controller.placement?.screenIndex == 1)
  } // End of func pressThatClosedFromOutsideDoesNotReopen()

  /// The classic toggle bug, button action first: the outside close that follows for the same
  /// press is ignored, after opening and after moving; a press elsewhere still closes.
  @Test func outsideCloseForTheActionsOwnPressIsIgnored() {
    let harness = Harness()
    harness.press(at: Self.icon)
    harness.system.now += 0.05
    harness.controller.close(.resignedKey)
    #expect(harness.controller.isOpen)
    harness.controller.close(.pressOutside)
    #expect(harness.controller.isOpen)
    harness.press(at: Self.portraitIcon)
    #expect(harness.controller.placement?.screenIndex == 1)
    harness.system.now += 0.05
    harness.controller.close(.pressOutside)
    #expect(harness.controller.isOpen)
    harness.system.pressCount += 1
    harness.system.held = CGPoint(x: 2000, y: 900)
    harness.controller.close(.pressOutside)
    #expect(!harness.controller.isOpen)
    #expect(harness.visibility == [true, false])
  } // End of func outsideCloseForTheActionsOwnPressIsIgnored()

  /// Rapid separate presses (PLAN.md D30), outside close first: with the popover open, a press
  /// on a neighboring menu bar item closes it from outside, and a press on muxFinder's icon
  /// 0.2 s later and 20 pt away is a new press, so it opens the popover again (it is not taken
  /// for the press that closed it).
  @Test func neighborPressThenQuickIconPressOpens() {
    let harness = Harness()
    harness.press(at: Self.icon)
    #expect(harness.controller.isOpen)
    let neighbor = CGPoint(x: Self.icon.x + 20, y: Self.icon.y)
    harness.pressOutside(at: neighbor, after: 1)
    #expect(!harness.controller.isOpen)
    #expect(harness.controller.lastCloseReason == .pressOutside)
    harness.system.now += 0.2
    harness.system.pressCount += 1
    harness.system.press = Self.icon
    harness.system.held = Self.icon
    harness.controller.buttonPressed()
    #expect(harness.controller.isOpen, "a separate press opens it")
    #expect(harness.panel.shownFrames == [Self.belowIcon, Self.belowIcon])
    #expect(harness.visibility == [true, false, true])
  } // End of func neighborPressThenQuickIconPressOpens()

  /// Rapid separate presses (PLAN.md D30), button action first: a press on muxFinder's icon
  /// opens the popover, and a press on a neighboring menu bar item 0.2 s later and 20 pt away
  /// is a new press, so its close from outside closes it (it is not taken for the icon's own
  /// press).
  @Test func iconPressThenQuickNeighborPressCloses() {
    let harness = Harness()
    harness.press(at: Self.icon)
    #expect(harness.controller.isOpen)
    harness.pressOutside(at: CGPoint(x: Self.icon.x - 20, y: Self.icon.y), after: 0.2)
    #expect(!harness.controller.isOpen, "a separate press closes it")
    #expect(harness.controller.lastCloseReason == .pressOutside)
    #expect(harness.visibility == [true, false])
  }

  /// Visibility follows the panel: an occluded panel (a locked screen, a sleeping display)
  /// counts as hidden and shown again when it shows; occlusion while closed changes nothing,
  /// and a new opening starts unoccluded.
  @Test func visibilityFollowsOcclusion() {
    let harness = Harness()
    harness.controller.occlusionChanged(isVisible: true)
    #expect(harness.visibility.isEmpty)
    harness.press(at: Self.icon)
    harness.controller.occlusionChanged(isVisible: true)
    #expect(harness.visibility == [true])
    harness.controller.occlusionChanged(isVisible: false)
    #expect(harness.visibility == [true, false])
    #expect(harness.controller.isOpen)
    harness.controller.occlusionChanged(isVisible: true)
    #expect(harness.visibility == [true, false, true])
    harness.controller.occlusionChanged(isVisible: false)
    harness.press(at: Self.icon)
    #expect(harness.visibility == [true, false, true, false])
    harness.controller.occlusionChanged(isVisible: false)
    #expect(harness.visibility == [true, false, true, false])
    harness.press(at: Self.icon)
    #expect(harness.visibility == [true, false, true, false, true])
    #expect(harness.controller.isReportedVisible)
  } // End of func visibilityFollowsOcclusion()

  /// A change of the content's size while open places the panel again with its top edge at
  /// the menu bar's bottom and its middle on the anchor; the same size, or a change while
  /// closed, does nothing.
  @Test func contentSizeChangePlacesAgain() {
    let harness = Harness()
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames.isEmpty)
    harness.press(at: Self.icon)
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames.isEmpty)
    harness.panel.naturalSize = CGSize(width: 360, height: 420)
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames == [CGRect(x: 1250, y: 1278, width: 360, height: 420)])
    #expect(harness.controller.placement?.frame == harness.panel.setFrames.last)
    harness.press(at: Self.icon)
    harness.panel.naturalSize = CGSize(width: 360, height: 200)
    harness.controller.contentSizeChanged()
    #expect(harness.panel.setFrames.count == 1)
  } // End of func contentSizeChangePlacesAgain()

  /// Content taller than the display has room for below its menu bar (PLAN.md D30): before
  /// the size is read, the controller limits the content to the anchor's display's room
  /// (`PopoverPlacement.availableHeight(on:)`), so the panel holds all of it, shrunk, and is
  /// never cut off; moving to the other display, and a size change, use that display's room.
  @Test func contentIsLimitedToTheDisplaysRoom() {
    let harness = Harness()
    harness.panel.naturalSize = CGSize(width: 360, height: 2400)
    let mainRoom = PopoverPlacement.availableHeight(on: PopoverAnchoringTests.main)
    let portraitRoom = PopoverPlacement.availableHeight(on: PopoverAnchoringTests.portrait)
    #expect(mainRoom == 1690 && portraitRoom == 1882)
    harness.press(at: Self.icon)
    #expect(harness.panel.limitsAtSizeReads == [mainRoom])
    #expect(harness.panel.shownFrames == [CGRect(x: 1250, y: 8, width: 360, height: 1690)])
    harness.press(at: Self.portraitIcon)
    #expect(harness.controller.placement?.screenIndex == 1)
    #expect(harness.panel.limitsAtSizeReads == [mainRoom, portraitRoom])
    #expect(harness.panel.shownFrames.last == CGRect(x: 3720, y: 257, width: 360, height: 1882))
    harness.panel.naturalSize = CGSize(width: 360, height: 300)
    harness.controller.contentSizeChanged()
    #expect(harness.panel.limitsAtSizeReads.last == portraitRoom)
    #expect(harness.panel.setFrames == [CGRect(x: 3720, y: 1839, width: 360, height: 300)])
  } // End of func contentIsLimitedToTheDisplaysRoom()
}
