import AppKit
import SwiftUI

/// muxFinder's menu bar item and popover (PLAN.md D22, D30): its own `NSStatusItem` with the
/// template icon (`MenuBarIcon`, D28) and a borderless, non-activating `NSPanel` hosting the live
/// `PopoverView`, opened, placed, moved and closed by `PopoverController`. This type is only the
/// AppKit wiring; every decision is the controller's (tested over fakes).
///
/// - **Button:** its action (sent on the left or right mouse press) is the controller's
///   `buttonPressed()`.
/// - **Session switcher** (PLAN.md D32): the model's `closePopover` is the controller's close
///   (`switcherOpened`), so opening the switcher closes the popover; its
///   `isStatusItemPressHeld` is the controller's `isButtonPressHeld`, so the switcher leaves a
///   close from outside made by a press on the button to the popover that press opens.
/// - **Panel:** at the pop-up menu level, on every Space and over full-screen apps; it becomes
///   key without activating the app, so the frontmost app stays frontmost and the search field
///   takes the keys. Its own close (Esc through the key monitor of `PopoverWindowBridge`) goes
///   to the controller.
/// - **Closing from outside:** a mouse press another process receives (a global monitor,
///   installed only while the panel shows; mouse presses need no permission), another app
///   becoming active, the panel resigning key, and the displays changing.
/// - **Size:** the hosted view lays itself out no taller than the controller's limit (the
///   display's room below the menu bar; its host list shrinks and scrolls) and reports changes
///   of its natural size, and the controller places the panel again.
///
/// Created only by the menu bar app (normal mode and `--report-popover-placement`); never in
/// `--preview-fixtures` or `--selftest`, so those make no status item.
@MainActor
public final class MenuBarPopover {
  /// Opens, moves and closes the panel.
  public let controller: PopoverController
  /// The status item button's wiring.
  private let button: StatusItemButton
  /// The panel's wiring.
  private let host: PopoverPanelHost
  /// The panel's notification observers.
  private var observers: PanelObservers?

  /// muxFinder's status item.
  public var statusItem: NSStatusItem { button.item }
  /// The popover's panel.
  public var panel: NSPanel { host.panel }
  /// The hosted popover's natural size, in points.
  public var contentSize: CGSize { host.contentSize }

  /// Puts muxFinder's item in the menu bar, with its icon from `bundle`, and builds the panel
  /// over `model`; the panel shows when the button is pressed.
  public init(model: AppModel, bundle: Bundle = .main) {
    let button = StatusItemButton(image: MenuBarIcon.statusItemImage(in: bundle))
    let host = PopoverPanelHost(model: model)
    let controller = PopoverController(
      panel: host, button: button, system: .appKit,
      onVisibilityChange: { [weak model] isVisible in
        model?.popoverVisibilityChanged(isVisible)
      },
      onOpen: { [weak model] in model?.focusSearch() })
    self.button = button
    self.host = host
    self.controller = controller
    button.onPress = { [weak controller] in controller?.buttonPressed() }
    model.closePopover = { [weak controller] in controller?.close(.switcherOpened) }
    model.isStatusItemPressHeld = { [weak controller] in controller?.isButtonPressHeld ?? false }
    host.panel.closeRequest = { [weak controller] in controller?.close(.escape) }
    host.onPressOutside = { [weak controller] in controller?.close(.pressOutside) }
    host.onContentSizeChange = { [weak controller] in controller?.contentSizeChanged() }
    observers = PanelObservers(
      panel: host.panel,
      resignedKey: { [weak controller] in controller?.close(.resignedKey) },
      occlusionChanged: { [weak controller] in controller?.occlusionChanged(isVisible: $0) },
      displaysChanged: { [weak controller] in controller?.close(.displaysChanged) },
      otherAppActivated: { [weak controller] in controller?.close(.appSwitch) })
  } // End of init(model:bundle:)
}

/// What closes or hides a muxFinder panel from outside (the popover's, PLAN.md D30, and the
/// session switcher's, D32): the panel resigning key, its occlusion changing, the displays
/// changing, and another app becoming active (muxFinder itself becoming active does not count:
/// opening Settings activates it). The observers live as long as this object.
@MainActor
final class PanelObservers {
  /// The notification observers (the default center's and the workspace's).
  private var observers: [(center: NotificationCenter, token: any NSObjectProtocol)] = []

  /// Observes `panel` and the system, calling the handler for each event (`occlusionChanged`
  /// gets whether some part of the panel shows).
  init(
    panel: NSPanel,
    resignedKey: @escaping @MainActor () -> Void,
    occlusionChanged: @escaping @MainActor (Bool) -> Void,
    displaysChanged: @escaping @MainActor () -> Void,
    otherAppActivated: @escaping @MainActor () -> Void
  ) {
    let center = NotificationCenter.default
    let workspace = NSWorkspace.shared.notificationCenter
    let ownPID = ProcessInfo.processInfo.processIdentifier
    add(center, NSWindow.didResignKeyNotification, object: panel) { _ in resignedKey() }
    add(center, NSWindow.didChangeOcclusionStateNotification, object: panel) {
      [weak panel] _ in
      guard let panel else { return }
      occlusionChanged(panel.occlusionState.contains(.visible))
    }
    add(center, NSApplication.didChangeScreenParametersNotification, object: nil) { _ in
      displaysChanged()
    }
    add(workspace, NSWorkspace.didActivateApplicationNotification, object: nil) { pid in
      guard pid != ownPID else { return }
      otherAppActivated()
    }
  } // End of init(panel:resignedKey:occlusionChanged:displaysChanged:otherAppActivated:)

  /// Observes `name` from `object` on `center`'s main queue; `handler` gets the activated
  /// app's process id when the notification names one.
  private func add(
    _ center: NotificationCenter, _ name: Notification.Name, object: AnyObject?,
    handler: @escaping @MainActor (pid_t?) -> Void
  ) {
    let token = center.addObserver(forName: name, object: object, queue: .main) { notification in
      let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
      let pid = app?.processIdentifier
      MainActor.assumeIsolated { handler(pid) }
    }
    observers.append((center: center, token: token))
  }
}

extension PopoverSystem {
  /// The mouse event types that count as the press behind the button's action.
  static let pressEventTypes: Set<NSEvent.EventType> = [
    .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .otherMouseDown, .otherMouseUp,
  ]
  /// How old, in seconds, the current event may be and still count as the press behind the
  /// action (`performClick(_:)` and VoiceOver send the action with an older, unrelated current
  /// event, or none).
  static let pressFreshness: TimeInterval = 1

  /// The mouse-down event types `hidPressCount()` counts.
  static let pressDownTypes: [CGEventType] = [.leftMouseDown, .rightMouseDown, .otherMouseDown]

  /// AppKit's: `NSScreen.screens`; the press's location when the current event is a recent
  /// mouse press or release (`NSEvent.mouseLocation`, the pointer as the window server has it;
  /// the event's own window may be a replica with a placeholder frame); the pointer; the pointer
  /// while a mouse button is held; the count of mouse presses (`hidPressCount()`); the system
  /// uptime.
  public static var appKit: PopoverSystem {
    PopoverSystem(
      screens: { NSScreen.screens.map { PopoverPlacement.Screen($0) } },
      pressLocation: {
        guard let event = NSApp.currentEvent, pressEventTypes.contains(event.type),
          ProcessInfo.processInfo.systemUptime - event.timestamp <= pressFreshness
        else { return nil }
        return NSEvent.mouseLocation
      },
      pointerLocation: { NSEvent.mouseLocation },
      heldPointerLocation: { NSEvent.pressedMouseButtons != 0 ? NSEvent.mouseLocation : nil },
      pressCount: { hidPressCount() },
      uptime: { ProcessInfo.processInfo.systemUptime })
  } // End of static var appKit

  /// The window server's count of left, right and other mouse-button presses from the
  /// hardware since it started (`CGEventSource.counterForEventType` on the HID system state; a
  /// public, read-only query, no event tap or monitor). A press raises it once, before any of
  /// its effects reach the app, and its release does not, so the button's action and a close
  /// from outside for one press read the same count, and any later press reads a higher one.
  /// Events another process posts are left out, so a relayed copy of a press is not counted as
  /// another press.
  static func hidPressCount() -> UInt64 {
    pressDownTypes.reduce(0) { total, type in
      total + UInt64(CGEventSource.counterForEventType(.hidSystemState, eventType: type))
    }
  }
}

/// muxFinder's `NSStatusItem` and its button, as `PopoverController` reads it.
@MainActor
final class StatusItemButton: NSObject, PopoverStatusButton {
  /// The status item (variable length; the user may ⌘-drag it out of the menu bar, which quits
  /// the app, as the `MenuBarExtra` item before it did).
  let item: NSStatusItem
  /// Called when the button is pressed.
  var onPress: (() -> Void)?
  /// Whether the button should show pressed (the popover is open).
  private var isHighlightWanted = false

  /// Adds the item to the system menu bar with `image` (a template image).
  init(image: NSImage) {
    item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    super.init()
    item.behavior = [.removalAllowed, .terminationOnRemoval]
    guard let button = item.button else { return }
    button.image = image
    button.imagePosition = .imageOnly
    button.setAccessibilityLabel(MenuBarIcon.accessibilityName)
    button.target = self
    button.action = #selector(pressed(_:))
    button.sendAction(on: [.leftMouseDown, .rightMouseDown])
  } // End of init(image:)

  /// The button's action.
  @objc private func pressed(_ sender: Any?) {
    onPress?()
  }

  /// The button's rectangle in screen coordinates.
  var screenRect: CGRect? {
    guard let button = item.button, let window = button.window else { return nil }
    return window.convertToScreen(button.convert(button.bounds, to: nil))
  }

  /// Shows the button pressed (or not), now and again once the run loop is back in its default
  /// mode: the action is sent on the mouse press, and the button's own tracking of that press
  /// would take the highlight away when the mouse is released.
  func setHighlighted(_ isHighlighted: Bool) {
    isHighlightWanted = isHighlighted
    item.button?.highlight(isHighlighted)
    RunLoop.main.perform(inModes: [.default]) { [weak self] in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.item.button?.highlight(self.isHighlightWanted)
      }
    }
  }
}

/// A panel root view the host lays out no taller than a limit (`PopoverPanelRoot`,
/// `SwitcherPanelRoot`).
protocol PanelRootView: View {
  /// The tallest the content lays itself out, in points (`nil`: no limit).
  var maximumHeight: CGFloat? { get set }
}

/// The popover's panel and what it hosts, as `PopoverController` drives it.
typealias PopoverPanelHost = PanelHost<PopoverPanelRoot>

extension PanelHost where Root == PopoverPanelRoot {
  /// The panel hosting the live popover for `model`, at the pop-up menu level (PLAN.md D30).
  convenience init(model: AppModel) {
    self.init(level: .popUpMenu) { onSizeChange in
      PopoverPanelRoot(model: model, onSizeChange: onSizeChange)
    }
  }
}

/// A borderless, non-activating panel and the live view it hosts, as a panel controller
/// drives it (`PopoverController` for the popover, `SwitcherController` for the session
/// switcher): shown and hidden on request, watching for presses outside it while shown, and
/// reporting changes of its content's natural size once per turn of the main loop.
@MainActor
final class PanelHost<Root: PanelRootView>: PopoverPanelSurface {
  /// The panel.
  let panel: PopoverPanelWindow
  /// The live view.
  let hostingView: PanelHostingView<Root>
  /// Called for a mouse press another process received while the panel shows.
  var onPressOutside: (() -> Void)?
  /// Called once per turn of the main loop after the content's natural size changed.
  var onContentSizeChange: (() -> Void)?
  /// The global mouse-down monitor, while the panel shows.
  private var outsideMonitor: Any?
  /// Whether a size change report is queued.
  private var isSizeChangeQueued = false

  /// A panel at `level` hosting the root view `makeRoot` builds; the root calls the handler it
  /// is given when its natural size changed.
  init(level: NSWindow.Level, makeRoot: (@escaping @MainActor () -> Void) -> Root) {
    let relay = PopoverSizeRelay()
    let hostingView = PanelHostingView(rootView: makeRoot({ relay.sizeChanged() }))
    hostingView.sizingOptions = [.intrinsicContentSize]
    hostingView.onIntrinsicSizeChange = { relay.sizeChanged() }
    self.hostingView = hostingView
    panel = PopoverPanelWindow(
      contentView: PopoverPanelContentView(hosting: hostingView), level: level)
    relay.handler = { [weak self] in self?.queueSizeChange() }
  }

  /// The tallest the hosted view lays itself out (`PopoverPanelRoot.maximumHeight`).
  var maximumContentHeight: CGFloat? {
    get { hostingView.rootView.maximumHeight }
    set {
      guard newValue != hostingView.rootView.maximumHeight else { return }
      hostingView.rootView.maximumHeight = newValue
    }
  }

  /// The hosted view's natural size (no taller than `maximumContentHeight` when it can shrink
  /// that far).
  var contentSize: CGSize {
    hostingView.fittingSize
  }

  /// Puts the panel at `frame` in front and makes it key (the app stays inactive), and starts
  /// watching for presses outside it.
  func show(at frame: CGRect) {
    panel.setFrame(frame, display: true)
    panel.orderFrontRegardless()
    panel.makeKey()
    panel.invalidateShadow()
    guard outsideMonitor == nil else { return }
    outsideMonitor = NSEvent.addGlobalMonitorForEvents(
      matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.onPressOutside?() }
    }
  } // End of func show(at:)

  /// Moves or resizes the panel.
  func setFrame(_ frame: CGRect) {
    panel.setFrame(frame, display: true)
    panel.invalidateShadow()
  }

  /// Stops watching for presses outside the panel and orders it out.
  func hide() {
    if let outsideMonitor { NSEvent.removeMonitor(outsideMonitor) }
    outsideMonitor = nil
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

/// A muxFinder panel's window (the popover's, PLAN.md D30, and the session switcher's, D32):
/// borderless, non-activating (it becomes key while the frontmost app stays frontmost), at
/// its level (the pop-up menu level for the popover, the floating level for the switcher), on
/// every Space and over full-screen apps, not movable, transparent outside its rounded
/// content, with a shadow. Closing it asks `closeRequest` (the controller), which orders it
/// out; it is never released.
final class PopoverPanelWindow: NSPanel {
  /// Called instead of closing the panel (Esc, or the diagnostic's own close).
  var closeRequest: (() -> Void)?

  /// A panel showing `contentView` at `level`.
  init(contentView: NSView, level: NSWindow.Level = .popUpMenu) {
    super.init(
      contentRect: NSRect(x: 0, y: 0, width: PopoverView.width, height: 100),
      styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
    self.contentView = contentView
    isFloatingPanel = true
    self.level = level
    collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    hidesOnDeactivate = false
    isReleasedWhenClosed = false
    becomesKeyOnlyIfNeeded = false
    isMovable = false
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    animationBehavior = .none
    tabbingMode = .disallowed
    isExcludedFromWindowsMenu = true
  } // End of init(contentView:level:)

  /// A borderless window cannot become key unless it says so; the search field needs the keys.
  override var canBecomeKey: Bool { true }

  /// Never the main window.
  override var canBecomeMain: Bool { false }

  /// Asks the controller to close the popover (it orders the panel out), else closes.
  override func close() {
    if let closeRequest {
      closeRequest()
    } else {
      super.close()
    }
  }
}

/// The panel's content: the hosted popover clipped to rounded corners, with a hairline border
/// in the system separator color (the popover paints its own opaque background, Phase 14).
final class PopoverPanelContentView: NSView {
  /// The corner radius, in points.
  static let cornerRadius: CGFloat = 12

  /// A content view holding `hosting`, which fills it.
  init(hosting: NSView) {
    super.init(frame: NSRect(x: 0, y: 0, width: PopoverView.width, height: 100))
    wantsLayer = true
    layer?.cornerRadius = Self.cornerRadius
    layer?.cornerCurve = .continuous
    layer?.masksToBounds = true
    hosting.frame = bounds
    hosting.autoresizingMask = [.width, .height]
    addSubview(hosting)
  }

  /// Not used: the view is only created in code.
  required init?(coder: NSCoder) {
    return nil
  }

  /// The border is set on the layer.
  override var wantsUpdateLayer: Bool { true }

  /// Sets the border's color for the current appearance and its width to one pixel.
  override func updateLayer() {
    effectiveAppearance.performAsCurrentDrawingAppearance {
      layer?.borderColor = NSColor.separatorColor.cgColor
    }
    layer?.borderWidth = 1 / max(1, window?.backingScaleFactor ?? 2)
  }

  /// Redraws the border in the new appearance.
  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    needsDisplay = true
  }

  /// Redraws the border for the new pixel size.
  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    needsDisplay = true
  }
}

/// The hosting view of the live popover (`PanelHostingView`).
typealias PopoverHostingView = PanelHostingView<PopoverPanelRoot>

/// The hosting view of a panel's live view; reports when AppKit's idea of its natural size is
/// invalidated (one of the two size reports, with the root view's).
final class PanelHostingView<Root: View>: NSHostingView<Root> {
  /// Called after the hosted view's natural size was invalidated.
  var onIntrinsicSizeChange: (() -> Void)?

  /// Invalidates the size, then reports it.
  override func invalidateIntrinsicContentSize() {
    super.invalidateIntrinsicContentSize()
    onIntrinsicSizeChange?()
  }
}

/// The panel's root view: the live `PopoverView` at its natural size, but no taller than
/// `maximumHeight` (`PopoverHeightLimit`; so the panel's frame, which the controller sets,
/// never squeezes or stretches it, and never cuts it off), reporting each change of that size
/// (one of the two size reports, with `PopoverHostingView`'s).
struct PopoverPanelRoot: PanelRootView {
  /// The popover's model.
  let model: AppModel
  /// The tallest the popover lays itself out, in points (`nil`: no limit); the controller sets
  /// the display's room below its menu bar.
  var maximumHeight: CGFloat?
  /// Called when the popover's natural size changed.
  let onSizeChange: @MainActor () -> Void

  /// The popover, at its natural size within the limit.
  var body: some View {
    PopoverHeightLimit(maximumHeight: maximumHeight) {
      PopoverView(model: model, isLive: true)
    }
    .onGeometryChange(for: CGSize.self) { geometry in
      geometry.size
    } action: { _ in
      onSizeChange()
    }
  }
}

/// Lays out its one subview at its natural size whatever it is offered, as `fixedSize()` does,
/// except never taller than `maximumHeight` (PLAN.md D30): content that is taller is offered
/// `maximumHeight` instead, so `PopoverView`'s host list, the only part that gives up height,
/// shrinks and scrolls while the search field, notices and footer keep theirs. Content that
/// fits, or any content with no limit, is offered nothing, exactly as under `fixedSize()`.
struct PopoverHeightLimit: Layout {
  /// The tallest the subview may be, in points; `nil` for no limit.
  var maximumHeight: CGFloat?

  /// The height offered to content of natural height `natural`: `nil` (its natural height)
  /// when it fits within `maximumHeight` or there is no limit, else `maximumHeight`.
  static func offeredHeight(natural: CGFloat, maximumHeight: CGFloat?) -> CGFloat? {
    guard let maximumHeight, natural > maximumHeight else { return nil }
    return max(0, maximumHeight)
  }

  /// What `subview` is offered: no width (it has its own) and `offeredHeight(natural:…)`.
  private func proposal(for subview: LayoutSubview) -> ProposedViewSize {
    let natural = subview.sizeThatFits(.unspecified)
    return ProposedViewSize(
      width: nil,
      height: Self.offeredHeight(natural: natural.height, maximumHeight: maximumHeight))
  }

  /// The subview's size for that offer, whatever this layout is offered.
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let subview = subviews.first else { return .zero }
    return subview.sizeThatFits(self.proposal(for: subview))
  }

  /// Puts the subview in the middle of `bounds`, with that offer.
  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    guard let subview = subviews.first else { return }
    subview.place(
      at: CGPoint(x: bounds.midX, y: bounds.midY), anchor: .center,
      proposal: self.proposal(for: subview))
  }
}

/// Hands the size reports of the hosting view and its root view, made before the panel's host
/// exists, to the host.
@MainActor
final class PopoverSizeRelay {
  /// The host's handler, once it exists.
  var handler: (() -> Void)?

  /// A size report.
  func sizeChanged() {
    handler?()
  }
}
