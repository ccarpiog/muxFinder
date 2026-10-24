import Foundation

/// The app's command-line flags (PLAN.md D22, D23, D25, D27).
///
/// - `--preview-fixtures`: no menu bar item, no refresh engine, no host list, no iTerm2; one
///   normal window renders every state from synthetic fixtures, for screenshots.
/// - `--preview-gallery popover|settings|onboarding|attach|switcher` (or `--preview-gallery=…`;
///   with `--preview-fixtures`): which states the window shows, the popover's (the default),
///   the Settings window's, the onboarding window's, the session actions' (Phase 10), or the
///   session switcher's (PLAN.md D32, Phase I-3b).
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
/// - `--report-popover-placement` (PLAN.md Phase I-1, D30): a read-only diagnostic of where the
///   popover opens. muxFinder's menu bar item and popover panel run over an inert model (never
///   started: no host list read, no engine, no iTerm2, no onboarding;
///   `AppEnvironment.placementDiagnostic()`); the app prints the displays, its status-bar
///   windows and status item button; when that button has an action or a menu (muxFinder's own
///   has its action) it opens the popover with the button's `performClick(_:)` for at most 3 s,
///   prints the panel's frame, the one `PopoverPlacement` would give and the after-fix check,
///   closes it and exits (0 measured, 1 clicked but the popover never appeared, 3 interrupted
///   by a signal, the open limit, the 10 s deadline or its watchdog, 4 not openable in process:
///   no button, or one with no action and no menu). Combined with another mode it is a usage
///   error.
/// - `--report-login-item-status`: a read-only diagnostic; the app prints
///   `SMAppService.mainApp.status` and exits at once, before any window, menu bar item, host
///   list or iTerm2 contact. Nothing is registered or unregistered.
/// - `--report-hotkey-registration` (PLAN.md D32, Phase I-3): a diagnostic of Carbon's hotkey
///   registration in this process. The app registers fixed test combinations unlikely to be in
///   use (⌃⌥⇧⌘F19, then ⌥ and ⌥⇧ ones), checks that a second registration of the same
///   combination is refused as taken, unregisters every one before it exits on every way out,
///   prints one `muxFinder hotkey registration: …` line per check and exits (0 every check as
///   expected, 1 a check failed, 3 SIGTERM or SIGINT arrived during the checks). No window,
///   menu bar item, engine, host list, iTerm2 or `preferences.json`; no event is posted.
///   Combined with another mode it is a usage error.
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
    /// The session switcher's states: the list, a filtered list, New session with a name, the
    /// form, an action in progress, failures, no hosts, hosts checking or unreachable
    /// (PLAN.md D32).
    case switcher
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
  /// Whether to run the popover placement diagnostic and exit (`--report-popover-placement`).
  public var reportsPopoverPlacement = false
  /// Whether to print the login item status and exit.
  public var reportsLoginItemStatus = false
  /// Whether to run the hotkey registration diagnostic and exit
  /// (`--report-hotkey-registration`).
  public var reportsHotkeyRegistration = false
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
      } else if argument == "--report-popover-placement" {
        reportsPopoverPlacement = true
      } else if argument == "--report-login-item-status" {
        reportsLoginItemStatus = true
      } else if argument == "--report-hotkey-registration" {
        reportsHotkeyRegistration = true
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
    checkPopoverPlacement()
    checkHotkeyRegistration()
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

  /// The usage line of the popover placement diagnostic.
  public static let popoverPlacementUsage =
    "usage: muxFinder --report-popover-placement [--appearance light|dark]"

  /// The usage line of the hotkey registration diagnostic.
  public static let hotkeyRegistrationUsage = "usage: muxFinder --report-hotkey-registration"

  /// Every usage line, printed after a usage error.
  public static let usage =
    selfTestUsage + "\n" + profileRemovalUsage + "\n" + popoverPlacementUsage + "\n"
    + hotkeyRegistrationUsage

  /// Applies `--selftest-keep` and refuses self-test arguments that cannot run: keep without a
  /// self-test, or a self-test with another mode.
  private mutating func checkSelfTest(keep: Bool) {
    guard usageError == nil else { return }
    if keep, selfTest == nil {
      usageError = "--selftest-keep needs --selftest."
    } else if selfTest != nil,
      previewFixtures || reportsMenuBarItem || reportsLoginItemStatus || removesPersistentProfiles
        || reportsPopoverPlacement || reportsHotkeyRegistration
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
    } else if previewFixtures || reportsMenuBarItem || reportsLoginItemStatus
      || reportsPopoverPlacement || reportsHotkeyRegistration
    {
      usageError = "--remove-persistent-profiles cannot be combined with another mode."
    } else if hasFolders, profilesDirectory == nil || profilesLockDirectory == nil {
      usageError = "--profiles-directory and --lock-directory go together."
    } else if hasFolders,
      ![profilesDirectory, profilesLockDirectory].allSatisfy({ $0?.hasPrefix("/") == true })
    {
      usageError = "--profiles-directory and --lock-directory need absolute paths."
    }
  } // End of func checkProfileRemoval()

  /// Refuses `--report-popover-placement` with another mode (the preview window, the menu bar
  /// item report, the login item report; the self-tests and the profile removal refuse it
  /// themselves).
  private mutating func checkPopoverPlacement() {
    guard usageError == nil, reportsPopoverPlacement else { return }
    if previewFixtures || reportsMenuBarItem || reportsLoginItemStatus || reportsHotkeyRegistration
    {
      usageError = "--report-popover-placement cannot be combined with another mode."
    }
  }

  /// Refuses `--report-hotkey-registration` with another mode (the preview window, the menu
  /// bar item report, the login item report; the self-tests, the profile removal and the
  /// popover placement diagnostic refuse it themselves).
  private mutating func checkHotkeyRegistration() {
    guard usageError == nil, reportsHotkeyRegistration else { return }
    if previewFixtures || reportsMenuBarItem || reportsLoginItemStatus {
      usageError = "--report-hotkey-registration cannot be combined with another mode."
    }
  }

  /// Whether this launch may bring an installed, out-of-date persistent profile file up to date
  /// (PLAN.md D26): only the menu bar app in normal mode, never with `--preview-fixtures`,
  /// `--selftest`, `--report-login-item-status`, `--report-menu-bar-item`,
  /// `--report-popover-placement`, `--report-hotkey-registration`,
  /// `--remove-persistent-profiles` or unusable arguments. `--appearance` alone keeps normal
  /// mode.
  public var rewritesProfilesAtLaunch: Bool {
    isNormalMode
  }

  /// Whether this launch reads `preferences.json` and registers the session switcher shortcut
  /// (PLAN.md D32): only the menu bar app in normal mode, as `rewritesProfilesAtLaunch`; never
  /// a self-test, a preview, a `--report-*` flag or `--remove-persistent-profiles`.
  public var registersGlobalShortcut: Bool {
    isNormalMode
  }

  /// The menu bar app with no diagnostic, preview, self-test or removal and usable arguments.
  var isNormalMode: Bool {
    !previewFixtures && !reportsMenuBarItem && !reportsLoginItemStatus && selfTest == nil
      && !removesPersistentProfiles && !reportsPopoverPlacement && !reportsHotkeyRegistration
      && usageError == nil
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
