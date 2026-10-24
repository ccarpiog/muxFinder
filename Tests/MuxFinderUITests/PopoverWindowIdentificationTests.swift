import AppKit
import Testing

@testable import MuxFinderUI

/// Which window the popover placement diagnostic takes for the popover, and so may close
/// (`PopoverWindowIdentification`, PLAN.md Phase I-1): never a status-bar window, whether a
/// replica with no button or the real item's window with its button; the window holding the
/// live `PopoverView` first, at any level; else a newly visible normal-level window.
@Suite("Popover window identification")
@MainActor
struct PopoverWindowIdentificationTests {
  /// Shorthand.
  typealias Identification = PopoverWindowIdentification

  /// A window newly visible since the click, described by its parts.
  static func window(
    _ classNames: [String], level: Int, button: Bool = false, livePopover: Bool = false,
    visible: Bool = true, visibleBefore: Bool = false
  ) -> Identification.Window {
    Identification.Window(
      classNames: classNames, level: level, isVisible: visible,
      wasVisibleBeforeClick: visibleBefore, holdsStatusItemButton: button,
      holdsLivePopover: livePopover)
  }

  /// AppKit's status item window classes, as recorded in Phase I-1a.
  static let statusBarClasses = ["NSStatusBarWindow", "NSPanel", "NSWindow", "NSResponder"]
  /// SwiftUI's or muxFinder's own popover window classes.
  static let panelClasses = ["_TtC7SwiftUI18SomePopoverWindow", "NSPanel", "NSWindow"]

  /// A replica status-bar window (level 25, no button, newly visible) is never the popover,
  /// not even under a key-value observing subclass; a status-bar window holding the button is
  /// never the popover either, nor one that somehow held the live popover view.
  @Test func statusBarWindowsAreNeverThePopover() {
    let replica = Self.window(Self.statusBarClasses, level: 25)
    #expect(Identification.isStatusBarWindow(replica))
    #expect(Identification.match(replica) == nil)
    #expect(Identification.popover(in: [replica]) == nil)
    let observed = Self.window(
      ["NSKVONotifying_NSStatusBarWindow"] + Self.statusBarClasses, level: 25)
    #expect(Identification.match(observed) == nil)
    let realItem = Self.window(Self.statusBarClasses, level: 25, button: true)
    #expect(Identification.match(realItem) == nil)
    let buttonAtNormalLevel = Self.window(Self.panelClasses, level: 0, button: true)
    #expect(Identification.match(buttonAtNormalLevel) == nil)
    let claimingLive = Self.window(Self.statusBarClasses, level: 25, livePopover: true)
    #expect(Identification.match(claimingLive) == nil)
    let six = Array(repeating: replica, count: 6)
    #expect(Identification.popover(in: [realItem] + six) == nil)
  } // End of func statusBarWindowsAreNeverThePopover()

  /// A newly visible normal-level window is a candidate (the fallback); one at or above the
  /// status-bar level is not without the live popover view; hidden windows and windows
  /// visible before the click are not.
  @Test func normalLevelWindowIsTheFallback() {
    let normal = Self.window(Self.panelClasses, level: 0)
    #expect(!Identification.isStatusBarWindow(normal))
    #expect(Identification.match(normal) == .newlyVisible)
    let replica = Self.window(Self.statusBarClasses, level: 25)
    let found = Identification.popover(in: [replica, replica, normal])
    #expect(found?.index == 2)
    #expect(found?.match == .newlyVisible)
    #expect(Identification.match(Self.window(Self.panelClasses, level: 24)) == .newlyVisible)
    #expect(Identification.match(Self.window(Self.panelClasses, level: 25)) == nil)
    #expect(Identification.match(Self.window(Self.panelClasses, level: 101)) == nil)
    #expect(Identification.match(Self.window(Self.panelClasses, level: 0, visible: false)) == nil)
    #expect(
      Identification.match(Self.window(Self.panelClasses, level: 0, visibleBefore: true)) == nil)
  } // End of func normalLevelWindowIsTheFallback()

  /// The window holding the live popover view wins over an earlier fallback match, at any
  /// level, but only when newly visible.
  @Test func livePopoverWindowIsIdentifiedFirst() {
    let other = Self.window(Self.panelClasses, level: 0)
    let live = Self.window(Self.panelClasses, level: 101, livePopover: true)
    #expect(Identification.match(live) == .livePopover)
    let found = Identification.popover(in: [
      Self.window(Self.statusBarClasses, level: 25), other, live,
    ])
    #expect(found?.index == 2)
    #expect(found?.match == .livePopover)
    let openBefore = Self.window(
      Self.panelClasses, level: 25, livePopover: true, visibleBefore: true)
    #expect(Identification.match(openBefore) == nil)
  } // End of func livePopoverWindowIsIdentifiedFirst()

  /// The live popover view is found anywhere under a view, and only there.
  @Test func livePopoverLookupFindsTheTrackingView() {
    let root = NSView()
    let middle = NSView()
    root.addSubview(middle)
    #expect(!LivePopoverLookup.holdsLivePopover(root))
    #expect(!LivePopoverLookup.holdsLivePopover(nil))
    let tracking = PopoverWindowTrackingView(model: AppModel(fixture: PreviewFixtures.overview))
    middle.addSubview(tracking)
    #expect(LivePopoverLookup.holdsLivePopover(root))
    #expect(LivePopoverLookup.holdsLivePopover(tracking))
    #expect(!LivePopoverLookup.holdsLivePopover(NSView()))
  } // End of func livePopoverLookupFindsTheTrackingView()
}
