import Foundation
import Testing

@testable import MuxFinderCore

/// `AttachmentIndex` against a fake iTerm2 whose answers are scripted per connection, and a
/// clock whose timeouts fire only when the test advances it. Nothing touches iTerm2 or tmux.
@Suite("Attachment index")
struct AttachmentIndexTests {
  /// Shorthand.
  typealias Support = AttachTestSupport

  /// The session `$3` on the fixture server.
  static let key = Support.session().key

  /// A fake iTerm2 listing `connections` (every listing, including the binding rule's), wrapped
  /// so each connection can get its own answers and some can hang.
  static func iTerm2(
    _ connections: [ITerm2API.TmuxConnection],
    clock: GatedAttachClock = GatedAttachClock(),
    hanging: Set<String> = []
  ) -> (FakeITerm2Integration, InstrumentedITerm2) {
    var script = FakeITerm2Integration.Script()
    script.listTmuxConnections = .init(.success(connections))
    script.sendTmuxCommand = .init(.success("unscripted"))
    let fake = FakeITerm2Integration(script: script)
    return (fake, InstrumentedITerm2(fake, clock: clock, hanging: hanging))
  } // End of func iTerm2(_:clock:hanging:)

  /// A connection `id` owned by `owner`.
  static func connection(_ id: String?, _ owner: String?) -> ITerm2API.TmuxConnection {
    ITerm2API.TmuxConnection(connectionID: id, owningSessionID: owner)
  }

  /// The bound commands sent, as (command, connection, owner), in order.
  static func boundCommands(_ calls: [FakeITerm2Integration.Call]) -> [[String]] {
    calls.compactMap { call in
      if case .sendOwnedTmuxCommand(let command, let connectionID, let owner) = call {
        return [command, connectionID, owner]
      }
      return nil
    }
  } // End of func boundCommands(_:)

  /// Whether any command went out without the binding rule.
  static func hasUnboundCommand(_ calls: [FakeITerm2Integration.Call]) -> Bool {
    calls.contains { call in
      if case .sendTmuxCommand = call { return true }
      return false
    }
  }

  // MARK: - Mapped

  /// A connection whose answer names this Mac's node name and a discovered server maps to the
  /// session, bound to the owner from the listing; the identity command is the only command.
  @Test func mapsAConnectionToItsSession() async throws {
    let (fake, iTerm2) = Self.iTerm2([Self.connection("tmux", "owner-1")])
    iTerm2.setAnswers([.success(Support.identityOutput(for: Self.key))], for: "tmux")
    let index = Support.patientIndex(iTerm2)
    let snapshot = try await index.snapshot(of: [Support.indexHost])
    #expect(
      snapshot.attachments == [
        .init(key: Self.key, connectionID: "tmux", owningSessionID: "owner-1")
      ])
    #expect(snapshot.unmapped.isEmpty)
    #expect(snapshot.counts == .init(mapped: 1))
    #expect(snapshot.attachments(of: Self.key).count == 1)
    #expect(snapshot.attachedKeys == [Self.key])
    let calls = await fake.calls
    #expect(calls.first == .listTmuxConnections)
    #expect(Self.boundCommands(calls) == [[ConnectionIdentity.command, "tmux", "owner-1"]])
    #expect(!Self.hasUnboundCommand(calls))
    #expect(calls.count == 2)
  } // End of func mapsAConnectionToItsSession()

  /// The session id comes from the answer: a session discovery has not listed yet still maps,
  /// on a discovered server, and two connections showing one session are both listed.
  @Test func sessionIDComesFromTheAnswer() async throws {
    let (_, iTerm2) = Self.iTerm2([
      Self.connection("tmux", "owner-1"), Self.connection("tmux-1", "owner-2"),
      Self.connection("tmux-2", "owner-3"),
    ])
    let newer = Support.session(id: "$9").key
    iTerm2.setAnswers([.success(Support.identityOutput(for: newer))], for: "tmux")
    iTerm2.setAnswers([.success(Support.identityOutput(for: Self.key))], for: "tmux-1")
    iTerm2.setAnswers([.success(Support.identityOutput(for: Self.key))], for: "tmux-2")
    let snapshot = try await Support.patientIndex(iTerm2).snapshot(of: [Support.indexHost])
    #expect(snapshot.attachments.map(\.key) == [newer, Self.key, Self.key])
    #expect(snapshot.attachments(of: Self.key).map(\.connectionID) == ["tmux-1", "tmux-2"])
    #expect(snapshot.counts.mapped == 3)
  } // End of func sessionIDComesFromTheAnswer()

  // MARK: - Unknown and ambiguous

  /// Answers that match no host's node name and server stay unmapped as `unknown`, each
  /// counted: another host name, another pid, start time or socket, or no host at all.
  @Test func unknownConnectionsAreCountedNotGuessed() async throws {
    let other = ServerIdentity(socketPath: Support.server.socketPath, pid: 4243, startTime: 1)
    let answers: [(String, String)] = [
      ("elsewhere", Support.identityOutput(for: Self.key, host: "Elsewhere-M4.local")),
      ("case", Support.identityOutput(for: Self.key, host: "FIXTURE-NODE.LOCAL")),
      ("pid", Support.identityLine(pid: "4243")),
      ("start", Support.identityLine(startTime: "1792599998")),
      ("socket", Support.identityLine(socketPath: "/private/tmp/tmux-501/other")),
      (
        "restarted",
        Support.identityOutput(
          for: SessionKey(hostID: Support.host.id, server: other, sessionID: Self.key.sessionID))
      ),
    ]
    let (_, iTerm2) = Self.iTerm2(answers.map { Self.connection($0.0, "owner-\($0.0)") })
    for (id, answer) in answers { iTerm2.setAnswers([.success(answer)], for: id) }
    let index = Support.patientIndex(iTerm2)
    let snapshot = try await index.snapshot(of: [Support.indexHost])
    #expect(snapshot.attachments.isEmpty)
    #expect(snapshot.counts == .init(unknown: answers.count))
    #expect(snapshot.unmapped.map(\.connectionID) == answers.map(\.0))
    #expect(snapshot.unmapped.allSatisfy { $0.kind == .unknown && $0.reported != nil })
    let none = try await index.snapshot(of: [])
    #expect(none.counts == .init(unknown: answers.count))
  } // End of func unknownConnectionsAreCountedNotGuessed()

  /// An answer that matches two hosts (the same Mac configured twice) is `ambiguous`, with the
  /// number of candidates; the same host listed twice counts once.
  @Test func ambiguousConnectionsAreCountedNotGuessed() async throws {
    let (_, iTerm2) = Self.iTerm2([Self.connection("tmux", "owner-1")])
    iTerm2.setAnswers([.success(Support.identityOutput(for: Self.key))], for: "tmux")
    let twin = AttachmentIndex.Host(
      hostID: UUID(uuidString: "00000000-0000-4000-8000-0000000000c2")!,
      nodeName: Support.nodeName, servers: [Support.server])
    let index = Support.patientIndex(iTerm2)
    let snapshot = try await index.snapshot(of: [Support.indexHost, twin])
    #expect(snapshot.attachments.isEmpty)
    #expect(snapshot.counts == .init(ambiguous: 1))
    #expect(snapshot.unmapped.first?.candidateCount == 2)
    #expect(snapshot.unmapped.first?.kind == .ambiguous)
    let once = try await index.snapshot(of: [Support.indexHost, Support.indexHost])
    #expect(once.counts == .init(mapped: 1))
  } // End of func ambiguousConnectionsAreCountedNotGuessed()

  /// The pure mapping, host by host.
  @Test func mapping() throws {
    let reported = try #require(ConnectionIdentity.parse(Support.identityOutput(for: Self.key)))
    #expect(AttachmentIndex.map(reported, among: [Support.indexHost]) == .mapped(Self.key))
    let noServer = AttachmentIndex.Host(
      hostID: Support.host.id, nodeName: Support.nodeName, servers: [])
    #expect(AttachmentIndex.map(reported, among: [noServer]) == .unknown)
    var renamed = Support.indexHost
    renamed.nodeName = "Renamed.local"
    #expect(AttachmentIndex.map(reported, among: [renamed]) == .unknown)
  } // End of func mapping()

  // MARK: - Clients not in UTF-8 mode

  /// The review's finding: a connection whose tmux client is not in UTF-8 mode (a user's
  /// `tmux -CC` without `-u` under a non-UTF-8 locale, whose tabs tmux replaces with `_`) still
  /// maps when its answer cannot have lost anything, and is counted as `nonUTF8`, never mapped,
  /// when it may have: `é` replaced by `_` (the path one byte shorter than its length says), a
  /// tab replaced by `_`, and a path whose `_` may be such a replacement, even though discovery
  /// reports exactly that path. The same path through a client in UTF-8 mode maps.
  @Test func nonUTF8ClientsMapOnlyExactAnswers() async throws {
    let underscored = ServerIdentity(
      socketPath: "/private/tmp/tmux_501/default", pid: 4242, startTime: 1_792_599_999)
    let host = AttachmentIndex.Host(
      hostID: Support.host.id, nodeName: Support.nodeName, servers: [Support.server, underscored])
    let answers: [(String, String)] = [
      ("clean", Support.identityLine(utf8: false)),
      (
        "accent",
        Support.identityLine(
          socketPath: "/private/tmp/_/tmux-501/default", utf8: false, socketLength: 32)
      ),
      ("tab", Support.identityLine(socketPath: "/private/tmp/a_b/default", utf8: false)),
      ("underscore", Support.identityLine(socketPath: underscored.socketPath, utf8: false)),
      ("exact", Support.identityLine(socketPath: underscored.socketPath)),
    ]
    let (_, iTerm2) = Self.iTerm2(answers.map { Self.connection($0.0, "owner-\($0.0)") })
    for (id, answer) in answers { iTerm2.setAnswers([.success(answer + "\n")], for: id) }
    let snapshot = try await Support.patientIndex(iTerm2).snapshot(of: [host])
    let underscoredKey = SessionKey(
      hostID: Support.host.id, server: underscored, sessionID: Self.key.sessionID)
    #expect(
      snapshot.attachments == [
        .init(key: Self.key, connectionID: "clean", owningSessionID: "owner-clean"),
        .init(key: underscoredKey, connectionID: "exact", owningSessionID: "owner-exact"),
      ])
    #expect(snapshot.counts == .init(mapped: 2, nonUTF8: 3))
    #expect(snapshot.counts.unmapped == 3)
    #expect(snapshot.unmapped.map(\.connectionID) == ["accent", "tab", "underscore"])
    #expect(
      snapshot.unmapped.allSatisfy {
        $0.kind == .nonUTF8 && $0.reported == nil && $0.staleReason == nil
      })
  } // End of func nonUTF8ClientsMapOnlyExactAnswers()

  // MARK: - Stale

  /// Connections without a usable answer are `stale` and counted, each with its reason, while
  /// the others still map: no id or owner in the listing (no command sent), a refused or
  /// failed request, an unreadable answer.
  @Test func staleConnectionsAreCounted() async throws {
    let (fake, iTerm2) = Self.iTerm2([
      Self.connection(nil, "owner-a"), Self.connection("no-owner", nil),
      Self.connection("", "owner-b"), Self.connection("refused", "owner-c"),
      Self.connection("garbled", "owner-d"), Self.connection("lost", "owner-e"),
      Self.connection("good", "owner-f"),
    ])
    iTerm2.setAnswers([.failure(.tmuxRequestFailed(.invalidConnectionID))], for: "refused")
    iTerm2.setAnswers([.success("garbage\n")], for: "garbled")
    iTerm2.setAnswers([.failure(.disconnected)], for: "lost")
    iTerm2.setAnswers([.success(Support.identityOutput(for: Self.key))], for: "good")
    let snapshot = try await Support.patientIndex(iTerm2).snapshot(of: [Support.indexHost])
    #expect(snapshot.counts == .init(mapped: 1, stale: 6))
    #expect(
      snapshot.unmapped.map(\.staleReason) == [
        .incompleteListing, .incompleteListing, .incompleteListing,
        .requestFailed(.tmuxRequestFailed(.invalidConnectionID)), .unreadable,
        .requestFailed(.disconnected),
      ])
    #expect(snapshot.attachments.map(\.connectionID) == ["good"])
    let bound = Self.boundCommands(await fake.calls)
    #expect(Set(bound.map { $0[1] }) == ["refused", "garbled", "lost", "good"])
    #expect(bound.allSatisfy { $0[0] == ConnectionIdentity.command })
  } // End of func staleConnectionsAreCounted()

  /// A connection that closed or changed owner between the index's listing and its command is
  /// refused by the binding rule (nothing sent) and counted as stale.
  @Test func ownerChangeIsStale() async throws {
    var script = FakeITerm2Integration.Script()
    script.listTmuxConnections = .init(
      .success([Self.connection("tmux", "someone-else")]),
      queued: [.success([Self.connection("tmux", "owner-1")])])
    script.sendTmuxCommand = .init(.success(Support.identityOutput(for: Self.key)))
    let fake = FakeITerm2Integration(script: script)
    let snapshot = try await Support.patientIndex(fake).snapshot(of: [Support.indexHost])
    #expect(snapshot.counts == .init(stale: 1))
    #expect(snapshot.unmapped.first?.staleReason == .requestFailed(.tmuxConnectionNotOwned))
    #expect(
      Self.boundCommands(await fake.calls) == [[ConnectionIdentity.command, "tmux", "owner-1"]])
  } // End of func ownerChangeIsStale()

  /// The review-style hazard: one connection that never answers is bounded by the index's own
  /// timeout (3 s of virtual time), counted as stale, and does not keep the other connection
  /// from mapping. The hung request is cancelled when the time is up.
  @Test func hungConnectionTimesOut() async throws {
    let clock = GatedAttachClock()
    let (_, iTerm2) = Self.iTerm2(
      [Self.connection("hung", "owner-1"), Self.connection("good", "owner-2")], clock: clock,
      hanging: ["hung"])
    iTerm2.setAnswers([.success(Support.identityOutput(for: Self.key))], for: "good")
    let index = AttachmentIndex(iTerm2: iTerm2, clock: clock)
    #expect(index.configuration.commandTimeout == .seconds(3))
    let snapshot = Task { try await index.snapshot(of: [Support.indexHost]) }
    // Both timeouts started, the good connection's was cancelled by its answer, and the hung
    // request is waiting.
    try await waitUntil("the good connection answered and the other one hangs") {
      clock.started == 2 && clock.waiting == 1 && iTerm2.hangingNow == 1
    }
    clock.advance(by: .milliseconds(2999))
    #expect(clock.waiting == 1)
    clock.advance(by: .milliseconds(1))
    let result = try await snapshot.value
    #expect(result.counts == .init(mapped: 1, stale: 1))
    #expect(result.unmapped.first?.connectionID == "hung")
    #expect(result.unmapped.first?.staleReason == .timedOut)
    #expect(result.attachments.map(\.connectionID) == ["good"])
    #expect(iTerm2.hangingNow == 0)
    #expect(clock.elapsed == .seconds(3))
  } // End of func hungConnectionTimesOut()

  // MARK: - Filter, failures, hosts

  /// Connections the filter leaves out get no command and are only counted as excluded.
  @Test func filterExcludesConnections() async throws {
    let (fake, iTerm2) = Self.iTerm2([
      Self.connection("mine", "launch-tab"), Self.connection("theirs", "user-tab"),
    ])
    iTerm2.setAnswers([.success(Support.identityOutput(for: Self.key))], for: "mine")
    let index = Support.patientIndex(iTerm2) { $0.owningSessionID == "launch-tab" }
    let snapshot = try await index.snapshot(of: [Support.indexHost])
    #expect(snapshot.counts == .init(mapped: 1, excluded: 1))
    #expect(snapshot.counts.unmapped == 0)
    #expect(
      Self.boundCommands(await fake.calls) == [[ConnectionIdentity.command, "mine", "launch-tab"]])
  } // End of func filterExcludesConnections()

  /// A failed connection listing throws its error (the caller decides); iTerm2 not running
  /// throws `notRunning`. Nothing is sent.
  @Test(arguments: [ITerm2Error.timedOut, .notSent(.disconnected), .apiDisabled])
  func listingFailureThrows(_ error: ITerm2Error) async throws {
    var script = FakeITerm2Integration.Script()
    script.listTmuxConnections = .init(.failure(error))
    let fake = FakeITerm2Integration(script: script)
    await #expect(throws: error) {
      try await Support.patientIndex(fake).snapshot(of: [Support.indexHost])
    }
    var stopped = FakeITerm2Integration.Script()
    stopped.isRunning = false
    let notRunning = FakeITerm2Integration(script: stopped)
    await #expect(throws: ITerm2Error.notRunning) {
      try await Support.patientIndex(notRunning).snapshot(of: [Support.indexHost])
    }
    #expect(Self.boundCommands(await fake.calls).isEmpty)
  } // End of func listingFailureThrows(_:)

  /// Cancelling the caller while a connection hangs ends the snapshot with `CancellationError`.
  @Test func cancellationThrows() async throws {
    let (_, iTerm2) = Self.iTerm2([Self.connection("hung", "owner-1")], hanging: ["hung"])
    let index = Support.patientIndex(iTerm2)
    let snapshot = Task { try await index.snapshot(of: [Support.indexHost]) }
    try await waitUntil("the request hangs") { iTerm2.hangingNow == 1 }
    snapshot.cancel()
    await #expect(throws: CancellationError.self) { try await snapshot.value }
  }

  /// A host comes from a discovery result: its node name and its sessions' servers; none when
  /// no server runs; nothing for other statuses or without a report.
  @Test func hostFromDiscovery() throws {
    let report = ProbeReport(nodeName: "Fixture-M4.local")
    let session = Support.session()
    let ok = try #require(
      AttachmentIndex.Host(
        DiscoveryResult(
          hostID: Support.host.id, status: .ok([session, Support.session(id: "$4")]),
          report: report, duration: .zero)))
    #expect(ok.hostID == Support.host.id)
    #expect(ok.nodeName == "Fixture-M4.local")
    #expect(ok.servers == [Support.server])
    let idle = try #require(
      AttachmentIndex.Host(
        DiscoveryResult(hostID: Support.host.id, status: .noServer, report: report, duration: .zero)
      ))
    #expect(idle.servers.isEmpty)
    #expect(
      AttachmentIndex.Host(
        DiscoveryResult(
          hostID: Support.host.id, status: .tmuxNotFound, report: report, duration: .zero)) == nil)
    #expect(
      AttachmentIndex.Host(
        DiscoveryResult(
          hostID: Support.host.id, status: .ok([session]), report: nil, duration: .zero))
        == nil)
  } // End of func hostFromDiscovery()
}
