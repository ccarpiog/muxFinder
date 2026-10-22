import Foundation
import Testing

@testable import MuxFinderCore

/// What `RefreshCoordinator` publishes: live and stale snapshots, per-host session identity,
/// the attachment merge and its failure policy, `refreshOnce`, local discovery without ssh,
/// and the system-events adapter. Fakes only: no ssh, no iTerm2, no tmux.
@Suite("Refresh snapshots")
struct RefreshSnapshotTests {
  /// Shorthand.
  typealias Support = RefreshTestSupport

  /// The snapshot of `id` once `condition` holds for it.
  static func snapshot(
    of id: UUID,
    in coordinator: RefreshCoordinator,
    where condition: @escaping (HostSnapshot) -> Bool
  ) async -> HostSnapshot? {
    _ = await Support.waitUntil {
      guard let snapshot = await coordinator.state.snapshot(of: id) else { return false }
      return condition(snapshot)
    }
    return await coordinator.state.snapshot(of: id)
  } // End of func snapshot(of:in:where:)

  // MARK: - Live and stale

  /// A failure after a success keeps the sessions but marks them stale, never live, with the
  /// failure classified and the success's time kept; the next success is live again.
  @Test func aFailureAfterASuccessMarksTheSessionsStale() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    let first = Support.session(on: host, id: "$1", name: "first")
    prober.setAnswer(.ok([first]), for: host.id)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([host], prober: prober, clock: clock)
    await coordinator.retry(host.id)
    let live = await Self.snapshot(of: host.id, in: coordinator) { $0.isLive }
    #expect(live?.sessions.map(\.key) == [first.key])
    #expect(live?.lastOutcome == .sessionsListed)
    #expect(live?.nodeName == Support.nodeName(of: host))
    #expect(live?.lastSuccess != nil && live?.lastSuccess == live?.lastAttempt)

    clock.advance(by: .seconds(60))
    prober.setAnswer(.unreachable(.timeout), for: host.id)
    await coordinator.retry(host.id)
    let stale = await Self.snapshot(of: host.id, in: coordinator) { $0.freshness == .stale }
    #expect(stale?.isLive == false)
    #expect(stale?.sessions.map(\.key) == [first.key])
    #expect(stale?.lastError == .unreachable(.timeout))
    #expect(stale?.lastSuccess == live?.lastSuccess)
    #expect(stale?.lastAttempt == live?.lastAttempt.map { $0.addingTimeInterval(60) })
    #expect(stale?.consecutiveFailures == 1)
    #expect(stale?.nodeName == Support.nodeName(of: host))

    let second = Support.session(on: host, id: "$2", name: "second")
    prober.setAnswer(.ok([second]), for: host.id)
    await coordinator.retry(host.id)
    let again = await Self.snapshot(of: host.id, in: coordinator) { $0.isLive }
    #expect(again?.sessions.map(\.key) == [second.key])
    #expect(again?.consecutiveFailures == 0)
    await coordinator.stop()
  } // End of func aFailureAfterASuccessMarksTheSessionsStale()

  /// A host that never answered is stale with no sessions after a failure; `noServer` is a
  /// live answer with no sessions.
  @Test func outcomesWithoutSessions() async {
    let failing = Support.sshHost("host-a")
    let empty = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.probeError("Synthetic failure."), for: failing.id)
    prober.setAnswer(.noServer, for: empty.id)
    let coordinator = Support.coordinator(
      [failing, empty], prober: prober, clock: GatedAttachClock())
    let state = await coordinator.refreshOnce()
    let failed = state.snapshot(of: failing.id)
    #expect(failed?.freshness == .stale)
    #expect(failed?.sessions.isEmpty == true)
    #expect(failed?.lastSuccess == nil)
    #expect(failed?.lastError == .probeError("Synthetic failure."))
    #expect(failed?.nodeName == nil)
    let noServer = state.snapshot(of: empty.id)
    #expect(noServer?.freshness == .live)
    #expect(noServer?.lastOutcome == .noServer)
    #expect(noServer?.sessions.isEmpty == true)
    #expect(noServer?.nodeName == Support.nodeName(of: empty))
    await coordinator.stop()
  } // End of func outcomesWithoutSessions()

  /// The same session name (and id and server, as for one Mac reached two ways) on two hosts
  /// stays two entries with two keys; an attachment of one marks only that one.
  @Test func theSameSessionNameOnTwoHostsStaysTwoEntries() async {
    let hostA = Support.sshHost("host-a")
    let hostB = Support.sshHost("host-b")
    let sessionA = Support.session(on: hostA, id: "$0", name: "work")
    let sessionB = Support.session(on: hostB, id: "$0", name: "work")
    let prober = ScriptedProber()
    prober.setAnswer(.ok([sessionA]), for: hostA.id)
    prober.setAnswer(.ok([sessionB]), for: hostB.id)
    let attachment = AttachmentSnapshot.Attachment(
      key: sessionA.key, connectionID: "fixture-connection", owningSessionID: "fixture-owner")
    let index = FakeAttachmentIndex(.answer(AttachmentSnapshot(attachments: [attachment])))
    let coordinator = Support.coordinator(
      [hostA, hostB], prober: prober, index: index, clock: GatedAttachClock())
    let state = await coordinator.refreshOnce(includeAttachments: true)
    #expect(state.sessions.count == 2)
    #expect(Set(state.sessions.map(\.key)).count == 2)
    #expect(state.sessions.map(\.discovered.name) == ["work", "work"])
    #expect(state.snapshot(of: hostA.id)?.sessions.map(\.key) == [sessionA.key])
    #expect(state.snapshot(of: hostB.id)?.sessions.map(\.key) == [sessionB.key])
    #expect(state.snapshot(of: hostA.id)?.sessions.first?.attachments == [attachment])
    #expect(state.snapshot(of: hostB.id)?.sessions.first?.isOpenInITerm2Here == false)
    await coordinator.stop()
  } // End of func theSameSessionNameOnTwoHostsStaysTwoEntries()

  // MARK: - Attachments

  /// While the popover is visible, results are followed by an attachment check over the hosts'
  /// node names and servers; the attached session carries its connection, the others none.
  @Test func attachmentsAreMergedIntoSnapshots() async {
    let thisMac = Support.thisMac()
    let remote = Support.sshHost("host-b")
    let localServer = Support.server
    let remoteServer = ServerIdentity(
      socketPath: "/private/tmp/tmux-501/default", pid: 777, startTime: 1_792_500_000)
    let attached = Support.session(on: thisMac, id: "$4", server: localServer)
    let other = Support.session(on: remote, id: "$4", server: remoteServer)
    let prober = ScriptedProber()
    prober.setAnswer(.ok([attached]), for: thisMac.id)
    prober.setAnswer(.ok([other]), for: remote.id)
    let mapped = AttachmentSnapshot.Attachment(
      key: attached.key, connectionID: "fixture-connection", owningSessionID: "fixture-owner")
    let unknown = AttachmentSnapshot.Unmapped(
      connection: ITerm2API.TmuxConnection(connectionID: "other", owningSessionID: "owner-2"),
      kind: .stale, staleReason: .timedOut, reported: nil)
    let index = FakeAttachmentIndex(
      .answer(AttachmentSnapshot(attachments: [mapped], unmapped: [unknown])))
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator(
      [thisMac, remote], prober: prober, index: index, clock: clock)
    await coordinator.popoverDidOpen()
    #expect(
      await Support.waitUntil {
        let state = await coordinator.state
        return state.hosts.allSatisfy(\.isLive) && state.attachmentCheck.kind == "checked"
          && state.snapshot(of: thisMac.id)?.sessions.first?.isOpenInITerm2Here == true
          && index.calls.contains { $0.count == 2 }
      })
    let state = await coordinator.state
    #expect(state.snapshot(of: thisMac.id)?.sessions.first?.attachments == [mapped])
    #expect(state.snapshot(of: remote.id)?.sessions.first?.attachments.isEmpty == true)
    if case .checked(_, let counts) = state.attachmentCheck {
      #expect(counts == AttachmentSnapshot.Counts(mapped: 1, stale: 1))
    }
    // The check after the second result knows both hosts (the first may know one).
    let asked = index.calls.first { $0.count == 2 } ?? []
    #expect(
      Set(asked)
        == [
          AttachmentIndex.Host(
            hostID: thisMac.id, nodeName: Support.nodeName(of: thisMac), servers: [localServer]),
          AttachmentIndex.Host(
            hostID: remote.id, nodeName: Support.nodeName(of: remote), servers: [remoteServer]),
        ])
    await coordinator.stop()
  } // End of func attachmentsAreMergedIntoSnapshots()

  /// With the popover closed, refreshes never run the attachment check, so iTerm2 is never
  /// contacted in the background.
  @Test func backgroundRefreshesNeverCheckAttachments() async {
    let host = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.ok([Support.session(on: host)]), for: host.id)
    let index = FakeAttachmentIndex(.answer(AttachmentSnapshot()))
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([host], prober: prober, index: index, clock: clock)
    await coordinator.start()
    #expect(await Support.waitUntil { clock.waiting == 1 })
    clock.advance(by: .seconds(300))
    #expect(await Support.waitUntil { (await coordinator.attemptsStarted[host.id]) == 2 })
    await coordinator.retry(host.id)
    await coordinator.networkPathChanged()
    #expect(
      await Support.waitUntil {
        let started = await coordinator.attemptsStarted[host.id]
        let refreshing = await coordinator.state.snapshot(of: host.id)?.isRefreshing
        return started == 3 && refreshing == false
      })
    #expect(index.calls.isEmpty)
    #expect(await coordinator.indexPassesStarted == 0)
    #expect(await coordinator.state.attachmentCheck == .notChecked)
    await coordinator.stop()
  } // End of func backgroundRefreshesNeverCheckAttachments()

  /// D16's index-failure policy: a failed listing leaves which sessions are open unknown (no
  /// session keeps the attachment an earlier check found, and the check says `failed`), and
  /// iTerm2 not running means nothing is attached.
  @Test func anIndexFailureLeavesNoAttachment() async {
    let host = Support.thisMac()
    let session = Support.session(on: host)
    let prober = ScriptedProber()
    prober.setAnswer(.ok([session]), for: host.id)
    let attachment = AttachmentSnapshot.Attachment(
      key: session.key, connectionID: "fixture-connection", owningSessionID: "fixture-owner")
    let index = FakeAttachmentIndex(.answer(AttachmentSnapshot(attachments: [attachment])))
    let coordinator = Support.coordinator(
      [host], prober: prober, index: index, clock: GatedAttachClock())
    let attached = await coordinator.refreshOnce(includeAttachments: true)
    #expect(attached.snapshot(of: host.id)?.sessions.first?.attachments == [attachment])

    index.setBehavior(.fail(.apiDisabled))
    let failed = await coordinator.refreshOnce(includeAttachments: true)
    #expect(failed.snapshot(of: host.id)?.sessions.first?.attachments.isEmpty == true)
    #expect(failed.snapshot(of: host.id)?.isLive == true)
    if case .failed(_, let error) = failed.attachmentCheck {
      #expect(error == .apiDisabled)
    } else {
      Issue.record("expected a failed check, got \(failed.attachmentCheck.kind)")
    }

    index.setBehavior(.answer(AttachmentSnapshot(attachments: [attachment])))
    _ = await coordinator.refreshOnce(includeAttachments: true)
    index.setBehavior(.fail(.notRunning))
    let notRunning = await coordinator.refreshOnce(includeAttachments: true)
    #expect(notRunning.attachmentCheck.kind == "iTermNotRunning")
    #expect(notRunning.snapshot(of: host.id)?.sessions.first?.isOpenInITerm2Here == false)
    #expect(index.calls.count == 4)
    await coordinator.stop()
  } // End of func anIndexFailureLeavesNoAttachment()

  // MARK: - refreshOnce and discovery

  /// `refreshOnce()` waits for every host and schedules nothing; without
  /// `includeAttachments` the index is never asked.
  @Test func refreshOnceRefreshesEveryHostAndSchedulesNothing() async {
    let hosts = [Support.thisMac(), Support.sshHost("host-b"), Support.sshHost("host-c")]
    let prober = ScriptedProber()
    for host in hosts { prober.setAnswer(.ok([Support.session(on: host)]), for: host.id) }
    let index = FakeAttachmentIndex(.answer(AttachmentSnapshot()))
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator(hosts, prober: prober, index: index, clock: clock)
    let state = await coordinator.refreshOnce()
    #expect(state.hosts.map(\.host.id) == hosts.map(\.id))
    #expect(state.hosts.allSatisfy { $0.isLive && !$0.isRefreshing && $0.nextRefreshAt == nil })
    #expect(state.sessions.count == 3)
    #expect(state.attachmentCheck == .notChecked)
    #expect(index.calls.isEmpty)
    #expect(await coordinator.armedTimerCount == 0)
    #expect(clock.waiting == 0)
    await coordinator.stop()
    #expect(await coordinator.liveTaskCount == 0)
  } // End of func refreshOnceRefreshesEveryHostAndSchedulesNothing()

  /// This Mac is discovered with `/bin/sh` and never through ssh; only the SSH host's request
  /// runs `/usr/bin/ssh`.
  @Test func thisMacNeverUsesSSH() async {
    let thisMac = Support.thisMac()
    let remote = Support.sshHost("host-b")
    let runner = FakeProcessRunner(stdout: Data())
    let probe = DiscoveryProbe(
      runner: runner, baseEnvironment: ["PATH": ProcessEnvironment.systemSearchPath])
    let coordinator = RefreshCoordinator(
      hosts: Support.list([thisMac, remote]), discovery: probe, clock: GatedAttachClock())
    _ = await coordinator.refreshOnce()
    let requests = runner.requests
    #expect(requests.count == 2)
    let ssh = requests.filter { $0.executableURL == DiscoveryProbe.sshURL }
    let local = requests.filter { $0.executableURL == DiscoveryProbe.shellURL }
    #expect(ssh.count == 1)
    #expect(local.count == 1)
    #expect(ssh.first?.arguments.contains("host-b.example") == true)
    #expect(local.first?.arguments.contains("host-b.example") == false)
    await coordinator.stop()
  } // End of func thisMacNeverUsesSSH()

  // MARK: - System events

  /// Sleep and wake notifications reach the coordinator in order (a wake never overtakes its
  /// sleep), and nothing is forwarded after `stop()`.
  @Test func systemEventsForwardSleepAndWakeInOrder() async {
    let host = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.noServer, for: host.id)
    let coordinator = Support.coordinator([host], prober: prober, clock: GatedAttachClock())
    await coordinator.start()
    let center = NotificationCenter()
    let events = RefreshSystemEvents(
      coordinator: coordinator, notificationCenter: center, watchesNetworkPath: false)
    events.start()
    center.post(name: RefreshSystemEvents.willSleepNotification, object: nil)
    center.post(name: RefreshSystemEvents.didWakeNotification, object: nil)
    await events.stop()
    #expect(await coordinator.isWakeRefreshPending)
    #expect(await coordinator.state.isAsleep == false)
    center.post(name: RefreshSystemEvents.willSleepNotification, object: nil)
    #expect(await coordinator.state.isAsleep == false)
    await coordinator.stop()
  } // End of func systemEventsForwardSleepAndWakeInOrder()

  /// A forwarded network change refreshes the failing host.
  @Test func systemEventsForwardNetworkChanges() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    prober.setAnswer(.unreachable(.dnsFailure), for: host.id)
    let coordinator = Support.coordinator([host], prober: prober, clock: GatedAttachClock())
    _ = await coordinator.refreshOnce()
    let events = RefreshSystemEvents(
      coordinator: coordinator, notificationCenter: NotificationCenter(), watchesNetworkPath: false)
    events.start()
    events.deliver(.networkPathChanged)
    await events.stop()
    #expect(await coordinator.attemptsStarted[host.id] == 2)
    await coordinator.stop()
  } // End of func systemEventsForwardNetworkChanges()

  /// A `stop()` that runs while `start()` is installing its observers (here inside the first
  /// registration) ends that start for good: once `start()` returns nothing is observed, a
  /// notification is not forwarded, and a later start and stop leave nothing behind either.
  @Test func stopDuringStartLeavesNothingObserved() async {
    let host = Support.thisMac()
    let prober = ScriptedProber()
    prober.setAnswer(.noServer, for: host.id)
    let coordinator = Support.coordinator([host], prober: prober, clock: GatedAttachClock())
    await coordinator.start()
    let center = CountingNotificationCenter()
    let events = RefreshSystemEvents(
      coordinator: coordinator, notificationCenter: center, watchesNetworkPath: false)
    center.runInsideNextRegistration {
      let stopped = DispatchSemaphore(value: 0)
      Task.detached {
        await events.stop()
        stopped.signal()
      }
      stopped.wait()
    }
    // On a Dispatch thread, so the hook's wait never blocks the test's task pool.
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      DispatchQueue.global().async {
        events.start()
        continuation.resume()
      }
    }
    #expect(center.liveObservers == 0)
    center.post(name: RefreshSystemEvents.willSleepNotification, object: nil)
    #expect(await coordinator.state.isAsleep == false)
    events.start()
    #expect(center.liveObservers == 2)
    await events.stop()
    #expect(center.liveObservers == 0)
    await coordinator.stop()
  } // End of func stopDuringStartLeavesNothingObserved()

  /// The path filter treats the first path as the baseline and repeats as no change.
  @Test func changeFilterIgnoresTheFirstValueAndRepeats() {
    var filter = ChangeFilter<Int>()
    #expect(filter.isChange(1) == false)
    #expect(filter.isChange(1) == false)
    #expect(filter.isChange(2) == true)
    #expect(filter.isChange(2) == false)
    #expect(filter.isChange(1) == true)
  }
}
