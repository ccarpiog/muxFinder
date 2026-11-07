import Foundation
import Testing
import os

@testable import MuxFinderCore
@testable import MuxFinderUI

/// A backend for the review fixes of Phase I-12d2 (PLAN.md D38 *The UI (I-12d2)*): records every
/// call; an attach confirms a first window (or ends `attachFailure`), a move here a second one
/// (or ends `moveHereState`), iTerm2's through a launch tab; a detach waits at `detachGate`, then
/// ends `detachOutcome`.
actor ReviewFixBackend: TerminalBackend {
  /// The terminal it stands for.
  nonisolated let terminal: LaunchTerminalApp
  /// The chosen terminal it was built for.
  let chosen: ChosenTerminal
  /// Where every detach waits first (open unless a test closes it).
  let detachGate: TestGate
  /// The calls so far, by name (`hasUnresolvedLaunch` and `state` left out).
  private(set) var calls: [String] = []
  /// How every attach fails, or `nil` to confirm the first window.
  private var attachFailure: AttachFailure?
  /// How every move here ends, or `nil` to confirm the second window.
  private var moveHereState: AttachState?
  /// How every detach ends.
  private var detachOutcome = SessionDetachResult.Outcome.detached

  /// A backend for `chosen` whose attach fails with `attachFailure` (`nil`: confirms) and whose
  /// detaches wait at `detachGate`.
  init(chosen: ChosenTerminal, attachFailure: AttachFailure? = nil, detachGate: TestGate) {
    self.chosen = chosen
    terminal = chosen.terminal
    self.attachFailure = attachFailure
    self.detachGate = detachGate
  }

  /// The window number `index` this backend's terminal opened (`nil` for iTerm2).
  nonisolated func window(_ index: Int) -> PlainTerminalWindow? {
    guard case .plain(let loaded) = chosen else { return nil }
    return PlainTerminalWindow(
      openedBy: loaded, windowID: "window-\(index)-\(loaded.definition.id)", tty: nil)
  }

  /// Sets how every attach fails (`nil`: confirms).
  func setAttachFailure(_ failure: AttachFailure?) { attachFailure = failure }

  /// Sets how every move here ends (`nil`: confirms the second window).
  func setMoveHereState(_ state: AttachState?) { moveHereState = state }

  /// Sets how every detach ends.
  func setDetachOutcome(_ outcome: SessionDetachResult.Outcome) { detachOutcome = outcome }

  /// A confirmed result for `target` in window `index` (iTerm2: through a launch tab).
  func confirmed(_ target: AttachTarget, window index: Int) -> AttachResult {
    guard let window = window(index) else {
      return AttachResult(
        key: target.key, launchID: LaunchToken(), state: .confirmed(connectionID: "c\(index)"),
        gatewaySessionID: "g\(index)", connectionID: "c\(index)",
        activation: .activated(tabID: "t\(index)"))
    }
    let client = TerminalSeamTests.client(target)
    return AttachResult(
      key: target.key, launchID: LaunchToken(), state: .plainConfirmed(client: client),
      plainWindow: window, plainClient: client)
  } // End of func confirmed(_:window:)

  /// Records the call; confirms the first window, or fails.
  func attach(_ target: AttachTarget) async -> AttachResult {
    calls.append("attach")
    if let attachFailure {
      return AttachResult(key: target.key, launchID: LaunchToken(), state: .failed(attachFailure))
    }
    return confirmed(target, window: 1)
  }

  /// Records the call; confirms the second window, or ends `moveHereState`.
  func moveHere(_ target: AttachTarget, confirmation: MoveHereConfirmation) async -> AttachResult {
    calls.append("moveHere")
    guard let moveHereState else { return confirmed(target, window: 2) }
    return AttachResult(key: target.key, launchID: LaunchToken(), state: moveHereState)
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

  /// Records the call; waits at the gate; ends `detachOutcome`.
  func detach(session key: SessionKey, on host: HostConfig) async -> SessionDetachResult {
    calls.append("detach")
    _ = await detachGate.pass()
    return SessionDetachResult(key: key, outcome: detachOutcome)
  }

  /// Records the call; nothing to detach.
  func detachOtherClients(
    of target: AttachTarget, confirmation: DetachOtherClientsConfirmation
  ) async -> DetachOtherClientsResult {
    calls.append("detachOtherClients")
    return DetachOtherClientsResult(key: target.key, outcome: .nothingToDetach)
  }

  /// No state.
  func state(of key: SessionKey) async -> AttachState? { nil }

  /// Never holds an unresolved launch.
  func hasUnresolvedLaunch(for key: SessionKey) async -> Bool { false }

  /// Records the call; brought forward.
  func focus(_ handle: TerminalAttachmentHandle) async -> TerminalFocusResult {
    calls.append("focus")
    return .plainWindowFocused
  }
} // End of actor ReviewFixBackend

/// The three should-fix findings of the review of Phase I-12d2 (`docs/reviews/phase-I-12d2.md`;
/// PLAN.md D38 *The UI (I-12d2)*, review fixes), each over the I-12c3a seam harness with
/// `ReviewFixBackend`s: a cached plain window record never dims Move here (the backend
/// revalidates it), "Try again" of a detach repeats it on the backend that ran it after a change
/// of terminal ("Detach (opened in …)" once its terminal is the chosen one, "Detach from this
/// Mac" once it is not), and a -1708 from a script muxFinder does not ship is never worded as
/// Ghostty's AppleScript turned off.
@Suite("Terminal session review fixes")
@MainActor
struct TerminalReviewFixTests {
  /// Shorthand.
  typealias Support = UITestSupport

  /// The sample definition's wording.
  static let sample = TerminalSeamTests.sampleWording

  /// A harness over `definitions` whose stored terminal is `stored`, its backends
  /// `ReviewFixBackend`s (attaches failing with what `attachFailure` gives the chosen terminal,
  /// detaches waiting at `gate`), kept in `holders` by terminal id.
  static func harness(
    stored: String,
    definitions: [LoadedTerminalDefinition],
    holders: OSAllocatedUnfairLock<[String: ReviewFixBackend]>,
    gate: TestGate = TestGate(),
    attachFailure: @escaping @Sendable (ChosenTerminal) -> AttachFailure? = { _ in nil }
  ) async -> SeamHarness {
    await SeamHarness.make(stored: stored, definitions: definitions) { chosen in
      let backend = ReviewFixBackend(
        chosen: chosen, attachFailure: attachFailure(chosen), detachGate: gate)
      holders.withLock { $0[chosen.id] = backend }
      return backend
    }
  } // End of static func harness(stored:definitions:holders:gate:attachFailure:)

  /// The row of `key` in the popover's content.
  static func row(_ model: AppModel, _ key: SessionKey) -> SessionRow? {
    model.content.sections.flatMap(\.rows).first { $0.key == key }
  }

  // MARK: - Finding 1: a stale window record never dims Move here

  /// A window the chosen plain terminal's backend recorded no longer dims "Move here…": the
  /// record is cached (its client may have been detached in tmux, its window closed since), so
  /// the move goes to the backend, which revalidates it. Stale there, the move runs and the new
  /// window replaces the record; live, the backend refuses (`alreadyOpenInTerminal`) and the row
  /// says so with "Bring forward" and "Detach from this Mac", the record kept.
  @Test func aCachedWindowRecordNeverDimsMoveHere() async throws {
    let holders = OSAllocatedUnfairLock<[String: ReviewFixBackend]>(initialState: [:])
    let harness = await Self.harness(
      stored: "sample-exec", definitions: [SeamHarness.sample], holders: holders)
    let model = harness.model
    let key = harness.localKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    let backend = try #require(holders.withLock { $0["sample-exec"] })
    let first = try #require(backend.window(1))
    let second = try #require(backend.window(2))
    #expect(model.terminalAttachments[key] == .plainWindow(first))
    let row = try #require(Self.row(model, key))
    #expect(row.hasWindowHere && row.offersDetach)
    #expect(row.offersMoveHere, "a cached window record never dims Move here")

    // The backend found its record stale: the move here runs and confirms a new window.
    model.requestMoveHere(key)
    guard case .moveHere? = model.panel else {
      Issue.record("Move here showed no confirmation")
      await model.shutdown()
      return
    }
    model.confirmMoveHere()
    #expect(await harness.waitForActions(2))
    #expect(await backend.calls == ["attach", "moveHere"])
    #expect(model.activities[key] == .confirmedInTerminal(Self.sample))
    #expect(model.terminalAttachments[key] == .plainWindow(second))
    #expect(Self.row(model, key)?.offersMoveHere == true)

    // Its client still holds the session: the backend refuses, and the row says why.
    await backend.setMoveHereState(.failed(.alreadyOpenInTerminal(window: second)))
    model.requestMoveHere(key)
    model.confirmMoveHere()
    #expect(await harness.waitForActions(3))
    #expect(await backend.calls == ["attach", "moveHere", "moveHere"])
    let refused = try #require(model.activities[key]?.problem)
    #expect(refused.message.hasPrefix("This session is already open in a Sample terminal window"))
    #expect(refused.recoveries == [.bringForward, .detachHere])
    #expect(model.terminalAttachments[key] == .plainWindow(second), "the record stays")
    await model.shutdown()
  } // End of func aCachedWindowRecordNeverDimsMoveHere()

  /// The galleries' context menus follow: Terminal's row with its window offers "Move here…";
  /// iTerm2's rows are as before (dimmed only while this Mac's iTerm2 shows the session).
  @Test func theMenusOfferMoveHereBesideAWindow() {
    let terminal = TerminalAttachFixtures.terminalMenu.rows
    #expect(terminal[0].hasWindowHere && !terminal[0].isOpenInITerm2Here)
    #expect(terminal[0].offersMoveHere)
    for row in AttachFixtures.menuRows {
      #expect(row.offersMoveHere == !row.isOpenInITerm2Here, "\(row.name)")
    }
    #expect(AttachFixtures.menuRows.contains { $0.isOpenInITerm2Here && !$0.offersMoveHere })
  } // End of func theMenusOfferMoveHereBesideAWindow()

  // MARK: - Finding 2: a detach's retry keeps its terminal

  /// "Detach (opened in Sample terminal)" runs while the second terminal is chosen; choosing
  /// Sample terminal meanwhile waits for it; it ends `notClosed`, the waiting choice applies
  /// (Sample terminal is now the chosen one), and "Try again" still repeats the detach on Sample
  /// terminal's backend (its record kept, its backend cached), worded for it. The second
  /// terminal's backend is never built.
  @Test func aDetachRetryKeepsItsTerminalAfterAChange() async throws {
    let holders = OSAllocatedUnfairLock<[String: ReviewFixBackend]>(initialState: [:])
    let gate = TestGate()
    let harness = await Self.harness(
      stored: "sample-exec", definitions: [SeamHarness.sample, SeamHarness.sampleTwo],
      holders: holders, gate: gate)
    let model = harness.model
    let key = harness.remoteKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(await model.setTerminal("sample-two") == .success(.plain(SeamHarness.sampleTwo)))
    #expect(
      Self.row(model, key)?.otherTerminalDetaches.map(\.terminalID) == ["sample-exec"])

    let backend = try #require(holders.withLock { $0["sample-exec"] })
    await backend.setDetachOutcome(.notClosed)
    gate.close()
    model.detach(key, openedIn: "sample-exec")
    #expect(model.isPending(key))
    await gate.waitForArrivals(1)
    #expect(await model.setTerminal("sample-exec") == .success(.plain(SeamHarness.sample)))
    #expect(model.pendingTerminalChoice == .plain(SeamHarness.sample), "waits for the detach")
    #expect(model.terminalChoice == .plain(SeamHarness.sampleTwo))
    gate.open()
    #expect(await harness.waitForActions(2))
    #expect(model.terminalChoice == .plain(SeamHarness.sample), "applied once idle")
    let failed = try #require(model.activities[key]?.problem)
    #expect(failed.recoveries == [.retry, .refresh])
    #expect(failed.message.contains("Sample terminal window"))
    #expect(model.terminalAttachmentsByTerminal["sample-exec"]?[key] != nil, "not detached")

    await backend.setDetachOutcome(.detached)
    model.perform(.retry, for: key)
    let started = model.isPending(key)
    #expect(started, "Try again repeats the detach on Sample terminal's backend")
    if started {
      #expect(await harness.waitForActions(3))
      #expect(await backend.calls == ["attach", "detach", "detach"])
      #expect(model.activities[key] == .detached)
      #expect(model.terminalAttachmentsByTerminal["sample-exec"] == nil)
    }
    #expect(harness.built == ["sample-exec"], "the second terminal's backend is never built")
    await model.shutdown()
  } // End of func aDetachRetryKeepsItsTerminalAfterAChange()

  /// The same for "Detach from this Mac": it runs on Sample terminal's window while Sample
  /// terminal is chosen, the second terminal is chosen meanwhile, it ends `notClosed`, and "Try
  /// again" repeats it on Sample terminal's backend (now another terminal's, its record kept),
  /// not on the second terminal's, which is never built.
  @Test func aDetachFromThisMacRetryKeepsItsTerminalAfterAChange() async throws {
    let holders = OSAllocatedUnfairLock<[String: ReviewFixBackend]>(initialState: [:])
    let gate = TestGate()
    let harness = await Self.harness(
      stored: "sample-exec", definitions: [SeamHarness.sample, SeamHarness.sampleTwo],
      holders: holders, gate: gate)
    let model = harness.model
    let key = harness.localKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.canDetach(key))
    let backend = try #require(holders.withLock { $0["sample-exec"] })
    await backend.setDetachOutcome(.notClosed)
    gate.close()
    model.detach(key)
    await gate.waitForArrivals(1)
    #expect(await model.setTerminal("sample-two") == .success(.plain(SeamHarness.sampleTwo)))
    gate.open()
    #expect(await harness.waitForActions(2))
    #expect(model.terminalChoice == .plain(SeamHarness.sampleTwo))
    #expect(!model.canDetach(key))
    #expect(
      Self.row(model, key)?.otherTerminalDetaches.map(\.terminalID) == ["sample-exec"])
    #expect(model.activities[key]?.problem?.recoveries == [.retry, .refresh])

    await backend.setDetachOutcome(.detached)
    model.perform(.retry, for: key)
    let started = model.isPending(key)
    #expect(started, "Try again repeats the detach on Sample terminal's backend")
    if started {
      #expect(await harness.waitForActions(3))
      #expect(await backend.calls == ["attach", "detach", "detach"])
      #expect(model.activities[key] == .detached)
      #expect(model.terminalAttachmentsByTerminal["sample-exec"] == nil)
    }
    #expect(harness.built == ["sample-exec"], "the second terminal's backend is never built")
    await model.shutdown()
  } // End of func aDetachFromThisMacRetryKeepsItsTerminalAfterAChange()

  /// The same with iTerm2's record: "Detach (opened in iTerm2)" while a plain terminal is
  /// chosen, iTerm2 chosen meanwhile, `notClosed`, then "Try again" detaches through iTerm2's
  /// backend.
  @Test func anITerm2DetachRetryKeepsITerm2AfterAChange() async throws {
    let holders = OSAllocatedUnfairLock<[String: ReviewFixBackend]>(initialState: [:])
    let gate = TestGate()
    let harness = await Self.harness(
      stored: "iterm2", definitions: [SeamHarness.sample], holders: holders, gate: gate)
    let model = harness.model
    let key = harness.remoteKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    #expect(model.attachedHere[key] != nil)
    #expect(await model.setTerminal("sample-exec") == .success(.plain(SeamHarness.sample)))
    let iTerm2 = try #require(holders.withLock { $0[TerminalChoice.iTerm2ID] })
    await iTerm2.setDetachOutcome(.notClosed)
    gate.close()
    model.detach(key, openedIn: TerminalChoice.iTerm2ID)
    await gate.waitForArrivals(1)
    #expect(await model.setTerminal("iterm2") == .success(.iTerm2))
    gate.open()
    #expect(await harness.waitForActions(2))
    #expect(model.terminalChoice == .iTerm2)
    #expect(model.activities[key]?.problem?.recoveries.contains(.retry) == true)

    await iTerm2.setDetachOutcome(.detached)
    model.perform(.retry, for: key)
    let started = model.isPending(key)
    #expect(started, "Try again repeats the detach on iTerm2's backend")
    if started {
      #expect(await harness.waitForActions(3))
      #expect(await iTerm2.calls == ["attach", "detach", "detach"])
      #expect(model.attachedHere[key] == nil)
      #expect(model.activities[key] == .detached)
    }
    #expect(harness.built == [TerminalChoice.iTerm2ID])
    await model.shutdown()
  } // End of func anITerm2DetachRetryKeepsITerm2AfterAChange()

  // MARK: - Finding 3: a missing handler is not Ghostty's AppleScript turned off

  /// An `appleScript` definition decoded in memory with `id`, `name` and `bundleIdentifier`,
  /// loaded from `source` (its script is never compiled: the backends are stand-ins).
  nonisolated static func appleScriptDefinition(
    id: String, name: String, bundleIdentifier: String, source: TerminalDefinitionSource
  ) -> LoadedTerminalDefinition {
    let json =
      #"{"schemaVersion": 1, "id": ""# + id + #"", "displayName": ""# + name + #"", "#
      + #""bundleIdentifier": ""# + bundleIdentifier + #"", "minimumVersion": "1.3", "#
      + #""open": {"kind": "appleScript", "script": ""# + id + #".applescript", "#
      + #""command": "words"}, "focus": {"kind": "windowID"}}"#
    return LoadedTerminalDefinition(
      definition: try! TerminalDefinition.decode(Data(json.utf8)), source: source,
      fileName: "\(id).json",
      script: TerminalScript(name: "\(id).applescript", source: "-- never compiled"))
  } // End of static func appleScriptDefinition(id:name:bundleIdentifier:source:)

  /// The built-in Ghostty definition (muxFinder's own script, which defines `muxfinder_open`).
  nonisolated static let builtInGhostty = appleScriptDefinition(
    id: "ghostty", name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", source: .builtIn)
  /// A user definition for Ghostty, whose script may lack `muxfinder_open`.
  nonisolated static let userGhostty = appleScriptDefinition(
    id: "my-ghostty", name: "Ghostty", bundleIdentifier: "com.mitchellh.ghostty", source: .user)
  /// A user definition for Terminal.
  nonisolated static let userTerminal = appleScriptDefinition(
    id: "my-terminal", name: "Terminal", bundleIdentifier: "com.apple.Terminal", source: .user)

  /// The open's script failure with `number` in `chosen`'s app.
  nonisolated static func openFailed(_ chosen: ChosenTerminal, _ number: Int) -> AttachFailure {
    guard case .plain(let loaded) = chosen else { return .timedOut }
    return .terminalWindow(
      .scriptFailed(
        appName: loaded.definition.displayName,
        .callFailed(handler: .open, errorNumber: number)))
  }

  /// Ghostty's open answering -1708 through a user definition: the line says the script may
  /// lack `muxfinder_open` or the AppleScript may be turned off, never that it is turned off.
  /// The same number through the built-in definition (whose script has the handler) and -10004
  /// (never a missing handler) keep "Ghostty's AppleScript is turned off". A user definition for
  /// Terminal answering -1708 points at its script's handler.
  @Test func aMissingHandlerIsNotGhosttysAppleScriptTurnedOff() async throws {
    let holders = OSAllocatedUnfairLock<[String: ReviewFixBackend]>(initialState: [:])
    let harness = await Self.harness(
      stored: "my-ghostty",
      definitions: [Self.builtInGhostty, Self.userGhostty, Self.userTerminal], holders: holders,
      attachFailure: { Self.openFailed($0, -1708) })
    let model = harness.model
    let key = harness.localKey
    model.open(key)
    #expect(await harness.waitForActions(1))
    let user = try #require(model.activities[key]?.problem)
    #expect(!user.message.contains("AppleScript is turned off"), "\(user.message)")
    #expect(user.message.contains("“muxfinder_open”"), "\(user.message)")
    #expect(user.message.contains("Ghostty's AppleScript may be turned off"), "\(user.message)")
    #expect(user.message.contains("(error -1708)"))
    #expect(user.recoveries == [.retry, .openSettings])

    let mine = try #require(holders.withLock { $0["my-ghostty"] })
    await mine.setAttachFailure(Self.openFailed(.plain(Self.userGhostty), -10004))
    model.open(key)
    #expect(await harness.waitForActions(2))
    #expect(
      model.activities[key]?.problem?.message.hasPrefix(
        "Ghostty's AppleScript is turned off (error -10004)") == true)

    #expect(await model.setTerminal("ghostty") == .success(.plain(Self.builtInGhostty)))
    model.open(key)
    #expect(await harness.waitForActions(3))
    #expect(
      model.activities[key]?.problem?.message.hasPrefix(
        "Ghostty's AppleScript is turned off (error -1708)") == true)

    #expect(await model.setTerminal("my-terminal") == .success(.plain(Self.userTerminal)))
    model.open(key)
    #expect(await harness.waitForActions(4))
    let terminal = try #require(model.activities[key]?.problem)
    #expect(terminal.message.contains("“muxfinder_open”"), "\(terminal.message)")
    #expect(!terminal.message.contains("AppleScript"), "\(terminal.message)")
    #expect(terminal.message.hasPrefix("Terminal couldn't open a window (error -1708)"))
    await model.shutdown()
  } // End of func aMissingHandlerIsNotGhosttysAppleScriptTurnedOff()

  /// The problem of a script failure `number` from `handler` in `app`, worded by `wording`, for a
  /// definition loaded from `source`.
  static func scriptProblem(
    _ app: String, _ wording: TerminalWording, _ handler: TerminalScriptHandler, _ number: Int,
    _ source: TerminalDefinitionSource
  ) -> SessionProblem {
    SessionProblem.attach(
      .terminalWindow(
        .scriptFailed(appName: app, .callFailed(handler: handler, errorNumber: number))),
      wording: wording, definitionSource: source)
  }

  /// The mapping: -1708 from the open of a definition that is not muxFinder's own (a user's or
  /// an override) gets the possibility line, for Ghostty and for any other app, with "Try again"
  /// and "Open Settings"; -10004, -600, and -1708 from a focus or a close keep their lines, as
  /// does the built-in default; with iTerm2's wording the source changes nothing. The two lines
  /// are sentences, distinct from each other and from every other window error's line.
  @Test func anOpenNobodyHandledIsWordedAsAPossibility() {
    let ghostty = TerminalSessionFixtures.ghosttyWording
    let terminal = TerminalSessionFixtures.terminalWording
    for source: TerminalDefinitionSource in [.user, .userOverride] {
      let own = Self.scriptProblem("Ghostty", ghostty, .open, -1708, source)
      #expect(own.message == ghostty.windowOpenNotHandled(errorNumber: -1708))
      #expect(own.recoveries == [.retry, .openSettings])
      #expect(
        Self.scriptProblem("Terminal", terminal, .open, -1708, source).message
          == terminal.windowOpenNotHandled(errorNumber: -1708))
      #expect(
        Self.scriptProblem("Ghostty", ghostty, .open, -10004, source).message.hasPrefix(
          "Ghostty's AppleScript is turned off (error -10004)"))
      #expect(
        Self.scriptProblem("Terminal", terminal, .open, -600, source).message.hasPrefix(
          "Terminal isn't running and couldn't be opened (error -600)"))
      for handler: TerminalScriptHandler in [.focus, .close] {
        #expect(
          Self.scriptProblem("Ghostty", ghostty, handler, -1708, source)
            == Self.scriptProblem("Ghostty", ghostty, handler, -1708, .builtIn), "\(handler)")
      }
    } // End of loop over the sources that are not muxFinder's own
    let builtIn = Self.scriptProblem("Ghostty", ghostty, .open, -1708, .builtIn)
    #expect(
      builtIn
        == SessionProblem.attach(
          .terminalWindow(
            .scriptFailed(appName: "Ghostty", .callFailed(handler: .open, errorNumber: -1708))),
          wording: ghostty))
    #expect(builtIn.message.hasPrefix("Ghostty's AppleScript is turned off (error -1708)"))
    #expect(
      Self.scriptProblem("Ghostty", .iTerm2, .open, -1708, .user)
        == Self.scriptProblem("Ghostty", .iTerm2, .open, -1708, .builtIn))

    let lines = [
      ghostty.windowOpenNotHandled(errorNumber: -1708),
      terminal.windowOpenNotHandled(errorNumber: -1708),
    ]
    let others =
      (TerminalErrorMappingTests.windowSamples.map(TerminalErrorMappingTests.problem)
      + TerminalErrorMappingTests.scriptSamples.map {
        TerminalErrorMappingTests.problem(.scriptFailed(appName: "Terminal", $0))
      }).map(\.message) + [ghostty.windowAppleScriptOff(errorNumber: -1708)]
    #expect(Set(lines).count == lines.count)
    #expect(Set(lines).isDisjoint(with: others))
    for line in lines {
      #expect(line.hasSuffix(".") && !line.contains("iTerm2") && !line.contains("is turned off"))
    }
    #expect(lines[0].contains("Ghostty's AppleScript may be turned off"))
    #expect(lines[0].contains("“macos-applescript = false”"))
    #expect(!lines[1].contains("AppleScript"))
  } // End of func anOpenNobodyHandledIsWordedAsAPossibility()
} // End of struct TerminalReviewFixTests
