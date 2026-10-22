import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// `RefreshCoordinator`'s slots, single flight, generations, configuration revisions and
/// `stop()`, with a scripted prober and a clock that only moves when a test advances it. One
/// test runs the real process runner against the fake tmux; nothing touches ssh, iTerm2 or the
/// user's tmux server.
@Suite("Refresh coordinator")
struct RefreshCoordinatorTests {
  /// Shorthand.
  typealias Support = RefreshTestSupport

  /// How a real-process test ends the run.
  enum RunEnd: String, CaseIterable, Sendable {
    /// `stop()`.
    case stop
    /// `systemWillSleep()`.
    case sleep
  }

  // MARK: - Slots and single flight

  /// A host whose probe hangs keeps only its own slot: the other three hosts (one of them
  /// queued behind the limit) turn live while it is still in flight.
  @Test func aSlowHostDoesNotDelayTheOthers() async {
    let hosts = (1...4).map { Support.sshHost("host-\($0)") }
    let prober = ScriptedProber()
    for host in hosts.dropFirst() {
      prober.setAnswer(.ok([Support.session(on: host)]), for: host.id)
    }
    let coordinator = Support.coordinator(hosts, prober: prober, clock: GatedAttachClock())
    await coordinator.start()
    #expect(
      await Support.waitUntil {
        await coordinator.state.hosts.dropFirst().allSatisfy(\.isLive)
      })
    #expect(await Support.waitUntil { prober.waitingCalls(of: hosts[0].id).count == 1 })
    let slow = await coordinator.state.snapshot(of: hosts[0].id)
    #expect(slow?.freshness == .notChecked)
    #expect(slow?.isRefreshing == true)
    prober.answerNext(hosts[0].id, with: .noServer)
    #expect(await Support.waitUntil { await coordinator.state.hosts.allSatisfy(\.isLive) })
    await coordinator.stop()
  } // End of func aSlowHostDoesNotDelayTheOthers()

  /// Requests that arrive while a host's attempt runs make exactly one follow-up attempt, which
  /// starts only after the first ended.
  @Test func overlappingRefreshesCoalesce() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    let coordinator = Support.coordinator([host], prober: prober, clock: GatedAttachClock())
    await coordinator.retry(host.id)
    #expect(await Support.waitUntil { prober.waitingCalls(of: host.id).count == 1 })
    await coordinator.retry(host.id)
    await coordinator.retryAll()
    await coordinator.popoverDidOpen()
    await coordinator.retry(host.id)
    #expect(await coordinator.attemptsStarted[host.id] == 1)
    prober.answerNext(host.id, with: .ok([Support.session(on: host, id: "$1")]))
    #expect(
      await Support.waitUntil {
        let started = await coordinator.attemptsStarted[host.id]
        return prober.waitingCalls(of: host.id).count == 1 && started == 2
      })
    prober.answerNext(host.id, with: .ok([Support.session(on: host, id: "$2")]))
    #expect(
      await Support.waitUntil {
        await coordinator.state.snapshot(of: host.id)?.isRefreshing == false
      })
    #expect(await coordinator.attemptsStarted[host.id] == 2)
    #expect(prober.callCount(of: host.id) == 2)
    #expect(prober.maxRunning == 1)
    let keys = await coordinator.state.snapshot(of: host.id)?.sessions.map(\.key.sessionID)
    #expect(keys == [TmuxSessionID("$2")!])
    await coordinator.stop()
  } // End of func overlappingRefreshesCoalesce()

  /// At most three probes run at once; queued hosts start as slots free up, first come first
  /// served, and a request for a queued host joins its queued attempt.
  @Test func theConcurrencyLimitIsThree() async {
    let hosts = (1...5).map { Support.sshHost("host-\($0)") }
    let prober = ScriptedProber()
    let coordinator = Support.coordinator(hosts, prober: prober, clock: GatedAttachClock())
    await coordinator.retryAll()
    #expect(
      await Support.waitUntil {
        hosts.prefix(3).allSatisfy { prober.waitingCalls(of: $0.id).count == 1 }
      })
    #expect(prober.running == 3)
    #expect(await coordinator.runningAttemptCount == 3)
    #expect(await coordinator.queuedHostCount == 2)
    await coordinator.retry(hosts[4].id)
    #expect(await coordinator.queuedHostCount == 2)
    #expect(Set(prober.calls.map(\.host.id)) == Set(hosts.prefix(3).map(\.id)))
    prober.answerNext(hosts[0].id, with: .noServer)
    #expect(await Support.waitUntil { prober.waitingCalls(of: hosts[3].id).count == 1 })
    #expect(await coordinator.queuedHostCount == 1)
    prober.answerNext(hosts[1].id, with: .noServer)
    #expect(await Support.waitUntil { prober.waitingCalls(of: hosts[4].id).count == 1 })
    #expect(await coordinator.queuedHostCount == 0)
    for host in hosts[2...] { prober.answerNext(host.id, with: .noServer) }
    #expect(await Support.waitUntil { await coordinator.state.hosts.allSatisfy(\.isLive) })
    #expect(prober.maxRunning == 3)
    for host in hosts {
      #expect(prober.callCount(of: host.id) == 1)
      #expect(await coordinator.attemptsStarted[host.id] == 1)
    }
    await coordinator.stop()
  } // End of func theConcurrencyLimitIsThree()

  /// A probe retired by a configuration edit (here one that ignores its cancellation) still
  /// holds its host's single flight and its slot: the edited host's new attempt waits in the
  /// queue without holding up the hosts behind it, the limit of three counts the retired probe,
  /// and the new attempt starts as soon as the retired probe ends, with no further request.
  @Test func aRetiredProbeKeepsItsHostsSingleFlight() async {
    let edited = Support.sshHost("host-a", destination: "old-host.example")
    var replacement = edited
    replacement.sshDestination = "new-host.example"
    let busy = Support.sshHost("host-b")
    let added = [Support.sshHost("host-c"), Support.sshHost("host-d")]
    let prober = ScriptedProber(ignoresCancellation: true)
    let coordinator = Support.coordinator(
      [edited, busy], prober: prober, clock: GatedAttachClock())
    await coordinator.start()
    #expect(
      await Support.waitUntil {
        prober.waitingCalls(of: edited.id).count == 1 && prober.waitingCalls(of: busy.id).count == 1
      })
    let retired = prober.waitingCalls(of: edited.id)[0]
    // Queue: the edited host (its probe retired, still running), then host-c, then host-d.
    await coordinator.setHosts(Support.list([replacement, busy] + added))
    #expect(await coordinator.attemptsStarted == [edited.id: 1, busy.id: 1, added[0].id: 1])
    #expect(await coordinator.runningAttemptCount == 3)
    #expect(await coordinator.queuedHostCount == 2)
    #expect(await coordinator.state.snapshot(of: edited.id)?.isRefreshing == true)
    // host-b ends: its slot goes to host-d, queued behind the edited host.
    prober.answerNext(busy.id, with: .noServer)
    #expect(await Support.waitUntil { prober.waitingCalls(of: added[1].id).count == 1 })
    #expect(await coordinator.attemptsStarted[edited.id] == 1)
    #expect(await coordinator.runningAttemptCount == 3)
    // host-c ends: a slot is free, and the edited host still waits for its retired probe.
    prober.answerNext(added[0].id, with: .noServer)
    #expect(await Support.waitUntil { await coordinator.runningAttemptCount == 2 })
    #expect(await coordinator.attemptsStarted[edited.id] == 1)
    #expect(await coordinator.queuedHostCount == 1)
    // The retired probe ends: its result is discarded and the new attempt starts on its own.
    prober.answer(retired, with: .ok([Support.session(on: edited, id: "$1")]))
    #expect(await Support.waitUntil { prober.waitingCalls(of: edited.id).count == 1 })
    #expect(await coordinator.discardedResults == 1)
    #expect(await coordinator.attemptsStarted[edited.id] == 2)
    #expect(prober.calls.last?.host.sshDestination == "new-host.example")
    prober.answerNext(edited.id, with: .ok([Support.session(on: edited, id: "$2")]))
    prober.answerNext(added[1].id, with: .noServer)
    #expect(await Support.waitUntil { await coordinator.state.hosts.allSatisfy(\.isLive) })
    let keys = await coordinator.state.snapshot(of: edited.id)?.sessions.map(\.key.sessionID)
    #expect(keys == [TmuxSessionID("$2")!])
    #expect(prober.maxRunning == 3)
    #expect(prober.maxRunning(of: edited.id) == 1)
    await coordinator.stop()
  } // End of func aRetiredProbeKeepsItsHostsSingleFlight()

  // MARK: - Generations and revisions

  /// A probe that ignored its cancellation at sleep answers only after waking: its result is
  /// discarded and never published. The refresh after waking waits for it (the retired probe
  /// keeps its host's single flight), starts once it has ended, and is applied.
  @Test func aLateStaleResultIsDiscarded() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber(ignoresCancellation: true)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator([host], prober: prober, clock: clock)
    let recorder = StateRecorder(await coordinator.updates(bufferingPolicy: .unbounded))
    await coordinator.start()
    #expect(await Support.waitUntil { prober.waitingCalls(of: host.id).count == 1 })
    let sleeping = Task { await coordinator.systemWillSleep() }
    #expect(await Support.waitUntil { await coordinator.state.isAsleep })
    await coordinator.systemDidWake()
    #expect(await Support.waitUntil { clock.waiting == 1 })
    clock.advance(by: .seconds(5))
    #expect(
      await Support.waitUntil {
        await coordinator.state.snapshot(of: host.id)?.isRefreshing == true
      })
    #expect(await coordinator.isWakeRefreshPending == false)
    #expect(await coordinator.attemptsStarted[host.id] == 1)
    let older = Support.session(on: host, id: "$1", name: "older")
    let newer = Support.session(on: host, id: "$2", name: "newer")
    prober.answerNext(host.id, with: .ok([older]))
    await sleeping.value
    #expect(await Support.waitUntil { prober.waitingCalls(of: host.id).count == 1 })
    #expect(await coordinator.discardedResults == 1)
    #expect(await coordinator.attemptsStarted[host.id] == 2)
    #expect(await coordinator.state.snapshot(of: host.id)?.freshness == .notChecked)
    prober.answerNext(host.id, with: .ok([newer]))
    #expect(
      await Support.waitUntil {
        await coordinator.state.snapshot(of: host.id)?.sessions.map(\.key) == [newer.key]
      })
    #expect(prober.maxRunning(of: host.id) == 1)
    await coordinator.stop()
    await recorder.finished()
    #expect(!recorder.all.contains { $0.sessions.contains { $0.key == older.key } })
  } // End of func aLateStaleResultIsDiscarded()

  /// Changing a host's destination retires the attempt in flight and resets the host under
  /// the new revision at once; the old probe's result is discarded, and the new attempt, for
  /// the new destination, starts as soon as the old probe has ended.
  @Test func aConfigEditInvalidatesInFlightWork() async {
    let original = Support.sshHost("host-a", destination: "old-host.example")
    var edited = original
    edited.sshDestination = "new-host.example"
    let prober = ScriptedProber(ignoresCancellation: true)
    let coordinator = Support.coordinator([original], prober: prober, clock: GatedAttachClock())
    let recorder = StateRecorder(await coordinator.updates(bufferingPolicy: .unbounded))
    await coordinator.start()
    #expect(await Support.waitUntil { prober.waitingCalls(of: original.id).count == 1 })
    await coordinator.setHosts(Support.list([edited]))
    #expect(await coordinator.state.configRevision == 2)
    let pending = await coordinator.state.snapshot(of: original.id)
    #expect(pending?.freshness == .notChecked)
    #expect(pending?.sessions.isEmpty == true)
    #expect(pending?.configRevision == 2)
    #expect(pending?.isRefreshing == true)
    #expect(pending?.host.sshDestination == "new-host.example")
    #expect(await coordinator.attemptsStarted[original.id] == 1)
    let stale = Support.session(on: original, id: "$1", name: "from-old-host")
    prober.answerNext(original.id, with: .ok([stale]))
    #expect(await Support.waitUntil { prober.waitingCalls(of: original.id).count == 1 })
    #expect(await coordinator.discardedResults == 1)
    #expect(prober.calls.last?.host.sshDestination == "new-host.example")
    #expect(await coordinator.state.snapshot(of: original.id)?.sessions.isEmpty == true)
    let current = Support.session(on: original, id: "$2", name: "from-new-host")
    prober.answerNext(original.id, with: .ok([current]))
    #expect(
      await Support.waitUntil {
        await coordinator.state.snapshot(of: original.id)?.sessions.map(\.key) == [current.key]
      })
    await coordinator.stop()
    await recorder.finished()
    #expect(!recorder.all.contains { $0.sessions.contains { $0.key == stale.key } })
  } // End of func aConfigEditInvalidatesInFlightWork()

  /// A removed host's late result is discarded and the host never reappears; added back with
  /// the same id it starts over under a new revision, and an answer to the attempt from before
  /// the removal still changes nothing.
  @Test func aRemovedHostsResultIsDropped() async {
    let kept = Support.sshHost("host-a")
    let removed = Support.sshHost("host-b")
    let prober = ScriptedProber(ignoresCancellation: true)
    prober.setAnswer(.noServer, for: kept.id)
    let coordinator = Support.coordinator(
      [kept, removed], prober: prober, clock: GatedAttachClock())
    await coordinator.start()
    #expect(await Support.waitUntil { prober.waitingCalls(of: removed.id).count == 1 })
    let first = prober.waitingCalls(of: removed.id)[0]
    await coordinator.setHosts(Support.list([kept]))
    #expect(await coordinator.state.snapshot(of: removed.id) == nil)
    prober.answer(first, with: .ok([Support.session(on: removed, id: "$1")]))
    #expect(await Support.waitUntil { await coordinator.discardedResults == 1 })
    #expect(await coordinator.state.snapshot(of: removed.id) == nil)
    #expect(await coordinator.state.hosts.map(\.host.id) == [kept.id])

    await coordinator.setHosts(Support.list([kept, removed]))
    #expect(await Support.waitUntil { prober.waitingCalls(of: removed.id).count == 1 })
    let readded = await coordinator.state.snapshot(of: removed.id)
    #expect(readded?.freshness == .notChecked)
    #expect(readded?.configRevision == 3)
    prober.answerNext(removed.id, with: .ok([Support.session(on: removed, id: "$2")]))
    #expect(
      await Support.waitUntil {
        await coordinator.state.snapshot(of: removed.id)?.sessions.map(\.key.sessionID.rawValue)
          == ["$2"]
      })
    await coordinator.stop()
  } // End of func aRemovedHostsResultIsDropped()

  /// Renaming a host changes nothing discovery does: the attempt in flight stays and its
  /// result is applied under the new name, with the revision unchanged.
  @Test func aRenameKeepsInFlightWork() async {
    let host = Support.sshHost("host-a")
    var renamed = host
    renamed.displayName = "Renamed host"
    renamed.iTermProfileName = "Work"
    let prober = ScriptedProber()
    let coordinator = Support.coordinator([host], prober: prober, clock: GatedAttachClock())
    await coordinator.start()
    #expect(await Support.waitUntil { prober.waitingCalls(of: host.id).count == 1 })
    await coordinator.setHosts(Support.list([renamed]))
    #expect(await coordinator.state.configRevision == 1)
    #expect(await coordinator.attemptsStarted[host.id] == 1)
    prober.answerNext(host.id, with: .noServer)
    #expect(
      await Support.waitUntil { await coordinator.state.snapshot(of: host.id)?.isLive == true })
    #expect(await coordinator.state.snapshot(of: host.id)?.host.displayName == "Renamed host")
    #expect(await coordinator.discardedResults == 0)
    await coordinator.stop()
  } // End of func aRenameKeepsInFlightWork()

  // MARK: - Stop

  /// `stop()` cancels the probe in flight, the scheduled attempt and the attachment check, and
  /// returns once every task ended: nothing is left running or sleeping, the update stream
  /// ends, and later calls start nothing.
  @Test func stopLeavesNoTasks() async {
    let busy = Support.sshHost("host-a")
    let idle = Support.sshHost("host-b")
    let prober = ScriptedProber()
    prober.setAnswer(.ok([Support.session(on: idle)]), for: idle.id)
    let index = FakeAttachmentIndex(.hang)
    let clock = GatedAttachClock()
    let coordinator = Support.coordinator(
      [busy, idle], prober: prober, index: index, clock: clock)
    let recorder = StateRecorder(await coordinator.updates(bufferingPolicy: .unbounded))
    await coordinator.start()
    await coordinator.popoverDidOpen()
    // Left running: the busy host's probe, the idle host's 15 s timer, the attachment check.
    #expect(
      await Support.waitUntil {
        let tasks = await coordinator.liveTaskCount
        return index.calls.count == 1 && clock.waiting == 1
          && prober.waitingCalls(of: busy.id).count == 1 && tasks == 3
      })
    await coordinator.stop()
    #expect(await coordinator.liveTaskCount == 0)
    #expect(await coordinator.runningAttemptCount == 0)
    #expect(prober.running == 0)
    #expect(prober.cancelled == 1)
    #expect(index.cancelled == 1)
    #expect(clock.waiting == 0)
    await recorder.finished()
    let last = recorder.all.last
    #expect(last?.hosts.allSatisfy { !$0.isRefreshing && $0.nextRefreshAt == nil } == true)
    let callsBefore = prober.calls.count
    await coordinator.start()
    await coordinator.retryAll()
    await coordinator.popoverDidOpen()
    await coordinator.systemDidWake()
    await coordinator.networkPathChanged()
    #expect(await coordinator.liveTaskCount == 0)
    #expect(prober.calls.count == callsBefore)
    #expect(index.calls.count == 1)
  } // End of func stopLeavesNoTasks()

  /// With the real process runner and discovery probe, a probe stuck in `list-sessions` (the
  /// fake tmux with a `sleep` child) is gone, its whole process group with it, when `stop()` or
  /// `systemWillSleep()` returns.
  @Test(arguments: RunEnd.allCases)
  func realProbeProcessGroupsAreGone(after end: RunEnd) async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tmux = try installFakeTmux(in: directory)
    let pidFile = directory.appending(path: "pids").path(percentEncoded: false)
    let probe = DiscoveryProbe(
      runner: TestSupport.patientRunner,
      baseEnvironment: [
        "PATH": ProcessEnvironment.systemSearchPath,
        "MUXFINDER_FAKE_MODE": "hang-pids",
        "MUXFINDER_FAKE_PIDFILE": pidFile,
      ],
      timeout: .seconds(60)
    )
    let host = HostConfig(displayName: "This Mac", mode: .local, tmuxPathOverride: tmux)
    let coordinator = RefreshCoordinator(
      hosts: Support.list([host]), discovery: probe, clock: GatedAttachClock())
    await coordinator.start()
    #expect(
      await TestSupport.eventually(within: .seconds(10)) {
        !TestSupport.processIDs(inFile: "pids", in: directory).isEmpty
      })
    let processIDs = TestSupport.processIDs(inFile: "pids", in: directory)
    #expect(processIDs.count == 2)
    let group = processIDs.first.map { getpgid($0) } ?? -1
    #expect(group > 0)
    switch end {
    case .stop: await coordinator.stop()
    case .sleep: await coordinator.systemWillSleep()
    }
    // The runner returns only once no member of the group is alive, so this holds at once:
    // `kill(-group, 0)` skips zombies (EPERM with only zombies left, ESRCH with none).
    let signalled = kill(-group, 0)
    let code = errno
    #expect(signalled == -1 && (code == ESRCH || code == EPERM))
    #expect(await coordinator.liveTaskCount == 0)
    for processID in processIDs {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(processID) })
    }
    #expect(await TestSupport.eventually { TestSupport.processGroupIsGone(group) })
    #expect(await coordinator.state.snapshot(of: host.id)?.freshness == .notChecked)
    await coordinator.stop()
  } // End of func realProbeProcessGroupsAreGone(after:)
}
