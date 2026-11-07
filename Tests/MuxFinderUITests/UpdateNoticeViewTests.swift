import AppKit
import Foundation
import SwiftUI
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The update notice in the app (PLAN.md D39 *The update views (I-13c2b)*): each button calls
/// its flow method through `UpdateModel.perform(_:)` over a fake pipeline, Download, What's new
/// and Release page go through the injected opener, VoiceOver hears a failure and the ask when
/// they appear, the popover gallery's thirteen synthetic states, and the notice's fit in the
/// popover (compact, wrapping, never wider than the popover, the host list giving up the
/// height under the panel's limit). Nothing here downloads, swaps, relaunches, sends a
/// request, opens a URL or shows a window: every effect is a fake's record, and views are
/// measured in hosting views that are never put in a window.
@MainActor
@Suite("Update notice views", .serialized)
struct UpdateNoticeViewTests {
  /// How far two measured heights may differ, in points (layout rounding).
  static let tolerance: CGFloat = 0.5

  /// A live model with its fakes.
  struct Harness {
    /// The model.
    let model: UpdateModel
    /// The fake pipeline.
    let pipeline: FakeUpdateFlowPipeline
    /// The URLs the opener was handed.
    let opened: OSAllocatedUnfairLock<[URL]>
    /// What VoiceOver was told.
    let announced: OSAllocatedUnfairLock<[String]>
    /// The terminator's calls.
    let terminated: OSAllocatedUnfairLock<Int>
  }

  /// A started model whose kept release 0.3.0 (with its asset) shows in an open popover, its
  /// offer read, over `pipeline` (automatic checks off: nothing is sent; a manual check gets
  /// `answer`).
  static func harness(
    _ pipeline: FakeUpdateFlowPipeline, unsaved: UpdateUnsavedWork = .none,
    answer: UpdateCheckResponse = UpdateModelTests.ok()
  ) async -> Harness {
    let opened = OSAllocatedUnfairLock(initialState: [URL]())
    let announced = OSAllocatedUnfairLock(initialState: [String]())
    let terminated = OSAllocatedUnfairLock(initialState: 0)
    let scheduler = UpdateScheduler(
      transport: UpdateModelTestTransport([], fallback: answer),
      stateStore: InMemoryUpdateStateStore(
        UpdateState(keptRelease: UpdateFlowTests.release("0.3.0"))),
      runningVersion: "0.2.0", clock: UpdateModelTestClock())
    let model = UpdateModel(
      environment: UpdateEnvironment(
        scheduler: scheduler,
        preferences: InMemoryPreferencesStore(Preferences(checkForUpdatesAutomatically: false)),
        runningVersion: "0.2.0", runningBuild: "2",
        openURL: { url in opened.withLock { $0.append(url) } },
        flow: UpdateFlowEnvironment(
          pipeline: pipeline, terminate: { terminated.withLock { $0 += 1 } },
          quitBound: .milliseconds(500))))
    model.announce = { text in announced.withLock { $0.append(text) } }
    model.flow.unsavedWork = { unsaved }
    model.start()
    #expect(await Self.wait { model.notice != nil })
    model.popoverVisibilityChanged(true)
    await model.flow.workEnded()
    return Harness(
      model: model, pipeline: pipeline, opened: opened, announced: announced,
      terminated: terminated)
  } // End of static func harness(_:unsaved:answer:)

  /// Waits until `condition` holds (bounded).
  static func wait(_ condition: @MainActor () async -> Bool) async -> Bool {
    await UITestSupport.waitUntil(condition)
  }

  /// The actions of the buttons `model`'s notice shows now.
  static func actions(_ model: UpdateModel) -> [UpdateNoticeAction] {
    model.noticeContent?.buttons.map(\.action) ?? []
  }

  /// The release page of 0.3.0.
  static let page = UpdateFlowTests.release("0.3.0").pageURL

  // MARK: - The buttons

  /// Update, then Cancel while downloading (the bar at 40 %), back to Update; What's new
  /// through the opener.
  @Test func updateAndCancelThroughTheButtons() async {
    let pipeline = FakeUpdateFlowPipeline(
      prepareStates: [.downloading(bytes: 40, total: 100)], holdsPrepare: true)
    let harness = await Self.harness(pipeline)
    let model = harness.model
    #expect(Self.actions(model) == [.update])
    #expect(model.noticeContent?.button(.update)?.isEnabled == true)
    model.perform(.update)
    #expect(await Self.wait { model.flow.state == .downloading(bytes: 40, total: 100) })
    #expect(Self.actions(model) == [.cancel])
    #expect(model.noticeContent?.lines.map(\.text) == ["Downloading… 40%"])
    #expect(model.noticeContent?.progress?.accessibilityValue == "40%")
    model.perform(.cancel)
    await model.flow.workEnded()
    #expect(model.flow.state == .idle)
    #expect(pipeline.calls.withLock { $0.cancelledPrepares } == 1)
    #expect(Self.actions(model) == [.update])
    model.perform(.whatsNew)
    #expect(harness.opened.withLock { $0 } == [Self.page])
    #expect(harness.announced.withLock { $0 }.isEmpty)
    await model.stop()
  } // End of func updateAndCancelThroughTheButtons()

  /// A failure: its line and Release page, which opens the page through the opener; Update
  /// again runs a second prepare; VoiceOver hears the failure once when it appears, and again
  /// after the second one.
  @Test func aFailureWithReleasePageAndUpdateAgain() async {
    let pipeline = FakeUpdateFlowPipeline(
      prepareResult: .failed(.verification(.download(.digestMismatch))))
    let harness = await Self.harness(pipeline)
    let model = harness.model
    model.perform(.update)
    await model.flow.workEnded()
    let phrase = UpdateFlowFailure.prepare(.verification(.download(.digestMismatch))).phrase
    #expect(model.noticeContent?.lines.map(\.text) == [phrase])
    #expect(Self.actions(model) == [.update, .releasePage])
    #expect(await Self.wait { harness.announced.withLock { $0 } == [phrase] })
    model.perform(.releasePage)
    #expect(harness.opened.withLock { $0 } == [Self.page])
    model.perform(.update)
    await model.flow.workEnded()
    #expect(pipeline.calls.withLock { $0.prepare } == 2)
    #expect(await Self.wait { harness.announced.withLock { $0 } == [phrase, phrase] })
    await model.stop()
  } // End of func aFailureWithReleasePageAndUpdateAgain()

  /// Not eligible: Download with its reason line, which opens the release page; Update is
  /// never offered and nothing is prepared.
  @Test func downloadOpensTheReleasePage() async {
    let harness = await Self.harness(FakeUpdateFlowPipeline(ineligibility: .notDeveloperID))
    let model = harness.model
    #expect(Self.actions(model) == [.download])
    #expect(
      model.noticeContent?.lines.map(\.text)
        == ["Can't update in place: " + UpdateIneligibility.notDeveloperID.reason])
    model.perform(.download)
    #expect(harness.opened.withLock { $0 } == [Self.page])
    model.perform(.update)
    #expect(harness.pipeline.calls.withLock { $0.prepare } == 0)
    await model.stop()
  } // End of func downloadOpensTheReleasePage()

  /// The ask through its buttons: announced when it appears; Not now (Install and relaunch);
  /// Install and relaunch asks again (announced again); Quit and install installs, the notice
  /// says "Relaunching…" with no What's new, and the terminator runs once.
  @Test func theAskThroughTheButtons() async {
    let pipeline = FakeUpdateFlowPipeline()
    let work = UpdateUnsavedWork(newSessionDraft: true, settingsEdits: true)
    let harness = await Self.harness(pipeline, unsaved: work)
    let model = harness.model
    model.perform(.update)
    await model.flow.workEnded()
    #expect(model.flow.state == .asking(work))
    #expect(Self.actions(model) == [.quitAndInstall, .notNow])
    let ask = UpdateNoticeContent.announcement(
      state: .asking(work), version: UpdateFlowTests.release("0.3.0").version)
    #expect(ask?.hasPrefix("muxFinder 0.3.0 is ready to install. Quitting to install") == true)
    #expect(await Self.wait { harness.announced.withLock { $0 } == [ask].compactMap { $0 } })
    model.perform(.notNow)
    #expect(model.flow.state == .deferred)
    #expect(Self.actions(model) == [.installAndRelaunch])
    #expect(
      model.noticeContent?.lines.map(\.text) == ["muxFinder 0.3.0 is ready to install"])
    try? await Task.sleep(for: .milliseconds(100))
    model.perform(.installAndRelaunch)
    #expect(model.flow.state == .asking(work))
    #expect(await Self.wait { harness.announced.withLock { $0 }.count == 2 })
    model.perform(.quitAndInstall)
    await model.flow.workEnded()
    #expect(model.flow.state == .relaunchScheduled)
    #expect(model.noticeContent?.title == "Relaunching…")
    #expect(model.noticeContent?.whatsNew == nil)
    #expect(Self.actions(model).isEmpty)
    #expect(await Self.wait { harness.terminated.withLock { $0 } == 1 })
    #expect(pipeline.calls.withLock { $0.install } == 1)
    await model.stop()
  } // End of func theAskThroughTheButtons()

  /// A fixture's model and the inert one run nothing whatever is pressed, and open nothing.
  @Test func fixturesRunNothing() {
    for fixture in UpdateFixtures.flowStates {
      let model = AppModel(fixture: fixture).update
      for action in UpdateNoticeAction.allCases { model.perform(action) }
      #expect(model.flow.state == .idle)
      #expect(model.flow.offer == nil)
      #expect(!model.flow.isAvailable)
    }
    let inert = UpdateModel.inert()
    for action in UpdateNoticeAction.allCases { inert.perform(action) }
    #expect(inert.noticeContent == nil)
  } // End of func fixturesRunNothing()

  /// `AppModel` hands the update model its own announcer.
  @Test func appModelPassesItsAnnouncer() {
    let model = AppModel(environment: AppEnvironment.placementDiagnostic())
    let said = OSAllocatedUnfairLock(initialState: [String]())
    model.announce = { text in said.withLock { $0.append(text) } }
    model.update.announce?("Couldn't update: no connection")
    #expect(said.withLock { $0 } == ["Couldn't update: no connection"])
  }

  // MARK: - The gallery

  /// The popover gallery's thirteen flow states, from synthetic fixtures (no pipeline): each
  /// renders its state through the mapping, with I-13c1's notice before them.
  @Test func galleryStates() {
    let states = UpdateFixtures.flowStates
    #expect(states.count == 13)
    #expect(Set(states.map(\.id)).count == 13)
    #expect(UpdateFixtures.popover == [UpdateFixtures.popoverNotice] + states)
    let expected: [String: [UpdateNoticeAction]] = [
      "update-reading": [], "update-offer": [.update], "update-download": [.download],
      "update-downloading": [.cancel], "update-downloading-unknown": [.cancel],
      "update-checking": [.cancel], "update-ask-one": [.quitAndInstall, .notNow],
      "update-ask-two": [.quitAndInstall, .notNow], "update-deferred": [.installAndRelaunch],
      "update-installing": [], "update-relaunching": [],
      "update-failed-update": [.update, .releasePage],
      "update-failed-download": [.download, .releasePage],
    ]
    for fixture in states {
      let content = AppModel(fixture: fixture).update.noticeContent
      #expect(content != nil, "\(fixture.id)")
      #expect(content?.buttons.map(\.action) == expected[fixture.id], "\(fixture.id)")
      #expect(content?.buttons.allSatisfy(\.isEnabled) == true, "\(fixture.id)")
    }
    #expect(
      AppModel(fixture: UpdateFixtures.flowDownloading).update.noticeContent?.lines.first?.text
        == "Downloading… 40%")
    #expect(
      AppModel(fixture: UpdateFixtures.flowDownloadingUnknown).update.noticeContent?.progress
        == nil)
    #expect(AppModel(fixture: UpdateFixtures.popoverNotice).update.noticeContent?.buttons == [])
  } // End of func galleryStates()

  // MARK: - Fit

  /// The notice's size at the popover's width.
  static func noticeSize(_ content: UpdateNoticeContent) -> CGSize {
    let controller = NSHostingController(
      rootView: UpdateNoticeView(content: content, perform: { _ in }))
    controller.view.layoutSubtreeIfNeeded()
    return controller.sizeThatFits(
      in: CGSize(width: PopoverView.width, height: .greatestFiniteMagnitude))
  }

  /// Every gallery state's notice is compact and never wider than the popover (its buttons at
  /// their full width); a long failure and the two-item ask wrap (taller, no wider).
  @Test func theNoticeFitsThePopoverWidth() {
    var heights: [String: CGFloat] = [:]
    for fixture in UpdateFixtures.flowStates {
      guard let content = AppModel(fixture: fixture).update.noticeContent else { continue }
      let size = Self.noticeSize(content)
      heights[fixture.id] = size.height
      #expect(size.width <= PopoverView.width + Self.tolerance, "\(fixture.id): \(size)")
      #expect(size.height <= 130, "\(fixture.id): \(size)")
    }
    let release = UpdateFlowTests.release("0.3.0")
    let long = UpdateFlowFailure(
      reason: Array(repeating: "the download changed while it was being checked", count: 3)
        .joined(separator: ", and "), code: "test")
    let longSize = Self.noticeSize(
      UpdateNoticeContent.make(
        release: release, offer: .update, state: .failed(long), canUpdate: true))
    #expect(longSize.width <= PopoverView.width + Self.tolerance, "\(longSize)")
    #expect(longSize.height > (heights["update-failed-update"] ?? .infinity), "\(longSize)")
    #expect(
      (heights["update-ask-two"] ?? 0) > (heights["update-ask-one"] ?? .infinity),
      "the two-item line wraps")
  } // End of func theNoticeFitsThePopoverWidth()

  /// Under the panel's height limit (D30) each gallery state's popover lays itself out at the
  /// limit: the host list gives up the height, the notice and the footer keep theirs.
  @Test func eachStateFitsUnderThePanelLimit() {
    for fixture in UpdateFixtures.flowStates {
      let model = AppModel(fixture: fixture)
      let host = NSHostingView(
        rootView: PopoverPanelRoot(model: model, maximumHeight: nil, onSizeChange: {}))
      host.layoutSubtreeIfNeeded()
      let natural = host.fittingSize.height
      let limit = natural - 60
      host.rootView.maximumHeight = limit
      #expect(
        abs(host.fittingSize.height - limit) <= Self.tolerance,
        "\(fixture.id): natural \(natural), limit \(limit)")
    } // End of loop over the gallery states
  } // End of func eachStateFitsUnderThePanelLimit()
}
