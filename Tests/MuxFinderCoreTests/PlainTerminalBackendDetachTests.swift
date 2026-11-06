import Foundation
import Testing

@testable import MuxFinderCore

/// The plain backend's detach, move here, "Detach other clients…", create and attach, and
/// current session (PLAN.md D37, D38, Phase I-12c1) over the same fakes as its attach tests:
/// the exact bound argv locally and over ssh, nothing run without an attachment, the kept
/// client the attachment's, the age guard by tmux's clock. No terminal app, iTerm2, tmux or
/// ssh is ever run.
@Suite("Plain terminal backend: detach and others")
@MainActor
struct PlainTerminalBackendDetachTests {
  /// Shorthand.
  typealias Support = PlainBackendSupport

  /// The runner's answer for an attachment of the fixture client that tmux then detaches: the
  /// local listing (or remote reading) confirms it; a presence check says present; a detach
  /// answers `detach` (by default detached, with the helper's result written for `store`'s
  /// latest launch, as the helper does once its client ends); the session clients answer
  /// `sessionClients`.
  static func answer(
    remote: Bool = false,
    store: LaunchStore,
    detach: ProcessResult = Support.output(""),
    sessionClients: ProcessResult = Support.output("")
  ) -> ScriptedProcessRunner.Answer {
    { kind, _ in
      switch kind {
      case .localListing: return Support.listing(Support.listingLine())
      case .remoteReading: return Support.remoteAnswer([(true, Support.remoteClient)])
      case .presence: return Support.output(PlainClientPresence.presentMarker + "\n")
      case .detach:
        if detach.standardOutput.isEmpty, detach.termination == .exited(0),
          let report = (try? LaunchTestSupport.names(in: store.directory))?
            .first(where: { $0.hasSuffix(".report.json") }),
          let token = LaunchToken(String(report.prefix(36)))
        {
          try? store.writeResult(Support.result(for: token))
        }
        return detach
      case .sessionClients: return sessionClients
      case .other: return Support.output("", status: 1)
      }
    }
  } // End of static func answer(remote:store:detach:sessionClients:)

  /// A harness on `host` whose runner answers `answer(…)` for its own store.
  static func harness(
    on host: HostConfig = AttachTestSupport.host,
    detach: ProcessResult = Support.output(""),
    sessionClients: ProcessResult = Support.output("")
  ) throws -> PlainBackendHarness {
    let harness = try PlainBackendHarness(sessions: [Support.session(on: host)])
    harness.runner.setAnswer(
      answer(
        remote: host.mode == .ssh, store: harness.store, detach: detach,
        sessionClients: sessionClients))
    if host.mode == .ssh { harness.report = { Support.report(for: $0, terminalPath: nil) } }
    return harness
  } // End of static func harness(on:detach:sessionClients:)

  // MARK: - Detach

  /// This Mac: the bound detach of the recorded client, exactly `/bin/sh -c <script> muxfinder
  /// <override> if-shell -F -t $3 <condition> "detach-client -t '/dev/ttys004'" "display-message
  /// -p muxfinder-not-this-client"` over all six session fields; `detached`, the helper's
  /// result taken, the attachment dropped; a second detach finds nothing and runs nothing.
  @Test func detachesTheRecordedClientLocally() async throws {
    let harness = try Self.harness()
    defer { harness.cleanUp() }
    let target = Support.target()
    let attached = await harness.backend.attach(target)
    let client = try #require(attached.plainClient)
    let result = await harness.backend.detach(session: target.key, on: target.host)
    #expect(result.outcome == .detached && result.detaches.isEmpty)
    #expect(result.plainDetach?.client == client)
    #expect(result.plainDetach?.outcome == .detached && result.plainDetach?.failure == nil)
    #expect(result.plainDetach?.helperResult == Support.result(for: attached.launchID))
    let detach = try #require(harness.runner.requests(.detach).first)
    let bound = try #require(
      PlainClientDetach.arguments(of: Support.localClient, in: Support.identity))
    #expect(
      bound
        == [
          "if-shell", "-F", "-t", "$3",
          PlainClientDetach.condition(of: Support.localClient, in: Support.identity)!,
          "detach-client -t '/dev/ttys004'", "display-message -p muxfinder-not-this-client",
        ])
    #expect(bound[4].contains("#{==:#{socket_path},/private/tmp/tmux-501/default}"))
    #expect(bound[4].contains("#{==:#{session_name},fixture-session}"))
    #expect(detach.executableURL.path(percentEncoded: false) == "/bin/sh")
    #expect(
      detach.arguments == ["-c", PlainTmuxCommands.script.source, "muxfinder", ""] + bound)
    #expect(await harness.backend.attachment(of: target.key) == nil)
    #expect(try harness.files().isEmpty, "the result and the report were taken")

    let before = harness.runner.requests.count
    let again = await harness.backend.detach(session: target.key, on: target.host)
    #expect(again.outcome == .nothingAttached && again.plainDetach == nil)
    #expect(harness.runner.requests.count == before)
    #expect(harness.windows.opens.count == 1, "never a window closed or opened")
  } // End of func detachesTheRecordedClientLocally()

  /// An SSH host: the same bound detach as one BatchMode ssh call, `/usr/bin/ssh <D6 options>
  /// -n -T -- <destination> <D3 string of the static script>`.
  @Test func detachesTheRecordedClientOverSSH() async throws {
    let host = Support.remoteHost
    let harness = try Self.harness(on: host)
    defer { harness.cleanUp() }
    let target = Support.target(on: host)
    let attached = await harness.backend.attach(target)
    #expect(attached.plainClient?.token == attached.launchID)
    let result = await harness.backend.detach(session: target.key, on: host)
    #expect(result.outcome == .detached)
    let detach = try #require(harness.runner.requests(.detach).first)
    let bound = try #require(
      PlainClientDetach.arguments(of: Support.remoteClient, in: Support.identity))
    #expect(detach.executableURL.path(percentEncoded: false) == "/usr/bin/ssh")
    #expect(
      detach.arguments
        == DiscoveryProbe.sshOptions
        + [
          "-n", "-T", "--", "remote-fixture",
          ShellQuoting.remoteCommand(script: PlainTmuxCommands.script, args: [""] + bound),
        ])
  } // End of func detachesTheRecordedClientOverSSH()

  /// No attachment of the session: `nothingAttached`, nothing run (no discovery, no tmux).
  @Test func detachWithoutAnAttachmentRunsNothing() async throws {
    let harness = try Self.harness()
    defer { harness.cleanUp() }
    let target = Support.target()
    let result = await harness.backend.detach(session: target.key, on: target.host)
    #expect(result == SessionDetachResult(key: target.key, outcome: .nothingAttached))
    #expect(harness.runner.requests.isEmpty && harness.discovery.calls == 0)
  }

  /// The bound check's refusal (`notThisClient`) is `notSent` and drops the attachment; a run
  /// that failed is `notClosed` and keeps it.
  @Test func detachRefusedOrFailed() async throws {
    let refused = try Self.harness(
      detach: Support.output(PlainClientDetach.notThisClientMarker + "\n"))
    defer { refused.cleanUp() }
    let target = Support.target()
    _ = await refused.backend.attach(target)
    let notSent = await refused.backend.detach(session: target.key, on: target.host)
    #expect(notSent.outcome == .notSent && notSent.plainDetach?.outcome == .notThisClient)
    #expect(await refused.backend.attachment(of: target.key) == nil)

    let failing = try Self.harness(detach: Support.output("", status: 1, stderr: "lost server"))
    defer { failing.cleanUp() }
    _ = await failing.backend.attach(target)
    let notClosed = await failing.backend.detach(session: target.key, on: target.host)
    #expect(notClosed.outcome == .notClosed)
    #expect(notClosed.plainDetach?.failure == .exited(.exited(1)))
    #expect(await failing.backend.attachment(of: target.key) != nil)
  } // End of func detachRefusedOrFailed()

  // MARK: - Move here

  /// A move here: a confirmation for another session runs nothing (`moveHereNotConfirmed`); the
  /// confirmed one writes a plain request whose bound attach is `attach-session -d` locally and
  /// `remoteMoveHereScript` over ssh; with the backend's own attachment still live it runs
  /// nothing (`alreadyOpenInTerminal`).
  @Test func movesHereWithTheBoundDetachingAttach() async throws {
    let harness = try Self.harness()
    defer { harness.cleanUp() }
    let target = Support.target()
    let other = SessionKey(
      hostID: target.key.hostID, server: target.key.server, sessionID: TmuxSessionID("$9")!)
    let stale = await harness.backend.moveHere(
      target, confirmation: .detachOtherClients(of: other))
    #expect(stale.failure == .moveHereNotConfirmed)
    #expect(harness.discovery.calls == 0 && harness.windows.opens.isEmpty)
    #expect(try harness.files().isEmpty && harness.log.states.isEmpty)

    let moved = await harness.backend.moveHere(
      target, confirmation: .detachOtherClients(of: target.key))
    #expect(moved.isConfirmed)
    let request = try #require(harness.taken.first)
    #expect(
      request.detachOtherClients == true && request.terminal == .plain(definitionID: "terminal"))
    let local = try #require(PlainLaunch.localAttachArguments(for: request))
    #expect(local[6] == "attach-session -d -t '$3'")
    var remote = request
    remote.host = .ssh(destination: "remote-fixture")
    let ssh = try #require(PlainLaunch.sshArguments(for: remote))
    #expect(
      ssh.last
        == PlainLaunch.remoteCommand(
          checkArguments: LaunchGuard.checkArguments(for: remote), token: request.id,
          detachingOthers: true))

    let refused = await harness.backend.moveHere(
      target, confirmation: .detachOtherClients(of: target.key))
    #expect(refused.failure == .alreadyOpenInTerminal(window: try #require(moved.plainWindow)))
    #expect(harness.windows.opens.count == 1 && harness.taken.count == 1)
  } // End of func movesHereWithTheBoundDetachingAttach()

  // MARK: - Detach other clients

  /// The kept client is the attachment's; every other client of the session (only of that
  /// session) old enough by tmux's clock gets the bound detach keeping the kept client, in
  /// listing order.
  @Test func detachesOtherClientsKeepingTheAttachments() async throws {
    let other = OtherClient(processID: "6000", created: "1792600000", name: "/dev/ttys009")!
    let listing = Support.output(
      "1792600200\n" + Support.listingLine() + "\n"
        + Support.listingLine(pid: 6000, created: 1_792_600_000, tty: "/dev/ttys009") + "\n"
        + Support.listingLine(sessionID: "$4", pid: 7000, tty: "/dev/ttys010") + "\n")
    let harness = try Self.harness(sessionClients: listing)
    defer { harness.cleanUp() }
    let target = Support.target()
    let attached = await harness.backend.attach(target)
    let result = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(result.outcome == .detached(count: 1))
    #expect(result.keptPlainClient == attached.plainClient && result.kept == nil)
    #expect(result.listedOthers == 1 && result.detachedClients == 1 && result.ageWait == .zero)
    let listingRequest = try #require(harness.runner.requests(.sessionClients).first)
    #expect(
      listingRequest.arguments
        == ["-c", PlainTmuxCommands.script.source, "muxfinder", ""]
        + PlainSessionClients.arguments)
    let detaches = harness.runner.requests(.detach)
    #expect(detaches.count == 1)
    let bound = try #require(
      PlainClientDetach.arguments(of: other, keeping: Support.localClient, in: Support.identity))
    #expect(
      detaches.first?.arguments == ["-c", PlainTmuxCommands.script.source, "muxfinder", ""] + bound)
    #expect(bound[4].contains("#{==:#{client_pid},5150}"), "the kept client's checks")
    #expect(await harness.backend.attachment(of: target.key) != nil, "the kept one stays")
  } // End of func detachesOtherClientsKeepingTheAttachments()

  // MARK: - Review fix: every detach bound to the kept client

  /// The session's listing with the kept client and two other clients, both old enough.
  static let twoOthers = Support.output(
    "1792600200\n" + Support.listingLine() + "\n"
      + Support.listingLine(pid: 6000, created: 1_792_600_000, tty: "/dev/ttys009") + "\n"
      + Support.listingLine(pid: 6001, created: 1_792_600_000, tty: "/dev/ttys010") + "\n")
  /// The first other client of `twoOthers`.
  static let firstOther = OtherClient(
    processID: "6000", created: "1792600000", name: "/dev/ttys009")!
  /// The second other client of `twoOthers`.
  static let secondOther = OtherClient(
    processID: "6001", created: "1792600000", name: "/dev/ttys010")!

  /// A runner answer for "Detach other clients…" over `twoOthers`: the listing confirms the
  /// attach, the n-th bound detach answers `detach(n)`, every presence check `presence`. No
  /// helper result is ever written.
  static func keptAnswer(
    detach: @escaping @Sendable (Int) -> ProcessResult,
    presence: ProcessResult
  ) -> ScriptedProcessRunner.Answer {
    let listing = twoOthers
    return { kind, number in
      switch kind {
      case .localListing: return Support.listing(Support.listingLine())
      case .presence: return presence
      case .detach: return detach(number)
      case .sessionClients: return listing
      default: return Support.output("", status: 1)
      }
    }
  } // End of static func keptAnswer(detach:presence:)

  /// The detaches sent for `client`.
  static func detaches(of client: OtherClient, in harness: PlainBackendHarness) -> Int {
    harness.runner.requests(.detach).filter {
      $0.arguments.contains("detach-client -t '\(client.name)'")
    }.count
  }

  /// A refused detach is told apart by the kept client's presence check: present, the other
  /// client counts as gone and the next one is detached; not present (the kept client ended
  /// or moved to another session), the call ends `identityChanged` with no further detach and
  /// the attachment dropped; a check that cannot run ends it `plainClientListing`, no further
  /// detach.
  @Test func refusedDetachStopsUnlessTheKeptClientHoldsTheSession() async throws {
    let refused = Support.output(PlainClientDetach.notThisClientMarker + "\n")
    let cases: [(ProcessResult, DetachOtherClientsResult.Outcome)] = [
      (Support.output(PlainClientPresence.presentMarker + "\n"), .detached(count: 1)),
      (refused, .identityChanged),
      (Support.output("", status: 3), .checkFailed(.plainClientListing(.exited(.exited(3))))),
    ]
    for (presence, expected) in cases {
      let harness = try PlainBackendHarness()
      defer { harness.cleanUp() }
      harness.runner.setAnswer(
        Self.keptAnswer(
          detach: { $0 == 1 ? refused : Support.output("") }, presence: presence))
      let target = Support.target()
      _ = await harness.backend.attach(target)
      let result = await harness.backend.detachOtherClients(
        of: target, confirmation: .detachOtherClients(of: target.key))
      #expect(result.outcome == expected)
      #expect(harness.runner.requests(.presence).count == 1)
      #expect(Self.detaches(of: Self.firstOther, in: harness) == 1)
      let keptHolds = expected == .detached(count: 1)
      #expect(Self.detaches(of: Self.secondOther, in: harness) == (keptHolds ? 1 : 0))
      #expect(result.goneBeforeDetach == (keptHolds ? 1 : 0))
      let dropped = await harness.backend.attachment(of: target.key) == nil
      #expect(dropped == (expected == .identityChanged))
    } // End of loop over the presence answers
  } // End of func refusedDetachStopsUnlessTheKeptClientHoldsTheSession()

  /// The kept attachment's helper ends while a detach runs (its result written then): the
  /// next client is not detached, the call ends `identityChanged` with the first detach
  /// counted, and the attachment is dropped.
  @Test func keptHelperEndingStopsTheDetaches() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    harness.runner.setAnswer(
      Self.keptAnswer(
        detach: { _ in Support.output("") },
        presence: Support.output(PlainClientPresence.presentMarker + "\n")))
    let target = Support.target()
    let attached = await harness.backend.attach(target)
    let store = harness.store
    harness.runner.setHook { kind, number in
      guard kind == .detach, number == 1 else { return }
      try? store.writeResult(Support.result(for: attached.launchID))
    }
    let result = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(result.outcome == .identityChanged)
    #expect(result.detachedClients == 1 && result.mayHaveSent)
    #expect(Self.detaches(of: Self.firstOther, in: harness) == 1)
    #expect(Self.detaches(of: Self.secondOther, in: harness) == 0)
    #expect(await harness.backend.attachment(of: target.key) == nil)
  } // End of func keptHelperEndingStopsTheDetaches()

  /// The backend's record of the session dropped (its own detach) or replaced (its detach,
  /// then a new attach) while a detach of "Detach other clients…" runs: the next client is not
  /// detached, the call ends `identityChanged` with the first detach counted.
  @Test(arguments: [false, true])
  func droppedOrReplacedRecordStopsTheDetaches(_ replaced: Bool) async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    let store = harness.store
    harness.runner.setAnswer(
      Self.keptAnswer(
        detach: { number in
          // The second detach is the backend's own of the kept client: its helper then ends.
          if number == 2, let token = Support.reportToken(in: store) {
            try? store.writeResult(Support.result(for: token))
          }
          return Support.output("")
        },
        presence: Support.output(PlainClientPresence.presentMarker + "\n")))
    let backend = harness.backend
    let target = Support.target()
    let first = await backend.attach(target)
    harness.runner.setHook { kind, number in
      guard kind == .detach, number == 1 else { return }
      _ = await backend.detach(session: target.key, on: target.host)
      if replaced { _ = await backend.attach(target) }
    }
    let result = await backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(result.outcome == .identityChanged, "replaced: \(replaced)")
    #expect(result.detachedClients == 1 && result.keptPlainClient == first.plainClient)
    #expect(Self.detaches(of: Self.firstOther, in: harness) == 1)
    #expect(Self.detaches(of: Self.secondOther, in: harness) == 0)
    #expect(Self.detaches(of: Support.localClient, in: harness) == 1, "the backend's own")
    let now = await backend.attachment(of: target.key)
    #expect(replaced ? now != nil && now?.launchID != first.launchID : now == nil)
  } // End of func droppedOrReplacedRecordStopsTheDetaches(_:)

  /// A client younger than 10 s by tmux's clock is waited for first (D37's age guard).
  @Test func waitsForYoungClients() async throws {
    let listing = Support.output(
      "1792600200\n" + Support.listingLine() + "\n"
        + Support.listingLine(pid: 6000, created: 1_792_600_195, tty: "/dev/ttys009") + "\n")
    let clock = ManualAttachClock()
    let harness = try PlainBackendHarness(clock: clock)
    defer { harness.cleanUp() }
    harness.runner.setAnswer(Self.answer(store: harness.store, sessionClients: listing))
    let target = Support.target()
    _ = await harness.backend.attach(target)
    let before = clock.elapsed
    let result = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(result.outcome == .detached(count: 1))
    #expect(result.ageWait == .seconds(6))
    #expect(clock.elapsed - before >= .seconds(6))
  } // End of func waitsForYoungClients()

  /// Nothing runs without the session's confirmation or without an attachment; the kept client
  /// missing from the listing is `identityChanged` (nothing detached); a client the bound check
  /// refuses counts as gone (`nothingToDetach`); a failed detach stops the call and may have run.
  @Test func detachOthersRefusalsAndFailures() async throws {
    let target = Support.target()
    let other = Support.listingLine(pid: 6000, created: 1_792_600_000, tty: "/dev/ttys009")
    let harness = try Self.harness(
      sessionClients: Support.output("1792600200\n" + other + "\n"))
    defer { harness.cleanUp() }
    let otherKey = SessionKey(
      hostID: target.key.hostID, server: target.key.server, sessionID: TmuxSessionID("$9")!)
    let unconfirmed = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: otherKey))
    #expect(unconfirmed.outcome == .notConfirmed)
    let unattached = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(unattached.outcome == .notAttachedHere && unattached.keptPlainClient == nil)
    #expect(harness.runner.requests.isEmpty && harness.discovery.calls == 0)

    _ = await harness.backend.attach(target)
    let changed = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(changed.outcome == .identityChanged)
    #expect(harness.runner.requests(.detach).isEmpty)

    let both = Support.output("1792600200\n" + Support.listingLine() + "\n" + other + "\n")
    harness.runner.setAnswer(
      Self.answer(
        store: harness.store, detach: Support.output(PlainClientDetach.notThisClientMarker + "\n"),
        sessionClients: both))
    let gone = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(gone.outcome == .nothingToDetach && gone.goneBeforeDetach == 1)

    harness.runner.setAnswer(
      Self.answer(
        store: harness.store, detach: Support.output("", status: 255), sessionClients: both))
    let failed = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(failed.outcome == .checkFailed(.plainDetach(.exited(.exited(255)))))
    #expect(failed.mayHaveSent)

    harness.runner.setAnswer(
      Self.answer(store: harness.store, sessionClients: Support.output("not a time\n")))
    let unreadable = await harness.backend.detachOtherClients(
      of: target, confirmation: .detachOtherClients(of: target.key))
    #expect(unreadable.outcome == .checkFailed(.plainClientListing(.unreadable)))
    #expect(!unreadable.mayHaveSent)
  } // End of func detachOthersRefusalsAndFailures()

  // MARK: - Create, current session, state

  /// Create and attach: D18's creation, then the attach of the created session without the
  /// record check; a failed creation opens nothing.
  @Test func createsThenAttaches() async throws {
    let created = CreatedSession(
      server: AttachTestSupport.server, sessionID: TmuxSessionID("$3")!,
      createdAt: Support.session().createdAt, name: "fixture-session")
    let harness = try PlainBackendHarness(creator: FakeSessionCreator(.success(created)))
    defer { harness.cleanUp() }
    let request = NewSessionRequest(host: AttachTestSupport.host, name: "fixture-session")
    let result = await harness.backend.createAndAttach(request)
    #expect(result.created == created && result.isAttached)
    #expect(result.attach?.plainClient?.client == Support.localClient)
    #expect(harness.creator.requests == [request])

    let failing = try PlainBackendHarness(creator: FakeSessionCreator(.failure(.directoryMissing)))
    defer { failing.cleanUp() }
    let refused = await failing.backend.createAndAttach(request)
    #expect(refused.creationFailure == .directoryMissing && refused.attach == nil)
    #expect(failing.windows.opens.isEmpty && failing.discovery.calls == 0)
  } // End of func createsThenAttaches()

  /// The current session by name, through the coordinator's shared step; the state per key.
  @Test func currentSessionAndState() async throws {
    let harness = try PlainBackendHarness()
    defer { harness.cleanUp() }
    let host = AttachTestSupport.host
    let found = await harness.backend.currentSession(named: "fixture-session", on: host)
    #expect(try found.get() == Support.target())
    #expect(await harness.backend.currentSession(named: "nope", on: host) == .failure(.sessionGone))
    #expect(await harness.backend.state(of: Support.target().key) == nil)
    let result = await harness.backend.attach(Support.target())
    #expect(await harness.backend.state(of: Support.target().key) == result.state)
  } // End of func currentSessionAndState()
} // End of struct PlainTerminalBackendDetachTests
