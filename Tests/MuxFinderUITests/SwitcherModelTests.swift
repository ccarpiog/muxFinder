import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// The session switcher in the app model (PLAN.md D32, Phase I-3b), through the real
/// `AppModel`, the real engine and the real `AttachCoordinator` over fakes (`AttachHarness`):
/// its keys, its selection across refreshes, the actions it starts (success closes it, a
/// failure stays or is carried to its next opening and the popover row, a pinned row the engine
/// does not list opens through its retained target, a creation failure Move here held back
/// shows later), the visibility rule shared with the popover (the status item handoff in either
/// order included), and the glue from the fake registrar's press to the switcher's toggle.
/// Nothing runs a process,
/// opens a socket, registers a hotkey or contacts iTerm2.
@Suite("Session switcher in the app")
@MainActor
struct SwitcherModelTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// A started model over This Mac and Saturno (one session each: `work-neptuno`,
  /// `work-saturno`).
  static func harness() async -> AttachHarness {
    await AttachHarness.make(hosts: [Support.localHost(), Support.sshHost("Saturno")])
  }

  /// A model with a shortcut environment over `registrar` holding ⌃⌥Space.
  static func shortcutModel(_ registrar: FakeHotkeyRegistrar) -> AppModel {
    GlobalShortcutAppTests.appModel(
      registrar: registrar,
      store: InMemoryPreferencesStore(
        Preferences(globalShortcut: ShortcutTestSupport.controlOptionSpace)))
  }

  /// A started model over This Mac and Saturno whose open switcher pins a session New session
  /// just created on This Mac (`x1`), with its attach's failure: the engine never listed it,
  /// and the coordinator's own discovery (the returned one) found This Mac unreachable when it
  /// revalidated the session. Returns the harness, that discovery and the session.
  static func failedPinnedCreation() async -> (AttachHarness, FakeDiscovery, DiscoveredSession) {
    let attachDiscovery = FakeDiscovery()
    let harness = await AttachHarness.make(
      hosts: [Support.localHost(), Support.sshHost("Saturno")], attachDiscovery: attachDiscovery)
    let model = harness.model
    let local = harness.hosts[0]
    let (discovered, record) = NewSessionSheetTests.created("x1", id: 7, on: local)
    harness.creator.script([.success(record)])
    attachDiscovery.setStatus(.unreachable(.timeout), for: local.id)
    model.switcherVisibilityChanged(true)
    model.switcherSearchText = "x1"
    _ = model.handleSwitcherKey(.newSession)
    _ = model.handleSwitcherKey(.open)
    _ = await harness.waitForActions(1)
    await model.sessionEventsHandled()
    return (harness, attachDiscovery, discovered)
  } // End of static func failedPinnedCreation()

  /// The model's switcher after the user started a New session in it that will fail with a
  /// collision, went back to the list, closed the switcher, opened the popover and asked to
  /// move This Mac's session here; returns once the creation failed, the Move here
  /// confirmation still showing.
  static func creationFailedDuringMoveHere(_ harness: AttachHarness) async {
    let model = harness.model
    harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.switcherVisibilityChanged(true)
    model.switcherSearchText = "taken-name"
    _ = model.handleSwitcherKey(.newSession)
    _ = model.handleSwitcherKey(.open)
    _ = model.handleSwitcherKey(.close)
    model.switcherVisibilityChanged(false)
    model.popoverVisibilityChanged(true)
    model.requestMoveHere(harness.key(on: harness.hosts[0]))
    _ = await harness.waitForActions(1)
    await model.sessionEventsHandled()
  } // End of static func creationFailedDuringMoveHere(_:)

  /// Whether `model`'s panel is a Move here confirmation.
  static func showsMoveHere(_ model: AppModel) -> Bool {
    if case .moveHere? = model.panel { return true }
    return false
  }

  /// Both real controllers over fakes, wired to one started model as `MenuBarPopover` and
  /// `SessionSwitcher` wire them (the popover's close and its status item press check).
  @MainActor
  struct Handoff {
    /// The model.
    let model: AppModel
    /// The popover's controller.
    let popover: PopoverController
    /// The switcher's controller.
    let switcher: SwitcherController
    /// The popover's system (presses, the pointer, the clock).
    let system: PopoverControllerTests.FakeSystem

    /// Builds and starts it.
    static func make() async -> Handoff {
      let model = AppModel(
        environment: Support.environment(load: { Support.loaded([Support.localHost()]) }))
      let system = PopoverControllerTests.FakeSystem()
      let popover = PopoverController(
        panel: PopoverControllerTests.FakePanel(), button: PopoverControllerTests.FakeButton(),
        system: system.system,
        onVisibilityChange: { [weak model] in model?.popoverVisibilityChanged($0) })
      model.closePopover = { [weak popover] in popover?.close(.switcherOpened) }
      model.isStatusItemPressHeld = { [weak popover] in popover?.isButtonPressHeld ?? false }
      let switcher = SwitcherController.make(
        for: model, panel: PopoverControllerTests.FakePanel(),
        system: SwitcherControllerTests.FakeSystem().system)
      await model.start()
      return Handoff(model: model, popover: popover, switcher: switcher, system: system)
    } // End of static func make()

    /// A new mouse press at `location`, held: its effects follow.
    func press(at location: CGPoint) {
      system.now += 1
      system.pressCount += 1
      system.press = location
      system.held = location
    }
  }

  // MARK: - Keys

  /// ↑/↓ move through the sessions and New session without wrapping; typing selects the first
  /// row again; ⌥↓ goes on to the focused view.
  @Test func arrowsMoveWithoutWrapping() async {
    let harness = await Self.harness()
    let model = harness.model
    model.switcherVisibilityChanged(true)
    let keys = harness.hosts.map { harness.key(on: $0) }
    #expect(model.switcherContent.items == [.session(keys[0]), .session(keys[1]), .newSession])
    #expect(model.handleSwitcherKey(.up) == .handled)
    #expect(model.switcherContent.selection == .session(keys[0]))
    for _ in 0..<4 { #expect(model.handleSwitcherKey(.down) == .handled) }
    #expect(model.switcherContent.selection == .newSession)
    _ = model.handleSwitcherKey(.up)
    #expect(model.switcherContent.selection == .session(keys[1]))
    model.switcherSearchText = "work"
    #expect(model.switcherSelection == .session(keys[0]))
    #expect(model.switcherContent.selection == .session(keys[0]))
    #expect(model.handleSwitcherKey(.openList) == .ignored)
    await model.shutdown()
  } // End of func arrowsMoveWithoutWrapping()

  /// A refresh that lists a new session above the row the switcher selected by itself (at its
  /// opening, then after the filter changed) leaves the selection, and Return's target, on that
  /// row (Phase I-3b review).
  @Test func aRefreshKeepsTheAutomaticSelection() async {
    let harness = await Self.harness()
    let model = harness.model
    let local = harness.hosts[0]
    let work = harness.key(on: local)
    model.switcherVisibilityChanged(true)
    #expect(model.switcherContent.selection == .session(work))
    let alpha = PreviewFixtures.session("alpha", id: 2, on: local, windows: 1).discovered
    harness.discovery.setStatus(.ok([alpha, FakeDiscovery.session(on: local)]), for: local.id)
    model.refresh()
    #expect(await Support.waitUntil { model.switcherContent.rows.count == 3 })
    #expect(model.switcherContent.rows.first?.key == alpha.key)
    #expect(model.switcherContent.selection == .session(work))
    model.switcherSearchText = "work"
    #expect(model.switcherContent.selection == .session(work))
    let early = PreviewFixtures.session("work-early", id: 3, on: local, windows: 1).discovered
    harness.discovery.setStatus(
      .ok([early, alpha, FakeDiscovery.session(on: local)]), for: local.id)
    model.refresh()
    #expect(await Support.waitUntil { model.switcherContent.rows.count == 3 })
    #expect(model.switcherContent.rows.first?.key == early.key)
    #expect(model.switcherContent.selection == .session(work))
    #expect(model.handleSwitcherKey(.open) == .handled)
    #expect(model.isPending(work) && !model.isPending(early.key))
    await model.shutdown()
  } // End of func aRefreshKeepsTheAutomaticSelection()

  /// Return on a session opens it as the popover's Open does; the switcher follows the action
  /// and its success closes the switcher.
  @Test func returnOpensTheSessionAndSuccessCloses() async {
    let harness = await Self.harness()
    let model = harness.model
    var closes: [SwitcherController.CloseReason] = []
    model.closeSwitcher = { closes.append($0) }
    model.switcherVisibilityChanged(true)
    let key = harness.key(on: harness.hosts[1])
    _ = model.handleSwitcherKey(.down)
    #expect(model.handleSwitcherKey(.open) == .handled)
    #expect(model.switcherActions[key] == .running(closesOnSuccess: true))
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .confirmed)
    #expect(await harness.iTerm2.createTabCount == 1)
    #expect(closes == [.actionSucceeded])
    #expect(model.switcherActions.isEmpty && model.switcherTargets.isEmpty)
    await model.shutdown()
  } // End of func returnOpensTheSessionAndSuccessCloses()

  /// Return on the New session row shows the form with the filter's name, for This Mac; Esc
  /// goes back to the list (the search field asked for the focus), and Esc in the list closes
  /// the switcher.
  @Test func returnOnNewSessionShowsTheFormAndEscGoesBack() async {
    let harness = await Self.harness()
    let model = harness.model
    model.switcherVisibilityChanged(true)
    model.switcherSearchText = "deploy-docs"
    #expect(model.switcherContent.items == [.newSession])
    #expect(model.handleSwitcherKey(.open) == .handled)
    #expect(model.switcherShowsNewSession)
    #expect(model.newSessionDraft.name == "deploy-docs")
    #expect(model.newSessionDraft.hostID == harness.hosts[0].id)
    let focus = model.switcherFocusRequests
    #expect(model.handleSwitcherKey(.close) == .handled)
    #expect(!model.switcherShowsNewSession && model.switcherFocusRequests == focus + 1)
    #expect(model.handleSwitcherKey(.close) == .closePopover)
    await model.shutdown()
  } // End of func returnOnNewSessionShowsTheFormAndEscGoesBack()

  /// ⌘N shows the form (empty without a filter, named from it with one); in the form ⌥↓ opens
  /// the directory list and Esc closes the list before the form; Return creates, the creation
  /// is the switcher's, and its attach's success closes the switcher.
  @Test func commandNAndTheFormsKeys() async {
    let harness = await Self.harness()
    let model = harness.model
    model.switcherVisibilityChanged(true)
    #expect(model.handleSwitcherKey(.newSession) == .handled)
    #expect(model.switcherShowsNewSession && model.newSessionDraft.name.isEmpty)
    #expect(model.handleSwitcherKey(.openList) == .handled)
    #expect(model.directoryPicker.isOpen)
    #expect(model.handleSwitcherKey(.close) == .handled)
    #expect(!model.directoryPicker.isOpen && model.switcherShowsNewSession)
    #expect(model.handleSwitcherKey(.newSession) == .handled)
    _ = model.handleSwitcherKey(.close)
    model.switcherSearchText = "x1"
    _ = model.handleSwitcherKey(.newSession)
    #expect(model.newSessionDraft.name == "x1")
    var closes: [SwitcherController.CloseReason] = []
    model.closeSwitcher = { closes.append($0) }
    let local = harness.hosts[0]
    let (discovered, record) = NewSessionSheetTests.created("x1", id: 7, on: local)
    harness.discovery.setStatus(.ok([FakeDiscovery.session(on: local), discovered]), for: local.id)
    harness.creator.script([.success(record)])
    #expect(model.handleSwitcherKey(.open) == .handled)
    #expect(model.newSessionDraft.state == .creating)
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.activities[discovered.key] == .confirmed)
    #expect(!model.switcherShowsNewSession)
    #expect(closes == [.actionSucceeded])
    await model.shutdown()
  } // End of func commandNAndTheFormsKeys()

  /// ⌘R refreshes every host, ⌘, opens Settings, ⌘F asks for the search field's focus.
  @Test func refreshSettingsAndFind() async throws {
    let discovery = FakeDiscovery()
    let host = Support.localHost()
    var environment = Support.environment(load: { Support.loaded([host]) }, discovery: discovery)
    let presented = Counter()
    environment.presentSettings = { _ in presented.increment() }
    let model = AppModel(environment: environment)
    await model.start()
    let engine = try #require(model.engine)
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    model.switcherVisibilityChanged(true)
    await model.engineRequestsHandled()
    #expect(await Support.waitUntil { await Support.isSettled(engine) })
    let calls = discovery.calls(of: host.id)
    #expect(model.handleSwitcherKey(.refresh) == .handled)
    #expect(await Support.waitUntil { discovery.calls(of: host.id) > calls })
    #expect(model.handleSwitcherKey(.settings) == .handled)
    #expect(presented.value == 1)
    let focus = model.switcherFocusRequests
    #expect(model.handleSwitcherKey(.find) == .handled)
    #expect(model.switcherFocusRequests == focus + 1)
    await model.shutdown()
  } // End of func refreshSettingsAndFind()

  // MARK: - Failures

  /// An Open that fails after the switcher closed shows on the popover row and at the top of the
  /// switcher's next opening (selected, with its recoveries), once: after that opening closes
  /// it is back in its place, still failed.
  @Test func aFailureAfterThePanelClosedShowsAtTheNextOpening() async {
    let harness = await Self.harness()
    let model = harness.model
    let key = harness.key(on: harness.hosts[1])
    await harness.iTerm2.configure {
      $0.holdsCreateTab = true
      $0.createTabError = .apiDisabled
    }
    model.switcherVisibilityChanged(true)
    model.activateSwitcherItem(.session(key))
    #expect(await Support.waitUntil { await harness.iTerm2.heldCreateTabCount == 1 })
    model.switcherVisibilityChanged(false)
    #expect(model.switcherActions[key] == .running(closesOnSuccess: false))
    await harness.iTerm2.releaseCreateTab()
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.switcherCarriedFailures == [key])
    let popoverRow = model.content.sections.flatMap(\.rows).first { $0.key == key }
    #expect(popoverRow?.activity?.problem != nil)
    model.switcherVisibilityChanged(true)
    let content = model.switcherContent
    #expect(content.pinned.map(\.key) == [key])
    #expect(!content.rows.contains { $0.key == key })
    #expect(content.selection == .session(key))
    #expect(content.pinned.first?.activity == popoverRow?.activity)
    model.switcherVisibilityChanged(false)
    #expect(model.switcherCarriedFailures.isEmpty && model.switcherTargets.isEmpty)
    model.switcherVisibilityChanged(true)
    #expect(model.switcherContent.pinned.isEmpty)
    #expect(model.switcherContent.rows.first { $0.key == key }?.activity?.problem != nil)
    await model.shutdown()
  } // End of func aFailureAfterThePanelClosedShowsAtTheNextOpening()

  /// An Open that fails while the switcher shows leaves it open with the failure on the row
  /// (nothing carried); closing it lets the failure go from the switcher's following.
  @Test func aFailureWhileShownStaysOnItsRow() async {
    let harness = await Self.harness()
    let model = harness.model
    var closes: [SwitcherController.CloseReason] = []
    model.closeSwitcher = { closes.append($0) }
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.configure { $0.createTabError = .apiDisabled }
    model.switcherVisibilityChanged(true)
    #expect(model.handleSwitcherKey(.open) == .handled)
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(closes.isEmpty)
    #expect(model.switcherActions[key] == .failedWhileShown)
    #expect(model.switcherContent.rows.first?.activity?.problem != nil)
    #expect(model.switcherCarriedFailures.isEmpty)
    model.switcherVisibilityChanged(false)
    #expect(model.switcherActions.isEmpty)
    await model.shutdown()
  } // End of func aFailureWhileShownStaysOnItsRow()

  /// A creation that fails after the user left the form (and closed the switcher) puts the
  /// form back with its failure, so the next opening shows it.
  @Test func aCreationFailureBringsTheFormBack() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.switcherVisibilityChanged(true)
    model.switcherSearchText = "taken-name"
    _ = model.handleSwitcherKey(.newSession)
    #expect(model.handleSwitcherKey(.open) == .handled)
    #expect(model.newSessionDraft.state == .creating)
    _ = model.handleSwitcherKey(.close)
    model.switcherVisibilityChanged(false)
    #expect(!model.switcherShowsNewSession)
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.switcherShowsNewSession && model.newSessionDraft.state == .collision)
    model.switcherVisibilityChanged(true)
    #expect(model.switcherShowsNewSession && model.newSessionDraft.name == "taken-name")
    await model.shutdown()
  } // End of func aCreationFailureBringsTheFormBack()

  /// A switcher creation that fails while the popover shows Move here: the confirmation stays
  /// as it is, and once it ends (Cancel) the form comes back with the failure (Phase I-3b
  /// review).
  @Test func aCreationFailureHeldBackByMoveHereShowsOnceItEnds() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    await Self.creationFailedDuringMoveHere(harness)
    #expect(model.finishedActions.count == 1)
    #expect(Self.showsMoveHere(model) && model.newSessionDraft.state == .collision)
    model.cancelPanel()
    #expect(model.panel == .newSession)
    #expect(model.newSessionDraft.name == "taken-name")
    #expect(model.newSessionDraft.state == .collision)
    await model.shutdown()
  } // End of func aCreationFailureHeldBackByMoveHereShowsOnceItEnds()

  /// The same failure while the Move here confirmation still waits when the switcher opens
  /// next (the popover closed meanwhile): the switcher shows the form with the failure, and the
  /// unconfirmed Move here closes having run nothing (Phase I-3b review).
  @Test func aCreationFailureHeldBackByMoveHereShowsAtTheNextOpening() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    await Self.creationFailedDuringMoveHere(harness)
    #expect(Self.showsMoveHere(model))
    model.popoverVisibilityChanged(false)
    model.switcherVisibilityChanged(true)
    #expect(model.switcherShowsNewSession)
    #expect(model.newSessionDraft.name == "taken-name")
    #expect(model.newSessionDraft.state == .collision)
    #expect(model.finishedActions.count == 1 && model.runningActions.isEmpty)
    await model.shutdown()
  } // End of func aCreationFailureHeldBackByMoveHereShowsAtTheNextOpening()

  /// A session New session created whose attach failed before the engine listed it (This Mac
  /// stopped answering): its pinned row's "Try again" attaches it through its retained target
  /// on its host as enabled now, revalidated by the coordinator, and the success closes the
  /// switcher (Phase I-3b review).
  @Test func aPinnedRetryAttachesThroughItsRetainedTarget() async throws {
    let (harness, attachDiscovery, created) = await Self.failedPinnedCreation()
    let model = harness.model
    var closes: [SwitcherController.CloseReason] = []
    model.closeSwitcher = { closes.append($0) }
    let key = created.key
    #expect(model.target(for: key) == nil)
    #expect(model.switcherActions[key] == .failedWhileShown)
    #expect(model.switcherContent.pinned.map(\.key) == [key])
    #expect(model.activities[key]?.problem?.recoveries == [.retry])
    let local = harness.hosts[0]
    attachDiscovery.setStatus(.ok([FakeDiscovery.session(on: local), created]), for: local.id)
    model.perform(.retry, for: key)
    try #require(model.isPending(key))
    #expect(model.switcherContent.pinned.first?.activity == .opening)
    #expect(await harness.waitForActions(2))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .confirmed)
    #expect(await harness.iTerm2.createTabCount == 1)
    #expect(closes == [.actionSucceeded])
    await model.shutdown()
  } // End of func aPinnedRetryAttachesThroughItsRetainedTarget()

  /// The same pinned row once its host was turned off: "Try again" and Return show on the row
  /// that the host is no longer turned on (never nothing) and open nothing; the message is a
  /// sentence of its own (Phase I-3b review).
  @Test func aPinnedRetryOnAHostTurnedOffShowsWhy() async throws {
    let (harness, _, created) = await Self.failedPinnedCreation()
    let model = harness.model
    let key = created.key
    var off = harness.hosts[0]
    off.isEnabled = false
    model.hostListSaved(try HostList([off, harness.hosts[1]]))
    #expect(await Support.waitUntil { model.refreshState?.hosts.count == 1 })
    model.perform(.retry, for: key)
    #expect(!model.isPending(key))
    try #require(model.activities[key] == .failed(.hostNotTurnedOn))
    #expect(model.switcherContent.pinned.map(\.key) == [key])
    #expect(model.switcherContent.pinned.first?.activity == .failed(.hostNotTurnedOn))
    model.activateSwitcherItem(.session(key))
    #expect(model.activities[key] == .failed(.hostNotTurnedOn) && !model.isPending(key))
    #expect(await harness.iTerm2.createTabCount == 0)
    let message = SessionProblem.hostNotTurnedOn.message
    #expect(!FailureMessageTests.allMessages.contains(message))
    #expect(message.first?.isUppercase == true && message.hasSuffix("."))
    await model.shutdown()
  } // End of func aPinnedRetryOnAHostTurnedOffShowsWhy()

  // MARK: - Visibility and the hotkey

  /// The popover, then the switcher, then both, then neither: the engine hears one opened and
  /// one closed; opening one asks the other to close; repeated reports change nothing.
  @Test func visibilityRuleCombinesThePopoverAndTheSwitcher() async {
    let model = AppModel(
      environment: Support.environment(load: { Support.loaded([Support.localHost()]) }))
    var popoverCloses = 0
    var switcherCloses: [SwitcherController.CloseReason] = []
    model.closePopover = { popoverCloses += 1 }
    model.closeSwitcher = { switcherCloses.append($0) }
    await model.start()
    model.popoverVisibilityChanged(true)
    #expect(model.engineVisibilityChanges == [true])
    #expect(await Support.waitUntil { model.refreshState?.isPopoverVisible == true })
    model.switcherVisibilityChanged(true)
    #expect(popoverCloses == 1)
    model.popoverVisibilityChanged(false)
    #expect(model.engineVisibilityChanges == [true] && model.isSessionListVisible)
    model.popoverVisibilityChanged(true)
    #expect(switcherCloses == [.popoverOpened])
    #expect(model.isPopoverVisible && model.isSwitcherVisible)
    model.switcherVisibilityChanged(false)
    #expect(model.engineVisibilityChanges == [true])
    model.popoverVisibilityChanged(false)
    #expect(model.engineVisibilityChanges == [true, false] && !model.isSessionListVisible)
    #expect(await Support.waitUntil { model.refreshState?.isPopoverVisible == false })
    model.switcherVisibilityChanged(true)
    model.switcherVisibilityChanged(true)
    model.switcherVisibilityChanged(false)
    model.switcherVisibilityChanged(false)
    #expect(model.engineVisibilityChanges == [true, false, true, false])
    #expect(popoverCloses == 1 && switcherCloses == [.popoverOpened])
    await model.shutdown()
  } // End of func visibilityRuleCombinesThePopoverAndTheSwitcher()

  /// With both real controllers over fakes: the status item button opens the popover, the
  /// hotkey then opens the switcher and closes the popover, the button closes the switcher; the
  /// engine hears one opened and one closed.
  @Test func openingOneClosesTheOther() async {
    let registrar = FakeHotkeyRegistrar()
    let model = Self.shortcutModel(registrar)
    let popoverSystem = PopoverControllerTests.FakeSystem()
    let popover = PopoverController(
      panel: PopoverControllerTests.FakePanel(), button: PopoverControllerTests.FakeButton(),
      system: popoverSystem.system,
      onVisibilityChange: { [weak model] in model?.popoverVisibilityChanged($0) })
    model.closePopover = { [weak popover] in popover?.close(.switcherOpened) }
    let switcher = SwitcherController.make(
      for: model, panel: PopoverControllerTests.FakePanel(),
      system: SwitcherControllerTests.FakeSystem().system)
    await model.start()
    popover.buttonPressed()
    #expect(popover.isOpen && model.isPopoverVisible)
    registrar.press(ShortcutTestSupport.controlOptionSpace)
    #expect(switcher.isOpen && model.isSwitcherVisible)
    #expect(!popover.isOpen && popover.lastCloseReason == .switcherOpened)
    #expect(!model.isPopoverVisible)
    popoverSystem.now += 1
    popover.buttonPressed()
    #expect(popover.isOpen && !switcher.isOpen && switcher.lastCloseReason == .popoverOpened)
    popover.close(.escape)
    #expect(model.engineVisibilityChanges == [true, false])
    await model.shutdown()
  } // End of func openingOneClosesTheOther()

  /// A press on muxFinder's status item while the switcher shows, its close from outside
  /// first (the switcher resigning key, the press seen by another process), then its button
  /// action: the switcher stays until the popover the action opens closes it, so the engine
  /// hears no closed and opened pair for the handoff; a later press elsewhere still closes the
  /// switcher, and every real change of "either one is visible" is one change (Phase I-3b
  /// review).
  @Test func statusItemHandoffWithTheOutsideCloseFirst() async {
    let handoff = await Handoff.make()
    let (model, popover, switcher) = (handoff.model, handoff.popover, handoff.switcher)
    switcher.toggle()
    #expect(model.engineVisibilityChanges == [true])
    handoff.press(at: PopoverControllerTests.icon)
    #expect(popover.isButtonPressHeld)
    switcher.close(.resignedKey)
    switcher.close(.pressOutside)
    #expect(switcher.isOpen && model.isSwitcherVisible)
    #expect(model.engineVisibilityChanges == [true])
    popover.buttonPressed()
    #expect(popover.isOpen && !switcher.isOpen)
    #expect(switcher.lastCloseReason == .popoverOpened)
    popover.close(.resignedKey)
    #expect(popover.isOpen && model.engineVisibilityChanges == [true])
    handoff.system.held = nil
    popover.close(.escape)
    #expect(model.engineVisibilityChanges == [true, false])
    switcher.toggle()
    handoff.press(at: CGPoint(x: 600, y: 900))
    #expect(!popover.isButtonPressHeld)
    switcher.close(.pressOutside)
    #expect(!switcher.isOpen && switcher.lastCloseReason == .pressOutside)
    #expect(model.engineVisibilityChanges == [true, false, true, false])
    await model.shutdown()
  } // End of func statusItemHandoffWithTheOutsideCloseFirst()

  /// The same press, its button action first: the popover opens and closes the switcher, the
  /// press's closes from outside then change nothing, and the engine hears no closed and opened
  /// pair; a press on the status item while the popover is open still closes it (PLAN.md D30),
  /// one change (Phase I-3b review).
  @Test func statusItemHandoffWithTheButtonActionFirst() async {
    let handoff = await Handoff.make()
    let (model, popover, switcher) = (handoff.model, handoff.popover, handoff.switcher)
    switcher.toggle()
    handoff.press(at: PopoverControllerTests.icon)
    popover.buttonPressed()
    #expect(popover.isOpen && !switcher.isOpen)
    #expect(switcher.lastCloseReason == .popoverOpened)
    switcher.close(.resignedKey)
    popover.close(.resignedKey)
    popover.close(.pressOutside)
    #expect(popover.isOpen && model.isPopoverVisible && !model.isSwitcherVisible)
    #expect(model.engineVisibilityChanges == [true])
    handoff.press(at: PopoverControllerTests.icon)
    popover.buttonPressed()
    #expect(!popover.isOpen && popover.lastCloseReason == .button)
    #expect(model.engineVisibilityChanges == [true, false])
    await model.shutdown()
  } // End of func statusItemHandoffWithTheButtonActionFirst()

  /// The fake registrar's press reaches the switcher through `globalShortcutPressed()`: it
  /// opens with an empty, focused search field and closes on the next press; after quitting,
  /// nothing is registered.
  @Test func theHotkeyTogglesTheSwitcher() async {
    let registrar = FakeHotkeyRegistrar()
    let model = Self.shortcutModel(registrar)
    let panel = PopoverControllerTests.FakePanel()
    let switcher = SwitcherController.make(
      for: model, panel: panel, system: SwitcherControllerTests.FakeSystem().system)
    await model.start()
    model.switcherSearchText = "left over"
    #expect(registrar.press(ShortcutTestSupport.controlOptionSpace))
    #expect(switcher.isOpen && model.isSwitcherVisible && panel.isShown)
    #expect(model.switcherSearchText.isEmpty && model.switcherFocusRequests == 1)
    #expect(model.engineVisibilityChanges == [true])
    registrar.press(ShortcutTestSupport.controlOptionSpace)
    #expect(!switcher.isOpen && switcher.lastCloseReason == .shortcut)
    #expect(!model.isSwitcherVisible && model.engineVisibilityChanges == [true, false])
    await model.shutdown()
    #expect(!registrar.press(ShortcutTestSupport.controlOptionSpace))
  } // End of func theHotkeyTogglesTheSwitcher()
}
