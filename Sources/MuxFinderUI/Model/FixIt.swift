import Foundation
import MuxFinderCore

/// A button that helps the user fix a problem muxFinder cannot fix itself (PLAN.md Phase 9,
/// D23). Wherever an error that has one is shown (the popover and Settings), the model exposes
/// it next to the error; performing it goes through a seam (`openURL`, the login item), so tests
/// never open System Settings.
///
/// - `openAutomationSettings`: macOS refused muxFinder's Apple event to iTerm2
///   (`ITerm2Error.automationDenied`); opens System Settings › Privacy & Security › Automation.
/// - `explainPythonAPI`: iTerm2's API server is off (`ITerm2Error.apiDisabled`); shows where the
///   iTerm2 setting is. muxFinder never changes iTerm2's preferences and never opens iTerm2 for
///   this.
/// - `openLoginItemsSettings`: launch at login waits for the user's approval
///   (`SMAppService.Status.requiresApproval`); opens System Settings › General › Login Items.
public enum FixIt: String, Sendable, Hashable, CaseIterable {
  /// Opens System Settings › Privacy & Security › Automation.
  case openAutomationSettings
  /// Explains how to turn on iTerm2's Python API.
  case explainPythonAPI
  /// Opens System Settings › General › Login Items.
  case openLoginItemsSettings

  /// What performing a fix-it does.
  public enum Action: Sendable, Hashable {
    /// Opens this URL (through the model's `openURL` seam).
    case openURL(URL)
    /// Shows `FixIt.explanation` next to the error.
    case explain
    /// Opens Login Items in System Settings (through the login item seam).
    case openLoginItems
  }

  /// System Settings › Privacy & Security › Automation. The `com.apple.preference.security`
  /// pane with the `Privacy_Automation` anchor, which System Settings still accepts on macOS 13
  /// and later.
  public static let automationSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!

  /// The fix-it for an iTerm2 error, looking through `notSent`: `automationDenied` opens the
  /// Automation settings, `apiDisabled` explains the iTerm2 setting; any other error (or none)
  /// has no fix-it.
  public init?(error: ITerm2Error?) {
    switch error {
    case .automationDenied: self = .openAutomationSettings
    case .apiDisabled: self = .explainPythonAPI
    case .notSent(let reason): self.init(error: reason)
    default: return nil
    }
  }

  /// The fix-it for an attach failure that carries an iTerm2 error.
  public init?(failure: AttachFailure) {
    switch failure {
    case .iTerm2(let error), .attachmentCheckFailed(let error):
      self.init(error: error)
    case .identityCheckFailed(let error):
      self.init(error: error)
    default:
      return nil
    }
  }

  /// The button's title, sentence case.
  public var buttonTitle: String {
    switch self {
    case .openAutomationSettings: return "Open Automation settings"
    case .explainPythonAPI: return "How to turn it on"
    case .openLoginItemsSettings: return "Open Login Items settings"
    }
  }

  /// What the button does.
  public var action: Action {
    switch self {
    case .openAutomationSettings: return .openURL(Self.automationSettingsURL)
    case .explainPythonAPI: return .explain
    case .openLoginItemsSettings: return .openLoginItems
    }
  }

  /// The text shown when the fix-it explains rather than opens something.
  public var explanation: String? {
    switch self {
    case .explainPythonAPI:
      return "In iTerm2, choose iTerm2 › Settings, then General › Magic, and turn on “Enable "
        + "Python API”. muxFinder uses iTerm2's API to find and open tmux tabs; it never changes "
        + "iTerm2's settings itself."
    case .openAutomationSettings, .openLoginItemsSettings:
      return nil
    }
  }
}
