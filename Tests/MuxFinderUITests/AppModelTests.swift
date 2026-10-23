import AppKit
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// `AppModel` over fixtures: keyboard selection across filtered rows and the key commands. A
/// fixture model opens nothing (the session actions are `AttachFlowTests`'). No engine runs.
@Suite("App model: keyboard and intents")
@MainActor
struct AppModelKeyboardTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// A model over the overview with `query` and no selection.
  static func model(query: String = "") -> AppModel {
    var fixture = Fixtures.overview
    fixture.searchText = query
    fixture.selection = nil
    return AppModel(fixture: fixture)
  }

  /// ↓ from nothing selects the first row, then moves down and stops at the last; ↑ moves up
  /// and stops at the first.
  @Test func arrowsMoveThroughRows() {
    let model = Self.model()
    let keys = model.content.selectableKeys
    #expect(keys.count == 6)
    _ = model.handle(.down)
    #expect(model.selection == keys[0])
    for _ in 0..<10 { _ = model.handle(.down) }
    #expect(model.selection == keys[5])
    _ = model.handle(.up)
    #expect(model.selection == keys[4])
    for _ in 0..<10 { _ = model.handle(.up) }
    #expect(model.selection == keys[0])
    model.selection = nil
    _ = model.handle(.up)
    #expect(model.selection == keys[5])
  } // End of func arrowsMoveThroughRows()

  /// The arrows move only through the rows the search left, across hosts; a selection the
  /// search hid restarts at the first (↓) or last (↑) listed row.
  @Test func arrowsFollowTheFilter() {
    let model = Self.model()
    model.selection = Fixtures.saturnoSessions[0].key
    model.searchText = "ex"
    let keys = model.content.selectableKeys
    #expect(
      keys == [
        Fixtures.saturnoSessions[1].key, Fixtures.neptunoSessions[1].key,
        Fixtures.sirioSessions[1].key,
      ])
    _ = model.handle(.down)
    #expect(model.selection == keys[0])
    _ = model.handle(.down)
    #expect(model.selection == keys[1])
    _ = model.handle(.down)
    _ = model.handle(.down)
    #expect(model.selection == keys[2])
    model.selection = Fixtures.saturnoSessions[0].key
    _ = model.handle(.up)
    #expect(model.selection == keys[2])
    model.searchText = "zebra"
    _ = model.handle(.down)
    #expect(model.selection == nil)
  } // End of func arrowsFollowTheFilter()

  /// Return on a fixture selects nothing new and opens nothing: a fixture model never builds
  /// an attach coordinator.
  @Test func returnOnAFixtureOpensNothing() {
    let model = Self.model()
    #expect(model.handle(.open) == .handled)
    _ = model.handle(.down)
    _ = model.handle(.open)
    #expect(model.selection == Fixtures.saturnoSessions[0].key)
    #expect(model.finishedActions.isEmpty)
    #expect(model.activities.isEmpty)
  }

  /// ⌘F asks for the search focus, ⌘N shows no sheet on a fixture, ⌘, is handled (a fixture
  /// model presents no window), ⌘R is accepted and Esc closes the popover.
  @Test func commandKeys() {
    let model = Self.model()
    #expect(model.handle(.find) == .handled)
    #expect(model.searchFocusRequests == 1)
    #expect(model.handle(.newSession) == .handled)
    #expect(model.panel == nil)
    #expect(model.handle(.settings) == .handled)
    #expect(model.handle(.refresh) == .handled)
    #expect(model.handle(.close) == .closePopover)
  }

  /// Clicking a row of a fixture selects it and opens nothing.
  @Test func clickSelects() {
    let model = Self.model()
    let key = Fixtures.neptunoSessions[0].key
    model.open(key)
    #expect(model.selection == key)
    #expect(model.activities[key] == nil)
  }

  /// A fixture model never quits, refreshes or starts anything, and keeps its fixed time.
  @Test func fixtureModelIsInert() async {
    let model = AppModel(fixture: Fixtures.progress)
    #expect(model.isPreview)
    model.quit()
    model.refresh()
    model.popoverDidOpen()
    await model.start()
    #expect(model.engine == nil)
    #expect(model.lifecycle == .idle)
    #expect(model.now == Fixtures.now)
    await model.shutdown()
  } // End of func fixtureModelIsInert()

  /// A row shows its session's activity; Retry on a failure no action caused clears it.
  @Test func activities() {
    let model = Self.model()
    let key = Fixtures.saturnoSessions[1].key
    let failure = SessionActivity.failed(SessionProblem(message: "No."))
    model.setActivity(failure, for: key)
    #expect(model.content.sections[0].rows[1].activity == failure)
    model.retry(session: key)
    #expect(model.activities[key] == nil)
  }

  /// Key presses map to commands only with the right modifiers.
  @Test func keyMapping() {
    typealias Key = PopoverKey
    #expect(
      Key(keyCode: 126, modifierFlags: [.numericPad, .function], charactersIgnoringModifiers: nil)
        == .up)
    #expect(Key(keyCode: 125, modifierFlags: [], charactersIgnoringModifiers: nil) == .down)
    #expect(Key(keyCode: 36, modifierFlags: [], charactersIgnoringModifiers: "\r") == .open)
    #expect(Key(keyCode: 76, modifierFlags: [], charactersIgnoringModifiers: "\u{3}") == .open)
    #expect(Key(keyCode: 53, modifierFlags: [], charactersIgnoringModifiers: "\u{1b}") == .close)
    #expect(Key(keyCode: 3, modifierFlags: .command, charactersIgnoringModifiers: "f") == .find)
    #expect(Key(keyCode: 15, modifierFlags: .command, charactersIgnoringModifiers: "r") == .refresh)
    #expect(
      Key(keyCode: 45, modifierFlags: .command, charactersIgnoringModifiers: "n") == .newSession)
    #expect(
      Key(keyCode: 43, modifierFlags: .command, charactersIgnoringModifiers: ",") == .settings)
    #expect(Key(keyCode: 126, modifierFlags: .shift, charactersIgnoringModifiers: nil) == nil)
    #expect(Key(keyCode: 36, modifierFlags: .command, charactersIgnoringModifiers: "\r") == nil)
    #expect(
      Key(keyCode: 15, modifierFlags: [.command, .shift], charactersIgnoringModifiers: "r") == nil)
    #expect(Key(keyCode: 15, modifierFlags: [], charactersIgnoringModifiers: "r") == nil)
    #expect(Key(keyCode: 0, modifierFlags: .command, charactersIgnoringModifiers: "a") == nil)
  } // End of func keyMapping()

  /// The command-line flags.
  @Test func launchOptions() {
    #expect(AppLaunchOptions(arguments: []) == AppLaunchOptions(arguments: ["-psn_0_1"]))
    let preview = AppLaunchOptions(arguments: ["--preview-fixtures", "--appearance", "dark"])
    #expect(preview.previewFixtures)
    #expect(preview.appearance == .dark)
    #expect(preview.previewSnapshotPath == nil)
    let equals = AppLaunchOptions(arguments: [
      "--appearance=LIGHT", "--preview-snapshot=/tmp/x.png", "-NSDocumentRevisionsDebugMode", "YES",
    ])
    #expect(!equals.previewFixtures)
    #expect(equals.appearance == .light)
    #expect(equals.previewSnapshotPath == "/tmp/x.png")
    #expect(AppLaunchOptions(arguments: ["--appearance", "sepia"]).appearance == nil)
    #expect(AppLaunchOptions(arguments: ["--appearance"]).appearance == nil)
    let snapshot = AppLaunchOptions(arguments: [
      "--preview-snapshot", "out.png", "--preview-fixtures",
    ])
    #expect(snapshot.previewSnapshotPath == "out.png")
    #expect(snapshot.previewFixtures)
    #expect(!snapshot.reportsMenuBarItem)
    #expect(AppLaunchOptions(arguments: ["--report-menu-bar-item"]).reportsMenuBarItem)
    #expect(
      AppLaunchOptions(arguments: ["--preview-gallery", "attach"]).previewGallery == .attach)
  } // End of func launchOptions()

  /// `--selftest` takes a known name (and `--selftest-keep`); anything else is a usage error,
  /// so the app exits before contacting anything.
  @Test func selfTestOptions() {
    let attach = AppLaunchOptions(arguments: ["--selftest", "attach-local"])
    #expect(attach.selfTest == SelfTestRequest(kind: .attachLocal))
    #expect(attach.usageError == nil)
    let keep = AppLaunchOptions(arguments: ["--selftest-keep", "--selftest=new-session-local"])
    #expect(keep.selfTest == SelfTestRequest(kind: .newSessionLocal, keep: true))
    #expect(keep.usageError == nil)
    #expect(AppLaunchOptions(arguments: []).selfTest == nil)
    for bad in [
      ["--selftest", "bogus"], ["--selftest"], ["--selftest-keep"], ["--selftest=", "x"],
      ["--selftest", "attach-local", "--preview-fixtures"],
      ["--report-login-item-status", "--selftest", "new-session-local"],
      ["--selftest", "Attach-Local"],
      ["--selftest", "attach-local", "--remove-persistent-profiles"],
    ] {
      #expect(AppLaunchOptions(arguments: bad).usageError != nil, "\(bad)")
    }
  } // End of func selfTestOptions()

  /// `--remove-persistent-profiles` (PLAN.md D27) with `--dry-run` and both test folders; its
  /// options without the mode, the mode with another mode, one folder alone, a missing or
  /// relative folder are usage errors, so a mistyped removal never starts the menu bar app.
  @Test func profileRemovalOptions() {
    let plain = AppLaunchOptions(arguments: ["--remove-persistent-profiles"])
    #expect(plain.removesPersistentProfiles)
    #expect(!plain.profileRemovalDryRun)
    #expect(plain.profilesDirectory == nil && plain.profilesLockDirectory == nil)
    #expect(plain.usageError == nil)
    #expect(!plain.rewritesProfilesAtLaunch)
    let full = AppLaunchOptions(arguments: [
      "--dry-run", "--profiles-directory", "/tmp/mfx.a/DynamicProfiles",
      "--lock-directory=/tmp/mfx.a/muxFinder", "--remove-persistent-profiles",
    ])
    #expect(full.removesPersistentProfiles && full.profileRemovalDryRun)
    #expect(full.profilesDirectory == "/tmp/mfx.a/DynamicProfiles")
    #expect(full.profilesLockDirectory == "/tmp/mfx.a/muxFinder")
    #expect(full.usageError == nil)
    #expect(!AppLaunchOptions(arguments: []).removesPersistentProfiles)
    for bad in [
      ["--dry-run"], ["--profiles-directory", "/a", "--lock-directory", "/b"],
      ["--remove-persistent-profiles", "--profiles-directory", "/a"],
      ["--remove-persistent-profiles", "--lock-directory", "/b"],
      ["--remove-persistent-profiles", "--profiles-directory", "a", "--lock-directory", "/b"],
      ["--remove-persistent-profiles", "--profiles-directory=", "--lock-directory", "/b"],
      ["--remove-persistent-profiles", "--profiles-directory", "/a", "--lock-directory"],
      ["--remove-persistent-profiles", "--preview-fixtures"],
      ["--remove-persistent-profiles", "--report-login-item-status"],
      ["--remove-persistent-profiles", "--report-menu-bar-item"],
    ] {
      let options = AppLaunchOptions(arguments: bad)
      #expect(options.usageError != nil, "\(bad)")
      #expect(!options.rewritesProfilesAtLaunch, "\(bad)")
    }
    #expect(AppLaunchOptions.usage.contains(AppLaunchOptions.profileRemovalUsage))
    #expect(AppLaunchOptions.usage.contains(AppLaunchOptions.selfTestUsage))
  } // End of func profileRemovalOptions()
}

/// `AppModel` driving a real `RefreshCoordinator` over fake discovery and fake attachment
/// checks: start, the host list's load states, popover visibility, Refresh and Retry, system
/// events, shutdown, and when iTerm2's cookie is requested (through the real `ITerm2APIClient`
/// with a counting cookie provider). No process, socket connection or iTerm2 is involved.
@Suite("App model: engine")
@MainActor
struct AppModelEngineTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// Start loads the list (writing nothing), runs the engine and mirrors its state; the hosts
  /// turn live.
  @Test func startRunsTheEngine() async {
    let hosts = [Support.localHost(), Support.sshHost("Saturno")]
    let discovery = FakeDiscovery()
    let model = AppModel(
      environment: Support.environment(load: { Support.loaded(hosts) }, discovery: discovery))
    #expect(model.content.placeholder == .loading)
    await model.start()
    #expect(model.lifecycle == .running)
    #expect(model.hostListStatus == .saved)
    #expect(await Support.waitUntil { model.refreshState?.hosts.allSatisfy(\.isLive) == true })
    #expect(model.content.sections.map(\.status) == [.thisMac, .reachable])
    #expect(model.content.sections.map { $0.rows.count } == [1, 1])
    #expect(model.now == Support.now)
    #expect(discovery.calls(of: hosts[0].id) == 1)
    await model.shutdown()
  } // End of func startRunsTheEngine()

  /// No saved list: the onboarding examples are all off, so nothing is discovered and the
  /// popover says no host is turned on.
  @Test func notSavedYetDiscoversNothing() async {
    let discovery = FakeDiscovery()
    let model = AppModel(
      environment: Support.environment(
        load: { HostStoreLoadResult(hosts: .onboardingDefaults(), state: .notSavedYet) },
        discovery: discovery))
    await model.start()
    #expect(await Support.waitUntil { model.refreshState != nil })
    #expect(model.hostListStatus == .notSavedYet)
    #expect(model.content.placeholder == .noHostsEnabled)
    #expect(model.content.notices.isEmpty)
    model.popoverDidOpen()
    model.refresh()
    await model.engineRequestsHandled()
    #expect(discovery.totalCalls == 0)
    await model.shutdown()
  } // End of func notSavedYetDiscoversNothing()

  /// An invalid file and an unusable folder are reported, with no host running.
  @Test func unusableHostLists() async {
    let invalid = AppModel(
      environment: Support.environment(load: {
        HostStoreLoadResult(hosts: .onboardingDefaults(), state: .invalid(.malformed))
      }))
    await invalid.start()
    #expect(invalid.hostListStatus == .invalid(.malformed))
    #expect(invalid.content.notices.map(\.kind) == [.hostList])
    await invalid.shutdown()
    let unreadable = AppModel(
      environment: Support.environment(load: { throw HostStoreError.directoryIsSymbolicLink }))
    await unreadable.start()
    guard case .unreadable(let message) = unreadable.hostListStatus else {
      Issue.record("expected an unreadable host list")
      return
    }
    #expect(message == HostStoreError.directoryIsSymbolicLink.errorDescription)
    #expect(await Support.waitUntil { unreadable.content.placeholder == .noHostsEnabled })
    await unreadable.shutdown()
  } // End of func unusableHostLists()

  /// Attachment checks run only while the popover is visible: none after results in the
  /// background, one after opening (the badge appears), none again after closing.
  @Test func popoverVisibilityTogglesAttachmentChecks() async throws {
    let host = Support.sshHost("Saturno")
    let discovery = FakeDiscovery()
    let index = FakeIndex(attached: [FakeDiscovery.session(on: host).key])
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([host]) }, discovery: discovery, index: index))
    await model.start()
    let engine = try #require(model.engine)
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    model.refresh()
    await model.engineRequestsHandled()
    #expect(await Support.waitUntil { discovery.calls(of: host.id) == 2 })
    #expect(await Support.waitUntil { await Support.isSettled(engine) })
    #expect(await engine.indexPassesStarted == 0)
    #expect(index.calls.value == 0)
    #expect(model.refreshState?.isPopoverVisible == false)

    model.popoverDidOpen()
    #expect(model.isPopoverVisible)
    #expect(await Support.waitUntil { model.refreshState?.isPopoverVisible == true })
    #expect(
      await Support.waitUntil {
        model.content.sections.first?.rows.first?.isOpenInITerm2Here == true
      })
    #expect(index.calls.value == 1)
    #expect(discovery.calls(of: host.id) == 3)

    model.popoverDidClose()
    #expect(await Support.waitUntil { model.refreshState?.isPopoverVisible == false })
    let passes = await engine.indexPassesStarted
    model.refresh()
    await model.engineRequestsHandled()
    #expect(await Support.waitUntil { discovery.calls(of: host.id) == 4 })
    #expect(await Support.waitUntil { await Support.isSettled(engine) })
    #expect(await engine.indexPassesStarted == passes)
    #expect(index.calls.value == 1)
    await model.shutdown()
  } // End of func popoverVisibilityTogglesAttachmentChecks()

  /// Repeated visibility reports change nothing; an open before the engine runs is applied
  /// once it does.
  @Test func visibilityBeforeStartAndRepeats() async {
    let host = Support.sshHost("Saturno")
    let discovery = FakeDiscovery()
    let model = AppModel(
      environment: Support.environment(load: { Support.loaded([host]) }, discovery: discovery))
    model.popoverVisibilityChanged(true)
    model.popoverVisibilityChanged(true)
    await model.start()
    #expect(await Support.waitUntil { model.refreshState?.isPopoverVisible == true })
    model.popoverVisibilityChanged(false)
    model.popoverVisibilityChanged(false)
    #expect(await Support.waitUntil { model.refreshState?.isPopoverVisible == false })
    #expect(!model.isPopoverVisible)
    await model.shutdown()
  } // End of func visibilityBeforeStartAndRepeats()

  /// "Refresh" asks every host again; "Retry" only its host; Retry on a failed session clears
  /// the failure and refreshes the session's host.
  @Test func refreshAndRetry() async {
    let saturno = Support.sshHost("Saturno")
    let sirio = Support.sshHost("Sirio")
    let discovery = FakeDiscovery()
    discovery.setStatus(.unreachable(.timeout), for: sirio.id)
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([saturno, sirio]) }, discovery: discovery))
    await model.start()
    #expect(
      await Support.waitUntil {
        model.refreshState?.hosts.allSatisfy { $0.lastAttempt != nil } == true
      })
    #expect(model.content.sections.map(\.status) == [.reachable, .unreachable])
    #expect(model.content.sections[1].problem == "The connection timed out.")

    model.refresh()
    #expect(
      await Support.waitUntil {
        discovery.calls(of: saturno.id) == 2 && discovery.calls(of: sirio.id) == 2
      })

    discovery.setStatus(.noServer, for: sirio.id)
    model.retry(hostID: sirio.id)
    #expect(await Support.waitUntil { discovery.calls(of: sirio.id) == 3 })
    #expect(await Support.waitUntil { model.content.sections[1].status == .noSessions })
    #expect(discovery.calls(of: saturno.id) == 2)

    let key = FakeDiscovery.session(on: saturno).key
    model.setActivity(.failed(SessionProblem(message: "No.")), for: key)
    model.retry(session: key)
    #expect(model.activities[key] == nil)
    #expect(await Support.waitUntil { discovery.calls(of: saturno.id) == 3 })
    #expect(discovery.calls(of: sirio.id) == 3)
    await model.shutdown()
  } // End of func refreshAndRetry()

  /// Sleep and wake notifications reach the engine through `RefreshSystemEvents` (a private
  /// notification center, no network monitor).
  @Test func systemEventsAreWired() async {
    let center = NotificationCenter()
    let host = Support.sshHost("Saturno")
    let discovery = FakeDiscovery()
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([host]) }, discovery: discovery,
        events: { engine in
          RefreshSystemEvents(
            coordinator: engine, notificationCenter: center, watchesNetworkPath: false)
        }))
    await model.start()
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    center.post(name: RefreshSystemEvents.willSleepNotification, object: nil)
    #expect(await Support.waitUntil { model.refreshState?.isAsleep == true })
    center.post(name: RefreshSystemEvents.didWakeNotification, object: nil)
    #expect(await Support.waitUntil { model.refreshState?.isAsleep == false })
    #expect(await Support.waitUntil { discovery.calls(of: host.id) == 2 })
    await model.shutdown()
  } // End of func systemEventsAreWired()

  /// Quit asks the environment to terminate; shutdown stops the engine and the updates and
  /// sends iTerm2 nothing (no detach); later requests are dropped.
  @Test func quitAndShutdown() async throws {
    let host = Support.localHost()
    let iTerm2 = FakeITerm2Integration()
    let terminations = Counter()
    let discovery = FakeDiscovery()
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([host]) }, discovery: discovery,
        index: AttachmentIndex(iTerm2: iTerm2), terminations: terminations))
    await model.start()
    let engine = try #require(model.engine)
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    model.quit()
    #expect(terminations.value == 1)
    await model.shutdown()
    #expect(model.lifecycle == .stopped)
    #expect(await engine.lifecycle == .stopped)
    #expect(await engine.liveTaskCount == 0)
    #expect(await iTerm2.calls.isEmpty)
    let calls = discovery.totalCalls
    model.refresh()
    model.popoverDidOpen()
    await model.engineRequestsHandled()
    #expect(discovery.totalCalls == calls)
    await model.shutdown()
  } // End of func quitAndShutdown()

  /// A popover opening still queued when shutdown begins is dropped, not handed to the engine
  /// about to stop: no probe and no attachment check start while quitting.
  @Test func shutdownDropsRequestsStillQueued() async throws {
    let host = Support.sshHost("Saturno")
    let discovery = FakeDiscovery()
    let index = FakeIndex(attached: [])
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([host]) }, discovery: discovery, index: index))
    await model.start()
    let engine = try #require(model.engine)
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    #expect(await Support.waitUntil { await Support.isSettled(engine) })
    let attempts = await engine.attemptsStarted[host.id]
    model.popoverDidOpen()
    await model.shutdown()
    #expect(await engine.attemptsStarted[host.id] == attempts)
    #expect(await engine.state.isPopoverVisible == false)
    #expect(await engine.indexPassesStarted == 0)
    #expect(index.calls.value == 0)
  } // End of func shutdownDropsRequestsStillQueued()

  /// A shutdown while the host list loads stops before any engine exists.
  @Test func shutdownDuringStart() async {
    let gate = Counter()
    let model = AppModel(
      environment: Support.environment(load: {
        gate.increment()
        try await Task.sleep(for: .milliseconds(200))
        return Support.loaded([Support.localHost()])
      }))
    let start = Task { await model.start() }
    #expect(await Support.waitUntil { gate.value == 1 })
    await model.shutdown()
    await start.value
    #expect(model.engine == nil)
    #expect(model.lifecycle == .stopped)
  } // End of func shutdownDuringStart()

  // MARK: - iTerm2 cookie timing

  /// Through the real API client: nothing asks for iTerm2's cookie (or even whether iTerm2
  /// runs) at start or while the popover is closed; opening the popover while iTerm2 runs
  /// asks for it, for the attachment check.
  @Test func cookieIsRequestedOnlyWhenThePopoverOpensWhileITerm2Runs() async throws {
    let (directory, socket) = try Support.fakeSocketPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = FakeAppControl(running: true)
    let cookies = CountingCookieProvider()
    let client = ITerm2APIClient(
      configuration: .init(socketPath: socket), appControl: control, cookieProvider: cookies)
    let host = Support.localHost()
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([host]) }, index: AttachmentIndex(iTerm2: client)))
    await model.start()
    let engine = try #require(model.engine)
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    model.refresh()
    await model.engineRequestsHandled()
    #expect(await Support.waitUntil { await Support.isSettled(engine) })
    #expect(await engine.indexPassesStarted == 0)
    #expect(cookies.requests.value == 0)
    #expect(control.runningChecks.value == 0)

    model.popoverDidOpen()
    #expect(
      await Support.waitUntil {
        if case .failed(_, .automationDenied) = model.refreshState?.attachmentCheck { return true }
        return false
      })
    #expect(cookies.requests.value >= 1)
    #expect(control.runningChecks.value >= 1)
    #expect(control.launches.value == 0)
    #expect(model.content.notices.map(\.kind) == [.attachmentCheck])
    await model.shutdown()
  } // End of func cookieIsRequestedOnlyWhenThePopoverOpensWhileITerm2Runs()

  /// The review's finding, from the model: closing the popover while the attachment check waits
  /// for iTerm2's cookie cancels the check, so when the cookie arrives nothing connects and
  /// nothing is published (the real `ITerm2APIClient`, a gated cookie, a counting connector).
  @Test func closingDuringTheCookieRequestConnectsNothing() async throws {
    let cookies = GatedCookieProvider()
    let connector = CountingConnector()
    let log = DiagnosticsLog(writesToSystemLog: false)
    let client = ITerm2APIClient(
      configuration: .init(socketPath: "/nonexistent/fake-socket"),
      appControl: FakeAppControl(running: true), cookieProvider: cookies, connector: connector,
      connectionSettings: ITerm2Connection.Settings(), diagnostics: log)
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([Support.localHost()]) }, index: AttachmentIndex(iTerm2: client)))
    await model.start()
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    model.popoverDidOpen()
    #expect(await Support.waitUntil { cookies.requests == 1 })
    model.popoverDidClose()
    await model.engineRequestsHandled()
    #expect(
      await Support.waitUntil(timeout: .seconds(3)) { await client.attemptWaiterCount == 0 })
    cookies.release()
    #expect(await Support.waitUntil { await !log.events().isEmpty })
    #expect(await log.events().map(\.detail) == ["iTerm2 API connection failed: cancelled"])
    #expect(connector.connects.value == 0)
    #expect(cookies.requests == 1)
    #expect(model.refreshState?.attachmentCheck == .notChecked)
    #expect(model.refreshState?.isPopoverVisible == false)
    await model.shutdown()
  } // End of func closingDuringTheCookieRequestConnectsNothing()

  /// While iTerm2 does not run, opening the popover only checks that it does not: no cookie,
  /// no launch, and the check reports nothing attached.
  @Test func cookieIsNotRequestedWhileITerm2IsNotRunning() async throws {
    let (directory, socket) = try Support.fakeSocketPath()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = FakeAppControl(running: false)
    let cookies = CountingCookieProvider()
    let client = ITerm2APIClient(
      configuration: .init(socketPath: socket), appControl: control, cookieProvider: cookies)
    let model = AppModel(
      environment: Support.environment(
        load: { Support.loaded([Support.localHost()]) }, index: AttachmentIndex(iTerm2: client)))
    await model.start()
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    #expect(control.runningChecks.value == 0)
    model.popoverDidOpen()
    #expect(
      await Support.waitUntil {
        if case .iTermNotRunning = model.refreshState?.attachmentCheck { return true }
        return false
      })
    #expect(control.runningChecks.value >= 1)
    #expect(cookies.requests.value == 0)
    #expect(control.launches.value == 0)
    #expect(model.content.notices.isEmpty)
    await model.shutdown()
  } // End of func cookieIsNotRequestedWhileITerm2IsNotRunning()
}
