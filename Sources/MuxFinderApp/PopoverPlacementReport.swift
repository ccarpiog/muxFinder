import AppKit
import CoreGraphics
import Foundation
import MuxFinderUI

/// `--report-popover-placement` (PLAN.md Phase I-1, D30): opens muxFinder's popover through its
/// own status item button and measures where it opens, read-only, inside the normal menu bar
/// item and panel (`MenuBarPopover`, over a model the app never starts).
///
/// Two seconds after launch it prints, one `muxFinder popover placement:` line each: the login
/// session (screen locked, on console) and the pointer; every display (frame, visible frame,
/// scale, the menu bar's bottom as `PopoverPlacement.Screen` computes it, main or not); every
/// status-bar-level window of the app with its screen, content view tree and status item; the
/// status item if one is reachable; each status item button with its window's frame, its
/// rectangle in screen coordinates and how it takes a click (action, target, cell, gesture
/// recognizers, observed key paths); other processes' status-bar windows (frames only, no
/// names); the popover content's size measured off screen (an `NSHostingView` that is never put
/// in a window) and the frame `PopoverPlacement` gives for it at the button and at each
/// status-bar window.
///
/// Then it opens muxFinder's own popover by calling muxFinder's status item button's
/// `performClick(_:)` in this process (no event is posted to the system; no Accessibility or
/// AppleScript), which sends the button's action, `PopoverController.buttonPressed()`; it
/// clicks only when the button has an action or a menu (a button with neither, as SwiftUI's
/// `MenuBarExtra` button had, would send nothing: exit 4 without clicking). With no mouse event
/// behind the action, the controller anchors at the button's rectangle (D30). After the click it
/// waits at most 2 s for the popover window (`PopoverWindowIdentification`: the window holding
/// the live `PopoverView`, else a newly visible window below the status-bar level; never a
/// status-bar window), prints its frame, its screen and level, the frame `PopoverPlacement`
/// would give for the same content on the button's display, the offsets between them, the
/// controller's placement (anchor, its source and display) and the after-fix check
/// (`PopoverPlacementCheck`: the panel's middle within 2 pt of the anchor's unless clamped, its
/// top within 1 pt of the menu bar's bottom); closes it with a second `performClick(_:)` (the
/// controller's toggle; ordered out if that left it open) and exits 0.
///
/// Bounds: the popover stays open at most 3 s; the whole run ends within 10 s; SIGTERM and
/// SIGINT close the popover and end it too, closing before anything is printed. Output goes
/// through a `NonblockingLineWriter`, so a reader that stops reading never delays a deadline or
/// a signal (lines that do not fit are dropped and counted), and a watchdog off the main thread
/// ends the process with 3 one second after the 10 s deadline whatever the main thread does.
/// Exit statuses: 0 measured; 1 clicked, but the popover never appeared; 3 interrupted (a
/// signal, the 3 s open limit, the 10 s deadline or the watchdog); 4 not openable in process
/// (no status item button, or one with no action and no menu). Nothing is written: no
/// defaults, no file; the status item's visibility is only read.
@MainActor
final class PopoverPlacementReport {
  /// How the diagnostic ends.
  enum ExitStatus: Int32 {
    /// Everything was measured.
    case measured = 0
    /// The button was clicked, but the popover window never appeared.
    case notMeasured = 1
    /// A signal, the open limit, the overall deadline or the watchdog ended the run first.
    case interrupted = 3
    /// The popover cannot be opened in process: no status item button, or a button with no
    /// action and no menu (as SwiftUI's `MenuBarExtra` button had), so nothing was clicked.
    case notOpenableInProcess = 4
  }

  /// Every line's prefix.
  static let prefix = "muxFinder popover placement:"
  /// How long after launch the first measurement is made (as `--report-menu-bar-item`).
  static let launchDelay: Duration = .seconds(2)
  /// How much longer to wait for a status item button when none exists yet.
  static let buttonWait: Duration = .seconds(1)
  /// How long to wait for the popover window after the click.
  static let appearanceWait: Duration = .seconds(2)
  /// How long the popover is left open before its frame is read again.
  static let settleDelay: Duration = .milliseconds(400)
  /// How long to wait for the second click to close the popover before ordering it out.
  static let closeWait: Duration = .milliseconds(500)
  /// The longest the popover may stay open, in seconds.
  static let openLimit: TimeInterval = 3
  /// The whole run's deadline, in seconds after `start()`.
  static let deadline: TimeInterval = 10
  /// The pause between two looks at the app's windows.
  static let pollInterval: Duration = .milliseconds(25)
  /// How long after `deadline` the watchdog ends the process, in seconds.
  static let watchdogGrace: TimeInterval = 1
  /// The longest the last lines are waited for before exiting, in seconds.
  static let outputFlushWait: TimeInterval = 0.25

  /// The popover's model (never started), for measuring the content off screen.
  private let model: AppModel
  /// muxFinder's menu bar item and popover panel.
  private let menuBarPopover: MenuBarPopover
  /// Standard output, written without blocking the main actor.
  private let output = NonblockingLineWriter(fileDescriptor: STDOUT_FILENO)
  /// The SIGTERM and SIGINT sources.
  private var signalSources: [any DispatchSourceSignal] = []
  /// The timer that ends the process if the main thread cannot.
  private var watchdog: (any DispatchSourceTimer)?
  /// The measuring task.
  private var task: Task<Void, Never>?
  /// The button clicked to open the popover.
  private var clickedButton: NSStatusBarButton?
  /// The windows visible right before the click.
  private var visibleBeforeClick: Set<ObjectIdentifier> = []
  /// The popover window, once it appeared.
  private var popover: NSWindow?
  /// Whether the run already ended.
  private var isFinished = false

  /// A report over the popover's `model` and muxFinder's menu bar item and panel; nothing runs
  /// until `start()`.
  init(model: AppModel, popover: MenuBarPopover) {
    self.model = model
    menuBarPopover = popover
  }

  /// Installs the signal handlers, the deadline and the watchdog, then starts measuring. A
  /// closed standard output fails its writes (`SIGPIPE` ignored) instead of killing the run
  /// before it closes the popover.
  func start() {
    signal(SIGPIPE, SIG_IGN)
    signalSources = [(SIGTERM, "SIGTERM"), (SIGINT, "SIGINT")].map { entry in
      let (number, name) = entry
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { [weak self] in
        MainActor.assumeIsolated {
          self?.finish(.interrupted, reason: "interrupted by \(name)")
        }
      }
      source.resume()
      return source
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.deadline) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isFinished else { return }
        self.finish(.interrupted, reason: "the \(Int(Self.deadline)) s deadline passed")
      }
    }
    watchdog = Self.makeWatchdog(
      after: Self.deadline + Self.watchdogGrace, exitCode: ExitStatus.interrupted.rawValue)
    task = Task { await self.run() }
  } // End of func start()

  /// A timer on a global queue that ends the process with `exitCode` after `seconds`, whatever
  /// the main thread is doing (blocked, or stuck in a run loop mode); the popover window goes
  /// with the process. Nonisolated, so its handler never asserts the main actor.
  nonisolated static func makeWatchdog(after seconds: TimeInterval, exitCode: Int32)
    -> any DispatchSourceTimer
  {
    let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
    timer.schedule(deadline: .now() + seconds)
    timer.setEventHandler { _exit(exitCode) }
    timer.resume()
    return timer
  }

  /// The measurement, in order; ends the process.
  private func run() async {
    try? await Task.sleep(for: Self.launchDelay)
    reportSession()
    let screens = NSScreen.screens
    reportScreens(screens)
    var found = Self.statusBarButtons()
    let waitEnd = ContinuousClock.now + Self.buttonWait
    while found.isEmpty, ContinuousClock.now < waitEnd {
      try? await Task.sleep(for: Self.pollInterval)
      found = Self.statusBarButtons()
    }
    let item = Self.reachableStatusItem()
    let own = menuBarPopover.statusItem
    reportStatusBarWindows(label: "before the click", item: own)
    reportStatusItem(item)
    line(
      "muxFinder's own status item: reachable from the status-bar windows "
        + "\(item === own ? "yes" : "no"), has button \(own.button == nil ? "no" : "yes")")
    for (index, button) in found.enumerated() { reportButton(button, index: index) }
    reportOtherProcessesStatusBarWindows(screens)
    guard let button = own.button ?? item?.button ?? Self.preferredButton(found) else {
      line("no status item button found; the popover cannot be opened in process")
      finish(.notOpenableInProcess)
    }
    reportPlacements(contentSize: Self.offScreenContentSize(model), button: button)
    let index = found.firstIndex { $0 === button }.map(String.init) ?? "from the status item"
    guard button.action != nil || button.menu != nil || own.menu != nil else {
      line(
        "the popover cannot be opened in process: button \(index) has no action (target "
          + "\(button.target.map { Self.className($0) } ?? "none")) and no menu, so "
          + "performClick(_:) would send nothing; not clicking")
      finish(.notOpenableInProcess)
    }
    line("clicking button \(index) with performClick(_:)")
    await open(with: button)
    await measure(button: button, screens: NSScreen.screens)
    await close()
    finish(.measured)
  } // End of func run()

  // MARK: - Opening and closing

  /// Clicks `button` in process and waits for the popover window
  /// (`PopoverWindowIdentification`); ends the run when none appears in time.
  private func open(with button: NSStatusBarButton) async {
    visibleBeforeClick = Set(NSApp.windows.filter(\.isVisible).map(ObjectIdentifier.init))
    let windowsBefore = Set(NSApp.windows.map(ObjectIdentifier.init))
    clickedButton = button
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.openLimit) { [weak self] in
      MainActor.assumeIsolated {
        guard let self, !self.isFinished else { return }
        self.finish(
          .interrupted, reason: "the popover's \(Int(Self.openLimit)) s open limit passed")
      }
    }
    let clicked = ContinuousClock.now
    button.performClick(nil)
    while ContinuousClock.now - clicked < Self.appearanceWait {
      if let (window, match) = identifiedPopover() {
        popover = window
        let elapsed = Self.milliseconds(ContinuousClock.now - clicked)
        let existed = windowsBefore.contains(ObjectIdentifier(window)) ? "yes" : "no"
        let how =
          match == .livePopover
          ? "it holds the live popover view"
          : "fallback: newly visible below the status-bar level, no live popover view found"
        line(
          "popover appeared after \(elapsed) ms (window existed before the click: \(existed); "
            + "identified: \(how))")
        return
      }
      try? await Task.sleep(for: Self.pollInterval)
    } // End of loop waiting for the popover window
    line("popover window did not appear within \(Self.milliseconds(Self.appearanceWait)) ms")
    reportAllWindows()
    finish(.notMeasured)
  } // End of func open(with:)

  /// Closes the popover through the app's own toggle (a second click on the same button),
  /// and orders it out if that left it visible.
  private func close() async {
    guard let popover, popover.isVisible else {
      line("popover already closed")
      return
    }
    clickedButton?.performClick(nil)
    let clicked = ContinuousClock.now
    while popover.isVisible, ContinuousClock.now - clicked < Self.closeWait {
      try? await Task.sleep(for: Self.pollInterval)
    }
    if popover.isVisible {
      popover.orderOut(nil)
      line("popover still visible after the second click; ordered out")
    } else {
      line("popover closed by the second click")
    }
  } // End of func close()

  /// Closes whatever this run opened, at once (the signal, limit and deadline paths): the
  /// popover, or a popover window that appeared after the click but was not seen yet. Never a
  /// status-bar window (`PopoverWindowIdentification`).
  private func closeNow() {
    var windows = popover.map { [$0] } ?? []
    if clickedButton != nil, let late = identifiedPopover()?.window, late !== popover {
      windows.append(late)
    }
    for window in windows where window.isVisible {
      window.close()
      line("closed the popover window")
    }
  }

  /// Closes the popover first, then prints `reason`, the exit status and how many lines were
  /// dropped, waits a bounded time for the output, and exits; later calls only exit.
  private func finish(_ status: ExitStatus, reason: String? = nil) -> Never {
    if !isFinished {
      isFinished = true
      closeNow()
      if let reason { line(reason) }
      let dropped = output.droppedLines
      line(
        "exit \(status.rawValue)"
          + (dropped > 0 ? " (\(dropped) earlier lines dropped: output not read in time)" : ""))
      _ = output.flush(timeout: Self.outputFlushWait)
    }
    exit(status.rawValue)
  } // End of func finish(_:reason:)

  /// The popover among the app's windows and how it was recognized
  /// (`PopoverWindowIdentification`: the window holding the live `PopoverView`, else a window
  /// newly visible since the click below the status-bar level; never a status-bar window).
  private func identifiedPopover() -> (window: NSWindow, match: PopoverWindowIdentification.Match)?
  {
    let windows = NSApp.windows
    let described = windows.map { Self.identificationWindow($0, visibleBefore: visibleBeforeClick) }
    return PopoverWindowIdentification.popover(in: described).map { found in
      (window: windows[found.index], match: found.match)
    }
  }

  // MARK: - Measuring

  /// Prints the popover window (when it appeared and once settled), the status-bar windows
  /// again, the frame the placement function gives, and the offsets between them.
  private func measure(button: NSStatusBarButton, screens: [NSScreen]) async {
    guard let popover else { return }
    line("popover at appearance: \(describe(popover))")
    try? await Task.sleep(for: Self.settleDelay)
    line("popover settled: \(describe(popover))")
    reportStatusBarWindows(label: "with the popover open", item: Self.reachableStatusItem())
    reportButton(button, index: nil)
    guard let window = button.window else {
      line("the clicked button has no window; no placement to compare")
      return
    }
    let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
    let described = screens.map { PopoverPlacement.Screen($0) }
    let byWindow = window.screen.flatMap { Self.index(of: $0, in: screens) }
    let byAnchor = PopoverPlacement.screenIndex(for: .rect(anchor), in: described)
    line(
      "anchor \(NSStringFromRect(anchor)) on screen \(Self.text(byWindow)) by its window, "
        + "\(Self.text(byAnchor)) by PopoverPlacement.screenIndex")
    guard let screenIndex = byWindow ?? byAnchor else {
      line("no screen for the anchor; no placement to compare")
      return
    }
    let screen = described[screenIndex]
    let expected = PopoverPlacement.frame(
      contentSize: popover.frame.size, anchor: .rect(anchor), screen: screen)
    line(
      "placement function frame \(NSStringFromRect(expected)) on screen \(screenIndex) "
        + "(content \(Self.number(popover.frame.width)) x \(Self.number(popover.frame.height)))")
    reportOffsets(popover.frame, expected: expected, anchor: anchor, screen: screen)
    reportAfterFixCheck(popover.frame)
  } // End of func measure(button:screens:)

  /// Prints where muxFinder's controller put the popover (its anchor, where the anchor came
  /// from, its display, its frame, the content's natural size) and the after-fix check
  /// (`PopoverPlacementCheck`) of the panel's `frame` against that anchor and display.
  private func reportAfterFixCheck(_ frame: CGRect) {
    guard let placement = menuBarPopover.controller.placement else {
      line("after-fix check: the controller recorded no placement")
      return
    }
    let anchor = placement.decision.anchor
    let anchorText: String
    switch anchor {
    case .rect(let rect): anchorText = "rect \(NSStringFromRect(rect))"
    case .point(let point): anchorText = "point \(NSStringFromPoint(point))"
    }
    let content = menuBarPopover.contentSize
    line(
      "controller placement: anchor \(anchorText) from the \(placement.decision.source.rawValue) "
        + "on screen \(placement.screenIndex), frame \(NSStringFromRect(placement.frame)) "
        + "(the panel's now: \(placement.frame == frame ? "same" : NSStringFromRect(frame))), "
        + "content \(Self.number(content.width)) x \(Self.number(content.height))")
    let check = PopoverPlacementCheck(frame: frame, anchor: anchor, screen: placement.screen)
    line(
      "after-fix check: panel middle x \(Self.number(frame.midX)) minus anchor middle x "
        + "\(Self.number(anchor.midX)) = \(Self.number(check.middleOffset)) (tolerance "
        + "\(Self.number(PopoverPlacementCheck.middleTolerance)) pt unless clamped; clamped "
        + "\(check.isClamped ? "yes" : "no")): \(check.middlePasses ? "pass" : "fail")")
    line(
      "after-fix check: panel top \(Self.number(frame.maxY)) minus menu bar bottom "
        + "\(Self.number(placement.screen.menuBarBottom)) = \(Self.number(check.topOffset)) "
        + "(tolerance \(Self.number(PopoverPlacementCheck.topTolerance)) pt): "
        + "\(check.topPasses ? "pass" : "fail")")
    line("after-fix check: \(check.passes ? "passed" : "failed")")
  } // End of func reportAfterFixCheck(_:)

  /// Prints how far the popover is from the icon, the menu bar and the visible frame's right
  /// edge, and from each status-bar window's middle.
  private func reportOffsets(
    _ frame: CGRect, expected: CGRect, anchor: CGRect, screen: PopoverPlacement.Screen
  ) {
    line(
      "offsets: popover middle minus icon middle \(Self.number(frame.midX - anchor.midX)), "
        + "popover top minus menu bar bottom \(Self.number(frame.maxY - screen.menuBarBottom)), "
        + "visible right edge minus popover right edge "
        + "\(Self.number(screen.visibleFrame.maxX - frame.maxX)), "
        + "popover minus placement function: x \(Self.number(frame.minX - expected.minX)) "
        + "y \(Self.number(frame.minY - expected.minY))")
    for (index, window) in Self.statusBarWindows().enumerated() {
      line(
        "offsets: popover middle minus status-bar window \(index) middle "
          + "\(Self.number(frame.midX - window.frame.midX))")
    }
  } // End of func reportOffsets(_:expected:anchor:screen:)

  /// The frames `PopoverPlacement` gives for `contentSize`: at the button on its display, and,
  /// for comparison, at each status-bar window on the display nearest to it.
  private func reportPlacements(contentSize: CGSize, button: NSStatusBarButton) {
    let described = NSScreen.screens.map { PopoverPlacement.Screen($0) }
    line(
      "popover content size off screen \(Self.number(contentSize.width)) x "
        + "\(Self.number(contentSize.height)) (PopoverView in an NSHostingView, no window)")
    if let window = button.window {
      let anchor = window.convertToScreen(button.convert(button.bounds, to: nil))
      if let index = PopoverPlacement.screenIndex(for: .rect(anchor), in: described) {
        let frame = PopoverPlacement.frame(
          contentSize: contentSize, anchor: .rect(anchor), screen: described[index])
        line("placement function frame at the button: \(NSStringFromRect(frame)) screen \(index)")
      }
    }
    for (number, window) in Self.statusBarWindows().enumerated() {
      guard let index = PopoverPlacement.screenIndex(for: .rect(window.frame), in: described)
      else { continue }
      let frame = PopoverPlacement.frame(
        contentSize: contentSize, anchor: .rect(window.frame), screen: described[index])
      line(
        "placement function frame at status-bar window \(number): \(NSStringFromRect(frame)) "
          + "nearest screen \(index)")
    } // End of loop over the status-bar windows
  } // End of func reportPlacements(contentSize:button:)

  // MARK: - Reports

  /// The login session (whether the screen is locked, whether the session is on the console)
  /// and the pointer's position.
  private func reportSession() {
    let session = (CGSessionCopyCurrentDictionary() as? [String: Any]) ?? [:]
    let locked = (session["CGSSessionScreenIsLocked"] as? Bool) ?? false
    let onConsole = (session["kCGSSessionOnConsoleKey"] as? Bool).map { $0 ? "yes" : "no" }
    line(
      "session screen locked \(locked ? "yes" : "no"), on console \(onConsole ?? "unknown"), "
        + "session dictionary \(session.isEmpty ? "missing" : "present")")
    line(
      "pointer \(NSStringFromPoint(NSEvent.mouseLocation)), menu bar thickness "
        + "\(Self.number(NSStatusBar.system.thickness))")
  } // End of func reportSession()

  /// Every display, with the menu bar's bottom as the placement function computes it.
  private func reportScreens(_ screens: [NSScreen]) {
    line(
      "screens \(screens.count) (separate spaces \(NSScreen.screensHaveSeparateSpaces ? "yes" : "no"))"
    )
    for (index, screen) in screens.enumerated() {
      let described = PopoverPlacement.Screen(screen)
      let id = Self.displayID(screen)
      let asleep = id.map { CGDisplayIsAsleep($0) != 0 ? "yes" : "no" } ?? "unknown"
      line(
        "screen \(index) display \(id.map(String.init) ?? "unknown") "
          + "main \(screen == NSScreen.main ? "yes" : "no") "
          + "primary \(index == 0 ? "yes" : "no") asleep \(asleep) "
          + "scale \(Self.number(screen.backingScaleFactor)) "
          + "frame \(NSStringFromRect(screen.frame)) "
          + "visible \(NSStringFromRect(screen.visibleFrame)) "
          + "menu bar height \(Self.number(described.reservedMenuBarHeight)) "
          + "hidden \(described.isMenuBarHidden ? "yes (thickness fallback)" : "no") "
          + "bottom \(Self.number(described.menuBarBottom)) "
          + "safe area top \(Self.number(described.safeAreaTop))")
    } // End of loop over the screens
  } // End of func reportScreens(_:)

  /// Every status-bar-level window of the app: its state, the status item buttons inside it,
  /// whether its status item is `item`, and its view tree (classes and frames).
  private func reportStatusBarWindows(label: String, item: NSStatusItem?) {
    let windows = Self.statusBarWindows()
    line("status-bar windows \(label): \(windows.count)")
    for (index, window) in windows.enumerated() {
      let own = Self.statusItem(of: window)
      let itemText = own.map { $0 === item ? "the status item" : "another" } ?? "none"
      line(
        "status-bar window \(index): \(describe(window)) buttons "
          + "\(Self.buttons(in: window.contentView).count) item \(itemText)")
      for entry in Self.viewTree(window.contentView) {
        line("status-bar window \(index) view: \(entry)")
      }
    } // End of loop over the status-bar windows
  } // End of func reportStatusBarWindows(label:item:)

  /// The status item, when AppKit's status-bar window exposes it; its visibility is only read.
  private func reportStatusItem(_ item: NSStatusItem?) {
    guard let item else {
      line("status item not reachable from the status-bar windows")
      return
    }
    line(
      "status item reachable: length \(Self.number(item.length)) visible "
        + "\(item.isVisible ? "yes" : "no") behavior \(item.behavior.rawValue) "
        + "has button \(item.button == nil ? "no" : "yes") menu \(item.menu == nil ? "no" : "yes")")
  }

  /// One status item button: where it is in its window, its window's frame, its rectangle in
  /// screen coordinates, and how it takes a click.
  private func reportButton(_ button: NSStatusBarButton, index: Int?) {
    let name = index.map { "button \($0)" } ?? "clicked button now"
    guard let window = button.window else {
      line("\(name): no window")
      return
    }
    let inScreen = window.convertToScreen(button.convert(button.bounds, to: nil))
    let screen = window.screen.flatMap { Self.index(of: $0, in: NSScreen.screens) }
    let recognizers = button.gestureRecognizers.map { Self.className($0) }
    let keyPaths = Self.observedKeyPaths(button)
    line(
      "\(name): class \(Self.className(button)) hidden \(button.isHidden ? "yes" : "no") "
        + "bounds \(NSStringFromRect(button.bounds)) "
        + "window \(Self.className(window)) frame \(NSStringFromRect(window.frame)) "
        + "screen \(Self.text(screen)) in screen \(NSStringFromRect(inScreen))")
    line(
      "\(name) click: action \(button.action.map(NSStringFromSelector) ?? "none") "
        + "target \(button.target.map { Self.className($0) } ?? "none") "
        + "cell \(button.cell.map { Self.className($0) } ?? "none") "
        + "menu \(button.menu == nil ? "no" : "yes") "
        + "gesture recognizers \(recognizers.isEmpty ? "none" : recognizers.joined(separator: ", ")) "
        + "observed key paths \(keyPaths.isEmpty ? "none" : keyPaths.joined(separator: ", "))")
  } // End of func reportButton(_:index:)

  /// Other processes' on-screen status-bar windows (layer 25), frames only, per display: where
  /// the menu bar items that are still drawn in their own apps sit, next to muxFinder's.
  private func reportOtherProcessesStatusBarWindows(_ screens: [NSScreen]) {
    let frames = Self.otherProcessesStatusBarFrames()
    line("other processes' status-bar windows on screen: \(frames.count)")
    let described = screens.map { PopoverPlacement.Screen($0) }
    var byScreen: [Int: [CGRect]] = [:]
    for frame in frames {
      guard let index = PopoverPlacement.screenIndex(for: .rect(frame), in: described) else {
        continue
      }
      byScreen[index, default: []].append(frame)
    }
    for index in byScreen.keys.sorted() {
      let spans = (byScreen[index] ?? []).sorted { $0.minX < $1.minX }.map { frame in
        "\(Self.number(frame.minX))-\(Self.number(frame.maxX))@\(Self.number(frame.minY))"
      }
      let text = spans.joined(separator: " ")
      line("other processes' status-bar windows on screen \(index): \(text)")
    }
  } // End of func reportOtherProcessesStatusBarWindows(_:)

  /// Every window of the app, when the popover did not appear.
  private func reportAllWindows() {
    line("all windows: \(NSApp.windows.count)")
    for (index, window) in NSApp.windows.enumerated() {
      line("window \(index): \(describe(window))")
    }
  }

  /// A window's class, number, level, visibility, key state, occlusion, screen and frame.
  private func describe(_ window: NSWindow) -> String {
    let screen = window.screen.flatMap { Self.index(of: $0, in: NSScreen.screens) }
    return "class \(Self.className(window)) number \(window.windowNumber) "
      + "level \(window.level.rawValue) visible \(window.isVisible ? "yes" : "no") "
      + "key \(window.isKeyWindow ? "yes" : "no") "
      + "occlusion visible \(window.occlusionState.contains(.visible) ? "yes" : "no") "
      + "screen \(Self.text(screen)) frame \(NSStringFromRect(window.frame))"
  }

  /// Queues one prefixed line for standard output; never blocks (`NonblockingLineWriter`).
  private func line(_ text: String) {
    output.write("\(Self.prefix) \(text)")
  }
}
