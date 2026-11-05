import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// A click on a session switcher row (PLAN.md D32, Phase I-5): one click activates it as Return
/// does, as a click on a popover row does, through the real `AppModel`, the real engine and the
/// real `AttachCoordinator` over fakes (`AttachHarness`); a second activation of a row already
/// opening, or of New session while its window shows, starts nothing new; the rest of the
/// clicking sequence is let through to no view of the switcher or of the New session window it
/// opened (`SwitcherClickSequence`, PLAN.md D34); and only a click holds the real controller's
/// panel through the double-click interval, a focus's success close and the New session
/// window's opening close waiting for its end (Phase I-5 review). Nothing runs a process, opens
/// a socket or contacts iTerm2.
@Suite("Session switcher clicks")
@MainActor
struct SwitcherClickTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// The switcher's real controller over fakes (a 300-point content), wired to a model as the
  /// app wires it (`SwitcherController.make`).
  @MainActor
  struct Wired {
    /// The controller.
    let switcher: SwitcherController
    /// Its panel.
    let panel: PopoverControllerTests.FakePanel
    /// Its system (the double-click interval and the delayed actions).
    let system: SwitcherControllerTests.FakeSystem

    /// Wires a controller to `model` and opens the switcher as the shortcut does.
    static func make(for model: AppModel) -> Wired {
      let panel = PopoverControllerTests.FakePanel()
      panel.naturalSize = CGSize(width: 540, height: 300)
      let system = SwitcherControllerTests.FakeSystem()
      let switcher = SwitcherController.make(for: model, panel: panel, system: system.system)
      switcher.toggle()
      return Wired(switcher: switcher, panel: panel, system: system)
    }
  }

  /// A started model over This Mac and Saturno (one session each: `work-neptuno`,
  /// `work-saturno`), its switcher open.
  static func openSwitcher() async -> AttachHarness {
    let harness = await AttachHarness.make(
      hosts: [Support.localHost(), Support.sshHost("Saturno")])
    harness.model.switcherVisibilityChanged(true)
    return harness
  }

  // MARK: - One click activates

  /// A click on Saturno's row while This Mac's is selected selects it and starts the same Open
  /// as Return (the popover's Open, followed by the switcher, closing it on success); the row
  /// clicked is the one showing "Opening…".
  @Test func aClickOnASessionOpensItAsReturnDoes() async throws {
    let harness = await Self.openSwitcher()
    let model = harness.model
    var closes: [SwitcherController.CloseReason] = []
    model.closeSwitcher = { closes.append($0) }
    let keys = harness.hosts.map { harness.key(on: $0) }
    #expect(model.switcherContent.selection == .session(keys[0]))
    model.clickSwitcherItem(.session(keys[1]))
    #expect(model.switcherSelection == .session(keys[1]))
    #expect(model.selection == keys[1])
    let row = try #require(model.switcherContent.rows.first { $0.key == keys[1] })
    #expect(row.isSelected && row.activity == .opening)
    #expect(model.runningActions[keys[1]]?.kind == .open && model.runningActions.count == 1)
    #expect(model.lastActions[keys[1]] == .open)
    #expect(model.switcherActions[keys[1]] == .running(closesOnSuccess: true))
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.activities[keys[1]] == .confirmed)
    #expect(await harness.iTerm2.createTabCount == 1)
    #expect(closes == [.actionSucceeded])
    await model.shutdown()
  } // End of func aClickOnASessionOpensItAsReturnDoes()

  /// A click on the New session row opens the New session window with the draft ⌘N gives:
  /// named from the filter when the row offers it, for This Mac, and with no filter an empty
  /// name; the row is selected first. (Each opening here follows a Cancel, so the draft is a
  /// fresh one; the switcher stays open in this model, which has no controller.)
  @Test func aClickOnNewSessionOpensTheWindowAsCommandNDoes() async {
    let harness = await Self.openSwitcher()
    let model = harness.model
    model.switcherSearchText = "deploy-docs"
    #expect(model.handleSwitcherKey(.newSession) == .handled)
    #expect(model.isNewSessionShown)
    let fromCommandN = model.newSessionDraft
    #expect(fromCommandN.name == "deploy-docs" && fromCommandN.hostID == harness.hosts[0].id)
    model.newSessionDraft.name = "edited"
    model.closeNewSession()
    #expect(!model.isNewSessionShown)
    model.clickSwitcherItem(.newSession)
    #expect(model.switcherSelection == .newSession)
    #expect(model.isNewSessionShown && model.panel == nil)
    #expect(model.newSessionDraft == fromCommandN)
    model.closeNewSession()
    model.switcherSearchText = ""
    _ = model.handleSwitcherKey(.newSession)
    let emptyFromCommandN = model.newSessionDraft
    model.closeNewSession()
    model.clickSwitcherItem(.newSession)
    #expect(model.isNewSessionShown && model.newSessionDraft == emptyFromCommandN)
    #expect(model.newSessionDraft.name.isEmpty)
    #expect(model.runningActions.isEmpty)
    await model.shutdown()
  } // End of func aClickOnNewSessionOpensTheWindowAsCommandNDoes()

  // MARK: - A second activation

  /// A second click on a row already opening (at once, and again once iTerm2 was asked for the
  /// launch tab), Return and the accessibility action on it start nothing: one Open, one launch
  /// tab (PLAN.md D25's in-flight rule).
  @Test func aSecondActivationOfARowOpeningStartsNothing() async {
    let harness = await Self.openSwitcher()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.configure { $0.holdsCreateTab = true }
    model.clickSwitcherItem(.session(key))
    model.clickSwitcherItem(.session(key))
    #expect(model.runningActions.count == 1 && model.activities[key] == .opening)
    #expect(await Support.waitUntil { await harness.iTerm2.heldCreateTabCount == 1 })
    model.clickSwitcherItem(.session(key))
    #expect(model.handleSwitcherKey(.open) == .handled)
    model.activateSwitcherItem(.session(key))
    #expect(model.runningActions.count == 1)
    #expect(await harness.iTerm2.heldCreateTabCount == 1)
    await harness.iTerm2.releaseCreateTab()
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .confirmed)
    #expect(model.finishedActions.count == 1 && model.runningActions.isEmpty)
    #expect(await harness.iTerm2.createTabCount == 1)
    await model.shutdown()
  } // End of func aSecondActivationOfARowOpeningStartsNothing()

  /// Activating New session again while its window shows (a second click, had it reached the
  /// row) only brings the window forward, its draft as the user left it.
  @Test func aSecondActivationOfNewSessionLeavesTheDraft() async {
    let harness = await Self.openSwitcher()
    let model = harness.model
    model.switcherSearchText = "deploy-docs"
    model.clickSwitcherItem(.newSession)
    #expect(model.newSessionDraft.name == "deploy-docs")
    model.newSessionDraft.name = "deploy-docs-2"
    model.clickSwitcherItem(.newSession)
    model.activateSwitcherItem(.newSession)
    model.newSessionFromSwitcher()
    #expect(model.isNewSessionShown)
    #expect(model.newSessionWindow.request?.kind == .open(source: nil))
    #expect(model.newSessionDraft.name == "deploy-docs-2")
    #expect(model.newSessionDraft.state == .editing && model.creation == nil)
    await model.shutdown()
  } // End of func aSecondActivationOfNewSessionLeavesTheDraft()

  // MARK: - The rest of the click sequence

  /// After a click activated a row, the rest of its sequence (a double or triple click's later
  /// presses, their drags and releases) passes to no view; the next sequence passes, a double
  /// click in it included (a word selected in the name field).
  @Test func theRestOfAnActivatingClickIsIgnored() {
    var clicks = SwitcherClickSequence()
    #expect(Self.passed([.press(clickCount: 1), .release], &clicks) == [true, true])
    clicks.rowActivated()
    #expect(clicks.ignoresRest)
    let rest = Self.passed(
      [.press(clickCount: 2), .drag, .release, .press(clickCount: 3), .release], &clicks)
    #expect(rest == [false, false, false, false, false])
    #expect(Self.passed([.press(clickCount: 1)], &clicks) == [true])
    #expect(!clicks.ignoresRest)
    let next = Self.passed([.drag, .release, .press(clickCount: 2), .release], &clicks)
    #expect(next == [true, true, true, true])
  } // End of func theRestOfAnActivatingClickIsIgnored()

  /// A row activated while its press is still down keeps that press's drags and release; the
  /// sequence's next press is ignored.
  @Test func aRowActivatedOnThePressKeepsItsRelease() {
    var clicks = SwitcherClickSequence()
    #expect(Self.passed([.press(clickCount: 1)], &clicks) == [true])
    clicks.rowActivated()
    let rest = Self.passed([.drag, .release, .press(clickCount: 2), .release], &clicks)
    #expect(rest == [true, true, false, false])
  }

  /// What `clicks` lets through of `events`, in order.
  static func passed(
    _ events: [SwitcherClickSequence.Event], _ clicks: inout SwitcherClickSequence
  ) -> [Bool] {
    events.map { clicks.passes($0) }
  }

  /// Only a click arms the switcher's filter (Return and the accessibility action do not), and
  /// each closing and opening of the switcher forgets it.
  @Test func onlyAClickIgnoresTheRestOfItsSequence() async {
    let harness = await Self.openSwitcher()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    model.switcherSearchText = "deploy-docs"
    _ = model.handleSwitcherKey(.open)
    #expect(model.isNewSessionShown)
    #expect(model.switcherPasses(.press(clickCount: 2)) && model.switcherPasses(.release))
    model.closeNewSession()
    model.activateSwitcherItem(.newSession)
    #expect(model.switcherPasses(.press(clickCount: 2)) && model.switcherPasses(.release))
    model.closeNewSession()
    model.clickSwitcherItem(.newSession)
    #expect(!model.switcherPasses(.press(clickCount: 2)) && !model.switcherPasses(.release))
    model.switcherVisibilityChanged(false)
    model.switcherVisibilityChanged(true)
    #expect(model.switcherPasses(.press(clickCount: 2)) && model.switcherPasses(.release))
    await harness.iTerm2.configure { $0.holdsCreateTab = true }
    model.clickSwitcherItem(.session(key))
    model.switcherVisibilityChanged(false)
    #expect(model.switcherPasses(.press(clickCount: 2)))
    await harness.iTerm2.releaseCreateTab()
    #expect(await harness.waitForActions(1))
    await model.shutdown()
  } // End of func onlyAClickIgnoresTheRestOfItsSequence()

  // MARK: - The panel held through the double-click interval (Phase I-5 review)

  /// Only a click holds the panel: ⌘N, the accessibility action and Return hold nothing (the
  /// New session window's opening and the success of Return's Open close the switcher at
  /// once); a click on "New session…" opens the window and holds the switcher at its height for
  /// the system's double-click interval, its close for the window's opening waiting for the
  /// interval's end (PLAN.md D34).
  @Test func onlyAClickHoldsThePanel() async {
    let harness = await AttachHarness.make(
      hosts: [Support.localHost(), Support.sshHost("Saturno")])
    let model = harness.model
    let wired = Wired.make(for: model)
    #expect(model.isSwitcherVisible)
    _ = model.handleSwitcherKey(.newSession)
    #expect(model.isNewSessionShown && !model.isSwitcherVisible)
    #expect(wired.switcher.lastCloseReason == .newSessionOpened)
    model.closeNewSession()
    wired.switcher.toggle()
    model.activateSwitcherItem(.newSession)
    #expect(!wired.switcher.isOpen && wired.switcher.lastCloseReason == .newSessionOpened)
    model.closeNewSession()
    #expect(!wired.switcher.isHoldingForClick && wired.system.delayed.isEmpty)
    #expect(wired.panel.minimumContentHeight == nil)
    wired.switcher.toggle()
    model.switcherSelection = .session(harness.key(on: harness.hosts[0]))
    _ = model.handleSwitcherKey(.open)
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.activities[harness.key(on: harness.hosts[0])] == .confirmed)
    #expect(!wired.switcher.isOpen && wired.switcher.lastCloseReason == .actionSucceeded)
    #expect(wired.system.delayed.isEmpty)
    wired.switcher.toggle()
    model.clickSwitcherItem(.newSession)
    #expect(model.isNewSessionShown)
    #expect(wired.switcher.isHoldingForClick && wired.panel.minimumContentHeight == 300)
    #expect(wired.switcher.isOpen && wired.switcher.pendingClose == .newSessionOpened)
    #expect(wired.system.delays == [0.42])
    #expect(!model.switcherPasses(.press(clickCount: 2)))
    #expect(!model.newSessionWindowPasses(.press(clickCount: 2)))
    wired.system.runDelayed()
    #expect(!wired.switcher.isOpen && wired.switcher.lastCloseReason == .newSessionOpened)
    #expect(model.isNewSessionShown)
    await model.shutdown()
  } // End of func onlyAClickHoldsThePanel()

  /// A click on a session already open in iTerm2 here focuses it, and the success comes within
  /// the double-click interval: the switcher stays open (so a second click lands on it, never
  /// on iTerm2's window) until the interval ends, then closes for the success, and the engine
  /// hears one opened and one closed (PLAN.md D22); Return on it closes at once.
  @Test func aFocusAfterAClickClosesOnceTheIntervalEnds() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    let key = harness.key(on: harness.hosts[0])
    await harness.iTerm2.addUserConnection("user-conn", owner: "user-tab", key: key)
    let wired = Wired.make(for: model)
    model.clickSwitcherItem(.session(key))
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .focused)
    #expect(await harness.iTerm2.focusedConnections == ["user-conn"])
    #expect(wired.switcher.isOpen && model.isSwitcherVisible)
    #expect(wired.switcher.pendingClose == .actionSucceeded)
    #expect(model.engineVisibilityChanges == [true])
    wired.system.runDelayed()
    #expect(!wired.switcher.isOpen && wired.switcher.lastCloseReason == .actionSucceeded)
    #expect(!model.isSwitcherVisible && model.engineVisibilityChanges == [true, false])
    wired.switcher.toggle()
    _ = model.handleSwitcherKey(.open)
    #expect(await harness.waitForActions(2))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .focused)
    #expect(!wired.switcher.isOpen && wired.system.delayed.isEmpty)
    #expect(model.engineVisibilityChanges == [true, false, true, false])
    await model.shutdown()
  } // End of func aFocusAfterAClickClosesOnceTheIntervalEnds()
}
