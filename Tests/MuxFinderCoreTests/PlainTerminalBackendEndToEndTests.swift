import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The plain backend end to end on This Mac with no terminal app and no iTerm2 (PLAN.md D38,
/// Phase I-12c1): the fake window layer's open runs the built `muxfinder-launch attach-plain`
/// on a pseudo-terminal of the test's (`LaunchHelperPlainBinaryTests`' harness: drained, never
/// kept), against a `muxfinder-test-*` session on a private tmux server (`-f /dev/null`, a
/// private `HOME` and `TMUX_TMPDIR` from `mkdtemp`), with a private launch directory and
/// `MUXFINDER_LAUNCH_NO_WAIT=1`. Discovery, the readings and the bound commands are the real
/// ones (`DiscoveryProbe`, `PlainTmuxCommands`) on that server only. Only the test's session is
/// ever killed (never `kill-server`); the server ends with it.
@Suite("Plain terminal backend: end to end (real)")
@MainActor
struct PlainTerminalBackendEndToEndTests {
  /// Shorthand.
  typealias Binary = LaunchHelperPlainBinaryTests

  /// The processes the test started, so every way out ends and reaps them.
  final class Started {
    /// The helper the fake open started.
    var helper: pid_t?
    /// The plain clients the test attached itself.
    var clients: [pid_t] = []
  }

  /// One real attach through the backend: confirmed from the helper's early report and tmux's
  /// listing (the report's terminal, its attach child with its start time); attaching again
  /// focuses the window (the real bound presence check) and opens nothing; "Detach other
  /// clients…" detaches a second plain client of the test's and keeps the backend's; the
  /// backend's detach (the real bound detach) ends only its own client, a third client of the
  /// test's staying attached; the helper writes a successful result and exits 0.
  @Test(
    .enabled(if: Binary.helperURL != nil && DiscoveryEndToEndTests.tmuxPath != nil),
    .timeLimit(.minutes(1)))
  func attachesConfirmsAndDetachesOnThisMac() async throws {
    let helper = try #require(Binary.helperURL)
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let socketFolder = try Binary.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: socketFolder) }
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = [
      "PATH": ProcessEnvironment.systemSearchPath,
      "HOME": socketFolder.path(percentEncoded: false),
      "TMUX_TMPDIR": socketFolder.path(percentEncoded: false),
    ]
    let server = PlainBoundCommandsTests.Server(tmux: tmux, environment: environment)
    var terminalEnvironment = environment
    terminalEnvironment["TERM"] = "xterm-256color"
    terminalEnvironment["LANG"] = "en_US.UTF-8"
    var helperEnvironment = terminalEnvironment
    helperEnvironment[LaunchHelper.directoryVariable] = store.directory.path(percentEncoded: false)
    helperEnvironment[StandardLaunchTerminal.noWaitVariable] = "1"
    let name = "muxfinder-test-plain-backend-\(UUID().uuidString.prefix(8).lowercased())"
    let terminal = try Binary.DrainedTerminal()
    let otherTerminal = try Binary.DrainedTerminal()
    // A terminal whose session leader exited is revoked, so the third client gets its own.
    let thirdTerminal = try Binary.DrainedTerminal()
    let started = Started()
    do {
      let created = try await Binary.createSession(name, on: server)
      #expect(created.server.socketPath.hasPrefix(socketFolder.path(percentEncoded: false)))
      let windows = FakePlainTerminalWindowLayer()
      windows.onOpen = { (token: LaunchToken) throws(PlainTerminalWindowError) in
        do {
          started.helper = try Binary.spawn(
            [
              helper.path(percentEncoded: false), LaunchHelperMode.attachPlain.word, token.rawValue,
            ],
            on: terminal, environment: helperEnvironment)
        } catch {
          throw .spawnFailed(appName: "Terminal", .spawnFailed(errno: EIO))
        }
      }
      let backend = PlainTerminalBackend(
        loaded: try PlainBackendSupport.terminal(), windows: windows,
        helperPath: try LaunchHelperPath(validating: helper.path(percentEncoded: false)),
        store: store, discovery: DiscoveryProbe(baseEnvironment: environment),
        tmux: PlainTmuxCommands(baseEnvironment: environment),
        configuration: AttachCoordinator.Configuration(minimumLaunchTabAge: .zero))
      let host = HostConfig(displayName: "This Mac", mode: .local, tmuxPathOverride: tmux)

      // Attach: confirmed from evidence only.
      let target = try await backend.currentSession(named: name, on: host).get()
      #expect(target.key.sessionID == created.sessionID)
      let attached = await backend.attach(target)
      #expect(attached.isConfirmed, "\(attached.state.kind) \(attached.failure?.kind ?? "")")
      let record = try #require(attached.plainClient)
      let report = try #require(try store.peekReport(attached.launchID))
      #expect(report.helperPID == started.helper && report.terminalPath == terminal.path)
      #expect(record.terminalPath == terminal.path && record.client.name == terminal.path)
      #expect(record.client.processID == report.attachChildPID)
      #expect(record.session == BoundSessionIdentity(created))
      #expect(windows.opens.count == 1 && windows.focuses.count == 1)
      #expect(try await server.clients().count == 1)

      // A second client of the test's; attaching again focuses the backend's window.
      started.clients.append(
        try Self.spawnClient(
          tmux, session: created.sessionID, on: otherTerminal, environment: terminalEnvironment))
      #expect(await Self.clientCount(on: server, becomes: 2))
      let focused = await backend.attach(target)
      #expect(focused.state == .plainFocused(client: record))
      #expect(windows.opens.count == 1 && windows.focuses.count == 2)

      // Detach other clients: the second client goes, the backend's stays.
      let others = await backend.detachOtherClients(
        of: target, confirmation: .detachOtherClients(of: target.key))
      #expect(others.outcome == .detached(count: 1) && others.keptPlainClient == record)
      if let second = started.clients.first {
        #expect(await Binary.waitForExit(second, within: .seconds(10)) == .exited(0))
        started.clients.removeFirst()
      }
      #expect(try await server.client(record.client.processID) == record.client)
      #expect(try await server.clients().count == 1)

      // A third client of the test's stays while the backend detaches its own.
      let third = try Self.spawnClient(
        tmux, session: created.sessionID, on: thirdTerminal, environment: terminalEnvironment)
      started.clients.append(third)
      _ = try await server.client(third)
      let detached = await backend.detach(session: target.key, on: host)
      #expect(detached.outcome == .detached)
      #expect(detached.plainDetach?.outcome == .detached)
      #expect(detached.plainDetach?.helperResult?.succeeded == true)
      if let helperProcess = started.helper {
        #expect(await Binary.waitForExit(helperProcess, within: .seconds(10)) == .exited(0))
        started.helper = nil
      }
      let left = try await server.clients()
      #expect(left.count == 1 && left.first?.contains(":\(third):") == true)
      #expect(await backend.attachment(of: target.key) == nil)
      #expect(try store.peekReport(attached.launchID) == nil)
    } catch {
      await Self.cleanUp(
        started, server: server, terminals: [terminal, otherTerminal, thirdTerminal])
      throw error
    }
    await Self.cleanUp(
      started, server: server, terminals: [terminal, otherTerminal, thirdTerminal])
    #expect(try await server.run(["list-sessions"]).succeeded == false)
  } // End of func attachesConfirmsAndDetachesOnThisMac()

  /// Reopens the terminal (`$0`) read-write as standard input, then runs the command (`$@`):
  /// `Binary.spawn` opens it read-only, and a plain tmux client draws through its standard
  /// input.
  static let readWriteInput = #"exec "$@" 0<>"$0""#

  /// Spawns a plain tmux client of the test's (an unbound `attach-session` of the test's own
  /// session on the private server) on `terminal`, in a new session, with its standard input
  /// read-write.
  static func spawnClient(
    _ tmux: String,
    session: TmuxSessionID,
    on terminal: Binary.DrainedTerminal,
    environment: [String: String]
  ) throws -> pid_t {
    try Binary.spawn(
      [
        "/bin/sh", "-c", readWriteInput, terminal.path, tmux, "-u", "attach-session", "-t",
        session.rawValue,
      ], on: terminal, environment: environment)
  } // End of static func spawnClient(_:session:on:environment:)

  /// Whether the private server lists `count` clients within 10 s.
  static func clientCount(on server: PlainBoundCommandsTests.Server, becomes count: Int) async
    -> Bool
  {
    for _ in 0..<100 {
      if (try? await server.clients().count) == count { return true }
      try? await Task.sleep(for: .milliseconds(100))
    }
    return false
  } // End of static func clientCount(on:becomes:)

  /// On every way out: kills only the test's `muxfinder-test-*` sessions (the server ends with
  /// its last one), waits until no server answers, ends and reaps what the test started if it
  /// still runs, closes the terminals.
  static func cleanUp(
    _ started: Started,
    server: PlainBoundCommandsTests.Server,
    terminals: [Binary.DrainedTerminal]
  ) async {
    await DiscoveryEndToEndTests.cleanUp([], tmux: server.tmux, environment: server.environment)
    try? await server.waitUntilGone()
    for process in [started.helper].compactMap({ $0 }) + started.clients {
      if await Binary.waitForExit(process, within: .seconds(5)) == nil {
        _ = kill(process, SIGKILL)
        _ = await Binary.waitForExit(process, within: .seconds(5))
      }
    } // End of loop over the started processes
    for terminal in terminals { terminal.close() }
  } // End of static func cleanUp(_:server:terminals:)
} // End of struct PlainTerminalBackendEndToEndTests
