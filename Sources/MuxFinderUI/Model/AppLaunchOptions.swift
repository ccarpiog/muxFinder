import Foundation

/// The app's command-line flags (PLAN.md D22, D23, D25, D27).
///
/// - `--preview-fixtures`: no menu bar item, no refresh engine, no host list, no iTerm2; one
///   normal window renders every state from synthetic fixtures, for screenshots.
/// - `--preview-gallery popover|settings|onboarding|attach` (or `--preview-gallery=…`; with
///   `--preview-fixtures`): which states the window shows, the popover's (the default), the
///   Settings window's, the onboarding window's, or the session actions' (Phase 10).
/// - `--appearance light|dark` (or `--appearance=…`): forces the appearance of the app's own
///   windows (`NSApp.appearance`); the system appearance and every preference stay as they
///   are.
/// - `--preview-snapshot <file.png>` (or `--preview-snapshot=…`; with `--preview-fixtures`):
///   the app also draws the preview window's contents into that PNG itself, then quits. For
///   when `screencapture -l` cannot capture the window (a locked screen, a sleeping display,
///   no Screen Recording permission).
/// - `--report-menu-bar-item` (normal mode): a read-only diagnostic; two seconds after launch
///   the app prints its own status-bar-level windows (the menu bar item), since on macOS 26 and
///   later `CGWindowListCopyWindowInfo` does not list them under the app's process.
/// - `--report-login-item-status`: a read-only diagnostic; the app prints
///   `SMAppService.mainApp.status` and exits at once, before any window, menu bar item, host
///   list or iTerm2 contact. Nothing is registered or unregistered.
/// - `--selftest attach-local|new-session-local` (or `--selftest=…`), optionally with
///   `--selftest-keep`: a hidden self-test that drives the real `AppModel` path against iTerm2
///   and This Mac's tmux and exits with its status (`SelfTestDriver`). An unknown name, a
///   missing name, `--selftest-keep` alone, or `--selftest` together with another mode is a
///   usage error (`usageError`): the app prints it and exits 2 before contacting anything.
/// - `--remove-persistent-profiles [--dry-run] [--profiles-directory <folder> --lock-directory
///   <folder>]` (`scripts/uninstall.sh`, PLAN.md D27): removes
///   `DynamicProfiles/muxFinder.json` only when it is muxFinder's generated file
///   (`PersistentProfileRemoval`), prints one line and exits at once, before any window, menu
///   bar item, host list or iTerm2 contact; `--dry-run` only reports. The two folders (both or
///   neither, absolute; for checks only) stand in for iTerm2's `DynamicProfiles` and
///   muxFinder's own folder. Any of the three options without the mode, the mode with another
///   mode, one folder alone or a folder that is not absolute is a usage error.
///
/// Anything else is ignored, such as the `-psn_…` and `-NS…` arguments macOS may add.
public struct AppLaunchOptions: Sendable, Hashable {
  /// A forced appearance.
  public enum Appearance: String, Sendable, Hashable, CaseIterable {
    /// Aqua.
    case light
    /// Dark Aqua.
    case dark
  }

  /// Which states the preview window shows.
  public enum PreviewGallery: String, Sendable, Hashable, CaseIterable {
    /// The popover's states.
    case popover
    /// The Settings window's states.
    case settings
    /// The onboarding window's states.
    case onboarding
    /// The session actions' states: progress, results, failures, Move here, Detach, New
    /// session and the banners (PLAN.md D25).
    case attach
  }

  /// Whether to show the fixture gallery instead of the menu bar item.
  public var previewFixtures = false
  /// Which gallery the preview window shows.
  public var previewGallery = PreviewGallery.popover
  /// The forced appearance of the app's windows, if any.
  public var appearance: Appearance?
  /// Where to write the preview window's PNG, if anywhere (preview mode only).
  public var previewSnapshotPath: String?
  /// Whether to print the menu bar item's windows after launch (normal mode only).
  public var reportsMenuBarItem = false
  /// Whether to print the login item status and exit.
  public var reportsLoginItemStatus = false
  /// The self-test to run, if any.
  public var selfTest: SelfTestRequest?
  /// Whether to remove muxFinder's dynamic profile file and exit
  /// (`--remove-persistent-profiles`).
  public var removesPersistentProfiles = false
  /// With `removesPersistentProfiles`: only report what a removal would do (`--dry-run`).
  public var profileRemovalDryRun = false
  /// With `removesPersistentProfiles`: the folder standing in for iTerm2's `DynamicProfiles`
  /// (`--profiles-directory`, checks only).
  public var profilesDirectory: String?
  /// With `removesPersistentProfiles`: the folder standing in for muxFinder's own folder, which
  /// holds `profiles.lock` (`--lock-directory`, checks only).
  public var profilesLockDirectory: String?
  /// Why the arguments are unusable, if they are (the app prints it with `usage` and exits 2).
  public var usageError: String?

  /// The options in `arguments`, the process's arguments without the executable path.
  public init(arguments: [String]) {
    var position = arguments.startIndex
    var keepsSelfTest = false
    while position < arguments.endIndex {
      let argument = arguments[position]
      position += 1
      if argument == "--preview-fixtures" {
        previewFixtures = true
      } else if argument == "--report-menu-bar-item" {
        reportsMenuBarItem = true
      } else if argument == "--report-login-item-status" {
        reportsLoginItemStatus = true
      } else if argument == "--selftest-keep" {
        keepsSelfTest = true
      } else if argument == "--remove-persistent-profiles" {
        removesPersistentProfiles = true
      } else if argument == "--dry-run" {
        profileRemovalDryRun = true
      } else if Self.valueOptions.contains(argument) {
        guard position < arguments.endIndex else {
          if argument == "--selftest" { usageError = "--selftest needs a self-test name." }
          if Self.folderOptions.contains(argument) { usageError = "\(argument) needs a folder." }
          break
        }
        set(argument, to: arguments[position])
        position += 1
      } else if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
        set(String(argument[..<equals]), to: String(argument[argument.index(after: equals)...]))
      }
    } // End of loop over the arguments
    checkSelfTest(keep: keepsSelfTest)
    checkProfileRemoval()
  } // End of init(arguments:)

  /// The options that take a value as the next argument.
  static let valueOptions: Set = [
    "--appearance", "--preview-snapshot", "--preview-gallery", "--selftest",
    "--profiles-directory", "--lock-directory",
  ]

  /// The options of `--remove-persistent-profiles` that name a folder.
  static let folderOptions: Set = ["--profiles-directory", "--lock-directory"]

  /// The usage line of the self-tests.
  public static let selfTestUsage =
    "usage: muxFinder --selftest attach-local|new-session-local [--selftest-keep]"

  /// The usage line of the profile removal.
  public static let profileRemovalUsage =
    "usage: muxFinder --remove-persistent-profiles [--dry-run] "
    + "[--profiles-directory <folder> --lock-directory <folder>]"

  /// Every usage line, printed after a usage error.
  public static let usage = selfTestUsage + "\n" + profileRemovalUsage

  /// Applies `--selftest-keep` and refuses self-test arguments that cannot run: keep without a
  /// self-test, or a self-test with another mode.
  private mutating func checkSelfTest(keep: Bool) {
    guard usageError == nil else { return }
    if keep, selfTest == nil {
      usageError = "--selftest-keep needs --selftest."
    } else if selfTest != nil,
      previewFixtures || reportsMenuBarItem || reportsLoginItemStatus || removesPersistentProfiles
    {
      usageError = "--selftest cannot be combined with another mode."
    } else if keep {
      selfTest?.keep = true
    }
  } // End of func checkSelfTest(keep:)

  /// Refuses profile removal arguments that cannot run: one of its options without the mode
  /// (so a mistyped removal never starts the menu bar app), the mode with another mode, one
  /// folder without the other, or a folder that is not an absolute path.
  private mutating func checkProfileRemoval() {
    guard usageError == nil else { return }
    let hasFolders = profilesDirectory != nil || profilesLockDirectory != nil
    if !removesPersistentProfiles {
      if profileRemovalDryRun || hasFolders {
        usageError =
          "--dry-run, --profiles-directory and --lock-directory need "
          + "--remove-persistent-profiles."
      }
    } else if previewFixtures || reportsMenuBarItem || reportsLoginItemStatus {
      usageError = "--remove-persistent-profiles cannot be combined with another mode."
    } else if hasFolders, profilesDirectory == nil || profilesLockDirectory == nil {
      usageError = "--profiles-directory and --lock-directory go together."
    } else if hasFolders,
      ![profilesDirectory, profilesLockDirectory].allSatisfy({ $0?.hasPrefix("/") == true })
    {
      usageError = "--profiles-directory and --lock-directory need absolute paths."
    }
  } // End of func checkProfileRemoval()

  /// Whether this launch may bring an installed, out-of-date persistent profile file up to date
  /// (PLAN.md D26): only the menu bar app in normal mode, never with `--preview-fixtures`,
  /// `--selftest`, `--report-login-item-status`, `--report-menu-bar-item`,
  /// `--remove-persistent-profiles` or unusable arguments. `--appearance` alone keeps normal
  /// mode.
  public var rewritesProfilesAtLaunch: Bool {
    !previewFixtures && !reportsMenuBarItem && !reportsLoginItemStatus && selfTest == nil
      && !removesPersistentProfiles && usageError == nil
  }

  /// The options of this process.
  public static var current: AppLaunchOptions {
    AppLaunchOptions(arguments: Array(CommandLine.arguments.dropFirst()))
  }

  /// Records the value of the option `name`; unknown names and unusable values are ignored.
  private mutating func set(_ name: String, to value: String) {
    switch name {
    case "--appearance":
      if let appearance = Appearance(rawValue: value.lowercased()) { self.appearance = appearance }
    case "--preview-snapshot":
      if !value.isEmpty { previewSnapshotPath = value }
    case "--preview-gallery":
      if let gallery = PreviewGallery(rawValue: value.lowercased()) { previewGallery = gallery }
    case "--selftest":
      if let kind = SelfTestKind(rawValue: value) {
        selfTest = SelfTestRequest(kind: kind)
      } else {
        usageError = "Unknown self-test. Use attach-local or new-session-local."
      }
    case "--profiles-directory":
      profilesDirectory = value
    case "--lock-directory":
      profilesLockDirectory = value
    default:
      break
    }
  } // End of func set(_:to:)
}
