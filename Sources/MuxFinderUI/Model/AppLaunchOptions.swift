import Foundation

/// The app's command-line flags (PLAN.md D22, D23).
///
/// - `--preview-fixtures`: no menu bar item, no refresh engine, no host list, no iTerm2; one
///   normal window renders every state from synthetic fixtures, for screenshots.
/// - `--preview-gallery popover|settings|onboarding` (or `--preview-gallery=…`; with
///   `--preview-fixtures`): which states the window shows, the popover's (the default), the
///   Settings window's or the onboarding window's.
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

  /// The options in `arguments`, the process's arguments without the executable path.
  public init(arguments: [String]) {
    var position = arguments.startIndex
    while position < arguments.endIndex {
      let argument = arguments[position]
      position += 1
      if argument == "--preview-fixtures" {
        previewFixtures = true
      } else if argument == "--report-menu-bar-item" {
        reportsMenuBarItem = true
      } else if argument == "--report-login-item-status" {
        reportsLoginItemStatus = true
      } else if Self.valueOptions.contains(argument) {
        guard position < arguments.endIndex else { break }
        set(argument, to: arguments[position])
        position += 1
      } else if argument.hasPrefix("--"), let equals = argument.firstIndex(of: "=") {
        set(String(argument[..<equals]), to: String(argument[argument.index(after: equals)...]))
      }
    } // End of loop over the arguments
  } // End of init(arguments:)

  /// The options that take a value as the next argument.
  static let valueOptions: Set = ["--appearance", "--preview-snapshot", "--preview-gallery"]

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
    default:
      break
    }
  } // End of func set(_:to:)
}
