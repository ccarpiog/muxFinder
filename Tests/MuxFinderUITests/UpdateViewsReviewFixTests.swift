import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The two should-fix findings of `docs/reviews/phase-I-13c2b.md` (PLAN.md D39 *The update
/// views (I-13c2b)*): VoiceOver hears a failure or the ask only while the notice shows (one
/// that appears while it is hidden is said once when it shows, the latest only, or dropped if
/// the state moved on), and What's new opens the release the notice shows, also after Not now
/// when a later check no longer offers a newer release. Over `UpdateNoticeViewTests`' harness:
/// a fake pipeline and a recording opener and announcer; nothing is downloaded, sent or opened.
@MainActor
@Suite("Update views review fixes", .serialized)
struct UpdateViewsReviewFixTests {
  /// How long the flow's state observer is given to run after a change (it hops to the main
  /// actor in a task of its own).
  static let settle = Duration.milliseconds(200)

  /// Waits until `condition` holds (bounded).
  static func wait(_ condition: @MainActor () async -> Bool) async -> Bool {
    await UITestSupport.waitUntil(condition)
  }

  /// Start an update, then hide the notice (the popover closed, or the switcher opened in its
  /// place) before the preparation ends: its failure is not said while hidden, is said once
  /// when the popover's main layout shows, and never again on later showings.
  @Test func aFailureWhileHiddenIsAnnouncedOnceTheNoticeShows() async {
    let failure = UpdatePipelineFailure.verification(.download(.digestMismatch))
    let pipeline = FakeUpdateFlowPipeline(holdsPrepare: true, prepareResult: .failed(failure))
    let harness = await UpdateNoticeViewTests.harness(pipeline)
    let model = harness.model
    let announced = { harness.announced.withLock { $0 } }
    model.perform(.update)
    #expect(await Self.wait { model.flow.state.isPreparing })
    model.popoverVisibilityChanged(false)
    pipeline.releasePrepare()
    await model.flow.workEnded()
    let phrase = UpdateFlowFailure.prepare(failure).phrase
    #expect(model.flow.state == .failed(.prepare(failure)))
    try? await Task.sleep(for: Self.settle)
    #expect(announced().isEmpty, "said while the notice was hidden")
    model.popoverVisibilityChanged(true)
    #expect(announced() == [phrase])
    model.popoverVisibilityChanged(false)
    model.popoverVisibilityChanged(true)
    try? await Task.sleep(for: Self.settle)
    #expect(announced() == [phrase], "said again")
    await model.stop()
  } // End of func aFailureWhileHiddenIsAnnouncedOnceTheNoticeShows()

  /// The ask appearing while the notice is hidden: dropped once the state moved on (Not now)
  /// before the notice shows; asked again while still hidden, the latest ask is said once
  /// when the notice shows, never again.
  @Test func anAskWhileHiddenIsDroppedOrSaidOnce() async {
    let work = UpdateUnsavedWork(newSessionDraft: true)
    let pipeline = FakeUpdateFlowPipeline(holdsPrepare: true)
    let harness = await UpdateNoticeViewTests.harness(pipeline, unsaved: work)
    let model = harness.model
    let announced = { harness.announced.withLock { $0 } }
    model.perform(.update)
    #expect(await Self.wait { model.flow.state.isPreparing })
    model.popoverVisibilityChanged(false)
    pipeline.releasePrepare()
    await model.flow.workEnded()
    #expect(model.flow.state == .asking(work))
    try? await Task.sleep(for: Self.settle)
    #expect(announced().isEmpty, "the ask said while the notice was hidden")
    model.perform(.notNow)
    try? await Task.sleep(for: Self.settle)
    model.popoverVisibilityChanged(true)
    #expect(announced().isEmpty, "the ask said after the state moved on")
    model.popoverVisibilityChanged(false)
    model.perform(.installAndRelaunch)
    #expect(model.flow.state == .asking(work))
    try? await Task.sleep(for: Self.settle)
    #expect(announced().isEmpty, "the second ask said while the notice was hidden")
    model.popoverVisibilityChanged(true)
    let ask = UpdateNoticeContent.announcement(
      state: .asking(work), version: UpdateFlowTests.release("0.3.0").version)
    #expect(announced() == [ask].compactMap { $0 })
    model.popoverVisibilityChanged(false)
    model.popoverVisibilityChanged(true)
    try? await Task.sleep(for: Self.settle)
    #expect(announced() == [ask].compactMap { $0 }, "said again")
    await model.stop()
  } // End of func anAskWhileHiddenIsDroppedOrSaidOnce()

  /// Not now, then a check that no longer offers a newer release (0.2.0 is the latest): the
  /// notice stays for the prepared 0.3.0, and What's new and Release page open its page
  /// through the injected opener.
  @Test func whatsNewOpensThePreparedReleaseAfterTheOfferIsGone() async {
    let work = UpdateUnsavedWork(settingsEdits: true)
    let harness = await UpdateNoticeViewTests.harness(
      FakeUpdateFlowPipeline(), unsaved: work, answer: UpdateModelTests.ok("v0.2.0"))
    let model = harness.model
    model.perform(.update)
    await model.flow.workEnded()
    #expect(model.flow.state == .asking(work))
    model.perform(.notNow)
    #expect(model.flow.state == .deferred)
    model.checkNow()
    #expect(await Self.wait { model.notice == nil && !model.isChecking })
    #expect(model.flow.preparedRelease?.version == UpdateVersion("0.3.0"))
    let content = model.noticeContent
    #expect(content?.title == "muxFinder 0.3.0 is available")
    #expect(content?.whatsNew?.accessibilityLabel == "What's new in muxFinder 0.3.0")
    #expect(content?.buttons.map(\.action) == [.installAndRelaunch])
    model.perform(.whatsNew)
    #expect(harness.opened.withLock { $0 } == [UpdateNoticeViewTests.page])
    model.openReleasePage()
    #expect(
      harness.opened.withLock { $0 } == [UpdateNoticeViewTests.page, UpdateNoticeViewTests.page])
    await model.stop()
  } // End of func whatsNewOpensThePreparedReleaseAfterTheOfferIsGone()
}
