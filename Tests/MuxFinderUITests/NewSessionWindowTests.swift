import AppKit
import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// New session in its own window (PLAN.md D34), through the real `AppModel`, the real engine
/// and the real `AttachCoordinator` over fakes (`AttachHarness`), with the real popover,
/// switcher and window controllers over fake surfaces wired as the app wires them: opening
/// from the popover and from the switcher (both close, the window shows, the switcher's name
/// fills only a fresh draft), opening again (forward, draft and frame kept), the endings
/// (Cancel, Esc, the close button drop the draft; a success closes; a collision or failure
/// stays, and one that ends after the window was closed brings it back, not key), a Move here
/// confirmation at the same time, the popover and the switcher leaving the window alone, the
/// window's keys and click filter, and the placement as a pure function. Nothing runs a
/// process, opens a socket, shows a window or contacts iTerm2.
@Suite("New session window")
@MainActor
struct NewSessionWindowTests {
  /// Shorthand.
  typealias Support = UITestSupport
  /// Shorthand.
  typealias Placement = NewSessionWindowPlacement

  /// One showing of the fake window.
  struct Show: Equatable {
    /// Where.
    var frame: CGRect
    /// Whether it was made key.
    var makingKey: Bool
  }

  /// The New session window as its controller drives it: a fixed size; records each showing.
  final class FakeWindow: NewSessionWindowSurface {
    /// The window's frame size for its content.
    var fittingFrameSize = CGSize(width: 540, height: 300)
    /// The frame now (a test may move it, as the user would).
    var frame: CGRect = .zero
    /// Whether it shows.
    private(set) var isShown = false
    /// Every showing, in order.
    private(set) var shows: [Show] = []
    /// Every frame it was resized to.
    private(set) var setFrames: [CGRect] = []
    /// How many times it was hidden.
    private(set) var hideCount = 0

    /// Shows at `frame`.
    func show(at frame: CGRect, makingKey: Bool) {
      self.frame = frame
      isShown = true
      shows.append(Show(frame: frame, makingKey: makingKey))
    }

    /// Records the frame.
    func setFrame(_ frame: CGRect) {
      self.frame = frame
      setFrames.append(frame)
    }

    /// Hides.
    func hide() {
      isShown = false
      hideCount += 1
    }
  } // End of class FakeWindow

  /// A started model with the popover's, the switcher's and the window's real controllers over
  /// fakes, wired as `MenuBarPopover`, `SessionSwitcher` and `NewSessionWindow` wire them.
  @MainActor
  struct Wired {
    /// The model and its fakes.
    let harness: AttachHarness
    /// The popover's controller.
    let popover: PopoverController
    /// The popover's system (presses, the clock).
    let popoverSystem: PopoverControllerTests.FakeSystem
    /// The switcher's controller.
    let switcher: SwitcherController
    /// The switcher's system (its delayed actions).
    let switcherSystem: SwitcherControllerTests.FakeSystem
    /// The New session window's controller.
    let controller: NewSessionWindowController
    /// The New session window.
    let window: FakeWindow

    /// The model.
    var model: AppModel { harness.model }

    /// Builds and starts it over This Mac and Saturno; `attachDiscovery` gives the coordinator
    /// a discovery of its own (`AttachHarness.make`).
    static func make(attachDiscovery: FakeDiscovery? = nil) async -> Wired {
      let harness = await AttachHarness.make(
        hosts: [Support.localHost(), Support.sshHost("Saturno")], attachDiscovery: attachDiscovery)
      let model = harness.model
      let popoverSystem = PopoverControllerTests.FakeSystem()
      let popover = PopoverController(
        panel: PopoverControllerTests.FakePanel(), button: PopoverControllerTests.FakeButton(),
        system: popoverSystem.system,
        onVisibilityChange: { [weak model] in model?.popoverVisibilityChanged($0) })
      model.closePopover = { [weak popover] reason in popover?.close(reason) }
      model.popoverSource = { [weak popover] in popover?.newSessionSource }
      let switcherSystem = SwitcherControllerTests.FakeSystem()
      let switcherPanel = PopoverControllerTests.FakePanel()
      switcherPanel.naturalSize = CGSize(width: 540, height: 300)
      let switcher = SwitcherController.make(
        for: model, panel: switcherPanel, system: switcherSystem.system)
      let window = FakeWindow()
      let controller = NewSessionWindowController.make(
        for: model, surface: window, screens: { PopoverAnchoringTests.screens })
      return Wired(
        harness: harness, popover: popover, popoverSystem: popoverSystem, switcher: switcher,
        switcherSystem: switcherSystem, controller: controller, window: window)
    } // End of static func make()

    /// A mouse press on muxFinder's menu bar icon: the popover opens below it (or closes).
    func pressIcon() {
      popoverSystem.now += 1
      popoverSystem.pressCount += 1
      popoverSystem.press = PopoverControllerTests.icon
      popoverSystem.held = PopoverControllerTests.icon
      popover.buttonPressed()
      popoverSystem.held = nil
    }
  } // End of struct Wired

  /// The top centre of `frame`.
  static func topCentre(_ frame: CGRect) -> CGPoint {
    CGPoint(x: frame.midX, y: frame.maxY)
  }

  /// Whether `model`'s popover shows a Move here confirmation.
  static func showsMoveHere(_ model: AppModel) -> Bool {
    if case .moveHere? = model.panel { return true }
    return false
  }

  // MARK: - Opening

  /// From the popover (⌘N, the footer's button): the popover closes, the window shows, key,
  /// its top centre at the popover's, with a fresh draft for This Mac and the Name field asked
  /// for the focus; the switcher is never involved.
  @Test func openingFromThePopover() async throws {
    let wired = await Wired.make()
    let model = wired.model
    wired.pressIcon()
    let popoverFrame = try #require(wired.popover.placement?.frame)
    #expect(model.isPopoverVisible)
    let focus = model.newSessionFocusRequests
    #expect(model.handle(.newSession) == .handled)
    #expect(!wired.popover.isOpen && wired.popover.lastCloseReason == .newSessionOpened)
    #expect(!model.isPopoverVisible && model.isNewSessionShown)
    #expect(wired.window.isShown && wired.window.shows.count == 1)
    let shown = try #require(wired.window.shows.first)
    #expect(shown.makingKey)
    #expect(Self.topCentre(shown.frame) == Self.topCentre(popoverFrame))
    #expect(shown.frame.size == wired.window.fittingFrameSize)
    #expect(model.newSessionDraft == NewSessionDraft(hostID: wired.harness.hosts[0].id))
    #expect(model.newSessionFocusRequests == focus + 1)
    #expect(model.newSessionOrigin == .popover)
    #expect(!wired.switcher.isOpen)
    await model.shutdown()
  } // End of func openingFromThePopover()

  /// From the switcher (⌘N, the New session row): the switcher closes, the window shows, key,
  /// its top centre at the switcher's, the name filled in from the filter; a later opening from
  /// the switcher with another filter brings the window forward and never overwrites the draft.
  @Test func openingFromTheSwitcherPrefillsOnlyAFreshDraft() async throws {
    let wired = await Wired.make()
    let model = wired.model
    wired.switcher.toggle()
    let switcherFrame = try #require(wired.switcher.frame)
    model.switcherSearchText = "deploy-docs"
    #expect(model.handleSwitcherKey(.newSession) == .handled)
    #expect(!wired.switcher.isOpen && wired.switcher.lastCloseReason == .newSessionOpened)
    #expect(!model.isSwitcherVisible && model.isNewSessionShown)
    let shown = try #require(wired.window.shows.last)
    #expect(shown.makingKey)
    #expect(Self.topCentre(shown.frame) == Self.topCentre(switcherFrame))
    #expect(model.newSessionDraft.name == "deploy-docs")
    #expect(model.newSessionDraft.hostID == wired.harness.hosts[0].id)
    #expect(model.newSessionOrigin == .switcher)
    model.newSessionDraft.name = "mine"
    wired.switcher.toggle()
    #expect(model.isNewSessionShown, "the switcher opening leaves the window")
    model.switcherSearchText = "other-name"
    model.activateSwitcherItem(.newSession)
    #expect(model.newSessionDraft.name == "mine")
    #expect(wired.window.shows.count == 2 && wired.window.shows.last?.makingKey == true)
    #expect(wired.window.shows.last?.frame == shown.frame)
    model.closeNewSession()
    wired.switcher.toggle()
    model.switcherSearchText = "other-name"
    _ = model.handleSwitcherKey(.newSession)
    #expect(model.newSessionDraft.name == "other-name", "a fresh draft takes the filter's name")
    await model.shutdown()
  } // End of func openingFromTheSwitcherPrefillsOnlyAFreshDraft()

  /// Opening again while the window shows (from either entry point) brings it forward, key, at
  /// the frame the user moved it to, its draft and its directory list as they are; the Name
  /// field is not asked for the focus again.
  @Test func openingAgainBringsItForwardWithItsDraft() async {
    let wired = await Wired.make()
    let model = wired.model
    wired.pressIcon()
    model.newSession()
    model.newSessionDraft.name = "half-typed"
    model.newSessionDraft.directory = "~/projects"
    model.openDirectoryList(highlightingFirst: false)
    let moved = CGRect(x: 200, y: 300, width: 540, height: 300)
    wired.window.frame = moved
    let focus = model.newSessionFocusRequests
    wired.pressIcon()
    model.newSession()
    #expect(!wired.popover.isOpen)
    #expect(wired.window.shows.last == Show(frame: moved, makingKey: true))
    #expect(model.newSessionDraft.name == "half-typed")
    #expect(model.newSessionDraft.directory == "~/projects")
    #expect(model.directoryPicker.isOpen)
    #expect(model.newSessionFocusRequests == focus)
    wired.switcher.toggle()
    model.newSessionFromSwitcher()
    #expect(!wired.switcher.isOpen)
    #expect(wired.window.shows.last == Show(frame: moved, makingKey: true))
    #expect(wired.window.shows.count == 3 && wired.window.hideCount == 0)
    #expect(model.newSessionDraft.name == "half-typed")
    await model.shutdown()
  } // End of func openingAgainBringsItForwardWithItsDraft()

  // MARK: - Ending

  /// Cancel, Esc (once the directory list closed: the first Esc closes only the list) and the
  /// close button (the panel's close, which ⌘W reaches too) each close the window and drop the
  /// draft: the next opening starts a fresh one.
  @Test func cancelEscAndCloseDropTheDraft() async {
    _ = NSApplication.shared
    let wired = await Wired.make()
    let model = wired.model
    let panel = NewSessionPanel(contentView: NSView())
    panel.closeRequest = { [weak model] in model?.closeNewSession() }
    let endings: [(String, @MainActor () -> Void)] = [
      ("Cancel", { model.closeNewSession() }),
      (
        "Esc",
        {
          #expect(model.handleNewSessionKey(.close) == .handled)
          #expect(model.isNewSessionShown && !model.directoryPicker.isOpen)
          #expect(model.handleNewSessionKey(.close) == .handled)
        }
      ),
      ("close button", { panel.close() }),
    ]
    for (number, (name, end)) in endings.enumerated() {
      model.newSession()
      #expect(model.newSessionDraft.name.isEmpty, "\(name): a fresh draft")
      model.newSessionDraft.name = "draft-\(number)"
      model.newSessionDraft.directory = "~/projects"
      model.openDirectoryList(highlightingFirst: false)
      end()
      #expect(!model.isNewSessionShown && !model.directoryPicker.isOpen, "\(name)")
      #expect(!wired.window.isShown && wired.window.hideCount == number + 1, "\(name)")
    } // End of loop over the endings
    model.newSession()
    #expect(model.newSessionDraft == NewSessionDraft(hostID: wired.harness.hosts[0].id))
    #expect(panel.isVisible == false)
    await model.shutdown()
  } // End of func cancelEscAndCloseDropTheDraft()

  /// A creation in progress keeps its draft when the window closes: opening it again shows that
  /// draft busy (no fresh draft, no prefill), and its success closes the window, the attach
  /// going on on its row.
  @Test func aRunningCreationKeepsItsDraftAndSuccessCloses() async {
    let wired = await Wired.make()
    let model = wired.model
    let local = wired.harness.hosts[0]
    let (discovered, record) = NewSessionSheetTests.created("fresh", id: 7, on: local)
    wired.harness.discovery.setStatus(
      .ok([FakeDiscovery.session(on: local), discovered]), for: local.id)
    wired.harness.creator.script([.success(record)])
    model.newSession()
    model.newSessionDraft.name = "fresh"
    #expect(model.handleNewSessionKey(.open) == .handled)
    #expect(model.newSessionDraft.state == .creating)
    model.closeNewSession()
    #expect(!wired.window.isShown)
    wired.switcher.toggle()
    model.switcherSearchText = "elsewhere"
    model.newSessionFromSwitcher()
    #expect(model.isNewSessionShown && model.newSessionDraft.name == "fresh")
    #expect(model.newSessionDraft.isBusy)
    #expect(await wired.harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(!model.isNewSessionShown && !wired.window.isShown)
    #expect(model.activities[discovered.key] == .confirmed)
    await model.shutdown()
  } // End of func aRunningCreationKeepsItsDraftAndSuccessCloses()

  /// A collision and a failure while the window shows stay in it ("Open existing" for the
  /// collision); nothing is shown again.
  @Test func aCollisionAndAFailureStayInTheWindow() async {
    let wired = await Wired.make()
    let model = wired.model
    wired.harness.creator.script([
      .failure(.sessionExists(.hasSession)), .failure(.directoryMissing),
    ])
    model.newSession()
    model.newSessionDraft.name = "taken"
    _ = model.handleNewSessionKey(.open)
    #expect(await wired.harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.isNewSessionShown && model.newSessionDraft.state == .collision)
    model.newSessionDraft.name = "other"
    _ = model.handleNewSessionKey(.open)
    #expect(await wired.harness.waitForActions(2))
    await model.sessionEventsHandled()
    #expect(model.newSessionDraft.state == .failed(SessionCreationError.directoryMissing.message))
    #expect(model.isNewSessionShown && wired.window.isShown)
    #expect(wired.window.shows.count == 1 && wired.window.hideCount == 0)
    await model.shutdown()
  } // End of func aCollisionAndAFailureStayInTheWindow()

  /// A collision and a failure that end after the window was closed during the creation bring
  /// it back with the draft as submitted and the outcome, in front at its last frame and not
  /// key, whichever entry point opened it; "Open existing" then works from it.
  @Test(arguments: [NewSessionOrigin.popover, .switcher])
  func aFailureAfterClosingBringsTheWindowBack(_ origin: NewSessionOrigin) async {
    let wired = await Wired.make()
    let model = wired.model
    let outcomes: [(SessionCreationError, NewSessionDraft.State)] = [
      (.sessionExists(.hasSession), .collision),
      (.directoryMissing, .failed(SessionCreationError.directoryMissing.message)),
    ]
    for (number, (failure, state)) in outcomes.enumerated() {
      wired.harness.creator.script([.failure(failure)])
      if origin == .popover {
        wired.pressIcon()
        model.newSession()
      } else {
        wired.switcher.toggle()
        model.newSessionFromSwitcher()
      }
      #expect(model.newSessionOrigin == origin)
      model.newSessionDraft.name = "submitted-\(number)"
      let moved = CGRect(x: 400 + CGFloat(number) * 10, y: 500, width: 540, height: 300)
      wired.window.frame = moved
      _ = model.handleNewSessionKey(.open)
      _ = model.handleNewSessionKey(.close)
      #expect(!model.isNewSessionShown && !wired.window.isShown)
      #expect(await wired.harness.waitForActions(number + 1))
      await model.sessionEventsHandled()
      #expect(model.isNewSessionShown && model.newSessionWindow.request?.kind == .outcome)
      #expect(wired.window.shows.last == Show(frame: moved, makingKey: false))
      #expect(model.newSessionDraft.name == "submitted-\(number)")
      #expect(model.newSessionDraft.state == state)
      model.closeNewSession()
    } // End of loop over the outcomes
    #expect(model.switcherCreation == nil)
    await model.shutdown()
  } // End of func aFailureAfterClosingBringsTheWindowBack(_:)

  /// The window comes back with a collision even while the popover shows a Move here
  /// confirmation, which stays; "Open existing" in it then opens the session.
  @Test func aFailureAfterClosingIsNotHeldBackByMoveHere() async {
    let wired = await Wired.make()
    let model = wired.model
    let key = wired.harness.key(on: wired.harness.hosts[0])
    wired.harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.newSession()
    model.newSessionDraft.name = FakeDiscovery.session(on: wired.harness.hosts[0]).name
    _ = model.handleNewSessionKey(.open)
    model.closeNewSession()
    wired.pressIcon()
    model.requestMoveHere(wired.harness.key(on: wired.harness.hosts[1]))
    #expect(await wired.harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.isNewSessionShown && model.newSessionDraft.state == .collision)
    #expect(Self.showsMoveHere(model) && wired.popover.isOpen)
    model.openExisting()
    #expect(await wired.harness.waitForActions(2))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .confirmed && !model.isNewSessionShown)
    #expect(Self.showsMoveHere(model))
    await model.shutdown()
  } // End of func aFailureAfterClosingIsNotHeldBackByMoveHere()

  /// "Open existing" from a draft the switcher made is the switcher's to follow although the
  /// switcher closed as the window opened (Phase I-9a review): its target is retained, so with
  /// the engine not listing the session (only the coordinator's own discovery does) its failure
  /// is carried to the top of the switcher's next opening, pinned and selected, and Return there
  /// opens it through that target, the success closing the switcher. From a draft the popover
  /// made the switcher follows nothing: nothing is retained, carried or pinned.
  @Test(arguments: [NewSessionOrigin.popover, .switcher])
  func openExistingIsFollowedByTheDraftsSwitcher(_ origin: NewSessionOrigin) async throws {
    let attachDiscovery = FakeDiscovery()
    let wired = await Wired.make(attachDiscovery: attachDiscovery)
    let model = wired.model
    let iTerm2 = wired.harness.iTerm2
    let local = wired.harness.hosts[0]
    let (existing, _) = NewSessionSheetTests.created("taken", id: 7, on: local)
    let key = existing.key
    attachDiscovery.setStatus(.ok([FakeDiscovery.session(on: local), existing]), for: local.id)
    wired.harness.creator.script([.failure(.sessionExists(.hasSession))])
    await iTerm2.configure {
      $0.holdsCreateTab = true
      $0.createTabError = .apiDisabled
    }
    if origin == .popover {
      wired.pressIcon()
      model.newSession()
    } else {
      wired.switcher.toggle()
      model.newSessionFromSwitcher()
    }
    #expect(!wired.switcher.isOpen && !model.isSwitcherVisible)
    model.newSessionDraft.name = "taken"
    _ = model.handleNewSessionKey(.open)
    #expect(await wired.harness.waitForActions(1))
    await model.sessionEventsHandled()
    try #require(model.newSessionDraft.state == .collision)
    model.openExisting()
    #expect(await Support.waitUntil { await iTerm2.heldCreateTabCount == 1 })
    #expect(!model.isNewSessionShown && model.isPending(key) && model.target(for: key) == nil)
    let followed = origin == .switcher
    #expect(
      model.switcherActions[key] == (followed ? .running(closesOnSuccess: false) : nil),
      "\(origin)")
    #expect(model.switcherTargets[key]?.key == (followed ? key : nil), "\(origin)")
    await iTerm2.releaseCreateTab()
    #expect(await wired.harness.waitForActions(2))
    await model.sessionEventsHandled()
    #expect(model.activities[key]?.problem != nil)
    #expect(model.switcherCarriedFailures == (followed ? [key] : []), "\(origin)")
    await iTerm2.configure { $0.createTabError = nil }
    wired.switcher.toggle()
    let content = model.switcherContent
    #expect(content.pinned.map(\.key) == (followed ? [key] : []), "\(origin)")
    #expect(!content.rows.contains { $0.key == key })
    if followed {
      #expect(content.selection == .session(key))
      #expect(model.handleSwitcherKey(.open) == .handled)
      #expect(model.isPending(key))
      #expect(await wired.harness.waitForActions(3))
      await model.sessionEventsHandled()
      #expect(model.activities[key] == .confirmed)
      #expect(!wired.switcher.isOpen && wired.switcher.lastCloseReason == .actionSucceeded)
    } else {
      #expect(model.switcherActions.isEmpty && model.switcherTargets.isEmpty)
    }
    await model.shutdown()
  } // End of func openExistingIsFollowedByTheDraftsSwitcher(_:)

  // MARK: - Alongside the popover and the switcher

  /// A Move here confirmation in the popover and the window show at the same time: confirming
  /// or cancelling it never touches the window or its draft.
  @Test func moveHereAndTheWindowAtTheSameTime() async {
    let wired = await Wired.make()
    let model = wired.model
    let saturno = wired.harness.key(on: wired.harness.hosts[1])
    wired.pressIcon()
    model.newSession()
    model.newSessionDraft.name = "kept"
    wired.pressIcon()
    model.requestMoveHere(saturno)
    #expect(Self.showsMoveHere(model) && model.isNewSessionShown)
    #expect(model.handle(.close) == .handled)
    #expect(model.panel == nil && model.isNewSessionShown)
    model.requestMoveHere(saturno)
    #expect(model.handle(.open) == .handled)
    #expect(model.activities[saturno] == .movingHere)
    #expect(model.isNewSessionShown && model.newSessionDraft.name == "kept")
    #expect(wired.window.isShown && wired.window.hideCount == 0)
    #expect(await wired.harness.waitForActions(1))
    await model.shutdown()
  } // End of func moveHereAndTheWindowAtTheSameTime()

  /// Opening and closing the popover and the switcher leave the window, its draft and its
  /// directory list alone, and never show a closed window.
  @Test func thePopoverAndTheSwitcherLeaveTheWindowAlone() async {
    let wired = await Wired.make()
    let model = wired.model
    model.newSession()
    model.newSessionDraft.name = "kept"
    model.newSessionDraft.directory = "~/notes"
    model.openDirectoryList(highlightingFirst: false)
    let draft = model.newSessionDraft
    let shows = wired.window.shows
    wired.pressIcon()
    wired.pressIcon()
    wired.switcher.toggle()
    wired.switcher.toggle()
    wired.pressIcon()
    wired.switcher.toggle()
    wired.switcher.close(.escape)
    #expect(model.isNewSessionShown && model.newSessionDraft == draft)
    #expect(model.directoryPicker.isOpen)
    #expect(wired.window.shows == shows && wired.window.hideCount == 0)
    model.closeNewSession()
    wired.pressIcon()
    wired.switcher.toggle()
    wired.switcher.close(.escape)
    #expect(!model.isNewSessionShown && wired.window.shows == shows)
    await model.shutdown()
  } // End of func thePopoverAndTheSwitcherLeaveTheWindowAlone()

  // MARK: - Keys and clicks

  /// The window's keys: Return creates, ⌥↓ opens the directory list, ↑, ↓ and ⌘N do nothing,
  /// ⌘, opens Settings (the window stays), ⌘R and ⌘F go on to the focused view; a closed
  /// window takes no key.
  @Test func theWindowsKeys() async {
    let host = Support.localHost()
    var environment = Support.environment(load: { Support.loaded([host]) })
    let presented = Counter()
    environment.presentSettings = { _ in presented.increment() }
    let model = AppModel(environment: environment)
    await model.start()
    #expect(await Support.waitUntil { model.refreshState?.hosts.first?.isLive == true })
    for key in PopoverKey.allCases {
      #expect(model.handleNewSessionKey(key) == .ignored, "\(key) with the window closed")
    }
    model.newSession()
    #expect(model.handleNewSessionKey(.up) == .handled)
    #expect(model.handleNewSessionKey(.down) == .handled)
    #expect(model.handleNewSessionKey(.newSession) == .handled)
    #expect(model.handleNewSessionKey(.find) == .ignored)
    #expect(model.handleNewSessionKey(.refresh) == .ignored)
    #expect(model.handleNewSessionKey(.settings) == .handled)
    #expect(presented.value == 1 && model.isNewSessionShown)
    #expect(model.handleNewSessionKey(.openList) == .handled)
    #expect(model.directoryPicker.isOpen)
    #expect(model.handleNewSessionKey(.close) == .handled)
    #expect(!model.directoryPicker.isOpen && model.isNewSessionShown)
    #expect(model.handleNewSessionKey(.open) == .handled)
    #expect(model.newSessionDraft.nameIssue != nil, "Return checked the empty name")
    await model.shutdown()
  } // End of func theWindowsKeys()

  /// Each opening ignores the rest of the click sequence in progress (a double click's second
  /// click on the row or button that opened it, landing on the window); the window's next
  /// sequence passes, a double click in it included.
  @Test func eachOpeningIgnoresTheRestOfTheClickInProgress() async {
    let wired = await Wired.make()
    let model = wired.model
    #expect(model.newSessionWindowPasses(.press(clickCount: 2)))
    wired.switcher.toggle()
    model.clickSwitcherItem(.newSession)
    #expect(!model.newSessionWindowPasses(.press(clickCount: 2)))
    #expect(!model.newSessionWindowPasses(.drag) && !model.newSessionWindowPasses(.release))
    #expect(model.newSessionWindowPasses(.press(clickCount: 1)))
    #expect(model.newSessionWindowPasses(.release))
    #expect(model.newSessionWindowPasses(.press(clickCount: 2)))
    model.newSession()
    #expect(!model.newSessionWindowPasses(.press(clickCount: 3)))
    await model.shutdown()
  } // End of func eachOpeningIgnoresTheRestOfTheClickInProgress()

  /// The model needs no window: without a controller (the self-tests, previews) nothing is
  /// wired to `newSessionWindowChanged` and New session works through the model alone.
  @Test func theModelNeedsNoWindow() async {
    let harness = await AttachHarness.make()
    let model = harness.model
    #expect(model.newSessionWindowChanged == nil)
    model.newSession()
    #expect(model.isNewSessionShown && model.newSessionWindow.request?.kind == .open(source: nil))
    model.closeNewSession()
    #expect(!model.isNewSessionShown)
    let fixture = AppModel(fixture: AttachFixtures.newSession)
    #expect(fixture.isNewSessionShown)
    fixture.newSession()
    #expect(fixture.newSessionWindow.request == nil, "a fixture opens nothing")
    await model.shutdown()
  } // End of func theModelNeedsNoWindow()

  // MARK: - Placement

  /// A fresh opening puts the window's top centre at the source's top centre, on the pixel
  /// grid, clamped into the source display's visible frame: at its right and left edges, at
  /// its bottom, and no larger than it.
  @Test func aFreshOpeningIsPlacedFromItsSource() {
    let main = PopoverAnchoringTests.main
    let size = CGSize(width: 540, height: 300)
    let popover = CGRect(x: 1250, y: 1530, width: 360, height: 168)
    let fresh = Placement.freshFrame(
      size: size, source: NewSessionWindowSource(frame: popover, screen: main))
    #expect(fresh == CGRect(x: 1160, y: 1398, width: 540, height: 300))
    #expect(Self.topCentre(fresh) == Self.topCentre(popover))
    let odd = Placement.freshFrame(
      size: CGSize(width: 541, height: 300),
      source: NewSessionWindowSource(frame: popover, screen: main))
    #expect(odd.minX == 1159.5 && odd.maxY == popover.maxY)
    let right = Placement.freshFrame(
      size: size,
      source: NewSessionWindowSource(
        frame: CGRect(x: 2900, y: 1530, width: 172, height: 168), screen: main))
    #expect(right.maxX == main.visibleFrame.maxX && right.maxY == 1698)
    let left = Placement.freshFrame(
      size: size,
      source: NewSessionWindowSource(
        frame: CGRect(x: 0, y: 1530, width: 100, height: 168), screen: main))
    #expect(left.minX == main.visibleFrame.minX)
    let low = Placement.freshFrame(
      size: size,
      source: NewSessionWindowSource(
        frame: CGRect(x: 1000, y: 0, width: 540, height: 100), screen: main))
    #expect(low.minY == main.visibleFrame.minY && low.height == 300)
    let huge = Placement.freshFrame(
      size: CGSize(width: 4000, height: 3000),
      source: NewSessionWindowSource(frame: popover, screen: main))
    #expect(huge == main.visibleFrame)
  } // End of func aFreshOpeningIsPlacedFromItsSource()

  /// A request's frame: while the window shows, its current frame whatever the request (the
  /// user's move stands); a fresh opening from its source, or with none where the switcher would
  /// show on the first display; a comeback at its last frame with the new height on the display
  /// it was on, or fresh when that display is gone.
  @Test func aRequestsFrame() {
    let screens = PopoverAnchoringTests.screens
    let size = CGSize(width: 540, height: 300)
    let source = NewSessionWindowSource(
      frame: CGRect(x: 1250, y: 1530, width: 360, height: 168), screen: screens[0])
    let moved = CGRect(x: 3200, y: 900, width: 540, height: 260)
    for kind: NewSessionWindowRequest.Kind in [.open(source: source), .open(source: nil), .outcome]
    {
      #expect(
        Placement.frame(
          for: kind, shownFrame: moved, lastFrame: nil, size: size, screens: screens) == moved)
    }
    #expect(
      Placement.frame(
        for: .open(source: source), shownFrame: nil, lastFrame: moved, size: size,
        screens: screens) == Placement.freshFrame(size: size, source: source))
    let fallback = Placement.frame(
      for: .open(source: nil), shownFrame: nil, lastFrame: nil, size: size, screens: screens)
    #expect(fallback?.maxY == SwitcherPlacement.top(on: screens[0]))
    #expect(fallback?.midX == screens[0].visibleFrame.midX)
    #expect(
      Placement.frame(
        for: .outcome, shownFrame: nil, lastFrame: moved, size: size, screens: screens)
        == CGRect(x: 3200, y: 860, width: 540, height: 300))
    let gone = CGRect(x: -5000, y: 0, width: 540, height: 260)
    #expect(
      Placement.frame(for: .outcome, shownFrame: nil, lastFrame: gone, size: size, screens: screens)
        == fallback)
    #expect(
      Placement.frame(
        for: .open(source: nil), shownFrame: nil, lastFrame: nil, size: size, screens: [])
        == nil)
  } // End of func aRequestsFrame()

  /// The height follows the content with the top edge fixed, clamped into the visible frame
  /// (a window reaching below it moves up); the display is the one sharing the most area.
  @Test func theHeightFollowsTheContent() {
    let main = PopoverAnchoringTests.main
    let frame = CGRect(x: 600, y: 900, width: 540, height: 300)
    #expect(
      Placement.resized(frame, height: 560, visibleFrame: main.visibleFrame)
        == CGRect(x: 600, y: 640, width: 540, height: 560))
    #expect(
      Placement.resized(frame, height: 1500, visibleFrame: main.visibleFrame)
        == CGRect(x: 600, y: 0, width: 540, height: 1500))
    let screens = PopoverAnchoringTests.screens
    #expect(
      Placement.screen(for: CGRect(x: 3000, y: 800, width: 540, height: 300), in: screens)
        == screens[1])
    #expect(Placement.screen(for: CGRect(x: -900, y: 0, width: 10, height: 10), in: screens) == nil)
  } // End of func theHeightFollowsTheContent()

  /// The controller: a content height change resizes the shown window with its top edge fixed
  /// (where the user moved it), and does nothing while it is hidden.
  @Test func theControllerResizesTheShownWindow() async {
    let wired = await Wired.make()
    let model = wired.model
    wired.pressIcon()
    model.newSession()
    let moved = CGRect(x: 700, y: 1000, width: 540, height: 300)
    wired.window.frame = moved
    wired.window.fittingFrameSize = CGSize(width: 540, height: 520)
    wired.controller.contentSizeChanged()
    #expect(wired.window.setFrames == [CGRect(x: 700, y: 780, width: 540, height: 520)])
    wired.controller.contentSizeChanged()
    #expect(wired.window.setFrames.count == 1, "no change, no resize")
    model.closeNewSession()
    #expect(wired.controller.lastFrame == CGRect(x: 700, y: 780, width: 540, height: 520))
    wired.window.fittingFrameSize = CGSize(width: 540, height: 300)
    wired.controller.contentSizeChanged()
    #expect(wired.window.setFrames.count == 1)
    await model.shutdown()
  } // End of func theControllerResizesTheShownWindow()
}
