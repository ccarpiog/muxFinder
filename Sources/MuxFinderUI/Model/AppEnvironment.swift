import AppKit
import Foundation
import MuxFinderCore

/// What `AppModel` runs on (PLAN.md D22, D23, D24, D25, D38): the host list, the refresh engine,
/// the system events adapter, the terminal backends and the terminal setting, the clock,
/// quitting, opening URLs, the Settings and onboarding windows and their seams. `production()`
/// wires the real core; tests pass fakes (iTerm2's backend over an attach coordinator over a
/// fake iTerm2 integration, directories in memory), so `swift test` never reads or saves
/// `hosts.json`, `directories.json` or `preferences.json`, runs a probe, contacts iTerm2, sends
/// an Apple event, opens a window, a tab or System Settings, changes a login item, or writes in
/// iTerm2's `DynamicProfiles`.
///
/// Building an environment does no work: nothing is read, started or contacted until
/// `AppModel.start()` resolves the terminal setting and calls `loadHosts` and `makeEngine`, a
/// window opens, or the first action on a session builds the chosen terminal's backend.
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
  /// Builds the terminal backend the session actions run on (Open, Move here, Detach, New
  /// session, Detach other clients, Show tab or window; PLAN.md D25, D38) for a chosen
  /// terminal, handing every state update to the given handler: for `iterm2`,
  /// `ITerm2TerminalBackend` over the attach coordinator; for a plain definition,
  /// `PlainTerminalBackend`. Called once per terminal id, at the first action that needs it,
  /// and kept for the model's life (`AppModel` caches it, so switching back reuses it and
  /// there is never a second coordinator on one iTerm2); it throws when the backend cannot be
  /// built (the launch helper is missing), which the row then explains. `nil` leaves sessions
  /// unopenable (tests of other parts).
  public var makeTerminalBackend:
    (
      @MainActor @Sendable (ChosenTerminal, @escaping AttachCoordinator.UpdateHandler) throws
        -> any TerminalBackend
    )?
  /// How the terminal setting is resolved (PLAN.md D38, Phase I-12c3a): the preferences file,
  /// the terminal definitions and LaunchServices' answers. `nil` (the self-tests, the
  /// placement diagnostic, the tests of other parts) forces iTerm2 with nothing read.
  public var terminal: TerminalEnvironment?
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
  /// This Mac's home folder, which New session's directory list matches a leading `~` against
  /// when it filters This Mac's directories (PLAN.md D31, Phase I-7): `NSHomeDirectory()` in
  /// the app; `nil` (entries matched only as stored, as for an SSH host) everywhere else, so no
  /// test depends on the real home folder.
  public var homeDirectory: String?
  /// Speaks a VoiceOver announcement: New session's directory list says how many directories
  /// match when the Directory field's filter changes (PLAN.md D31, Phase I-7).
  /// `postAccessibilityAnnouncement(_:)` in the app; `nil` (nothing said) in the self-tests,
  /// the placement diagnostic and the tests, which record through `AppModel.announce`.
  public var announce: (@MainActor @Sendable (String) -> Void)?
  /// New session's folder search (PLAN.md D36, Phase I-10b): the transport, clock and timings
  /// of its channel and the preferences file its scope is read from for each query. Only the
  /// menu bar app in normal mode has it (`ProcessFolderSearchTransport` and
  /// `preferences.json`); `nil` everywhere else (the self-tests, the preview modes, every
  /// `--report-*` flag, the tests of other parts), so those never run Spotlight or read
  /// `preferences.json` for it, and the directory list shows no folders section.
  public var folderSearch: FolderSearchEnvironment?
  /// The update check (PLAN.md D39 *The notice (I-13c1)*): the scheduler over the real
  /// transport and state store, the toggle's preferences file and "What's new"'s opener. Only
  /// the menu bar app in normal mode has it (`AppLaunchOptions.createsUpdateMachinery`); `nil`
  /// everywhere else (the self-tests, the preview modes, every `--report-*` flag, the tests of
  /// other parts), so those create no transport, scheduler or state store and show no notice,
  /// dot or Settings section.
  public var update: UpdateEnvironment?

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
    makeTerminalBackend: (
      @MainActor @Sendable (ChosenTerminal, @escaping AttachCoordinator.UpdateHandler) throws
        -> any TerminalBackend
    )? = nil,
    terminal: TerminalEnvironment? = nil,
    newSessionCommand: [String] = [],
    directories: (any DirectoryStoring)? = nil,
    sessionActionShutdownBudget: Duration = AppModel.sessionActionShutdownBudget,
    rewritesProfilesAtLaunch: Bool = false,
    globalShortcut: GlobalShortcutEnvironment? = nil,
    homeDirectory: String? = nil,
    announce: (@MainActor @Sendable (String) -> Void)? = nil,
    folderSearch: FolderSearchEnvironment? = nil,
    update: UpdateEnvironment? = nil
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
    self.makeTerminalBackend = makeTerminalBackend
    self.terminal = terminal
    self.newSessionCommand = newSessionCommand
    self.directories = directories
    self.sessionActionShutdownBudget = sessionActionShutdownBudget
    self.rewritesProfilesAtLaunch = rewritesProfilesAtLaunch
    self.globalShortcut = globalShortcut
    self.homeDirectory = homeDirectory
    self.announce = announce
    self.folderSearch = folderSearch
    self.update = update
  } // End of init(loadHosts:makeEngine:makeSystemEvents:now:terminate:openURL:…)

  /// The real app: `hosts.json` through one `HostStore` (loading never writes; Settings saves
  /// through it), an engine over `DiscoveryProbe` whose attachment checks use
  /// `AttachmentIndex` over one shared `ITerm2APIClient`, `NSWorkspace`'s sleep and wake
  /// notifications plus the network path, one `DiagnosticsLog`, and the Settings window's real
  /// seams: the same probe for Detect and Test connection, the same client for the profile
  /// list, `~/.ssh/config` suggestions (read-only), `SMAppService.mainApp`, the general
  /// pasteboard, `NSWorkspace` for URLs, "Set up SSH in iTerm2…" (`SSHSetupLauncher` over
  /// the same client, the launch store and the bundled helper; with a plain terminal chosen,
  /// `PlainSSHSetupLauncher` over the plain window layer below, PLAN.md D38), the bundled
  /// helper's path for the plain persistent work commands, and the persistent profile
  /// file (`PersistentProfileFiles` over iTerm2's `DynamicProfiles` folder, PLAN.md D26). The
  /// session actions run on the chosen terminal's backend (PLAN.md D38, Phase I-12c3a), built
  /// at the first action and kept per terminal id: iTerm2's is `ITerm2TerminalBackend` over one
  /// `AttachCoordinator` over the same client, `DiscoveryProbe`, the launch store and the
  /// bundled `muxfinder-launch` (`LaunchHelperPath.locate()`), with the standard
  /// existing-attachment check (PLAN.md D16, D25); a plain definition's is
  /// `PlainTerminalBackend` over one `PlainTerminalWindows` (`NSAppleScriptRunner`,
  /// LaunchServices, the detached spawner, `NSRunningApplication`), the same helper, launch
  /// store and discovery, and This Mac's `LocalClientAttributor`; both bring an `.app` handle
  /// forward through `RunningApplicationActivator`. The terminal definitions load once (the
  /// bundle's `Resources/Terminals/` and the user's
  /// `~/Library/Application Support/muxFinder/terminals/`, read only, never created) and serve
  /// the terminal setting and the engine's attributor of This Mac's clients
  /// (`RefreshCoordinator(localClients:)`). The setting itself is read from and written to
  /// `preferences.json` only with `usesGlobalShortcut` (normal mode); otherwise it is absent,
  /// so the default (iTerm2 when installed) applies. New session's directory list and
  /// Settings' Directories tab share one `DirectoryStore` on `directories.json` (PLAN.md D31;
  /// it is read when New session or the Settings window opens, and written only when a session
  /// is created in a directory or the user saves or clears directories); its filter matches
  /// `~` against `NSHomeDirectory()` and says the match count through VoiceOver
  /// (`postAccessibilityAnnouncement(_:)`). `rewritesProfilesAtLaunch` is the caller's: only the menu bar app in normal mode passes
  /// `true`. So is `usesGlobalShortcut` (PLAN.md D32): only normal mode passes `true`, which
  /// adds the session switcher shortcut over `preferences.json` (`PreferencesStore`, read at
  /// launch, written only when the user records or clears a shortcut), Carbon's hotkeys
  /// (`CarbonHotkeyRegistrar`) and the current keyboard layout, and, over the same store, New
  /// session's folder search (PLAN.md D36: `ProcessFolderSearchTransport`, its scope read for
  /// each query) and Settings › Directories' scope setting (written only when the user picks a
  /// scope); otherwise nothing reads that file, registers a hotkey or runs Spotlight.
  /// `checksForUpdates` (PLAN.md D39 *The notice (I-13c1)*) is the caller's as well: only
  /// normal mode passes `true` (`AppLaunchOptions.createsUpdateMachinery`), which adds the
  /// update check (`UpdateEnvironment.production(preferences:)` over the same store); otherwise
  /// no transport, scheduler or state store is created.
  ///
  /// The client connects on its first request only. The engine sends requests only for an
  /// attachment check, which runs only while the popover is visible and is cancelled when it
  /// closes (PLAN.md D20); Settings asks for the profile list only when its window opens while
  /// iTerm2 runs; "Set up SSH in iTerm2…" contacts iTerm2 (and may launch it) only when the
  /// user clicks it; a session action contacts iTerm2 (and an attach may launch it) only when
  /// the user asks for it. Connecting checks that iTerm2 runs before asking for its cookie (D13), and
  /// an attempt whose callers were cancelled stops before the cookie or the connection, so the
  /// cookie is never requested at launch, nor once the popover has closed, nor while iTerm2 is
  /// not running. The onboarding window contacts nothing by itself. While iTerm2 is not the
  /// chosen terminal, nothing contacts it at all (PLAN.md D38): `AppModel` turns the engine's
  /// attachment checks off and gates the profile list, "Set up SSH in iTerm2…" and D26's
  /// rewrite, and only the chosen terminal's backend is built.
  @MainActor
  public static func production(
    rewritesProfilesAtLaunch: Bool, usesGlobalShortcut: Bool = false,
    checksForUpdates: Bool = false
  ) -> AppEnvironment {
    let diagnostics = DiagnosticsLog()
    let iTerm2 = ITerm2APIClient(diagnostics: diagnostics)
    let index = AttachmentIndex(iTerm2: iTerm2)
    let catalog = TerminalCatalogCache {
      TerminalDefinitionLoader(
        builtInDirectory: TerminalDefinitionLoader.bundledDirectory(),
        userDirectory: AppPaths.standard.terminalDefinitionsDirectory
      ).load()
    }
    let plainWindows = PlainTerminalWindowsHolder()
    let activator = RunningApplicationActivator()
    let store = HostStore()
    let directories = DirectoryStore()
    let preferences = PreferencesStore()
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
      directories: directories,
      preferences: usesGlobalShortcut ? preferences : nil,
      plainSSHSetup: { loaded in
        PlainSSHSetupLauncher(
          loaded: loaded, windows: plainWindows.windows, store: LaunchStore(),
          diagnostics: diagnostics)
      },
      helperPath: { SSHSetupLauncher.locateStandardHelper() })
    return AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: { hosts in
        RefreshCoordinator(
          hosts: hosts, discovery: DiscoveryProbe(), attachmentIndex: index,
          localClients: LocalClientAttributor(definitions: catalog.catalog().definitions))
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
      makeTerminalBackend: { chosen, onUpdate in
        switch chosen {
        case .iTerm2:
          return ITerm2TerminalBackend(
            coordinator: AttachCoordinator(
              iTerm2: iTerm2, discovery: DiscoveryProbe(), store: LaunchStore(),
              helperPath: try LaunchHelperPath.locate(), diagnostics: diagnostics,
              onUpdate: onUpdate),
            appActivator: activator)
        case .plain(let loaded):
          return PlainTerminalBackend(
            loaded: loaded, windows: plainWindows.windows,
            helperPath: try LaunchHelperPath.locate(),
            store: LaunchStore(), discovery: DiscoveryProbe(), diagnostics: diagnostics,
            localClients: LocalClientAttributor(definitions: catalog.catalog().definitions),
            appActivator: activator, onUpdate: onUpdate)
        }
      },
      terminal: TerminalEnvironment(
        preferences: usesGlobalShortcut ? preferences : nil,
        loadDefinitions: { catalog.catalog() },
        inspector: WorkspaceTerminalAppInspector()),
      directories: directories,
      rewritesProfilesAtLaunch: rewritesProfilesAtLaunch,
      globalShortcut: usesGlobalShortcut
        ? GlobalShortcutEnvironment(
          store: preferences, registrar: CarbonHotkeyRegistrar(),
          layout: SystemKeyboardLayout())
        : nil,
      homeDirectory: NSHomeDirectory(),
      announce: { postAccessibilityAnnouncement($0) },
      folderSearch: usesGlobalShortcut
        ? FolderSearchEnvironment(
          transport: ProcessFolderSearchTransport(), preferences: preferences)
        : nil,
      update: checksForUpdates ? .production(preferences: preferences) : nil)
  } // End of static func production(rewritesProfilesAtLaunch:usesGlobalShortcut:…)

  /// Asks VoiceOver to say `text` (`NSAccessibility` `announcementRequested`, medium priority,
  /// so it follows the echo of the key just typed), from the key window (the popover's or the
  /// switcher's panel, which take the key focus without activating the app) or the app.
  /// Nothing is said while VoiceOver is off.
  @MainActor
  public static func postAccessibilityAnnouncement(_ text: String) {
    let application = NSApplication.shared
    let element: Any = application.keyWindow ?? application
    NSAccessibility.post(
      element: element, notification: .announcementRequested,
      userInfo: [
        .announcement: text, .priority: NSAccessibilityPriorityLevel.medium.rawValue,
      ])
  } // End of static func postAccessibilityAnnouncement(_:)

  /// The popover placement diagnostic's (`--report-popover-placement`, PLAN.md Phase I-1): an
  /// inert environment for a model the app never starts. Its host list is an empty in-memory
  /// one, as the self-tests' (`HostStoreLoadResult.inMemory(_:)`: no `hosts.json` read or
  /// written, no onboarding); an engine built for it would have no host to discover and no
  /// attachment index, so it could not run a probe or contact iTerm2; no system events, no
  /// Settings seams (inert Settings and onboarding models), no terminal backend or terminal
  /// setting (iTerm2 forced, nothing read), no directory
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
