import CoreGraphics
import Foundation

/// Where the session switcher goes (PLAN.md D32, Phase I-3b): `width` points wide, centered
/// horizontally on the display with the keyboard focus, its top edge `topFraction` of that
/// display's visible height below the visible frame's top (Spotlight-like, in its upper part),
/// growing downwards, no taller than the room left above the visible frame's bottom.
///
/// Points in AppKit's global screen coordinates, as `PopoverPlacement`; a pure value
/// computation over `PopoverPlacement.Screen`, so tests never need an `NSScreen`.
public enum SwitcherPlacement {
  /// The switcher's width, in points (recorded in PLAN.md D32): wide enough for a session's
  /// name, its host's name and its detail text on one line.
  public static let width: CGFloat = 540
  /// How far below the visible frame's top the switcher's top edge sits, as a fraction of the
  /// visible frame's height.
  public static let topFraction: CGFloat = 0.18

  /// The y of the switcher's top edge on `screen`, on the display's pixel grid.
  public static func top(on screen: PopoverPlacement.Screen) -> CGFloat {
    let visible = screen.visibleFrame
    let scale = max(1, screen.backingScaleFactor)
    return ((visible.maxY - visible.height * topFraction) * scale).rounded() / scale
  }

  /// The tallest the switcher may be on `screen`: from its top edge down to
  /// `PopoverPlacement.screenInset` above the visible frame's bottom; 0 when there is none.
  public static func availableHeight(on screen: PopoverPlacement.Screen) -> CGFloat {
    max(0, top(on: screen) - (screen.visibleFrame.minY + PopoverPlacement.screenInset))
  }

  /// The switcher's frame on `screen` for content of `contentSize`: centered horizontally on
  /// the visible frame (the left edge on the pixel grid), no wider than the visible frame
  /// minus both insets and no taller than `availableHeight(on:)`, its top at `top(on:)`.
  public static func frame(contentSize: CGSize, screen: PopoverPlacement.Screen) -> CGRect {
    let visible = screen.visibleFrame
    let inset = PopoverPlacement.screenInset
    let width = max(0, min(contentSize.width, visible.width - 2 * inset))
    let height = max(0, min(contentSize.height, availableHeight(on: screen)))
    let scale = max(1, screen.backingScaleFactor)
    let x = ((visible.midX - width / 2) * scale).rounded() / scale
    let top = top(on: screen)
    return CGRect(x: x, y: top - height, width: width, height: height)
  } // End of static func frame(contentSize:screen:)

  /// The index in `screens` of the display with the keyboard focus: the one sharing the most
  /// area with the frontmost app's frontmost window (`focusedWindow`), else the one whose
  /// frame is `mainScreen` (`NSScreen.main`), else the one holding `pointer`, else the first;
  /// `nil` only for no displays.
  public static func screenIndex(
    focusedWindow: CGRect?,
    mainScreen: CGRect?,
    pointer: CGPoint,
    in screens: [PopoverPlacement.Screen]
  ) -> Int? {
    guard !screens.isEmpty else { return nil }
    if let window = focusedWindow {
      let areas = screens.map { screen -> CGFloat in
        let shared = screen.frame.intersection(window)
        return shared.isNull ? 0 : shared.width * shared.height
      }
      if let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 {
        return best
      }
    }
    if let mainScreen, let index = screens.firstIndex(where: { $0.frame == mainScreen }) {
      return index
    }
    return PopoverPlacement.screenIndex(holding: pointer, in: screens) ?? 0
  } // End of static func screenIndex(focusedWindow:mainScreen:pointer:in:)
}

/// What `SwitcherController` reads from the system, as closures so tests pass fixed values.
public struct SwitcherSystem {
  /// The displays, in `NSScreen.screens` order.
  public var screens: @MainActor () -> [PopoverPlacement.Screen]
  /// The index in those displays of the one with the keyboard focus
  /// (`SwitcherPlacement.screenIndex(focusedWindow:mainScreen:pointer:in:)`), or `nil`.
  public var focusedScreenIndex: @MainActor ([PopoverPlacement.Screen]) -> Int?
  /// The longest time between two clicks of one click sequence, in seconds
  /// (`NSEvent.doubleClickInterval`).
  public var doubleClickInterval: @MainActor () -> TimeInterval
  /// Runs an action on the main actor once a delay, in seconds, has passed.
  public var runAfter: @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void

  /// A system from its parts.
  public init(
    screens: @escaping @MainActor () -> [PopoverPlacement.Screen],
    focusedScreenIndex: @escaping @MainActor ([PopoverPlacement.Screen]) -> Int?,
    doubleClickInterval: @escaping @MainActor () -> TimeInterval,
    runAfter: @escaping @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> Void
  ) {
    self.screens = screens
    self.focusedScreenIndex = focusedScreenIndex
    self.doubleClickInterval = doubleClickInterval
    self.runAfter = runAfter
  }
}

/// Opens and closes the session switcher's panel (PLAN.md D32, Phase I-3b) over
/// `PopoverPanelSurface` (the same seam as the popover's panel) and `SwitcherSystem`, so tests
/// drive it with fakes.
///
/// - **Toggle:** the session switcher shortcut opens it on the display with the keyboard focus
///   (`SwitcherPlacement`) and closes it when open.
/// - **Closing:** Esc (the panel's own close), a mouse press another process received, another
///   app becoming active, the panel resigning key, the displays changing, the popover opening
///   (only one of the two shows) and an Open or New session it started succeeding. A close from
///   outside made by a press on muxFinder's status item button (`isStatusItemPress`) is left
///   to that press's button action, which opens the popover, which closes the switcher
///   (`popoverOpened`) once the popover is reported visible; so in either order of the press's
///   two effects the handoff never reaches the engine as a close (PLAN.md D22, D32).
/// - **Size:** the content lays itself out no taller than the room below the switcher's top
///   edge; while open, a change of the content's size places it again with the same top edge.
/// - **A click's hold** (`holdForClick()`, Phase I-5 review): a click that activated a row
///   keeps the panel at least as tall as it was, and holds back a close for the action's
///   success, another app becoming active or the panel resigning key, until the system's
///   double-click interval has passed, so the rest of that click's sequence lands on the panel
///   (which ignores it, `SwitcherClickSequence`), never on the window behind it. Every other
///   close is made at once and ends the hold, as does each close.
/// - **Visibility** (`onVisibilityChange`, the model's `switcherVisibilityChanged(_:)`):
///   visible while open and not fully occluded, reported on changes only and, when opening,
///   before the panel shows, so the model can close the popover while the engine still sees one
///   of the two visible (PLAN.md D22).
@MainActor
public final class SwitcherController {
  /// Why the switcher closed.
  public enum CloseReason: String, Sendable, Hashable {
    /// Esc, or anything else that closed the panel itself.
    case escape
    /// A mouse press another process received.
    case pressOutside
    /// Another app became active (iTerm2 taking the focus included).
    case appSwitch
    /// The panel stopped being the key window.
    case resignedKey
    /// The displays changed.
    case displaysChanged
    /// The session switcher shortcut was pressed while it was open.
    case shortcut
    /// The popover opened (only one of the two shows at a time).
    case popoverOpened
    /// An Open or New session started in the switcher succeeded.
    case actionSucceeded

    /// Whether this close comes from outside the switcher, so it may be a press on muxFinder's
    /// status item button (left to the popover that press opens).
    var isOutside: Bool {
      switch self {
      case .pressOutside, .appSwitch, .resignedKey: true
      case .escape, .displaysChanged, .shortcut, .popoverOpened, .actionSucceeded: false
      }
    }

    /// Whether this close waits for the end of a click's hold (`holdForClick()`): the ones the
    /// clicked row's own action brings, its success and iTerm2 coming forward with it (another
    /// app active, the panel no longer key). Esc, the shortcut, a press outside, a display
    /// change and the popover opening never wait.
    var waitsForClickHold: Bool {
      switch self {
      case .actionSucceeded, .appSwitch, .resignedKey: true
      case .escape, .pressOutside, .displaysChanged, .shortcut, .popoverOpened: false
      }
    }
  }

  /// A click's hold, while it lasts (`holdForClick()`).
  private struct ClickHold {
    /// Tells holds apart, so the end of an earlier one changes nothing.
    let number: Int
    /// The first close that waits for its end.
    var pendingClose: CloseReason?
  }

  /// Whether the switcher is open.
  public private(set) var isOpen = false
  /// The display it opened on, while open (or when it last closed).
  public private(set) var screen: PopoverPlacement.Screen?
  /// Its frame, while open (or when it last closed).
  public private(set) var frame: CGRect?
  /// The visibility last reported.
  public private(set) var isReportedVisible = false
  /// Why it last closed.
  public private(set) var lastCloseReason: CloseReason?
  /// Whether a click's hold lasts (`holdForClick()`).
  public var isHoldingForClick: Bool { clickHold != nil }
  /// The close waiting for the end of the click's hold, if any.
  public var pendingClose: CloseReason? { clickHold?.pendingClose }

  /// The panel.
  private let panel: any PopoverPanelSurface
  /// The system's state.
  private let system: SwitcherSystem
  /// Told when the switcher becomes visible or hidden.
  private let onVisibilityChange: @MainActor (Bool) -> Void
  /// Called each time it opens, after the panel shows (the search field takes the focus).
  private let onOpen: @MainActor () -> Void
  /// Whether a mouse press on muxFinder's status item button is in progress now
  /// (`PopoverController.isButtonPressHeld`).
  private let isStatusItemPress: @MainActor () -> Bool
  /// Whether the open panel is fully occluded.
  private var isOccluded = false
  /// The click's hold, while it lasts.
  private var clickHold: ClickHold?
  /// How many holds were made (numbers them).
  private var holdCount = 0

  /// A controller over its parts; nothing shows until `toggle()` or `open()`.
  /// `isStatusItemPress` says whether a press on muxFinder's status item button is in progress
  /// (none by default).
  public init(
    panel: any PopoverPanelSurface,
    system: SwitcherSystem,
    onVisibilityChange: @escaping @MainActor (Bool) -> Void,
    onOpen: @escaping @MainActor () -> Void = {},
    isStatusItemPress: @escaping @MainActor () -> Bool = { false }
  ) {
    self.panel = panel
    self.system = system
    self.onVisibilityChange = onVisibilityChange
    self.onOpen = onOpen
    self.isStatusItemPress = isStatusItemPress
  }

  /// A controller for `model` (the app's `SessionSwitcher` and the tests share this glue): its
  /// visibility goes to `switcherVisibilityChanged(_:)`, each opening focuses the search
  /// field, the model's `isStatusItemPressHeld` says whether a press on the status item button
  /// is in progress, and the model's `toggleSwitcher`, `closeSwitcher` and
  /// `holdSwitcherForClick` reach it.
  public static func make(
    for model: AppModel,
    panel: any PopoverPanelSurface,
    system: SwitcherSystem
  ) -> SwitcherController {
    let controller = SwitcherController(
      panel: panel, system: system,
      onVisibilityChange: { [weak model] isVisible in
        model?.switcherVisibilityChanged(isVisible)
      },
      onOpen: { [weak model] in model?.focusSwitcherSearch() },
      isStatusItemPress: { [weak model] in model?.isStatusItemPressHeld?() ?? false })
    model.toggleSwitcher = { [weak controller] in controller?.toggle() }
    model.closeSwitcher = { [weak controller] reason in controller?.close(reason) }
    model.holdSwitcherForClick = { [weak controller] in controller?.holdForClick() }
    return controller
  } // End of static func make(for:panel:system:)

  /// The session switcher shortcut: closes the open switcher, or opens it.
  public func toggle() {
    if isOpen {
      close(.shortcut)
    } else {
      open()
    }
  }

  /// Opens the switcher on the display with the keyboard focus. Reports the visibility first
  /// (the model empties the search field and closes the popover), then lays the content out no
  /// taller than that display has room for, shows the panel and calls `onOpen`. Does nothing
  /// while open or with no display.
  public func open() {
    guard !isOpen else { return }
    let screens = system.screens()
    guard !screens.isEmpty else { return }
    let index = system.focusedScreenIndex(screens).flatMap {
      screens.indices.contains($0) ? $0 : nil
    }
    let screen = screens[index ?? 0]
    self.screen = screen
    isOpen = true
    isOccluded = false
    lastCloseReason = nil
    updateVisibility()
    panel.maximumContentHeight = SwitcherPlacement.availableHeight(on: screen)
    let frame = SwitcherPlacement.frame(contentSize: panel.contentSize, screen: screen)
    self.frame = frame
    panel.show(at: frame)
    onOpen()
  } // End of func open()

  /// Closes the switcher for `reason`. A close from outside made while a press on muxFinder's
  /// status item button is in progress is left to that press's button action: it opens the
  /// popover, which closes the switcher (`popoverOpened`) after the popover reported visible,
  /// so the engine never hears the handoff (PLAN.md D22, D32). While a click's hold lasts, a
  /// close that waits for it (`CloseReason.waitsForClickHold`) is made when it ends (the
  /// first one asked); any other close is made at once and ends the hold. Does nothing while
  /// closed.
  public func close(_ reason: CloseReason) {
    guard isOpen else { return }
    if reason.isOutside, isStatusItemPress() { return }
    if var hold = clickHold, reason.waitsForClickHold {
      if hold.pendingClose == nil { hold.pendingClose = reason }
      clickHold = hold
      return
    }
    endClickHold()
    isOpen = false
    lastCloseReason = reason
    panel.hide()
    updateVisibility()
  } // End of func close(_:)

  /// A click activated a row (`AppModel.clickSwitcherItem(_:)` calls this before the row
  /// acts): until the system's double-click interval has passed, the content lays itself out
  /// no shorter than the panel is now (`PopoverPanelSurface.minimumContentHeight`; a shrink,
  /// such as the New session form replacing a taller list, waits; growth does not), and a close
  /// for the action's success, another app becoming active or the panel resigning key waits
  /// (`close(_:)`), so the rest of that click's sequence lands on the panel, which ignores it
  /// (`SwitcherClickSequence`), instead of on the window behind. A click during a hold starts
  /// a new one from the panel's frame then, keeping a close already waiting. Does nothing while
  /// closed.
  public func holdForClick() {
    guard isOpen, let frame else { return }
    holdCount += 1
    let number = holdCount
    clickHold = ClickHold(number: number, pendingClose: clickHold?.pendingClose)
    panel.minimumContentHeight = frame.height
    system.runAfter(system.doubleClickInterval()) { [weak self] in
      self?.clickHoldEnded(number)
    }
  }

  /// Hold number `number`'s interval passed: when it is the one lasting, it ends, the waiting
  /// close (if any) is made, and the panel takes its content's size. A hold already ended (a
  /// close, or a later click's) changes nothing.
  private func clickHoldEnded(_ number: Int) {
    guard let hold = clickHold, hold.number == number else { return }
    endClickHold()
    if let reason = hold.pendingClose { close(reason) }
    contentSizeChanged()
  }

  /// Ends the click's hold, if any: the content takes its natural height again.
  private func endClickHold() {
    guard clickHold != nil else { return }
    clickHold = nil
    panel.minimumContentHeight = nil
  }

  /// The content's size changed: while open, places the panel again for the new size on the
  /// same display, keeping its top edge.
  public func contentSizeChanged() {
    guard isOpen, let screen else { return }
    let frame = SwitcherPlacement.frame(contentSize: panel.contentSize, screen: screen)
    guard frame != self.frame else { return }
    self.frame = frame
    panel.setFrame(frame)
  }

  /// The panel's occlusion changed: visible means some part of it shows.
  public func occlusionChanged(isVisible: Bool) {
    guard isOpen else { return }
    isOccluded = !isVisible
    updateVisibility()
  }

  /// Reports the visibility when it changed: open and not fully occluded.
  private func updateVisibility() {
    let isVisible = isOpen && !isOccluded
    guard isVisible != isReportedVisible else { return }
    isReportedVisible = isVisible
    onVisibilityChange(isVisible)
  }
}
