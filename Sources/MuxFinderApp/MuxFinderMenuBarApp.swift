import AppKit
import MuxFinderUI
import SwiftUI

/// The entry point (PLAN.md D22): `--preview-fixtures` runs the fixture window on a plain
/// `NSApplication` (no SwiftUI scene, so no menu bar item is ever created and nothing is
/// recorded for one); every other launch runs the menu bar app.
@main
enum MuxFinderMain {
  /// Picks the mode from the command line and runs it; never returns.
  @MainActor
  static func main() {
    let options = AppLaunchOptions.current
    if options.previewFixtures {
      PreviewAppDelegate.run(options: options)
    } else {
      MuxFinderMenuBarApp.main()
    }
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
