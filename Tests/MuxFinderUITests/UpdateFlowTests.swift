import AppKit
import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The one-click update flow (PLAN.md D39 *The update flow (I-13c2a)*) over a fake pipeline:
/// the offer, prepare and Cancel, failures, the ask, install and the terminator, a quit's
/// bounded waits and the launch's leftover cleanup. Nothing here downloads, swaps, relaunches,
/// opens a URL or touches the real update folder: every effect is the fake's record.
@MainActor
@Suite(.serialized)
struct UpdateFlowTests {
  /// A synthetic release `version`, with its `muxFinder.zip` asset unless `withAsset` is false.
  static func release(_ version: String, withAsset: Bool = true) -> UpdateRelease {
    let tag = "v" + version
    var body: [String: Any] = [
      "tag_name": tag, "html_url": "https://github.com/ccarpiog/muxFinder/releases/tag/" + tag,
      "draft": false, "prerelease": false, "assets": [],
    ]
    if withAsset {
      body["assets"] = [
        [
          "name": "muxFinder.zip", "content_type": "application/zip", "state": "uploaded",
          "size": 100, "digest": "sha256:" + String(repeating: "ab01", count: 16),
          "browser_download_url":
            "https://github.com/ccarpiog/muxFinder/releases/download/\(tag)/muxFinder.zip",
        ]
      ]
    }
    let data = try! JSONSerialization.data(withJSONObject: body)
    guard case .release(let release) = UpdateReleaseParser.parse(data) else {
      fatalError("the synthetic release does not parse")
    }
    return release
  } // End of static func release(_:withAsset:)

  /// A flow over `pipeline`, recording the terminator's calls (with the state at each) and the
  /// opened URLs.
  struct Harness {
    /// The flow.
    let flow: UpdateFlow
    /// The fake pipeline.
    let pipeline: FakeUpdateFlowPipeline
    /// The flow's state at each terminator call.
    let terminated: OSAllocatedUnfairLock<[UpdateFlowState]>
    /// The URLs Download opened.
    let opened: OSAllocatedUnfairLock<[URL]>
  }

  /// A harness over `pipeline` with `unsaved` as the unsaved-work source.
  static func harness(
    _ pipeline: FakeUpdateFlowPipeline, unsaved: UpdateUnsavedWork = .none
  ) -> Harness {
    let terminated = OSAllocatedUnfairLock<[UpdateFlowState]>(initialState: [])
    let opened = OSAllocatedUnfairLock<[URL]>(initialState: [])
    nonisolated(unsafe) var flowBox: UpdateFlow?
    let flow = UpdateFlow(
      environment: UpdateFlowEnvironment(
        pipeline: pipeline,
        terminate: {
          let state = flowBox?.state ?? .idle
          terminated.withLock { $0.append(state) }
        },
        quitBound: .milliseconds(500)),
      openURL: { url in opened.withLock { $0.append(url) } })
    flowBox = flow
    flow.unsavedWork = { unsaved }
    return Harness(flow: flow, pipeline: pipeline, terminated: terminated, opened: opened)
  } // End of static func harness(_:unsaved:)

  /// Waits until `condition` holds (bounded).
  static func wait(_ condition: @MainActor () async -> Bool) async -> Bool {
    await UITestSupport.waitUntil(condition)
  }

  /// A harness whose notice shows `release` and whose offer is read.
  static func offered(
    _ pipeline: FakeUpdateFlowPipeline, unsaved: UpdateUnsavedWork = .none,
    release: UpdateRelease = release("0.3.0")
  ) async -> Harness {
    let harness = Self.harness(pipeline, unsaved: unsaved)
    harness.flow.noticeShown(release)
    await harness.flow.workEnded()
    return harness
  }

  // MARK: - The offer

  /// Eligible with an asset: Update, eligibility read once per notice version.
  @Test func eligibilityIsReadOncePerNoticeVersion() async {
    let harness = Self.harness(FakeUpdateFlowPipeline())
    #expect(harness.flow.offer == nil)
    harness.flow.noticeShown(Self.release("0.3.0"))
    #expect(harness.flow.offer == .reading)
    #expect(!harness.flow.canUpdate)
    await harness.flow.workEnded()
    #expect(harness.flow.offer == .update)
    #expect(harness.flow.canUpdate)
    harness.flow.noticeShown(Self.release("0.3.0"))
    await harness.flow.workEnded()
    #expect(harness.pipeline.calls.withLock { $0.eligibility } == 1)
    harness.flow.noticeShown(Self.release("0.4.0"))
    await harness.flow.workEnded()
    #expect(harness.pipeline.calls.withLock { $0.eligibility } == 2)
    harness.flow.noticeShown(nil)
    #expect(harness.flow.offer == nil)
  } // End of func eligibilityIsReadOncePerNoticeVersion()

  /// A notice cleared, then the same version again: the release and the offer read for it
  /// come back (Update pressable), with no second read.
  @Test func theSameVersionAfterAClearedNoticeRestoresTheOffer() async {
    let harness = await Self.offered(FakeUpdateFlowPipeline())
    #expect(harness.flow.offer == .update)
    harness.flow.noticeShown(nil)
    #expect(harness.flow.offer == nil)
    #expect(!harness.flow.canUpdate)
    harness.flow.noticeShown(Self.release("0.3.0"))
    #expect(harness.flow.offer == .update)
    #expect(harness.flow.canUpdate)
    harness.flow.update()
    await harness.flow.workEnded()
    #expect(harness.pipeline.calls.withLock { $0.eligibility } == 1)
    #expect(harness.pipeline.calls.withLock { $0.prepare } == 1)
  } // End of func theSameVersionAfterAClearedNoticeRestoresTheOffer()

  /// A newer notice during a prepare is kept and shown once the prepare is cancelled; during
  /// the ask it never changes what is installed: the prepared release.
  @Test func aNoticeDuringPrepareIsReconciled() async {
    let pipeline = FakeUpdateFlowPipeline(holdsPrepare: true)
    let harness = await Self.offered(pipeline)
    harness.flow.update()
    #expect(await Self.wait { harness.flow.state.isPreparing })
    harness.flow.noticeShown(Self.release("0.4.0"))
    #expect(harness.flow.preparedRelease?.version == Self.release("0.3.0").version)
    harness.flow.cancel()
    await harness.flow.workEnded()
    await harness.flow.workEnded()
    #expect(harness.flow.state == .idle)
    #expect(harness.flow.preparedRelease == nil)
    #expect(harness.flow.offer == .update)
    #expect(pipeline.calls.withLock { $0.eligibility } == 2)
    harness.flow.update()
    #expect(await Self.wait { pipeline.calls.withLock { $0.prepare } == 2 })
    #expect(pipeline.calls.withLock { $0.preparedVersions }.last == Self.release("0.4.0").version)
    harness.flow.cancel()
    await harness.flow.workEnded()

    let asked = FakeUpdateFlowPipeline()
    let second = await Self.offered(asked, unsaved: UpdateUnsavedWork(settingsEdits: true))
    second.flow.update()
    await second.flow.workEnded()
    second.flow.noticeShown(Self.release("0.5.0"))
    second.flow.notNow()
    #expect(second.flow.preparedRelease?.version == Self.release("0.3.0").version)
    second.flow.installAndRelaunch()
    second.flow.quitAndInstall()
    await second.flow.workEnded()
    #expect(asked.calls.withLock { $0.installedVersions } == [Self.release("0.3.0").version])
  } // End of func aNoticeDuringPrepareIsReconciled()

  /// Not eligible: Download with the reason's phrase, which opens the release page.
  @Test func notEligibleIsDownloadWithTheReason() async {
    let harness = await Self.offered(FakeUpdateFlowPipeline(ineligibility: .notDeveloperID))
    #expect(harness.flow.offer == .download(reason: UpdateIneligibility.notDeveloperID.reason))
    #expect(!harness.flow.canUpdate)
    harness.flow.update()
    #expect(harness.flow.state == .idle)
    harness.flow.download()
    #expect(harness.opened.withLock { $0 } == [Self.release("0.3.0").pageURL])
    #expect(harness.pipeline.calls.withLock { $0.prepare } == 0)
  }

  /// No installable asset: Download with a phrase of its own, no eligibility read.
  @Test func noAssetIsDownloadWithItsOwnPhrase() async {
    let harness = await Self.offered(
      FakeUpdateFlowPipeline(), release: Self.release("0.3.0", withAsset: false))
    #expect(harness.flow.offer == .download(reason: UpdateFlowText.noInstallableAsset))
    #expect(harness.pipeline.calls.withLock { $0.eligibility } == 0)
  }

  /// The inert flow offers and runs nothing.
  @Test func theInertFlowRunsNothing() async {
    let flow = UpdateFlow.inert()
    #expect(!flow.isAvailable)
    flow.noticeShown(Self.release("0.3.0"))
    flow.startCleanup()
    flow.update()
    #expect(flow.offer == nil)
    #expect(flow.state == .idle)
    #expect(flow.cleanupReport == nil)
    await flow.stop()
  } // End of func theInertFlowRunsNothing()

  // MARK: - Prepare

  /// Update: downloading with bytes and total (a percent), checking, prepared, then straight
  /// on to install with nothing unsaved; the terminator only after `relaunchScheduled`.
  @Test func prepareThenInstallWithNothingUnsaved() async {
    let pipeline = FakeUpdateFlowPipeline(
      prepareStates: [.downloading(bytes: 0, total: 100), .downloading(bytes: 40, total: 100)],
      holdsPrepare: true)
    let harness = await Self.offered(pipeline)
    harness.flow.update()
    #expect(await Self.wait { harness.flow.state == .downloading(bytes: 40, total: 100) })
    #expect(harness.flow.state.percent == 40)
    #expect(harness.flow.state.isPreparing)
    #expect(!harness.flow.canUpdate)
    harness.flow.update()
    pipeline.step(.checking)
    #expect(await Self.wait { harness.flow.state == .checking })
    pipeline.step(.downloading(bytes: 50, total: 100))
    pipeline.releasePrepare()
    #expect(await Self.wait { harness.flow.state == .relaunchScheduled })
    #expect(await Self.wait { harness.terminated.withLock { $0 } == [.relaunchScheduled] })
    let calls = pipeline.calls.withLock { $0 }
    #expect(calls.prepare == 1)
    #expect(calls.install == 1)
    #expect(calls.discard == 0)
  } // End of func prepareThenInstallWithNothingUnsaved()

  /// The percent and the downloading phrase; an unknown total has no percent.
  @Test func downloadingPercent() {
    #expect(UpdateFlowText.percent(bytes: 40, total: 100) == 40)
    #expect(UpdateFlowText.percent(bytes: 150, total: 100) == 100)
    #expect(UpdateFlowText.percent(bytes: 5, total: 0) == nil)
    #expect(UpdateFlowText.downloading(bytes: 2, total: 5) == "Downloading… 40%")
    #expect(UpdateFlowText.downloading(bytes: 2, total: 0) == "Downloading…")
    #expect(UpdateFlowState.downloading(bytes: 2, total: 0).percent == nil)
    #expect(UpdateFlowState.checking.percent == nil)
  }

  /// Cancel while downloading and while checking: cancelled, back to the offer.
  @Test func cancelReturnsToTheOffer() async {
    for checking in [false, true] {
      let pipeline = FakeUpdateFlowPipeline(
        prepareStates: [.downloading(bytes: 10, total: 100)], holdsPrepare: true)
      let harness = await Self.offered(pipeline)
      harness.flow.update()
      #expect(await Self.wait { harness.flow.state == .downloading(bytes: 10, total: 100) })
      if checking {
        pipeline.step(.checking)
        #expect(await Self.wait { harness.flow.state == .checking })
      }
      harness.flow.cancel()
      await harness.flow.workEnded()
      #expect(harness.flow.state == .idle, "checking \(checking)")
      #expect(harness.flow.canUpdate)
      #expect(pipeline.calls.withLock { $0.cancelledPrepares } == 1)
      #expect(pipeline.calls.withLock { $0.install } == 0)
    } // End of loop over cancelling while downloading and while checking
  } // End of func cancelReturnsToTheOffer()

  /// A prepare failure carries the typed reason's phrase; Update is offered again; an
  /// eligibility refusal at prepare turns the offer into Download.
  @Test func prepareFailureOffersUpdateAgain() async {
    let pipeline = FakeUpdateFlowPipeline(prepareResult: .failed(.stagingRoot(.busy)))
    let harness = await Self.offered(pipeline)
    harness.flow.update()
    await harness.flow.workEnded()
    let failure = UpdateFlowFailure.prepare(.stagingRoot(.busy))
    #expect(harness.flow.state == .failed(failure))
    #expect(failure.phrase == "Couldn't update: " + UpdateStagingRootError.busy.reason)
    #expect(harness.flow.canUpdate)
    harness.flow.update()
    await harness.flow.workEnded()
    #expect(pipeline.calls.withLock { $0.prepare } == 2)

    let refused = FakeUpdateFlowPipeline(prepareResult: .failed(.notEligible(.translocated)))
    let second = await Self.offered(refused)
    second.flow.update()
    await second.flow.workEnded()
    #expect(second.flow.state == .failed(.prepare(.notEligible(.translocated))))
    #expect(second.flow.offer == .download(reason: UpdateIneligibility.translocated.reason))
    #expect(!second.flow.canUpdate)
  } // End of func prepareFailureOffersUpdateAgain()

  // MARK: - The ask

  /// Some unsaved work: the ask names it; Not now keeps the update (Install and relaunch),
  /// which asks again; Quit and install installs and quits.
  @Test func theAskWithUnsavedWork() async {
    let work = UpdateUnsavedWork(newSessionDraft: true, settingsEdits: true)
    let pipeline = FakeUpdateFlowPipeline()
    let harness = await Self.offered(pipeline, unsaved: work)
    harness.flow.update()
    await harness.flow.workEnded()
    #expect(harness.flow.state == .asking(work))
    #expect(work.items == ["the New session draft", "unsaved changes in Settings"])
    harness.flow.notNow()
    #expect(harness.flow.state == .deferred)
    #expect(!harness.flow.canUpdate)
    harness.flow.installAndRelaunch()
    #expect(harness.flow.state == .asking(work))
    #expect(pipeline.calls.withLock { $0.install } == 0)
    harness.flow.quitAndInstall()
    #expect(harness.flow.state == .installing)
    await harness.flow.workEnded()
    #expect(harness.flow.state == .relaunchScheduled)
    #expect(await Self.wait { harness.terminated.withLock { $0 } == [.relaunchScheduled] })
    #expect(pipeline.calls.withLock { $0.install } == 1)
  } // End of func theAskWithUnsavedWork()

  /// Not now, then Install and relaunch once nothing is unsaved: installs without asking.
  @Test func notNowThenInstallAndRelaunch() async {
    let unsaved = OSAllocatedUnfairLock(initialState: UpdateUnsavedWork(newSessionDraft: true))
    let pipeline = FakeUpdateFlowPipeline()
    let harness = await Self.offered(pipeline)
    harness.flow.unsavedWork = { unsaved.withLock { $0 } }
    harness.flow.update()
    await harness.flow.workEnded()
    harness.flow.notNow()
    unsaved.withLock { $0 = .none }
    harness.flow.installAndRelaunch()
    #expect(harness.flow.state == .installing)
    await harness.flow.workEnded()
    #expect(harness.flow.state == .relaunchScheduled)
    #expect(await Self.wait { harness.terminated.withLock { $0 }.count == 1 })
  } // End of func notNowThenInstallAndRelaunch()

  /// The app's unsaved-work source: a New session window's draft with text, Settings' dirty
  /// directory list; nothing otherwise.
  @Test func appModelUnsavedWork() async {
    let model = AppModel(environment: AppEnvironment.placementDiagnostic())
    #expect(model.unsavedWorkForUpdate() == .none)
    model.newSessionDraft.name = "work"
    #expect(!model.unsavedWorkForUpdate().newSessionDraft, "the window does not show")
    model.settings.directoryDraft = ["/private/tmp/mfx-directory"]
    #expect(model.unsavedWorkForUpdate().settingsEdits == model.settings.isDirectoryListDirty)
    await model.shutdown()
  }

  /// While an update installs, the New session draft, Settings' host editor and directory list
  /// and opening a New session window refuse changes; a failed install restores editing.
  @Test func editsAreRefusedWhileInstalling() async {
    let pipeline = FakeUpdateFlowPipeline(
      installOutcome: .failed(.swapFailed(errno: EIO), rollback: .rolledBack), holdsInstall: true)
    var environment = AppEnvironment.placementDiagnostic()
    environment.update = UpdateEnvironment(
      scheduler: UpdateScheduler(
        transport: UpdateModelTestTransport([], fallback: UpdateModelTests.ok()),
        stateStore: InMemoryUpdateStateStore(), runningVersion: "0.2.0",
        clock: UpdateModelTestClock()),
      preferences: nil, runningVersion: "0.2.0", runningBuild: "2", openURL: { _ in },
      flow: UpdateFlowEnvironment(pipeline: pipeline, terminate: {}))
    let model = AppModel(environment: environment)
    let flow = model.update.flow
    model.newSessionDraft.name = "before"
    let hostsEditable = model.settings.isEditable
    let directoriesEditable = model.settings.areDirectoriesEditable
    flow.noticeShown(Self.release("0.3.0"))
    await flow.workEnded()
    #expect(!model.isInstallingUpdate)
    flow.update()
    #expect(await Self.wait { flow.state == .installing })
    #expect(model.isInstallingUpdate)
    model.newSessionDraft.name = "after"
    model.newSessionDraft.directory = "/private/tmp/mfx-directory"
    #expect(model.newSessionDraft.name == "before")
    #expect(model.newSessionDraft.directory.isEmpty)
    #expect(!model.settings.isEditable)
    #expect(!model.settings.areDirectoriesEditable)
    model.openNewSession(from: .popover, source: nil, prefill: "other")
    #expect(!model.isNewSessionShown)
    pipeline.releaseInstall()
    await flow.workEnded()
    #expect(!model.isInstallingUpdate)
    #expect(model.settings.isEditable == hostsEditable)
    #expect(model.settings.areDirectoriesEditable == directoriesEditable)
    model.newSessionDraft.name = "after"
    #expect(model.newSessionDraft.name == "after")
    await model.shutdown()
  } // End of func editsAreRefusedWhileInstalling()

  // MARK: - Install

  /// An install failure: its phrase (rolled back, `recoveryRequired`, a failed rollback), no
  /// terminator, Update offered again.
  @Test func installFailuresKeepTheAppRunning() async {
    let cases: [(UpdateInstallOutcome, String)] = [
      (
        .failed(.swapFailed(errno: EIO), rollback: .rolledBack),
        UpdateInstallFailure.swapFailed(errno: EIO).reason
      ),
      (
        .failed(.swapUnconfirmed, rollback: .recoveryRequired(runFolder: "/private/tmp/x")),
        UpdateRollback.recoveryRequired(runFolder: "/private/tmp/x").reason
          ?? UpdateFlowText.recoveryRequired
      ),
      (
        .failed(.swapUnconfirmed, rollback: .failed(runFolder: "/private/tmp/x")),
        UpdateInstallFailure.swapUnconfirmed.reason + ", and the change couldn't be undone"
      ),
    ]
    for (outcome, reason) in cases {
      let pipeline = FakeUpdateFlowPipeline(installOutcome: outcome)
      let harness = await Self.offered(pipeline)
      harness.flow.update()
      await harness.flow.workEnded()
      guard case .failed(let failure) = harness.flow.state else {
        Issue.record("not failed: \(harness.flow.state)")
        continue
      }
      #expect(failure.reason == reason)
      #expect(!failure.reason.contains("/private/tmp"))
      #expect(failure.phrase == "Couldn't update: " + reason)
      #expect(harness.flow.canUpdate)
      try? await Task.sleep(for: .milliseconds(50))
      #expect(harness.terminated.withLock { $0 }.isEmpty)
    } // End of loop over the install failures
  } // End of func installFailuresKeepTheAppRunning()

  // MARK: - Quit

  /// A quit while preparing cancels the prepare; nothing is installed or terminated.
  @Test func quitWhilePreparingCancels() async {
    let pipeline = FakeUpdateFlowPipeline(
      prepareStates: [.downloading(bytes: 1, total: 100)], holdsPrepare: true)
    let harness = await Self.offered(pipeline)
    harness.flow.update()
    #expect(await Self.wait { harness.flow.state.isPreparing })
    await harness.flow.stop()
    #expect(pipeline.calls.withLock { $0.cancelledPrepares } == 1)
    #expect(pipeline.calls.withLock { $0.install } == 0)
    #expect(harness.terminated.withLock { $0 }.isEmpty)
    harness.flow.update()
    #expect(pipeline.calls.withLock { $0.prepare } == 1)
  } // End of func quitWhilePreparingCancels()

  /// A quit once the swap began waits for the swap (and any rollback) to end, however long,
  /// then calls no terminator of its own; the install is never cut short.
  @Test func quitWhileInstallingLetsTheStepEnd() async {
    let pipeline = FakeUpdateFlowPipeline(installDelay: .milliseconds(1200))
    let harness = await Self.offered(pipeline)
    harness.flow.update()
    #expect(await Self.wait { pipeline.calls.withLock { $0.swapsStarted } == 1 })
    let started = ContinuousClock.now
    await harness.flow.stop()
    #expect(ContinuousClock.now - started >= .milliseconds(900))
    #expect(pipeline.calls.withLock { $0.installsEnded } == 1)
    #expect(pipeline.calls.withLock { $0.installCancelled } == false)
    #expect(harness.flow.state == .relaunchScheduled)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(harness.terminated.withLock { $0 }.isEmpty)
    #expect(harness.flow.locksEditing)
  } // End of func quitWhileInstallingLetsTheStepEnd()

  /// A quit before the swap starts stops the install at its last point before the swap and
  /// waits for that answer: nothing swapped, no terminator, editing still refused.
  @Test func quitBeforeTheSwapStopsTheInstall() async {
    let pipeline = FakeUpdateFlowPipeline(holdsInstall: true)
    let harness = await Self.offered(pipeline)
    harness.flow.update()
    #expect(await Self.wait { harness.flow.state == .installing })
    await harness.flow.stop()
    #expect(pipeline.calls.withLock { $0.installCancelled })
    #expect(pipeline.calls.withLock { $0.installsEnded } == 1)
    #expect(pipeline.calls.withLock { $0.swapsStarted } == 0)
    #expect(harness.flow.state == .failed(.install(.cancelled, rollback: .notNeeded)))
    #expect(harness.terminated.withLock { $0 }.isEmpty)
    #expect(harness.flow.locksEditing)
    pipeline.releaseInstall()
  } // End of func quitBeforeTheSwapStopsTheInstall()

  /// A prepared update never installed (Not now) is discarded at quit.
  @Test func aPreparedUpdateIsDiscardedAtQuit() async {
    let pipeline = FakeUpdateFlowPipeline()
    let harness = await Self.offered(pipeline, unsaved: UpdateUnsavedWork(settingsEdits: true))
    harness.flow.update()
    await harness.flow.workEnded()
    harness.flow.notNow()
    await harness.flow.stop()
    #expect(pipeline.calls.withLock { $0.discard } == 1)
    #expect(pipeline.calls.withLock { $0.install } == 0)
    harness.flow.installAndRelaunch()
    #expect(pipeline.calls.withLock { $0.install } == 0)
  } // End of func aPreparedUpdateIsDiscardedAtQuit()

  // MARK: - Cleanup at launch

  /// The live model with a flow runs the leftover cleanup once at start (its report kept);
  /// one without a flow, a fixture's and the inert model run none.
  @Test func cleanupRunsOnlyWithTheFlow() async {
    let pipeline = FakeUpdateFlowPipeline()
    let live = UpdateModel(
      environment: UpdateEnvironment(
        scheduler: UpdateScheduler(
          transport: UpdateModelTestTransport([], fallback: UpdateModelTests.ok()),
          stateStore: InMemoryUpdateStateStore(), runningVersion: "0.2.0",
          clock: UpdateModelTestClock()),
        preferences: nil, runningVersion: "0.2.0", runningBuild: "2", openURL: { _ in },
        flow: UpdateFlowEnvironment(pipeline: pipeline, terminate: {})))
    #expect(live.flow.isAvailable)
    live.start()
    await live.flow.workEnded()
    #expect(pipeline.calls.withLock { $0.cleanup } == 1)
    #expect(live.flow.cleanupReport == UpdateCleanupReport(skipped: .missing))
    await live.stop()
    #expect(pipeline.calls.withLock { $0.cleanup } == 1)

    let withoutFlow = UpdateModel(
      environment: UpdateEnvironment(
        scheduler: UpdateScheduler(
          transport: UpdateModelTestTransport([], fallback: UpdateModelTests.ok()),
          stateStore: InMemoryUpdateStateStore(), runningVersion: "0.2.0",
          clock: UpdateModelTestClock()),
        preferences: nil, runningVersion: "0.2.0", runningBuild: "2", openURL: { _ in }))
    #expect(!withoutFlow.flow.isAvailable)
    withoutFlow.start()
    await withoutFlow.stop()
    #expect(!UpdateModel.inert().flow.isAvailable)
    #expect(!UpdateModel(fixture: UpdateFixture(status: nil, now: Date())).flow.isAvailable)
  } // End of func cleanupRunsOnlyWithTheFlow()
}

/// A fake pipeline: records every call, emits the scripted states, holds a prepare until
/// released or cancelled, and answers the scripted outcomes. Creates, downloads, swaps and
/// relaunches nothing.
final class FakeUpdateFlowPipeline: UpdateFlowPipeline, Sendable {
  /// What a prepare that is not cancelled returns.
  enum PrepareResult: Sendable {
    /// A stand-in prepared update.
    case prepared
    /// A failure.
    case failed(UpdatePipelineFailure)
  }

  /// The calls so far.
  struct Calls: Sendable {
    /// Eligibility reads.
    var eligibility = 0
    /// Prepares started.
    var prepare = 0
    /// Prepares that ended cancelled.
    var cancelledPrepares = 0
    /// Installs started.
    var install = 0
    /// Installs that returned.
    var installsEnded = 0
    /// Whether an install saw cancellation before its swap (and stopped there).
    var installCancelled = false
    /// Installs whose swap started (cancellation ignored from then on).
    var swapsStarted = 0
    /// The versions prepares were started for.
    var preparedVersions: [UpdateVersion] = []
    /// The versions installs were started for.
    var installedVersions: [UpdateVersion] = []
    /// Discards.
    var discard = 0
    /// Leftover cleanups.
    var cleanup = 0
  }

  /// The calls so far.
  let calls = OSAllocatedUnfairLock(initialState: Calls())
  /// The eligibility answer.
  let ineligibilityAnswer: UpdateIneligibility?
  /// The states a prepare emits first.
  let prepareStates: [UpdatePipelineState]
  /// Whether a prepare waits for `releasePrepare()` (or cancellation).
  let holdsPrepare: Bool
  /// What a prepare returns.
  let prepareResult: PrepareResult
  /// What an install returns.
  let installOutcome: UpdateInstallOutcome
  /// How long an install's swap takes (cancellation ignored).
  let installDelay: Duration
  /// Whether an install waits before its swap for `releaseInstall()` (or cancellation).
  let holdsInstall: Bool
  /// Whether the held install was released.
  private let installReleased = OSAllocatedUnfairLock(initialState: false)
  /// Whether the held prepare was released.
  private let released = OSAllocatedUnfairLock(initialState: false)
  /// The running prepare's state callback.
  private let onState = OSAllocatedUnfairLock<(@Sendable (UpdatePipelineState) -> Void)?>(
    initialState: nil)

  /// A fake from its script.
  init(
    ineligibility: UpdateIneligibility? = nil, prepareStates: [UpdatePipelineState] = [],
    holdsPrepare: Bool = false, prepareResult: PrepareResult = .prepared,
    installOutcome: UpdateInstallOutcome = .relaunchScheduled(relauncher: 4242),
    installDelay: Duration = .zero, holdsInstall: Bool = false
  ) {
    ineligibilityAnswer = ineligibility
    self.prepareStates = prepareStates
    self.holdsPrepare = holdsPrepare
    self.prepareResult = prepareResult
    self.installOutcome = installOutcome
    self.installDelay = installDelay
    self.holdsInstall = holdsInstall
  } // End of init(ineligibility:prepareStates:holdsPrepare:prepareResult:…)

  /// Lets a held install go on to its swap.
  func releaseInstall() { installReleased.withLock { $0 = true } }

  /// Lets a held prepare return.
  func releasePrepare() { released.withLock { $0 = true } }

  /// Emits `state` through the running prepare's callback.
  func step(_ state: UpdatePipelineState) {
    onState.withLock { $0 }?(state)
  }

  /// See `UpdateFlowPipeline`.
  func ineligibility() async -> UpdateIneligibility? {
    calls.withLock { $0.eligibility += 1 }
    return ineligibilityAnswer
  }

  /// See `UpdateFlowPipeline`.
  func prepare(
    _ release: UpdateRelease, onState: @escaping @Sendable (UpdatePipelineState) -> Void
  ) async -> UpdateFlowPrepareOutcome {
    calls.withLock {
      $0.prepare += 1
      $0.preparedVersions.append(release.version)
    }
    self.onState.withLock { $0 = onState }
    defer { self.onState.withLock { $0 = nil } }
    for state in prepareStates { onState(state) }
    while holdsPrepare, !released.withLock({ $0 }), !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(5))
    }
    if Task.isCancelled {
      calls.withLock { $0.cancelledPrepares += 1 }
      return .cancelled
    }
    switch prepareResult {
    case .prepared: return .prepared(UpdateFlowPrepared(release: release))
    case .failed(let failure): return .failed(failure)
    }
  } // End of func prepare(_:onState:)

  /// See `UpdateFlowPipeline`. Like the pipeline: a cancel before the swap stops there
  /// (`cancelled`, nothing swapped); the swap itself (`installDelay`) ignores cancellation.
  func install(
    _ prepared: UpdateFlowPrepared, onState: @escaping @Sendable (UpdatePipelineState) -> Void
  ) async -> UpdateInstallOutcome {
    calls.withLock {
      $0.install += 1
      $0.installedVersions.append(prepared.release.version)
    }
    onState(.installing)
    while holdsInstall, !installReleased.withLock({ $0 }), !Task.isCancelled {
      try? await Task.sleep(for: .milliseconds(5))
    }
    if Task.isCancelled {
      calls.withLock {
        $0.installCancelled = true
        $0.installsEnded += 1
      }
      return .failed(.cancelled, rollback: .notNeeded)
    }
    calls.withLock { $0.swapsStarted += 1 }
    if installDelay > .zero {
      let parts = installDelay.components
      let seconds = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
      await withCheckedContinuation { continuation in
        DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { continuation.resume() }
      }
    }
    calls.withLock { $0.installsEnded += 1 }
    return installOutcome
  } // End of func install(_:onState:)

  /// See `UpdateFlowPipeline`.
  func discard(_ prepared: UpdateFlowPrepared) async -> Bool {
    calls.withLock { $0.discard += 1 }
    return true
  }

  /// See `UpdateFlowPipeline`.
  func cleanLeftovers() async -> UpdateCleanupReport {
    calls.withLock { $0.cleanup += 1 }
    return UpdateCleanupReport(skipped: .missing)
  }
}
