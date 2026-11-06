import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// tmux of a private server for `e2e-plain`'s step tests: `tmux -u -f /dev/null <arguments>`
/// with an environment whose `TMUX_TMPDIR` and `HOME` are a private folder, so no user
/// `tmux.conf` runs and no session of the user's is ever seen.
struct PrivateServerTmux: E2EPlainHostTmux {
  /// The tmux executable.
  let tmux: String
  /// The environment that selects the private server.
  let environment: [String: String]

  /// `at <path> (a private server)`.
  var location: String { "at \(tmux) (a private server)" }

  /// Runs `tmux -u -f /dev/null <arguments>` with a 10 s deadline.
  func run(_ arguments: [String]) async throws -> E2EPlainTmuxOutput {
    E2EPlainTmuxOutput(
      try await DiscoveryEndToEndTests.tmuxResult(
        tmux, ["-u", "-f", "/dev/null"] + arguments, environment: environment,
        timeout: .seconds(10)))
  }

  /// `tmux -V`.
  func version() async -> String? {
    guard
      let result = try? await DiscoveryEndToEndTests.tmuxResult(
        tmux, ["-V"], environment: environment, timeout: .seconds(10)),
      result.succeeded
    else { return nil }
    return E2EPlainTmuxOutput(result).lines.first
  } // End of func version()

  /// `tmux -u -C attach-session -t =<name>` on the private server.
  func controlClientCommand(attachingTo name: String) -> E2EPlainProcessCommand {
    E2EPlainProcessCommand(
      executable: tmux, arguments: ["-u", "-C", "attach-session", "-t", "=" + name],
      environment: environment)
  }
} // End of struct PrivateServerTmux

/// A plain control client of a test (`tmux -u -C attach-session`), its standard input a pipe the
/// test holds open, its standard output only scanned for a line starting with `%exit` (nothing
/// kept), its standard error discarded.
final class TestControlClient: E2EPlainControlClient, @unchecked Sendable {
  /// What the reader saw.
  private struct State {
    /// Whether a line started with `%exit`.
    var sawExit = false
    /// The current line's first bytes.
    var lineStart: [UInt8] = []
    /// Whether standard output reached its end.
    var reachedEnd = false
  }

  /// The client.
  let process = Process()
  /// Its standard input.
  private let input = Pipe()
  /// Its standard output.
  private let output = Pipe()
  /// The reader's state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Starts `command`.
  init(_ command: E2EPlainProcessCommand) throws {
    process.executableURL = URL(fileURLWithPath: command.executable)
    process.arguments = command.arguments
    process.environment = command.environment
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    let state = self.state
    output.fileHandleForReading.readabilityHandler = { handle in
      let data = handle.availableData
      state.withLock { state in
        if data.isEmpty {
          state.reachedEnd = true
          return
        }
        for byte in data {
          if byte == UInt8(ascii: "\n") {
            state.lineStart.removeAll()
          } else if state.lineStart.count < 5 {
            state.lineStart.append(byte)
            if state.lineStart == Array("%exit".utf8) { state.sawExit = true }
          }
        } // End of loop over the chunk
      }
      if data.isEmpty { handle.readabilityHandler = nil }
    } // End of the reader
    try process.run()
  } // End of init(_:)

  /// Its pid.
  var processID: Int32 { process.processIdentifier }
  /// Whether it runs.
  var isRunning: Bool { process.isRunning }
  /// Whether a line started with `%exit`.
  var sawExitNotification: Bool { state.withLock { $0.sawExit } }
  /// Nothing is kept of standard error.
  var errorText: String { "" }

  /// Waits up to `time` for it to exit (and its output to reach its end, at most 1 s more).
  func waitForExit(within time: Duration) async -> ProcessResult.Termination? {
    let deadline = ContinuousClock.now + time
    while process.isRunning {
      guard ContinuousClock.now < deadline else { return nil }
      try? await Task.sleep(for: .milliseconds(20))
    }
    let end = ContinuousClock.now + .seconds(1)
    while !state.withLock({ $0.reachedEnd }), ContinuousClock.now < end {
      try? await Task.sleep(for: .milliseconds(10))
    }
    return process.terminationReason == .exit
      ? .exited(process.terminationStatus) : .signaled(process.terminationStatus)
  } // End of func waitForExit(within:)

  /// Closes its input, waits 2 s, then sends SIGTERM and waits 2 s more.
  @discardableResult
  func stop() async -> ProcessResult.Termination? {
    try? input.fileHandleForWriting.close()
    if let ended = await waitForExit(within: .seconds(2)) { return ended }
    process.terminate()
    return await waitForExit(within: .seconds(2))
  }
} // End of class TestControlClient

/// `e2e-plain`'s steps for real on This Mac with no terminal app and no iTerm2 (PLAN.md D38 *The
/// plain runs (I-12c3b)*): the run's own `E2EPlainRun` drives the real `PlainTerminalBackend`
/// over I-12c1's fake window layer, whose open starts the built `muxfinder-launch attach-plain`
/// on a pseudo-terminal of the test's (drained, never kept) and whose close checks that the
/// window's helper has exited; against a private tmux server (`-f /dev/null`, a private `HOME`
/// and `TMUX_TMPDIR`), with a private launch directory and `MUXFINDER_LAUNCH_NO_WAIT=1`.
/// Discovery, the readings, the bound commands, the run's own control clients and the session's
/// creation and kill are real, on that server only. Not reached here: a terminal app's windows
/// (the fake stands in for open, focus and close), the gate's facts (a fake inspector), and the
/// remote path (the token reading and the control client over ssh).
@Suite("e2e-plain: the steps (real, private tmux server)")
@MainActor
struct E2EPlainStepsTests {
  /// Shorthand.
  typealias Binary = LaunchHelperPlainBinaryTests

  /// The helpers the fake open started, each reaped by a waiter of its own.
  final class Helpers: Sendable {
    /// Started and ended helpers.
    private struct State {
      /// Every helper started, in order.
      var started: [pid_t] = []
      /// How each one ended, once reaped.
      var ended: [pid_t: ProcessResult.Termination] = [:]
    }

    /// The state.
    private let state = OSAllocatedUnfairLock(initialState: State())

    /// Records `pid` and reaps it once it exits (within 2 minutes).
    func start(_ pid: pid_t) {
      state.withLock { $0.started.append(pid) }
      let state = self.state
      Task.detached {
        if let ended = await Binary.waitForExit(pid, within: .seconds(120)) {
          state.withLock { $0.ended[pid] = ended }
        }
      }
    } // End of func start(_:)

    /// Every helper started.
    var started: [pid_t] { state.withLock { $0.started } }

    /// How `pid` ended, once reaped.
    func ended(_ pid: pid_t) -> ProcessResult.Termination? { state.withLock { $0.ended[pid] } }

    /// Waits up to `limit` until every helper started was reaped; returns whether they were.
    func waitForAll(within limit: Duration) async -> Bool {
      let deadline = ContinuousClock.now + limit
      while started.contains(where: { ended($0) == nil }) {
        guard ContinuousClock.now < deadline else { return false }
        try? await Task.sleep(for: .milliseconds(20))
      }
      return true
    } // End of func waitForAll(within:)
  } // End of class Helpers

  /// Whether `pid` (a child of this process) has exited: a zombie, or already reaped.
  nonisolated static func hasExited(_ pid: pid_t) -> Bool {
    var info = siginfo_t()
    while true {
      if waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
        return info.si_pid != 0
      }
      if errno != EINTR { return true }
    }
  } // End of static func hasExited(_:)

  /// One run's private server, launch folder, terminals, fake window layer and records.
  @MainActor
  final class Fixture {
    /// tmux.
    let tmux: String
    /// The built helper.
    let helper: URL
    /// The private server's folder.
    let socketFolder: URL
    /// The launch files.
    let store: LaunchStore
    /// The folder holding them.
    let root: URL
    /// The environment that selects the private server.
    let environment: [String: String]
    /// The pseudo-terminals the opens use, in order.
    let terminals: [Binary.DrainedTerminal]
    /// The window layer.
    let windows = FakePlainTerminalWindowLayer()
    /// The helpers started.
    let helpers = Helpers()
    /// The helper of each open, in order.
    let openedHelpers = OSAllocatedUnfairLock(initialState: [pid_t]())
    /// The run's control clients.
    let clients = OSAllocatedUnfairLock(initialState: [TestControlClient]())
    /// The run's output.
    let lines = OSAllocatedUnfairLock(initialState: [String]())
    /// Windows closed while their helper still ran (must stay empty).
    let violations = OSAllocatedUnfairLock(initialState: [String]())
    /// Runs once, at the first close that goes ahead.
    var onFirstClose: (@MainActor () -> Void)?
    /// Runs after each open started its helper, with the open's number (1 for the first).
    var afterOpen: (@MainActor (Int) -> Void)?
    /// Runs in each open before its helper starts, with the open's number and launch token.
    var beforeHelper: (@MainActor (Int, LaunchToken) -> Void)?
    /// Whether the helpers start without `MUXFINDER_LAUNCH_NO_WAIT`, so a failed one waits for
    /// Return on its pseudo-terminal (where nobody types), as in a real terminal's window.
    var waitingHelpers = false
    /// How long the run waits for a helper's end before it leaves a window (`helperEnd`).
    var helperEnd: Duration = .seconds(5)

    /// A fixture, or throws (the test then cleans up what was made).
    init(tmux: String, helper: URL) throws {
      self.tmux = tmux
      self.helper = helper
      socketFolder = try Binary.makePrivateFolder()
      (store, root) = try LaunchTestSupport.makeStore(now: Date())
      environment = [
        "PATH": ProcessEnvironment.systemSearchPath,
        "HOME": socketFolder.path(percentEncoded: false),
        "TMUX_TMPDIR": socketFolder.path(percentEncoded: false),
      ]
      terminals = try (0..<3).map { _ in try Binary.DrainedTerminal() }
      var helperEnvironment = environment
      helperEnvironment["TERM"] = "xterm-256color"
      helperEnvironment["LANG"] = "en_US.UTF-8"
      helperEnvironment[LaunchHelper.directoryVariable] = store.directory.path(
        percentEncoded: false)
      helperEnvironment[StandardLaunchTerminal.noWaitVariable] = "1"
      let terminals = self.terminals
      let openedHelpers = self.openedHelpers
      let helpers = self.helpers
      windows.onOpen = { [weak self] (token: LaunchToken) throws(PlainTerminalWindowError) in
        let index = openedHelpers.withLock { $0.count }
        guard index < terminals.count else {
          throw .spawnFailed(appName: "Terminal", .spawnFailed(errno: EMFILE))
        }
        self?.beforeHelper?(index + 1, token)
        var environment = helperEnvironment
        if self?.waitingHelpers == true {
          environment[StandardLaunchTerminal.noWaitVariable] = nil
        }
        do {
          let pid = try Binary.spawn(
            [
              helper.path(percentEncoded: false), LaunchHelperMode.attachPlain.word,
              token.rawValue,
            ],
            on: terminals[index], environment: environment)
          openedHelpers.withLock { $0.append(pid) }
          helpers.start(pid)
        } catch {
          throw .spawnFailed(appName: "Terminal", .spawnFailed(errno: EIO))
        }
        self?.afterOpen?(index + 1)
      } // End of the fake open
      windows.onClose = { [weak self] window throws(PlainTerminalWindowError) in
        try self?.checkClose(window)
      }
    } // End of init(tmux:helper:)

    /// The close's check: the window's helper must have exited, else the close is refused as
    /// busy and recorded as a violation. Runs `onFirstClose` once.
    func checkClose(_ window: PlainTerminalWindow) throws(PlainTerminalWindowError) {
      let prefix = "fake-window-"
      guard let id = window.windowID, id.hasPrefix(prefix),
        let number = Int(id.dropFirst(prefix.count))
      else { return }
      let pid = openedHelpers.withLock { $0.indices.contains(number - 1) ? $0[number - 1] : nil }
      guard let pid, E2EPlainStepsTests.hasExited(pid) else {
        violations.withLock { $0.append(id) }
        throw .windowBusy(appName: "Terminal")
      }
      if let hook = onFirstClose {
        onFirstClose = nil
        hook()
      }
    } // End of func checkClose(_:)

    /// The run's parts over this fixture (the age guard's minimum 1 s, the helper's end within
    /// `helperEnd`).
    func parts() throws -> E2EPlainRun.Parts {
      let options = E2EPlainOptions(terminalID: "terminal", target: .local)
      let clients = self.clients
      let lines = self.lines
      return E2EPlainRun.Parts(
        name: options.runName, owedCommand: options.owedCommand,
        loaded: try PlainBackendSupport.terminal(),
        host: HostConfig(displayName: "This Mac", mode: .local, tmuxPathOverride: tmux),
        tmux: PrivateServerTmux(tmux: tmux, environment: environment),
        startControlClient: { command in
          let client = try TestControlClient(command)
          clients.withLock { $0.append(client) }
          return client
        },
        windows: windows,
        inspector: E2EPlainGateTests.inspector(version: "2.14", running: true),
        helperPath: try LaunchHelperPath(validating: helper.path(percentEncoded: false)),
        store: store, discovery: DiscoveryProbe(baseEnvironment: environment),
        tmuxCommands: PlainTmuxCommands(baseEnvironment: environment),
        configuration: AttachCoordinator.Configuration(minimumLaunchTabAge: .seconds(1)),
        budgets: E2EPlainRun.Budgets(helperEnd: helperEnd),
        output: { line in lines.withLock { $0.append(line) } })
    } // End of func parts()

    /// What the run left, looked at before the fixture's own cleanup: launch files, sessions on
    /// the private server, control clients still running, helpers not reaped within 5 s.
    func leftovers() async -> [String] {
      var left: [String] = []
      let files = (try? LaunchTestSupport.names(in: store.directory)) ?? []
      if !files.isEmpty { left.append("\(files.count) launch file(s)") }
      if let sessions = try? await DiscoveryEndToEndTests.tmuxResult(
        tmux, ["-u", "list-sessions", "-F", "#{session_name}"], environment: environment,
        timeout: .seconds(10)), sessions.succeeded
      {
        left.append("a session on the private server")
      }
      if clients.withLock({ $0.contains(where: \.isRunning) }) { left.append("a control client") }
      if await !helpers.waitForAll(within: .seconds(5)) { left.append("a helper") }
      return left
    } // End of func leftovers()

    /// On every way out: ends the control clients, kills only this test's `muxfinder-test-*`
    /// sessions (the server ends with its last one), kills and reaps helpers still running,
    /// closes the terminals and removes the folders.
    func cleanUp() async {
      for client in clients.withLock({ $0 }) where client.isRunning { await client.stop() }
      await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: environment)
      for pid in helpers.started where helpers.ended(pid) == nil {
        _ = kill(pid, SIGKILL)
      }
      _ = await helpers.waitForAll(within: .seconds(5))
      for terminal in terminals { terminal.close() }
      try? FileManager.default.removeItem(at: socketFolder)
      try? FileManager.default.removeItem(at: root)
    } // End of func cleanUp()
  } // End of class Fixture

  /// Whether the test can run: the built helper and tmux.
  nonisolated static let canRun = Binary.helperURL != nil && DiscoveryEndToEndTests.tmuxPath != nil

  /// Runs the whole run over a fixture made by `prepare`, returns its status and output and
  /// what it left, and always cleans up.
  static func run(
    interrupts: AsyncStream<Int32>? = nil,
    prepare: (Fixture) -> Void = { _ in },
    check: (Fixture, Int32, [String], [String]) async throws -> Void
  ) async throws {
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let helper = try #require(Binary.helperURL)
    let fixture = try Fixture(tmux: tmux, helper: helper)
    do {
      prepare(fixture)
      let status = await E2EPlainRun(parts: try fixture.parts()).execute(
        limit: .seconds(90), interrupts: interrupts)
      let left = await fixture.leftovers()
      try await check(fixture, status, fixture.lines.withLock { $0 }, left)
    } catch {
      await fixture.cleanUp()
      throw error
    }
    await fixture.cleanUp()
  } // End of static func run(interrupts:prepare:check:)

  /// Every step passes: two windows opened and both closed only after their helper exited,
  /// three focuses (after each confirmation and the second open), one run policy check before
  /// each request, and nothing left (no launch file, session, control client or helper).
  @Test(.enabled(if: canRun), .timeLimit(.minutes(2)))
  func runsEveryStep() async throws {
    try await Self.run { fixture, status, lines, left in
      let output = lines.joined(separator: "\n")
      #expect(status == 0, "\(output)")
      for number in 1...E2EPlainRun.stepCount {
        #expect(lines.contains { $0.hasPrefix("PASS \(number) ") }, "step \(number)\n\(output)")
      }
      #expect(fixture.windows.opens.count == 2 && fixture.windows.closed.count == 2)
      #expect(fixture.violations.withLock { $0 }.isEmpty, "closed while a helper ran")
      #expect(fixture.windows.focuses.count == 3)
      #expect(fixture.windows.runPolicyChecks == 2)
      #expect(left.isEmpty, "\(left)")
      for pid in fixture.helpers.started {
        #expect(fixture.helpers.ended(pid) == .exited(0))
      }
      #expect(fixture.clients.withLock { $0.count } == 2)
    }
  } // End of func runsEveryStep()

  /// The window layer's recheck of the gate refuses the move here's request (as when the app
  /// quit or its permission changed during the run): step 6 fails naming the gate, nothing
  /// more is opened, cleanup ends the control client and kills the session, and the run exits 1
  /// with nothing left.
  @Test(.enabled(if: canRun), .timeLimit(.minutes(2)))
  func aRecheckThatFailsMidRunStopsTheRun() async throws {
    try await Self.run(
      prepare: { fixture in
        let windows = fixture.windows
        fixture.onFirstClose = {
          windows.runPolicyFailure = .unattendedRunRefused(appName: "Terminal", .notRunning)
        }
      },
      check: { fixture, status, lines, left in
        let output = lines.joined(separator: "\n")
        #expect(status == 1, "\(output)")
        for number in 1...5 {
          #expect(lines.contains { $0.hasPrefix("PASS \(number) ") }, "step \(number)\n\(output)")
        }
        #expect(lines.contains { $0.hasPrefix("FAIL 6 ") && $0.contains("gate") }, "\(output)")
        #expect(lines.contains { $0.hasPrefix("PASS 9 cleanup") }, "\(output)")
        #expect(lines.contains { $0.contains("recheck of the gate refused") })
        #expect(fixture.windows.opens.count == 1 && fixture.windows.closed.count == 1)
        #expect(fixture.violations.withLock { $0 }.isEmpty)
        #expect(left.isEmpty, "\(left)")
      })
  } // End of func aRecheckThatFailsMidRunStopsTheRun()

  /// SIGTERM arrives right after the first window's close: the steps stop, cleanup runs (its
  /// control client ended, any window closed only after its helper exited, the session killed),
  /// and the run exits 1 with nothing left.
  @Test(.enabled(if: canRun), .timeLimit(.minutes(2)))
  func aSignalStopsTheRunAndCleansUp() async throws {
    let (interrupts, continuation) = AsyncStream<Int32>.makeStream()
    try await Self.run(
      interrupts: interrupts,
      prepare: { fixture in fixture.onFirstClose = { continuation.yield(SIGTERM) } },
      check: { fixture, status, lines, left in
        let output = lines.joined(separator: "\n")
        #expect(status == 1, "\(output)")
        #expect(lines.contains("Interrupted by signal \(SIGTERM); cleaning up."), "\(output)")
        #expect(lines.contains { $0.hasPrefix("PASS 9 cleanup") }, "\(output)")
        #expect(!lines.contains { $0.hasPrefix("PASS 8 ") })
        #expect(fixture.violations.withLock { $0 }.isEmpty)
        #expect(left.isEmpty, "\(left)")
      })
    continuation.finish()
  } // End of func aSignalStopsTheRunAndCleansUp()

  /// SIGTERM arrives while the move here's launch runs (right after its window opened): the
  /// launch is cancelled with its helper started, so the backend holds no record of it; cleanup
  /// learns that window's helper from its report or result, leaves the window while the helper
  /// runs, kills the session, then closes the window once the helper ended, and nothing is
  /// left.
  @Test(.enabled(if: canRun), .timeLimit(.minutes(2)))
  func aSignalDuringALaunchStillClosesOnlyEndedWindows() async throws {
    let (interrupts, continuation) = AsyncStream<Int32>.makeStream()
    try await Self.run(
      interrupts: interrupts,
      prepare: { fixture in
        fixture.afterOpen = { number in
          if number == 2 { continuation.yield(SIGTERM) }
        }
      },
      check: { fixture, status, lines, left in
        let output = lines.joined(separator: "\n")
        #expect(status == 1, "\(output)")
        #expect(lines.contains("Interrupted by signal \(SIGTERM); cleaning up."), "\(output)")
        #expect(lines.contains { $0.hasPrefix("FAIL 6 move here") }, "\(output)")
        #expect(lines.contains { $0.hasPrefix("PASS 9 cleanup") }, "\(output)")
        #expect(fixture.windows.opens.count == 2 && fixture.windows.closed.count == 2, "\(output)")
        #expect(fixture.violations.withLock { $0 }.isEmpty, "closed while a helper ran")
        #expect(left.isEmpty, "\(left)")
      })
    continuation.finish()
  } // End of func aSignalDuringALaunchStillClosesOnlyEndedWindows()

  /// A launch whose helper fails, as a real one does in a terminal's window (PLAN.md D38 *The
  /// plain runs (I-12c3b)*, review S1): its request withdrawn right before the helper starts
  /// (without `MUXFINDER_LAUNCH_NO_WAIT`), so the real helper writes its result, explains and
  /// waits for Return on its pseudo-terminal, where nobody types. Step 3 fails; cleanup leaves
  /// the window while the helper waits, kills the session, asks the helper to stop (SIGTERM,
  /// which finishes its wait), and only then closes the window: cleanup passes, exit 1, and
  /// nothing is left.
  @Test(.enabled(if: canRun), .timeLimit(.minutes(2)))
  func aFailedHelperWaitingForReturnIsStoppedBeforeItsWindowCloses() async throws {
    try await Self.run(
      prepare: { fixture in
        fixture.waitingHelpers = true
        fixture.helperEnd = .seconds(2)
        let store = fixture.store
        fixture.beforeHelper = { number, token in
          if number == 1 { _ = try? store.discardRequest(token) }
        }
      },
      check: { fixture, status, lines, left in
        let output = lines.joined(separator: "\n")
        #expect(status == 1, "\(output)")
        #expect(lines.contains { $0.hasPrefix("FAIL 3 open") }, "\(output)")
        let cleanup = try #require(lines.first { $0.hasPrefix("PASS 9 cleanup") }, "\(output)")
        #expect(cleanup.contains("asked 1 helper(s) of the run's own that still ran to stop"))
        #expect(cleanup.contains("its window closed by its recorded id after its helper ended"))
        #expect(fixture.windows.opens.count == 1 && fixture.windows.closed.count == 1, "\(output)")
        #expect(fixture.violations.withLock { $0 }.isEmpty, "closed while its helper ran")
        #expect(left.isEmpty, "\(left)")
      })
  } // End of func aFailedHelperWaitingForReturnIsStoppedBeforeItsWindowCloses()
} // End of struct E2EPlainStepsTests
