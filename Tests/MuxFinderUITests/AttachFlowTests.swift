import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The session actions' state machine (PLAN.md D25) through the real `AppModel`, the real
/// `AttachCoordinator` and the real engine, over a fake iTerm2 integration (`SimulatedITerm2`),
/// fake discovery, an in-memory launch store and a virtual clock. Nothing runs a process,
/// opens a socket or contacts iTerm2.
@Suite("Session actions: attach state machine")
@MainActor
struct AttachFlowTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// A burst of five clicks starts one launch: the clicks after the first are ignored while it
  /// is pending; the row shows "Confirmed" and Detach is offered.
  @Test func burstOfFiveClicksGivesOneLaunch() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    for _ in 0..<5 { model.open(key) }
    #expect(model.isPending(key))
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(await harness.iTerm2.createTabCount == 1)
    #expect(harness.builds.value == 1)
    #expect(model.finishedActions.count == 1)
    #expect(model.finishedActions[0].outcome.attachResult?.isConfirmed == true)
    #expect(model.activities[key] == .confirmed)
    #expect(model.attachedHere[key]?.connectionID == "conn-1")
    #expect(model.attachedHere[key]?.gatewaySessionID == "gateway-1")
    #expect(model.content.sections[0].rows[0].offersDetach)
    #expect(model.selection == key)
    #expect(!model.isPending(key))
    await model.shutdown()
  } // End of func burstOfFiveClicksGivesOneLaunch()

  /// Return opens the selected row the same way; with nothing selected it does nothing.
  @Test func returnOpensTheSelection() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    #expect(model.handle(.open) == .handled)
    #expect(harness.builds.value == 0)
    _ = model.handle(.down)
    _ = model.handle(.open)
    #expect(await harness.waitForActions(1))
    #expect(await harness.iTerm2.createTabCount == 1)
    await model.shutdown()
  }

  /// A session already open in this Mac's iTerm2 is focused: nothing is launched, the existing
  /// connection's tab is activated, and the row says so.
  @Test func alreadyOpenHereFocuses() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.addUserConnection("user-conn", owner: "user-tab", key: key)
    model.open(key)
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(await harness.iTerm2.createTabCount == 0)
    #expect(await harness.iTerm2.focusedConnections == ["user-conn"])
    #expect(harness.store.written.isEmpty)
    #expect(model.finishedActions[0].outcome.attachResult?.isFocused == true)
    #expect(model.activities[key] == .focused)
    #expect(model.attachedHere[key]?.gatewaySessionID == "user-tab")
    await model.shutdown()
  } // End of func alreadyOpenHereFocuses()

  /// "Confirmed" appears only once the core confirmed: while the identity question waits, the
  /// row shows "Waiting for iTerm2…"; after the answer, "Confirmed".
  @Test func confirmedOnlyAfterCoreConfirmation() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.configure { $0.holdsIdentity = true }
    model.open(key)
    #expect(await Support.waitUntil { await harness.iTerm2.heldIdentityCount == 1 })
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .waitingForITerm2)
    #expect(model.finishedActions.isEmpty)
    await harness.iTerm2.releaseIdentity()
    #expect(await harness.waitForActions(1))
    #expect(model.activities[key] == .confirmed)
    await model.shutdown()
  } // End of func confirmedOnlyAfterCoreConfirmation()

  /// A connection that reaches another session is never confirmed: the row never says so, a
  /// "changed" banner appears and the host is refreshed.
  @Test func identityMismatchIsNeverConfirmed() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let host = harness.hosts[0]
    let key = harness.key(on: host)
    let other = PreviewFixtures.session("other", id: 9, on: host, windows: 1).key
    await harness.iTerm2.configure { $0.reportsKey = other }
    let calls = harness.discovery.calls(of: host.id)
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.finishedActions[0].outcome.attachResult?.failure == .identityMismatch)
    #expect(model.activities[key] == nil)
    #expect(model.attachedHere[key] == nil)
    #expect(model.banners.map(\.kind) == [.changed])
    #expect(await Support.waitUntil { harness.discovery.calls(of: host.id) > calls + 1 })
    await model.shutdown()
  } // End of func identityMismatchIsNeverConfirmed()

  /// A remote launch tab that is still waiting shows "Still connecting — check the iTerm2 tab"
  /// with "Show tab"; Show tab activates that launch tab (by its session id) and nothing else.
  /// Quitting then cancels the attach and detaches nothing.
  @Test func stillConnectingShowsTheLaunchTab() async {
    let saturno = Support.sshHost("Saturno")
    let harness = await AttachHarness.make(
      hosts: [saturno], attaches: false, holdAfter: .seconds(25))
    let model = harness.model
    let key = harness.key(on: saturno)
    model.open(key)
    #expect(
      await Support.waitUntil {
        model.activities[key] == .stillConnecting(launchTabID: "gateway-1")
      })
    #expect(
      model.content.sections[0].rows[0].activity?.text == "Still connecting — check the iTerm2 tab")
    #expect(await harness.iTerm2.activations.isEmpty)
    model.showTab(for: key)
    #expect(await Support.waitUntil { await harness.iTerm2.activations.count == 1 })
    let request = await harness.iTerm2.activations[0]
    #expect(request.target == .session("gateway-1"))
    #expect(request.selectSession && request.selectTab && request.orderWindowFront)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    #expect(model.notes[key] == nil)
    let other = PreviewFixtures.session("elsewhere", id: 5, on: saturno, windows: 1).key
    model.showTab(for: other)
    await model.shutdown()
    #expect(await harness.iTerm2.activations.count == 1)
    #expect(model.finishedActions.first?.outcome.attachResult?.failure == .cancelled)
    #expect(await harness.iTerm2.sent.isEmpty)
    #expect(await harness.iTerm2.closeCount == 0)
  } // End of func stillConnectingShowsTheLaunchTab()

  /// Move here reaches the core only after the dialog's confirmation: asking, cancelling and
  /// Esc run nothing; "Move here" (or Return) runs a move whose request asks for `-d`.
  @Test func moveHereNeedsTheConfirmation() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    model.requestMoveHere(key)
    guard case .moveHere(let request) = model.panel else {
      Issue.record("no Move here dialog")
      return
    }
    #expect(request.target.key == key)
    #expect(request.explanation.contains("disconnect every other client"))
    #expect(request.explanation.contains("other Macs"))
    #expect(request.explanation.contains("keeps running"))
    model.cancelPanel()
    model.requestMoveHere(key)
    #expect(model.handle(.close) == .handled)
    #expect(model.panel == nil)
    #expect(harness.builds.value == 0)
    #expect(harness.store.written.isEmpty)
    #expect(await harness.iTerm2.createTabCount == 0)
    model.requestMoveHere(key)
    #expect(model.handle(.open) == .handled)
    #expect(model.panel == nil)
    #expect(model.activities[key] == .movingHere)
    #expect(await harness.waitForActions(1))
    guard case .moveHere(let result) = model.finishedActions[0].outcome else {
      Issue.record("not a move here")
      return
    }
    #expect(result.isConfirmed)
    #expect(harness.store.written.map(\.detachesOtherClients) == [true])
    #expect(model.activities[key] == .confirmed)
    await model.shutdown()
  } // End of func moveHereNeedsTheConfirmation()

  /// Move here of a session open here refuses (`alreadyAttachedHere`) and offers "Bring
  /// forward" and "Detach from this Mac", which then is offered for it.
  @Test func moveHereOfASessionOpenHere() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.addUserConnection("user-conn", owner: "user-tab", key: key)
    model.requestMoveHere(key)
    model.confirmMoveHere()
    #expect(await harness.waitForActions(1))
    #expect(model.activities[key]?.problem?.recoveries == [.bringForward, .detachHere])
    #expect(model.canDetach(key))
    #expect(await harness.iTerm2.createTabCount == 0)
    model.perform(.bringForward, for: key)
    #expect(await harness.waitForActions(2))
    #expect(model.activities[key] == .focused)
    await model.shutdown()
  } // End of func moveHereOfASessionOpenHere()

  /// Detach is offered only for this Mac's attachments: before an attach nothing runs; after a
  /// confirmed attach it detaches with one `detach-client` (no tab closed), says the session
  /// keeps running, and forgets the attachment.
  @Test func detachOnlyForThisMacsAttachments() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    #expect(!model.canDetach(key))
    #expect(!model.content.sections[0].rows[0].offersDetach)
    model.detach(key)
    #expect(model.activities[key] == nil)
    #expect(harness.builds.value == 0)
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.canDetach(key))
    model.detach(key)
    #expect(model.activities[key] == .detaching)
    #expect(await harness.waitForActions(2))
    guard case .detached(let result) = model.finishedActions[1].outcome else {
      Issue.record("not a detach")
      return
    }
    #expect(result.outcome == .detached)
    #expect(model.activities[key] == .detached)
    #expect(model.activities[key]?.text.contains("keeps running") == true)
    #expect(await harness.iTerm2.commands(to: "conn-1").filter { $0 == "detach-client" }.count == 1)
    #expect(await harness.iTerm2.closeCount == 0)
    #expect(model.attachedHere[key] == nil)
    #expect(!model.canDetach(key))
    await model.shutdown()
  } // End of func detachOnlyForThisMacsAttachments()

  /// An Open hides its launch tab once attached (PLAN.md D29): the result says `buried`, and
  /// iTerm2 lists the launch tab in `buried_sessions` and in no window, while the session's
  /// tab stays. A Detach then ends it (the helper restores its tab and the tab closes), so
  /// nothing of it is listed afterwards.
  @Test func anOpenBuriesItsLaunchTab() async throws {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.finishedActions[0].outcome.attachResult?.burial == .buried)
    #expect(await harness.iTerm2.buried == ["gateway-1"])
    let listed = try await harness.iTerm2.listSessions()
    #expect(listed.buriedSessions.map(\.uniqueIdentifier) == ["gateway-1"])
    #expect(listed.placement(ofSession: "gateway-1") == nil)
    #expect(!listed.tabs(ofTmuxConnection: "conn-1").isEmpty)
    model.detach(key)
    #expect(await harness.waitForActions(2))
    #expect(await harness.iTerm2.buried.isEmpty)
    #expect(!(try await harness.iTerm2.listSessions().allSessionIDs.contains("gateway-1")))
    #expect(await harness.iTerm2.closeCount == 0)
    await model.shutdown()
  } // End of func anOpenBuriesItsLaunchTab()

  /// A session the attachment index shows open here offers Detach without an attach by
  /// muxFinder.
  @Test func detachIsOfferedForTheIndexBadge() async {
    let host = Support.localHost()
    let index = FakeIndex(attached: [FakeDiscovery.session(on: host).key])
    let harness = await AttachHarness.make(hosts: [host], index: index)
    let model = harness.model
    model.popoverDidOpen()
    #expect(
      await Support.waitUntil { model.content.sections.first?.rows.first?.offersDetach == true })
    #expect(model.content.sections[0].rows[0].offersMoveHere == false)
    #expect(model.canDetach(harness.key(on: host)))
    await model.shutdown()
  }

  /// "Show tab" is offered only for the app's own launch tab: a failure with no tab offers no
  /// "Show tab", and the model asks the coordinator only for ids its own updates gave.
  @Test func showTabOnlyForTheAppsLaunchTabs() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.configure { $0.createTabError = .createTabFailed(.invalidProfileName) }
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.activities[key]?.launchTabID == nil)
    model.showTab(for: key)
    #expect(model.showTabTasks.isEmpty)
    #expect(await harness.iTerm2.activations.isEmpty)
    await model.shutdown()
  }

  /// A failure shows its own message and recoveries; "Try again" repeats the attach.
  @Test func failureAndRetry() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.configure { $0.createTabError = .createTabFailed(.invalidProfileName) }
    model.open(key)
    #expect(await harness.waitForActions(1))
    let problem = model.activities[key]?.problem
    #expect(problem?.message == AttachFailure.iTerm2(.createTabFailed(.invalidProfileName)).message)
    #expect(problem?.recoveries == [.retry])
    await harness.iTerm2.configure { $0.createTabError = nil }
    model.perform(.retry, for: key)
    #expect(await harness.waitForActions(2))
    #expect(model.activities[key] == .confirmed)
    #expect(await harness.iTerm2.createTabCount == 2)
    await model.shutdown()
  } // End of func failureAndRetry()

  /// A missing helper is explained on the row, with nothing to retry; nothing is contacted.
  @Test func missingHelperIsExplained() async {
    let harness = await AttachHarness.make(failsToBuild: .notFound)
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    model.open(key)
    #expect(model.activities[key] == .failed(.unavailable(LaunchHelperPathError.notFound.message)))
    #expect(model.activities[key]?.problem?.recoveries == [])
    #expect(await harness.iTerm2.createTabCount == 0)
    await model.shutdown()
  }

  /// A session gone between the listing and Open gets a "vanished" banner, its row no failure,
  /// and its host is refreshed; a dismissed banner goes away.
  @Test func vanishedSessionBanner() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let host = harness.hosts[0]
    let key = harness.key(on: host)
    harness.discovery.setStatus(.noServer, for: host.id)
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.finishedActions[0].outcome.attachResult?.failure == .sessionGone)
    #expect(model.activities[key] == nil)
    #expect(model.banners.count == 1)
    let banner = model.banners[0]
    #expect(banner.kind == .vanished)
    #expect(banner.sessionName == "work-neptuno")
    #expect(banner.text.contains("ended before muxFinder could open it"))
    #expect(model.content.banners == model.banners)
    #expect(await Support.waitUntil { model.content.sections.first?.rows.isEmpty == true })
    #expect(await harness.iTerm2.createTabCount == 0)
    model.dismissBanner(banner.id)
    #expect(model.banners.isEmpty)
    await model.shutdown()
  } // End of func vanishedSessionBanner()

  /// A session whose id now names another session gets a "changed" banner.
  @Test func changedSessionBanner() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let host = harness.hosts[0]
    var changed = FakeDiscovery.session(on: host)
    changed.createdAt += 60
    harness.discovery.setStatus(.ok([changed]), for: host.id)
    model.open(changed.key)
    #expect(await harness.waitForActions(1))
    #expect(model.finishedActions[0].outcome.attachResult?.failure == .sessionChanged)
    #expect(model.banners.map(\.kind) == [.changed])
    #expect(model.banners[0].text.contains("changed since muxFinder listed it"))
    await model.shutdown()
  }

  /// Opening the popover again clears the results of the previous opening, not failures.
  @Test func popoverOpenClearsResults() async {
    let harness = await AttachHarness.make(hosts: [Support.localHost(), Support.sshHost("Sirio")])
    let model = harness.model
    let local = harness.key(on: harness.hosts[0])
    let remote = harness.key(on: harness.hosts[1])
    model.open(local)
    #expect(await harness.waitForActions(1))
    model.setActivity(.failed(SessionProblem(message: "No.")), for: remote)
    model.popoverDidOpen()
    #expect(model.activities[local] == nil)
    #expect(model.activities[remote]?.problem?.message == "No.")
    await model.shutdown()
  }

  /// A session open here whose tab the focus did not bring forward (iTerm2 refused the
  /// activation, or no tab of the connection appeared) never reads "Already open here — brought
  /// its tab forward": the row explains it with "Try again", the attachment is kept (Detach
  /// stays offered), and "Try again" focuses it again, still launching nothing.
  @Test func focusThatDidNotBringTheTabForward() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.addUserConnection("user-conn", owner: "user-tab", key: key)
    await harness.iTerm2.configure { $0.activationError = .activateFailed(.badIdentifier) }
    model.open(key)
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    let result = model.finishedActions[0].outcome.attachResult
    #expect(result?.isFocused == true)
    #expect(result?.activation == .failed(.activateFailed(.badIdentifier)))
    #expect(model.activities[key] == .failed(.notBroughtForward(.activateFailed(.badIdentifier))))
    #expect(model.activities[key]?.text != SessionActivity.focused.text)
    #expect(model.activities[key]?.problem?.recoveries == [.retry])
    #expect(model.attachedHere[key]?.gatewaySessionID == "user-tab")
    #expect(model.canDetach(key))

    await harness.iTerm2.configure {
      $0.activationError = nil
      $0.showsNoTabs = true
    }
    model.perform(.retry, for: key)
    #expect(await harness.waitForActions(2))
    #expect(model.finishedActions[1].outcome.attachResult?.activation == .noTab)
    #expect(model.activities[key] == .failed(.notBroughtForward(nil)))
    #expect(model.attachedHere[key] != nil)

    await harness.iTerm2.configure { $0.showsNoTabs = false }
    model.perform(.retry, for: key)
    #expect(await harness.waitForActions(3))
    #expect(model.activities[key] == .focused)
    #expect(await harness.iTerm2.createTabCount == 0)
    #expect(harness.store.written.isEmpty)
    await model.shutdown()
  } // End of func focusThatDidNotBringTheTabForward()

  /// Quitting while an attach waits for iTerm2 to answer its `CreateTab` (which cancelling
  /// cannot end, D15) stops Settings' probe and the engine at once instead of after the attach;
  /// `shutdown()` returns once its budget for the session actions has passed and reports the
  /// open still running; once iTerm2 answers, that attach withdraws its request, so nothing
  /// attaches, and nothing is sent to or closed in iTerm2.
  @Test func quitStopsTheRestWithoutWaitingForAnAttach() async throws {
    let settingsDiscovery = ScriptedDiscovery()
    let settingsStore = FakeHostListStore(Support.loaded([Support.sshHost("Saturno")]))
    let harness = await AttachHarness.make(
      attaches: false,
      settings: SettingsTestSupport.environment(store: settingsStore, discovery: settingsDiscovery),
      shutdownBudget: .milliseconds(300))
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    let engine = try #require(model.engine)
    await model.settings.windowDidOpen()
    settingsDiscovery.hold(cancellable: true)
    model.settings.testConnection()
    await settingsDiscovery.waitForCalls(1)
    await harness.iTerm2.configure { $0.holdsCreateTab = true }
    model.open(key)
    #expect(await Support.waitUntil { await harness.iTerm2.heldCreateTabCount == 1 })

    let returned = Counter()
    let shutdown = Task {
      let report = await model.shutdown()
      returned.increment()
      return report
    }
    #expect(await Support.waitUntil(timeout: .seconds(5)) { await engine.lifecycle == .stopped })
    #expect(await Support.waitUntil { await engine.liveTaskCount == 0 })
    #expect(await Support.waitUntil(timeout: .seconds(5)) { settingsDiscovery.cancellations == 1 })
    #expect(await Support.waitUntil(timeout: .seconds(5)) { returned.value == 1 })
    #expect(await harness.iTerm2.heldCreateTabCount == 1, "iTerm2 has not answered yet")
    await harness.iTerm2.releaseCreateTab()
    let report = await shutdown.value
    #expect(report.unfinishedActions == ["open"])
    #expect(!report.isComplete)
    #expect(model.lifecycle == .stopped)
    #expect(
      await Support.waitUntil {
        !harness.store.written.isEmpty && harness.store.discarded == harness.store.written.map(\.id)
      })
    #expect(await harness.iTerm2.sent.isEmpty)
    #expect(await harness.iTerm2.closeCount == 0)
    settingsDiscovery.release()
  } // End of func quitStopsTheRestWithoutWaitingForAnAttach()

  /// While a panel shows, the arrows, ⌘F and ⌘N do nothing and Esc closes the panel.
  @Test func keysWhileAPanelShows() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    model.newSession()
    #expect(model.panel == .newSession)
    let selection = model.selection
    #expect(model.handle(.down) == .handled)
    #expect(model.selection == selection)
    #expect(model.handle(.find) == .handled)
    #expect(model.searchFocusRequests == 0)
    #expect(model.handle(.newSession) == .handled)
    #expect(model.handle(.close) == .handled)
    #expect(model.panel == nil)
    await model.shutdown()
  }
}

/// The New session sheet (PLAN.md D18, D25): inline validation, creation through
/// `createAndAttach`, a collision with "Open existing".
@Suite("Session actions: new session")
@MainActor
struct NewSessionSheetTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// The created session's discovery entry and tmux record on `host`.
  static func created(_ name: String, id: Int, on host: HostConfig) -> (
    DiscoveredSession, CreatedSession
  ) {
    let discovered = PreviewFixtures.session(name, id: id, on: host, windows: 1).discovered
    let record = CreatedSession(
      server: discovered.key.server, sessionID: discovered.key.sessionID,
      createdAt: discovered.createdAt, name: name)
    return (discovered, record)
  }

  /// The sheet opens for This Mac; an empty or invalid name is reported inline and runs
  /// nothing; a valid name creates the session and attaches it, closing the sheet.
  @Test func validationThenCreation() async {
    let harness = await AttachHarness.make(hosts: [Support.sshHost("Saturno"), Support.localHost()])
    let model = harness.model
    let local = harness.hosts[1]
    model.newSession()
    #expect(model.panel == .newSession)
    #expect(model.newSessionDraft.hostID == local.id)
    #expect(model.newSessionHosts.map(\.id) == harness.hosts.map(\.id))
    #expect(model.newSessionDraft.nameIssue == nil)
    model.createSession()
    #expect(model.newSessionDraft.nameIssue == ValidationError.sessionNameEmpty.message)
    model.newSessionDraft.name = "logs:old"
    #expect(
      model.newSessionDraft.nameIssue == ValidationError.sessionNameContainsColonOrPeriod.message)
    model.newSessionDraft.directory = "bad\ndir"
    #expect(
      model.newSessionDraft.directoryIssue
        == ValidationError.workingDirectoryContainsLineBreak.message)
    model.createSession()
    #expect(model.newSessionDraft.state == .editing)
    #expect(harness.creator.requests.isEmpty)
    #expect(harness.builds.value == 0)

    let (discovered, record) = Self.created("fresh", id: 7, on: local)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: local), discovered]), for: local.id)
    harness.creator.script([.success(record)])
    model.newSessionDraft.name = " fresh "
    model.newSessionDraft.directory = "~/projects"
    #expect(model.newSessionDraft.nameIssue == nil)
    model.createSession()
    #expect(model.newSessionDraft.state == .creating)
    #expect(await harness.waitForActions(1))
    #expect(harness.creator.requests.map(\.name) == ["fresh"])
    #expect(harness.creator.requests.first?.workingDirectory == "~/projects")
    #expect(harness.creator.requests.first?.command == [])
    #expect(model.panel == nil)
    #expect(model.finishedActions[0].key == discovered.key)
    #expect(model.activities[discovered.key] == .confirmed)
    #expect(await harness.iTerm2.createTabCount == 1)
    #expect(
      await Support.waitUntil {
        model.content.sections[1].rows.contains { $0.key == discovered.key }
      })
    await model.shutdown()
  } // End of func validationThenCreation()

  /// A name that exists is refused as a collision, nothing launches, and "Open existing" opens
  /// the session with that name, once a fresh listing of the host shows it (the sheet looks for
  /// it meanwhile).
  @Test func collisionOffersOpenExisting() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let host = harness.hosts[0]
    let existing = FakeDiscovery.session(on: host)
    harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.newSession()
    model.newSessionDraft.name = existing.name
    model.createSession()
    #expect(await harness.waitForActions(1))
    #expect(model.newSessionDraft.state == .collision)
    #expect(model.panel == .newSession)
    #expect(model.newSessionDraft.stateMessage?.contains("already exists") == true)
    #expect(await harness.iTerm2.createTabCount == 0)
    model.openExisting()
    #expect(model.newSessionDraft.state == .findingExisting)
    #expect(model.newSessionDraft.isBusy)
    #expect(await Support.waitUntil { model.panel == nil })
    #expect(await harness.waitForActions(2))
    #expect(model.finishedActions[1].key == existing.key)
    #expect(model.activities[existing.key] == .confirmed)
    #expect(await harness.iTerm2.createTabCount == 1)
    await model.shutdown()
  } // End of func collisionOffersOpenExisting()

  /// "Open existing" for a session the popover does not list yet finds it in a fresh listing of
  /// the host and opens it; editing the name after a collision goes back to editing.
  @Test func openExistingFindsASessionNotListedYet() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let host = harness.hosts[0]
    harness.creator.script([.failure(.sessionExists(.duplicateSession))])
    model.newSession()
    model.newSessionDraft.name = "late"
    model.createSession()
    #expect(await harness.waitForActions(1))
    model.newSessionDraft.name = "late2"
    #expect(model.newSessionDraft.state == .editing)
    model.newSessionDraft.name = "late"
    model.createSession()
    #expect(await harness.waitForActions(2))
    #expect(model.newSessionDraft.state == .collision)
    let (late, _) = Self.created("late", id: 8, on: host)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: host), late]), for: host.id)
    model.openExisting()
    #expect(await Support.waitUntil { model.panel == nil })
    #expect(await harness.waitForActions(3))
    #expect(model.finishedActions[2].key == late.key)
    await model.shutdown()
  } // End of func openExistingFindsASessionNotListedYet()

  /// A New session's attach is its session's action as soon as the session was created: the
  /// sheet closes, the row follows the launch ("Still connecting — check the iTerm2 tab" for a
  /// remote tab still waiting, before the attach has ended), "Show tab" brings that launch tab
  /// forward, a click on the row meanwhile starts nothing, and quitting cancels the attach.
  @Test func newSessionAttachShowsProgressAndShowTab() async {
    let saturno = Support.sshHost("Saturno")
    let harness = await AttachHarness.make(
      hosts: [saturno], attaches: false, holdAfter: .seconds(25))
    let model = harness.model
    let (discovered, record) = Self.created("remote-work", id: 7, on: saturno)
    harness.discovery.setStatus(
      .ok([FakeDiscovery.session(on: saturno), discovered]), for: saturno.id)
    harness.creator.script([.success(record)])
    model.newSession()
    model.newSessionDraft.name = "remote-work"
    model.createSession()
    #expect(model.newSessionDraft.state == .creating)
    #expect(
      await Support.waitUntil {
        model.activities[discovered.key] == .stillConnecting(launchTabID: "gateway-1")
      })
    #expect(model.finishedActions.isEmpty)
    #expect(model.panel == nil)
    #expect(model.isPending(discovered.key))
    #expect(
      await Support.waitUntil {
        model.content.sections.first?.rows.first { $0.key == discovered.key }?.activity?.text
          == "Still connecting — check the iTerm2 tab"
      })
    model.open(discovered.key)
    model.showTab(for: discovered.key)
    #expect(await Support.waitUntil { await harness.iTerm2.activations.count == 1 })
    #expect(await harness.iTerm2.activations.first?.target == .session("gateway-1"))
    #expect(await harness.iTerm2.createTabCount == 1)
    model.newSession()
    #expect(model.newSessionDraft.name.isEmpty, "a fresh draft: the creation is over")
    model.cancelPanel()
    await model.shutdown()
    #expect(model.finishedActions.count == 1)
    #expect(model.finishedActions.first?.outcome.attachResult?.failure == .cancelled)
    #expect(await harness.iTerm2.createTabCount == 1)
    #expect(await harness.iTerm2.closeCount == 0)
  } // End of func newSessionAttachShowsProgressAndShowTab()

  /// The collision of `name` on `harness`'s first host, with the sheet left offering "Open
  /// existing".
  static func collide(_ name: String, in harness: AttachHarness) async {
    harness.creator.script([.failure(.sessionExists(.hasSession))])
    harness.model.newSession()
    harness.model.newSessionDraft.name = name
    harness.model.createSession()
    _ = await harness.waitForActions(1)
  }

  /// "Open existing" never trusts the popover's list: here the listed session was renamed and
  /// another one took its name (which is why tmux refused it), and the engine's list is not
  /// refreshed yet. A fresh listing of the host finds the session that has the name now, and
  /// that one is opened, not the listed one.
  @Test func openExistingResolvesTheNameAfresh() async {
    let host = Support.localHost()
    let fresh = FakeDiscovery()
    let harness = await AttachHarness.make(hosts: [host], attachDiscovery: fresh)
    let model = harness.model
    let listed = FakeDiscovery.session(on: host)
    var renamed = listed
    renamed.name = "old-work"
    let (taker, _) = Self.created(listed.name, id: 2, on: host)
    fresh.setStatus(.ok([renamed, taker]), for: host.id)
    await Self.collide(listed.name, in: harness)
    #expect(model.newSessionDraft.state == .collision)
    #expect(model.target(for: listed.key)?.session.name == listed.name, "the stale list")
    model.openExisting()
    #expect(model.newSessionDraft.state == .findingExisting)
    #expect(await harness.waitForActions(2))
    #expect(model.finishedActions[1].key == taker.key)
    #expect(model.finishedActions[1].outcome.attachResult?.isConfirmed == true)
    #expect(harness.store.written.map(\.sessionID) == [taker.key.sessionID])
    #expect(model.panel == nil)
    #expect(model.activities[taker.key] == .confirmed)
    #expect(model.activities[listed.key] == nil)
    await model.shutdown()
  } // End of func openExistingResolvesTheNameAfresh()

  /// When the fresh listing has no session with that exact name any more (the listed one was
  /// renamed and none took the name), "Open existing" says so in the sheet and opens, writes
  /// and launches nothing; a host that cannot be listed says that instead.
  @Test func openExistingOpensNothingWhenTheNameIsGone() async {
    let host = Support.localHost()
    let fresh = FakeDiscovery()
    let harness = await AttachHarness.make(hosts: [host], attachDiscovery: fresh)
    let model = harness.model
    let listed = FakeDiscovery.session(on: host)
    var renamed = listed
    renamed.name = "old-work"
    fresh.setStatus(.ok([renamed]), for: host.id)
    await Self.collide(listed.name, in: harness)
    model.openExisting()
    #expect(await Support.waitUntil { model.newSessionDraft.state != .findingExisting })
    #expect(model.newSessionDraft.state == .failed(NewSessionDraft.existingGone))
    #expect(model.panel == .newSession)

    harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.createSession()
    #expect(await harness.waitForActions(2))
    fresh.setStatus(.authFailed, for: host.id)
    model.openExisting()
    #expect(await Support.waitUntil { model.newSessionDraft.state != .findingExisting })
    #expect(
      model.newSessionDraft.state
        == .failed(
          NewSessionDraft.existingNotListed(AttachFailure.discoveryFailed("authFailed").message)))
    #expect(model.finishedActions.count == 2)
    #expect(harness.store.written.isEmpty)
    #expect(await harness.iTerm2.createTabCount == 0)
    await model.shutdown()
  } // End of func openExistingOpensNothingWhenTheNameIsGone()

  /// A creation failure other than a collision stays in the sheet with its message.
  @Test func creationFailureStaysInTheSheet() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    harness.creator.script([.failure(.directoryMissing)])
    model.newSession()
    model.newSessionDraft.name = "work"
    model.newSessionDraft.directory = "/nonexistent"
    model.createSession()
    #expect(await harness.waitForActions(1))
    #expect(model.newSessionDraft.state == .failed(SessionCreationError.directoryMissing.message))
    #expect(model.panel == .newSession)
    model.newSessionDraft.directory = ""
    #expect(model.newSessionDraft.state == .editing)
    await model.shutdown()
  }
}

/// Every failure path has its own plain-English message (PLAN.md D25).
@Suite("Session actions: failure messages")
struct FailureMessageTests {
  /// One sample of every `AttachFailure` case; `caseIndex(_:)` makes the compiler insist on a
  /// sample for a new case.
  static let attachSamples: [AttachFailure] = [
    .invalidDestination(.sshDestinationEmpty), .sessionGone, .sessionChanged, .tmuxMissing,
    .discoveryFailed("unreachable"), .launchStore(.directoryMissing), .iTerm2(.notRunning),
    .helperFailed(.checkTimedOut), .helperEnded, .timedOut, .waitLimitReached,
    .identityCheckFailed(nil), .identityMismatch, .cancelled, .attachmentCheckFailed(.timedOut),
    .attachmentChanged, .moveHereNotConfirmed,
    .alreadyAttachedHere(connectionID: "c", owningSessionID: "o"),
    .possiblyAttachedHere(unresolved: 1), .earlierLaunchPending,
  ]

  /// The case's position, exhaustively.
  static func caseIndex(_ failure: AttachFailure) -> Int {
    switch failure {
    case .invalidDestination: return 0
    case .sessionGone: return 1
    case .sessionChanged: return 2
    case .tmuxMissing: return 3
    case .discoveryFailed: return 4
    case .launchStore: return 5
    case .iTerm2: return 6
    case .helperFailed: return 7
    case .helperEnded: return 8
    case .timedOut: return 9
    case .waitLimitReached: return 10
    case .identityCheckFailed: return 11
    case .identityMismatch: return 12
    case .cancelled: return 13
    case .attachmentCheckFailed: return 14
    case .attachmentChanged: return 15
    case .moveHereNotConfirmed: return 16
    case .alreadyAttachedHere: return 17
    case .possiblyAttachedHere: return 18
    case .earlierLaunchPending: return 19
    }
  } // End of static func caseIndex(_:)

  /// Every message: each attach failure's, each detach outcome but `detached`, the Show tab
  /// notes, the missing helper's, the two focuses that did not bring the tab forward, and the
  /// two "Open existing" outcomes that open nothing.
  static var allMessages: [String] {
    let key = PreviewFixtures.session("s", id: 1, on: PreviewFixtures.neptuno, windows: 1).key
    let attach = attachSamples.map { SessionProblem.attach($0, launchTab: "tab").message }
    let detach = SessionDetachResult.Outcome.allCases.compactMap {
      SessionProblem.detach(
        SessionDetachResult(key: key, outcome: $0, checkFailure: .attachmentCheckFailed(.timedOut)))?
        .message
    }
    let notes = [
      SessionProblem.showTabNote(.notOpenedHere), SessionProblem.showTabNote(.failed(.timedOut)),
    ].compactMap { $0 }
    let focus = [
      SessionProblem.notBroughtForward(nil).message,
      SessionProblem.notBroughtForward(.activateFailed(.badIdentifier)).message,
    ]
    let openExisting = [
      NewSessionDraft.existingGone,
      NewSessionDraft.existingNotListed(AttachFailure.discoveryFailed("unreachable").message),
    ]
    return attach + detach + notes + [LaunchHelperPathError.notFound.message] + focus
      + openExisting
  } // End of static var allMessages

  /// The samples cover every case, and every message is distinct from every other.
  @Test func messagesArePairwiseDistinct() {
    #expect(Set(Self.attachSamples.map(Self.caseIndex)).count == 20)
    let messages = Self.allMessages
    #expect(messages.count == 20 + 5 + 2 + 1 + 2 + 2)
    for (offset, message) in messages.enumerated() {
      for other in messages[(offset + 1)...] {
        #expect(message != other)
      }
    }
  }

  /// Messages are sentences: a capital or a product name first, a full stop last.
  @Test func messagesAreSentences() {
    for message in Self.allMessages {
      let first = message.first.map(String.init) ?? ""
      #expect(
        first == first.uppercased() || message.hasPrefix("muxFinder") || message.hasPrefix("iTerm2")
          || message.hasPrefix("ssh") || message.hasPrefix("tmux"), "\(message)")
      #expect(message.hasSuffix("."), "\(message)")
    }
  }

  /// The session-action fixtures show every state: each progress and result, every attach
  /// failure but the three a banner covers, every detach problem, both focuses that did not
  /// bring the tab forward, both panels with the sheet's states, and both banners; all from
  /// synthetic data.
  @Test func attachFixturesCoverEveryState() {
    let fixtures = AttachFixtures.all
    let activities = fixtures.flatMap { $0.activities.values }
    let problems = Set(activities.compactMap(\.problem?.message))
    #expect(problems.count == 17 + 1 + 5 + 2)
    #expect(problems.contains(SessionProblem.notBroughtForward(nil).message))
    #expect(
      problems.contains(SessionProblem.notBroughtForward(.activateFailed(.badIdentifier)).message))
    let shown: [SessionActivity] = [
      .opening, .movingHere, .waitingForITerm2, .confirmed, .focused, .detaching, .detached,
    ]
    for activity in shown { #expect(activities.contains(activity), "\(activity)") }
    #expect(activities.contains { if case .stillConnecting = $0 { true } else { false } })
    #expect(fixtures.contains { if case .moveHere = $0.panel { true } else { false } })
    let sheets = fixtures.filter { $0.panel == .newSession }.map(\.newSessionDraft)
    #expect(Set(sheets.map(\.state)) == [.editing, .creating, .collision])
    #expect(sheets.contains { $0.nameIssue != nil })
    #expect(Set(fixtures.flatMap(\.banners).map(\.kind)) == [.vanished, .changed])
    #expect(Set(fixtures.map(\.id)).count == fixtures.count)
    let hosts = fixtures.compactMap(\.state).flatMap(\.hosts).map(\.host)
    #expect(hosts.filter { $0.mode == .ssh }.allSatisfy { $0.sshDestination.hasSuffix(".example") })
    #expect(AttachFixtures.menuRows.map(\.offersDetach) == [true, false])
  } // End of func attachFixturesCoverEveryState()

  /// Every failure that has a sensible recovery offers one; a tab that explains more gets
  /// "Show tab"; vanished and changed sessions get banners.
  @Test func recoveries() {
    #expect(SessionProblem.attach(.timedOut, launchTab: "t").recoveries == [.showTab("t"), .retry])
    #expect(SessionProblem.attach(.timedOut).recoveries == [.retry])
    #expect(SessionProblem.attach(.waitLimitReached, launchTab: "t").recoveries == [.showTab("t")])
    #expect(SessionProblem.attach(.tmuxMissing).recoveries == [.openSettings, .retry])
    #expect(SessionProblem.attach(.iTerm2(.automationDenied)).fixIt == .openAutomationSettings)
    #expect(
      SessionProblem.attach(.helperFailed(.sshFailed(.authFailed)), launchTab: "t").message
        .contains("shown in the tab"))
    for failure in Self.attachSamples {
      let problem = SessionProblem.attach(failure)
      #expect(!problem.recoveries.isEmpty, "\(failure.kind)")
      #expect((SessionBanner.kind(for: failure) != nil) == failure.triggersRefresh)
    }
    #expect(SessionActivity.stillConnecting(launchTabID: "t").launchTabID == "t")
    #expect(SessionActivity(.stillWaiting(sessionID: "t")) == .stillConnecting(launchTabID: "t"))
    #expect(SessionActivity(.confirmed(connectionID: "c")) == .confirmed)
    #expect(SessionActivity(.requested, movingHere: true) == .movingHere)
  } // End of func recoveries()
}
