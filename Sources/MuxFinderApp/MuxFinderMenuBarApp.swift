import AppKit
import Foundation
import MuxFinderCore
import MuxFinderUI
import SwiftUI

/// The entry point (PLAN.md D22, D23, D25, D27): unusable arguments print the usage and exit
/// 2; `--remove-persistent-profiles` removes muxFinder's dynamic profile file (only when it is
/// muxFinder's generated file) and exits; `--report-login-item-status` prints the login item
/// status and exits; `--preview-fixtures` runs the fixture window on a plain `NSApplication`
/// (no `MenuBarPopover`, so no menu bar item is ever created and nothing is recorded for one);
/// `--selftest` runs a self-test on a plain `NSApplication` too; every other launch runs the
/// menu bar app (with `--report-popover-placement`, over a model that is never started, to
/// open and measure the popover and exit).
@main
enum MuxFinderMain {
  /// Picks the mode from the command line and runs it; never returns.
  @MainActor
  static func main() {
    let options = AppLaunchOptions.current
    if let usageError = options.usageError {
      FileHandle.standardError.write(
        Data("muxFinder: \(usageError)\n\(AppLaunchOptions.usage)\n".utf8))
      exit(PersistentProfileRemoval.exitUsage)
    } else if let selfTest = options.selfTest {
      SelfTestAppDelegate.run(request: selfTest)
    } else if options.removesPersistentProfiles {
      removePersistentProfiles(options)
    } else if options.reportsLoginItemStatus {
      reportLoginItemStatus()
    } else if options.previewFixtures {
      PreviewAppDelegate.run(options: options)
    } else {
      MuxFinderMenuBarApp.main()
    }
  } // End of static func main()

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

  /// `--remove-persistent-profiles` (`scripts/uninstall.sh`, PLAN.md D27): removes
  /// `DynamicProfiles/muxFinder.json` through `PersistentProfileRemoval` only when it is
  /// muxFinder's generated file (with `--dry-run` only reports), prints one line and exits with
  /// its status. No window, menu bar item, host list or iTerm2 contact.
  @MainActor
  static func removePersistentProfiles(_ options: AppLaunchOptions) -> Never {
    let removal = PersistentProfileRemoval(
      profilesDirectory: options.profilesDirectory,
      lockDirectory: options.profilesLockDirectory,
      dryRun: options.profileRemovalDryRun)
    let outcome = removal.run()
    FileHandle.standardOutput.write(Data((removal.report(outcome) + "\n").utf8))
    exit(PersistentProfileRemoval.exitStatus(for: outcome))
  }
}

/// The muxFinder menu bar app (PLAN.md D22, D30). Its menu bar item and popover are
/// muxFinder's own (`MenuBarPopover`, an `NSStatusItem` and a panel, created by `AppDelegate`),
/// not a SwiftUI scene: SwiftUI's `MenuBarExtra` gives no hook for its window's position. The
/// SwiftUI app stays for its standard main menu (Edit commands for the text fields, Quit,
/// Close), which an accessory app's windows still use; its one scene is an empty `Settings`
/// whose menu item is removed, so nothing ever opens it (muxFinder's Settings window is its
/// own, D23). Lifecycle and quitting live in `AppDelegate`; model and views in MuxFinderUI.
struct MuxFinderMenuBarApp: App {
  /// Owns the model, the menu bar item and the app's lifecycle.
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

  /// An empty `Settings` scene that nothing opens (no window at launch, no menu item).
  var body: some Scene {
    Settings {
      EmptyView()
    }
    .commands {
      CommandGroup(replacing: .appSettings) {}
    }
  }
}
