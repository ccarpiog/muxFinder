import Foundation
import ServiceManagement

/// What macOS says about muxFinder as a login item: `SMAppService.Status` as a value the model
/// and its tests can hold (PLAN.md D23).
public enum LoginItemStatus: Sendable, Hashable {
  /// Registered and allowed: muxFinder opens at login.
  case enabled
  /// Not registered.
  case notRegistered
  /// Registered, but the user must allow it in System Settings › General › Login Items.
  case requiresApproval
  /// macOS cannot find muxFinder as a login item (for example a copy that is not an installed
  /// app bundle).
  case notFound
  /// A status this muxFinder does not know, with its raw value.
  case unknown(Int)

  /// The status for `SMAppService.Status`.
  public init(_ status: SMAppService.Status) {
    switch status {
    case .enabled: self = .enabled
    case .notRegistered: self = .notRegistered
    case .requiresApproval: self = .requiresApproval
    case .notFound: self = .notFound
    @unknown default: self = .unknown(status.rawValue)
    }
  }

  /// A stable, machine-readable name (`--report-login-item-status` and diagnostics print it).
  public var code: String {
    switch self {
    case .enabled: return "enabled"
    case .notRegistered: return "notRegistered"
    case .requiresApproval: return "requiresApproval"
    case .notFound: return "notFound"
    case .unknown(let raw): return "unknown(\(raw))"
    }
  }
}

/// muxFinder as a login item (PLAN.md D23). `SystemLoginItem` uses `SMAppService.mainApp`; tests
/// use a fake, so no test ever changes the user's login items.
@MainActor
public protocol LoginItemControlling: Sendable {
  /// The current status, read afresh. Reading never registers anything.
  var status: LoginItemStatus { get }
  /// Registers muxFinder to open at login.
  func register() throws
  /// Unregisters muxFinder.
  func unregister() throws
  /// Opens System Settings › General › Login Items.
  func openSystemSettingsLoginItems()
}

/// The real login item: `SMAppService.mainApp`.
@MainActor
public final class SystemLoginItem: LoginItemControlling {
  /// Creates the login item; nothing is read or registered until asked.
  public init() {}

  /// `SMAppService.mainApp.status`.
  public var status: LoginItemStatus {
    LoginItemStatus(SMAppService.mainApp.status)
  }

  /// `SMAppService.mainApp.register()`.
  public func register() throws {
    try SMAppService.mainApp.register()
  }

  /// `SMAppService.mainApp.unregister()`.
  public func unregister() throws {
    try SMAppService.mainApp.unregister()
  }

  /// `SMAppService.openSystemSettingsLoginItems()`.
  public func openSystemSettingsLoginItems() {
    SMAppService.openSystemSettingsLoginItems()
  }
}

/// What the General tab shows for a login item status: the toggle and an explanation, with a
/// fix-it when the user must act in System Settings.
public struct LaunchAtLoginContent: Sendable, Hashable {
  /// Whether the toggle is on (registered, approved or waiting for approval).
  public var isOn: Bool
  /// The line under the toggle.
  public var message: String
  /// The button that helps, if any.
  public var fixIt: FixIt?

  /// The content for `status`.
  public init(status: LoginItemStatus) {
    switch status {
    case .enabled:
      isOn = true
      message = "muxFinder opens when you log in."
      fixIt = nil
    case .notRegistered:
      isOn = false
      message = "muxFinder doesn't open when you log in."
      fixIt = nil
    case .requiresApproval:
      isOn = true
      message =
        "macOS needs your approval first: turn on muxFinder in System Settings › "
        + "General › Login Items."
      fixIt = .openLoginItemsSettings
    case .notFound:
      isOn = false
      message =
        "macOS can't find muxFinder as a login item. Launch at login works for the "
        + "app installed in /Applications (or ~/Applications) and opened from there, not for "
        + "a copy run from a build folder or the command line."
      fixIt = nil
    case .unknown(let raw):
      isOn = false
      message = "macOS reported a login item state muxFinder doesn't know (\(raw))."
      fixIt = nil
    }
  } // End of init(status:)
}
