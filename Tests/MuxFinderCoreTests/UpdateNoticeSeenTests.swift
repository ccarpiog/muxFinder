import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `UpdateScheduler.markNoticeSeen(_:)` (PLAN.md D39 *The notice (I-13c1)*): the seen version
/// is written through the actor, only when greater than the recorded one, through the store
/// (an `UpdateStateStore` on a private folder for the file's rules), published only once saved,
/// kept as it was when the save fails, saved one at a time with a check's saves (neither losing
/// the other's fields), and never after `stop()`. Nothing is sent (fake transports only).
@Suite("Update notice seen")
struct UpdateNoticeSeenTests {
  /// Shorthand.
  typealias Support = UpdateTestSupport

  /// A version from its text.
  static func version(_ text: String) -> UpdateVersion {
    UpdateVersion(text)!
  }

  /// A scheduler over `store` with the 0.3.0 release kept, for an app running 0.2.0.
  static func scheduler(
    _ store: any UpdateStateStoring, transport: FakeUpdateTransport = FakeUpdateTransport()
  ) -> UpdateScheduler {
    UpdateScheduler(
      transport: transport, stateStore: store, runningVersion: "0.2.0",
      clock: ManualUpdateClock())
  }

  /// Greater versions are recorded and published; equal and older ones write nothing; no
  /// request is sent.
  @Test func recordsOnlyGreaterVersions() async throws {
    let store = InMemoryUpdateStateStore(UpdateState(keptRelease: Support.release()))
    let transport = FakeUpdateTransport()
    let scheduler = Self.scheduler(store, transport: transport)
    let updates = await scheduler.updates()
    #expect(await scheduler.status.noticeSeenVersion == nil)
    #expect(await scheduler.markNoticeSeen(Self.version("0.3.0")))
    #expect(await store.state.noticeSeenVersion == Self.version("0.3.0"))
    #expect(await store.saveCount == 1)
    #expect(await scheduler.status.noticeSeenVersion == Self.version("0.3.0"))
    #expect(!(await scheduler.markNoticeSeen(Self.version("0.3.0"))))
    #expect(!(await scheduler.markNoticeSeen(Self.version("0.2.9"))))
    #expect(await store.saveCount == 1)
    #expect(await scheduler.markNoticeSeen(Self.version("0.4.0")))
    #expect(await store.state.noticeSeenVersion == Self.version("0.4.0"))
    #expect(await store.state.keptRelease == Support.release())
    var published: UpdateVersion?
    for await status in updates {
      published = status.noticeSeenVersion
      if published == Self.version("0.4.0") { break }
    }
    #expect(published == Self.version("0.4.0"))
    #expect(transport.calls == 0)
    await scheduler.stop()
  } // End of func recordsOnlyGreaterVersions()

  /// A save that fails keeps the recorded version as it was, so the dot stays; a later save
  /// that works records it.
  @Test func failedSaveKeepsTheRecordedVersion() async throws {
    let store = InMemoryUpdateStateStore(
      UpdateState(keptRelease: Support.release(), noticeSeenVersion: Self.version("0.2.5")))
    await store.setFailure(.encodingFailed)
    let scheduler = Self.scheduler(store)
    #expect(!(await scheduler.markNoticeSeen(Self.version("0.3.0"))))
    #expect(await scheduler.status.noticeSeenVersion == Self.version("0.2.5"))
    #expect(await scheduler.failedSaves == 1)
    await store.setFailure(nil)
    #expect(await scheduler.markNoticeSeen(Self.version("0.3.0")))
    #expect(await scheduler.status.noticeSeenVersion == Self.version("0.3.0"))
  }

  /// Through the real store on a private folder: the file holds the version, a private regular
  /// file, and reads back; after `stop()` nothing is recorded.
  @Test func writesTheStateFile() async throws {
    let folder = try Support.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let file = folder.appendingPathComponent("update-state.json")
    let store = UpdateStateStore(fileURL: file)
    let scheduler = Self.scheduler(store)
    #expect(await scheduler.markNoticeSeen(Self.version("0.3.0")))
    let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
    #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    #expect(attributes[.type] as? FileAttributeType == .typeRegular)
    let reread = await UpdateStateStore(fileURL: file).load()
    #expect(reread.state.noticeSeenVersion == Self.version("0.3.0"))
    await scheduler.stop()
    #expect(!(await scheduler.markNoticeSeen(Self.version("0.5.0"))))
    #expect(
      await UpdateStateStore(fileURL: file).load().state.noticeSeenVersion == Self.version("0.3.0"))
  } // End of func writesTheStateFile()

  /// The transport answering one check with the 0.4.0 release and the `ETag` `"e2"`.
  static func newerTransport() -> FakeUpdateTransport {
    let page = "https://github.com/ccarpiog/muxFinder/releases/tag/v0.4.0"
    return FakeUpdateTransport([.body(Support.body(tag: "v0.4.0", page: page), etag: "\"e2\"")])
  }

  /// Starts a seen mark of 0.3.0 whose save the store holds, then a manual check, and returns
  /// once the check has gone as far as it can while the mark's save is held (its own saves wait
  /// for their turn, or, were they not serialized, it has ended).
  static func markWhileACheckRuns(
    _ scheduler: UpdateScheduler, store: ControlledUpdateStateStore
  ) async -> (mark: Task<Bool, Never>, check: Task<UpdateCheckOutcome, Never>) {
    store.holdNextSave()
    let mark = Task { await scheduler.markNoticeSeen(Self.version("0.3.0")) }
    #expect(await Support.waitUntil { store.isHoldingSave })
    // The mark still being saved is not in the status, so nothing published clears the dot.
    #expect(await scheduler.status.noticeSeenVersion == nil)
    let check = Task { await scheduler.checkNow() }
    let reached = await Support.waitUntil {
      let ended = await scheduler.status.lastCheck != nil
      let waiting = await scheduler.savesWaiting
      return ended || waiting == 1
    }
    #expect(reached)
    #expect(await scheduler.status.noticeSeenVersion == nil)
    return (mark, check)
  } // End of static func markWhileACheckRuns(_:store:)

  /// The last status `updates` held when its scheduler stopped (never read before).
  static func lastStatus(_ updates: AsyncStream<UpdateCheckStatus>) async -> UpdateCheckStatus? {
    var last: UpdateCheckStatus?
    for await status in updates { last = status }
    return last
  }

  /// A seen mark whose save fails while a check runs and saves its own result: nothing it
  /// tried is published or saved (the dot stays), and the check's fields are saved.
  @Test func failedSaveDuringACheckPublishesNothing() async throws {
    let store = ControlledUpdateStateStore(UpdateState(keptRelease: Support.release()))
    let scheduler = Self.scheduler(store, transport: Self.newerTransport())
    let updates = await scheduler.updates()
    let (mark, check) = await Self.markWhileACheckRuns(scheduler, store: store)
    store.releaseHeldSave(failing: true)
    #expect(!(await mark.value))
    guard case .checked(.newer(let release)) = await check.value else {
      Issue.record("the check did not offer the newer release")
      return
    }
    #expect(release.version == Self.version("0.4.0"))
    #expect(await scheduler.failedSaves == 1)
    #expect(await scheduler.status.noticeSeenVersion == nil)
    let saved = store.state
    #expect(saved.noticeSeenVersion == nil)
    #expect(saved.etag == "\"e2\"")
    #expect(saved.keptRelease?.version == Self.version("0.4.0"))
    await scheduler.stop()
    let last = await Self.lastStatus(updates)
    #expect(last?.lastCheck != nil)
    #expect(last?.noticeSeenVersion == nil)
    #expect(last?.offer == .newer(release))
  } // End of func failedSaveDuringACheckPublishesNothing()

  /// A check that ends while a seen mark's save is held: once that save succeeds, the file holds
  /// both the seen version and the check's fields (`etag`, `keptRelease`, the dates), and every
  /// save after the mark's keeps the mark.
  @Test func checkDuringAHeldSeenSaveKeepsBothWrites() async throws {
    let store = ControlledUpdateStateStore(UpdateState(keptRelease: Support.release()))
    let scheduler = Self.scheduler(store, transport: Self.newerTransport())
    let (mark, check) = await Self.markWhileACheckRuns(scheduler, store: store)
    store.releaseHeldSave(failing: false)
    #expect(await mark.value)
    guard case .checked(.newer(let release)) = await check.value else {
      Issue.record("the check did not offer the newer release")
      return
    }
    let saved = store.state
    #expect(saved.noticeSeenVersion == Self.version("0.3.0"))
    #expect(saved.etag == "\"e2\"")
    #expect(saved.keptRelease?.version == Self.version("0.4.0"))
    #expect(saved.lastAttempt != nil)
    #expect(saved.lastSuccessfulCheck != nil)
    let saves = store.saves
    #expect(saves.count == 3)
    #expect(saves.first?.noticeSeenVersion == Self.version("0.3.0"))
    #expect(saves.allSatisfy { $0.noticeSeenVersion == Self.version("0.3.0") })
    #expect(saves.last == saved)
    let status = await scheduler.status
    #expect(status.noticeSeenVersion == Self.version("0.3.0"))
    #expect(status.offer == .newer(release))
    #expect(await scheduler.failedSaves == 0)
    await scheduler.stop()
  } // End of func checkDuringAHeldSeenSaveKeepsBothWrites()
}

/// A state store whose saves the test controls: `holdNextSave()` makes the next save wait until
/// `releaseHeldSave(failing:)`, which keeps it or fails it with `encodingFailed`; every other
/// save is kept at once, and loads return at once.
final class ControlledUpdateStateStore: UpdateStateStoring, Sendable {
  /// Mutable state.
  private struct State {
    /// The state a load gives and kept saves replace.
    var state: UpdateState
    /// Every kept save, in order.
    var saves: [UpdateState] = []
    /// Whether the next save waits.
    var holdNext = false
    /// The held save, waiting for whether it fails.
    var held: CheckedContinuation<Bool, Never>?
    /// A release that came before the held save waited: whether it fails.
    var earlyRelease: Bool?
  }

  /// The state.
  private let lock: OSAllocatedUnfairLock<State>

  /// A store holding `state`.
  init(_ state: UpdateState) {
    lock = OSAllocatedUnfairLock(initialState: State(state: state))
  }

  /// The state, as a usable file would give it.
  func load() async -> UpdateStateLoadResult {
    let state = lock.withLock { $0.state }
    return UpdateStateLoadResult(state: state, found: state == UpdateState() ? .missing : .saved)
  }

  /// Keeps `state`, unless it is the held save and its release fails it.
  func save(_ state: UpdateState) async throws(UpdateStateStoreError) {
    let hold = lock.withLock { current -> Bool in
      defer { current.holdNext = false }
      return current.holdNext
    }
    if hold {
      let fails = await withCheckedContinuation {
        (continuation: CheckedContinuation<Bool, Never>) in
        let early = lock.withLock { current -> Bool? in
          if let early = current.earlyRelease {
            current.earlyRelease = nil
            return early
          }
          current.held = continuation
          return nil
        }
        if let early { continuation.resume(returning: early) }
      }
      if fails { throw .encodingFailed }
    }
    lock.withLock { current in
      current.state = state
      current.saves.append(state)
    }
  } // End of func save(_:)

  /// Makes the next save wait for `releaseHeldSave(failing:)`.
  func holdNextSave() { lock.withLock { $0.holdNext = true } }

  /// Lets the held save go: kept, or failed when `failing`.
  func releaseHeldSave(failing: Bool) {
    let held = lock.withLock { current -> CheckedContinuation<Bool, Never>? in
      guard let held = current.held else {
        current.earlyRelease = failing
        return nil
      }
      current.held = nil
      return held
    }
    held?.resume(returning: failing)
  }

  /// Whether a save is held.
  var isHoldingSave: Bool { lock.withLock { $0.held != nil } }
  /// The state kept last.
  var state: UpdateState { lock.withLock { $0.state } }
  /// Every kept save, in order.
  var saves: [UpdateState] { lock.withLock { $0.saves } }
}
