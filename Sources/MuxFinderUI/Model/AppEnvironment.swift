import AppKit
import Foundation
import MuxFinderCore

/// What `AppModel` runs on (PLAN.md D22, D23, D24, D25): the host list, the refresh engine, the
/// system events adapter, the attach coordinator, the clock, quitting, opening URLs, the
/// Settings and onboarding windows and their seams. `production()` wires the real core; tests
/// pass fakes (the attach coordinator over a fake iTerm2 integration, directories in memory), so
/// `swift test` never reads or saves `hosts.json` or `directories.json`, runs a probe, contacts
/// iTerm2, opens a window, a tab or System
/// Settings, changes a login item, or writes in iTerm2's `DynamicProfiles`.
///
/// Building an environment does no work: nothing is read, started or contacted until
/// `AppModel.start()` calls `loadHosts` and `makeEngine`, a window opens, or the first action
/// on a session builds the attach coordinator.
public struct AppEnvironment: Sendable {
  /// Loads the host list (`HostStore.load()` in production, which never writes).
  public var loadHosts: @Sendable () async throws -> HostStoreLoadResult
  /// Builds the refresh engine for a host list, idle (not started).
  public var makeEngine: @Sendable (HostList) -> RefreshCoordinator
  /// Builds the sleep, wake and network adapter for the engine (not started), or `nil` for
  /// none.
  public var makeSystemEvents: @MainActor @Sendable (RefreshCoordinator) -> RefreshSystemEvents?
  /// The wall clock that relative times ("2 min ago") are measured against.
  public var now: @Sendable () -> Date
  /// Quits the app (`NSApplication.terminate(_:)` in production).
  public var terminate: @MainActor @Sendable () -> Void
  /// Opens a URL (a fix-it's System Settings pane; `NSWorkspace` in production).
  public var openURL: @MainActor @Sendable (URL) -> Void
  /// Shows the Settings window for the model (`SettingsWindowController` in production).
  public var presentSettings: @MainActor @Sendable (SettingsModel) -> Void
  /// Shows the onboarding window for the model (`OnboardingWindowController` in production);
  /// `AppModel.start()` calls it only while the host list loaded as `notSavedYet`.
  public var presentOnboarding: @MainActor @Sendable (OnboardingModel) -> Void
  /// The Settings window's seams (the onboarding window and the popover's "Set up SSH in
  /// iTerm2…" use its store, log and ssh setup too); `nil` gives inert models.
  public var settings: SettingsEnvironment?
  /// The operation log, if any (the app model records how the host list loaded).
  public var diagnostics: DiagnosticsLog?
  /// Builds the attach coordinator the session actions run on (Open, Move here, Detach, New
  /// session, Show tab; PLAN.md D25), handing every state update to the given handler. Called
  /// once, at the first action; it throws when the coordinator cannot be built (the launch
  /// helper is missing), which the row then explains. `nil` leaves sessions unopenable (tests
  /// of other parts).
  public var makeAttachCoordinator:
    (@Sendable (@escaping AttachCoordinator.UpdateHandler) throws -> AttachCoordinator)?
  /// The first pane's command of a session made with New session, as argv; empty (the app's
  /// value) runs the user's shell. The self-tests run `sleep` instead, so no login shell starts.
  public var newSessionCommand: [String]
  /// Where New session reads its directory list, records the directories it created sessions
  /// in and saves or clears directories from the list (PLAN.md D31): `DirectoryStore` on the
  /// real `directories.json` in the app, an `InMemoryDirectoryStore` in the self-tests, `nil`
  /// (nothing read or recorded) in the tests of other parts and the placement diagnostic.
  /// Preview fixtures have no environment, so they never reach a store.
  public var directories: (any DirectoryStoring)?
  /// How long `AppModel.shutdown()` waits for the session actions it cancelled before it
  /// reports the ones still running and returns (`AppModel.sessionActionShutdownBudget` by
  /// default; tests shorten it).
  public var sessionActionShutdownBudget: Duration
  /// Whether `AppModel.start()` brings an installed, out-of-date persistent profile file up to
  /// date once the host list loaded as `saved` (PLAN.md D26), through Settings' seam. Only the
  /// menu bar app in normal mode sets it (`AppLaunchOptions.rewritesProfilesAtLaunch`); every
  /// other mode, the self-tests and the tests leave it off, so they never call the installer.
  public var rewritesProfilesAtLaunch: Bool
  /// The session switcher shortcut's preferences file, hotkey registrar and keyboard layout
  /// (PLAN.md D32). Only the menu bar app in normal mode has them
  /// (`AppLaunchOptions.registersGlobalShortcut`); `nil` everywhere else (the self-tests, the
  /// preview modes, every `--report-*` flag, the tests of other parts), so those never read
  /// `preferences.json` or register a hotkey.
  public var globalShortcut: GlobalShortcutEnvironment?

  /// Creates an environment from its parts.
  public init(
    loadHosts: @escaping @Sendable () async throws -> HostStoreLoadResult,
    makeEngine: @escaping @Sendable (HostList) -> RefreshCoordinator,
    makeSystemEvents: @escaping @MainActor @Sendable (RefreshCoordinator) -> RefreshSystemEvents?,
    now: @escaping @Sendable () -> Date = { Date() },
    terminate: @escaping @MainActor @Sendable () -> Void,
    openURL: @escaping @MainActor @Sendable (URL) -> Void = { _ in },
    presentSettings: @escaping @MainActor @Sendable (SettingsModel) -> Void = { _ in },
    presentOnboarding: @escaping @MainActor @Sendable (OnboardingModel) -> Void = { _ in },
    settings: SettingsEnvironment? = nil,
    diagnostics: DiagnosticsLog? = nil,
    makeAttachCoordinator: (
      @Sendable (@escaping AttachCoordinator.UpdateHandler) throws -> AttachCoordinator
    )? = nil,
    newSessionCommand: [String] = [],
    directories: (any DirectoryStoring)? = nil,
    sessionActionShutdownBudget: Duration = AppModel.sessionActionShutdownBudget,
    rewritesProfilesAtLaunch: Bool = false,
    globalShortcut: GlobalShortcutEnvironment? = nil
  ) {
    self.loadHosts = loadHosts
    self.makeEngine = makeEngine
    self.makeSystemEvents = makeSystemEvents
    self.now = now
    self.terminate = terminate
    self.openURL = openURL
    self.presentSettings = presentSettings
    self.presentOnboarding = presentOnboarding
    self.settings = settings
    self.diagnostics = diagnostics
    self.makeAttachCoordinator = makeAttachCoordinator
    self.newSessionCommand = newSessionCommand
    self.directories = directories
    self.sessionActionShutdownBudget = sessionActionShutdownBudget
    self.rewritesProfilesAtLaunch = rewritesProfilesAtLaunch
    self.globalShortcut = globalShortcut
  } // End of init(loadHosts:makeEngine:makeSystemEvents:now:terminate:openURL:…)

  /// The real app: `hosts.json` through one `HostStore` (loading never writes; Settings saves
  /// through it), an engine over `DiscoveryProbe` whose attachment checks use
  /// `AttachmentIndex` over one shared `ITerm2APIClient`, `NSWorkspace`'s sleep and wake
  /// notifications plus the network path, one `DiagnosticsLog`, and the Settings window's real
  /// seams: the same probe for Detect and Test connection, the same client for the profile
  /// list, `~/.ssh/config` suggestions (read-only), `SMAppService.mainApp`, the general
  /// pasteboard, `NSWorkspace` for URLs, "Set up SSH in iTerm2…" (`SSHSetupLauncher` over
  /// the same client, the launch store and the bundled helper), and the persistent profile
  /// file (`PersistentProfileFiles` over iTerm2's `DynamicProfiles` folder, PLAN.md D26). The
  /// session actions run on one `AttachCoordinator` over the same client, `DiscoveryProbe`, the
  /// launch store and the bundled `muxfinder-launch` (`LaunchHelperPath.locate()`), with the
  /// standard existing-attachment check (PLAN.md D16, D25). New session's directory list and
  /// Settings' Directories tab share one `DirectoryStore` on `directories.json` (PLAN.md D31;
  /// it is read when New session or the Settings window opens, and written only when a session
  /// is created in a directory or the user saves or clears directories).
  /// `rewritesProfilesAtLaunch` is the caller's: only the menu bar app in normal mode passes
  /// `true`. So is `usesGlobalShortcut` (PLAN.md D32): only normal mode passes `true`, which
  /// adds the session switcher shortcut over `preferences.json` (`PreferencesStore`, read at
  /// launch, written only when the user records or clears a shortcut), Carbon's hotkeys
  /// (`CarbonHotkeyRegistrar`) and the current keyboard layout; otherwise nothing reads that
  /// file or registers a hotkey.
  ///
  /// The client connects on its first request only. The engine sends requests only for an
  /// attachment check, which runs only while the popover is visible and is cancelled when it
  /// closes (PLAN.md D20); Settings asks for the profile list only when its window opens while
  /// iTerm2 runs; "Set up SSH in iTerm2…" contacts iTerm2 (and may launch it) only when the
  /// user clicks it; a session action contacts iTerm2 (and an attach may launch it) only when
  /// the user asks for it. Connecting checks that iTerm2 runs before asking for its cookie (D13), and
  /// an attempt whose callers were cancelled stops before the cookie or the connection, so the
  /// cookie is never requested at launch, nor once the popover has closed, nor while iTerm2 is
  /// not running. The onboarding window contacts nothing by itself.
  @MainActor
  public static func production(
    rewritesProfilesAtLaunch: Bool, usesGlobalShortcut: Bool = false
  ) -> AppEnvironment {
    let diagnostics = DiagnosticsLog()
    let iTerm2 = ITerm2APIClient(diagnostics: diagnostics)
    let index = AttachmentIndex(iTerm2: iTerm2)
    let store = HostStore()
    let directories = DirectoryStore()
    let sshSetup = SSHSetupLauncher(
      iTerm2: iTerm2, store: LaunchStore(), diagnostics: diagnostics)
    let settings = SettingsEnvironment(
      store: store,
      discovery: DiscoveryProbe(),
      profiles: ITerm2ProfileSource(iTerm2: iTerm2),
      sshSuggestions: {
        await Task.detached(priority: .utility) { SSHConfigSuggestions().hostNames() }.value
      },
      loginItem: SystemLoginItem(),
      diagnostics: diagnostics,
      copyText: { SettingsEnvironment.copyToGeneralPasteboard($0) },
      openURL: { SettingsEnvironment.openWithWorkspace($0) },
      appVersion: AppVersion.current,
      systemVersion: ProcessInfo.processInfo.operatingSystemVersionString,
      sshSetup: sshSetup,
      persistentProfiles: PersistentProfileFiles(),
      directories: directories)
    return AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: { hosts in
        RefreshCoordinator(hosts: hosts, discovery: DiscoveryProbe(), attachmentIndex: index)
      },
      makeSystemEvents: { engine in
        RefreshSystemEvents(
          coordinator: engine, notificationCenter: NSWorkspace.shared.notificationCenter)
      },
      terminate: { AppTermination.request() },
      openURL: { SettingsEnvironment.openWithWorkspace($0) },
      presentSettings: { SettingsWindowController.shared.show($0) },
      presentOnboarding: { OnboardingWindowController.shared.show($0) },
      settings: settings,
      diagnostics: diagnostics,
      makeAttachCoordinator: { onUpdate in
        AttachCoordinator(
          iTerm2: iTerm2, discovery: DiscoveryProbe(), store: LaunchStore(),
          helperPath: try LaunchHelperPath.locate(), diagnostics: diagnostics, onUpdate: onUpdate)
      },
      directories: directories,
      rewritesProfilesAtLaunch: rewritesProfilesAtLaunch,
      globalShortcut: usesGlobalShortcut
        ? GlobalShortcutEnvironment(
          store: PreferencesStore(), registrar: CarbonHotkeyRegistrar(),
          layout: SystemKeyboardLayout())
        : nil)
  } // End of static func production(rewritesProfilesAtLaunch:usesGlobalShortcut:)

  /// The popover placement diagnostic's (`--report-popover-placement`, PLAN.md Phase I-1): an
  /// inert environment for a model the app never starts. Its host list is an empty in-memory
  /// one, as the self-tests' (`HostStoreLoadResult.inMemory(_:)`: no `hosts.json` read or
  /// written, no onboarding); an engine built for it would have no host to discover and no
  /// attachment index, so it could not run a probe or contact iTerm2; no system events, no
  /// Settings seams (inert Settings and onboarding models), no attach coordinator, no directory
  /// store (no `directories.json` read or written), no persistent profile rewrite, and no
  /// session switcher shortcut (no `preferences.json` read, no hotkey). Quitting goes through
  /// `AppTermination` as usual.
  public static func placementDiagnostic() -> AppEnvironment {
    AppEnvironment(
      loadHosts: { .inMemory(HostList()) },
      makeEngine: { hosts in RefreshCoordinator(hosts: hosts, discovery: DiscoveryProbe()) },
      makeSystemEvents: { _ in nil },
      terminate: { AppTermination.request() },
      rewritesProfilesAtLaunch: false)
  }
}

/// Quitting the app safely from any main-thread context.
public enum AppTermination {
  /// Asks AppKit to quit (`NSApplication.terminate(_:)`), from a run-loop block on the main
  /// thread.
  ///
  /// The app answers `applicationShouldTerminate` with `.terminateLater` and replies once the
  /// model's shutdown, a main-actor task, has run; meanwhile AppKit waits in a nested run
  /// loop. The main actor runs on the main dispatch queue, which is not drained again while
  /// one of its blocks is running, so `terminate(_:)` called from a main-actor task or a
  /// main-queue block would wait for ever. A run-loop block is neither.
  public static func request() {
    RunLoop.main.perform {
      MainActor.assumeIsolated { NSApplication.shared.terminate(nil) }
    }
  }
}
