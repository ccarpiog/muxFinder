import AppKit
import SwiftUI
import Testing

@testable import MuxFinderUI

/// The popover's height limit (PLAN.md D30): content taller than the display's room below the
/// menu bar lays itself out no taller than that room, its host list shrinking and scrolling,
/// so the panel never cuts off the footer; content that fits keeps its natural size. Measured
/// in hosting views that are never put in a window (no window, panel or status item).
@Suite("Popover height limit")
@MainActor
struct PopoverHeightLimitTests {
  /// How far two measured heights may differ, in points (layout rounding).
  static let tolerance: CGFloat = 0.5

  /// A model whose popover lists hosts with sessions, so its host list has height to give up.
  static func model() -> AppModel {
    AppModel(fixture: PreviewFixtures.overview)
  }

  /// `PopoverView`'s height when offered `height` (`nil`: its natural height), at its width.
  static func popoverHeight(_ model: AppModel, offered height: CGFloat?) -> CGFloat {
    let controller = NSHostingController(rootView: PopoverView(model: model, isLive: false))
    controller.view.layoutSubtreeIfNeeded()
    let offered = CGSize(width: PopoverView.width, height: height ?? .greatestFiniteMagnitude)
    return controller.sizeThatFits(in: offered).height
  }

  /// The panel root's fitting size with limit `maximumHeight`, in a hosting view (as
  /// `PopoverPanelHost.contentSize` measures it); the root view is then changed to
  /// `changedTo` (when given) and measured again, as the controller's limit changes it.
  static func rootHeights(
    _ model: AppModel, maximumHeight: CGFloat?, changedTo changed: CGFloat? = nil
  ) -> [CGFloat] {
    let host = NSHostingView(
      rootView: PopoverPanelRoot(model: model, maximumHeight: maximumHeight, onSizeChange: {}))
    host.layoutSubtreeIfNeeded()
    var heights = [host.fittingSize.height]
    if let changed {
      host.rootView.maximumHeight = changed
      heights.append(host.fittingSize.height)
    }
    return heights
  } // End of static func rootHeights(_:maximumHeight:changedTo:)

  /// The offer: nothing for content that fits or with no limit, else the limit.
  @Test func offeredHeight() {
    #expect(PopoverHeightLimit.offeredHeight(natural: 500, maximumHeight: nil) == nil)
    #expect(PopoverHeightLimit.offeredHeight(natural: 500, maximumHeight: 500) == nil)
    #expect(PopoverHeightLimit.offeredHeight(natural: 500, maximumHeight: 800) == nil)
    #expect(PopoverHeightLimit.offeredHeight(natural: 500, maximumHeight: 320) == 320)
    #expect(PopoverHeightLimit.offeredHeight(natural: 500, maximumHeight: -4) == 0)
  }

  /// Offered less than its natural height, the popover shrinks to the offer (its host list
  /// gives up the height); offered its natural height or more, it keeps its natural height.
  @Test func popoverShrinksItsHostListToTheOffer() {
    let model = Self.model()
    let natural = Self.popoverHeight(model, offered: nil)
    #expect(natural > 200, "the fixture's popover has a host list to shrink")
    let offer = natural - 120
    let shrunk = Self.popoverHeight(model, offered: offer)
    #expect(abs(shrunk - offer) <= Self.tolerance, "natural \(natural), offered \(offer)")
    #expect(abs(Self.popoverHeight(model, offered: natural + 300) - natural) <= Self.tolerance)
  }

  /// The panel's root: with no limit, or one the content fits in, the popover's natural size
  /// (Phase 14's sizing unchanged); with a lower limit, exactly the limit, also when the
  /// limit is set on the existing root view (as the controller does before measuring).
  @Test func panelRootIsNoTallerThanItsLimit() {
    let model = Self.model()
    let natural = Self.popoverHeight(model, offered: nil)
    let unlimited = Self.rootHeights(model, maximumHeight: nil)
    #expect(abs(unlimited[0] - natural) <= Self.tolerance)
    let roomy = Self.rootHeights(model, maximumHeight: natural + 200)
    #expect(abs(roomy[0] - natural) <= Self.tolerance)
    let limit = natural - 120
    let limited = Self.rootHeights(model, maximumHeight: limit)
    #expect(abs(limited[0] - limit) <= Self.tolerance, "natural \(natural), limit \(limit)")
    let changed = Self.rootHeights(model, maximumHeight: nil, changedTo: limit)
    #expect(abs(changed[0] - natural) <= Self.tolerance)
    #expect(abs(changed[1] - limit) <= Self.tolerance, "natural \(natural), limit \(limit)")
  } // End of func panelRootIsNoTallerThanItsLimit()
}
