import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Discovery's new client fields and process ancestry on the real process table (PLAN.md D38,
/// Phase I-12c2), kept hermetic: a `muxfinder-test-*` session on a private tmux server
/// (`TMUX_TMPDIR` from `mkdtemp("/private/tmp/mfx.XXXXXX")`, `-f /dev/null`), a plain client
/// on a pseudo-terminal the test opens itself (everything printed drained and discarded) and a
/// control client with no terminal. The table is only read; only that session is killed, the
/// server ending with it. No terminal app, iTerm2 or Apple event.
@Suite("Open on this Mac: the real process table (private tmux server)")
struct LocalClientsRealTests {
  /// Shorthand.
  typealias Plain = LaunchHelperPlainBinaryTests

  /// The session's clients as the real probe discovers them on `server`, once `ready` holds.
  static func clients(
    of sessionID: TmuxSessionID,
    on server: PlainBoundCommandsTests.Server,
    until ready: @escaping ([ClientSummary]) -> Bool
  ) async throws -> [ClientSummary]? {
    let probe = DiscoveryProbe(runner: TestSupport.fastRunner, baseEnvironment: server.environment)
    let host = HostConfig(displayName: "This Mac", mode: .local)
    return try await Plain.eventually(within: .seconds(10)) {
      guard case .ok(let sessions) = try await probe.discover(host).status,
        let clients = sessions.first(where: { $0.key.sessionID == sessionID })?.clients,
        ready(clients)
      else { return nil }
      return clients
    }
  } // End of static func clients(of:on:until:)

  /// A plain client on the test's pseudo-terminal: discovery reports that terminal and a
  /// creation time of now; its process has that terminal as its controlling one and did not
  /// start after the client; ancestry finds iTerm2 (when the tests run in it) or no terminal
  /// ancestor, never a refusal; a creation time ten seconds early or another terminal is
  /// refused as pid reuse. A control client with no terminal has no terminal path and is
  /// `incompleteClient`.
  @Test(.enabled(if: DiscoveryEndToEndTests.tmuxPath != nil), .timeLimit(.minutes(1)))
  func tracesARealClient() async throws {
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let folder = try Plain.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let server = PlainBoundCommandsTests.Server(
      tmux: tmux,
      environment: [
        "PATH": ProcessEnvironment.systemSearchPath, "HOME": folder.path(percentEncoded: false),
        "TMUX_TMPDIR": folder.path(percentEncoded: false),
      ])
    let name = "muxfinder-test-local-clients-\(UUID().uuidString.prefix(8).lowercased())"
    let terminal = try Plain.DrainedTerminal()
    let other = try Plain.DrainedTerminal()
    var clientPID: pid_t?
    var control: PlainBoundCommandsTests.ControlClient?
    do {
      let created = try await Plain.createSession(name, on: server)
      var environment = server.environment
      environment["TERM"] = "xterm-256color"
      environment["LANG"] = "en_US.UTF-8"
      let pid = try Plain.spawn(
        [tmux, "-u", "attach-session", "-t", created.sessionID.rawValue], on: terminal,
        environment: environment)
      clientPID = pid
      let listed = try #require(
        try await Self.clients(of: created.sessionID, on: server) { $0.contains { $0.pid == pid } })
      let client = try #require(listed.first { $0.pid == pid })
      #expect(client.terminalPath == terminal.path && !client.isControlMode)
      let createdAt = try #require(client.createdAt)
      #expect(abs(createdAt - Int64(Date().timeIntervalSince1970)) <= 30)

      let table = SystemProcessTable()
      guard case .found(let entry) = table.process(pid) else {
        Issue.record("the client's process was not found")
        throw CancellationError()
      }
      #expect(entry.controllingTerminal != nil)
      #expect(entry.controllingTerminal == table.terminalDevice(atPath: terminal.path))
      #expect(entry.parentPID == getpid())
      #expect(entry.executablePath == tmux || entry.executablePath?.hasSuffix("/tmux") == true)
      #expect(entry.bundleIdentifier == nil)
      #expect(!LocalClientAttributor.started(entry.startTime, after: createdAt))
      #expect(table.terminalDevice(atPath: "/dev/null") != nil, "a character device")
      #expect(table.terminalDevice(atPath: folder.path(percentEncoded: false)) == nil)

      let attributor = LocalClientAttributor(
        table: table, definitions: [], iTerm2JobServerDirectory: nil)
      let attribution = attributor.attribute(client)
      #expect(
        attribution == .app(.iTerm2()) || attribution == .unmapped(.noTerminalAncestor),
        "\(attribution)")
      var early = client
      early.createdAt = createdAt - 10
      #expect(attributor.attribute(early) == .unmapped(.startedAfterClient))
      var elsewhere = client
      elsewhere.terminalPath = other.path
      #expect(attributor.attribute(elsewhere) == .unmapped(.terminalMismatch))

      let controlClient = try PlainBoundCommandsTests.ControlClient(
        tmux: tmux, environment: server.environment, sessionID: created.sessionID)
      control = controlClient
      let controlPID = controlClient.process.processIdentifier
      let both = try #require(
        try await Self.clients(of: created.sessionID, on: server) {
          $0.contains { $0.pid == controlPID }
        })
      let listedControl = try #require(both.first { $0.pid == controlPID })
      #expect(listedControl.isControlMode && listedControl.terminalPath == nil)
      #expect(listedControl.createdAt != nil)
      #expect(attributor.attribute(listedControl) == .unmapped(.incompleteClient))
    } catch {
      await Self.cleanUp(clientPID, control: control, server: server, terminals: [terminal, other])
      throw error
    }
    await Self.cleanUp(clientPID, control: control, server: server, terminals: [terminal, other])
  } // End of func tracesARealClient()

  /// On every way out: ends the control client, kills only the test's `muxfinder-test-*`
  /// session (the server ends with it, and the plain client with the server), reaps the plain
  /// client (SIGKILL if it outlives that), and closes the terminals.
  static func cleanUp(
    _ clientPID: pid_t?,
    control: PlainBoundCommandsTests.ControlClient?,
    server: PlainBoundCommandsTests.Server,
    terminals: [Plain.DrainedTerminal]
  ) async {
    await control?.stop()
    await DiscoveryEndToEndTests.cleanUp([], tmux: server.tmux, environment: server.environment)
    try? await server.waitUntilGone()
    if let clientPID, await Plain.waitForExit(clientPID, within: .seconds(5)) == nil {
      _ = kill(clientPID, SIGKILL)
      _ = await Plain.waitForExit(clientPID, within: .seconds(5))
    }
    for terminal in terminals { terminal.close() }
  } // End of static func cleanUp(_:control:server:terminals:)
} // End of struct LocalClientsRealTests
