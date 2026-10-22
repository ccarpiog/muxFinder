import AppKit
import Foundation
import MuxFinderCore

/// Loads and saves the host list (PLAN.md D19, D23). `HostStore` is the only production
/// implementation, so every save goes through its rules (the revision check, atomic
/// publication, the backup of the file it displaces); tests use a `HostStore` on a private
/// folder, or a fake that counts calls.
public protocol HostListPersisting: Sendable {
  /// Loads the list and the file's revision; never writes anything (`HostStore.load()`).
  func load() async throws(HostStoreError) -> HostStoreLoadResult
  /// Saves the list only while the file is still `revision`; a file changed since is left as
  /// it is and the save throws `fileChanged` (`HostStore.save(_:expecting:)`).
  func save(
    _ list: HostList, expecting revision: HostFileRevision
  ) async throws(HostStoreError) -> HostStoreSaveResult
}

extension HostStore: HostListPersisting {}

/// The answer to "which iTerm2 profiles are there?".
public enum ProfileListResult: Sendable, Hashable {
  /// The profile names, sorted, without duplicates.
  case available([String])
  /// iTerm2 is not running; it was not launched to find out.
  case iTermNotRunning
  /// Listing failed (`nil`: an error that is not an iTerm2 one).
  case failed(ITerm2Error?)
  /// The caller was cancelled (the Settings window closed) before iTerm2 was asked.
  case cancelled
}

/// Lists iTerm2's profiles for the host editor's picker (PLAN.md D23).
public protocol ITerm2ProfileListing: Sendable {
  /// The profile names, or why there are none. Never launches iTerm2.
  func profileNames() async -> ProfileListResult
}

/// The real profile list: `ListProfiles` through an `ITerm2Integration`, asked only while
/// iTerm2 runs. `ensureRunning()` is never called, so iTerm2 is never launched to fill the
/// picker, and nothing is asked at all while it is not running. A cancelled caller asks
/// nothing either; once the request has started, the client stops before its next iTerm2
/// contact (D13, D22).
public struct ITerm2ProfileSource: ITerm2ProfileListing {
  /// The iTerm2 client (the app's shared one).
  public let iTerm2: any ITerm2Integration

  /// A source over `iTerm2`.
  public init(iTerm2: any ITerm2Integration) {
    self.iTerm2 = iTerm2
  }

  /// Checks that iTerm2 runs, then lists the profiles' names; `cancelled` once the calling
  /// task is cancelled before the request.
  public func profileNames() async -> ProfileListResult {
    guard !Task.isCancelled else { return .cancelled }
    guard await iTerm2.isRunning() else { return .iTermNotRunning }
    guard !Task.isCancelled else { return .cancelled }
    do {
      let profiles = try await iTerm2.listProfiles(
        properties: [ITerm2API.ProfileProperty.Key.name], guids: [])
      let names = Set(profiles.compactMap(\.name).filter { !$0.isEmpty })
      return .available(names.sorted { $0.localizedStandardCompare($1) == .orderedAscending })
    } catch let error as ITerm2Error {
      return error == .notRunning ? .iTermNotRunning : .failed(error)
    } catch {
      return .failed(nil)
    }
  } // End of func profileNames()
}

/// What the Settings window runs on (PLAN.md D23), and with it the onboarding window and the
/// popover's "Set up SSH in iTerm2…" (D24). `AppEnvironment.production()` wires the real ones;
/// tests pass fakes, so `swift test` never saves the real `hosts.json`, runs a probe, contacts
/// iTerm2, opens a tab, changes a login item, opens System Settings or touches the pasteboard.
public struct SettingsEnvironment: Sendable {
  /// The host list file (`HostStore`, shared with the app model).
  public var store: any HostListPersisting
  /// Runs the discovery probe for "Detect" and "Test connection" (`DiscoveryProbe`).
  public var discovery: any HostDiscovering
  /// Lists iTerm2's profiles for the picker.
  public var profiles: any ITerm2ProfileListing
  /// Host names from `~/.ssh/config`, offered as destination suggestions only.
  public var sshSuggestions: @Sendable () async -> [String]
  /// muxFinder as a login item (`SMAppService.mainApp`).
  public var loginItem: any LoginItemControlling
  /// The operation log the Diagnostics tab lists.
  public var diagnostics: DiagnosticsLog
  /// Puts text on the pasteboard ("Copy diagnostics").
  public var copyText: @MainActor @Sendable (String) -> Void
  /// Opens a URL (a fix-it's System Settings pane).
  public var openURL: @MainActor @Sendable (URL) -> Void
  /// muxFinder's version, for the diagnostics.
  public var appVersion: String
  /// The macOS version, for the diagnostics.
  public var systemVersion: String
  /// The wall clock (the diagnostics' date).
  public var now: @Sendable () -> Date
  /// Opens "Set up SSH in iTerm2…" tabs (`SSHSetupLauncher`, PLAN.md D24), for the Settings
  /// host editor, the onboarding window and the popover; `nil` offers no action.
  public var sshSetup: (any SSHSetupOpening)?

  /// Creates an environment from its parts.
  public init(
    store: any HostListPersisting,
    discovery: any HostDiscovering,
    profiles: any ITerm2ProfileListing,
    sshSuggestions: @escaping @Sendable () async -> [String],
    loginItem: any LoginItemControlling,
    diagnostics: DiagnosticsLog,
    copyText: @escaping @MainActor @Sendable (String) -> Void,
    openURL: @escaping @MainActor @Sendable (URL) -> Void,
    appVersion: String,
    systemVersion: String,
    now: @escaping @Sendable () -> Date = { Date() },
    sshSetup: (any SSHSetupOpening)? = nil
  ) {
    self.store = store
    self.discovery = discovery
    self.profiles = profiles
    self.sshSuggestions = sshSuggestions
    self.loginItem = loginItem
    self.diagnostics = diagnostics
    self.copyText = copyText
    self.openURL = openURL
    self.appVersion = appVersion
    self.systemVersion = systemVersion
    self.now = now
    self.sshSetup = sshSetup
  } // End of init(store:discovery:profiles:sshSuggestions:loginItem:diagnostics:…)

  /// Puts `text` on the general pasteboard as plain text.
  @MainActor
  public static func copyToGeneralPasteboard(_ text: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
  }

  /// Opens `url` with `NSWorkspace`.
  @MainActor
  public static func openWithWorkspace(_ url: URL) {
    NSWorkspace.shared.open(url)
  }
}

/// muxFinder's version as the bundle states it.
public enum AppVersion {
  /// "0.1.0 (1)" from the main bundle's `CFBundleShortVersionString` and `CFBundleVersion`, or
  /// "development build (not an app bundle)" when they are missing (`swift run`).
  public static var current: String {
    let info = Bundle.main.infoDictionary ?? [:]
    guard let short = info["CFBundleShortVersionString"] as? String else {
      return "development build (not an app bundle)"
    }
    if let build = info["CFBundleVersion"] as? String { return "\(short) (\(build))" }
    return short
  }
}
