import Foundation

/// The state of macOS's Automation permission for sending Apple events to one app, as
/// `AEDeterminePermissionToAutomateTarget` reports it with `askUserIfNeeded` false, so reading
/// it never shows a prompt (PLAN.md D38). The permission belongs to the process macOS holds
/// responsible for the sender: for a command run from a shell, the terminal app it runs in.
public enum AutomationPermission: Sendable, Hashable {
  /// `noErr`: Apple events may be sent.
  case granted
  /// `errAEEventNotPermitted` (-1743): the user turned it off, or refused the prompt.
  case denied
  /// `errAEEventWouldRequireUserConsent` (-1744): macOS would have to ask first.
  case notDetermined
  /// `procNotFound` (-600): the app is not running, so macOS cannot tell.
  case targetNotRunning
  /// Any other status, kept as it came.
  case other(status: Int32)

  /// `noErr`.
  public static let grantedStatus: Int32 = 0
  /// `errAEEventNotPermitted`.
  public static let deniedStatus: Int32 = -1743
  /// `errAEEventWouldRequireUserConsent`.
  public static let notDeterminedStatus: Int32 = -1744
  /// `procNotFound`.
  public static let targetNotRunningStatus: Int32 = -600

  /// Maps the status `AEDeterminePermissionToAutomateTarget` returned.
  public init(status: Int32) {
    switch status {
    case Self.grantedStatus: self = .granted
    case Self.deniedStatus: self = .denied
    case Self.notDeterminedStatus: self = .notDetermined
    case Self.targetNotRunningStatus: self = .targetNotRunning
    default: self = .other(status: status)
    }
  }

  /// A stable name for logs and JSON: `granted`, `denied`, `notDetermined`,
  /// `targetNotRunning` or `other`.
  public var kind: String {
    switch self {
    case .granted: return "granted"
    case .denied: return "denied"
    case .notDetermined: return "notDetermined"
    case .targetNotRunning: return "targetNotRunning"
    case .other: return "other"
    }
  }

  /// Whether Apple events may be sent now without a prompt: only `granted`.
  public var allowsEventsWithoutPrompt: Bool { self == .granted }
} // End of enum AutomationPermission
