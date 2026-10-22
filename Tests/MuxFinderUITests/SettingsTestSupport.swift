import Foundation
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// Fakes for the Settings model's tests. Nothing here saves the real `hosts.json`, runs a
/// process, contacts iTerm2, changes a login item, opens System Settings or touches the
/// pasteboard.
enum SettingsTestSupport {
  /// An enabled SSH host with a `.example` destination.
  static func sshHost(_ name: String, enabled: Bool = true) -> HostConfig {
    HostConfig(
      displayName: name, mode: .ssh, sshDestination: "\(name.lowercased()).example",
      isEnabled: enabled)
  }

  /// A host list result as `HostStore.load()` returns it.
  static func loaded(_ hosts: [HostConfig], state: HostStoreLoadResult.State = .saved)
    -> HostStoreLoadResult
  {
    HostStoreLoadResult(hosts: try! HostList(hosts), state: state)
  }

  /// An environment over fakes.
  @MainActor
  static func environment(
    store: any HostListPersisting,
    discovery: ScriptedDiscovery = ScriptedDiscovery(),
    profiles: FakeProfiles = FakeProfiles(.available(["Default", "Work"])),
    loginItem: FakeLoginItem = FakeLoginItem(.notRegistered),
    seams: SeamRecorder = SeamRecorder(),
    diagnostics: DiagnosticsLog = DiagnosticsLog(
      writesToSystemLog: false, now: { UITestSupport.now }),
    suggestions: [String] = ["build-box.example"]
  ) -> SettingsEnvironment {
    SettingsEnvironment(
      store: store,
      discovery: discovery,
      profiles: profiles,
      sshSuggestions: { suggestions },
      loginItem: loginItem,
      diagnostics: diagnostics,
      copyText: { seams.copied.append($0) },
      openURL: { seams.openedURLs.append($0) },
      appVersion: "1.2.3 (45)",
      systemVersion: "Version 27.2 (Build 27C00)",
      now: { UITestSupport.now })
  } // End of static func environment(store:discovery:profiles:loginItem:seams:diagnostics:…)

  /// A model over fakes whose store loads `hosts`, opened (list, login item, profiles,
  /// suggestions and log loaded).
  @MainActor
  static func openModel(
    _ hosts: [HostConfig],
    state: HostStoreLoadResult.State = .saved,
    discovery: ScriptedDiscovery = ScriptedDiscovery(),
    profiles: FakeProfiles = FakeProfiles(.available(["Default", "Work"])),
    loginItem: FakeLoginItem = FakeLoginItem(.notRegistered),
    seams: SeamRecorder = SeamRecorder()
  ) async -> (SettingsModel, FakeHostListStore) {
    let store = FakeHostListStore(loaded(hosts, state: state))
    let model = SettingsModel(
      environment: environment(
        store: store, discovery: discovery, profiles: profiles, loginItem: loginItem,
        seams: seams))
    await model.windowDidOpen()
    return (model, store)
  } // End of static func openModel(_:state:discovery:profiles:loginItem:seams:)

  /// A private folder for a real `HostStore` (removed by the caller): the store's file is
  /// `<folder>/muxFinder/hosts.json`, whose folder does not exist yet.
  static func privateStoreFolder() throws -> (base: URL, file: URL) {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "mfx-settings-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = base.appending(path: "muxFinder", directoryHint: .isDirectory)
      .appending(path: HostStore.fileName)
    return (base, file)
  }
}

/// Records what the URL and pasteboard seams were given.
@MainActor
final class SeamRecorder {
  /// URLs opened.
  var openedURLs: [URL] = []
  /// Texts copied.
  var copied: [String] = []
  /// Settings models presented.
  var presented: [ObjectIdentifier] = []

  /// Creates an empty recorder.
  init() {}
}

/// A gate that fakes wait at while it is closed, so a test can hold a call at a known point
/// without any timing: close it, wait until calls have arrived (`waitForArrivals(_:)`), act,
/// then open it. A call that waits with `cancellable` stops waiting as soon as its task is
/// cancelled, the way the real process runner kills its process group and returns.
final class TestGate: Sendable {
  /// Lock-protected state.
  private struct State {
    /// Whether calls pass at once.
    var isOpen = true
    /// The last call number handed out.
    var lastCall = 0
    /// Calls that reached the gate so far.
    var arrivals = 0
    /// Calls whose task was cancelled while they were at the gate (cancellable calls only).
    var cancellations = 0
    /// The calls waiting, by call number.
    var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    /// The calls whose task was cancelled.
    var cancelled: Set<Int> = []
    /// Tests waiting until a number of calls has arrived.
    var arrivalWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// An open gate.
  init() {}

  /// Calls that reached the gate so far.
  var arrivals: Int { state.withLock { $0.arrivals } }
  /// Cancellable calls whose task was cancelled while at the gate.
  var cancellations: Int { state.withLock { $0.cancellations } }

  /// Makes later calls wait until `open()`.
  func close() {
    state.withLock { $0.isOpen = false }
  }

  /// Lets every waiting and later call pass.
  func open() {
    let waiters = state.withLock { state in
      state.isOpen = true
      defer { state.waiting = [:] }
      return Array(state.waiting.values)
    }
    for waiter in waiters { waiter.resume() }
  }

  /// Arrives at the gate and waits while it is closed. With `cancellable`, a cancelled task
  /// stops waiting and the result is `false`; otherwise the result is `true`. The arrival is
  /// counted only once the cancellation handler is in place, so a test that cancels after
  /// `waitForArrivals(_:)` returned always reaches a waiting call.
  func pass(cancellable: Bool = false) async -> Bool {
    let call = state.withLock { state in
      state.lastCall += 1
      return state.lastCall
    }
    await withTaskCancellationHandler {
      await withCheckedContinuation { continuation in
        let (resumeNow, arrived) = state.withLock { state in
          state.arrivals += 1
          let count = state.arrivals
          let arrived = state.arrivalWaiters.filter { $0.count <= count }.map(\.continuation)
          state.arrivalWaiters.removeAll { $0.count <= count }
          if state.isOpen || state.cancelled.contains(call) { return (true, arrived) }
          state.waiting[call] = continuation
          return (false, arrived)
        }
        if resumeNow { continuation.resume() }
        for waiter in arrived { waiter.resume() }
      }
    } onCancel: {
      guard cancellable else { return }
      let waiter = state.withLock { state in
        state.cancelled.insert(call)
        state.cancellations += 1
        return state.waiting.removeValue(forKey: call)
      }
      waiter?.resume()
    }
    return !state.withLock { $0.cancelled.contains(call) }
  } // End of func pass(cancellable:)

  /// Returns once `count` calls have reached the gate. As a safety net against a test that
  /// fails before they do, it also returns after 10 s (the test's next checks then fail).
  func waitForArrivals(_ count: Int) async {
    let safetyNet = Task { [weak self] in
      try? await Task.sleep(for: .seconds(10))
      self?.releaseArrivalWaiters()
    }
    defer { safetyNet.cancel() }
    await withCheckedContinuation { continuation in
      let ready = state.withLock { state in
        if state.arrivals >= count { return true }
        state.arrivalWaiters.append((count, continuation))
        return false
      }
      if ready { continuation.resume() }
    }
  } // End of func waitForArrivals(_:)

  /// Lets every test waiting for arrivals go on.
  private func releaseArrivalWaiters() {
    let waiters = state.withLock { state in
      defer { state.arrivalWaiters = [] }
      return state.arrivalWaiters.map(\.continuation)
    }
    for waiter in waiters { waiter.resume() }
  }
}

extension HostStoreLoadResult {
  /// A result for fakes. Its revision is a placeholder: `FakeHostListStore` answers its own.
  init(hosts: HostList, state: State) {
    self.init(hosts: hosts, state: state, revision: HostFileRevision(entry: .missing))
  }
}

/// An in-memory host list store: `load()` answers the scripted result (or error), `save(_:)`
/// records the list (or throws the scripted error). Counts both. The "file" has a revision
/// number: a save expecting another one is refused (`fileChanged`), as `HostStore` refuses a
/// changed file; `changeFile(to:)` plays another program. `holdLoads()` and `holdSaves()` make
/// calls wait until released.
final class FakeHostListStore: HostListPersisting {
  /// Lock-protected state.
  private struct State {
    /// What `load()` answers.
    var loadResult: HostStoreLoadResult
    /// What `load()` throws, if anything.
    var loadError: HostStoreError?
    /// What `save(_:)` throws, if anything.
    var saveError: HostStoreError?
    /// Every list saved.
    var saves: [HostList] = []
    /// `load()` calls.
    var loads = 0
    /// The file's revision number.
    var revision = 0
  }

  /// The revision the fake reports for revision number `number`.
  static func revision(_ number: Int) -> HostFileRevision {
    HostFileRevision(entry: .contents(Data("fake revision \(number)".utf8), nil))
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>
  /// Where `load()` waits while loads are held.
  private let loadGate = TestGate()
  /// Where `save(_:)` waits while saves are held.
  private let saveGate = TestGate()

  /// A store that loads `result`.
  init(_ result: HostStoreLoadResult) {
    state = OSAllocatedUnfairLock(initialState: State(loadResult: result))
  }

  /// Every list saved, oldest first.
  var saves: [HostList] { state.withLock { $0.saves } }
  /// `load()` calls so far.
  var loads: Int { state.withLock { $0.loads } }

  /// Makes `load()` throw `error`.
  func failLoads(with error: HostStoreError?) {
    state.withLock { $0.loadError = error }
  }

  /// Makes `save(_:)` throw `error`.
  func failSaves(with error: HostStoreError?) {
    state.withLock { $0.saveError = error }
  }

  /// Another program changes the file: later loads answer `result`, and a save expecting an
  /// earlier revision is refused.
  func changeFile(to result: HostStoreLoadResult) {
    state.withLock { state in
      state.loadResult = result
      state.revision += 1
    }
  }

  /// Makes later loads wait for `releaseLoads()`.
  func holdLoads() { loadGate.close() }
  /// Lets every waiting and later load answer.
  func releaseLoads() { loadGate.open() }
  /// Returns once `count` loads have started.
  func waitForLoadCalls(_ count: Int) async { await loadGate.waitForArrivals(count) }

  /// Makes later saves wait for `releaseSaves()`.
  func holdSaves() { saveGate.close() }
  /// Lets every waiting and later save go on.
  func releaseSaves() { saveGate.open() }
  /// Returns once `count` saves have started.
  func waitForSaveCalls(_ count: Int) async { await saveGate.waitForArrivals(count) }

  /// Waits while loads are held, then answers the scripted result with the current revision; a
  /// saved list is loaded back as `saved`.
  func load() async throws(HostStoreError) -> HostStoreLoadResult {
    _ = await loadGate.pass()
    let (result, error) = state.withLock { state in
      state.loads += 1
      var result = state.loadResult
      result.revision = Self.revision(state.revision)
      return (result, state.loadError)
    }
    if let error { throw error }
    return result
  } // End of func load()

  /// Waits while saves are held, then refuses a stale `revision` (`fileChanged`) or throws the
  /// scripted error, or records `list` as the next revision.
  func save(
    _ list: HostList, expecting revision: HostFileRevision
  ) async throws(HostStoreError) -> HostStoreSaveResult {
    _ = await saveGate.pass()
    let outcome = state.withLock { state -> Result<HostStoreSaveResult, HostStoreError> in
      let current = Self.revision(state.revision)
      guard revision == current else { return .failure(.fileChanged(current: current)) }
      if let error = state.saveError { return .failure(error) }
      state.saves.append(list)
      state.revision += 1
      state.loadResult = HostStoreLoadResult(hosts: list, state: .saved)
      return .success(HostStoreSaveResult(revision: Self.revision(state.revision)))
    }
    return try outcome.get()
  } // End of func save(_:expecting:)
}

/// A discovery that answers a scripted status (one session on success by default) and records
/// the configurations it was asked about. `hold()` makes calls wait until `release()`.
final class ScriptedDiscovery: HostDiscovering {
  /// Lock-protected state.
  private struct State {
    /// What every call answers.
    var status: HostStatus = .noServer
    /// The report every call carries.
    var report: ProbeReport? = ProbeReport(
      nodeName: "fixture.node", tmuxPath: "/opt/homebrew/bin/tmux", tmuxVersion: "tmux 3.8")
    /// The configurations asked about.
    var calls: [HostConfig] = []
    /// Whether a held call stops waiting when its task is cancelled.
    var cancellableHolds = false
    /// Calls that ended, answered or stopped by cancellation.
    var finishedCalls = 0
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())
  /// Where calls wait while held.
  private let gate = TestGate()

  /// Creates a discovery answering "no server" with a report naming tmux.
  init() {}

  /// Makes every call answer `status` with `report`.
  func answer(_ status: HostStatus, report: ProbeReport?) {
    state.withLock {
      $0.status = status
      $0.report = report
    }
  }

  /// The configurations asked about, oldest first.
  var calls: [HostConfig] { state.withLock { $0.calls } }
  /// Calls that ended (answered, or stopped by cancellation), like a probe whose process
  /// group was killed and reaped.
  var finishedCalls: Int { state.withLock { $0.finishedCalls } }
  /// Held calls whose task was cancelled while they waited.
  var cancellations: Int { gate.cancellations }

  /// Makes later calls wait for `release()`. With `cancellable`, a call whose task is
  /// cancelled stops waiting and throws `CancellationError`, as `DiscoveryProbe` does once its
  /// process group is gone; otherwise it waits for `release()` whatever happens.
  func hold(cancellable: Bool = false) {
    state.withLock { $0.cancellableHolds = cancellable }
    gate.close()
  }

  /// Lets every waiting and later call answer.
  func release() {
    gate.open()
  }

  /// Returns once `count` calls have been made.
  func waitForCalls(_ count: Int) async {
    await gate.waitForArrivals(count)
  }

  /// Records `host`, waits while held, then answers (or throws `CancellationError`, see
  /// `hold(cancellable:)`).
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    let cancellable = state.withLock { state in
      state.calls.append(host)
      return state.cancellableHolds
    }
    let passed = await gate.pass(cancellable: cancellable)
    defer { state.withLock { $0.finishedCalls += 1 } }
    guard passed else { throw CancellationError() }
    let (status, report) = state.withLock { ($0.status, $0.report) }
    return DiscoveryResult(
      hostID: host.id, status: status, report: report, duration: .milliseconds(1_250))
  } // End of func discover(_:)
}

/// A profile list answering a scripted result; counts calls. With a closed `gate`, calls wait
/// there, and a call whose task is cancelled stops waiting, as the real iTerm2 client stops
/// before contacting iTerm2 once its caller is cancelled.
final class FakeProfiles: ITerm2ProfileListing {
  /// The answer.
  private let result: ProfileListResult
  /// Where calls wait, if anywhere.
  private let gate: TestGate?
  /// Calls so far.
  let calls = Counter()

  /// A list answering `result`, waiting at `gate` first if there is one.
  init(_ result: ProfileListResult, gate: TestGate? = nil) {
    self.result = result
    self.gate = gate
  }

  /// Counts the call, waits at the gate, and answers (`cancelled` once cancelled there).
  func profileNames() async -> ProfileListResult {
    calls.increment()
    if let gate, await !gate.pass(cancellable: true) { return .cancelled }
    return result
  }
}

/// A login item in memory: register and unregister change the status (or throw the scripted
/// error); every call is counted. Never touches `SMAppService`.
@MainActor
final class FakeLoginItem: LoginItemControlling {
  /// The current status.
  var currentStatus: LoginItemStatus
  /// The status after a successful `register()`.
  var statusAfterRegister = LoginItemStatus.enabled
  /// What `register()` and `unregister()` throw, if anything.
  var error: (any Error)?
  /// `status` reads.
  var statusReads = 0
  /// `register()` calls.
  var registerCalls = 0
  /// `unregister()` calls.
  var unregisterCalls = 0
  /// `openSystemSettingsLoginItems()` calls.
  var openSettingsCalls = 0

  /// A login item at `status`.
  init(_ status: LoginItemStatus) {
    currentStatus = status
  }

  /// Counts the read and answers.
  var status: LoginItemStatus {
    statusReads += 1
    return currentStatus
  }

  /// Counts the call; throws the scripted error or changes the status.
  func register() throws {
    registerCalls += 1
    if let error { throw error }
    currentStatus = statusAfterRegister
  }

  /// Counts the call; throws the scripted error or changes the status.
  func unregister() throws {
    unregisterCalls += 1
    if let error { throw error }
    currentStatus = .notRegistered
  }

  /// Counts the call.
  func openSystemSettingsLoginItems() {
    openSettingsCalls += 1
  }
}

/// An error with a fixed description, standing in for `SMAppService`'s.
struct FakeLoginItemError: LocalizedError {
  /// The description.
  var errorDescription: String? { "Operation not permitted." }
}
