import CoreGraphics
import Foundation

/// Where a New session window opening came from (PLAN.md D34): the frame of the popover or
/// session switcher panel that opened it and that panel's display, in AppKit's global screen
/// coordinates. A fresh opening puts the window's top centre at the frame's top centre.
public struct NewSessionWindowSource: Sendable, Hashable {
  /// The popover's or the switcher's frame.
  public var frame: CGRect
  /// Its display.
  public var screen: PopoverPlacement.Screen

  /// A source from its parts.
  public init(frame: CGRect, screen: PopoverPlacement.Screen) {
    self.frame = frame
    self.screen = screen
  }
}

/// Which entry point made the New session draft (PLAN.md D34): the creation and the attach of
/// a draft the session switcher made, and the attach its "Open existing" starts, are the
/// switcher's to follow (D32, `switcherCreation`, `AppModel.switcherExistingOpened(_:target:)`).
public enum NewSessionOrigin: Sendable, Hashable {
  /// The popover (⌘N, the footer's "New session").
  case popover
  /// The session switcher (⌘N, the New session row).
  case switcher
}

/// A request to show the New session window or bring it forward (PLAN.md D34), numbered so
/// its controller carries each one out once.
public struct NewSessionWindowRequest: Sendable, Hashable {
  /// What the request asks for.
  public enum Kind: Sendable, Hashable {
    /// The user opened it from the popover or the switcher: in front and key. A fresh opening
    /// is placed from `source` (`nil`: where the switcher would show on the first display); a
    /// window already showing keeps its frame (the user's move stands).
    case open(source: NewSessionWindowSource?)
    /// A creation whose window was closed ended in a collision or a failure: back in front at
    /// its last frame, not key, so it never takes typing from the app in front.
    case outcome

    /// Whether the window becomes key.
    public var makesKey: Bool {
      switch self {
      case .open: return true
      case .outcome: return false
      }
    }
  }

  /// Tells requests apart (increases with each one).
  public var number: Int
  /// What it asks for.
  public var kind: Kind

  /// A request from its parts.
  public init(number: Int, kind: Kind) {
    self.number = number
    self.kind = kind
  }
}

/// The New session window as the model has it (PLAN.md D34): whether it shows, and the latest
/// request to show it or bring it forward. The view layer observes it
/// (`AppModel.newSessionWindowChanged`); the model never needs the window itself.
public struct NewSessionWindowState: Sendable, Hashable {
  /// Whether the window shows.
  public var isShown: Bool
  /// The latest request to show it or bring it forward; `nil` before the first.
  public var request: NewSessionWindowRequest?

  /// A state from its parts (hidden, no request, by default).
  public init(isShown: Bool = false, request: NewSessionWindowRequest? = nil) {
    self.isShown = isShown
    self.request = request
  }
}

/// Where the New session window goes (PLAN.md D34): a pure value computation over
/// `PopoverPlacement.Screen`, in AppKit's global screen coordinates, so tests never need an
/// `NSScreen`. Sizes and frames are the window's own (its title bar included).
///
/// - **A fresh opening** puts the window's top centre at the top centre of the popover or
///   switcher it came from, clamped into that display's visible frame (no frame is remembered
///   across closes).
/// - **While it shows** its frame is the user's: opening it again only brings it forward.
/// - **A comeback** (a failure after the window was closed) uses its last frame, on the display
///   it was on.
/// - **Size:** `width` wide; the height follows the content with the top edge fixed, the frame
///   clamped into the visible frame of the display it is on.
public enum NewSessionWindowPlacement {
  /// The window's content width, in points: the width the form had in the session switcher.
  public static let width = SwitcherPlacement.width

  /// The frame of a fresh opening for a window of `size` from `source`: its top centre at the
  /// source's top centre (the left edge on the pixel grid), clamped into the source display's
  /// visible frame.
  public static func freshFrame(size: CGSize, source: NewSessionWindowSource) -> CGRect {
    let scale = max(1, source.screen.backingScaleFactor)
    let x = ((source.frame.midX - size.width / 2) * scale).rounded() / scale
    let frame = CGRect(
      x: x, y: source.frame.maxY - size.height, width: size.width, height: size.height)
    return clamped(frame, into: source.screen.visibleFrame)
  }

  /// The source of an opening with none (no popover or switcher frame known): where the
  /// session switcher would show content of `size` on `screen` (`SwitcherPlacement`).
  public static func fallbackSource(
    size: CGSize, screen: PopoverPlacement.Screen
  ) -> NewSessionWindowSource {
    NewSessionWindowSource(
      frame: SwitcherPlacement.frame(contentSize: size, screen: screen), screen: screen)
  }

  /// `frame` moved (never resized beyond `visible`) so it lies inside `visible`: no wider or
  /// taller than it, its left and bottom edges no lower than its own, its right and top edges
  /// no higher.
  public static func clamped(_ frame: CGRect, into visible: CGRect) -> CGRect {
    let width = min(frame.width, visible.width)
    let height = min(frame.height, visible.height)
    let x = min(max(frame.minX, visible.minX), visible.maxX - width)
    let y = min(max(frame.minY, visible.minY), visible.maxY - height)
    return CGRect(x: x, y: y, width: width, height: height)
  }

  /// `frame` with the new `height`, its top edge and left edge kept, clamped into `visible`
  /// (a window that would reach below the visible frame moves up as far as it must).
  public static func resized(_ frame: CGRect, height: CGFloat, visibleFrame: CGRect) -> CGRect {
    let resized = CGRect(
      x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    return clamped(resized, into: visibleFrame)
  }

  /// The display in `screens` sharing the most area with `frame`, or `nil` when none does.
  public static func screen(
    for frame: CGRect, in screens: [PopoverPlacement.Screen]
  ) -> PopoverPlacement.Screen? {
    let areas = screens.map { screen -> CGFloat in
      let shared = screen.frame.intersection(frame)
      return shared.isNull ? 0 : shared.width * shared.height
    }
    guard let best = areas.indices.max(by: { areas[$0] < areas[$1] }), areas[best] > 0 else {
      return nil
    }
    return screens[best]
  } // End of static func screen(for:in:)

  /// The frame a request puts the window at, for a window of `size`: while it shows
  /// (`shownFrame`), that frame, whatever the request (the user's move stands); otherwise a
  /// fresh opening's frame from the request's source (or the fallback source on the first of
  /// `screens`), and for a comeback after a failure its `lastFrame` with the new height on the
  /// display it was on (a fresh frame when it was on none of `screens`). `nil` only when there
  /// is nothing to place it on.
  public static func frame(
    for kind: NewSessionWindowRequest.Kind,
    shownFrame: CGRect?,
    lastFrame: CGRect?,
    size: CGSize,
    screens: [PopoverPlacement.Screen]
  ) -> CGRect? {
    if let shownFrame { return shownFrame }
    let fallback = screens.first.map { fallbackSource(size: size, screen: $0) }
    switch kind {
    case .open(let source):
      return (source ?? fallback).map { freshFrame(size: size, source: $0) }
    case .outcome:
      if let lastFrame, let screen = screen(for: lastFrame, in: screens) {
        return resized(lastFrame, height: size.height, visibleFrame: screen.visibleFrame)
      }
      return fallback.map { freshFrame(size: size, source: $0) }
    }
  } // End of static func frame(for:shownFrame:lastFrame:size:screens:)
}

/// The New session window as `NewSessionWindowController` drives it: `NewSessionWindow`'s
/// panel in the app, a fake in tests.
@MainActor
public protocol NewSessionWindowSurface: AnyObject {
  /// The window's frame size for its content at its natural height (the title bar included),
  /// `NewSessionWindowPlacement.width` wide.
  var fittingFrameSize: CGSize { get }
  /// The window's frame now (the user may have moved it).
  var frame: CGRect { get }
  /// Puts the window at `frame` in front, and makes it key when `makingKey` (the app stays
  /// inactive: the window is a non-activating panel).
  func show(at frame: CGRect, makingKey: Bool)
  /// Moves or resizes the shown window.
  func setFrame(_ frame: CGRect)
  /// Takes the window off screen.
  func hide()
}

/// Shows, places and hides the New session window (PLAN.md D34) as the model's
/// `newSessionWindow` says, over `NewSessionWindowSurface`, so tests drive it with fakes.
///
/// - **A request** (`NewSessionWindowRequest`) is carried out once: a fresh opening is placed
///   from its source (`NewSessionWindowPlacement`), an opening while it shows only brings it
///   forward (key, its frame kept), a comeback after a failure shows it at its last frame
///   without making it key.
/// - **Hidden** in the model: ordered out, its frame remembered for a comeback.
/// - **Size:** while it shows, a change of the content's height resizes it with its top edge
///   fixed, clamped into the visible frame of the display it is on.
///
/// Installed by the app shell only (`NewSessionWindow`): the self-tests and preview mode have
/// none, and the model works without it.
@MainActor
public final class NewSessionWindowController {
  /// Whether the window shows.
  public private(set) var isShown = false
  /// Its frame when it last showed or hid (the user's move included); a comeback uses it.
  public private(set) var lastFrame: CGRect?

  /// The window.
  private let surface: any NewSessionWindowSurface
  /// The displays, in `NSScreen.screens` order.
  private let screens: @MainActor () -> [PopoverPlacement.Screen]
  /// The model's window state.
  private let state: @MainActor () -> NewSessionWindowState
  /// The number of the last request carried out.
  private var handledRequest: Int?

  /// A controller over its parts; nothing shows until the state asks for it.
  public init(
    surface: any NewSessionWindowSurface,
    screens: @escaping @MainActor () -> [PopoverPlacement.Screen],
    state: @escaping @MainActor () -> NewSessionWindowState
  ) {
    self.surface = surface
    self.screens = screens
    self.state = state
  }

  /// A controller following `model` (the app's `NewSessionWindow` and the tests share this
  /// glue): it reads `model.newSessionWindow` and the model's `newSessionWindowChanged` reaches
  /// `update()`; the current state is applied at once.
  public static func make(
    for model: AppModel,
    surface: any NewSessionWindowSurface,
    screens: @escaping @MainActor () -> [PopoverPlacement.Screen]
  ) -> NewSessionWindowController {
    let controller = NewSessionWindowController(
      surface: surface, screens: screens,
      state: { [weak model] in model?.newSessionWindow ?? NewSessionWindowState() })
    model.newSessionWindowChanged = { [weak controller] in controller?.update() }
    controller.update()
    return controller
  } // End of static func make(for:surface:screens:)

  /// The model's window state changed: hidden, the window is ordered out (its frame kept for a
  /// comeback); shown with a request not carried out yet, the window is placed
  /// (`NewSessionWindowPlacement.frame(for:shownFrame:lastFrame:size:screens:)`) and shown, key
  /// for an opening, not key for a comeback.
  public func update() {
    let state = state()
    guard state.isShown else {
      guard isShown else { return }
      lastFrame = surface.frame
      isShown = false
      surface.hide()
      return
    }
    guard let request = state.request, request.number != handledRequest else { return }
    handledRequest = request.number
    guard
      let frame = NewSessionWindowPlacement.frame(
        for: request.kind, shownFrame: isShown ? surface.frame : nil, lastFrame: lastFrame,
        size: surface.fittingFrameSize, screens: screens())
    else { return }
    isShown = true
    lastFrame = frame
    surface.show(at: frame, makingKey: request.kind.makesKey)
  } // End of func update()

  /// The content's height changed: while the window shows, resizes it to the new height with
  /// its top edge fixed, clamped into the visible frame of the display it is on (the first
  /// display when it is on none).
  public func contentSizeChanged() {
    guard isShown else { return }
    let current = surface.frame
    let screens = screens()
    guard let screen = NewSessionWindowPlacement.screen(for: current, in: screens) ?? screens.first
    else { return }
    let frame = NewSessionWindowPlacement.resized(
      current, height: surface.fittingFrameSize.height, visibleFrame: screen.visibleFrame)
    guard frame != current else { return }
    lastFrame = frame
    surface.setFrame(frame)
  } // End of func contentSizeChanged()
}
