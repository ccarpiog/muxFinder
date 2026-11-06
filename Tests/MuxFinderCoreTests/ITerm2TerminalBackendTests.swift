import Foundation
import Testing
import os

@testable import MuxFinderCore

/// iTerm2's backend of the terminal seam (PLAN.md D38, Phase I-12b3) over the attach
/// coordinator's existing test fakes: each scenario runs twice on fresh, identical fakes, once
/// calling the coordinator directly and once through `ITerm2TerminalBackend`, and the results,
/// the requests that reached iTerm2's fake, the launch store and discovery, and the published
/// states must be equal (launch ids, which the coordinator draws at random, compared by
/// position). A plain window handle is refused with nothing sent. Nothing touches iTerm2, tmux
/// or the launch directory.
@Suite("Terminal seam: iTerm2 backend")
struct ITerm2TerminalBackendTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The built-in definition `id`, loaded as text from the repository's `Resources/Terminals/`
  /// (a plain window is bound to the loaded definition that opened it).
  static func builtIn(_ id: String) throws -> LoadedTerminalDefinition {
    let definitions = TerminalDefinitionTestSupport.load(
      builtIn: TerminalDefinitionTestSupport.builtInDirectory)
    return try #require(definitions.definition(withID: id))
  }

  /// The launch id every recorded launch id is replaced with, by position.
  static func placeholder(_ index: Int) -> LaunchToken {
    LaunchToken(String(format: "00000000-0000-4000-8000-%012d", index))!
  }

  /// What a launch store saw, with launch ids replaced by position.
  struct StoreRecord: Equatable {
    /// Requests written.
    let written: [LaunchRequest]
    /// Requests discarded.
    let discarded: [LaunchToken]
    /// Sweeps, takes and peeks.
    let sweeps: Int, takes: Int, peeks: Int
  }

  /// The launch ids `store` saw, in the order of their first appearance.
  static func launchIDs(_ store: FakeLaunchStore) -> [LaunchToken] {
    var ids: [LaunchToken] = []
    let snapshot = store.snapshot
    for id in snapshot.written.map(\.id) + snapshot.discarded where !ids.contains(id) {
      ids.append(id)
    }
    return ids
  }

  /// `id` replaced by its position in `ids` (an id not there stays as it is).
  static func normalized(_ id: LaunchToken, _ ids: [LaunchToken]) -> LaunchToken {
    ids.firstIndex(of: id).map(placeholder) ?? id
  }

  /// `result` with its launch id replaced by position.
  static func normalized(_ result: AttachResult, _ ids: [LaunchToken]) -> AttachResult {
    var copy = result
    copy.launchID = normalized(result.launchID, ids)
    return copy
  }

  /// `result` with its attach's launch id replaced by position.
  static func normalized(
    _ result: CreateAndAttachResult,
    _ ids: [LaunchToken]
  ) -> CreateAndAttachResult {
    var copy = result
    copy.attach = result.attach.map { normalized($0, ids) }
    return copy
  }

  /// What `store` saw, launch ids replaced by position.
  static func record(_ store: FakeLaunchStore) -> StoreRecord {
    let ids = launchIDs(store)
    let snapshot = store.snapshot
    return StoreRecord(
      written: snapshot.written.map { request in
        var copy = request
        copy.id = normalized(request.id, ids)
        return copy
      },
      discarded: snapshot.discarded.map { normalized($0, ids) },
      sweeps: snapshot.sweeps, takes: snapshot.takes, peeks: snapshot.peeks)
  } // End of static func record(_:)

  /// iTerm2's recorded calls, the launch ids in tab commands replaced by position.
  static func normalized(
    _ calls: [FakeITerm2Integration.Call],
    _ ids: [LaunchToken]
  ) -> [FakeITerm2Integration.Call] {
    calls.map { call in
      guard case .createTab(var request) = call else { return call }
      request.customProfileProperties = request.customProfileProperties.map { property in
        var copy = property
        for (index, id) in ids.enumerated() {
          copy.jsonValue = copy.jsonValue.replacingOccurrences(
            of: id.rawValue, with: placeholder(index).rawValue)
        }
        return copy
      }
      return .createTab(request)
    }
  } // End of static func normalized(_:_:)

  /// The updates' states and launch ids, launch ids replaced by position.
  static func updates(_ log: UpdateLog, _ ids: [LaunchToken]) -> [AttachUpdate] {
    log.all.map { update in
      var copy = update
      copy.launchID = normalized(update.launchID, ids)
      return copy
    }
  }

  // MARK: - Identity

  /// The backend names iTerm2 and is usable as the seam's existential.
  @Test func namesITerm2() throws {
    let harness = AttachCoordinatorTests.harness()
    let backend: any TerminalBackend = ITerm2TerminalBackend(coordinator: harness.coordinator)
    #expect(backend.terminal == .iterm2)
    #expect(TerminalAttachmentHandle.iTerm2LaunchTab(sessionID: "s").terminal == .iterm2)
    let window = PlainTerminalWindow(
      openedBy: try Self.builtIn("ghostty"), windowID: "W-1", tty: nil)
    #expect(
      TerminalAttachmentHandle.plainWindow(window).terminal == .plain(definitionID: "ghostty"))
  }

  // MARK: - Forwarding

  /// A successful attach: the same result, states, iTerm2 requests, request file and
  /// discovery; `state(of:)` through the backend equals the coordinator's.
  @Test func attachForwardsUnchanged() async {
    let direct = AttachCoordinatorTests.harness()
    let adapted = AttachCoordinatorTests.harness()
    let backend = ITerm2TerminalBackend(coordinator: adapted.coordinator)
    #expect(await backend.state(of: adapted.target.key) == nil)
    let expected = await direct.coordinator.attach(direct.target)
    let result = await backend.attach(adapted.target)
    let directIDs = Self.launchIDs(direct.store)
    let adaptedIDs = Self.launchIDs(adapted.store)
    #expect(result.isConfirmed)
    #expect(Self.normalized(result, adaptedIDs) == Self.normalized(expected, directIDs))
    #expect(
      Self.normalized(await adapted.iTerm2.calls, adaptedIDs)
        == Self.normalized(await direct.iTerm2.calls, directIDs))
    #expect(Self.record(adapted.store) == Self.record(direct.store))
    #expect(Self.updates(adapted.log, adaptedIDs) == Self.updates(direct.log, directIDs))
    #expect(adapted.discovery.calls == direct.discovery.calls)
    #expect(await backend.state(of: adapted.target.key) == result.state)
    #expect(
      await backend.state(of: adapted.target.key)
        == (await direct.coordinator.state(of: direct.target.key)))
  } // End of func attachForwardsUnchanged()

  /// Move here, confirmed and not: the same results and requests (`-d` in the request file).
  @Test func moveHereForwardsUnchanged() async throws {
    let direct = MoveHereCoordinatorTests.harness(
      script: MoveHereCoordinatorTests.launchAfterEmptyCheck)
    let adapted = MoveHereCoordinatorTests.harness(
      script: MoveHereCoordinatorTests.launchAfterEmptyCheck)
    let backend = ITerm2TerminalBackend(coordinator: adapted.coordinator)
    let expected = await direct.coordinator.moveHere(
      direct.target, confirmation: direct.confirmation)
    let result = await backend.moveHere(adapted.target, confirmation: adapted.confirmation)
    let directIDs = Self.launchIDs(direct.store)
    let adaptedIDs = Self.launchIDs(adapted.store)
    #expect(result.isConfirmed)
    #expect(Self.normalized(result, adaptedIDs) == Self.normalized(expected, directIDs))
    #expect(try #require(adapted.store.snapshot.written.first).detachesOtherClients)
    #expect(Self.record(adapted.store) == Self.record(direct.store))
    #expect(
      Self.normalized(await adapted.fake.calls, adaptedIDs)
        == Self.normalized(await direct.fake.calls, directIDs))
    #expect(adapted.iTerm2.sent == direct.iTerm2.sent)
    #expect(Self.updates(adapted.log, adaptedIDs) == Self.updates(direct.log, directIDs))

    let otherKey = Support.session(id: "$4").key
    let refused = await backend.moveHere(
      adapted.target, confirmation: .detachOtherClients(of: otherKey))
    let refusedDirect = await direct.coordinator.moveHere(
      direct.target, confirmation: .detachOtherClients(of: otherKey))
    #expect(refused.failure == .moveHereNotConfirmed)
    #expect(refused.state == refusedDirect.state && refused.key == refusedDirect.key)
    #expect(Self.record(adapted.store) == Self.record(direct.store))
  } // End of func moveHereForwardsUnchanged()

  /// What one create-and-attach run produced, launch ids replaced by position.
  struct CreateRun: Equatable {
    /// The result.
    let result: CreateAndAttachResult
    /// The sessions `onCreated` was called with.
    let announced: [CreatedSession]
    /// The requests the session creator got.
    let creatorRequests: [NewSessionRequest]
    /// iTerm2's recorded calls.
    let calls: [FakeITerm2Integration.Call]
    /// What the launch store saw.
    let store: StoreRecord
  }

  /// Create and attach, with `onCreated` and through the seam's convenience without it, and a
  /// creation failure: the same results, announcements, creator requests and iTerm2 requests.
  @Test func createAndAttachForwardsUnchanged() async {
    /// One run: a coordinator over fresh fakes with `outcome`, called directly or through the
    /// backend, with or without `onCreated`.
    func run(
      _ outcome: Result<CreatedSession, SessionCreationError>,
      throughBackend: Bool,
      announcing: Bool
    ) async -> CreateRun {
      let session = Support.session()
      let iTerm2 = FakeITerm2Integration(script: Support.successScript(for: session))
      let store = FakeLaunchStore()
      let creator = FakeSessionCreator(outcome)
      let coordinator = CreateAndAttachTests.coordinator(
        iTerm2: iTerm2, discovery: FakeDiscovery(.ok([session])), store: store,
        creator: creator, log: UpdateLog())
      let announced = OSAllocatedUnfairLock(initialState: [CreatedSession]())
      let announce: @Sendable (CreatedSession) -> Void = { created in
        announced.withLock { $0.append(created) }
      }
      let onCreated = announcing ? announce : nil
      let result: CreateAndAttachResult
      if throughBackend {
        let backend = ITerm2TerminalBackend(coordinator: coordinator)
        result =
          announcing
          ? await backend.createAndAttach(CreateAndAttachTests.request, onCreated: onCreated)
          : await backend.createAndAttach(CreateAndAttachTests.request)
      } else {
        result = await coordinator.createAndAttach(
          CreateAndAttachTests.request, onCreated: onCreated)
      }
      let ids = Self.launchIDs(store)
      return CreateRun(
        result: Self.normalized(result, ids), announced: announced.withLock { $0 },
        creatorRequests: creator.requests, calls: Self.normalized(await iTerm2.calls, ids),
        store: Self.record(store))
    } // End of func run(_:throughBackend:announcing:)

    for outcome: Result<CreatedSession, SessionCreationError> in [
      .success(CreateAndAttachTests.created), .failure(.sessionExists(.duplicateSession)),
    ] {
      for announcing in [true, false] {
        let expected = await run(outcome, throughBackend: false, announcing: announcing)
        let actual = await run(outcome, throughBackend: true, announcing: announcing)
        #expect(actual == expected)
        #expect(actual.creatorRequests == [CreateAndAttachTests.request])
        if case .success = outcome {
          #expect(actual.result.isAttached)
          #expect(actual.announced == (announcing ? [CreateAndAttachTests.created] : []))
        } else {
          #expect(actual.result.creationFailure == .sessionExists(.duplicateSession))
          #expect(actual.announced.isEmpty && actual.calls.isEmpty)
        }
      } // End of loop over announcing and not
    } // End of loop over the creation outcomes
  } // End of func createAndAttachForwardsUnchanged()

  /// The current session by name, found and gone: the same answers, one discovery each, and
  /// nothing asked of iTerm2.
  @Test func currentSessionForwardsUnchanged() async {
    let direct = AttachCoordinatorTests.harness()
    let adapted = AttachCoordinatorTests.harness()
    let backend = ITerm2TerminalBackend(coordinator: adapted.coordinator)
    for name in ["fixture-session", "missing"] {
      let expected = await direct.coordinator.currentSession(named: name, on: Support.host)
      let actual = await backend.currentSession(named: name, on: Support.host)
      #expect(actual == expected)
    }
    #expect(
      await backend.currentSession(named: "fixture-session", on: Support.host)
        == .success(adapted.target))
    #expect(
      await backend.currentSession(named: "missing", on: Support.host) == .failure(.sessionGone))
    #expect(adapted.discovery.calls == direct.discovery.calls + 2)
    #expect(await adapted.iTerm2.calls.isEmpty)
  } // End of func currentSessionForwardsUnchanged()

  /// `items` as their descriptions, sorted: for requests the attachment index sends to several
  /// connections at once, whose order varies from run to run whoever calls the coordinator.
  static func unordered<Item>(_ items: [Item]) -> [String] {
    items.map { String(describing: $0) }.sorted()
  }

  /// Detaching a session's attachments this coordinator did not open: the same result, the
  /// same bound `detach-client` commands in the same order at the same virtual times, and the
  /// same iTerm2 calls (the index's concurrent identity checks in any order).
  @Test func detachSessionForwardsUnchanged() async {
    /// The scenario of `AttachFocusTests.detachesAttachmentsItDidNotOpen`.
    func harness() -> AttachFocusTests.Harness {
      let second = AttachFocusTests.connection("user-2", "user-tab-2")
      let both = [AttachFocusTests.userConnection, second]
      let harness = AttachFocusTests.harness { script in
        script.listTmuxConnections = .init(
          .success([]),
          queued: Array(repeating: .success(both), count: 5)
            + Array(repeating: .success([second]), count: 3))
      }
      let identity = Support.identityOutput(for: harness.key)
      harness.iTerm2.setAnswers([.success(identity)], for: "user")
      harness.iTerm2.setAnswers([.success(identity)], for: "user-2")
      return harness
    } // End of func harness()

    let direct = harness()
    let adapted = harness()
    let backend = ITerm2TerminalBackend(coordinator: adapted.coordinator)
    let expected = await direct.coordinator.detach(session: direct.key, on: Support.host)
    let result = await backend.detach(session: adapted.key, on: Support.host)
    #expect(result.outcome == .detached)
    #expect(result == expected)
    #expect(Self.unordered(adapted.iTerm2.sent) == Self.unordered(direct.iTerm2.sent))
    let detaches = { (harness: AttachFocusTests.Harness) in
      harness.iTerm2.sent.filter { $0.command == ConnectionIdentity.detachCommand }
    }
    #expect(detaches(adapted).map(\.connectionID) == ["user", "user-2"])
    #expect(detaches(adapted) == detaches(direct))
    #expect(Self.unordered(await adapted.fake.calls) == Self.unordered(await direct.fake.calls))
    #expect(adapted.discovery.calls == direct.discovery.calls)
  } // End of func detachSessionForwardsUnchanged()

  /// Detach other clients, confirmed and not: the same results and the same commands.
  @Test func detachOtherClientsForwardsUnchanged() async {
    let direct = DetachOtherClientsTests.harness()
    let adapted = DetachOtherClientsTests.harness()
    for harness in [direct, adapted] {
      DetachOtherClientsTests.answer(
        harness, lines: [DetachOtherClientsTests.ownLine, DetachOtherClientsTests.otherLine])
    }
    let backend = ITerm2TerminalBackend(coordinator: adapted.coordinator)
    let otherKey = Support.session(id: "$4").key
    let refusedDirect = await direct.coordinator.detachOtherClients(
      of: direct.target, confirmation: .detachOtherClients(of: otherKey))
    let refused = await backend.detachOtherClients(
      of: adapted.target, confirmation: .detachOtherClients(of: otherKey))
    #expect(refused.outcome == .notConfirmed)
    #expect(refused == refusedDirect)
    #expect(await adapted.fake.calls.isEmpty)
    let expected = await direct.coordinator.detachOtherClients(
      of: direct.target, confirmation: direct.confirmation)
    let result = await backend.detachOtherClients(
      of: adapted.target, confirmation: adapted.confirmation)
    #expect(result.outcome == .detached(count: 1))
    #expect(result == expected)
    #expect(adapted.commands == direct.commands)
    #expect(adapted.iTerm2.sent == direct.iTerm2.sent)
    #expect(await adapted.fake.calls == (await direct.fake.calls))
  } // End of func detachOtherClientsForwardsUnchanged()

  // MARK: - Focus

  /// A launch tab handle is "Show tab": the coordinator's result, unchanged, and the same
  /// restore and activation reach iTerm2; an id the coordinator did not open is
  /// `notOpenedHere` with nothing sent.
  @Test func focusOfALaunchTabIsShowTab() async {
    let direct = AttachCoordinatorTests.harness()
    let adapted = AttachCoordinatorTests.harness()
    let backend = ITerm2TerminalBackend(coordinator: adapted.coordinator)
    _ = await direct.coordinator.attach(direct.target)
    _ = await backend.attach(adapted.target)
    await direct.iTerm2.clearCalls()
    await adapted.iTerm2.clearCalls()
    let expected = await direct.coordinator.showLaunchTab(Support.gateway)
    let result = await backend.focus(.iTerm2LaunchTab(sessionID: Support.gateway))
    #expect(expected == .shown)
    #expect(result == .launchTab(expected))
    #expect(result.kind == "launchTab")
    #expect(await adapted.iTerm2.calls == (await direct.iTerm2.calls))
    #expect(
      await adapted.iTerm2.calls.first == .setBuried(buried: false, sessionID: Support.gateway))
    await adapted.iTerm2.clearCalls()
    #expect(
      await backend.focus(.iTerm2LaunchTab(sessionID: "user-session"))
        == .launchTab(.notOpenedHere))
    #expect(await adapted.iTerm2.calls.isEmpty)
  } // End of func focusOfALaunchTabIsShowTab()

  /// A plain window handle is refused with a typed result: nothing reaches the coordinator or
  /// iTerm2, before or after an attach, and the session's state is untouched.
  @Test func refusesAPlainWindowHandle() async throws {
    let harness = AttachCoordinatorTests.harness()
    let backend = ITerm2TerminalBackend(coordinator: harness.coordinator)
    let window = PlainTerminalWindow(
      openedBy: try Self.builtIn("terminal"), windowID: "4711",
      tty: "/dev/ttys004")
    let refused = await backend.focus(.plainWindow(window))
    #expect(refused == .handleOfAnotherTerminal)
    #expect(refused.kind == "handleOfAnotherTerminal")
    #expect(await harness.iTerm2.calls.isEmpty)
    #expect(harness.discovery.calls == 0)
    _ = await backend.attach(harness.target)
    let state = await backend.state(of: harness.target.key)
    let calls = await harness.iTerm2.calls
    #expect(await backend.focus(.plainWindow(window)) == .handleOfAnotherTerminal)
    #expect(await harness.iTerm2.calls == calls)
    #expect(await backend.state(of: harness.target.key) == state)
    #expect(harness.store.snapshot.written.count == 1)
  } // End of func refusesAPlainWindowHandle()
} // End of struct ITerm2TerminalBackendTests
