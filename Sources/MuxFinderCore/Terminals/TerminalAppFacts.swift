import AppKit
import CoreServices
import Foundation

/// What muxFinder can tell about a definition's app with no Apple event sent and nothing
/// launched (PLAN.md D38, Phase I-12b1): the app LaunchServices finds by bundle identifier,
/// its version against the definition's minimum, whether it runs, and the Automation
/// permission read without a prompt.
public struct TerminalAppFacts: Sendable, Hashable {
  /// The installed version against the definition's `minimumVersion`.
  public enum VersionCheck: String, Sendable, Hashable {
    /// It reads as a version at least the minimum.
    case meets
    /// It reads as a version below the minimum.
    case tooOld
    /// It is missing or does not read as a dotted decimal version: never a pass.
    case unknown
    /// LaunchServices finds no app with the bundle identifier.
    case notInstalled
  }

  /// The Automation permission's state for the app.
  public enum Automation: Sendable, Hashable {
    /// The definition opens with `exec`, which sends no Apple event.
    case notNeeded
    /// The state `AEDeterminePermissionToAutomateTarget` reported, with its raw status.
    case permission(AutomationPermission, status: Int32)

    /// A stable name: `notNeeded`, or the permission's `kind`.
    public var kind: String {
      switch self {
      case .notNeeded: return "notNeeded"
      case .permission(let permission, _): return permission.kind
      }
    }

    /// The raw status, when one was read.
    public var status: Int32? {
      if case .permission(_, let status) = self { return status }
      return nil
    }
  } // End of enum Automation

  /// Whether LaunchServices knows an app with the bundle identifier.
  public let installed: Bool
  /// The app's path, when installed.
  public let path: String?
  /// Its `CFBundleShortVersionString`, when readable.
  public let version: String?
  /// The version against the minimum.
  public let versionCheck: VersionCheck
  /// Whether an instance runs now.
  public let running: Bool
  /// The Automation permission's state.
  public let automation: Automation

  /// Reads the facts for `definition` through `inspector`. The permission is read only for an
  /// `appleScript` definition; an `exec` one gets `notNeeded`.
  @MainActor
  public static func read(
    for definition: TerminalDefinition,
    inspector: any TerminalAppInspecting = WorkspaceTerminalAppInspector()
  ) -> TerminalAppFacts {
    let snapshot = inspector.snapshot(bundleIdentifier: definition.bundleIdentifier)
    let versionCheck: VersionCheck
    if snapshot.url == nil {
      versionCheck = .notInstalled
    } else {
      switch TerminalVersion.meets(installed: snapshot.version, minimum: definition.minimumVersion)
      {
      case true?: versionCheck = .meets
      case false?: versionCheck = .tooOld
      case nil: versionCheck = .unknown
      }
    }
    let automation: Automation
    if definition.needsAutomationPermission {
      let status = inspector.automationStatus(bundleIdentifier: definition.bundleIdentifier)
      automation = .permission(AutomationPermission(status: status), status: status)
    } else {
      automation = .notNeeded
    }
    return TerminalAppFacts(
      installed: snapshot.url != nil,
      path: snapshot.url.map(WorkspaceTerminalAppInspector.displayPath),
      version: snapshot.version,
      versionCheck: versionCheck,
      running: snapshot.running,
      automation: automation
    )
  } // End of static func read(for:inspector:)
} // End of struct TerminalAppFacts

/// What LaunchServices and the running applications say about one bundle identifier.
public struct TerminalAppSnapshot: Sendable, Hashable {
  /// The app's location, when installed.
  public let url: URL?
  /// Its `CFBundleShortVersionString`, when readable.
  public let version: String?
  /// Whether an instance runs now.
  public let running: Bool

  /// A snapshot of these values.
  public init(url: URL?, version: String?, running: Bool) {
    self.url = url
    self.version = version
    self.running = running
  }
} // End of struct TerminalAppSnapshot

/// Reads an app's facts without launching it or sending it an Apple event. A seam: the app
/// and the probe use `WorkspaceTerminalAppInspector`, tests a fake.
public protocol TerminalAppInspecting: Sendable {
  /// Where LaunchServices finds the app, its version, and whether it runs.
  @MainActor func snapshot(bundleIdentifier: String) -> TerminalAppSnapshot
  /// The raw status of the Automation permission for the app, read without a prompt.
  func automationStatus(bundleIdentifier: String) -> Int32
}

/// The real inspector: `NSWorkspace` (LaunchServices) for the app's location, its bundle's
/// `CFBundleShortVersionString`, `NSRunningApplication` for whether it runs, and
/// `AutomationPermission.status(forBundleIdentifier:)`. It launches nothing and sends no
/// Apple event.
public struct WorkspaceTerminalAppInspector: TerminalAppInspecting {
  /// An inspector.
  public init() {}

  /// Asks LaunchServices and the running applications.
  @MainActor
  public func snapshot(bundleIdentifier: String) -> TerminalAppSnapshot {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier)
    let version = url.flatMap {
      Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }
    let running = !NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier
    ).isEmpty
    return TerminalAppSnapshot(url: url, version: version, running: running)
  }

  /// `AutomationPermission.status(forBundleIdentifier:)`.
  public func automationStatus(bundleIdentifier: String) -> Int32 {
    AutomationPermission.status(forBundleIdentifier: bundleIdentifier)
  }

  /// `url`'s path without a trailing slash.
  public static func displayPath(_ url: URL) -> String {
    let text = url.path(percentEncoded: false)
    return text.count > 1 && text.hasSuffix("/") ? String(text.dropLast()) : text
  }
} // End of struct WorkspaceTerminalAppInspector

extension AutomationPermission {
  /// The status of `AEDeterminePermissionToAutomateTarget` for the app `bundleIdentifier`, any
  /// event class and id, `askUserIfNeeded` false: it sends no event, never prompts and never
  /// launches the app (-600 when it is not running). -1 when the address cannot be made.
  public static func status(forBundleIdentifier bundleIdentifier: String) -> Int32 {
    var address = AEAddressDesc()
    let bytes = Array(bundleIdentifier.utf8)
    let created = bytes.withUnsafeBytes { buffer in
      AECreateDesc(
        DescType(typeApplicationBundleID), buffer.baseAddress, buffer.count, &address)
    }
    guard created == noErr else { return -1 }
    defer { AEDisposeDesc(&address) }
    return AEDeterminePermissionToAutomateTarget(
      &address, AEEventClass(typeWildCard), AEEventID(typeWildCard), false)
  } // End of static func status(forBundleIdentifier:)
} // End of extension AutomationPermission
