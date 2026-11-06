import Foundation
import Testing

@testable import MuxFinderCore
@testable import MuxFinderUI

/// "Detach other clients…" in the popover (PLAN.md D37, Phase I-11b) through the real
/// `AppModel`, the real `AttachCoordinator` and the real engine, over the fake iTerm2
/// (`SimulatedITerm2`, whose sessions have other tmux clients as state), fake discovery, an
/// in-memory launch store and a virtual clock: the offer rule, the confirmation, the pending
/// row, each outcome's line and recoveries, the host refresh afterwards, and quitting. Nothing
/// runs a process, opens a socket or contacts iTerm2, tmux or ssh.
@Suite("Session actions: detach other clients")
@MainActor
struct DetachOtherClientsUITests {
  /// Shorthand.
  typealias Support = UITestSupport
  /// Shorthand.
  typealias Fixtures = PreviewFixtures
  /// Shorthand.
  typealias TmuxClient = SimulatedITerm2.TmuxClient

  /// This Mac, the host of every test here.
  static let host = Support.localHost()

  /// This Mac's session `name` (session id `$<id>`) with `clients` tmux clients, as discovery
  /// lists it.
  static func session(_ name: String = "work-neptuno", id: Int = 1, clients: Int)
    -> DiscoveredSession
  {
    Fixtures.session(name, id: id, on: host, windows: 2, clients: clients).discovered
  }

  /// Another Mac's client `number`, created `age` seconds before the fake tmux clock.
  static func other(_ number: Int32, age: Int64 = 3_600) -> TmuxClient {
    TmuxClient(pid: 9_000 + number, created: 1_800_000_000 - age, name: "/dev/ttys00\(number)")
  }

  /// A started model over This Mac listing `sessions` (both discoveries), the engine's index
  /// showing each of them open here, a connection of the user's in the fake iTerm2 for each of
  /// `connected` (`user-conn-<n>`, in order), `others` as the sessions' other clients, and the
  /// popover open; returns once every session is listed with its client count and badge and
  /// the engine is settled. `holdAfter` stops the coordinator's clock.
  static func harness(
    sessions: [DiscoveredSession],
    connected: [SessionKey]? = nil,
    others: [SessionKey: [TmuxClient]] = [:],
    holdAfter: Duration? = nil
  ) async throws -> AttachHarness {
    let attachDiscovery = FakeDiscovery()
    attachDiscovery.setStatus(.ok(sessions), for: host.id)
    let harness = await AttachHarness.make(
      hosts: [host], holdAfter: holdAfter, index: FakeIndex(attached: sessions.map(\.key)),
      attachDiscovery: attachDiscovery)
    harness.discovery.setStatus(.ok(sessions), for: host.id)
    for (number, key) in (connected ?? sessions.map(\.key)).enumerated() {
      await harness.iTerm2.addUserConnection(
        "user-conn-\(number + 1)", owner: "user-tab-\(number + 1)", key: key)
    }
    await harness.iTerm2.configure { $0.otherClients = others }
    let model = harness.model
    model.popoverDidOpen()
    let listed = await Support.waitUntil {
      let rows = model.content.sections.flatMap(\.rows)
      return sessions.allSatisfy { session in
        rows.contains {
          $0.key == session.key && $0.isOpenInITerm2Here
            && $0.clientCount == session.attachedClientCount
        }
      }
    }
    #expect(listed)
    let engine = try #require(model.engine)
    #expect(await Support.waitUntil { await Support.isSettled(engine) })
    return harness
  } // End of static func harness(sessions:connected:others:holdAfter:)

  /// The popover's row of `key`.
  static func row(_ key: SessionKey, in model: AppModel) -> SessionRow? {
    model.content.sections.flatMap(\.rows).first { $0.key == key }
  }

  /// The `detach-client` commands sent through `connectionID`.
  static func detaches(_ harness: AttachHarness, through connectionID: String) async -> [String] {
    await harness.iTerm2.commands(to: connectionID).filter { $0.hasPrefix("detach-client") }
  }

  /// Confirms "Detach other clients…" for `key` and waits until it ended; returns its result.
  static func run(_ key: SessionKey, in harness: AttachHarness) async throws
    -> DetachOtherClientsResult
  {
    let model = harness.model
    let ended = model.finishedActions.count
    #expect(model.requestDetachOtherClients(key))
    model.confirmDetachOtherClients()
    #expect(await harness.waitForActions(ended + 1))
    await model.sessionEventsHandled()
    guard case .detachedOtherClients(let result) = model.finishedActions[ended].outcome else {
      throw TestFailure("not a detach of other clients")
    }
    return result
  } // End of static func run(_:in:)

  /// A test's own failure.
  struct TestFailure: Error, CustomStringConvertible {
    /// What went wrong.
    let description: String

    /// A failure saying `description`.
    init(_ description: String) {
      self.description = description
    }
  }

  // MARK: - The offer

  /// The offer rule over the popover's content: shown for a live row this Mac's iTerm2 shows
  /// with more clients than its attachments here (the index's count, or 1 for an attachment
  /// muxFinder made or found); hidden with one client, when not open here, on a stale row, on
  /// an unreachable host's row and before the first check. The badge gains "also attached
  /// elsewhere" exactly while it is offered, for VoiceOver too.
  @Test func offerRule() throws {
    /// The row of one Saturno session with `clients` clients and `attachments` here, after
    /// `outcome`, with muxFinder's own record of it when `recorded`.
    func row(
      clients: Int,
      attachments: Int,
      outcome: HostSnapshot.Outcome? = .sessionsListed,
      recorded: Bool = false
    ) throws -> SessionRow {
      var session = Fixtures.session(
        "build-farm", id: 60, on: Fixtures.saturno, windows: 4, clients: clients)
      session.attachments = (0..<attachments).map {
        AttachmentSnapshot.Attachment(
          key: session.key, connectionID: "c\($0)", owningSessionID: "o\($0)")
      }
      let snapshot = Fixtures.snapshot(
        Fixtures.saturno, outcome: outcome, sessions: [session], lastSuccessAgo: 60,
        lastAttemptAgo: 5)
      let content = PopoverContent(
        state: Fixtures.state([snapshot]), hostList: .saved, query: "", activities: [:],
        selection: nil, now: Fixtures.now, attachedHere: recorded ? [session.key] : [])
      return try #require(content.sections.first?.rows.first)
    } // End of func row(clients:attachments:outcome:recorded:)

    let offered = try row(clients: 2, attachments: 1)
    #expect(offered.offersDetachOtherClients)
    #expect(offered.attachmentsHere == 1)
    #expect(offered.openHereText == "Open in iTerm2 here · also attached elsewhere")
    #expect(
      offered.accessibilityValue
        == "4 windows · 2 clients, Open in iTerm2 here, also attached elsewhere")
    let one = try row(clients: 1, attachments: 1)
    #expect(!one.offersDetachOtherClients)
    #expect(one.openHereText == SessionRow.openHereBadge)
    #expect(!one.accessibilityValue.contains("elsewhere"))
    #expect(!(try row(clients: 2, attachments: 0)).offersDetachOtherClients)
    #expect(
      !(try row(clients: 2, attachments: 1, outcome: .failed(.authFailed)))
        .offersDetachOtherClients)
    let unreachable = try row(
      clients: 3, attachments: 1, outcome: .failed(.unreachable(.timeout)))
    #expect(unreachable.isStale && !unreachable.offersDetachOtherClients)
    #expect(!unreachable.openHereText.contains("elsewhere"))
    #expect(!(try row(clients: 2, attachments: 1, outcome: nil)).offersDetachOtherClients)
    #expect(try row(clients: 2, attachments: 0, recorded: true).offersDetachOtherClients)
    #expect(!(try row(clients: 1, attachments: 0, recorded: true)).offersDetachOtherClients)
    #expect(!(try row(clients: 2, attachments: 2)).offersDetachOtherClients)
    let twoHere = try row(clients: 3, attachments: 2, recorded: true)
    #expect(twoHere.attachmentsHere == 2 && twoHere.offersDetachOtherClients)
    #expect(
      !SessionRow.offersDetachOtherClients(isLive: false, clientCount: 5, attachmentsHere: 1))
  } // End of func offerRule()

  /// The model offers it under the same rule: with two clients the confirmation shows the
  /// session and one other client; with one client nothing shows and nothing is contacted.
  @Test func offerInTheModel() async throws {
    let two = try await Self.harness(sessions: [Self.session(clients: 2)])
    let key = Self.session(clients: 2).key
    let row = try #require(Self.row(key, in: two.model))
    #expect(row.offersDetachOtherClients && !row.isPending)
    #expect(row.openHereText.hasSuffix("also attached elsewhere"))
    #expect(two.model.requestDetachOtherClients(key))
    guard case .detachOtherClients(let request) = two.model.panel else {
      Issue.record("no Detach other clients dialog")
      return
    }
    #expect(request.target.key == key)
    #expect(request.otherClients == 1 && request.otherClientsHere == 0)
    #expect(request.title == "Detach other clients of “work-neptuno”?")
    #expect(request.clientsText == "1 other client was attached when muxFinder last looked.")
    #expect(request.explanation.contains("other Macs"))
    #expect(request.explanation.contains("keeps running"))
    #expect(
      DetachOtherClientsRequest.windowSizeText
        == "While another client is attached, tmux may keep the window at the other client's size."
    )
    #expect(DetachOtherClientsRequest.confirmTitle == "Detach other clients")
    await two.model.shutdown()

    let one = try await Self.harness(sessions: [Self.session(clients: 1)])
    #expect(Self.row(key, in: one.model)?.offersDetachOtherClients == false)
    #expect(!one.model.requestDetachOtherClients(key))
    #expect(one.model.panel == nil)
    #expect(one.builds.value == 0)
    #expect(await one.iTerm2.sent.isEmpty)
    await one.model.shutdown()
  } // End of func offerInTheModel()

  /// The confirmation's count says how many of the other clients are in this Mac's iTerm2 when
  /// it has more than one attachment of the session.
  @Test func confirmationCountsThisMacsOtherAttachments() {
    let target = AttachTarget(host: Self.host, session: Self.session(clients: 4))
    #expect(
      DetachOtherClientsRequest(target: target, otherClients: 3, otherClientsHere: 1).clientsText
        == "3 other clients were attached when muxFinder last looked, including 1 in this Mac's "
        + "iTerm2.")
    #expect(
      DetachOtherClientsRequest(target: target, otherClients: 2).clientsText
        == "2 other clients were attached when muxFinder last looked.")
  }

  /// While another action of the row is pending (here a Detach from this Mac waiting for the
  /// user's tab to be old enough), the item stays shown but disabled (`isPending`) and asking
  /// for it shows nothing.
  @Test func disabledWhileAnotherActionIsPending() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], others: [key: [Self.other(1)]],
      holdAfter: .seconds(5))
    let model = harness.model
    model.detach(key)
    #expect(model.isPending(key))
    let row = try #require(Self.row(key, in: model))
    #expect(row.offersDetachOtherClients && row.isPending)
    #expect(!model.requestDetachOtherClients(key))
    #expect(model.panel == nil)
    await model.shutdown()
    #expect(await Self.detaches(harness, through: "user-conn-1").isEmpty)
    #expect(await harness.iTerm2.otherClients[key]?.count == 1)
  } // End of func disabledWhileAnotherActionIsPending()

  // MARK: - The confirmation

  /// Cancel and Esc run nothing (no coordinator, no iTerm2 request); while the dialog shows the
  /// arrows, ⌘F and ⌘N do nothing; VoiceOver hears each dialog's title (Move here's too);
  /// Return confirms.
  @Test func cancelAndEscRunNothing() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], others: [key: [Self.other(1)]])
    let model = harness.model
    let recorder = AnnouncementRecorder()
    model.announce = { recorder.said.append($0) }
    let title = "Detach other clients of “work-neptuno”?"
    #expect(model.requestDetachOtherClients(key))
    model.cancelPanel()
    #expect(model.panel == nil)
    #expect(model.requestDetachOtherClients(key))
    let selection = model.selection
    #expect(model.handle(.down) == .handled)
    #expect(model.selection == selection)
    #expect(model.handle(.find) == .handled)
    #expect(model.searchFocusRequests == 0)
    #expect(model.handle(.newSession) == .handled)
    #expect(!model.isNewSessionShown)
    #expect(model.handle(.close) == .handled)
    #expect(model.panel == nil)
    model.confirmDetachOtherClients()
    #expect(harness.builds.value == 0)
    #expect(await harness.iTerm2.sent.isEmpty)
    #expect(model.finishedActions.isEmpty)
    #expect(recorder.said == [title, title])
    model.requestMoveHere(key)
    #expect(recorder.said.last == "Move “work-neptuno” here?")
    model.cancelPanel()

    #expect(model.requestDetachOtherClients(key))
    #expect(model.handle(.open) == .handled)
    #expect(model.panel == nil)
    #expect(model.activities[key] == .detachingOtherClients)
    #expect(await harness.waitForActions(1))
    #expect(
      await Self.detaches(harness, through: "user-conn-1") == ["detach-client -t '/dev/ttys001'"])
    await model.shutdown()
  } // End of func cancelAndEscRunNothing()

  /// The confirm passes only the key of the session the dialog names: asked for one session
  /// and then another, it detaches the other clients of the second only, through that
  /// session's own connection; without a dialog it does nothing.
  @Test func confirmPassesOnlyTheShownSessionsKey() async throws {
    let first = Self.session(clients: 2)
    let second = Self.session("logs", id: 2, clients: 2)
    let harness = try await Self.harness(
      sessions: [first, second],
      others: [first.key: [Self.other(1)], second.key: [Self.other(2)]])
    let model = harness.model
    #expect(model.requestDetachOtherClients(first.key))
    #expect(model.requestDetachOtherClients(second.key))
    let result = try await Self.run(second.key, in: harness)
    #expect(result.key == second.key)
    #expect(result.outcome == .detached(count: 1))
    #expect(await Self.detaches(harness, through: "user-conn-1").isEmpty)
    #expect(
      await Self.detaches(harness, through: "user-conn-2") == ["detach-client -t '/dev/ttys002'"])
    #expect(await harness.iTerm2.otherClients[first.key] == [Self.other(1)])
    #expect(model.activities[first.key] == nil)
    model.confirmDetachOtherClients()
    await model.sessionEventsHandled()
    #expect(model.finishedActions.count == 1)
    await model.shutdown()
  } // End of func confirmPassesOnlyTheShownSessionsKey()

  // MARK: - Outcomes

  /// A detach of one other client: "Detached 1 other client — the session keeps running", the
  /// client gone, no tab closed, and the host refreshed afterwards; with another client that
  /// left before its check, the line says so.
  @Test func detachedThenTheHostIsRefreshed() async throws {
    let key = Self.session(clients: 3).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 3)], others: [key: [Self.other(1), Self.other(2)]])
    let model = harness.model
    await harness.iTerm2.configure { $0.leavesAfterListing = ["/dev/ttys002"] }
    let before = harness.discovery.calls(of: Self.host.id)
    let result = try await Self.run(key, in: harness)
    #expect(result.outcome == .detached(count: 1))
    #expect(result.goneBeforeDetach == 1)
    #expect(model.activities[key] == .detachedOtherClients(count: 1, alreadyLeft: 1))
    #expect(
      model.activities[key]?.text
        == "Detached 1 other client — the session keeps running (1 had already left)")
    #expect(model.activities[key]?.isDone == true)
    #expect(
      await Self.detaches(harness, through: "user-conn-1") == ["detach-client -t '/dev/ttys001'"])
    #expect(await harness.iTerm2.otherClients[key]?.isEmpty == true)
    #expect(await harness.iTerm2.closeCount == 0)
    #expect(await Support.waitUntil { harness.discovery.calls(of: Self.host.id) > before })
    #expect(!model.isPending(key))
    model.popoverDidClose()
    model.popoverDidOpen()
    #expect(model.activities[key] == nil, "a result is cleared when the popover opens again")
    await model.shutdown()
  } // End of func detachedThenTheHostIsRefreshed()

  /// Every other client gone by its check: the informational "No other clients to detach —
  /// they had already left", not a failure; nothing detached; the host refreshed.
  @Test func nothingToDetachIsInformational() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], others: [key: [Self.other(1)]])
    let model = harness.model
    await harness.iTerm2.configure { $0.leavesAfterListing = ["/dev/ttys001"] }
    let before = harness.discovery.calls(of: Self.host.id)
    let result = try await Self.run(key, in: harness)
    #expect(result.outcome == .nothingToDetach)
    #expect(model.activities[key] == .noOtherClientsLeft)
    #expect(model.activities[key]?.problem == nil)
    #expect(model.activities[key]?.text == "No other clients to detach — they had already left")
    #expect(await Self.detaches(harness, through: "user-conn-1").isEmpty)
    #expect(await Support.waitUntil { harness.discovery.calls(of: Self.host.id) > before })
    await model.shutdown()
  } // End of func nothingToDetachIsInformational()

  /// This Mac's iTerm2 no longer shows the session (no connection of it): its line with
  /// "Refresh", the attachment muxFinder recorded forgotten, nothing sent, the host refreshed.
  @Test func notAttachedHereAnyMore() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], connected: [], others: [key: [Self.other(1)]])
    let model = harness.model
    model.attachedHere[key] = AttachmentRecord(connectionID: "gone", gatewaySessionID: "gone-tab")
    let before = harness.discovery.calls(of: Self.host.id)
    let result = try await Self.run(key, in: harness)
    #expect(result.outcome == .notAttachedHere)
    let problem = try #require(model.activities[key]?.problem)
    #expect(problem.message.hasPrefix("This Mac's iTerm2 no longer shows this session"))
    #expect(problem.recoveries == [.refresh])
    #expect(model.attachedHere[key] == nil)
    #expect(await harness.iTerm2.sent.isEmpty)
    #expect(await Support.waitUntil { harness.discovery.calls(of: Self.host.id) > before })
    model.perform(.refresh, for: key)
    #expect(model.activities[key] == nil)
    await model.shutdown()
  } // End of func notAttachedHereAnyMore()

  /// tmux refusing a detach (D37's residual): its own line with "Refresh" only, the host
  /// refreshed.
  @Test func tmuxRefusedADetach() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], others: [key: [Self.other(1)]])
    let model = harness.model
    await harness.iTerm2.configure { $0.detachClientError = .tmuxCommandFailed }
    let before = harness.discovery.calls(of: Self.host.id)
    let result = try await Self.run(key, in: harness)
    #expect(result.outcome == .checkFailed(.send(.tmuxCommandFailed)))
    let problem = try #require(model.activities[key]?.problem)
    #expect(problem.message.hasPrefix("tmux refused to detach one of the other clients"))
    #expect(problem.recoveries == [.refresh])
    #expect(await Support.waitUntil { harness.discovery.calls(of: Self.host.id) > before })
    await model.shutdown()
  } // End of func tmuxRefusedADetach()

  /// A send that failed otherwise offers "Try again", which shows the confirmation again (its
  /// counts the listing's), and "Refresh".
  @Test func tryAgainShowsTheConfirmationAgain() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], others: [key: [Self.other(1)]])
    let model = harness.model
    await harness.iTerm2.configure { $0.detachClientError = .timedOut }
    let result = try await Self.run(key, in: harness)
    #expect(result.outcome == .checkFailed(.send(.timedOut)))
    let problem = try #require(model.activities[key]?.problem)
    #expect(problem.recoveries == [.retry, .refresh])
    #expect(problem.fixIt == nil)
    model.perform(.retry, for: key)
    #expect(model.activities[key] == nil)
    guard case .detachOtherClients(let request) = model.panel else {
      Issue.record("Try again did not show the confirmation")
      return
    }
    #expect(request.target.key == key && request.otherClients == 1)
    model.cancelPanel()
    #expect(model.finishedActions.count == 1)
    await model.shutdown()
  } // End of func tryAgainShowsTheConfirmationAgain()

  // MARK: - Try again from the switcher

  /// Opens the session switcher over the failed `key` of `harness` (the popover closing, as
  /// the real handoff does) and checks its row: the failure's message with `others` as its
  /// recoveries, no "Try again"; a retry there anyway (no view offers it) keeps the failure,
  /// sets no confirmation, starts nothing and contacts no iTerm2. Then closes the switcher and
  /// opens the popover again, whose row offers "Try again" with the same failure.
  static func expectNoRetryInTheSwitcher(
    _ key: SessionKey,
    offering others: [SessionProblem.Recovery],
    in harness: AttachHarness
  ) async throws {
    let model = harness.model
    model.closePopover = { [weak model] _ in model?.popoverVisibilityChanged(false) }
    let failure = try #require(model.activities[key])
    let problem = try #require(failure.problem)
    #expect(problem.recoveries.contains(.retry))
    let ended = model.finishedActions.count
    let sent = await harness.iTerm2.sent.count
    model.switcherVisibilityChanged(true)
    #expect(model.isSwitcherVisible && !model.isPopoverVisible)
    let row = try #require(model.switcherContent.rows.first { $0.key == key })
    #expect(row.activity?.problem?.message == problem.message)
    #expect(row.activity?.problem?.recoveries == others)
    model.perform(.retry, for: key)
    #expect(model.panel == nil)
    #expect(model.activities[key] == failure)
    #expect(!model.isPending(key))
    await model.sessionEventsHandled()
    #expect(model.finishedActions.count == ended)
    #expect(await harness.iTerm2.sent.count == sent)
    model.switcherVisibilityChanged(false)
    model.popoverVisibilityChanged(true)
    #expect(model.isPopoverVisible && !model.isSwitcherVisible)
    #expect(Self.row(key, in: model)?.activity?.problem?.recoveries == problem.recoveries)
  } // End of static func expectNoRetryInTheSwitcher(_:offering:in:)

  /// A "Detach other clients…" whose send failed, seen from the session switcher (the review
  /// of Phase I-11b): its row there offers "Refresh" but no "Try again", and a retry there sets
  /// no confirmation in the hidden popover; the popover's "Try again" shows the confirmation,
  /// and nothing is sent until it is confirmed.
  @Test func aFailedDetachOtherClientsRetriesOnlyFromThePopover() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], others: [key: [Self.other(1)]])
    let model = harness.model
    await harness.iTerm2.configure { $0.detachClientError = .timedOut }
    let failed = try await Self.run(key, in: harness)
    #expect(failed.outcome == .checkFailed(.send(.timedOut)))
    try await Self.expectNoRetryInTheSwitcher(key, offering: [.refresh], in: harness)

    let sent = await harness.iTerm2.sent.count
    model.perform(.retry, for: key)
    guard case .detachOtherClients(let request) = model.panel else {
      Issue.record("the popover's Try again did not show the confirmation")
      await model.shutdown()
      return
    }
    #expect(request.target.key == key)
    #expect(model.activities[key] == nil && !model.isPending(key))
    await model.sessionEventsHandled()
    #expect(model.finishedActions.count == 1)
    #expect(await harness.iTerm2.sent.count == sent)
    await harness.iTerm2.configure { $0.detachClientError = nil }
    model.confirmDetachOtherClients()
    #expect(model.panel == nil)
    #expect(await harness.waitForActions(2))
    await model.sessionEventsHandled()
    guard case .detachedOtherClients(let result) = model.finishedActions[1].outcome else {
      Issue.record("not a detach of other clients")
      await model.shutdown()
      return
    }
    #expect(result.outcome == .detached(count: 1))
    #expect(await harness.iTerm2.otherClients[key]?.isEmpty == true)
    await model.shutdown()
  } // End of func aFailedDetachOtherClientsRetriesOnlyFromThePopover()

  /// A move here that failed (tmux missing when the coordinator looked again), seen from the
  /// session switcher: its row there offers "Open Settings" but no "Try again", and a retry
  /// there sets no confirmation in the hidden popover; the popover's "Try again" shows the Move
  /// here confirmation, and nothing is asked or launched until it is confirmed.
  @Test func aFailedMoveHereRetriesOnlyFromThePopover() async throws {
    let attachDiscovery = FakeDiscovery()
    let harness = await AttachHarness.make(attachDiscovery: attachDiscovery)
    let model = harness.model
    let host = harness.hosts[0]
    let key = harness.key(on: host)
    model.popoverDidOpen()
    attachDiscovery.setStatus(.tmuxNotFound, for: host.id)
    model.requestMoveHere(key)
    model.confirmMoveHere()
    #expect(await harness.waitForActions(1))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .failed(.attach(.tmuxMissing)))
    try await Self.expectNoRetryInTheSwitcher(key, offering: [.openSettings], in: harness)

    let asked = attachDiscovery.calls(of: host.id)
    model.perform(.retry, for: key)
    guard case .moveHere(let request) = model.panel else {
      Issue.record("the popover's Try again did not show the Move here confirmation")
      await model.shutdown()
      return
    }
    #expect(request.target.key == key)
    #expect(model.activities[key] == nil && !model.isPending(key))
    await model.sessionEventsHandled()
    #expect(model.finishedActions.count == 1)
    #expect(attachDiscovery.calls(of: host.id) == asked)
    #expect(await harness.iTerm2.createTabCount == 0)
    #expect(harness.store.written.isEmpty)
    attachDiscovery.setStatus(.ok([FakeDiscovery.session(on: host)]), for: host.id)
    model.confirmMoveHere()
    #expect(model.panel == nil && model.activities[key] == .movingHere)
    #expect(await harness.waitForActions(2))
    await model.sessionEventsHandled()
    #expect(model.activities[key] == .confirmed)
    #expect(harness.store.written.map(\.detachesOtherClients) == [true])
    await model.shutdown()
  } // End of func aFailedMoveHereRetriesOnlyFromThePopover()

  /// `cancelled` shows nothing and `notConfirmed` (unreachable from the UI) a failure with
  /// "Refresh"; neither refreshes the host.
  @Test func cancelledAndNotConfirmedDoNotRefresh() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(sessions: [Self.session(clients: 2)])
    let model = harness.model
    let engine = try #require(model.engine)
    let before = harness.discovery.calls(of: Self.host.id)
    model.finish(
      key, .detachedOtherClients(DetachOtherClientsResult(key: key, outcome: .notConfirmed)))
    #expect(model.activities[key]?.problem?.recoveries == [.refresh])
    model.finish(
      key, .detachedOtherClients(DetachOtherClientsResult(key: key, outcome: .cancelled)))
    #expect(model.activities[key] == nil)
    await model.engineRequestsHandled()
    #expect(await Support.waitUntil { await Support.isSettled(engine) })
    #expect(harness.discovery.calls(of: Self.host.id) == before)
    await model.shutdown()
  } // End of func cancelledAndNotConfirmedDoNotRefresh()

  /// While the call waits for a young other client, the row shows "Detaching other clients…",
  /// clicks on it are ignored and the item is disabled; quitting cancels the call: it ends
  /// `cancelled` within the budget, sends no detach, and the row shows nothing.
  @Test func shutdownCancelsAPendingCall() async throws {
    let key = Self.session(clients: 2).key
    let harness = try await Self.harness(
      sessions: [Self.session(clients: 2)], others: [key: [Self.other(1, age: 0)]],
      holdAfter: .seconds(5))
    let model = harness.model
    #expect(model.requestDetachOtherClients(key))
    model.confirmDetachOtherClients()
    let listing = OtherClientsCommands.clients(of: key.sessionID)
    #expect(
      await Support.waitUntil {
        await harness.iTerm2.commands(to: "user-conn-1").contains(listing)
      })
    let row = try #require(Self.row(key, in: model))
    #expect(row.activity?.text == "Detaching other clients…")
    #expect(row.activity?.isInProgress == true)
    #expect(row.isPending)
    model.open(key)
    #expect(!model.requestDetachOtherClients(key))
    #expect(model.finishedActions.isEmpty)
    let report = await model.shutdown()
    #expect(report.isComplete)
    #expect(await harness.iTerm2.focusedConnections.isEmpty)
    guard case .detachedOtherClients(let result)? = model.finishedActions.first?.outcome else {
      Issue.record("the call did not end")
      return
    }
    #expect(result.outcome == .cancelled)
    #expect(result.ageWait > .zero)
    #expect(model.activities[key] == nil)
    #expect(await Self.detaches(harness, through: "user-conn-1").isEmpty)
    #expect(await harness.iTerm2.otherClients[key]?.count == 1)
  } // End of func shutdownCancelsAPendingCall()

  // MARK: - Messages

  /// One sample of every outcome (each `checkFailed` problem kind, and a detach tmux refused).
  nonisolated static let outcomes: [DetachOtherClientsResult.Outcome] = [
    .detached(count: 1), .detached(count: 3), .nothingToDetach, .notAttachedHere,
    .identityChanged, .checkFailed(.attachmentCheck(.attachmentCheckFailed(.apiDisabled))),
    .checkFailed(.identityCheck(.timedOut)), .checkFailed(.clientListing(nil)),
    .checkFailed(.send(.tmuxCommandFailed)), .checkFailed(.send(.automationDenied)),
    .notConfirmed, .cancelled,
  ]

  /// Each outcome's line: pairwise distinct (and distinct from Detach from this Mac's), the
  /// failures through `SessionProblem` with the recoveries listed (PLAN.md D37), D23's fix-it
  /// for iTerm2 permission and API errors, nothing for `cancelled`.
  @Test func eachOutcomeHasItsOwnLine() {
    let key = Self.session(clients: 2).key
    let activities = Self.outcomes.map {
      AppModel.activity(after: DetachOtherClientsResult(key: key, outcome: $0))
    }
    #expect(activities.last == .some(nil))
    let left = AppModel.activity(
      after: DetachOtherClientsResult(key: key, outcome: .detached(count: 2), goneBeforeDetach: 1))
    let texts =
      (activities.compactMap { $0 } + [left].compactMap { $0 }).map(\.text) + [
        SessionActivity.detached.text, SessionActivity.detachingOtherClients.text,
      ]
    #expect(texts.count == 14)
    #expect(Set(texts).count == texts.count)
    #expect(activities[0]?.text == "Detached 1 other client — the session keeps running")
    #expect(activities[1]?.text == "Detached 3 other clients — the session keeps running")
    #expect(activities[2] == .noOtherClientsLeft)
    let problems = Self.outcomes.map {
      SessionProblem.detachOtherClients(DetachOtherClientsResult(key: key, outcome: $0))
    }
    #expect(problems[0] == nil && problems[1] == nil && problems[2] == nil && problems[11] == nil)
    for index in [3, 4, 8, 10] { #expect(problems[index]?.recoveries == [.refresh], "\(index)") }
    for index in [5, 6, 7, 9] {
      #expect(problems[index]?.recoveries == [.retry, .refresh], "\(index)")
    }
    #expect(problems[5]?.fixIt == .explainPythonAPI)
    #expect(problems[9]?.fixIt == .openAutomationSettings)
    #expect(
      problems[3]?.message.hasPrefix("This Mac's iTerm2 no longer shows this session") == true)
    for (index, activity) in activities.enumerated() {
      #expect(activity?.problem == problems[index], "\(index)")
    }
  } // End of func eachOutcomeHasItsOwnLine()

  /// The gallery's fixtures show both dialogs (one other client; two, one of them here), the
  /// pending row and every result, from synthetic data; the context menu's open-here row offers
  /// the item, and the popover gallery shows the hint.
  @Test func galleriesShowEveryState() {
    let panels = AttachFixtures.all.compactMap { fixture -> DetachOtherClientsRequest? in
      if case .detachOtherClients(let request)? = fixture.panel { return request }
      return nil
    }
    #expect(panels.map(\.otherClients) == [1, 2])
    #expect(panels.map(\.otherClientsHere) == [0, 1])
    let activities = AttachFixtures.all.flatMap { $0.activities.values }
    #expect(activities.contains(.detachingOtherClients))
    #expect(activities.contains(.noOtherClientsLeft))
    #expect(activities.contains(.detachedOtherClients(count: 1, alreadyLeft: 0)))
    #expect(activities.contains(.detachedOtherClients(count: 2, alreadyLeft: 1)))
    let key = Self.session(clients: 2).key
    let messages = Set(activities.compactMap(\.problem?.message))
    for outcome in Self.outcomes where outcome != .checkFailed(.send(.automationDenied)) {
      guard
        let problem = SessionProblem.detachOtherClients(
          DetachOtherClientsResult(key: key, outcome: outcome)),
        outcome != .checkFailed(.identityCheck(.timedOut)),
        outcome != .checkFailed(.clientListing(nil))
      else { continue }
      #expect(messages.contains(problem.message), "\(outcome.kind)")
    }
    #expect(AttachFixtures.menuRows.map(\.offersDetachOtherClients) == [true, false])
    let popoverRows = PreviewFixtures.all.compactMap(\.state).flatMap { state in
      PopoverContent(
        state: state, hostList: .saved, query: "", activities: [:], selection: nil,
        now: Fixtures.now
      ).sections.flatMap(\.rows)
    }
    #expect(popoverRows.contains { $0.isOpenInITerm2Here && $0.offersDetachOtherClients })
  } // End of func galleriesShowEveryState()
}
