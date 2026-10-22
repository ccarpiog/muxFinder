import Foundation
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// A fake iTerm2 for the session-action tests: it never touches iTerm2, a socket or a process.
/// It keeps launch tabs and tmux connections as state, so the real `AttachCoordinator` runs
/// its whole path against it: `CreateTab` opens a launch tab `gateway-<n>` whose connection
/// `conn-<n>` (when `attaches`) shows the session of the launch request just written; the
/// identity question answers that session's server and session with its host's node name;
/// `detach-client` closes the connection and its tab (when `closesOnDetach`); `close(_:)` is
/// counted (nothing in the app may call it). Every command, activation and tab is recorded.
/// `createTab` and identity questions can be held, and activations can fail or find no tab.
actor SimulatedITerm2: ITerm2Integration {
  /// One tmux connection.
  struct Connection: Sendable {
    /// Its id.
    var id: String
    /// The iTerm2 session that owns it.
    var owner: String
    /// The session it shows.
    var key: SessionKey
    /// The node name its identity answer reports.
    var nodeName: String
  }

  /// A command sent to a connection.
  struct Sent: Sendable, Hashable {
    /// The command.
    var command: String
    /// The connection.
    var connectionID: String
  }

  /// The launch requests' store, read when a tab opens.
  let store: MemoryLaunchStore
  /// The socket path of every server (the requests do not carry it).
  let socketPath: String
  /// Node names by host id.
  let nodeNames: [UUID: String]
  /// The node name of a host `nodeNames` does not list.
  let defaultNodeName: String
  /// Whether a launch tab's connection appears.
  var attaches: Bool
  /// Whether `detach-client` closes the connection.
  var closesOnDetach = true
  /// The error `createTab` throws, if any.
  var createTabError: ITerm2Error?
  /// When set, the identity answer of a launch tab's connection names this session instead.
  var reportsKey: SessionKey?
  /// Whether identity questions to launch tabs' connections wait for `releaseIdentity()`.
  var holdsIdentity = false
  /// The held identity questions.
  private var heldIdentity: [CheckedContinuation<Void, Never>] = []
  /// Whether `createTab` waits for `releaseCreateTab()` before iTerm2 "answers" (cancelling
  /// the caller does not end the wait, as with a request already sent).
  var holdsCreateTab = false
  /// The held `createTab` calls.
  private var heldCreateTabs: [CheckedContinuation<Void, Never>] = []
  /// The error `activateFirstTab` throws for a connection it would activate, if any.
  var activationError: ITerm2Error?
  /// Whether `activateFirstTab` finds no tab of the connection (it answers `nil`).
  var showsNoTabs = false

  /// The connections.
  private(set) var connections: [Connection] = []
  /// The open launch tabs (their session ids).
  private(set) var launchTabs: [String] = []
  /// `createTab` calls.
  private(set) var createTabCount = 0
  /// Commands sent (whose ownership check passed).
  private(set) var sent: [Sent] = []
  /// `activate(_:)` requests and the activations of `activateFirstTab`.
  private(set) var activations: [ITerm2API.ActivateRequest] = []
  /// `activateFirstTab` targets (connection ids).
  private(set) var focusedConnections: [String] = []
  /// `close(_:)` calls.
  private(set) var closeCount = 0
  /// Numbers the tabs.
  private var nextNumber = 0

  /// A fake over `store` whose launch tabs attach (`attaches`) the requested session.
  init(
    store: MemoryLaunchStore,
    socketPath: String = "/tmp/tmux-fixture/default",
    nodeNames: [UUID: String] = [:],
    defaultNodeName: String = "?",
    attaches: Bool = true
  ) {
    self.store = store
    self.socketPath = socketPath
    self.nodeNames = nodeNames
    self.defaultNodeName = defaultNodeName
    self.attaches = attaches
  } // End of init(store:socketPath:nodeNames:defaultNodeName:attaches:)

  /// The node name of the host `hostID`.
  private func nodeName(of hostID: UUID) -> String {
    nodeNames[hostID] ?? defaultNodeName
  }

  /// Adds a connection the user opened (owned by a tab muxFinder did not open).
  func addUserConnection(_ id: String, owner: String, key: SessionKey) {
    connections.append(
      Connection(id: id, owner: owner, key: key, nodeName: nodeName(of: key.hostID)))
  }

  /// Changes the behavior.
  func configure(_ change: @Sendable (isolated SimulatedITerm2) -> Void) {
    change(self)
  }

  /// Lets every held identity question answer.
  func releaseIdentity() {
    holdsIdentity = false
    let held = heldIdentity
    heldIdentity = []
    for continuation in held { continuation.resume() }
  }

  /// How many identity questions wait.
  var heldIdentityCount: Int { heldIdentity.count }

  /// Lets every held `createTab` call answer.
  func releaseCreateTab() {
    holdsCreateTab = false
    let held = heldCreateTabs
    heldCreateTabs = []
    for continuation in held { continuation.resume() }
  }

  /// How many `createTab` calls wait.
  var heldCreateTabCount: Int { heldCreateTabs.count }

  /// Always running.
  func isRunning() async -> Bool { true }

  /// Connected.
  func status() async -> ITerm2Status {
    ITerm2Status(isRunning: true, socketPresent: true, isConnected: true, protocolVersion: "fake")
  }

  /// Always succeeds.
  func ensureRunning() async throws {}

  /// One window per launch tab and per connection's tab.
  func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    let launchWindows = launchTabs.map { gateway in
      ITerm2API.Window(
        windowID: "w-\(gateway)",
        tabs: [
          .init(
            tabID: "t-\(gateway)",
            root: .init(links: [.session(.init(uniqueIdentifier: gateway))]))
        ])
    }
    let tmuxWindows = connections.map { connection in
      ITerm2API.Window(
        windowID: "w-\(connection.id)",
        tabs: [
          .init(
            tabID: "tab-\(connection.id)",
            root: .init(links: [.session(.init(uniqueIdentifier: "s-\(connection.id)"))]),
            tmuxWindowID: "0", tmuxConnectionID: connection.id)
        ])
    }
    return ITerm2API.ListSessionsResponse(windows: launchWindows + tmuxWindows)
  } // End of func listSessions()

  /// Opens a launch tab; its connection shows the session of the latest request.
  func createTab(_ request: ITerm2API.CreateTabRequest) async throws
    -> ITerm2API.CreateTabResponse
  {
    createTabCount += 1
    if holdsCreateTab {
      await withCheckedContinuation { heldCreateTabs.append($0) }
    }
    if let createTabError { throw createTabError }
    nextNumber += 1
    let gateway = "gateway-\(nextNumber)"
    launchTabs.append(gateway)
    if attaches, let launch = store.written.last {
      let key = SessionKey(
        hostID: launch.hostID,
        server: ServerIdentity(
          socketPath: socketPath, pid: launch.expectedServerPID,
          startTime: launch.expectedServerStartTime),
        sessionID: launch.sessionID)
      connections.append(
        Connection(
          id: "conn-\(nextNumber)", owner: gateway, key: key,
          nodeName: nodeName(of: key.hostID)))
    }
    return ITerm2API.CreateTabResponse(
      status: .ok, windowID: "w-\(gateway)", tabID: Int32(nextNumber), sessionID: gateway)
  } // End of func createTab(_:)

  /// The connections.
  func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] {
    connections.map { ITerm2API.TmuxConnection(connectionID: $0.id, owningSessionID: $0.owner) }
  }

  /// Unbound commands are not used by the app; answered like bound ones by the connection.
  func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    guard let connection = connections.first(where: { $0.id == connectionID }) else {
      throw ITerm2Error.tmuxRequestFailed(.invalidConnectionID)
    }
    return try await answer(command, on: connection)
  }

  /// Answers a command only while the connection is owned by `owningSessionID`.
  func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String {
    guard
      let connection = connections.first(where: {
        $0.id == connectionID && $0.owner == owningSessionID
      })
    else { throw ITerm2Error.tmuxConnectionNotOwned }
    return try await answer(command, on: connection)
  } // End of func sendTmuxCommand(_:connectionID:ownedBy:)

  /// The identity line, or a detach.
  private func answer(_ command: String, on connection: Connection) async throws -> String {
    sent.append(Sent(command: command, connectionID: connection.id))
    if command == ConnectionIdentity.detachCommand {
      if closesOnDetach {
        connections.removeAll { $0.id == connection.id }
        launchTabs.removeAll { $0 == connection.owner }
      }
      return ""
    }
    guard command == ConnectionIdentity.command else { return "" }
    let isLaunchTab = launchTabs.contains(connection.owner)
    if holdsIdentity, isLaunchTab {
      await withCheckedContinuation { heldIdentity.append($0) }
    }
    let key = isLaunchTab ? reportsKey ?? connection.key : connection.key
    let host = connection.nodeName
    let path = key.server.socketPath
    return "1:\(host.utf8.count):\(host):\(key.server.pid):\(key.server.startTime):"
      + "\(path.utf8.count):\(path):\(key.sessionID.rawValue)\n"
  } // End of func answer(_:on:)

  /// Records the activation.
  func activate(_ request: ITerm2API.ActivateRequest) async throws {
    activations.append(request)
  }

  /// Activates the connection's tab while it is owned by `owningSessionID`.
  func activateFirstTab(
    ofTmuxConnection connectionID: String,
    ownedBy owningSessionID: String,
    options: ITerm2API.ActivateRequest
  ) async throws -> String? {
    guard connections.contains(where: { $0.id == connectionID && $0.owner == owningSessionID })
    else { throw ITerm2Error.tmuxConnectionNotOwned }
    if let activationError { throw activationError }
    if showsNoTabs { return nil }
    var request = options
    request.target = .tab("tab-\(connectionID)")
    activations.append(request)
    focusedConnections.append(connectionID)
    return "tab-\(connectionID)"
  } // End of func activateFirstTab(ofTmuxConnection:ownedBy:options:)

  /// No profiles.
  func listProfiles(properties: [String], guids: [String]) async throws -> [ITerm2API.Profile] {
    []
  }

  /// Counted; the app never closes anything.
  func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse {
    closeCount += 1
    return ITerm2API.CloseResponse()
  }

  /// Nothing to disconnect.
  func disconnect() async {}

  /// The commands sent to `connectionID`.
  func commands(to connectionID: String) -> [String] {
    sent.filter { $0.connectionID == connectionID }.map(\.command)
  }
}

/// An in-memory launch store: records requests and withdrawals; no helper ever reports.
final class MemoryLaunchStore: LaunchRequestStore {
  /// Lock-protected state.
  private struct State {
    /// Written requests, in order.
    var written: [LaunchRequest] = []
    /// Withdrawn ids.
    var discarded: [LaunchToken] = []
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates an empty store.
  init() {}

  /// The written requests.
  var written: [LaunchRequest] { state.withLock { $0.written } }

  /// The withdrawn request ids.
  var discarded: [LaunchToken] { state.withLock { $0.discarded } }

  /// Records the request.
  func writeRequest(_ request: LaunchRequest) throws(LaunchStoreError) {
    state.withLock { $0.written.append(request) }
  }

  /// Records the withdrawal; the file "was" there.
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    state.withLock { $0.discarded.append(id) }
    return true
  }

  /// No helper result ever.
  func takeResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult? { nil }

  /// Nothing to sweep.
  func sweep() throws(LaunchStoreError) -> Int { 0 }
}

/// A virtual clock: `sleep(for:)` advances virtual time at once, except that a sleep that would
/// pass `holdAfter` waits until its task is cancelled (so a test can stop time at a state).
final class VirtualClock: AttachClock {
  /// Lock-protected state.
  private struct State {
    /// Virtual time.
    var offset: Duration = .zero
  }

  /// The real instant virtual time starts from.
  private let base = ContinuousClock.now
  /// When sleeps start to hold, if ever.
  private let holdAfter: Duration?
  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// A clock whose sleeps hold once virtual time would pass `holdAfter`.
  init(holdAfter: Duration? = nil) {
    self.holdAfter = holdAfter
  }

  /// `base` plus virtual time.
  func now() -> ContinuousClock.Instant { base + state.withLock { $0.offset } }

  /// A fixed date plus virtual time.
  func date() -> Date {
    let offset = state.withLock { $0.offset }
    return UITestSupport.now.addingTimeInterval(Double(offset / .milliseconds(1)) / 1000)
  }

  /// Advances virtual time, or holds until cancelled.
  func sleep(for duration: Duration) async throws {
    try Task.checkCancellation()
    let holds = state.withLock { state -> Bool in
      if let holdAfter, state.offset + duration > holdAfter { return true }
      state.offset += duration
      return false
    }
    if holds {
      try await Task.sleep(for: .seconds(3600))
    } else {
      await Task.yield()
    }
  } // End of func sleep(for:)

  /// Virtual time elapsed.
  var elapsed: Duration { state.withLock { $0.offset } }
}

/// A clock whose sleeps last until cancelled: the attachment index's question timeout never
/// fires, so answers decide.
struct PatientClock: AttachClock {
  /// The real instant.
  func now() -> ContinuousClock.Instant { .now }

  /// Waits until cancelled.
  func sleep(for duration: Duration) async throws {
    try await Task.sleep(for: .seconds(3600))
  }

  /// The real date.
  func date() -> Date { Date() }
}

/// A scripted session creator: answers each request with the next scripted result (the last
/// repeats) and records the requests.
final class FakeSessionCreator: SessionCreating {
  /// Lock-protected state.
  private struct State {
    /// Results still to give.
    var results: [Result<CreatedSession, SessionCreationError>] = []
    /// Requests so far.
    var requests: [NewSessionRequest] = []
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a creator without results (every call then fails `cancelled`).
  init() {}

  /// Scripts the results.
  func script(_ results: [Result<CreatedSession, SessionCreationError>]) {
    state.withLock { $0.results = results }
  }

  /// The requests so far.
  var requests: [NewSessionRequest] { state.withLock { $0.requests } }

  /// Records `request` and gives the next result.
  func createSession(
    _ request: NewSessionRequest
  ) async throws(SessionCreationError) -> CreatedSession {
    let result = state.withLock { state -> Result<CreatedSession, SessionCreationError> in
      state.requests.append(request)
      guard let first = state.results.first else { return .failure(.cancelled) }
      if state.results.count > 1 { state.results.removeFirst() }
      return first
    }
    return try result.get()
  } // End of func createSession(_:)
}

/// A model over a real engine and a real attach coordinator, both over fakes: `FakeDiscovery`,
/// `SimulatedITerm2`, `MemoryLaunchStore`, a `VirtualClock` and a `FakeSessionCreator`.
@MainActor
struct AttachHarness {
  /// The helper path the coordinator puts in launch requests (never run).
  nonisolated static let helper = try! LaunchHelperPath(
    validating: "/Applications/muxFinder.app/Contents/MacOS/muxfinder-launch")

  /// The model.
  let model: AppModel
  /// The fake iTerm2.
  let iTerm2: SimulatedITerm2
  /// The launch store.
  let store: MemoryLaunchStore
  /// Discovery, for the engine (and the coordinator, unless the harness got another).
  let discovery: FakeDiscovery
  /// The coordinator's discovery (revalidation, "Open existing"): `discovery` by default.
  let attachDiscovery: FakeDiscovery
  /// New session's creator.
  let creator: FakeSessionCreator
  /// The coordinator's clock.
  let clock: VirtualClock
  /// The hosts, in list order.
  let hosts: [HostConfig]
  /// How many times the coordinator was built.
  let builds: Counter

  /// The session `FakeDiscovery` lists on `host`.
  func key(on host: HostConfig) -> SessionKey { FakeDiscovery.session(on: host).key }

  /// A started model over `hosts` (This Mac by default), waiting until every host is live.
  /// `attaches` decides whether launch tabs attach; `holdAfter` stops the coordinator's clock;
  /// `index` gives the engine attachment checks; `failsToBuild` makes the coordinator's
  /// factory throw; `attachDiscovery` gives the coordinator a discovery of its own (the engine
  /// keeps `discovery`'s answers, like a list not refreshed yet); `settings` gives the model
  /// Settings seams; `shutdownBudget` is how long `shutdown()` waits for session actions.
  static func make(
    hosts: [HostConfig] = [UITestSupport.localHost()],
    attaches: Bool = true,
    holdAfter: Duration? = nil,
    index: (any AttachmentIndexing)? = nil,
    failsToBuild: LaunchHelperPathError? = nil,
    attachDiscovery: FakeDiscovery? = nil,
    settings: SettingsEnvironment? = nil,
    shutdownBudget: Duration = AppModel.sessionActionShutdownBudget
  ) async -> AttachHarness {
    let store = MemoryLaunchStore()
    let discovery = FakeDiscovery()
    let coordinatorDiscovery = attachDiscovery ?? discovery
    let nodeNames = Dictionary(
      uniqueKeysWithValues: hosts.map { ($0.id, "\($0.displayName.lowercased()).node") })
    let iTerm2 = SimulatedITerm2(store: store, nodeNames: nodeNames, attaches: attaches)
    let creator = FakeSessionCreator()
    let clock = VirtualClock(holdAfter: holdAfter)
    let builds = Counter()
    let environment = AppEnvironment(
      loadHosts: { UITestSupport.loaded(hosts) },
      makeEngine: { list in
        RefreshCoordinator(
          hosts: list, discovery: discovery, attachmentIndex: index,
          configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      settings: settings,
      makeAttachCoordinator: { onUpdate in
        builds.increment()
        if let failsToBuild { throw failsToBuild }
        return AttachCoordinator(
          iTerm2: iTerm2, discovery: coordinatorDiscovery, store: store, helperPath: helper,
          clock: clock,
          existingAttachments: .index(AttachmentIndex(iTerm2: iTerm2, clock: PatientClock())),
          sessionCreator: creator, onUpdate: onUpdate)
      },
      sessionActionShutdownBudget: shutdownBudget)
    let model = AppModel(environment: environment)
    await model.start()
    _ = await UITestSupport.waitUntil {
      model.refreshState?.hosts.count == hosts.count
        && model.refreshState?.hosts.allSatisfy(\.isLive) == true
    }
    return AttachHarness(
      model: model, iTerm2: iTerm2, store: store, discovery: discovery,
      attachDiscovery: coordinatorDiscovery, creator: creator, clock: clock, hosts: hosts,
      builds: builds)
  } // End of static func make(hosts:attaches:holdAfter:index:failsToBuild:attachDiscovery:…)

  /// Waits until `count` actions ended; returns whether they did.
  func waitForActions(_ count: Int) async -> Bool {
    await UITestSupport.waitUntil { model.finishedActions.count >= count }
  }
}
