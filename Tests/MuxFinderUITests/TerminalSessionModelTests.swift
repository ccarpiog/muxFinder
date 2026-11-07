import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// A backend for the model's routing per terminal (PLAN.md D38 *The UI (I-12d2)*): records
/// every call, answers `attach` and `moveHere` with what `answer` makes, `detach` with
/// `detachOutcome`, `hasUnresolvedLaunch` with `holdsLaunch`, and every focus as brought
/// forward.
actor RoutedBackend: TerminalBackend {
  /// The terminal it stands for.
  nonisolated let terminal: LaunchTerminalApp
  /// Makes the attach result for a target.
  private let answer: @Sendable (AttachTarget) -> AttachResult
  /// The calls so far, by name, `hasUnresolvedLaunch` included.
  private(set) var calls: [String] = []
  /// The handles focused so far.
  private(set) var focused: [TerminalAttachmentHandle] = []
  /// Whether it holds a launch that may still attach any session.
  private var holdsLaunch = false
  /// How every detach ends.
  private var detachOutcome = SessionDetachResult.Outcome.detached

  /// A backend for `terminal` answering `answer`.
  init(terminal: LaunchTerminalApp, answer: @escaping @Sendable (AttachTarget) -> AttachResult) {
    self.terminal = terminal
    self.answer = answer
  }

  /// Sets whether it holds an unresolved launch.
  func setHoldsLaunch(_ holds: Bool) { holdsLaunch = holds }

  /// Sets how every detach ends.
  func setDetachOutcome(_ outcome: SessionDetachResult.Outcome) { detachOutcome = outcome }

  /// Records the call; answers.
  func attach(_ target: AttachTarget) async -> AttachResult {
    calls.append("attach")
    return answer(target)
  }

  /// Records the call; answers.
  func moveHere(_ target: AttachTarget, confirmation: MoveHereConfirmation) async -> AttachResult {
    calls.append("moveHere")
    return answer(target)
  }

  /// Records the call; creation fails.
  func createAndAttach(
    _ request: NewSessionRequest, onCreated: (@Sendable (CreatedSession) -> Void)?
  ) async -> CreateAndAttachResult {
    calls.append("createAndAttach")
    return CreateAndAttachResult(creationFailure: .directoryMissing)
  }

  /// Records the call; gone.
  func currentSession(
    named name: String, on host: HostConfig
  ) async -> Result<AttachTarget, AttachFailure> {
    calls.append("currentSession")
    return .failure(.sessionGone)
  }

  /// Records the call; ends `detachOutcome`.
  func detach(session key: SessionKey, on host: HostConfig) async -> SessionDetachResult {
    calls.append("detach")
    return SessionDetachResult(key: key, outcome: detachOutcome)
  }

  /// Records the call; nothing to detach.
  func detachOtherClients(
    of target: AttachTarget, confirmation: DetachOtherClientsConfirmation
  ) async -> DetachOtherClientsResult {
    calls.append("detachOtherClients")
    return DetachOtherClientsResult(key: target.key, outcome: .nothingToDetach)
  }

  /// Records the call; no state.
  func state(of key: SessionKey) async -> AttachState? {
    calls.append("state")
    return nil
  }

  /// Records the call; `holdsLaunch`.
  func hasUnresolvedLaunch(for key: SessionKey) async -> Bool {
    calls.append("hasUnresolvedLaunch")
    return holdsLaunch
  }

  /// Records the handle; brought forward.
  func focus(_ handle: TerminalAttachmentHandle) async -> TerminalFocusResult {
    calls.append("focus")
    focused.append(handle)
    if case .app = handle { return .appActivation(.activated) }
    return .plainWindowFocused
  }
} // End of actor RoutedBackend

/// The model's session rows and actions per terminal (PLAN.md D38 *The UI (I-12d2)*): another
/// terminal's record detached through that terminal's own backend only, the "earlier launch
/// pending" line naming the holder, a session open in another app on this Mac (iTerm2 chosen
/// too), the plain results worded for their terminal, and iTerm2's content unchanged.
@Suite("Terminal session model")
@MainActor
struct TerminalSessionModelTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// The sample definition's wording.
  static let sample = TerminalSeamTests.sampleWording

  /// A harness whose backends are `RoutedBackend`s answering `answer`, kept in `holders` by
  /// terminal id.
  static func harness(
    stored: String?,
    holders: OSAllocatedUnfairLock<[String: RoutedBackend]>,
    definitions: [LoadedTerminalDefinition] = [SeamHarness.sample, SeamHarness.sampleTwo],
    answer: @escaping @Sendable (ChosenTerminal, AttachTarget) -> AttachResult
  ) async -> SeamHarness {
    await SeamHarness.make(stored: stored, definitions: definitions) { chosen in
      let backend = RoutedBackend(terminal: chosen.terminal) { answer(chosen, $0) }
      holders.withLock { $0[chosen.id] = backend }
      return backend
    }
  } // End of static func harness(stored:holders:definitions:answer:)

  /// A plain confirmed result for `target` in `chosen`'s window (iTerm2: confirmed through a
  /// launch tab).
  nonisolated static func confirmed(_ chosen: ChosenTerminal, _ target: AttachTarget)
    -> AttachResult
  {
    guard chosen != .iTerm2 else {
      return AttachResult(
        key: target.key, launchID: LaunchToken(), state: .confirmed(connectionID: "c1"),
        gatewaySessionID: "g1", connectionID: "c1", activation: .activated(tabID: "t1"))
    }
    return AttachResult(
      key: target.key, launchID: LaunchToken(),
      state: .plainConfirmed(client: TerminalSeamTests.client(target)),
      plainWindow: TerminalSeamTests.window(of: chosen),
      plainClient: TerminalSeamTests.client(target))
  } // End of static func confirmed(_:_:)

  /// The row of `key` in the popover's content.
  static func row(_ model: AppModel, _ key: SessionKey) -> SessionRow? {
    model.content.sections.flatMap(\.rows).first { $0.key == key }
  }

  /// A window muxFinder opened in Sample terminal, kept by its backend; after a change to the
  /// second terminal the row offers "Detach (opened in Sample terminal)" (and no Detach of the
  /// chosen terminal), which runs only the first backend's `detach`: the chosen terminal's
  /// backend is never built, nothing else of the first one is called, its record goes, and
  /// "Try again" after a failure repeats it on the same backend.
  @Test func anotherTerminalsRecordDetachesThroughItsOwnBackend() async throws {
    let holders = OSAllocatedUnfairLock<[String: RoutedBackend]>(initialState: [:])
    let harness = await Self.harness(
      stored: "sample-exec", holders: holders, answer: Self.confirmed)
    let model = harness.model
    let key = harness.remoteKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.activities[key] == .confirmedInTerminal(Self.sample))
    let opened = try #require(Self.row(model, key))
    #expect(opened.hasWindowHere && opened.offersDetach && opened.offersMoveHere)
    #expect(opened.otherTerminalDetaches.isEmpty)

    #expect(await model.setTerminal("sample-two") == .success(.plain(SeamHarness.sampleTwo)))
    let other = try #require(Self.row(model, key))
    #expect(!other.hasWindowHere && !other.offersDetach && other.offersMoveHere)
    #expect(
      other.otherTerminalDetaches == [
        OtherTerminalDetach(terminalID: "sample-exec", wording: Self.sample)
      ])
    #expect(other.otherTerminalDetaches.map(\.title) == ["Detach (opened in Sample terminal)"])
    #expect(!model.canDetach(key))

    let first = try #require(holders.withLock { $0["sample-exec"] })
    await first.setDetachOutcome(.notClosed)
    model.detach(key, openedIn: "sample-exec")
    #expect(model.activities[key] == .detaching)
    #expect(await harness.waitForActions(2))
    #expect(model.activities[key]?.problem?.recoveries == [.retry, .refresh])
    #expect(model.terminalAttachmentsByTerminal["sample-exec"]?[key] != nil, "not detached yet")
    await first.setDetachOutcome(.detached)
    model.perform(.retry, for: key)
    #expect(await harness.waitForActions(3))
    #expect(await first.calls == ["attach", "detach", "detach"])
    #expect(harness.built == ["sample-exec"], "the chosen terminal's backend is never built")
    #expect(model.activities[key] == .detached)
    #expect(model.terminalAttachmentsByTerminal["sample-exec"] == nil)
    #expect(Self.row(model, key)?.otherTerminalDetaches.isEmpty == true)
    model.detach(key, openedIn: "sample-exec")
    #expect(!model.isPending(key), "no record left: nothing runs")
    model.detach(key, openedIn: "sample-two")
    #expect(!model.isPending(key), "the chosen terminal is not another terminal")
    await model.shutdown()
  } // End of func anotherTerminalsRecordDetachesThroughItsOwnBackend()

  /// An attachment muxFinder made in iTerm2, then a plain choice: the row offers "Detach
  /// (opened in iTerm2)" through iTerm2's backend only; the plain backend is never built.
  @Test func anITerm2RecordDetachesThroughITerm2sBackend() async throws {
    let holders = OSAllocatedUnfairLock<[String: RoutedBackend]>(initialState: [:])
    let harness = await Self.harness(stored: "iterm2", holders: holders, answer: Self.confirmed)
    let model = harness.model
    let key = harness.remoteKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.activities[key] == .confirmed)
    #expect(Self.row(model, key)?.otherTerminalDetaches.isEmpty == true)
    #expect(await model.setTerminal("sample-exec") == .success(.plain(SeamHarness.sample)))
    let row = try #require(Self.row(model, key))
    #expect(row.otherTerminalDetaches.map(\.title) == ["Detach (opened in iTerm2)"])
    #expect(!row.offersDetach)
    model.detach(key, openedIn: TerminalChoice.iTerm2ID)
    #expect(await harness.waitForActions(2))
    let iTerm2 = try #require(holders.withLock { $0["iterm2"] })
    #expect(await iTerm2.calls == ["attach", "detach"])
    #expect(harness.built == ["iterm2"])
    #expect(model.attachedHere[key] == nil)
    #expect(model.activities[key] == .detached)
    await model.shutdown()
  } // End of func anITerm2RecordDetachesThroughITerm2sBackend()

  /// I-12c3a's open risk: an Open refused because another terminal's launch may still attach
  /// the session names that terminal; iTerm2's own refusal keeps iTerm2's line.
  @Test func theEarlierLaunchLineNamesTheHolder() async throws {
    let holders = OSAllocatedUnfairLock<[String: RoutedBackend]>(initialState: [:])
    let harness = await Self.harness(stored: "sample-exec", holders: holders) { chosen, target in
      AttachResult(
        key: target.key, launchID: LaunchToken(),
        state: .failed(chosen == .iTerm2 ? .earlierLaunchPending : .timedOut))
    }
    let model = harness.model
    let key = harness.localKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    let plain = try #require(holders.withLock { $0["sample-exec"] })
    await plain.setHoldsLaunch(true)
    #expect(await model.setTerminal("iterm2") == .success(.iTerm2))
    model.open(key)
    #expect(await harness.waitForActions(2))
    #expect(
      model.activities[key] == .failed(.attach(.earlierLaunchPending, wording: Self.sample)))
    #expect(
      model.activities[key]?.problem?.message
        == "An earlier launch of this session may still attach it in Sample terminal, so "
        + "muxFinder did not start another. Finish or close that Sample terminal window, then "
        + "try again.")
    let iTerm2 = try #require(holders.withLock { $0["iterm2"] })
    #expect(await iTerm2.calls.isEmpty, "nothing asked of iTerm2's backend")
    await plain.setHoldsLaunch(false)
    model.open(key)
    #expect(await harness.waitForActions(3))
    #expect(await iTerm2.calls == ["attach"])
    #expect(model.activities[key] == .failed(.attach(.earlierLaunchPending)))
    await model.shutdown()
  } // End of func theEarlierLaunchLineNamesTheHolder()

  /// Requirement 9 with iTerm2 chosen (I-12c3a's call): a session open in another app on this
  /// Mac shows "Open in <app> on this Mac" with "Show in <app>", which brings the app forward
  /// through iTerm2's backend (an `.app` focus); Open still opens in iTerm2; the row's other
  /// states are as before.
  @Test func aSessionOpenInAnotherAppShowsWithITerm2Chosen() async throws {
    let holders = OSAllocatedUnfairLock<[String: RoutedBackend]>(initialState: [:])
    let harness = await Self.harness(stored: "iterm2", holders: holders, answer: Self.confirmed)
    let model = harness.model
    let key = harness.localKey
    model.popoverDidOpen()
    #expect(await Support.waitUntil { Self.row(model, key)?.openInApps.isEmpty == false })
    let row = try #require(Self.row(model, key))
    #expect(row.openInApps.map(\.badgeText) == ["Open in Sample terminal on this Mac"])
    #expect(row.openInApps.map(\.showTitle) == ["Show in Sample terminal"])
    #expect(row.accessibilityValue.contains("Open in Sample terminal on this Mac"))
    #expect(!row.isOpenInITerm2Here && !row.hasWindowHere)
    #expect(Self.row(model, harness.remoteKey)?.openInApps.isEmpty == true)
    model.showInApp(row.openInApps[0].app, for: key)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    let iTerm2 = try #require(holders.withLock { $0["iterm2"] })
    #expect(await iTerm2.focused == [.app(SeamHarness.sampleApp)])
    #expect(model.notes[key] == nil)
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(await iTerm2.calls == ["focus", "attach"])
    #expect(model.activities[key] == .confirmed)
    await model.shutdown()
  } // End of func aSessionOpenInAnotherAppShowsWithITerm2Chosen()

  /// The plain backend's results in the rows, worded for their terminal: a confirmed window
  /// whose one focus failed (its note), a focus of the window that failed, an app found open
  /// whose activation was refused or went through, a still-waiting window with "Show window",
  /// and a timed-out one whose "Show window" focuses it through the chosen backend.
  @Test func plainResultsAreWordedForTheirTerminal() async throws {
    let holders = OSAllocatedUnfairLock<[String: RoutedBackend]>(initialState: [:])
    let harness = await Self.harness(
      stored: "sample-exec", holders: holders, answer: Self.confirmed)
    let model = harness.model
    let key = harness.localKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    let window = try #require(TerminalSeamTests.window(of: .plain(SeamHarness.sample)))
    let failed = TerminalFocusResult.plainWindowFailed(.appNotRunning(appName: "Sample terminal"))
    /// A result of `state` for `key` with `extra` applied.
    func result(_ state: AttachState, _ extra: (inout AttachResult) -> Void = { _ in })
      -> AttachResult
    {
      var made = AttachResult(key: key, launchID: LaunchToken(), state: state, plainWindow: window)
      extra(&made)
      return made
    }
    let client = TerminalAttachFixtures.client
    model.finishAttach(
      result(.plainConfirmed(client: client)) { $0.plainWindowFocus = failed }, target: nil,
      terminalID: "sample-exec")
    #expect(model.activities[key] == .confirmedInTerminal(Self.sample))
    #expect(model.notes[key] == "Sample terminal isn't running, so the session's window is gone.")
    model.finishAttach(
      result(.plainFocused(client: client)) { $0.plainWindowFocus = failed }, target: nil,
      terminalID: "sample-exec")
    #expect(
      model.activities[key] == .failed(.windowNotBroughtForward(failed, wording: Self.sample)))
    model.finishAttach(
      result(.appFocused(app: SeamHarness.sampleApp)) { $0.appActivation = .refused },
      target: nil, terminalID: "sample-exec")
    #expect(model.activities[key] == .failed(.appNotBroughtForward(.refused, app: Self.sample)))
    model.finishAttach(
      result(.appFocused(app: SeamHarness.sampleApp)) { $0.appActivation = .activated },
      target: nil, terminalID: "sample-exec")
    #expect(model.activities[key] == .focusedApp(Self.sample))
    #expect(
      model.activities[key]?.text
        == "Already open in Sample terminal on this Mac — brought it forward")
    model.finishAttach(
      result(.plainStillWaiting(window: window)), target: nil, terminalID: "sample-exec")
    #expect(model.activities[key] == .stillConnectingInWindow(window, Self.sample))
    model.finishAttach(result(.failed(.timedOut)), target: nil, terminalID: "sample-exec")
    #expect(
      model.activities[key] == .failed(.attach(.timedOut, wording: Self.sample, window: window)))
    #expect(model.activities[key]?.launchWindow == window)
    model.showLaunchWindow(for: key)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    model.perform(.showWindow(window), for: key)
    #expect(await Support.waitUntil { model.showTabTasks.isEmpty })
    let backend = try #require(holders.withLock { $0["sample-exec"] })
    #expect(await backend.focused == [.plainWindow(window), .plainWindow(window)])
    await model.shutdown()
  } // End of func plainResultsAreWordedForTheirTerminal()

  /// "Open System Settings…" opens Privacy & Security › Automation through the URL seam (no
  /// Apple event); an unavailable choice's problem names the definition's terminal.
  @Test func openSystemSettingsOpensAutomation() async {
    let urls = OSAllocatedUnfairLock<[URL]>(initialState: [])
    let model = AppModel(
      environment: AppEnvironment(
        loadHosts: { UITestSupport.loaded([]) },
        makeEngine: { hosts in
          RefreshCoordinator(
            hosts: hosts, discovery: FakeDiscovery(), configuration: Support.quietConfiguration)
        },
        makeSystemEvents: { _ in nil }, terminate: {},
        openURL: { url in urls.withLock { $0.append(url) } }))
    let key = PreviewFixtures.session("s", id: 1, on: PreviewFixtures.saturno, windows: 1).key
    model.perform(.openAutomationSettings, for: key)
    #expect(urls.withLock { $0 } == [FixIt.automationSettingsURL])

    let harness = await SeamHarness.make(
      stored: "sample-exec", snapshot: TerminalAppSnapshot(url: nil, version: nil, running: false))
    let unavailable = TerminalChoiceUnavailable(terminalID: "sample-exec", reason: .notInstalled)
    #expect(harness.model.terminalChoice == .unavailable(unavailable))
    harness.model.open(harness.localKey)
    #expect(
      harness.model.activities[harness.localKey]?.problem?.message
        == "The chosen terminal, Sample terminal, isn't installed. Install it, or choose another "
        + "terminal in Settings.")
    #expect(harness.model.activities[harness.localKey]?.problem?.recoveries == [.openSettings])
    await harness.model.shutdown()
  } // End of func openSystemSettingsOpensAutomation()

  /// Requirement 12: with iTerm2 chosen the content is what the old parameters build, for
  /// every existing popover, attach and switcher fixture (no window, app, record or wording
  /// adds anything), and the fixture models' content matches it.
  @Test func iTerm2ContentIsUnchanged() {
    for fixture in PreviewFixtures.all + AttachFixtures.all + AttachFixtures.newSessionStates {
      let old = PopoverContent(
        state: fixture.state, hostList: fixture.hostList, query: fixture.searchText,
        activities: fixture.activities, selection: fixture.selection, now: fixture.now,
        sshSetupStates: fixture.sshSetupStates, notes: fixture.notes, banners: fixture.banners,
        attachedHere: Set(fixture.attachedHere.keys))
      #expect(AppModel(fixture: fixture).content == old, "\(fixture.id)")
      let explicit = PopoverContent(
        state: fixture.state, hostList: fixture.hostList, query: fixture.searchText,
        activities: fixture.activities, selection: fixture.selection, now: fixture.now,
        sshSetupStates: fixture.sshSetupStates, notes: fixture.notes, banners: fixture.banners,
        attachedHere: Set(fixture.attachedHere.keys), windowsHere: [],
        catalog: TerminalSessionFixtures.catalog, otherTerminalDetaches: [:], wording: .iTerm2)
      #expect(explicit == old, "\(fixture.id)")
    } // End of loop over the popover fixtures
    for fixture in SwitcherFixtures.all {
      let old = SwitcherContent(
        state: fixture.state, hostList: fixture.hostList, query: fixture.switcherSearchText,
        selection: fixture.switcherSelection, activities: fixture.activities, now: fixture.now,
        notes: fixture.notes, banners: fixture.banners,
        attachedHere: Set(fixture.attachedHere.keys), carried: fixture.switcherCarriedFailures)
      #expect(AppModel(fixture: fixture).switcherContent == old, "\(fixture.id)")
    }
  } // End of func iTerm2ContentIsUnchanged()
} // End of struct TerminalSessionModelTests

/// The galleries' states per terminal (PLAN.md D38 *The UI (I-12d2)*): iTerm2, Terminal and
/// Ghostty for the row actions, pending, confirmed, focused, failed (every window error), a
/// session open in another app, an unavailable choice; all from synthetic data.
@Suite("Terminal session fixtures")
@MainActor
struct TerminalSessionFixtureTests {
  /// Every terminal fixture of the three galleries.
  static var all: [PreviewFixture] {
    TerminalSessionFixtures.popover + TerminalAttachFixtures.all + TerminalSessionFixtures.switcher
      + TerminalAttachFixtures.menus.map(\.fixture)
  }

  /// The built-ins' copies decode as the built-ins read: ids, names, apps, kinds, sorted.
  @Test func definitionsDecodeAsTheBuiltIns() {
    let terminal = TerminalSessionFixtures.terminal.definition
    let ghostty = TerminalSessionFixtures.ghostty.definition
    #expect(terminal.id == "terminal" && terminal.displayName == "Terminal")
    #expect(terminal.bundleIdentifier == "com.apple.Terminal" && terminal.focus == .tty)
    #expect(ghostty.id == "ghostty" && ghostty.minimumVersion == TerminalVersion("1.3"))
    #expect(ghostty.focus == .windowID)
    #expect(TerminalSessionFixtures.terminalWording.kind == .terminalApp)
    #expect(TerminalSessionFixtures.ghosttyWording.kind == .ghostty)
    #expect(
      TerminalSessionFixtures.catalog.definitions.map(\.definition.id) == ["ghostty", "terminal"])
    #expect(TerminalSessionFixtures.terminal.script == nil, "no script read")
  } // End of func definitionsDecodeAsTheBuiltIns()

  /// Each gallery shows each terminal: iTerm2, Terminal and Ghostty chosen, and each one
  /// unavailable; every plain state and a session open in another app.
  @Test func galleriesShowEveryTerminal() {
    let choices = Set(Self.all.map(\.terminal.terminalID))
    #expect(choices == ["iterm2", "terminal", "ghostty"])
    let unavailable = Set(
      TerminalSessionFixtures.popover.compactMap { fixture -> String? in
        if case .unavailable(let failure) = fixture.terminal { return failure.terminalID }
        return nil
      })
    #expect(unavailable == ["iterm2", "terminal", "ghostty"])
    let activities = Self.all.flatMap { $0.activities.values }
    let terminal = TerminalSessionFixtures.terminalWording
    let ghostty = TerminalSessionFixtures.ghosttyWording
    for activity: SessionActivity in [
      .waitingForTerminal(terminal), .waitingForTerminal(ghostty),
      .stillConnectingInWindow(TerminalSessionFixtures.terminalWindow, terminal),
      .confirmedInTerminal(terminal), .confirmedInTerminal(ghostty), .focusedWindow(terminal),
      .focusedWindow(ghostty), .focusedApp(ghostty), .waitingForITerm2, .confirmed, .detaching,
      .detached,
    ] {
      #expect(activities.contains(activity), "\(activity)")
    }
    for fixture in [
      TerminalSessionFixtures.iTerm2Popover, TerminalSessionFixtures.terminalHerePopover,
      TerminalSessionFixtures.ghosttyHerePopover, TerminalSessionFixtures.iTerm2Switcher,
    ] {
      let rows = AppModel(fixture: fixture).content.sections.flatMap(\.rows)
      #expect(rows.contains { !$0.openInApps.isEmpty }, "\(fixture.id)")
    }
    let terminalRows = AppModel(fixture: TerminalSessionFixtures.terminalHerePopover).content
      .sections.flatMap(\.rows)
    #expect(terminalRows.contains { $0.hasWindowHere })
    #expect(
      AppModel(fixture: TerminalSessionFixtures.terminalPopover).terminalWording == terminal)
    #expect(
      AppModel(fixture: TerminalSessionFixtures.ghosttyUnavailable).terminalWording == ghostty)
  } // End of func galleriesShowEveryTerminal()

  /// The attach gallery shows every window error's line, and the context menus offer the plain
  /// terminals' items.
  @Test func theAttachGalleryShowsEveryWindowError() {
    let errors =
      TerminalAttachFixtures.terminalWindowErrors + TerminalAttachFixtures.ghosttyWindowErrors
    #expect(Set(errors.map(TerminalErrorMappingTests.caseIndex)) == Set(0...18))
    let messages = Set(
      TerminalAttachFixtures.all.flatMap { $0.activities.values }.compactMap(\.problem?.message))
    for error in TerminalAttachFixtures.terminalWindowErrors {
      let line = SessionProblem.attach(
        .terminalWindow(error), wording: TerminalSessionFixtures.terminalWording
      ).message
      #expect(messages.contains(line), "\(error.kind)")
    }
    for error in TerminalAttachFixtures.ghosttyWindowErrors {
      let line = SessionProblem.attach(
        .terminalWindow(error), wording: TerminalSessionFixtures.ghosttyWording
      ).message
      #expect(messages.contains(line), "\(error.kind)")
    }
    #expect(messages.contains { $0.hasPrefix("Stopped after detaching 2 other clients") })
    #expect(messages.contains { $0.contains("Some may have been detached") })
    #expect(messages.contains { $0.hasPrefix("The chosen terminal, Ghostty, isn't installed.") })
    let menu = TerminalAttachFixtures.terminalMenu.rows
    #expect(menu[0].hasWindowHere && menu[0].openInApps.map(\.showTitle) == ["Show in iTerm2"])
    #expect(menu[1].otherTerminalDetaches.map(\.title) == ["Detach (opened in iTerm2)"])
    let ghostty = TerminalAttachFixtures.ghosttyMenu.rows
    #expect(ghostty[0].openInApps.map(\.showTitle) == ["Show in Terminal"])
    #expect(ghostty[0].otherTerminalDetaches.map(\.title) == ["Detach (opened in Terminal)"])
    #expect(
      AppModel(fixture: TerminalAttachFixtures.ghosttyMenu.fixture).terminalWording
        == TerminalSessionFixtures.ghosttyWording)
  } // End of func theAttachGalleryShowsEveryWindowError()

  /// Ids are unique within each gallery and new; only synthetic hosts and sockets.
  @Test func fixturesAreUniqueAndSynthetic() {
    let popover = PreviewFixtures.all + TerminalSessionFixtures.popover
    let attach =
      AttachFixtures.all + TerminalAttachFixtures.all + AttachFixtures.newSessionStates
      + TerminalAttachFixtures.menus.map(\.fixture)
    let switcher = SwitcherFixtures.all + TerminalSessionFixtures.switcher
    for gallery in [popover, attach, switcher] {
      #expect(Set(gallery.map(\.id)).count == gallery.count)
    }
    let hosts = Self.all.compactMap(\.state).flatMap(\.hosts).map(\.host)
    #expect(hosts.filter { $0.mode == .ssh }.allSatisfy { $0.sshDestination.hasSuffix(".example") })
    let sessions = Self.all.compactMap(\.state).flatMap(\.sessions)
    #expect(sessions.allSatisfy { $0.key.server.socketPath == "/tmp/tmux-fixture/default" })
  } // End of func fixturesAreUniqueAndSynthetic()
} // End of struct TerminalSessionFixtureTests
