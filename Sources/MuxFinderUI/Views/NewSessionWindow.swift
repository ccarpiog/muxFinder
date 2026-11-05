import AppKit
import SwiftUI

/// muxFinder's New session window (PLAN.md D34): one titled, floating, non-activating panel
/// (`NewSessionPanel`) hosting the live New session form, shown, placed and hidden by
/// `NewSessionWindowController` as the model's `newSessionWindow` says. This type is only the
/// AppKit wiring; every decision is the controller's or the model's (tested over fakes).
///
/// - **Made at the first opening** and reused (never released): at launch there is no such
///   window, so the app shell check lists none.
/// - **Ending:** its close button and ⌘W (the main menu's Close, enabled for a titled window,
///   PLAN.md D33) reach `NewSessionPanel.close()`, which is the model's `closeNewSession()`, as
///   Cancel and Esc are.
/// - **Never closed from outside:** it does not hide when muxFinder is inactive and nothing
///   closes it on resigning key, a click elsewhere or another app becoming active.
/// - **Size:** the hosted form reports changes of its natural size and the controller resizes
///   the window with its top edge fixed.
///
/// Created only by the menu bar app in normal mode (`AppDelegate`); never in a preview, a
/// self-test or `--report-popover-placement`, so the model works without it.
@MainActor
public final class NewSessionWindow {
  /// The window's title.
  public static let title = "New session"

  /// Shows, places and hides the window.
  public let controller: NewSessionWindowController
  /// The window, made at the first opening.
  private let loader: NewSessionWindowLoader

  /// Connects a window to `model` (`NewSessionWindowController.make`); the window itself is
  /// made when the model first asks for it.
  public init(model: AppModel) {
    let loader = NewSessionWindowLoader { NewSessionWindowHost(model: model) }
    let controller = NewSessionWindowController.make(
      for: model, surface: loader,
      screens: { NSScreen.screens.map { PopoverPlacement.Screen($0) } })
    loader.onMake = { [weak controller, weak model] host in
      host.onContentSizeChange = { [weak controller] in controller?.contentSizeChanged() }
      host.panel.closeRequest = { [weak model] in model?.closeNewSession() }
    }
    self.loader = loader
    self.controller = controller
  } // End of init(model:)

  /// The window, once made (the first opening makes it).
  public var panel: NSPanel? { loader.host?.panel }
}

/// The New session window's surface as the controller drives it, made at its first use: until
/// the controller first measures or shows it, no window exists (PLAN.md D34).
@MainActor
final class NewSessionWindowLoader: NewSessionWindowSurface {
  /// Makes the window.
  private let make: @MainActor () -> NewSessionWindowHost
  /// Called once with the window just made (its size reports and close button get wired).
  var onMake: (@MainActor (NewSessionWindowHost) -> Void)?
  /// The window, once made.
  private(set) var host: NewSessionWindowHost?

  /// A loader that makes the window with `make`.
  init(make: @escaping @MainActor () -> NewSessionWindowHost) {
    self.make = make
  }

  /// The window, made now if it was not yet.
  private var made: NewSessionWindowHost {
    if let host { return host }
    let host = make()
    self.host = host
    onMake?(host)
    return host
  }

  /// The made window's fitting frame size.
  var fittingFrameSize: CGSize { made.fittingFrameSize }
  /// The window's frame (zero before it was made).
  var frame: CGRect { host?.frame ?? .zero }

  /// Shows the window, making it first if needed.
  func show(at frame: CGRect, makingKey: Bool) {
    made.show(at: frame, makingKey: makingKey)
  }

  /// Moves or resizes the window, if made.
  func setFrame(_ frame: CGRect) {
    host?.setFrame(frame)
  }

  /// Orders the window out, if made.
  func hide() {
    host?.hide()
  }
}

/// The New session panel and the live form it hosts (PLAN.md D34): shown and hidden on
/// request, reporting changes of its content's natural size once per turn of the main loop.
/// The app's window (through `NewSessionWindowLoader`), the key view loop diagnostic and the
/// tests build it.
@MainActor
final class NewSessionWindowHost: NewSessionWindowSurface {
  /// The panel.
  let panel: NewSessionPanel
  /// The live form.
  let hostingView: PanelHostingView<NewSessionWindowRoot>
  /// Called once per turn of the main loop after the content's natural size changed.
  var onContentSizeChange: (() -> Void)?
  /// Whether a size change report is queued.
  private var isSizeChangeQueued = false

  /// A panel hosting the live form over `model` (its key monitor included).
  init(model: AppModel) {
    let relay = PopoverSizeRelay()
    let hostingView = PanelHostingView(
      rootView: NewSessionWindowRoot(
        model: model, isLive: true, onSizeChange: { relay.sizeChanged() }))
    hostingView.sizingOptions = [.intrinsicContentSize]
    hostingView.onIntrinsicSizeChange = { relay.sizeChanged() }
    self.hostingView = hostingView
    panel = NewSessionPanel(contentView: hostingView)
    relay.handler = { [weak self] in self?.queueSizeChange() }
  }

  /// The panel's frame size for the form at its natural height,
  /// `NewSessionWindowPlacement.width` wide (the title bar included).
  var fittingFrameSize: CGSize {
    let content = CGRect(
      x: 0, y: 0, width: NewSessionWindowPlacement.width,
      height: hostingView.fittingSize.height)
    return panel.frameRect(forContentRect: content).size
  }

  /// The panel's frame now.
  var frame: CGRect { panel.frame }

  /// Puts the panel at `frame` in front, making it key (the app stays inactive) when
  /// `makingKey`.
  func show(at frame: CGRect, makingKey: Bool) {
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
    if makingKey { panel.makeKey() }
  }

  /// Moves or resizes the panel.
  func setFrame(_ frame: CGRect) {
    panel.setFrame(frame, display: true)
  }

  /// Orders the panel out (it is never released).
  func hide() {
    panel.orderOut(nil)
  }

  /// Reports a size change on the next turn of the main loop, once (the hosted view may
  /// invalidate its size several times, and inside its own layout).
  private func queueSizeChange() {
    guard !isSizeChangeQueued else { return }
    isSizeChangeQueued = true
    DispatchQueue.main.async { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.isSizeChangeQueued = false
        self.onContentSizeChange?()
      }
    }
  } // End of func queueSizeChange()
}

/// The New session window (PLAN.md D34): a titled, closable, non-activating panel titled "New
/// session" (not a `PopoverPanelWindow`, so the main menu's Close, ⌘W, is enabled for it, D33),
/// at the floating level (above other apps' normal windows, below the popover and switcher
/// panels and menus), on every Space and beside full-screen apps (`canJoinAllSpaces`,
/// `fullScreenAuxiliary`); key without activating muxFinder, a click into it making it key
/// again without taking the frontmost app's place; not hidden when muxFinder is inactive, not
/// released when closed, movable, not resizable by the user; its key view loop recalculated as
/// the form changes (PLAN.md Phase I-6). Closing it (its close button, ⌘W) asks
/// `closeRequest` (the model's `closeNewSession()`), whose state change orders it out.
final class NewSessionPanel: NSPanel {
  /// Called instead of closing the panel.
  var closeRequest: (() -> Void)?

  /// A panel showing `contentView`.
  init(contentView: NSView) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: NewSessionWindowPlacement.width, height: 200),
      styleMask: [.titled, .closable, .nonactivatingPanel], backing: .buffered, defer: true)
    title = NewSessionWindow.title
    self.contentView = contentView
    isFloatingPanel = true
    level = .floating
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    becomesKeyOnlyIfNeeded = false
    isRestorable = false
    tabbingMode = .disallowed
    autorecalculatesKeyViewLoop = PopoverPanelWindow.recalculatesKeyViewLoop
  } // End of init(contentView:)

  /// The form's fields need the keys.
  override var canBecomeKey: Bool { true }

  /// Never the main window.
  override var canBecomeMain: Bool { false }

  /// Asks the model to close the window (it orders it out), else closes.
  override func close() {
    if let closeRequest {
      closeRequest()
    } else {
      super.close()
    }
  }
}

/// The New session window's root view: the live form, `NewSessionWindowPlacement.width` wide
/// at its natural height whatever the window's frame (`PopoverHeightLimit` with no limit), on
/// Phase 14's opaque background, reporting each change of that size (one of the two size
/// reports, with `PanelHostingView`'s). With `isLive`, it tracks its window for the window's
/// keys and mouse clicks (`NewSessionWindowBridge`) and focuses the Name field.
struct NewSessionWindowRoot: View {
  /// The model whose draft the form edits.
  let model: AppModel
  /// Whether this is the real window (keys, clicks, the Name field's focus).
  let isLive: Bool
  /// Called when the form's natural size changed.
  let onSizeChange: @MainActor () -> Void
  /// Light or dark, for the background.
  @Environment(\.colorScheme) private var colorScheme

  /// The form, at its natural size.
  var body: some View {
    PopoverHeightLimit(maximumHeight: nil, minimumHeight: nil) {
      NewSessionPanelView(model: model, focusesName: isLive)
        .frame(width: NewSessionWindowPlacement.width)
    }
    .background(PopoverPalette(colorScheme).background)
    .background {
      if isLive { NewSessionWindowBridge(model: model) }
    }
    .onGeometryChange(for: CGSize.self) { geometry in
      geometry.size
    } action: { _ in
      onSizeChange()
    }
  } // End of var body
}

/// Connects the real New session form to its window: its keys (`PopoverKey`) go to
/// `AppModel.handleNewSessionKey(_:)` before the focused view sees them, as `PanelKeyRoute`
/// decides (the panels' rule: an open menu, an input method composing and a focused pop-up
/// button's ↑, ↓ and ⌥↓ first), and its left mouse button events through
/// `AppModel.newSessionWindowPasses(_:)` (`PanelKeyTrackingView`).
struct NewSessionWindowBridge: NSViewRepresentable {
  /// The model told about keys and clicks.
  let model: AppModel

  /// Creates the tracking view.
  func makeNSView(context: Context) -> NewSessionWindowTrackingView {
    NewSessionWindowTrackingView(model: model)
  }

  /// Nothing to update: the view follows its window by itself.
  func updateNSView(_ nsView: NewSessionWindowTrackingView, context: Context) {}

  /// Stops tracking when SwiftUI removes the view.
  static func dismantleNSView(_ nsView: NewSessionWindowTrackingView, coordinator: ()) {
    nsView.stopTracking()
  }
}

/// The New session window's tracking view: its keys go to `AppModel.handleNewSessionKey(_:)`
/// and its left mouse button events through `AppModel.newSessionWindowPasses(_:)`, so the rest
/// of a click sequence in progress when the window opened (a double click on the switcher's New
/// session row) reaches none of its views (PLAN.md D34).
final class NewSessionWindowTrackingView: PanelKeyTrackingView {
  /// Creates the view for `model`.
  init(model: AppModel) {
    super.init(
      route: { [weak model] key in model?.handleNewSessionKey(key) ?? .ignored },
      isDirectoryListOpen: { [weak model] in model?.directoryPicker.isOpen ?? false },
      passes: { [weak model] event in model?.newSessionWindowPasses(event) ?? true })
  }

  /// Not used: the view is only created in code.
  required init?(coder: NSCoder) {
    return nil
  }
}
