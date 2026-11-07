import Foundation
import Testing

@testable import MuxFinderCore

/// `UpdateScheduler`'s timing (PLAN.md D39) over `ManualUpdateClock`, whose time moves only
/// when a test says, and `FakeUpdateTransport`, so no request is ever sent: the first check 5 s
/// after start, nothing before 24 h after a success, an hour after a failure, the rate limit's
/// wait, automatic checks off, manual checks (with automatic checks off, joining one in flight,
/// during a rate limit), the clock moved back, waking, the state kept across launches, and a
/// load of the state still pending past the launch delay (nothing armed or sent before it ends).
@Suite("Update scheduler")
struct UpdateSchedulerTests {
  /// Shorthand.
  typealias Support = UpdateTestSupport

  /// A scheduler with its fakes.
  struct Harness {
    /// The scheduler.
    let scheduler: UpdateScheduler
    /// Its transport.
    let transport: FakeUpdateTransport
    /// Its state store.
    let store: InMemoryUpdateStateStore
    /// Its clock.
    let clock: ManualUpdateClock

    /// Waits until no check is in flight, `requests` requests were made and `sleepers` sleeps
    /// wait (the armed timer).
    func settle(requests: Int, sleepers: Int = 1) async -> Bool {
      await Support.waitUntil {
        guard transport.calls == requests, clock.waiting == sleepers else { return false }
        return await scheduler.status.activity == .idle
      }
    }
  }

  /// The canonical 200 answer with an `ETag`.
  static let ok = UpdateCheckResponse.body(Data(Support.canonicalBody.utf8), etag: "\"e1\"")
  /// One second.
  static let second = Duration.seconds(1)
  /// One hour.
  static let hour = Duration.seconds(3600)
  /// One day.
  static let day = Duration.seconds(86_400)

  /// A harness over `state`, answering `script` then `fallback`, for an app running
  /// `runningVersion`; `clock` is shared to model a second launch.
  static func harness(
    state: UpdateState = UpdateState(),
    store: InMemoryUpdateStateStore? = nil,
    script: [UpdateCheckResponse] = [ok],
    fallback: UpdateCheckResponse = .notModified,
    runningVersion: String = "0.2.0",
    clock: ManualUpdateClock = ManualUpdateClock()
  ) -> Harness {
    let transport = FakeUpdateTransport(script, fallback: fallback)
    let store = store ?? InMemoryUpdateStateStore(state)
    let scheduler = UpdateScheduler(
      transport: transport, stateStore: store, runningVersion: runningVersion, clock: clock)
    return Harness(scheduler: scheduler, transport: transport, store: store, clock: clock)
  } // End of func harness(state:store:script:fallback:runningVersion:clock:)

  /// Nothing is sent or armed before `start`, and the first automatic check is 5 s after it:
  /// not at 4.999 s.
  @Test func firstCheckFiveSecondsAfterStart() async throws {
    let harness = Self.harness()
    #expect(harness.clock.waiting == 0)
    #expect(await harness.scheduler.nextAutomaticCheck() == nil)
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    #expect(harness.clock.nextWake == .seconds(5))
    harness.clock.advance(by: .milliseconds(4999))
    #expect(harness.clock.waiting == 1)
    #expect(harness.transport.calls == 0)
    harness.clock.advance(by: .milliseconds(1))
    #expect(await harness.settle(requests: 1))
    let base = ManualUpdateClock.baseDate
    let status = await harness.scheduler.status
    #expect(
      status.lastCheck
        == UpdateCheckRecord(
          outcome: .checked(.newer(Support.release())), date: base.addingTimeInterval(5),
          manual: false))
    #expect(status.offer == .newer(Support.release()))
    #expect(status.lastSuccessfulCheck == base.addingTimeInterval(5))
    #expect(harness.transport.etags == [nil])
    let saved = await harness.store.state
    #expect(saved.lastAttempt == base.addingTimeInterval(5))
    #expect(saved.etag == "\"e1\"")
    #expect(saved.keptRelease == Support.release())
  } // End of func firstCheckFiveSecondsAfterStart()

  /// After a success nothing is sent for 24 h; then one request with `If-None-Match`, and a
  /// 304 keeps the release.
  @Test func nothingBefore24Hours() async throws {
    let harness = Self.harness()
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
    #expect(harness.clock.nextWake == Self.day)
    harness.clock.advance(by: Self.day - Self.second)
    #expect(harness.clock.waiting == 1)
    #expect(harness.transport.calls == 1)
    harness.clock.advance(by: Self.second)
    #expect(await harness.settle(requests: 2))
    #expect(harness.transport.etags == [nil, "\"e1\""])
    #expect(
      await harness.scheduler.status.lastCheck?.outcome == .checked(.newer(Support.release())))
    #expect(harness.clock.nextWake == Self.day)
    #expect(await harness.scheduler.requestsSent == 2)
  } // End of func nothingBefore24Hours()

  /// A failure is retried no sooner than an hour later, silently (only published).
  @Test func failureRetriesAfterAnHour() async throws {
    let harness = Self.harness(script: [.failed(.offline), .httpStatus(503)], fallback: Self.ok)
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
    #expect(await harness.scheduler.status.lastCheck?.outcome == .failed(.offline))
    #expect(harness.clock.nextWake == Self.hour)
    harness.clock.advance(by: Self.hour - Self.second)
    #expect(harness.transport.calls == 1)
    harness.clock.advance(by: Self.second)
    #expect(await harness.settle(requests: 2))
    #expect(await harness.scheduler.status.lastCheck?.outcome == .failed(.httpStatus(503)))
    #expect(harness.clock.nextWake == Self.hour)
    harness.clock.advance(by: Self.hour)
    #expect(await harness.settle(requests: 3))
    #expect(harness.clock.nextWake == Self.day)
  } // End of func failureRetriesAfterAnHour()

  /// A 304 with no kept release fails and drops the `ETag`, so the next check (an hour later)
  /// fetches the body.
  @Test func notModifiedWithoutReleaseRefetches() async throws {
    let harness = Self.harness(
      state: UpdateState(etag: "\"stale\""), script: [.notModified], fallback: Self.ok)
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
    #expect(
      await harness.scheduler.status.lastCheck?.outcome == .failed(.notModifiedWithoutRelease))
    #expect(await harness.store.state.etag == nil)
    harness.clock.advance(by: Self.hour)
    #expect(await harness.settle(requests: 2))
    #expect(harness.transport.etags == ["\"stale\"", nil])
    #expect(await harness.scheduler.status.offer == .newer(Support.release()))
  } // End of func notModifiedWithoutReleaseRefetches()

  /// A rate limit holds every automatic check until its date, and a manual check during it
  /// answers "rate limited until …" without sending.
  @Test func rateLimitWaitsForTheReset() async throws {
    let base = ManualUpdateClock.baseDate
    let reset = base.addingTimeInterval(5 + 7200)
    let harness = Self.harness(script: [.rateLimited(until: reset)], fallback: Self.ok)
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
    #expect(await harness.scheduler.status.lastCheck?.outcome == .rateLimited(until: reset))
    #expect(harness.clock.nextWake == .seconds(7200))
    #expect(await harness.scheduler.checkNow() == .rateLimited(until: reset))
    #expect(harness.transport.calls == 1)
    let manual = await harness.scheduler.status.lastCheck
    #expect(manual?.manual == true && manual?.outcome == .rateLimited(until: reset))
    harness.clock.advance(by: Self.hour)
    #expect(harness.transport.calls == 1)
    #expect(harness.clock.waiting == 1)
    harness.clock.advance(by: Self.hour)
    #expect(await harness.settle(requests: 2))
    #expect(await harness.store.state.rateLimitedUntil == nil)
  } // End of func rateLimitWaitsForTheReset()

  /// With automatic checks off nothing is armed or sent, however long it waits; turning them
  /// on arms the check, due at once here.
  @Test func automaticChecksOffSendNothing() async throws {
    let harness = Self.harness()
    await harness.scheduler.start(automaticChecks: false)
    #expect(await harness.scheduler.nextAutomaticCheck() == nil)
    for _ in 0..<4 {
      harness.clock.advance(by: Self.day)
      await harness.scheduler.woke()
    }
    try await Task.sleep(for: .milliseconds(50))
    #expect(harness.clock.waiting == 0)
    #expect(harness.transport.calls == 0)
    #expect(await harness.store.saveCount == 0)
    await harness.scheduler.setAutomaticChecks(true)
    #expect(await harness.settle(requests: 1))
    await harness.scheduler.setAutomaticChecks(false)
    #expect(harness.clock.waiting == 0)
    harness.clock.advance(by: Self.day * 3)
    try await Task.sleep(for: .milliseconds(50))
    #expect(harness.transport.calls == 1)
  } // End of func automaticChecksOffSendNothing()

  /// A manual check runs with automatic checks off (and before `start`), sends exactly one
  /// request and arms nothing.
  @Test func manualCheckWithAutomaticChecksOff() async throws {
    let early = Self.harness()
    #expect(await early.scheduler.checkNow() == .checked(.newer(Support.release())))
    #expect(early.transport.calls == 1)
    #expect(early.clock.waiting == 0)

    let harness = Self.harness()
    await harness.scheduler.start(automaticChecks: false)
    let outcome = await harness.scheduler.checkNow()
    #expect(outcome == .checked(.newer(Support.release())))
    #expect(harness.transport.calls == 1)
    let record = await harness.scheduler.status.lastCheck
    #expect(record?.manual == true)
    #expect(record?.date == ManualUpdateClock.baseDate)
    #expect(harness.clock.waiting == 0)
    #expect(await harness.scheduler.checkNow() == .checked(.newer(Support.release())))
    #expect(harness.transport.calls == 2)
    #expect(harness.transport.etags == [nil, "\"e1\""])
  } // End of func manualCheckWithAutomaticChecksOff()

  /// A manual check joins the check in flight: one request, the same outcome for all.
  @Test func manualCheckJoinsTheCheckInFlight() async throws {
    let harness = Self.harness()
    harness.transport.hold()
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await Support.waitUntil { harness.transport.heldCount == 1 })
    #expect(await harness.scheduler.status.activity == .checking(manual: false))
    let first = Task { await harness.scheduler.checkNow() }
    let second = Task { await harness.scheduler.checkNow() }
    #expect(await Support.waitUntil { await harness.scheduler.joinedChecks == 2 })
    #expect(harness.transport.calls == 1)
    harness.transport.releaseHeld()
    let expected = UpdateCheckOutcome.checked(.newer(Support.release()))
    #expect(await first.value == expected)
    #expect(await second.value == expected)
    #expect(await harness.settle(requests: 1))
    #expect(await harness.scheduler.status.lastCheck?.manual == false)
  } // End of func manualCheckJoinsTheCheckInFlight()

  /// A manual check while automatic checks are off, held, then joined by another: still one
  /// request; the in-flight state is published as manual.
  @Test func manualChecksNeverOverlap() async throws {
    let harness = Self.harness()
    harness.transport.hold()
    await harness.scheduler.start(automaticChecks: false)
    let first = Task { await harness.scheduler.checkNow() }
    #expect(await Support.waitUntil { harness.transport.heldCount == 1 })
    #expect(await harness.scheduler.status.activity == .checking(manual: true))
    let second = Task { await harness.scheduler.checkNow() }
    #expect(await Support.waitUntil { await harness.scheduler.joinedChecks == 1 })
    harness.transport.releaseHeld()
    #expect(await first.value == (await second.value))
    #expect(harness.transport.calls == 1)
  } // End of func manualChecksNeverOverlap()

  /// A last check in the future (the clock went back) counts as due: the check runs 5 s after
  /// start; and after the clock is set back while running, waking runs it at once.
  @Test func clockMovedBackCountsAsDue() async throws {
    let base = ManualUpdateClock.baseDate
    let future = base.addingTimeInterval(3 * 86_400)
    let harness = Self.harness(
      state: UpdateState(
        lastSuccessfulCheck: future, lastAttempt: future, keptRelease: Support.release(),
        rateLimitedUntil: future))
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    #expect(harness.clock.nextWake == .seconds(5))
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
    #expect(harness.clock.nextWake == Self.day)
    harness.clock.shiftWallClock(by: -2 * 86_400)
    await harness.scheduler.woke()
    #expect(await harness.settle(requests: 2))
  } // End of func clockMovedBackCountsAsDue()

  /// The clock set back a day between start and the first check: the first check still comes,
  /// at most 5 s after the clock was set back.
  @Test func clockMovedBackBeforeTheFirstCheck() async throws {
    let harness = Self.harness()
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(2))
    harness.clock.shiftWallClock(by: -86_400)
    await harness.scheduler.woke()
    #expect(await Support.waitUntil { harness.clock.nextWake == .seconds(5) })
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
  }

  /// The Mac slept past the due time: waking runs the check at once.
  @Test func wakingRunsADueCheck() async throws {
    let harness = Self.harness()
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
    harness.clock.shiftWallClock(by: 23 * 3600)
    await harness.scheduler.woke()
    #expect(await Support.waitUntil { harness.clock.nextWake == Self.hour })
    harness.clock.shiftWallClock(by: 2 * 3600)
    await harness.scheduler.woke()
    #expect(await harness.settle(requests: 2))
  } // End of func wakingRunsADueCheck()

  /// The state carries over to the next launch: a check made an hour ago means no check at
  /// launch, the next one 23 h later.
  @Test func nextLaunchKeepsTheSchedule() async throws {
    let clock = ManualUpdateClock()
    let first = Self.harness(clock: clock)
    await first.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { clock.waiting == 1 })
    clock.advance(by: .seconds(5))
    #expect(await first.settle(requests: 1))
    await first.scheduler.stop()
    #expect(clock.waiting == 0)
    clock.advance(by: Self.hour)
    let second = Self.harness(store: first.store, clock: clock)
    await second.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { clock.waiting == 1 })
    #expect(clock.nextWake == Self.day - Self.hour)
    #expect(second.transport.calls == 0)
    #expect(await second.scheduler.status.offer == .newer(Support.release()))
  } // End of func nextLaunchKeepsTheSchedule()

  /// A scheduler over `store` (whose load the test holds) with a fresh transport and clock.
  static func suspendedHarness(
    _ store: SuspendedUpdateStateStore
  ) -> (scheduler: UpdateScheduler, transport: FakeUpdateTransport, clock: ManualUpdateClock) {
    let transport = FakeUpdateTransport([ok], fallback: .notModified)
    let clock = ManualUpdateClock()
    let scheduler = UpdateScheduler(
      transport: transport, stateStore: store, runningVersion: "0.2.0", clock: clock)
    return (scheduler, transport, clock)
  }

  /// The state's load still pending past the launch delay: a wake 6 s after start arms and
  /// sends nothing until the load ends; then the loaded throttling holds (a success an hour
  /// before start: the next check 23 h after start, not at once). A regression of the phase's
  /// review: the wake used to arm on the empty state and send at once.
  @Test func wakeDuringASuspendedLoadWaitsForTheState() async throws {
    let anHourAgo = ManualUpdateClock.baseDate.addingTimeInterval(-3600)
    let store = SuspendedUpdateStateStore(
      UpdateState(
        lastSuccessfulCheck: anHourAgo, lastAttempt: anHourAgo, keptRelease: Support.release()))
    let (scheduler, transport, clock) = Self.suspendedHarness(store)
    let start = Task { await scheduler.start(automaticChecks: true) }
    #expect(await Support.waitUntil { store.loadCalls == 1 })
    clock.advance(by: .seconds(6))
    await scheduler.woke()
    #expect(await scheduler.nextAutomaticCheck() == nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.calls == 0)
    #expect(clock.waiting == 0)
    #expect(store.saveCount == 0)
    store.releaseLoad()
    await start.value
    #expect(await Support.waitUntil { clock.waiting == 1 })
    let remaining = Self.day - Self.hour - .seconds(6)
    #expect(clock.nextWake == remaining)
    #expect(await scheduler.nextAutomaticCheck() == anHourAgo.addingTimeInterval(86_400))
    #expect(transport.calls == 0)
    clock.advance(by: remaining - Self.second)
    #expect(transport.calls == 0)
    clock.advance(by: Self.second)
    #expect(
      await Support.waitUntil {
        guard transport.calls == 1 else { return false }
        return await scheduler.status.activity == .idle
      })
    #expect(await scheduler.status.lastCheck?.manual == false)
    #expect(store.loadCalls == 1)
  } // End of func wakeDuringASuspendedLoadWaitsForTheState()

  /// The state's load still pending past the launch delay, automatic checks off at start:
  /// turning them on and a manual check send nothing until the load ends; then the persisted
  /// rate limit holds both (the manual check answers "rate limited until …" without sending,
  /// the automatic one, armed once the load ended, waits for its date). A regression of the
  /// phase's review: the toggle used to arm on the empty state and send at once.
  @Test func toggleAndManualCheckDuringASuspendedLoadKeepTheRateLimit() async throws {
    let base = ManualUpdateClock.baseDate
    let reset = base.addingTimeInterval(7200)
    let store = SuspendedUpdateStateStore(
      UpdateState(lastAttempt: base.addingTimeInterval(-60), rateLimitedUntil: reset))
    let (scheduler, transport, clock) = Self.suspendedHarness(store)
    let start = Task { await scheduler.start(automaticChecks: false) }
    #expect(await Support.waitUntil { store.loadCalls == 1 })
    clock.advance(by: .seconds(6))
    await scheduler.setAutomaticChecks(true)
    #expect(await scheduler.nextAutomaticCheck() == nil)
    let manual = Task { await scheduler.checkNow() }
    try await Task.sleep(for: .milliseconds(50))
    #expect(transport.calls == 0)
    #expect(clock.waiting == 0)
    #expect(store.saveCount == 0)
    store.releaseLoad()
    await start.value
    #expect(await manual.value == .rateLimited(until: reset))
    #expect(transport.calls == 0)
    #expect(await Support.waitUntil { clock.waiting == 1 })
    #expect(clock.nextWake == .seconds(7200 - 6))
    #expect(await scheduler.nextAutomaticCheck() == reset)
    clock.advance(by: .seconds(7200 - 6 - 1))
    #expect(transport.calls == 0)
    clock.advance(by: Self.second)
    #expect(await Support.waitUntil { transport.calls == 1 })
    #expect(store.loadCalls == 1)
  } // End of func toggleAndManualCheckDuringASuspendedLoadKeepTheRateLimit()

  /// "Newer" is worked out against the running version: an app already on the kept release
  /// is up to date.
  @Test func offerFollowsTheRunningVersion() async throws {
    let state = UpdateState(
      lastSuccessfulCheck: ManualUpdateClock.baseDate, keptRelease: Support.release())
    let updated = Self.harness(state: state, runningVersion: "0.3.0")
    await updated.scheduler.start(automaticChecks: false)
    #expect(await updated.scheduler.status.offer == .upToDate(latest: Support.release().version))
    let unknown = Self.harness(state: state, runningVersion: "dev")
    await unknown.scheduler.start(automaticChecks: false)
    #expect(await unknown.scheduler.status.offer == .nothingOffered(.runningVersionUnknown))
  }

  /// After `stop` nothing is armed or sent, and a manual check sends nothing.
  @Test func stopEndsEverything() async throws {
    let harness = Self.harness()
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    let stream = await harness.scheduler.updates()
    await harness.scheduler.stop()
    #expect(harness.clock.waiting == 0)
    harness.clock.advance(by: Self.day * 2)
    #expect(await harness.scheduler.checkNow() == .failed(.cancelled))
    try await Task.sleep(for: .milliseconds(50))
    #expect(harness.transport.calls == 0)
    var received = 0
    for await _ in stream { received += 1 }
    #expect(received >= 1)
  } // End of func stopEndsEverything()

  /// The published stream shows the check in flight, then its outcome.
  @Test func publishesCheckingThenTheOutcome() async throws {
    let harness = Self.harness()
    harness.transport.hold()
    await harness.scheduler.start(automaticChecks: false)
    let stream = await harness.scheduler.updates()
    let check = Task { await harness.scheduler.checkNow() }
    var seen: [UpdateCheckStatus.Activity] = []
    for await status in stream {
      seen.append(status.activity)
      if status.activity == .checking(manual: true) { harness.transport.releaseHeld() }
      if status.lastCheck != nil { break }
    } // End of loop over published statuses
    #expect(seen.contains(.checking(manual: true)))
    #expect(seen.last == .idle)
    _ = await check.value
  } // End of func publishesCheckingThenTheOutcome()

  /// A state that cannot be saved is still used in memory: the schedule holds.
  @Test func unsavedStateStillSchedules() async throws {
    let store = InMemoryUpdateStateStore()
    await store.setFailure(.existingFileNotRegular)
    let harness = Self.harness(store: store)
    await harness.scheduler.start(automaticChecks: true)
    #expect(await Support.waitUntil { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await harness.settle(requests: 1))
    #expect(await harness.scheduler.failedSaves == 2)
    #expect(harness.clock.nextWake == Self.day)
  } // End of func unsavedStateStillSchedules()
}
