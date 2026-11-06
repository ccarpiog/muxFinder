import Foundation
import Testing

@testable import MuxFinderCore

/// "Detach other clients" (PLAN.md D37): `AttachCoordinator.detachOtherClients(of:confirmation:)`
/// with its session-key confirmation, the attachment it keeps, the identity check right before
/// anything is asked, the read-only listing, the check right before each detach, and every typed
/// result; `OtherClientsCommands`' commands and the reading of their answers. Fakes for iTerm2,
/// discovery, the launch store and the clocks; the index's clock is never advanced, so only
/// answers decide its outcomes.
@Suite("Attach coordinator: detach other clients")
struct DetachOtherClientsTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The fakes of one test.
  struct Harness {
    /// The session.
    let session: DiscoveredSession
    /// iTerm2's fake (every call is logged here).
    let fake: FakeITerm2Integration
    /// The wrapper the coordinator talks to (per-command answers, sent-command times).
    let iTerm2: InstrumentedITerm2
    /// Discovery.
    let discovery: FakeDiscovery
    /// The coordinator's clock.
    let clock: ManualAttachClock
    /// The coordinator.
    let coordinator: AttachCoordinator

    /// The target.
    var target: AttachTarget { AttachTarget(host: Support.host, session: session) }
    /// The session key.
    var key: SessionKey { session.key }
    /// The confirmation for this session.
    var confirmation: DetachOtherClientsConfirmation { .detachOtherClients(of: key) }

    /// The tmux commands sent, in order.
    var commands: [String] { iTerm2.sent.map(\.command) }
  }

  /// A connection `id` owned by `owner`.
  static func connection(_ id: String, _ owner: String) -> ITerm2API.TmuxConnection {
    ITerm2API.TmuxConnection(connectionID: id, owningSessionID: owner)
  }

  /// The user's attachment of the session: connection `user` in the tab `user-tab`.
  static let userConnection = connection("user", "user-tab")
  /// The kept connection's own client name.
  static let ownName = "/dev/ttys004"
  /// tmux's clock when the own client's name is read (seconds since 1970).
  static let serverTime: Int64 = 1_800_000_000
  /// A creation time an hour before `serverTime`: a client that needs no wait.
  static let longAgo = String(serverTime - 3600)
  /// The other client in most tests: a client without a terminal (another Mac's, say), created
  /// long ago.
  static let other = OtherClient(processID: "4321", created: longAgo, name: "client-4321")!
  /// The other client's listing line.
  static let otherLine = "4321:\(longAgo):client-4321"

  /// A harness whose iTerm2 lists `connections` (every listing, unless `script` changes it)
  /// and answers every identity check with the session's identity.
  static func harness(
    connections: [ITerm2API.TmuxConnection] = [userConnection],
    status: HostStatus? = nil,
    holdsSleeps: Bool = false,
    script: ((inout FakeITerm2Integration.Script) -> Void)? = nil
  ) -> Harness {
    let session = Support.session()
    var fakeScript = Support.successScript(for: session)
    fakeScript.listTmuxConnections = .init(.success(connections))
    script?(&fakeScript)
    let fake = FakeITerm2Integration(script: fakeScript)
    let clock = ManualAttachClock(holdsSleeps: holdsSleeps)
    let iTerm2 = InstrumentedITerm2(fake, clock: clock)
    let discovery = FakeDiscovery(status ?? .ok([session]))
    let coordinator = Support.coordinator(
      iTerm2: iTerm2, discovery: discovery, store: FakeLaunchStore(), clock: clock,
      existingAttachments: .index(Support.patientIndex(iTerm2)))
    return Harness(
      session: session, fake: fake, iTerm2: iTerm2, discovery: discovery, clock: clock,
      coordinator: coordinator)
  } // End of func harness(connections:status:holdsSleeps:script:)

  /// Scripts the reads through the kept connection: its own name with tmux's clock
  /// (`serverTime`), the session's listing (`lines`, one `<pid>:<created>:<name>` each) and
  /// each check's answer.
  static func answer(
    _ harness: Harness,
    own: String = ownName,
    lines: [String],
    checks: [Result<String, ITerm2Error>] = [.success("4321\n")]
  ) {
    let id = harness.key.sessionID
    harness.iTerm2.setAnswers(
      [.success("\(serverTime) \(own)\n")], forCommand: OtherClientsCommands.ownClientAndTime)
    harness.iTerm2.setAnswers(
      [.success(lines.joined(separator: "\n") + "\n")],
      forCommand: OtherClientsCommands.clients(of: id))
    harness.iTerm2.setAnswers(checks, forCommand: OtherClientsCommands.check(other, of: id))
  } // End of func answer(_:own:lines:checks:)

  /// The listing line of the kept connection's own client.
  static let ownLine = "1000:\(longAgo):\(ownName)"

  /// The commands a full run through one connection sends for `client`: the index's identity
  /// check, the re-check, the own name with tmux's clock, the listing, the check and the
  /// detach.
  static func fullRun(_ key: SessionKey, client: OtherClient = other) -> [String] {
    [
      ConnectionIdentity.command, ConnectionIdentity.command,
      OtherClientsCommands.ownClientAndTime,
      OtherClientsCommands.clients(of: key.sessionID),
      OtherClientsCommands.check(client, of: key.sessionID), OtherClientsCommands.detach(client),
    ]
  }

  // MARK: - Confirmation

  /// A confirmation naming another key (the same tmux session under another host id, or
  /// another session) runs nothing: no discovery, no iTerm2 request, no wait.
  @Test func confirmationForAnotherKeyRunsNothing() async throws {
    let harness = Self.harness()
    Self.answer(harness, lines: [Self.ownLine, Self.otherLine])
    let otherHost = SessionKey(
      hostID: UUID(), server: harness.key.server, sessionID: harness.key.sessionID)
    let otherSession = Support.session(id: "$4").key
    for key in [otherHost, otherSession] {
      let result = await harness.coordinator.detachOtherClients(
        of: harness.target, confirmation: .detachOtherClients(of: key))
      #expect(result.outcome == .notConfirmed)
      #expect(result.kept == nil && result.counts == nil && !result.mayHaveSent)
    }
    #expect(harness.discovery.calls == 0)
    #expect(await harness.fake.calls.isEmpty)
    #expect(harness.clock.elapsed == .zero)
    #expect(DetachOtherClientsConfirmation.detachOtherClients(of: otherHost).key == otherHost)
  } // End of func confirmationForAnotherKeyRunsNothing()

  // MARK: - Detached

  /// The session is attached here once and has one other client: the identity is checked again,
  /// the own name and the listing are read, the other client is checked right before its
  /// detach, and `detach-client -t <name>` goes out once, every request bound to the tab that
  /// owns the connection. Nothing else is sent; no tab is created, closed or activated.
  @Test func detachesTheOtherClient() async throws {
    let harness = Self.harness()
    Self.answer(harness, lines: [Self.ownLine, Self.otherLine])
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .detached(count: 1))
    #expect(
      result.kept
        == .init(key: harness.key, connectionID: "user", owningSessionID: "user-tab"))
    #expect(result.otherAttachmentsHere == 0)
    #expect(result.listedOthers == 1 && result.goneBeforeDetach == 0)
    #expect(result.detachedClients == 1 && result.mayHaveSent)
    #expect(result.counts == .init(mapped: 1))
    #expect(harness.commands == Self.fullRun(harness.key))
    #expect(harness.iTerm2.sent.allSatisfy { $0.connectionID == "user" && $0.at == .zero })
    let calls = await harness.fake.calls
    let owners = calls.compactMap { call -> String? in
      if case .sendOwnedTmuxCommand(_, _, let owner) = call { return owner }
      return nil
    }
    #expect(owners.count == 6 && owners.allSatisfy { $0 == "user-tab" })
    #expect(
      !calls.contains { call in
        switch call {
        case .sendTmuxCommand, .createTab, .close, .activate, .activateOwnedTmuxTab, .setBuried,
          .buryLaunchTab, .ensureRunning:
          return true
        default: return false
        }
      })
  } // End of func detachesTheOtherClient()

  /// Clients on a terminal (another Mac's iTerm2) are detached by their terminal's name.
  @Test func detachesAClientOnATerminal() async throws {
    let harness = Self.harness()
    let remote = try #require(
      OtherClient(processID: "77", created: Self.longAgo, name: "/dev/ttys012"))
    let id = harness.key.sessionID
    Self.answer(harness, lines: [Self.ownLine, "77:\(Self.longAgo):/dev/ttys012"])
    harness.iTerm2.setAnswers(
      [.success("77\n")], forCommand: OtherClientsCommands.check(remote, of: id))
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .detached(count: 1))
    #expect(harness.commands == Self.fullRun(harness.key, client: remote))
    #expect(harness.commands.last == "detach-client -t '/dev/ttys012'")
  } // End of func detachesAClientOnATerminal()

  // MARK: - Commands

  /// Every command holds only the validated session id, pid, creation time and name,
  /// single-quoted; nothing else of the run is inserted, and no command detaches more than one
  /// named client. The read-only listing and check filter the server's clients instead of
  /// naming the session with `-t` (which fails once the session is gone, an error iTerm2 3.7
  /// answers by ending the connection), and the check binds the client's session id and
  /// creation time besides its name and pid.
  @Test func commandsHoldOnlyValidatedValues() throws {
    let id = try #require(TmuxSessionID("$3"))
    #expect(OtherClientsCommands.ownClientAndTime == "display-message -p '%s #{client_name}'")
    #expect(
      OtherClientsCommands.clients(of: id)
        == "list-clients -f '#{==:#{session_id},$3}' "
        + "-F '#{client_pid}:#{client_created}:#{client_name}'")
    #expect(
      OtherClientsCommands.check(Self.other, of: id)
        == "list-clients -f '#{&&:#{==:#{client_name},client-4321},"
        + "#{&&:#{==:#{client_pid},4321},#{&&:#{==:#{client_created},1799996400},"
        + "#{==:#{session_id},$3}}}}' -F '#{client_pid}'")
    #expect(OtherClientsCommands.detach(Self.other) == "detach-client -t 'client-4321'")
    for command in [
      OtherClientsCommands.clients(of: id), OtherClientsCommands.check(Self.other, of: id),
    ] {
      #expect(!command.contains(" -t "))
    }
    for command in [
      OtherClientsCommands.ownClientAndTime, OtherClientsCommands.clients(of: id),
      OtherClientsCommands.check(Self.other, of: id), OtherClientsCommands.detach(Self.other),
    ] {
      #expect(!command.contains("-a") && !command.contains(" -s ") && !command.contains(";"))
      #expect(!command.contains("attach-session") && !command.contains("if-shell"))
    }
  } // End of func commandsHoldOnlyValidatedValues()

  /// Names and pids that are not what tmux reports for a client are refused, so they can never
  /// reach a command: quotes, spaces, separators, format syntax, options, leading zeros.
  @Test(arguments: [
    "client-1;kill-server", "client-", "client-01", "client-1x", "/dev/", "/dev/tty s1",
    "/dev/ttys1'", "/dev/ttys1,x", "/dev/#{x}", "/dev/ttys1}", "/dev/a$b", "/dev/a\\b", "-t",
    "kill-server", "client-1\n", "/dev/ttys1\u{1B}", "ttys001", "/dev/ttÿ",
    "/dev/" + String(repeating: "a", count: 300),
  ])
  func refusesNamesThatAreNotClientNames(_ name: String) {
    #expect(OtherClient(processID: "12", created: "1", name: name) == nil)
    #expect(!OtherClient.isValidName(name))
  }

  /// Valid names and the pids and creation times around them.
  @Test func acceptsClientNamesAndRefusesBadPIDs() {
    for name in ["client-0", "client-27157", "/dev/ttys003", "/dev/pts/7", "/dev/tty.usb-1_a"] {
      #expect(OtherClient(processID: "12", created: "1", name: name) != nil)
    }
    for pid in ["0", "-1", "01", "1x", "", "99999999999", " 1"] {
      #expect(OtherClient(processID: pid, created: "1", name: "client-1") == nil)
    }
    for created in ["-1", "01", "1x", "", " 1", "99999999999999999999", "1,2", "1}"] {
      #expect(OtherClient(processID: "12", created: created, name: "client-1") == nil)
    }
    #expect(OtherClient(processID: "12", created: "0", name: "client-1")?.created == 0)
  } // End of func acceptsClientNamesAndRefusesBadPIDs()

  /// The answers are read strictly.
  @Test func readsTheAnswers() {
    let time = Self.serverTime
    #expect(
      OtherClientsCommands.readOwn("\(time) /dev/ttys004\n")
        == .init(serverTime: time, name: "/dev/ttys004"))
    #expect(OtherClientsCommands.readOwn("") == nil)
    #expect(OtherClientsCommands.readOwn("/dev/ttys004\n") == nil)
    #expect(OtherClientsCommands.readOwn("\(time) \n") == nil)
    #expect(OtherClientsCommands.readOwn("0\(time) a\n") == nil)
    #expect(OtherClientsCommands.readOwn("\(time) a\n\(time) b\n") == nil)
    #expect(OtherClientsCommands.readOwn("\(time) a\u{1B}b") == nil)
    let own = Self.ownName
    let old = Self.longAgo
    #expect(
      OtherClientsCommands.readListing("1000:\(old):\(own)\n\(Self.otherLine)\n", ownName: own)
        == .others([Self.other]))
    #expect(OtherClientsCommands.readListing("1000:\(old):\(own)", ownName: own) == .others([]))
    #expect(OtherClientsCommands.readListing("\(Self.otherLine)\n", ownName: own) == .ownNotListed)
    #expect(OtherClientsCommands.readListing("", ownName: own) == .ownNotListed)
    #expect(
      OtherClientsCommands.readListing("1000:1:\(own)\n1001:1:\(own)", ownName: own)
        == .unreadable)
    #expect(
      OtherClientsCommands.readListing("1000:1:\(own)\n9:1:client-1;x", ownName: own)
        == .unreadable)
    #expect(
      OtherClientsCommands.readListing("1000:1:\(own)\n9:client-9", ownName: own) == .unreadable)
    #expect(
      OtherClientsCommands.readListing("1000:1:\(own)\n9:x:client-9", ownName: own) == .unreadable)
    #expect(OtherClientsCommands.readListing("1000:1:\(own)\n\n", ownName: own) == .unreadable)
    #expect(OtherClientsCommands.readListing("1000:1:\(own)\nnope", ownName: own) == .unreadable)
    #expect(OtherClientsCommands.readCheck("4321\n", for: Self.other) == .present)
    #expect(OtherClientsCommands.readCheck("", for: Self.other) == .gone)
    #expect(OtherClientsCommands.readCheck("4322\n", for: Self.other) == .unreadable)
    #expect(OtherClientsCommands.readCheck("4321\n4321\n", for: Self.other) == .unreadable)
  } // End of func readsTheAnswers()

  /// A listing that names a client whose name could not be put into a command safely ends
  /// `checkFailed(.clientListing(nil))` and detaches nobody, not even the valid ones.
  @Test func anUnsafeNameDetachesNobody() async throws {
    let harness = Self.harness()
    Self.answer(harness, lines: [Self.ownLine, Self.otherLine, "5:\(Self.longAgo):/dev/tty'x"])
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .checkFailed(.clientListing(nil)))
    #expect(!harness.commands.contains { $0.hasPrefix("detach-client") })
    #expect(!result.mayHaveSent)
  } // End of func anUnsafeNameDetachesNobody()

  // MARK: - Identity changed

  /// The re-check right before anything else shows another session, an answer that may have
  /// lost bytes, or the own client missing from the session's clients: nothing is detached.
  @Test func identityChangeSendsNothing() async throws {
    let moved = Self.harness()
    moved.iTerm2.setAnswers(
      [
        .success(Support.identityOutput(for: moved.key)),
        .success(Support.identityOutput(for: Support.session(id: "$7").key)),
      ], forCommand: ConnectionIdentity.command)
    let first = await moved.coordinator.detachOtherClients(
      of: moved.target, confirmation: moved.confirmation)
    #expect(first.outcome == .identityChanged)
    #expect(first.kept?.connectionID == "user")
    #expect(moved.commands == [ConnectionIdentity.command, ConnectionIdentity.command])

    let lossy = Self.harness()
    lossy.iTerm2.setAnswers(
      [
        .success(Support.identityOutput(for: lossy.key)),
        .success(
          Support.identityLine(socketPath: "/private/tmp/tmux_501/default", utf8: false) + "\n"),
      ], forCommand: ConnectionIdentity.command)
    let second = await lossy.coordinator.detachOtherClients(
      of: lossy.target, confirmation: lossy.confirmation)
    #expect(second.outcome == .identityChanged)
    #expect(lossy.commands == [ConnectionIdentity.command, ConnectionIdentity.command])

    let left = Self.harness()
    Self.answer(left, lines: [Self.otherLine])
    let third = await left.coordinator.detachOtherClients(
      of: left.target, confirmation: left.confirmation)
    #expect(third.outcome == .identityChanged)
    #expect(left.commands == Array(Self.fullRun(left.key).prefix(4)))
    #expect(!third.mayHaveSent)
  } // End of func identityChangeSendsNothing()

  /// Every attachment's connection closed (or changed owner) before its re-check: nothing is
  /// asked of any other connection and nothing is detached.
  @Test func everyAttachmentGoneIsIdentityChanged() async throws {
    let harness = Self.harness { script in
      // The index's listing and its one bound identity check see the connection; later
      // listings do not.
      script.listTmuxConnections = .init(
        .success([]), queued: [.success([Self.userConnection]), .success([Self.userConnection])])
    }
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .identityChanged)
    #expect(result.kept == nil)
    #expect(harness.commands == [ConnectionIdentity.command])
  } // End of func everyAttachmentGoneIsIdentityChanged()

  // MARK: - Nothing to detach

  /// The listing shows only the kept connection's own client, or the other one left before its
  /// check: nothing is detached.
  @Test func nothingToDetach() async throws {
    let alone = Self.harness()
    Self.answer(alone, lines: [Self.ownLine])
    let first = await alone.coordinator.detachOtherClients(
      of: alone.target, confirmation: alone.confirmation)
    #expect(first.outcome == .nothingToDetach)
    #expect(first.listedOthers == 0 && first.detachedClients == 0)
    #expect(alone.commands == Array(Self.fullRun(alone.key).prefix(4)))

    let left = Self.harness()
    Self.answer(left, lines: [Self.ownLine, Self.otherLine], checks: [.success("")])
    let second = await left.coordinator.detachOtherClients(
      of: left.target, confirmation: left.confirmation)
    #expect(second.outcome == .nothingToDetach)
    #expect(second.listedOthers == 1 && second.goneBeforeDetach == 1)
    #expect(left.commands == Array(Self.fullRun(left.key).prefix(5)))
    #expect(!second.mayHaveSent)
  } // End of func nothingToDetach()

  // MARK: - Not attached here

  /// No connection shows the session (another session's only), no tmux server, or iTerm2 not
  /// running: `notAttachedHere`, nothing detached.
  @Test func notAttachedHere() async throws {
    let elsewhere = Self.harness { script in
      script.sendTmuxCommand = .init(
        .success(Support.identityOutput(for: Support.session(id: "$4").key)))
    }
    let first = await elsewhere.coordinator.detachOtherClients(
      of: elsewhere.target, confirmation: elsewhere.confirmation)
    #expect(first.outcome == .notAttachedHere)
    #expect(first.counts == .init(mapped: 1))
    #expect(elsewhere.commands == [ConnectionIdentity.command])

    let idle = Self.harness(status: .noServer)
    let second = await idle.coordinator.detachOtherClients(
      of: idle.target, confirmation: idle.confirmation)
    #expect(second.outcome == .notAttachedHere)
    #expect(await idle.fake.calls.isEmpty)

    let stopped = Self.harness { script in script.isRunning = false }
    let third = await stopped.coordinator.detachOtherClients(
      of: stopped.target, confirmation: stopped.confirmation)
    #expect(third.outcome == .notAttachedHere)
    #expect(third.counts == nil)
    #expect(await stopped.fake.calls == [.listTmuxConnections])
  } // End of func notAttachedHere()

  // MARK: - Check failed

  /// The lookups fail: discovery, the index's listing, the host's SSH destination, the
  /// re-check, the own name, the listing, a check or the detach. Nothing more is sent after
  /// the failure.
  @Test func checkFailures() async throws {
    let broken = Self.harness { script in script.listTmuxConnections = .init(.failure(.timedOut)) }
    let listing = await broken.coordinator.detachOtherClients(
      of: broken.target, confirmation: broken.confirmation)
    #expect(listing.outcome == .checkFailed(.attachmentCheck(.attachmentCheckFailed(.timedOut))))
    #expect(broken.commands.isEmpty)

    let probe = Self.harness(status: .probeError("fixture"))
    let discovery = await probe.coordinator.detachOtherClients(
      of: probe.target, confirmation: probe.confirmation)
    #expect(discovery.outcome == .checkFailed(.attachmentCheck(.discoveryFailed("probeError"))))
    #expect(await probe.fake.calls.isEmpty)

    let remote = Self.harness()
    var target = remote.target
    target.host = HostConfig(
      id: Support.host.id, displayName: "Remote", mode: .ssh, sshDestination: "-oProxyCommand=x")
    let invalid = await remote.coordinator.detachOtherClients(
      of: target, confirmation: remote.confirmation)
    #expect(
      invalid.outcome
        == .checkFailed(.attachmentCheck(.invalidDestination(.sshDestinationStartsWithHyphen))))
    #expect(remote.discovery.calls == 0)

    let stale = Self.harness()
    stale.iTerm2.setAnswers(
      [.success(Support.identityOutput(for: stale.key)), .success("garbage")],
      forCommand: ConnectionIdentity.command)
    let recheck = await stale.coordinator.detachOtherClients(
      of: stale.target, confirmation: stale.confirmation)
    #expect(recheck.outcome == .checkFailed(.identityCheck(.unreadable)))
    #expect(stale.commands == [ConnectionIdentity.command, ConnectionIdentity.command])
  } // End of func checkFailures()

  /// A read through the kept connection fails, or the detach does.
  @Test func requestFailures() async throws {
    let refused = ITerm2Error.tmuxRequestFailed(.invalidRequest)
    let ownFails = Self.harness()
    Self.answer(ownFails, lines: [Self.ownLine, Self.otherLine])
    ownFails.iTerm2.setAnswers(
      [.failure(refused)], forCommand: OtherClientsCommands.ownClientAndTime)
    let first = await ownFails.coordinator.detachOtherClients(
      of: ownFails.target, confirmation: ownFails.confirmation)
    #expect(first.outcome == .checkFailed(.clientListing(refused)))
    #expect(ownFails.commands == Array(Self.fullRun(ownFails.key).prefix(3)))

    let checkFails = Self.harness()
    Self.answer(
      checkFails, lines: [Self.ownLine, Self.otherLine], checks: [.failure(.timedOut)])
    let second = await checkFails.coordinator.detachOtherClients(
      of: checkFails.target, confirmation: checkFails.confirmation)
    #expect(second.outcome == .checkFailed(.clientListing(.timedOut)))
    #expect(!checkFails.commands.contains(OtherClientsCommands.detach(Self.other)))
    #expect(!second.mayHaveSent)

    let detachFails = Self.harness()
    Self.answer(detachFails, lines: [Self.ownLine, Self.otherLine])
    detachFails.iTerm2.setAnswers(
      [.failure(.timedOut)], forCommand: OtherClientsCommands.detach(Self.other))
    let third = await detachFails.coordinator.detachOtherClients(
      of: detachFails.target, confirmation: detachFails.confirmation)
    #expect(third.outcome == .checkFailed(.send(.timedOut)))
    #expect(third.detachedClients == 0 && third.mayHaveSent)
    #expect(detachFails.commands == Self.fullRun(detachFails.key))
  } // End of func requestFailures()

  /// The review's finding (Phase I-11a): a `detach-client` tmux did not confirm (answered
  /// without output: `%error`, such as a client that ended since its check) is never counted.
  /// With two other clients, the first one detached and the second one's detach unconfirmed,
  /// the call ends `checkFailed(.send(.tmuxCommandFailed))` with one client detached; with one,
  /// none. Nothing more is sent after it, and the result says a detach may have been sent.
  @Test func anUnconfirmedDetachIsNotCounted() async throws {
    let harness = Self.harness()
    let second = try #require(
      OtherClient(processID: "77", created: Self.longAgo, name: "/dev/ttys012"))
    let id = harness.key.sessionID
    Self.answer(harness, lines: [Self.ownLine, Self.otherLine, "77:\(Self.longAgo):/dev/ttys012"])
    harness.iTerm2.setAnswers(
      [.success("77\n")], forCommand: OtherClientsCommands.check(second, of: id))
    harness.iTerm2.setAnswers(
      [.failure(.tmuxCommandFailed)], forCommand: OtherClientsCommands.detach(second))
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .checkFailed(.send(.tmuxCommandFailed)))
    #expect(result.listedOthers == 2 && result.detachedClients == 1 && result.mayHaveSent)
    #expect(
      harness.commands
        == Self.fullRun(harness.key) + [
          OtherClientsCommands.check(second, of: id), OtherClientsCommands.detach(second),
        ])

    let alone = Self.harness()
    Self.answer(alone, lines: [Self.ownLine, Self.otherLine])
    alone.iTerm2.setAnswers(
      [.failure(.tmuxCommandFailed)], forCommand: OtherClientsCommands.detach(Self.other))
    let only = await alone.coordinator.detachOtherClients(
      of: alone.target, confirmation: alone.confirmation)
    #expect(only.outcome == .checkFailed(.send(.tmuxCommandFailed)))
    #expect(only.detachedClients == 0 && only.mayHaveSent)
    #expect(DetachOtherClientsProblem.send(.tmuxCommandFailed).detail == "tmuxCommandFailed")
  } // End of func anUnconfirmedDetachIsNotCounted()

  // MARK: - Young clients

  /// The review's finding (Phase I-11a): the age rule covers every client the listing shows,
  /// not only the attachments step 2's snapshot found (here there are none besides the kept
  /// one). A client 3 s old by tmux's clock, such as an attachment in this Mac's iTerm2 opened
  /// after the snapshot, is checked and detached only 8 s after the listing (10 s old, with
  /// the 1 s of tmux's whole seconds); one created after tmux's clock was read gets the whole
  /// 10 s, never more; one 11 s old needs no wait.
  @Test(arguments: [
    (Int64(3), Duration.seconds(8)), (Int64(0), Duration.seconds(10)),
    (Int64(-30), Duration.seconds(10)), (Int64(10), Duration.seconds(1)),
    (Int64(11), Duration.zero),
  ])
  func waitsUntilEveryClientIsOldEnough(age: Int64, wait: Duration) async throws {
    let harness = Self.harness()
    let created = String(Self.serverTime - age)
    let client = try #require(
      OtherClient(processID: "4321", created: created, name: "client-4321"))
    let id = harness.key.sessionID
    Self.answer(harness, lines: [Self.ownLine, "4321:\(created):client-4321"])
    harness.iTerm2.setAnswers(
      [.success("4321\n")], forCommand: OtherClientsCommands.check(client, of: id))
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .detached(count: 1))
    #expect(result.ageWait == wait)
    let sent = harness.iTerm2.sent
    #expect(sent.map(\.command) == Self.fullRun(harness.key, client: client))
    #expect(sent.prefix(4).allSatisfy { $0.at == .zero })
    #expect(sent.suffix(2).allSatisfy { $0.at == wait })
  } // End of func waitsUntilEveryClientIsOldEnough(age:wait:)

  /// A caller cancelled while a young client is left to age sends no check and no detach.
  @Test func cancelledDuringTheAgeWaitSendsNothing() async throws {
    let harness = Self.harness(holdsSleeps: true)
    let created = String(Self.serverTime - 1)
    Self.answer(harness, lines: [Self.ownLine, "4321:\(created):client-4321"])
    let coordinator = harness.coordinator
    let target = harness.target
    let confirmation = harness.confirmation
    let call = Task { await coordinator.detachOtherClients(of: target, confirmation: confirmation) }
    try await waitUntil("the call is waiting") { harness.clock.heldSleeps > 0 }
    call.cancel()
    let result = await call.value
    #expect(result.outcome == .cancelled)
    #expect(result.ageWait == .seconds(10) && result.listedOthers == 1)
    #expect(harness.commands == Array(Self.fullRun(harness.key).prefix(4)))
    #expect(!result.mayHaveSent)
  } // End of func cancelledDuringTheAgeWaitSendsNothing()

  // MARK: - Several attachments here

  /// The session is attached twice in this Mac's iTerm2: the first one listed (the one Show
  /// tab focuses) is kept, and the other one's client is among the other clients. The other
  /// attachment's tab is first left to be 10 s old (counted from the snapshot, as it was not
  /// opened by this coordinator); every read, check and detach goes through the kept
  /// connection only.
  @Test func keepsTheFocusedAttachmentAndCountsTheOthers() async throws {
    let second = Self.connection("user-2", "user-tab-2")
    let harness = Self.harness(connections: [Self.userConnection, second])
    let sibling = try #require(
      OtherClient(processID: "200", created: Self.longAgo, name: "/dev/ttys005"))
    let id = harness.key.sessionID
    Self.answer(harness, lines: [Self.ownLine, "200:\(Self.longAgo):/dev/ttys005", Self.otherLine])
    harness.iTerm2.setAnswers(
      [.success("200\n")], forCommand: OtherClientsCommands.check(sibling, of: id))
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .detached(count: 2))
    #expect(result.kept?.connectionID == "user" && result.kept?.owningSessionID == "user-tab")
    #expect(result.otherAttachmentsHere == 1 && result.listedOthers == 2)
    let afterIndex = Array(harness.iTerm2.sent.dropFirst(2))
    #expect(afterIndex.allSatisfy { $0.connectionID == "user" && $0.at == .seconds(10) })
    #expect(
      afterIndex.map(\.command) == [
        ConnectionIdentity.command, OtherClientsCommands.ownClientAndTime,
        OtherClientsCommands.clients(of: id), OtherClientsCommands.check(sibling, of: id),
        OtherClientsCommands.detach(sibling), OtherClientsCommands.check(Self.other, of: id),
        OtherClientsCommands.detach(Self.other),
      ])
  } // End of func keepsTheFocusedAttachmentAndCountsTheOthers()

  /// The first attachment's connection closed before its re-check: as Show tab would, the next
  /// one is kept.
  @Test func skipsAnAttachmentWhoseConnectionClosed() async throws {
    let second = Self.connection("user-2", "user-tab-2")
    let both = [Self.userConnection, second]
    let harness = Self.harness(connections: both) { script in
      // The index's listing and its two bound identity checks see both connections; from
      // then on only the second.
      script.listTmuxConnections = .init(
        .success([second]), queued: Array(repeating: .success(both), count: 3))
    }
    Self.answer(
      harness, own: "/dev/ttys005", lines: ["200:\(Self.longAgo):/dev/ttys005", Self.otherLine])
    let result = await harness.coordinator.detachOtherClients(
      of: harness.target, confirmation: harness.confirmation)
    #expect(result.outcome == .detached(count: 1))
    #expect(result.kept?.connectionID == "user-2")
    #expect(result.otherAttachmentsHere == 1)
    #expect(harness.iTerm2.sent.dropFirst(2).allSatisfy { $0.connectionID == "user-2" })
  } // End of func skipsAnAttachmentWhoseConnectionClosed()

  /// A caller cancelled while another attachment's tab is left to age sends nothing more.
  @Test func cancelledDuringTheWaitSendsNothing() async throws {
    let second = Self.connection("user-2", "user-tab-2")
    let harness = Self.harness(connections: [Self.userConnection, second], holdsSleeps: true)
    let coordinator = harness.coordinator
    let target = harness.target
    let confirmation = harness.confirmation
    let call = Task { await coordinator.detachOtherClients(of: target, confirmation: confirmation) }
    try await waitUntil("the call is waiting") { harness.clock.heldSleeps > 0 }
    call.cancel()
    let result = await call.value
    #expect(result.outcome == .cancelled)
    #expect(harness.commands == [ConnectionIdentity.command, ConnectionIdentity.command])
    #expect(!result.mayHaveSent)
  } // End of func cancelledDuringTheWaitSendsNothing()

  // MARK: - Results

  /// Every outcome and problem has its machine-readable name and detail.
  @Test func resultsMap() {
    let key = Support.session().key
    let outcomes: [(DetachOtherClientsResult.Outcome, String)] = [
      (.detached(count: 2), "detached"), (.nothingToDetach, "nothingToDetach"),
      (.notAttachedHere, "notAttachedHere"), (.identityChanged, "identityChanged"),
      (.checkFailed(.send(.timedOut)), "checkFailed"), (.notConfirmed, "notConfirmed"),
      (.cancelled, "cancelled"),
    ]
    for (outcome, kind) in outcomes {
      #expect(outcome.kind == kind)
    }
    let problems: [(DetachOtherClientsProblem, String, String?)] = [
      (.attachmentCheck(.sessionGone), "attachmentCheck", "sessionGone"),
      (.identityCheck(.timedOut), "identityCheck", "timedOut"),
      (.clientListing(nil), "clientListing", "unreadable"),
      (.clientListing(.disconnected), "clientListing", "disconnected"),
      (.send(.notSent(.disconnected)), "send", "notSent"),
    ]
    for (problem, kind, detail) in problems {
      #expect(problem.kind == kind && problem.detail == detail)
    }
    #expect(
      DetachOtherClientsResult(key: key, outcome: .detached(count: 1), detachedClients: 1)
        .mayHaveSent)
    #expect(
      !DetachOtherClientsResult(key: key, outcome: .checkFailed(.send(.notSent(.timedOut))))
        .mayHaveSent)
    #expect(
      DetachOtherClientsResult(key: key, outcome: .checkFailed(.send(.timedOut))).mayHaveSent)
    #expect(!DetachOtherClientsResult(key: key, outcome: .nothingToDetach).mayHaveSent)
  } // End of func resultsMap()

  /// The recorder counts every call it forwards, of every kind (the real run proves a
  /// confirmation for another key asks iTerm2 nothing this way).
  @Test func recorderCountsEveryForwardedCall() async throws {
    let recorder = RecordingITerm2Integration(base: FakeITerm2Integration())
    #expect(await recorder.forwardedCallCount == 0)
    _ = await recorder.isRunning()
    _ = await recorder.status()
    _ = try await recorder.listSessions()
    _ = try await recorder.listTmuxConnections()
    _ = try await recorder.sendTmuxCommand("x", connectionID: "c")
    _ = try? await recorder.sendTmuxCommand("x", connectionID: "c", ownedBy: "o")
    try await recorder.setBuried(false, sessionID: "s")
    _ = try await recorder.close(.init(target: .sessions(["s"]), force: true))
    await recorder.disconnect()
    #expect(await recorder.forwardedCallCount == 9)
  } // End of func recorderCountsEveryForwardedCall()
}
