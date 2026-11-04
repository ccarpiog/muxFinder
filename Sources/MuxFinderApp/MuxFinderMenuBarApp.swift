import AppKit
import Foundation
import MuxFinderCore
import MuxFinderUI

/// The entry point (PLAN.md D22, D23, D25, D27, D33): unusable arguments print the usage and
/// exit 2; `--remove-persistent-profiles` removes muxFinder's dynamic profile file (only when
/// it is muxFinder's generated file) and exits; `--report-login-item-status` prints the login
/// item status and exits; `--report-hotkey-registration` checks Carbon's hotkey registration
/// with fixed test combinations and exits (PLAN.md D32); `--preview-fixtures` runs the fixture
/// window on a plain `NSApplication`
/// (no `MenuBarPopover`, so no menu bar item is ever created and nothing is recorded for one);
/// `--selftest` runs a self-test on a plain `NSApplication` too; every other launch runs the
/// menu bar app, on a plain `NSApplication` as well (with `--report-popover-placement`, over a
/// model that is never started, to open and measure the popover and exit).
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
    } else if options.reportsHotkeyRegistration {
      HotkeyRegistrationReport.run()
    } else if options.previewFixtures {
      PreviewAppDelegate.run(options: options)
    } else {
      MuxFinderMenuBarApp.run()
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

/// The muxFinder menu bar app (PLAN.md D22, D30, D33): a plain `NSApplication` whose delegate
/// is `AppDelegate` and whose main menu is muxFinder's own (`MainMenu`), with no SwiftUI `App`
/// and no scene. Its menu bar item and popover are muxFinder's own (`MenuBarPopover`, an
/// `NSStatusItem` and a panel, created by `AppDelegate`), and so are its Settings and
/// onboarding windows (D23, D24), each shown only when asked for; nothing else can open a
/// window, so a launch shows none but onboarding (only while there is no host list). On macOS
/// 27.3 a SwiftUI `App` shows its first scene's window when launching finishes, even a
/// `Settings` scene whose menu item is removed: the empty "muxFinder Settings" window every
/// launch showed until D33 (*Verified facts*, Phase I-4). The main menu is never shown (an
/// accessory app has no menu bar); it carries the key equivalents the text fields and windows
/// use. Lifecycle and quitting live in `AppDelegate`; model and views in MuxFinderUI.
@MainActor
enum MuxFinderMenuBarApp {
  /// Runs the menu bar app; returns only if the run loop is stopped (quitting exits the
  /// process first).
  static func run() {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    MainMenu.install(in: app)
    withExtendedLifetime(delegate) { app.run() }
  }
}
