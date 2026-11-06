import Foundation
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// A clock for the folder search channel's timers in the UI tests: `sleep(for:)` waits until
/// `advance(by:)` moves virtual time past its deadline (or its task is cancelled), so a test
/// decides exactly when the debounce, a timeout or the quiet minute passes.
final class GatedClock: AttachClock {
  /// One waiting sleep.
  private struct Waiter {
    /// When it ends, in virtual time.
    let deadline: Duration
    /// Resumes the sleep.
    let continuation: CheckedContinuation<Void, any Error>
  }

  /// Mutable state.
  private struct State {
    /// Virtual time since `base`.
    var offset: Duration = .zero
    /// Waiting sleeps, by id.
    var waiters: [Int: Waiter] = [:]
    /// Ids of sleeps cancelled before they registered.
    var cancelledEarly: Set<Int> = []
    /// The next sleep's id.
    var nextID = 0
  }

  /// The real instant virtual time starts from.
  private let base = ContinuousClock.now
  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// A clock at virtual time zero.
  init() {}

  /// `base` plus the virtual time.
  func now() -> ContinuousClock.Instant { base + state.withLock { $0.offset } }

  /// The tests' fixed date plus the virtual time.
  func date() -> Date {
    let offset = state.withLock { $0.offset }
    return UITestSupport.now.addingTimeInterval(Double(offset / .milliseconds(1)) / 1000)
  }

  /// Waits until virtual time reaches now + `duration`, or throws when cancelled.
  func sleep(for duration: Duration) async throws {
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let immediate = state.withLock { state -> Result<Void, any Error>? in
          if state.cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
          guard duration > .zero else { return .success(()) }
          state.waiters[id] = Waiter(deadline: state.offset + duration, continuation: continuation)
          return nil
        }
        if let immediate { continuation.resume(with: immediate) }
      }
    } onCancel: {
      let waiter = state.withLock { state -> Waiter? in
        guard let waiter = state.waiters.removeValue(forKey: id) else {
          state.cancelledEarly.insert(id)
          return nil
        }
        return waiter
      }
      waiter?.continuation.resume(throwing: CancellationError())
    }
  } // End of func sleep(for:)

  /// Moves virtual time forward and ends every sleep whose deadline it reaches.
  func advance(by duration: Duration) {
    let due = state.withLock { state -> [Waiter] in
      state.offset += duration
      let due = state.waiters.filter { $0.value.deadline <= state.offset }
      for id in due.keys { state.waiters[id] = nil }
      return Array(due.values)
    }
    for waiter in due { waiter.continuation.resume() }
  } // End of func advance(by:)

  /// How many sleeps wait now.
  var waiting: Int { state.withLock { $0.waiters.count } }
}

/// A preferences store whose reads fail (an unreadable settings folder), counting them.
actor FailingPreferencesStore: PreferencesStoring {
  /// Reads so far.
  private(set) var loads = 0

  /// Creates the store.
  init() {}

  /// Fails as an unreadable folder does.
  func load() throws(PreferencesStoreError) -> PreferencesLoadResult {
    loads += 1
    throw .directoryIsSymbolicLink
  }

  /// Fails too.
  func setGlobalShortcut(
    _ shortcut: GlobalShortcut?
  ) throws(PreferencesStoreError) -> PreferencesChangeResult {
    throw .directoryIsSymbolicLink
  }

  /// Fails too.
  func setFolderSearchScope(
    _ scope: FolderSearchScope
  ) throws(PreferencesStoreError) -> PreferencesChangeResult {
    throw .directoryIsSymbolicLink
  }
}

/// A preferences store in memory whose scope saves wait until `release()` (a slow disk), so a
/// test sees what happens while one runs; a 10 s safety net releases them should a test not.
actor GatedPreferencesStore: PreferencesStoring {
  /// What it keeps.
  private(set) var preferences = Preferences()
  /// How many scope saves have started.
  private(set) var scopeSavesStarted = 0
  /// Whether `release()` ran: saves no longer wait.
  private var isReleased = false
  /// The saves waiting for `release()`.
  private var waiting: [CheckedContinuation<Void, Never>] = []

  /// An empty store (Home folder) whose saves wait.
  init() {}

  /// The preferences, as a usable file would give them.
  func load() -> PreferencesLoadResult {
    PreferencesLoadResult(preferences: preferences, state: .saved)
  }

  /// Keeps `shortcut` at once (these tests are about the scope).
  func setGlobalShortcut(_ shortcut: GlobalShortcut?) -> PreferencesChangeResult {
    preferences.globalShortcut = shortcut
    return PreferencesChangeResult(preferences: preferences, wrote: true)
  }

  /// Waits until released, then keeps `scope`.
  func setFolderSearchScope(_ scope: FolderSearchScope) async -> PreferencesChangeResult {
    scopeSavesStarted += 1
    if !isReleased {
      let safetyNet = Task { [weak self] in
        try? await Task.sleep(for: .seconds(10))
        await self?.release()
      }
      await withCheckedContinuation { waiting.append($0) }
      safetyNet.cancel()
    }
    preferences.folderSearchScope = scope
    return PreferencesChangeResult(preferences: preferences, wrote: true)
  } // End of func setFolderSearchScope(_:)

  /// Lets every waiting and later save go on.
  func release() {
    isReleased = true
    let released = waiting
    waiting = []
    for save in released { save.resume() }
  }
}

/// A started app model over This Mac and Saturno with New session's folder search on a
/// `FakeFolderSearchTransport` and a `GatedClock` (nothing runs Spotlight, ssh or a process),
/// its scope read from `preferences`, its announcements, URLs and Settings windows recorded.
@MainActor
struct FolderSearchHarness {
  /// The model.
  let model: AppModel
  /// The folder search's transport.
  let transport: FakeFolderSearchTransport
  /// The channel's clock.
  let clock: GatedClock
  /// What VoiceOver was told.
  let said: AnnouncementRecorder
  /// URLs opened and Settings windows presented.
  let seams: SeamRecorder
  /// This Mac.
  let local: HostConfig
  /// Saturno, an SSH host.
  let saturno: HostConfig

  /// The header a Mac with Spotlight on everywhere writes, its home `/Users/me`.
  static let header = FolderSearchHeader(
    homeDirectory: "/Users/me", hasSpotlight: true, homeIndexing: .on, diskIndexing: .on,
    desktop: .notChecked, documents: .notChecked, downloads: .notChecked)

  /// A started model with New session open on This Mac (its list closed, its field empty).
  static func make(
    preferences: any PreferencesStoring = InMemoryPreferencesStore(),
    directories: (any DirectoryStoring)? = nil
  ) async -> FolderSearchHarness {
    let local = UITestSupport.localHost()
    let saturno = UITestSupport.sshHost("Saturno")
    let transport = FakeFolderSearchTransport()
    let clock = GatedClock()
    let said = AnnouncementRecorder()
    let seams = SeamRecorder()
    let discovery = FakeDiscovery()
    let environment = AppEnvironment(
      loadHosts: { UITestSupport.loaded([local, saturno]) },
      makeEngine: { hosts in
        RefreshCoordinator(
          hosts: hosts, discovery: discovery, configuration: UITestSupport.quietConfiguration)
      },
      makeSystemEvents: { _ in nil },
      now: { UITestSupport.now },
      terminate: {},
      openURL: { seams.openedURLs.append($0) },
      presentSettings: { seams.presented.append(ObjectIdentifier($0)) },
      directories: directories,
      folderSearch: FolderSearchEnvironment(
        transport: transport, clock: clock, preferences: preferences))
    let model = AppModel(environment: environment)
    model.announce = { said.said.append($0) }
    await model.start()
    let listed = await UITestSupport.waitUntil { model.refreshState?.hosts.count == 2 }
    precondition(listed, "the engine lists both hosts")
    model.newSession()
    return FolderSearchHarness(
      model: model, transport: transport, clock: clock, said: said, seams: seams, local: local,
      saturno: saturno)
  } // End of static func make(preferences:directories:)

  /// Types `text` into the Directory field (a user edit) and waits until the folder search
  /// queued what it asks.
  func type(_ text: String) async {
    model.newSessionDraft.directory = text
    await model.folderSearchRequestsHandled()
  }

  /// Waits until `count` connections were opened; returns the last one.
  func opened(_ count: Int) async -> FakeFolderSearchConnection? {
    _ = await UITestSupport.waitUntil { transport.connections.count >= count }
    return transport.connections.count == count ? transport.connections.last : nil
  }

  /// Waits until `connection` was sent `count` lines; returns them.
  func lines(_ connection: FakeFolderSearchConnection, _ count: Int) async -> [String] {
    _ = await UITestSupport.waitUntil { connection.sentLines.count >= count }
    return connection.sentLines
  }

  /// Waits until exactly `count` sleeps wait on the clock.
  func sleeps(_ count: Int) async -> Bool {
    await UITestSupport.waitUntil { clock.waiting == count }
  }

  /// Waits until the channel's header is in and only the quiet minute and a debounce wait (no
  /// query in flight): moving the clock then passes that debounce.
  func debounceWaits() async -> Bool {
    await UITestSupport.waitUntil {
      model.folderSearchState?.header != nil && clock.waiting == 2
    }
  }

  /// Passes the debounce of the latest text once it waits (`debounceWaits()`), so its query
  /// goes.
  func passDebounce() async {
    _ = await debounceWaits()
    clock.advance(by: .milliseconds(150))
  }

  /// Opens the channel for the typed `text` (on This Mac unless the host changed), gives it
  /// `header`, passes the debounce and returns the connection with its query line sent.
  func searched(
    _ text: String, header: FolderSearchHeader = header, connections: Int = 1
  ) async -> FakeFolderSearchConnection? {
    await type(text)
    guard let connection = await opened(connections) else { return nil }
    connection.emit(.header(header))
    // Once the header is in, only the quiet minute and the debounce wait (the header's
    // timeout was cancelled); the debounce must wait before the clock moves past it.
    guard await debounceWaits() else { return nil }
    clock.advance(by: .milliseconds(150))
    _ = await lines(connection, connection.sentLines.count + 1)
    return connection
  } // End of func searched(_:header:connections:)

  /// Answers the latest line of `connection` with `paths`, and waits until the model shows an
  /// answer for the field's text.
  func answer(_ connection: FakeFolderSearchConnection, _ paths: [String]) async -> Bool {
    guard let id = connection.sentID(at: connection.sentLines.count - 1) else { return false }
    connection.emit(.reply(FolderSearchReply(id: id, status: .ok, paths: paths)))
    return await UITestSupport.waitUntil {
      model.directoryPickerContent?.folders?.status.isSettled == true
    }
  }

  /// The folders section shown now.
  var folders: FolderSearchSection? { model.directoryPickerContent?.folders }
}
