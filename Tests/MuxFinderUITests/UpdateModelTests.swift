import AppKit
import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The update check in the app (PLAN.md D39 *The notice (I-13c1)*): the mode gate, the
/// scheduler's wiring through `UpdateModel` (start, wake, toggle, manual check, stop) over an
/// injected transport, state store, preferences store and clock, the notice and the dot, the
/// seen version, "What's new"'s opener, the status line's phrases and the dot's drawing.
/// Nothing here sends a request (`UpdateModelTestTransport` answers every one), reads or
/// writes `update-state.json` or `preferences.json`, or opens a URL.
@MainActor
@Suite("Update model")
struct UpdateModelTests {
  /// The answer a check gets: a 200 offering `tag`, with no asset.
  static func ok(_ tag: String = "v0.3.0") -> UpdateCheckResponse {
    let body: [String: Any] = [
      "tag_name": tag, "html_url": "https://github.com/ccarpiog/muxFinder/releases/tag/\(tag)",
      "draft": false, "prerelease": false, "assets": [],
    ]
    return .body(try! JSONSerialization.data(withJSONObject: body), etag: "\"e1\"")
  }

  /// A synthetic release.
  static func release(_ version: String) -> UpdateRelease {
    UpdateFixtures.release(version)!
  }

  /// A version.
  static func version(_ text: String) -> UpdateVersion { UpdateVersion(text)! }

  /// A live model with its fakes.
  struct Harness {
    /// The model.
    let model: UpdateModel
    /// The scheduler.
    let scheduler: UpdateScheduler
    /// The transport.
    let transport: UpdateModelTestTransport
    /// The state store.
    let store: InMemoryUpdateStateStore
    /// The preferences store.
    let preferences: InMemoryPreferencesStore
    /// The clock.
    let clock: UpdateModelTestClock
    /// The wake notifications' centre.
    let center: NotificationCenter
    /// The URLs "What's new" opened.
    let opened: OSAllocatedUnfairLock<[URL]>
  }

  /// A harness with automatic checks `on`, the state `state`, answering `script` then `ok()`,
  /// for an app running `runningVersion`.
  static func harness(
    on: Bool = true, state: UpdateState = UpdateState(), script: [UpdateCheckResponse] = [],
    runningVersion: String = "0.2.0"
  ) -> Harness {
    let transport = UpdateModelTestTransport(script, fallback: ok())
    let store = InMemoryUpdateStateStore(state)
    let clock = UpdateModelTestClock()
    let preferences = InMemoryPreferencesStore(Preferences(checkForUpdatesAutomatically: on))
    let scheduler = UpdateScheduler(
      transport: transport, stateStore: store, runningVersion: runningVersion, clock: clock)
    let center = NotificationCenter()
    let opened = OSAllocatedUnfairLock(initialState: [URL]())
    let model = UpdateModel(
      environment: UpdateEnvironment(
        scheduler: scheduler, preferences: preferences, runningVersion: runningVersion,
        runningBuild: "2", openURL: { url in opened.withLock { $0.append(url) } },
        wakeNotifications: center, now: { clock.date() }))
    return Harness(
      model: model, scheduler: scheduler, transport: transport, store: store,
      preferences: preferences, clock: clock, center: center, opened: opened)
  } // End of static func harness(on:state:script:runningVersion:)

  /// Waits on the main actor until `condition` holds.
  static func wait(_ condition: @MainActor () async -> Bool) async -> Bool {
    await UITestSupport.waitUntil(condition)
  }

  // MARK: - The mode gate

  /// Only the normal launch (alone or with `--appearance`) creates the update machinery; every
  /// preview, gallery, key view loop, report, self-test, removal and unusable argument list
  /// creates none.
  @Test func onlyTheNormalLaunchCreatesUpdateMachinery() {
    let normal: [[String]] = [[], ["--appearance", "dark"], ["-psn_0_1"]]
    for arguments in normal {
      #expect(AppLaunchOptions(arguments: arguments).createsUpdateMachinery, "\(arguments)")
    }
    var others: [[String]] = [
      ["--preview-fixtures"], ["--preview-fixtures", "--preview-snapshot", "/tmp/x.png"],
      ["--preview-fixtures", "--preview-key-view-loop", "popover"],
      ["--preview-fixtures", "--preview-key-view-loop", "switcher"],
      ["--report-menu-bar-item"], ["--report-popover-placement"],
      ["--report-login-item-status"], ["--report-hotkey-registration"],
      ["--report-update-eligibility"], ["--selftest", "attach-local"],
      ["--selftest", "new-session-local"], ["--selftest", "attach-local", "--selftest-keep"],
      ["--remove-persistent-profiles"], ["--remove-persistent-profiles", "--dry-run"],
      ["--selftest"], ["--selftest", "unknown"], ["--selftest-keep"], ["--dry-run"],
      ["--preview-key-view-loop", "popover"], ["--report-menu-bar-item", "--preview-fixtures"],
    ]
    for gallery in AppLaunchOptions.PreviewGallery.allCases {
      others.append(["--preview-fixtures", "--preview-gallery", gallery.rawValue])
    }
    for arguments in others {
      let options = AppLaunchOptions(arguments: arguments)
      #expect(!options.createsUpdateMachinery, "\(arguments)")
      #expect(!AppLaunchOptions.createsUpdateMachinery(options), "\(arguments)")
    }
  } // End of func onlyTheNormalLaunchCreatesUpdateMachinery()

  /// Every environment but normal mode's has no update environment, so its model is inert:
  /// no notice, no dot, no Settings section, and starting it runs nothing.
  @Test func otherModesHaveAnInertModel() async {
    let environment = AppEnvironment.placementDiagnostic()
    #expect(environment.update == nil)
    let model = AppModel(environment: environment)
    #expect(!model.update.isAvailable)
    #expect(!model.settings.update.isAvailable)
    model.update.start()
    #expect(model.update.notice == nil)
    #expect(!model.update.showsDot)
    #expect(model.update.statusItemLabel == "muxFinder")
    let fixture = AppModel(fixture: PreviewFixtures.overview)
    #expect(!fixture.update.isAvailable)
  }

  // MARK: - The scheduler's wiring

  /// With the toggle on: one request 5 s after start (none sooner), then none sooner than
  /// 24 h after that success; `stop()` ends it.
  @Test func toggleOnChecksFiveSecondsAfterStartThenDaily() async {
    let harness = Self.harness()
    harness.model.start()
    #expect(await Self.wait { harness.clock.waiting == 1 })
    harness.clock.advance(by: .milliseconds(4999))
    #expect(harness.transport.calls == 0)
    harness.clock.advance(by: .milliseconds(1))
    #expect(await Self.wait { harness.transport.calls == 1 && harness.clock.waiting == 1 })
    #expect(await Self.wait { harness.model.notice?.version == Self.version("0.3.0") })
    harness.clock.advance(by: .seconds(86_399))
    #expect(harness.transport.calls == 1)
    harness.clock.advance(by: .seconds(1))
    #expect(await Self.wait { harness.transport.calls == 2 })
    await harness.model.stop()
    harness.clock.advance(by: .seconds(3 * 86_400))
    #expect(harness.transport.calls == 2)
  } // End of func toggleOnChecksFiveSecondsAfterStartThenDaily()

  /// With the toggle off: nothing for two days; "Check for updates…" sends one request, the
  /// button disabled while it runs.
  @Test func toggleOffSendsNothingUntilTheManualCheck() async {
    let harness = Self.harness(on: false)
    harness.model.start()
    #expect(await Self.wait { await harness.scheduler.status.lastCheck == nil })
    try? await Task.sleep(for: .milliseconds(50))
    harness.clock.advance(by: .seconds(2 * 86_400))
    try? await Task.sleep(for: .milliseconds(50))
    #expect(harness.transport.calls == 0)
    #expect(!harness.model.automaticChecks)
    harness.transport.hold()
    harness.model.checkNow()
    #expect(harness.model.isChecking)
    #expect(harness.model.statusLines.first == "Checking for updates…")
    #expect(await Self.wait { harness.transport.calls == 1 })
    harness.transport.releaseHeld()
    #expect(await Self.wait { !harness.model.isChecking })
    #expect(harness.transport.calls == 1)
    #expect(harness.model.statusLines.first == "muxFinder 0.3.0 is available")
    #expect(harness.model.statusLines.last == "Last checked just now")
    await harness.model.stop()
  } // End of func toggleOffSendsNothingUntilTheManualCheck()

  /// The toggle saves through the preferences store and then tells the scheduler: on arms the
  /// first check; a refused save puts it back and says why.
  @Test func toggleSavesAndTellsTheScheduler() async {
    let harness = Self.harness(on: false)
    harness.model.start()
    #expect(await Self.wait { await harness.scheduler.status.lastCheck == nil })
    try? await Task.sleep(for: .milliseconds(50))
    harness.model.setAutomaticChecks(true)
    await harness.model.workEnded()
    #expect(await harness.preferences.preferences.checkForUpdatesAutomatically)
    #expect(await Self.wait { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await Self.wait { harness.transport.calls == 1 })
    await harness.preferences.setFailure(.directoryMissing)
    harness.model.setAutomaticChecks(false)
    await harness.model.workEnded()
    #expect(harness.model.automaticChecks)
    #expect(harness.model.toggleProblem?.hasPrefix("Couldn't save the setting") == true)
    await harness.model.stop()
  } // End of func toggleSavesAndTellsTheScheduler()

  /// Toggle changes made while the setting is still being read win over the (stale) value read:
  /// once the read returns, the toggle, the saved setting and the scheduler's automatic checks
  /// all hold the last change (turned off over a saved on; off then on over a saved off, the
  /// first check 5 s later); a change whose save is refused puts the toggle back to the value
  /// read, the scheduler's too.
  @Test func toggleChangedWhileTheSettingIsReadWins() async {
    let cases: [(saved: Bool, changes: [Bool], refused: Bool, expected: Bool)] = [
      (true, [false], false, false), (false, [false, true], false, true),
      (true, [false], true, true),
    ]
    for entry in cases {
      let backing = InMemoryPreferencesStore(
        Preferences(checkForUpdatesAutomatically: entry.saved))
      if entry.refused { await backing.setFailure(.directoryMissing) }
      let preferences = SuspendedLoadPreferencesStore(backing)
      let transport = UpdateModelTestTransport([], fallback: Self.ok())
      let clock = UpdateModelTestClock()
      let scheduler = UpdateScheduler(
        transport: transport, stateStore: InMemoryUpdateStateStore(), runningVersion: "0.2.0",
        clock: clock)
      let model = UpdateModel(
        environment: UpdateEnvironment(
          scheduler: scheduler, preferences: preferences, runningVersion: "0.2.0",
          runningBuild: "2", openURL: { _ in }, now: { clock.date() }))
      model.start()
      #expect(await Self.wait { preferences.loadCalls == 1 }, "\(entry)")
      for change in entry.changes { model.setAutomaticChecks(change) }
      #expect(model.automaticChecks == entry.changes.last, "\(entry)")
      preferences.releaseLoad()
      await model.workEnded()
      #expect(model.automaticChecks == entry.expected, "\(entry)")
      #expect((model.toggleProblem != nil) == entry.refused, "\(entry)")
      #expect(
        await backing.preferences.checkForUpdatesAutomatically
          == (entry.refused ? entry.saved : entry.expected), "\(entry)")
      #expect(await scheduler.lifecycle == .running, "\(entry)")
      #expect(await scheduler.automaticChecks == entry.expected, "\(entry)")
      #expect((await scheduler.nextAutomaticCheck() != nil) == entry.expected, "\(entry)")
      if entry.expected {
        #expect(await Self.wait { clock.waiting == 1 }, "\(entry)")
        clock.advance(by: .seconds(5))
        #expect(await Self.wait { transport.calls == 1 }, "\(entry)")
      }
      await model.stop()
    } // End of loop over the cases
  } // End of func toggleChangedWhileTheSettingIsReadWins()

  /// A wake works the schedule out again: a check that came due while the wall clock moved
  /// without the sleep noticing runs at the wake.
  @Test func wakeRunsADueCheck() async {
    let harness = Self.harness()
    harness.model.start()
    #expect(await Self.wait { harness.clock.waiting == 1 })
    harness.clock.advance(by: .seconds(5))
    #expect(await Self.wait { harness.transport.calls == 1 && harness.clock.waiting == 1 })
    harness.clock.shiftWallClock(by: 25 * 3600)
    try? await Task.sleep(for: .milliseconds(50))
    #expect(harness.transport.calls == 1)
    harness.center.post(name: NSWorkspace.didWakeNotification, object: nil)
    #expect(await Self.wait { harness.transport.calls == 2 })
    await harness.model.stop()
  }

  // MARK: - The notice and the dot

  /// The notice shows only for a newer release: never for an equal or older one, nor with a
  /// running version that cannot be parsed.
  @Test func noticeOnlyForANewerRelease() {
    let newer = Self.release("0.3.0")
    #expect(UpdateNotice.release(offer: .newer(newer), runningVersion: "0.2.0") == newer)
    #expect(UpdateNotice.release(offer: .newer(newer), runningVersion: "0.3.0") == nil)
    #expect(UpdateNotice.release(offer: .newer(newer), runningVersion: "0.4.0") == nil)
    #expect(UpdateNotice.release(offer: .newer(newer), runningVersion: "dev") == nil)
    #expect(UpdateNotice.release(offer: .newer(newer), runningVersion: nil) == nil)
    #expect(
      UpdateNotice.release(offer: .upToDate(latest: Self.version("0.3.0")), runningVersion: "0.2.0")
        == nil)
    #expect(
      UpdateNotice.release(offer: .nothingOffered(.unrecognizedTag), runningVersion: "0.2.0")
        == nil)
    #expect(UpdateNotice.release(offer: nil, runningVersion: "0.2.0") == nil)
  }

  /// Through the scheduler: a kept release equal to, older than or newer than the running app,
  /// and an unusable tag in the answer.
  @Test func noticeFollowsTheKeptRelease() async {
    let cases: [(version: String, tag: String, shows: Bool)] = [
      ("0.3.0", "v0.3.0", false), ("0.4.0", "v0.3.0", false), ("0.2.0", "v0.3.0", true),
      ("0.2.0", "v0.3", false), ("0.2.0", "0.3.0", false),
    ]
    for entry in cases {
      let harness = Self.harness(
        on: false, script: [Self.ok(entry.tag)], runningVersion: entry.version)
      harness.model.start()
      #expect(await Self.wait { await harness.scheduler.status.lastCheck == nil })
      try? await Task.sleep(for: .milliseconds(20))
      harness.model.checkNow()
      #expect(await Self.wait { !harness.model.isChecking && harness.transport.calls == 1 })
      #expect((harness.model.notice != nil) == entry.shows, "\(entry)")
      #expect(harness.model.showsDot == entry.shows, "\(entry)")
      await harness.model.stop()
    }
  } // End of func noticeFollowsTheKeptRelease()

  /// The dot shows while the notice's version is greater than the seen one (or none is seen),
  /// with the matching label.
  @Test func dotRule() {
    let newer = Self.release("0.3.0")
    #expect(UpdateNotice.showsDot(release: newer, seen: nil))
    #expect(UpdateNotice.showsDot(release: newer, seen: Self.version("0.2.9")))
    #expect(!UpdateNotice.showsDot(release: newer, seen: Self.version("0.3.0")))
    #expect(!UpdateNotice.showsDot(release: newer, seen: Self.version("0.4.0")))
    #expect(!UpdateNotice.showsDot(release: nil, seen: nil))
    #expect(UpdateNotice.statusItemLabel(showsDot: true) == "muxFinder, update available")
    #expect(UpdateNotice.statusItemLabel(showsDot: false) == "muxFinder")
  }

  /// A notice kept from an earlier check shows at launch with the dot; once the popover shows
  /// it the version is recorded as seen through the scheduler and the dot clears (the notice
  /// stays); a newer release brings the dot back.
  @Test func dotClearsOnceShownAndReturnsForANewerVersion() async {
    let kept = UpdateState(
      lastSuccessfulCheck: UpdateModelTestClock.baseDate, keptRelease: Self.release("0.3.0"))
    let harness = Self.harness(on: false, state: kept, script: [Self.ok("v0.4.0")])
    harness.model.start()
    #expect(await Self.wait { harness.model.showsDot })
    #expect(harness.model.statusItemLabel == "muxFinder, update available")
    harness.model.popoverVisibilityChanged(true)
    #expect(await Self.wait { !harness.model.showsDot })
    #expect(await harness.store.state.noticeSeenVersion == Self.version("0.3.0"))
    #expect(harness.model.notice?.version == Self.version("0.3.0"))
    #expect(harness.model.statusItemLabel == "muxFinder")
    harness.model.popoverVisibilityChanged(false)
    harness.model.checkNow()
    #expect(await Self.wait { harness.model.notice?.version == Self.version("0.4.0") })
    #expect(harness.model.showsDot)
    harness.model.popoverVisibilityChanged(true)
    #expect(await Self.wait { !harness.model.showsDot })
    #expect(await harness.store.state.noticeSeenVersion == Self.version("0.4.0"))
    await harness.model.stop()
  } // End of func dotClearsOnceShownAndReturnsForANewerVersion()

  /// `AppModel` starts the update model with itself, hands it the popover's visibility (the
  /// notice shown marks it seen) and stops it at shutdown.
  @Test func appModelWiresTheUpdateModel() async {
    let kept = UpdateState(keptRelease: Self.release("0.3.0"))
    let harness = Self.harness(on: false, state: kept)
    var environment = AppEnvironment.placementDiagnostic()
    environment.update = UpdateEnvironment(
      scheduler: harness.scheduler, preferences: harness.preferences, runningVersion: "0.2.0",
      runningBuild: "2", openURL: { _ in })
    let model = AppModel(environment: environment)
    #expect(model.update.isAvailable)
    #expect(model.settings.update === model.update)
    await model.start()
    #expect(await Self.wait { model.update.showsDot })
    model.popoverVisibilityChanged(true)
    #expect(await Self.wait { !model.update.showsDot })
    #expect(await harness.store.state.noticeSeenVersion == Self.version("0.3.0"))
    await model.shutdown()
    #expect(await harness.scheduler.checkNow() == .failed(.cancelled))
    #expect(harness.transport.calls == 0)
  } // End of func appModelWiresTheUpdateModel()

  /// A seen mark that cannot be saved leaves the dot.
  @Test func failedSeenWriteLeavesTheDot() async {
    let kept = UpdateState(keptRelease: Self.release("0.3.0"))
    let harness = Self.harness(on: false, state: kept)
    await harness.store.setFailure(.encodingFailed)
    harness.model.start()
    #expect(await Self.wait { harness.model.showsDot })
    harness.model.popoverVisibilityChanged(true)
    await harness.model.workEnded()
    #expect(harness.model.showsDot)
    #expect(await harness.store.state.noticeSeenVersion == nil)
    await harness.model.stop()
  }

  /// "What's new" opens the notice's release page through the injected opener; a fixture's
  /// model opens nothing.
  @Test func whatsNewOpensTheReleasePage() async {
    let harness = Self.harness(on: false, state: UpdateState(keptRelease: Self.release("0.3.0")))
    harness.model.start()
    #expect(await Self.wait { harness.model.notice != nil })
    harness.model.openWhatsNew()
    #expect(
      harness.opened.withLock { $0 }
        == [URL(string: "https://github.com/ccarpiog/muxFinder/releases/tag/v0.3.0")!])
    await harness.model.stop()
    UpdateModel(fixture: UpdateFixture(status: UpdateFixtures.newerStatus(), now: Date()))
      .openWhatsNew()
  }

  /// The popover's fixture shows the notice; the AppModel hands the popover's visibility to
  /// the update model.
  @Test func popoverFixtureShowsTheNotice() {
    let model = AppModel(fixture: UpdateFixtures.popoverNotice)
    #expect(model.update.notice?.version == Self.version("0.3.0"))
    #expect(model.update.showsDot)
  }

  // MARK: - The status line

  /// One phrase per state and outcome, then when the last check succeeded.
  @Test func statusLinePhrases() {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let utc = TimeZone(identifier: "UTC")!
    /// The lines for `status`.
    func lines(_ status: UpdateCheckStatus?, requested: Bool = false) -> [String] {
      UpdateNotice.statusLines(
        status: status, isCheckRequested: requested, runningVersion: "0.2.0",
        runningBuild: "2", now: now, timeZone: utc)
    }
    /// A status after `outcome`, last successful two minutes ago.
    func after(_ outcome: UpdateCheckOutcome) -> UpdateCheckStatus {
      UpdateCheckStatus(
        lastCheck: UpdateCheckRecord(outcome: outcome, date: now, manual: true),
        lastSuccessfulCheck: now.addingTimeInterval(-120))
    }
    #expect(lines(nil) == ["Not checked yet"])
    #expect(lines(nil, requested: true) == ["Checking for updates…", "Not checked yet"])
    #expect(
      lines(UpdateCheckStatus(activity: .checking(manual: false))).first
        == "Checking for updates…")
    #expect(
      lines(after(.checked(.upToDate(latest: Self.version("0.2.0")))))
        == ["You're up to date (0.2.0 (2))", "Last checked 2 min ago"])
    #expect(
      lines(after(.checked(.newer(Self.release("0.3.0"))))).first
        == "muxFinder 0.3.0 is available")
    #expect(lines(after(.failed(.offline))).first == "Couldn't check: no connection")
    #expect(lines(after(.failed(.timedOut))).first == "Couldn't check: no answer")
    #expect(lines(after(.failed(.httpStatus(502)))).first == "Couldn't check: GitHub answered 502")
    #expect(
      lines(after(.failed(.unreadableAnswer(.notJSON)))).first
        == "Couldn't check: the answer couldn't be read")
    #expect(
      lines(after(.failed(.notModifiedWithoutRelease))).first
        == "Couldn't check: the answer had no release")
    #expect(lines(after(.failed(.cancelled))).first == "Couldn't check: the check was stopped")
    #expect(lines(after(.failed(.other("x")))).first == "Couldn't check: something went wrong")
    #expect(
      lines(after(.rateLimited(until: now.addingTimeInterval(1800)))).first
        == "Couldn't check: GitHub is limiting requests until 08:30")
    #expect(
      lines(after(.checked(.nothingOffered(.runningVersionUnknown)))).first
        == "No update offered: this build has no version number")
    #expect(
      lines(after(.checked(.nothingOffered(.draft)))).first
        == "No update offered: the latest release can't be used")
    let kept = UpdateCheckStatus(
      offer: .newer(Self.release("0.3.0")), lastSuccessfulCheck: now.addingTimeInterval(-7200))
    #expect(lines(kept) == ["muxFinder 0.3.0 is available", "Last checked 2 hr ago"])
    #expect(
      UpdateNotice.upToDate(runningVersion: "0.2.0", runningBuild: nil)
        == "You're up to date (0.2.0)")
  } // End of func statusLinePhrases()

  /// The Settings fixtures cover every phrase shown in the gallery, the toggle off and the
  /// button disabled while checking.
  @Test func settingsFixtures() {
    let checking = UpdateModel(fixture: UpdateFixtures.settingsChecking.update!)
    #expect(checking.isChecking)
    let off = UpdateModel(fixture: UpdateFixtures.settingsOff.update!)
    #expect(!off.automaticChecks)
    #expect(!off.isChecking)
    let notChecked = UpdateModel(fixture: UpdateFixtures.settingsNotChecked.update!)
    #expect(notChecked.statusLines == ["Not checked yet"])
    #expect(SettingsModel(fixture: UpdateFixtures.settingsOff).update.isAvailable)
    #expect(!SettingsModel(fixture: SettingsFixtures.loginEnabled).update.isAvailable)
  }

  // MARK: - The dot's drawing

  /// The dot is drawn into the template image at run time: still a template of the same
  /// size, opaque in its corner, the rest as the base; without the dot, the base itself.
  @Test func dotIsDrawnIntoTheTemplateImage() throws {
    let base = NSImage(size: NSSize(width: 18, height: 18))
    base.isTemplate = true
    #expect(MenuBarIcon.image(base, withDot: false) === base)
    let dotted = MenuBarIcon.image(base, withDot: true)
    #expect(dotted.isTemplate)
    #expect(dotted.size == base.size)
    let bitmap = try #require(
      NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
        bytesPerRow: 0, bitsPerPixel: 0))
    bitmap.size = base.size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
    dotted.draw(in: NSRect(origin: .zero, size: base.size))
    NSGraphicsContext.restoreGraphicsState()
    let dot = MenuBarIcon.dotRect(in: base.size)
    // Bitmap rows run top down: the dot's centre is near the top-right corner.
    let x = Int((dot.midX * 2).rounded(.down))
    let y = Int(((base.size.height - dot.midY) * 2).rounded(.down))
    #expect((bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.9)
    #expect((bitmap.colorAt(x: 2, y: 34)?.alphaComponent ?? 1) < 0.1)
  } // End of func dotIsDrawnIntoTheTemplateImage()
}

/// A transport that answers from a script and counts requests; it can hold them until the test
/// releases them. Never sends anything.
final class UpdateModelTestTransport: UpdateCheckTransport, Sendable {
  /// Mutable state.
  private struct State {
    /// Answers in order, then `fallback`.
    var script: [UpdateCheckResponse]
    /// The answer after the script.
    var fallback: UpdateCheckResponse
    /// Requests made.
    var calls = 0
    /// Whether requests wait.
    var holding = false
    /// Requests waiting.
    var held: [CheckedContinuation<Void, Never>] = []
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// A transport answering `script`, then `fallback`.
  init(_ script: [UpdateCheckResponse], fallback: UpdateCheckResponse) {
    state = OSAllocatedUnfairLock(initialState: State(script: script, fallback: fallback))
  }

  /// Counts the request, waits while holding, answers.
  func latestRelease(etag: String?) async -> UpdateCheckResponse {
    let hold = state.withLock { state -> Bool in
      state.calls += 1
      return state.holding
    }
    if hold {
      await withCheckedContinuation { continuation in
        let now = state.withLock { state -> Bool in
          guard state.holding else { return true }
          state.held.append(continuation)
          return false
        }
        if now { continuation.resume() }
      }
    }
    return state.withLock { $0.script.isEmpty ? $0.fallback : $0.script.removeFirst() }
  } // End of func latestRelease(etag:)

  /// Requests made.
  var calls: Int { state.withLock { $0.calls } }

  /// Holds the next requests.
  func hold() { state.withLock { $0.holding = true } }

  /// Releases the held requests.
  func releaseHeld() {
    let held = state.withLock { state -> [CheckedContinuation<Void, Never>] in
      state.holding = false
      defer { state.held = [] }
      return state.held
    }
    for continuation in held { continuation.resume() }
  }
}

/// A preferences store whose `load()` reads `backing` at once but returns only once the test
/// calls `releaseLoad()` (a read that was slow to come back, so its value may be stale by
/// then); changes go to `backing` at once.
final class SuspendedLoadPreferencesStore: UpdateCheckSettingStoring, Sendable {
  /// Mutable state.
  private struct Gate {
    /// Whether loads may return.
    var released = false
    /// Loads waiting for `releaseLoad()`.
    var waiting: [CheckedContinuation<Void, Never>] = []
    /// How many loads were asked for.
    var loadCalls = 0
  }

  /// Where the preferences are kept.
  let backing: InMemoryPreferencesStore
  /// The gate.
  private let gate = OSAllocatedUnfairLock(initialState: Gate())

  /// A store over `backing`, its loads suspended.
  init(_ backing: InMemoryPreferencesStore) {
    self.backing = backing
  }

  /// Reads `backing` now, waits for `releaseLoad()`, then gives what it read.
  func load() async throws(PreferencesStoreError) -> PreferencesLoadResult {
    let read = await backing.load()
    let released = gate.withLock { gate -> Bool in
      gate.loadCalls += 1
      return gate.released
    }
    if !released {
      await withCheckedContinuation { continuation in
        let now = gate.withLock { gate -> Bool in
          guard !gate.released else { return true }
          gate.waiting.append(continuation)
          return false
        }
        if now { continuation.resume() }
      }
    }
    return read
  } // End of func load()

  /// `backing`'s.
  func setGlobalShortcut(
    _ shortcut: GlobalShortcut?
  ) async throws(PreferencesStoreError) -> PreferencesChangeResult {
    try await backing.setGlobalShortcut(shortcut)
  }

  /// `backing`'s.
  func setFolderSearchScope(
    _ scope: FolderSearchScope
  ) async throws(PreferencesStoreError) -> PreferencesChangeResult {
    try await backing.setFolderSearchScope(scope)
  }

  /// `backing`'s.
  func setCheckForUpdatesAutomatically(
    _ on: Bool
  ) async throws(PreferencesStoreError) -> PreferencesChangeResult {
    try await backing.setCheckForUpdatesAutomatically(on)
  }

  /// Lets every waiting and later load return.
  func releaseLoad() {
    let waiting = gate.withLock { gate -> [CheckedContinuation<Void, Never>] in
      gate.released = true
      defer { gate.waiting = [] }
      return gate.waiting
    }
    for continuation in waiting { continuation.resume() }
  }

  /// How many loads were asked for.
  var loadCalls: Int { gate.withLock { $0.loadCalls } }
}

/// A clock whose time moves only when the test says (`advance(by:)` ends the sleeps it
/// reaches; `shiftWallClock(by:)` moves only the wall clock).
final class UpdateModelTestClock: UpdateClock, Sendable {
  /// Where virtual time starts.
  static let baseDate = Date(timeIntervalSince1970: 1_800_000_000)

  /// One sleep.
  private struct Waiter {
    /// When it ends, in virtual seconds.
    let deadline: TimeInterval
    /// Resumes it.
    let continuation: CheckedContinuation<Void, any Error>
  }

  /// Mutable state.
  private struct State {
    /// Virtual seconds elapsed.
    var offset: TimeInterval = 0
    /// The wall clock's hand shift.
    var shift: TimeInterval = 0
    /// Waiting sleeps.
    var waiters: [Int: Waiter] = [:]
    /// Sleeps cancelled before they registered.
    var cancelledEarly: Set<Int> = []
    /// The next id.
    var nextID = 0
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// The wall clock.
  func date() -> Date {
    state.withLock { Self.baseDate.addingTimeInterval($0.offset + $0.shift) }
  }

  /// Sleeps until virtual time reaches now + `duration`.
  func sleep(for duration: Duration) async throws {
    let seconds =
      Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    let id = state.withLock { state -> Int in
      state.nextID += 1
      return state.nextID
    }
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation {
        (continuation: CheckedContinuation<Void, any Error>) in
        let immediate = state.withLock { state -> Result<Void, any Error>? in
          if state.cancelledEarly.remove(id) != nil { return .failure(CancellationError()) }
          guard seconds > 0 else { return .success(()) }
          state.waiters[id] = Waiter(deadline: state.offset + seconds, continuation: continuation)
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

  /// Moves virtual time forward, ending the sleeps it reaches.
  func advance(by duration: Duration) {
    let seconds =
      Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    let due = state.withLock { state -> [Waiter] in
      state.offset += seconds
      let due = state.waiters.filter { $0.value.deadline <= state.offset + 1e-9 }
      for id in due.keys { state.waiters[id] = nil }
      return Array(due.values)
    }
    for waiter in due { waiter.continuation.resume() }
  }

  /// Moves only the wall clock.
  func shiftWallClock(by seconds: TimeInterval) {
    state.withLock { $0.shift += seconds }
  }

  /// Sleeps waiting.
  var waiting: Int { state.withLock { $0.waiters.count } }
}
