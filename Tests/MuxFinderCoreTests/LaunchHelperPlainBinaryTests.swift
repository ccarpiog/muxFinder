import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The plain mode for real (PLAN.md D38, Phase I-12b2's check): the runner's read-write
/// standard input on a pseudo-terminal, and one real plain attach of the built
/// `muxfinder-launch attach-plain` with no terminal app and no iTerm2. The helper runs on a
/// pseudo-terminal this test opens itself (as `plain-proof` does: its own session, that
/// terminal its controlling one, everything printed drained and counted, never kept), against
/// a `muxfinder-test-*` session on a private tmux server (`TMUX_TMPDIR` a folder from
/// `mkdtemp("/private/tmp/mfx.XXXXXX")`), with a private launch directory, test mode and
/// `MUXFINDER_LAUNCH_NO_WAIT=1`. Only that session is ever killed (never `kill-server`); the
/// server ends with it. The helper is the one built with the tests, or the one at the absolute
/// path in `MUXFINDER_TEST_LAUNCH_HELPER` (such as the app bundle's).
@Suite("Launch helper plain mode (real)")
struct LaunchHelperPlainBinaryTests {
  /// Names another helper to run, such as `build/muxFinder.app/Contents/MacOS/muxfinder-launch`.
  static let helperVariable = "MUXFINDER_TEST_LAUNCH_HELPER"

  /// The helper the real attach runs: `helperVariable`'s executable when set, else the one
  /// built with the tests (`LaunchHelperBinaryTests.helperURL`).
  static let helperURL: URL? = {
    guard let path = ProcessInfo.processInfo.environment[helperVariable] else {
      return LaunchHelperBinaryTests.helperURL
    }
    guard path.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: path) else {
      return nil
    }
    return URL(fileURLWithPath: path)
  }()

  /// A pseudo-terminal the test owns: the master drained on a queue (bytes counted, never
  /// kept), the slave kept open by the test with `O_NOCTTY` (so the master never reads end of
  /// file between children), 80 × 24.
  final class DrainedTerminal: @unchecked Sendable {
    /// The slave end's path.
    let path: String
    /// The test's own slave descriptor.
    let slave: Int32
    /// The drain of the master; its cancel handler closes the master.
    private let source: any DispatchSourceRead
    /// Bytes read and discarded so far.
    private let drained = OSAllocatedUnfairLock(initialState: 0)

    /// Opens and prepares a pseudo-terminal, or throws.
    init() throws {
      let master = posix_openpt(O_RDWR | O_NOCTTY)
      guard master >= 0 else { throw POSIXError(.EIO) }
      var name = [CChar](repeating: 0, count: 128)
      guard grantpt(master) == 0, unlockpt(master) == 0,
        ptsname_r(master, &name, name.count) == 0
      else {
        Darwin.close(master)
        throw POSIXError(.EIO)
      }
      path = String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
      slave = open(path, O_RDWR | O_NOCTTY | O_CLOEXEC)
      guard slave >= 0 else {
        Darwin.close(master)
        throw POSIXError(.EIO)
      }
      _ = fcntl(master, F_SETFD, FD_CLOEXEC)
      _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
      var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
      _ = ioctl(slave, TIOCSWINSZ, &size)
      source = DispatchSource.makeReadSource(
        fileDescriptor: master, queue: DispatchQueue(label: "cc.carpio.muxfinder.test-drain"))
      let source = source
      let drained = drained
      source.setEventHandler {
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
          let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
          if count > 0 {
            drained.withLock { $0 += count }
            continue
          }
          if count < 0, errno == EINTR { continue }
          if count < 0, errno == EAGAIN { return }
          source.cancel()
          return
        } // End of loop reading what is waiting
      } // End of the drain's event handler
      source.setCancelHandler { Darwin.close(master) }
      source.resume()
    } // End of init()

    /// Bytes drained so far.
    var drainedByteCount: Int { drained.withLock { $0 } }

    /// Closes the test's slave descriptor and the master.
    func close() {
      Darwin.close(slave)
      source.cancel()
    }
  } // End of class DrainedTerminal

  /// Opens the terminal (`$1`) as standard input **read-only** and as standard output and error
  /// write-only, which makes it the new session's controlling terminal, then replaces the shell
  /// with the command (`$2` and the rest). A read-only standard input is the case the helper's
  /// read-write reopen exists for: tmux draws through it.
  static let trampoline = #"""
    t=$1
    shift
    exec "$@" 0<"$t" 1>"$t" 2>&1
    exit 126
    """#

  /// Spawns `argv` in a new session on `terminal` through `trampoline`, with exactly
  /// `environment`, every signal at its default and only descriptors 0–2.
  static func spawn(
    _ argv: [String],
    on terminal: DrainedTerminal,
    environment: [String: String]
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDWR, 0)
    posix_spawn_file_actions_adddup2(&actions, 0, 1)
    posix_spawn_file_actions_adddup2(&actions, 0, 2)
    let flags =
      POSIX_SPAWN_SETSID | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attributes, Int16(flags))
    var blocked = sigset_t()
    sigemptyset(&blocked)
    posix_spawnattr_setsigmask(&attributes, &blocked)
    var defaults = sigset_t()
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    let words = ["/bin/sh", "-c", trampoline, "muxfinder", terminal.path] + argv
    let cArgv = words.map { strdup($0) } + [nil]
    let cEnv =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
      for pointer in cArgv + cEnv { free(pointer) }
    }
    var processID: pid_t = 0
    let code = posix_spawn(&processID, "/bin/sh", &actions, &attributes, cArgv, cEnv)
    guard code == 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
    return processID
  } // End of static func spawn(_:on:environment:)

  /// Waits (at most `limit`) for `processID` to exit and reaps it; its termination, or `nil`
  /// when it still runs.
  static func waitForExit(_ processID: pid_t, within limit: Duration) async -> ProcessResult
    .Termination?
  {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      var status: Int32 = 0
      let reaped = waitpid(processID, &status, WNOHANG)
      if reaped == processID { return ProcessSupervisor.termination(fromWaitStatus: status) }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return nil
  } // End of static func waitForExit(_:within:)

  /// Polls `body` every 20 ms for at most `limit` and returns its first non-`nil` value.
  static func eventually<Value>(
    within limit: Duration,
    _ body: () async throws -> Value?
  ) async rethrows -> Value? {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if let value = try await body() { return value }
      try? await Task.sleep(for: .milliseconds(20))
    }
    return try await body()
  } // End of static func eventually(within:_:)

  /// A private folder under `/private/tmp` from `mkdtemp`, short enough for a socket path.
  static func makePrivateFolder() throws -> URL {
    var template = Array("/private/tmp/mfx.XXXXXX".utf8CString)
    guard let path = mkdtemp(&template) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return URL(fileURLWithPath: String(cString: path), isDirectory: true)
  }

  /// The parent pid of `processID`, or `nil`.
  static func parent(of processID: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
  }

  /// `LaunchChildStandardInput.terminalReadWrite`: a terminal reached only read-only is opened
  /// again read-write (same device) for the child, which can then write through its standard
  /// input; a pipe or `/dev/null` is no terminal, so nothing is reopened.
  @Test(.timeLimit(.minutes(1)))
  func reopensTheTerminalReadWrite() async throws {
    let terminal = try DrainedTerminal()
    defer { terminal.close() }
    let readOnly = open(terminal.path, O_RDONLY | O_NOCTTY | O_CLOEXEC)
    try #require(readOnly >= 0)
    defer { close(readOnly) }
    let reopened = try #require(TerminalChildRunner.openReadWriteTerminal(like: readOnly))
    #expect(fcntl(reopened, F_GETFL) & O_ACCMODE == O_RDWR)
    var first = stat()
    var second = stat()
    #expect(fstat(readOnly, &first) == 0 && fstat(reopened, &second) == 0)
    #expect(first.st_rdev == second.st_rdev)
    close(reopened)
    let null = open("/dev/null", O_RDONLY | O_CLOEXEC)
    defer { close(null) }
    #expect(TerminalChildRunner.openReadWriteTerminal(like: null) == nil)
    let pipe = try PipePair.make()
    defer {
      close(pipe.readEnd)
      close(pipe.writeEnd)
    }
    #expect(TerminalChildRunner.openReadWriteTerminal(like: pipe.readEnd) == nil)

    let runner = TerminalChildRunner(terminalInput: readOnly)
    let before = terminal.drainedByteCount
    let outcome = try await runner.run(
      executable: "/bin/sh", arguments: ["-c", "printf muxfinder-rw >&0"],
      environment: TestSupport.environment, relaysStandardError: false,
      standardInput: .terminalReadWrite, onSpawn: nil)
    #expect(outcome.termination == .exited(0))
    let wrote = await Self.eventually(within: .seconds(2)) {
      terminal.drainedByteCount >= before + 12 ? true : nil
    }
    #expect(wrote == true)
  } // End of func reopensTheTerminalReadWrite()

  /// One real plain attach: the built helper on a pseudo-terminal of the test's (standard input
  /// read-only), a private server's `muxfinder-test-*` session, a plain request. The early
  /// report names that terminal, the helper's pid and its attach child (the helper's own child,
  /// its kernel start time); the session has exactly that one client, on that terminal, and
  /// tmux draws on it; the bound `PlainClientDetach` ends it; the helper writes its result
  /// (success) and exits 0; nothing is left (the report goes with the result, the session is
  /// killed, the server gone, the helper reaped and its attach child gone).
  @Test(
    .enabled(
      if: LaunchHelperPlainBinaryTests.helperURL != nil && DiscoveryEndToEndTests.tmuxPath != nil),
    .timeLimit(.minutes(1)))
  func realPlainAttachOnAPseudoTerminal() async throws {
    let helper = try #require(Self.helperURL)
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let socketFolder = try Self.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: socketFolder) }
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let server = PlainBoundCommandsTests.Server(
      tmux: tmux,
      environment: [
        "PATH": ProcessEnvironment.systemSearchPath,
        "HOME": socketFolder.path(percentEncoded: false),
        "TMUX_TMPDIR": socketFolder.path(percentEncoded: false),
      ])
    let name = "muxfinder-test-plain-helper-\(UUID().uuidString.prefix(8).lowercased())"
    let terminal = try DrainedTerminal()
    var helperProcess: pid_t?
    var attachChild: (pid: pid_t, start: ProcessStartTime)?
    do {
      let created = try await Self.createSession(name, on: server)
      #expect(created.server.socketPath.hasPrefix(socketFolder.path(percentEncoded: false)))
      var request = LaunchRequest(
        createdAt: Date(), host: .local, hostID: UUID(), tmuxPathOverride: nil,
        sessionID: created.sessionID, expectedServerPID: created.server.pid,
        expectedServerStartTime: created.server.startTime,
        expectedSessionCreated: created.createdAt)
      request.terminal = .plain(definitionID: "terminal")
      try store.writeRequest(request)
      var environment = server.environment
      environment[LaunchHelper.directoryVariable] = store.directory.path(percentEncoded: false)
      environment[StandardLaunchTerminal.noWaitVariable] = "1"
      environment[LaunchHelper.testModeVariable] = "1"
      environment["TERM"] = "xterm-256color"
      environment["LANG"] = "en_US.UTF-8"
      let processID = try Self.spawn(
        [helper.path(percentEncoded: false), "attach-plain", request.id.rawValue], on: terminal,
        environment: environment)
      helperProcess = processID

      let report = try #require(
        try await Self.eventually(within: .seconds(10)) { try store.peekReport(request.id) })
      #expect(report.helperPID == processID)
      #expect(report.terminalPath == terminal.path)
      let digestURL = store.directory.appending(
        path: LaunchArgvDigest.fileName(helperPID: processID))
      let childPID = try #require(
        await Self.eventually(within: .seconds(5)) {
          (try? Data(contentsOf: digestURL)).flatMap {
            try? LaunchCoding.decoder().decode(LaunchArgvDigest.self, from: $0)
          }?.attachChildProcessID
        })
      #expect(report.attachChildPID == childPID)
      #expect(Self.parent(of: childPID) == processID)
      #expect(ProcessStartTime.of(childPID) == report.attachChildStartTime)
      attachChild = (childPID, report.attachChildStartTime)

      let client = try #require(
        try await Self.eventually(within: .seconds(10)) {
          try await Self.confirmedClient(of: created.sessionID, on: terminal.path, server: server)
        })
      #expect(client.processID == childPID)
      let drawn = await Self.eventually(within: .seconds(3)) {
        terminal.drainedByteCount >= 200 ? terminal.drainedByteCount : nil
      }
      #expect(drawn != nil, "tmux drew \(terminal.drainedByteCount) bytes")

      #expect(try await server.detach(client, from: BoundSessionIdentity(created)) == .detached)
      let ended = await Self.waitForExit(processID, within: .seconds(10))
      if ended != nil { helperProcess = nil }
      #expect(ended == .exited(0))
      #expect(try await server.clients().isEmpty)
      let result = try #require(try store.takeResult(request.id))
      #expect(result.succeeded && result.childTermination == .exited(0))
      #expect(result.helperPID == processID)
      #expect(try store.peekReport(request.id) == nil)
      _ = try store.takeArgvDigests()
      #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
    } catch {
      await Self.cleanUp(helperProcess, server: server, terminal: terminal)
      throw error
    }
    await Self.cleanUp(helperProcess, server: server, terminal: terminal)
    #expect(try await server.run(["list-sessions"]).succeeded == false)
    if let attachChild {
      #expect(ProcessStartTime.of(attachChild.pid) != attachChild.start, "attach child left")
    }
  } // End of func realPlainAttachOnAPseudoTerminal()

  /// Creates the detached session `name` running `sleep 600` on `server`, starting the private
  /// server with no configuration file (`-f /dev/null`), so no user `tmux.conf` runs.
  static func createSession(
    _ name: String,
    on server: PlainBoundCommandsTests.Server
  ) async throws -> CreatedSession {
    let result = try await server.run([
      "-f", "/dev/null", "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", name,
      "sleep", "600",
    ])
    try #require(result.succeeded)
    return try #require(
      CreatedSession.parse(String(decoding: result.standardOutput, as: UTF8.self)))
  } // End of static func createSession(_:on:)

  /// The session's one client on `terminal` (`PlainClientIdentification.local` over the whole
  /// listing), or `nil` while there is none (or more than one).
  static func confirmedClient(
    of sessionID: TmuxSessionID,
    on terminal: String,
    server: PlainBoundCommandsTests.Server
  ) async throws -> OtherClient? {
    let listing = try await server.run([
      "list-clients", "-F", PlainClientIdentification.localFormat,
    ])
    guard listing.succeeded,
      let reading = PlainClientIdentification.local(
        listing: String(decoding: listing.standardOutput, as: UTF8.self), sessionID: sessionID,
        terminal: terminal),
      case .confirmed(let client) = reading.outcome, reading.clients.count == 1
    else { return nil }
    return client
  } // End of static func confirmedClient(of:on:server:)

  /// On every way out: kills only the test's `muxfinder-test-*` sessions (the server ends with
  /// its last session), waits until no server answers, ends and reaps the helper if it still
  /// runs (the pseudo-terminal's hang-up reaches what is left on it), closes the terminal.
  static func cleanUp(
    _ helper: pid_t?,
    server: PlainBoundCommandsTests.Server,
    terminal: DrainedTerminal
  ) async {
    await DiscoveryEndToEndTests.cleanUp([], tmux: server.tmux, environment: server.environment)
    try? await server.waitUntilGone()
    if let helper {
      if await waitForExit(helper, within: .seconds(5)) == nil {
        _ = kill(helper, SIGKILL)
        _ = await waitForExit(helper, within: .seconds(5))
      }
    }
    terminal.close()
  } // End of static func cleanUp(_:server:terminal:)
} // End of struct LaunchHelperPlainBinaryTests
