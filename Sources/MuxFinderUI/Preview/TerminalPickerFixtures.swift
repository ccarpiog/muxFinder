import Foundation
import MuxFinderCore

/// The terminal picker's fixed states for previews and the Settings and onboarding galleries
/// (PLAN.md D38, Phase I-12d1), from synthetic data only: the built-in Terminal and Ghostty,
/// invented versions and a made-up user definition. Building them reads nothing and runs
/// nothing.
public enum TerminalPickerFixtures {
  /// Terminal's wording.
  public static let terminalWording = TerminalWording(name: "Terminal", kind: .terminalApp)
  /// Ghostty's wording.
  public static let ghosttyWording = TerminalWording(name: "Ghostty", kind: .ghostty)
  /// The helper path the fixtures' persistent work commands run.
  public static let helperPath = "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch"

  /// iTerm2's row.
  static let iTerm2 = TerminalPickerRow(
    id: TerminalChoice.iTerm2ID, name: "iTerm2", version: "3.7.7",
    note: TerminalPickerContent.iTerm2Note, isPlain: false)

  /// Terminal's row with `permission`.
  static func terminal(_ permission: TerminalPermissionLabel) -> TerminalPickerRow {
    TerminalPickerRow(
      id: "terminal", name: "Terminal", version: "2.15", permission: permission,
      note: TerminalPickerContent.plainNote, isPlain: true)
  }

  /// Ghostty's row with `permission` (version 1.3.1 unless `version` says otherwise), and the
  /// reason it cannot be used, if any.
  static func ghostty(
    _ permission: TerminalPermissionLabel, version: String = "1.3.1", reason: String? = nil
  ) -> TerminalPickerRow {
    TerminalPickerRow(
      id: "ghostty", name: "Ghostty", version: version, permission: permission,
      note: TerminalPickerContent.plainNote, unavailableReason: reason, isPlain: true)
  }

  /// A user definition that starts its app with `exec` (no permission needed).
  static let userExec = TerminalPickerRow(
    id: "wezterm", name: "WezTerm", version: "20240203", permission: .notNeeded,
    note: TerminalPickerContent.plainNote, isPlain: true)

  /// A fixture of `rows` with `selectedID`, its applied choice worded as `wording`.
  static func fixture(
    _ rows: [TerminalPickerRow], selected selectedID: String?, wording: TerminalWording,
    configure: (inout TerminalPickerContent) -> Void = { _ in }
  ) -> TerminalPickerFixture {
    var content = TerminalPickerContent(rows: rows, selectedID: selectedID)
    configure(&content)
    return TerminalPickerFixture(content: content, wording: wording)
  }

  /// iTerm2 chosen (the default), Terminal not asked yet, Ghostty not running.
  public static let iTerm2Chosen = fixture(
    [iTerm2, ghostty(.checkedWhenRunning), terminal(.notAskedYet)],
    selected: TerminalChoice.iTerm2ID, wording: .iTerm2)

  /// Terminal chosen and allowed.
  public static let terminalAllowed = fixture(
    [iTerm2, ghostty(.checkedWhenRunning), terminal(.allowed)], selected: "terminal",
    wording: terminalWording)

  /// Terminal chosen and not allowed ("Allow in System Settings…"), Ghostty's permission
  /// unknown, and a user `exec` definition that needs none.
  public static let terminalNotAllowed = fixture(
    [iTerm2, ghostty(.unknown), terminal(.notAllowed), userExec], selected: "terminal",
    wording: terminalWording)

  /// No iTerm2 installed: Terminal, the default, chosen and not asked yet.
  public static let terminalNotAskedNoITerm2 = fixture(
    [ghostty(.checkedWhenRunning), terminal(.notAskedYet)], selected: "terminal",
    wording: terminalWording)

  /// Terminal chosen while it is not running: macOS tells only while it runs.
  public static let terminalNotRunning = fixture(
    [iTerm2, ghostty(.checkedWhenRunning), terminal(.checkedWhenRunning)], selected: "terminal",
    wording: terminalWording)

  /// Terminal chosen with a permission status macOS did not explain.
  public static let terminalUnknown = fixture(
    [iTerm2, ghostty(.checkedWhenRunning), terminal(.unknown)], selected: "terminal",
    wording: terminalWording)

  /// Ghostty chosen and allowed.
  public static let ghosttyChosen = fixture(
    [iTerm2, ghostty(.allowed), terminal(.notAskedYet)], selected: "ghostty",
    wording: ghosttyWording)

  /// Ghostty chosen but too old: kept selected with its reason, never replaced.
  public static let unavailable = fixture(
    [
      iTerm2,
      ghostty(.checkedWhenRunning, version: "1.2", reason: "Ghostty 1.2 is older than 1.3."),
      terminal(.notAskedYet),
    ], selected: "ghostty", wording: ghosttyWording)

  /// A stored terminal no definition has (its file unusable), kept selected with its reason,
  /// and the loader's problems listed by file name and reason.
  public static let problems = fixture(
    [
      iTerm2, ghostty(.checkedWhenRunning), terminal(.notAskedYet),
      TerminalPickerRow(
        id: "warp", name: TerminalChoice.displayID("warp"),
        unavailableReason: "No terminal named “warp”.", isPlain: false),
    ], selected: "warp", wording: TerminalWording(name: "the chosen terminal", kind: .other)
  ) {
    $0.problems = [
      TerminalPickerProblem(
        id: 0, fileName: "warp.json",
        reason: TerminalDefinitionProblem.unknownKey("colors").message),
      TerminalPickerProblem(
        id: 1, fileName: "kitty.json", reason: TerminalDefinitionProblem.notJSON.message),
    ]
  }

  /// Terminal chosen while a session action runs: still iTerm2 until it ends.
  public static let pending = fixture(
    [iTerm2, ghostty(.checkedWhenRunning), terminal(.notAskedYet)], selected: "terminal",
    wording: .iTerm2
  ) {
    $0.pendingNote = TerminalPickerContent.pendingText
  }

  /// A change refused by the preferences file: the old choice kept, the store's error shown.
  public static let saveRefused = fixture(
    [iTerm2, ghostty(.checkedWhenRunning), terminal(.notAskedYet)],
    selected: TerminalChoice.iTerm2ID, wording: .iTerm2
  ) {
    $0.saveError =
      PreferencesStoreError.fileNotUsable(.unsafe(.permissionsTooOpen)).errorDescription
  }
} // End of enum TerminalPickerFixtures
