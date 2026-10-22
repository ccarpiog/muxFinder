import AppKit
import Foundation
import MuxFinderCore

/// What `AppModel` runs on (PLAN.md D22): the host list, the refresh engine, the system events
/// adapter, the clock and quitting. `production()` wires the real core; tests pass fakes, so
/// `swift test` never reads `hosts.json`, runs a probe or contacts iTerm2.
///
/// Building an environment does no work: nothing is read, started or contacted until
/// `AppModel.start()` calls `loadHosts` and `makeEngine`.
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

  /// Creates an environment from its parts.
  public init(
    loadHosts: @escaping @Sendable () async throws -> HostStoreLoadResult,
    makeEngine: @escaping @Sendable (HostList) -> RefreshCoordinator,
    makeSystemEvents: @escaping @MainActor @Sendable (RefreshCoordinator) -> RefreshSystemEvents?,
    now: @escaping @Sendable () -> Date = { Date() },
    terminate: @escaping @MainActor @Sendable () -> Void
  ) {
    self.loadHosts = loadHosts
    self.makeEngine = makeEngine
    self.makeSystemEvents = makeSystemEvents
    self.now = now
    self.terminate = terminate
  } // End of init(loadHosts:makeEngine:makeSystemEvents:now:terminate:)

  /// The real app: `hosts.json` through `HostStore` (read-only), an engine over
  /// `DiscoveryProbe` whose attachment checks use `AttachmentIndex` over one shared
  /// `ITerm2APIClient`, and `NSWorkspace`'s sleep and wake notifications plus the network path.
  ///
  /// The client connects on its first request only, and the engine sends requests only for an
  /// attachment check, which runs only while the popover is visible and is cancelled when it
  /// closes (PLAN.md D20). Connecting checks that iTerm2 runs before asking for its cookie
  /// (D13), and an attempt whose callers were cancelled stops before the cookie or the
  /// connection, so the cookie is never requested at launch, nor once the popover has closed,
  /// nor while iTerm2 is not running.
  public static func production() -> AppEnvironment {
    let iTerm2 = ITerm2APIClient()
    let index = AttachmentIndex(iTerm2: iTerm2)
    let store = HostStore()
    return AppEnvironment(
      loadHosts: { try await store.load() },
      makeEngine: { hosts in
        RefreshCoordinator(hosts: hosts, discovery: DiscoveryProbe(), attachmentIndex: index)
      },
      makeSystemEvents: { engine in
        RefreshSystemEvents(
          coordinator: engine, notificationCenter: NSWorkspace.shared.notificationCenter)
      },
      terminate: { AppTermination.request() })
  } // End of static func production()
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
