import AppKit
import Foundation
import MuxFinderUI
import SwiftUI

/// The menu bar app's lifecycle (PLAN.md D22, D30).
///
/// - **Launch:** an accessory app (no Dock icon) that puts its menu bar item and popover panel
///   in place (`MenuBarPopover`) and starts its model once launching finished: it loads the host
///   list and starts the refresh engine, and in normal mode brings an installed, out-of-date
///   persistent profile file up to date (PLAN.md D26; never with `--report-menu-bar-item`).
///   Nothing contacts iTerm2.
/// - **Popover placement diagnostic** (`--report-popover-placement`, PLAN.md Phase I-1): the
///   same menu bar item and panel over an inert model that is never started (no host list,
///   engine, onboarding or iTerm2; `AppEnvironment.placementDiagnostic()`);
///   `PopoverPlacementReport` opens and measures the popover, handles SIGTERM and SIGINT itself
///   and exits.
/// - **Quitting** (the footer's "Quit", SIGTERM or SIGINT from a shell, logout): the model's
///   `shutdown()` cancels the session actions and stops Settings, the engine and the rest at
///   the same time, waits for the session actions within its own budget (reporting those still
///   running), then the app exits with status 0. Sessions, tmux clients and iTerm2 tabs are
///   left as they are.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// How long quitting waits for the model to shut down before exiting anyway: longer than the
  /// model's own budget for the session actions (`AppModel.terminationDeadline`), so the model
  /// reports what it did not finish before the app exits.
  static let shutdownDeadline = AppModel.terminationDeadline

  /// The popover's model.
  let model: AppModel
  /// The menu bar item and the popover panel, once launching finished.
  private var menuBarPopover: MenuBarPopover?
  /// The SIGTERM and SIGINT sources.
  private var signalSources: [any DispatchSourceSignal] = []
  /// The popover placement diagnostic, while it runs.
  private var placementReport: PopoverPlacementReport?
  /// Whether quitting already started.
  private var isTerminating = false
  /// Whether AppKit was told it may terminate.
  private var didReplyToTerminate = false

  /// Builds the model over the real core (over an inert environment for the popover placement
  /// diagnostic); nothing runs yet.
  override init() {
    let options = AppLaunchOptions.current
    model = AppModel(
      environment: options.reportsPopoverPlacement
        ? .placementDiagnostic()
        : .production(rewritesProfilesAtLaunch: options.rewritesProfilesAtLaunch))
    super.init()
  }

  /// Applies the options, puts the menu bar item in place and starts the model, or runs the
  /// popover placement diagnostic instead (the model is then never started).
  func applicationDidFinishLaunching(_ notification: Notification) {
    let options = AppLaunchOptions.current
    if options.reportsPopoverPlacement {
      NSApp.setActivationPolicy(.accessory)
      QuitSignals.applyAppearance(options.appearance)
      let popover = MenuBarPopover(model: model)
      menuBarPopover = popover
      let report = PopoverPlacementReport(model: model, popover: popover)
      placementReport = report
      report.start()
      return
    }
    signalSources = QuitSignals.install()
    NSApp.setActivationPolicy(.accessory)
    QuitSignals.applyAppearance(options.appearance)
    menuBarPopover = MenuBarPopover(model: model)
    Task { await model.start() }
    if options.reportsMenuBarItem {
      Task {
        try? await Task.sleep(for: .seconds(2))
        Self.reportMenuBarItem()
      }
    }
  } // End of func applicationDidFinishLaunching(_:)

  /// `--report-menu-bar-item`: prints the app's own status-bar-level windows (the menu bar
  /// item, one per display) with their visibility and frames. Read-only. On macOS 26 and
  /// later the item is drawn outside the app's process, so `CGWindowListCopyWindowInfo` does
  /// not list it under the app's pid; AppKit still lists its windows in `NSApp.windows`.
  private static func reportMenuBarItem() {
    let items = NSApp.windows.filter { $0.level == .statusBar }
    var lines = ["muxFinder menu bar item windows: \(items.count)"]
    for window in items {
      lines.append(
        "muxFinder menu bar item: level \(window.level.rawValue) visible \(window.isVisible) "
          + "frame \(NSStringFromRect(window.frame))")
    }
    FileHandle.standardOutput.write(Data((lines.joined(separator: "\n") + "\n").utf8))
  } // End of func reportMenuBarItem()

  /// Reopening the running app (Finder, `open`) opens no window: the app lives in the menu
  /// bar.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool)
    -> Bool
  {
    false
  }

  /// Quits only once the model has shut down (or `shutdownDeadline` passed).
  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    guard !isTerminating else { return .terminateLater }
    isTerminating = true
    Task {
      await model.shutdown()
      replyToTerminate()
    }
    Task {
      try? await Task.sleep(for: Self.shutdownDeadline)
      replyToTerminate()
    }
    return .terminateLater
  } // End of func applicationShouldTerminate(_:)

  /// Lets AppKit finish terminating, once.
  private func replyToTerminate() {
    guard !didReplyToTerminate else { return }
    didReplyToTerminate = true
    NSApp.reply(toApplicationShouldTerminate: true)
  }
}

/// What both modes share: quitting on SIGTERM and SIGINT, and the forced appearance.
enum QuitSignals {
  /// Turns SIGTERM and SIGINT into a normal quit, so a shell can end the app cleanly, and
  /// returns the sources (keep them). The quit goes through `AppTermination.request()`, never
  /// straight from the signal source's main-queue block (see there why).
  @MainActor
  static func install() -> [any DispatchSourceSignal] {
    [SIGTERM, SIGINT].map { number in
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
      source.setEventHandler { AppTermination.request() }
      source.resume()
      return source
    }
  }

  /// Forces the appearance of the app's own windows (`NSApp.appearance`); the system
  /// appearance and preferences are left alone. `nil` follows the system.
  @MainActor
  static func applyAppearance(_ appearance: AppLaunchOptions.Appearance?) {
    guard let appearance else { return }
    NSApp.appearance = NSAppearance(named: appearance == .dark ? .darkAqua : .aqua)
  }
}
