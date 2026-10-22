import Foundation
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// Fakes and helpers for the app model's tests. Nothing here runs a process, reads
/// `hosts.json`, opens a socket or contacts iTerm2.
enum UITestSupport {
  /// The fixed wall clock of the model tests.
  static let now = Date(timeIntervalSince1970: 1_800_000_000)

  /// An enabled SSH host.
  static func sshHost(_ name: String) -> HostConfig {
    HostConfig(displayName: name, mode: .ssh, sshDestination: "\(name.lowercased()).example")
  }

  /// This Mac.
  static func localHost(_ name: String = "Neptuno") -> HostConfig {
    HostConfig(displayName: name, mode: .local)
  }

  /// A host list result as `HostStore.load()` returns it.
  static func loaded(_ hosts: [HostConfig], state: HostStoreLoadResult.State = .saved)
    -> HostStoreLoadResult
  {
    HostStoreLoadResult(hosts: try! HostList(hosts), state: state)
  }

  /// An engine configuration whose schedules never fire during a test (only explicit requests
  /// and the wake refresh, after 10 ms, run).
  static let quietConfiguration = RefreshCoordinator.Configuration(
    visibleInterval: .seconds(3_600), backgroundInterval: .seconds(3_600),
    backoffSteps: [.seconds(3_600)], wakeDelay: .milliseconds(10))

  /// An environment over fakes: `load` gives the host list, the engine uses `discovery` and
  /// `index` (none when `nil`), and `events` builds the system events adapter (none when
  /// `nil`). `terminations` counts quits.
  @MainActor
  static func environment(
    load: @escaping @Sendable () async throws -> HostStoreLoadResult,
    discovery: FakeDiscovery = FakeDiscovery(),
    index: (any AttachmentIndexing)? = nil,
    events: (@MainActor @Sendable (RefreshCoordinator) -> RefreshSystemEvents?)? = nil,
    terminations: Counter = Counter()
  ) -> AppEnvironment {
    AppEnvironment(
      loadHosts: load,
      makeEngine: { hosts in
        RefreshCoordinator(
          hosts: hosts, discovery: discovery, attachmentIndex: index,
          configuration: quietConfiguration)
      },
      makeSystemEvents: { engine in events?(engine) },
      now: { now },
      terminate: { terminations.increment() })
  } // End of static func environment(load:discovery:index:events:terminations:)

  /// Polls `condition` on the main actor every 10 ms until it holds or `timeout` passes;
  /// returns whether it held.
  @MainActor
  static func waitUntil(
    timeout: Duration = .seconds(10),
    _ condition: @MainActor () async -> Bool
  ) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
      if await condition() { return true }
      try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
  } // End of static func waitUntil(timeout:_:)

  /// Whether `engine` has no probe running and no host queued: every requested attempt has
  /// ended, and whatever its end decided (an attachment check or none) is decided.
  static func isSettled(_ engine: RefreshCoordinator) async -> Bool {
    let running = await engine.runningAttemptCount
    let queued = await engine.queuedHostCount
    return running == 0 && queued == 0
  }

  /// A private directory holding a regular file named `socket`, which the iTerm2 client's
  /// socket check counts as present (nothing ever listens on it).
  static func fakeSocketPath() throws -> (directory: URL, socket: String) {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "mfx-ui-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let socket = directory.appending(path: "socket").path(percentEncoded: false)
    try Data().write(to: URL(fileURLWithPath: socket))
    return (directory, socket)
  }
}

/// A thread-safe counter.
final class Counter: Sendable {
  /// The count.
  private let state = OSAllocatedUnfairLock(initialState: 0)

  /// Creates a counter at zero.
  init() {}

  /// Adds one.
  func increment() {
    state.withLock { $0 += 1 }
  }

  /// The count.
  var value: Int { state.withLock { $0 } }
}

/// A discovery that answers at once: by default every host has one session named after it
/// (`ok`, node name `<name>.node`); `setStatus(_:for:)` changes a host's answer. Counts calls
/// per host.
final class FakeDiscovery: HostDiscovering {
  /// Mutable state.
  private struct State {
    /// Calls per host.
    var calls: [UUID: Int] = [:]
    /// Scripted statuses per host.
    var statuses: [UUID: HostStatus] = [:]
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates the fake.
  init() {}

  /// Makes `host` answer `status` from now on.
  func setStatus(_ status: HostStatus, for host: UUID) {
    state.withLock { $0.statuses[host] = status }
  }

  /// How many times `host` was discovered.
  func calls(of host: UUID) -> Int {
    state.withLock { $0.calls[host, default: 0] }
  }

  /// Every discovery so far.
  var totalCalls: Int { state.withLock { $0.calls.values.reduce(0, +) } }

  /// The session this fake reports for `host`.
  static func session(on host: HostConfig) -> DiscoveredSession {
    PreviewFixtures.session(
      "work-\(host.displayName.lowercased())", id: 1, on: host, windows: 2, clients: 1
    ).discovered
  }

  /// Answers with the scripted status, or one session named after the host.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    let scripted = state.withLock { state -> HostStatus? in
      state.calls[host.id, default: 0] += 1
      return state.statuses[host.id]
    }
    let status = scripted ?? .ok([Self.session(on: host)])
    return DiscoveryResult(
      hostID: host.id, status: status,
      report: ProbeReport(nodeName: "\(host.displayName.lowercased()).node"), duration: .zero)
  } // End of func discover(_:)
}

/// An attachment index that reports `attached` as open in iTerm2 and counts its calls.
final class FakeIndex: AttachmentIndexing {
  /// The keys reported as attached.
  private let attached: [SessionKey]
  /// Calls so far.
  let calls = Counter()

  /// An index reporting `attached`.
  init(attached: [SessionKey]) {
    self.attached = attached
  }

  /// Reports every key in `attached` with one connection.
  func snapshot(of hosts: [AttachmentIndex.Host]) async throws -> AttachmentSnapshot {
    calls.increment()
    return AttachmentSnapshot(
      attachments: attached.map {
        AttachmentSnapshot.Attachment(key: $0, connectionID: "tmux", owningSessionID: "owner")
      })
  }
}

/// iTerm2's running state for the real API client, without `NSWorkspace`: `isRunning` is
/// scripted and counted; `launch()` must never be called (it fails the call).
final class FakeAppControl: ITerm2AppControl {
  /// Whether iTerm2 "runs".
  let running: Bool
  /// `isRunning()` calls.
  let runningChecks = Counter()
  /// `launch()` calls.
  let launches = Counter()

  /// A control reporting `running`.
  init(running: Bool) {
    self.running = running
  }

  /// Counts the call and returns `running`.
  func isRunning() async -> Bool {
    runningChecks.increment()
    return running
  }

  /// Counts the call and refuses: nothing in these tests may launch iTerm2.
  func launch() async throws {
    launches.increment()
    throw ITerm2Error.launchFailed("launching is not allowed in tests")
  }
}

/// A cookie provider whose requests wait until `release()` and then hand out credentials
/// (`cookie-n`/`key-n` for request n); counts requests. As a safety net against a test that
/// fails before releasing, waiting requests also resume on their own after 10 s.
final class GatedCookieProvider: ITerm2CookieProvider {
  /// Lock-protected state.
  private struct State {
    /// Requests so far.
    var requests = 0
    /// Whether `release()` ran.
    var released = false
    /// The requests waiting for `release()`.
    var waiters: [CheckedContinuation<Void, Never>] = []
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates the provider.
  init() {}

  /// Requests so far.
  var requests: Int { state.withLock { $0.requests } }

  /// Lets every waiting and later request answer.
  func release() {
    let waiters = state.withLock { state in
      state.released = true
      defer { state.waiters = [] }
      return state.waiters
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Waits until released, then hands out numbered credentials.
  func requestCredentials() async throws -> ITerm2Credentials {
    let number = state.withLock { state in
      state.requests += 1
      return state.requests
    }
    let safetyNet = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      self?.release()
    }
    defer { safetyNet.cancel() }
    await withCheckedContinuation { continuation in
      let resumeNow = state.withLock { state in
        if state.released { return true }
        state.waiters.append(continuation)
        return false
      }
      if resumeNow { continuation.resume() }
    }
    return try ITerm2Credentials(cookie: "cookie-\(number)", key: "key-\(number)")
  } // End of func requestCredentials()
}

/// A socket connector for the real API client: the socket "exists", and every connection is
/// counted and refused (`apiDisabled`). Nothing is opened.
final class CountingConnector: ITerm2SocketConnector {
  /// Connections tried.
  let connects = Counter()

  /// Creates the connector.
  init() {}

  /// The socket "exists".
  func endpointExists() -> Bool { true }

  /// Counts the connection and refuses it.
  func connect(deadline: ContinuousClock.Instant) throws -> any ByteStream {
    connects.increment()
    throw ITerm2Error.apiDisabled
  }
}

/// A cookie provider that counts requests and refuses them (`automationDenied`), so the real
/// client never goes on to connect.
final class CountingCookieProvider: ITerm2CookieProvider {
  /// Requests so far.
  let requests = Counter()

  /// Creates the provider.
  init() {}

  /// Counts the request and refuses it.
  func requestCredentials() async throws -> ITerm2Credentials {
    requests.increment()
    throw ITerm2Error.automationDenied
  }
}
