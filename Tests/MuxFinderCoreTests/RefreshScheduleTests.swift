import Foundation
import Testing

@testable import MuxFinderCore

/// `RefreshCoordinator`'s cadence, backoff, sleep, wake and network-change handling. The clock
/// only moves when a test advances it, so every timer fires exactly when the test says.
@Suite("Refresh schedule")
struct RefreshScheduleTests {
  /// Shorthand.
  typealias Support = RefreshTestSupport

  /// Waits until host `id` has had `attempts` attempts, the last one ended and the next one is
  /// scheduled (its timer is the clock's only sleeper), then returns how far ahead that is.
  static func nextDelay(
    _ coordinator: RefreshCoordinator,
    _ id: UUID,
    afterAttempts attempts: Int,
    clock: GatedAttachClock
  ) async -> Duration? {
    let ready = await Support.waitUntil {
      guard (await coordinator.attemptsStarted[id]) == attempts, clock.waiting == 1,
        let snapshot = await coordinator.state.snapshot(of: id)
      else { return false }
      return !snapshot.isRefreshing && snapshot.nextRefreshAt != nil
    }
    guard ready, let due = await coordinator.state.snapshot(of: id)?.nextRefreshAt else {
      return nil
    }
    return clock.now().duration(to: due)
  } // End of func nextDelay(_:_:afterAttempts:clock:)

  /// In the background a failing host waits 30 s, 1 min, 2 min, 5 min, then 15 min (the cap)
  /// before its next attempt, never sooner; a success returns it to the 5-minute cadence, and
  /// the next failure starts the steps over.
  @Test func backgroundBackoffProgressesAndResets() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    prober.setAnswer(.unreachable(.timeout), for: host.id)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([host], prober: prober, clock: clock)
    await coordinator.start()
    let steps: [Duration] = [30, 60, 120, 300, 900, 900].map { .seconds($0) }
    for (offset, step) in steps.enumerated() {
      let attempts = offset + 1
      let delay = await Self.nextDelay(coordinator, host.id, afterAttempts: attempts, clock: clock)
      #expect(delay == step)
      #expect(await coordinator.state.snapshot(of: host.id)?.consecutiveFailures == attempts)
      clock.advance(by: step - .seconds(1))
      #expect(await coordinator.attemptsStarted[host.id] == attempts)
      if attempts == steps.count {
        prober.setAnswer(.ok([Support.session(on: host)]), for: host.id)
      }
      clock.advance(by: .seconds(1))
    } // End of loop over the backoff steps
    let afterSuccess = await Self.nextDelay(
      coordinator, host.id, afterAttempts: steps.count + 1, clock: clock)
    #expect(afterSuccess == .seconds(300))
    #expect(await coordinator.state.snapshot(of: host.id)?.consecutiveFailures == 0)
    #expect(await coordinator.state.snapshot(of: host.id)?.isLive == true)
    prober.setAnswer(.unreachable(.timeout), for: host.id)
    clock.advance(by: .seconds(300))
    let afterReset = await Self.nextDelay(
      coordinator, host.id, afterAttempts: steps.count + 2, clock: clock)
    #expect(afterReset == .seconds(30))
    #expect(await coordinator.state.snapshot(of: host.id)?.consecutiveFailures == 1)
    await coordinator.stop()
  } // End of func backgroundBackoffProgressesAndResets()

  /// "Retry" for one host and for all run at once whatever the backoff; the failure they end
  /// with still counts, so the next background attempt waits the next step.
  @Test func manualRetryBypassesBackoff() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    prober.setAnswer(.authFailed, for: host.id)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([host], prober: prober, clock: clock)
    await coordinator.start()
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 1, clock: clock) == .seconds(30))
    clock.advance(by: .seconds(30))
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 2, clock: clock) == .seconds(60))
    await coordinator.retry(host.id)
    #expect(await coordinator.attemptsStarted[host.id] == 3)
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 3, clock: clock) == .seconds(120))
    await coordinator.retryAll()
    #expect(await coordinator.attemptsStarted[host.id] == 4)
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 4, clock: clock) == .seconds(300))
    #expect(clock.elapsed == .seconds(30))
    await coordinator.stop()
  } // End of func manualRetryBypassesBackoff()

  /// While the popover is visible a failing host is retried every 15 s whatever its backoff;
  /// once it closes, the background backoff for its failure count applies again.
  @Test func visibleCadenceIgnoresBackoff() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    prober.setAnswer(.hostKeyProblem(.changed), for: host.id)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([host], prober: prober, clock: clock)
    await coordinator.start()
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 1, clock: clock) == .seconds(30))
    await coordinator.popoverDidOpen()
    #expect(await coordinator.attemptsStarted[host.id] == 2)
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 2, clock: clock) == .seconds(15))
    clock.advance(by: .seconds(15))
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 3, clock: clock) == .seconds(15))
    #expect(await coordinator.state.snapshot(of: host.id)?.consecutiveFailures == 3)
    await coordinator.popoverDidClose()
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 3, clock: clock) == .seconds(120))
    await coordinator.stop()
  } // End of func visibleCadenceIgnoresBackoff()

  /// A healthy host is refreshed every 5 minutes in the background, at once when the popover
  /// opens, every 15 s while it is visible, and every 5 minutes again after it closes.
  @Test func cadenceFollowsThePopover() async {
    let host = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.ok([Support.session(on: host)]), for: host.id)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([host], prober: prober, clock: clock)
    await coordinator.start()
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 1, clock: clock) == .seconds(300))
    await coordinator.popoverDidOpen()
    #expect(await coordinator.attemptsStarted[host.id] == 2)
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 2, clock: clock) == .seconds(15))
    clock.advance(by: .seconds(15))
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 3, clock: clock) == .seconds(15))
    await coordinator.popoverDidClose()
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 3, clock: clock) == .seconds(300))
    clock.advance(by: .seconds(299))
    #expect(await coordinator.attemptsStarted[host.id] == 3)
    clock.advance(by: .seconds(1))
    #expect(
      await Self.nextDelay(coordinator, host.id, afterAttempts: 4, clock: clock) == .seconds(300))
    await coordinator.stop()
  } // End of func cadenceFollowsThePopover()

  /// Sleep cancels the probe in flight and every timer and returns once they ended; nothing
  /// scheduled runs while asleep, however much time passes; waking refreshes every host
  /// exactly 5 s later.
  @Test func sleepCancelsAndWakeRefreshesAfterFiveSeconds() async {
    let busy = Support.sshHost("host-a")
    let healthy = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.ok([Support.session(on: healthy)]), for: healthy.id)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([busy, healthy], prober: prober, clock: clock)
    await coordinator.start()
    #expect(
      await Support.waitUntil {
        let isLive = await coordinator.state.snapshot(of: healthy.id)?.isLive
        return clock.waiting == 1 && prober.waitingCalls(of: busy.id).count == 1 && isLive == true
      })
    await coordinator.systemWillSleep()
    #expect(prober.cancelled == 1)
    #expect(prober.running == 0)
    #expect(await coordinator.liveTaskCount == 0)
    #expect(clock.waiting == 0)
    let asleep = await coordinator.state
    #expect(asleep.isAsleep)
    #expect(asleep.hosts.allSatisfy { !$0.isRefreshing && $0.nextRefreshAt == nil })
    #expect(asleep.snapshot(of: busy.id)?.freshness == .notChecked)
    #expect(asleep.snapshot(of: healthy.id)?.isLive == true)

    clock.advance(by: .seconds(3600))
    await coordinator.networkPathChanged()
    #expect(await coordinator.attemptsStarted == [busy.id: 1, healthy.id: 1])

    await coordinator.systemDidWake()
    #expect(await coordinator.state.isAsleep == false)
    #expect(await Support.waitUntil { clock.waiting == 1 })
    clock.advance(by: .milliseconds(4999))
    #expect(await coordinator.attemptsStarted == [busy.id: 1, healthy.id: 1])
    clock.advance(by: .milliseconds(1))
    #expect(
      await Support.waitUntil {
        (await coordinator.attemptsStarted) == [busy.id: 2, healthy.id: 2]
      })
    #expect(await Support.waitUntil { prober.waitingCalls(of: busy.id).count == 1 })
    prober.answerNext(busy.id, with: .noServer)
    #expect(await Support.waitUntil { await coordinator.state.hosts.allSatisfy(\.isLive) })
    await coordinator.stop()
  } // End of func sleepCancelsAndWakeRefreshesAfterFiveSeconds()

  /// Sleep in the middle of `refreshOnce(includeAttachments: true)` ends the round: its probe
  /// is cancelled, the round returns, and it submits nothing afterwards (no attachment check),
  /// so the sleep leaves no task behind. A round started while asleep still runs.
  @Test func sleepEndsARefreshOnceRound() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    let index = FakeAttachmentIndex(.answer(AttachmentSnapshot()))
    let coordinator = Support.coordinator(
      [host], prober: prober, index: index, clock: GatedAttachClock())
    let round = Task { await coordinator.refreshOnce(includeAttachments: true) }
    #expect(await Support.waitUntil { prober.waitingCalls(of: host.id).count == 1 })
    await coordinator.systemWillSleep()
    let interrupted = await round.value
    #expect(interrupted.isAsleep)
    #expect(interrupted.attachmentCheck == .notChecked)
    #expect(interrupted.snapshot(of: host.id)?.freshness == .notChecked)
    #expect(prober.cancelled == 1)
    #expect(index.calls.isEmpty)
    #expect(await coordinator.indexPassesStarted == 0)
    #expect(await coordinator.liveTaskCount == 0)

    prober.setAnswer(.noServer, for: host.id)
    let asleep = await coordinator.refreshOnce(includeAttachments: true)
    #expect(asleep.snapshot(of: host.id)?.isLive == true)
    #expect(index.calls.count == 1)
    await coordinator.stop()
  } // End of func sleepEndsARefreshOnceRound()

  /// A network path change refreshes only the hosts whose last attempt failed, at once and
  /// whatever their backoff.
  @Test func networkChangeRefreshesOnlyFailingHosts() async {
    let healthy = Support.thisMac()
    let failing = Support.sshHost("host-b")
    let prober = ScriptedProber()
    prober.setAnswer(.noServer, for: healthy.id)
    prober.setAnswer(.unreachable(.noRoute), for: failing.id)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([healthy, failing], prober: prober, clock: clock)
    await coordinator.start()
    #expect(
      await Support.waitUntil {
        let state = await coordinator.state
        return state.snapshot(of: healthy.id)?.isLive == true
          && state.snapshot(of: failing.id)?.consecutiveFailures == 1
      })
    await coordinator.networkPathChanged()
    #expect(await coordinator.attemptsStarted == [healthy.id: 1, failing.id: 2])
    #expect(clock.elapsed == .zero)
    #expect(
      await Support.waitUntil {
        await coordinator.state.snapshot(of: failing.id)?.consecutiveFailures == 2
      })
    #expect(await coordinator.attemptsStarted[healthy.id] == 1)
    await coordinator.stop()
  } // End of func networkChangeRefreshesOnlyFailingHosts()
}
