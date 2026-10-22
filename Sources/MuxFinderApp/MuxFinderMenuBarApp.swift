import AppKit
import Foundation
import MuxFinderUI
import SwiftUI

/// The entry point (PLAN.md D22, D23): `--report-login-item-status` prints the login item
/// status and exits; `--preview-fixtures` runs the fixture window on a plain `NSApplication`
/// (no SwiftUI scene, so no menu bar item is ever created and nothing is recorded for one);
/// every other launch runs the menu bar app.
@main
enum MuxFinderMain {
  /// Picks the mode from the command line and runs it; never returns.
  @MainActor
  static func main() {
    let options = AppLaunchOptions.current
    if options.reportsLoginItemStatus {
      reportLoginItemStatus()
    } else if options.previewFixtures {
      PreviewAppDelegate.run(options: options)
    } else {
      MuxFinderMenuBarApp.main()
    }
  }

  /// `--report-login-item-status`: prints `SMAppService.mainApp.status` and whether this
  /// process runs from an app bundle, then exits 0. Read-only: nothing is registered, no
  /// window or menu bar item appears, and no host list or iTerm2 is touched.
  @MainActor
  static func reportLoginItemStatus() -> Never {
    let status = SystemLoginItem().status
    let isBundle = Bundle.main.bundleURL.pathExtension == "app"
    FileHandle.standardOutput.write(
      Data(
        ("muxFinder login item status: \(status.code) (running from an app bundle: "
          + "\(isBundle ? "yes" : "no"))\n").utf8))
    exit(0)
  }
}

/// The muxFinder menu bar app: a menu bar extra whose window is the popover. Lifecycle and
/// quitting live in `AppDelegate`; model and views in MuxFinderUI.
struct MuxFinderMenuBarApp: App {
  /// Owns the model and the app's lifecycle.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// The menu bar extra, an SF Symbol in the menu bar.
  var body: some Scene {
    MenuBarExtra("muxFinder", systemImage: "terminal") {
      PopoverView(model: appDelegate.model, isLive: true)
    }
    .menuBarExtraStyle(.window)
  }
}
