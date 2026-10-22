import Darwin
import Foundation
import MuxFinderCore
import os

/// A plain tmux control client the e2e harness keeps attached in the background for its Move
/// here step (PLAN.md D21): `tmux -u -C attach-session -t '=<name>'` on this Mac, or the same
/// through noninteractive ssh on the remote host (`HarnessTmux.controlClientCommand(attachingTo:)`).
///
/// It is spawned directly (argv only, no shell) in a process group of its own, with every
/// signal at its default disposition and only descriptors 0–2 open: standard input is a pipe
/// whose write end the harness holds open (a control client exits at end of file), standard
/// output and standard error are pipes drained by one reader thread each. Nothing it prints is
/// logged or kept: standard output is only scanned for a line starting with `%exit`, the
/// notification tmux sends a control client it detaches (or that reaches end of input), and
/// standard error keeps at most its first 200 bytes as printable ASCII for a failure message.
///
/// The child is observed with `waitid(WNOWAIT)` and reaped only once its process group is
/// signalled for the last time, so a signal for the group can never reach a process that reused
/// its id. `stop()` ends it on every way out: it closes standard input, waits up to 3 s, then
/// ends the whole group (SIGTERM, then SIGKILL 2 s later) and reaps it.
final class BackgroundControlClient: Sendable {
  /// What the readers saw and how the client ended.
  private struct State {
    /// The write end of the client's standard input while open, else -1.
    var standardInput: Int32
    /// Whether a line of standard output started with `%exit`.
    var sawExit = false
    /// The current output line's first bytes (at most as many as `%exit` has), carried from one
    /// chunk to the next.
    var lineStart: [UInt8] = []
    /// The first bytes of standard error.
    var errorPrefix: [UInt8] = []
    /// How the client ended, once reaped.
    var termination: ProcessResult.Termination?
  }

  /// The most standard error kept, in bytes.
  static let errorLimit = 200

  /// The client's process id, also its process group id.
  let processID: pid_t
  /// The shared state.
  private let state: OSAllocatedUnfairLock<State>

  /// Wraps a spawned client whose standard input write end is `standardInput`.
  private init(processID: pid_t, standardInput: Int32) {
    self.processID = processID
    state = OSAllocatedUnfairLock(initialState: State(standardInput: standardInput))
  }

  /// Starts `executable` with `arguments` (argv after argv[0]) and `environment`, and the
  /// readers of its output. Throws `ProcessRunnerError` when it cannot be started.
  static func start(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) throws -> BackgroundControlClient {
    let input = try makePipe()
    let output: (read: Int32, write: Int32)
    let errors: (read: Int32, write: Int32)
    do {
      output = try makePipe()
      do {
        errors = try makePipe()
      } catch {
        closeAll([output.read, output.write])
        throw error
      }
    } catch {
      closeAll([input.read, input.write])
      throw error
    }
    let processID: pid_t
    do {
      processID = try spawn(
        executable: executable, arguments: arguments, environment: environment,
        standardInput: input.read, standardOutput: output.write, standardError: errors.write)
    } catch {
      closeAll([input.read, input.write, output.read, output.write, errors.read, errors.write])
      throw error
    }
    closeAll([input.read, output.write, errors.write])
    let client = BackgroundControlClient(processID: processID, standardInput: input.write)
    client.startReader(output.read, name: "stdout") { bytes, state in
      Self.scanForExit(bytes, state: &state)
    }
    client.startReader(errors.read, name: "stderr") { bytes, state in
      let room = Self.errorLimit - state.errorPrefix.count
      if room > 0 { state.errorPrefix += bytes.prefix(room) }
    }
    return client
  } // End of static func start(executable:arguments:environment:)

  /// Whether a line of the client's standard output started with `%exit`.
  var sawExitNotification: Bool { state.withLock { $0.sawExit } }

  /// The first bytes of the client's standard error, printable ASCII only (anything else `?`).
  var errorText: String {
    let bytes = state.withLock { $0.errorPrefix }
    return String(
      decoding: bytes.map { (0x20...0x7E).contains($0) ? $0 : UInt8(ascii: "?") }, as: UTF8.self)
  }

  /// How the client ended, once it was reaped.
  var termination: ProcessResult.Termination? { state.withLock { $0.termination } }

  /// Whether the client is still running (not exited).
  var isRunning: Bool { state.withLock { $0.termination == nil } && !Self.hasExited(processID) }

  /// Waits up to `time` for the client to exit by itself, then reaps it (ending what is left of
  /// its group first) and returns how it ended; `nil` when it still runs.
  func waitForExit(within time: Duration) async -> ProcessResult.Termination? {
    if let ended = termination { return ended }
    guard await Self.waitUntilExited(processID, within: time) else { return nil }
    return reap()
  }

  /// Ends the client on every way out: closes its standard input (a control client exits at end
  /// of input), waits up to 3 s, then sends its group SIGTERM and, 2 s later, SIGKILL, and
  /// reaps it. Returns how it ended (`nil` only if it could not be reaped).
  @discardableResult
  func stop() async -> ProcessResult.Termination? {
    if let ended = termination { return ended }
    closeStandardInput()
    if await Self.waitUntilExited(processID, within: .seconds(3)) { return reap() }
    Self.signalGroup(processID, SIGTERM)
    if await Self.waitUntilExited(processID, within: .seconds(2)) { return reap() }
    Self.signalGroup(processID, SIGKILL)
    _ = await Self.waitUntilExited(processID, within: .seconds(2))
    return reap()
  } // End of func stop()

  /// Closes the write end of the client's standard input, once.
  func closeStandardInput() {
    let descriptor = state.withLock { state -> Int32 in
      defer { state.standardInput = -1 }
      return state.standardInput
    }
    if descriptor >= 0 { _ = Darwin.close(descriptor) }
  }

  /// Reaps the exited client, after sending SIGKILL to whatever is left of its group (the
  /// unreaped leader still pins the group id, so the signal cannot reach another process), and
  /// records how it ended. Closes standard input if still open.
  private func reap() -> ProcessResult.Termination? {
    if let ended = termination { return ended }
    closeStandardInput()
    if kill(-processID, 0) == 0 { _ = kill(-processID, SIGKILL) }
    var status: Int32 = 0
    while waitpid(processID, &status, 0) != processID {
      if errno != EINTR { return nil }
    }
    let signal = status & 0x7f
    let ended: ProcessResult.Termination =
      signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    state.withLock { $0.termination = ended }
    return ended
  } // End of func reap()

  /// Starts a thread that reads `descriptor` until end of file, hands each chunk to `consume`
  /// under the lock, and closes it.
  private func startReader(
    _ descriptor: Int32,
    name: String,
    consume: @escaping @Sendable (ArraySlice<UInt8>, inout State) -> Void
  ) {
    let state = self.state
    let thread = Thread {
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count > 0 {
          let chunk = buffer[..<count]
          state.withLock { consume(chunk, &$0) }
        } else if count < 0, errno == EINTR {
          continue
        } else {
          break
        }
      } // End of loop reading the pipe
      _ = Darwin.close(descriptor)
    }
    thread.name = "cc.carpio.muxfinder.e2e-control-client.\(name)"
    thread.start()
  } // End of func startReader(_:name:consume:)

  /// The bytes of `%exit`.
  private static let exitPrefix = Array("%exit".utf8)

  /// Scans a chunk of standard output for a line starting with `%exit`; only that fact (and the
  /// current line's first bytes) is kept.
  private static func scanForExit(_ bytes: ArraySlice<UInt8>, state: inout State) {
    for byte in bytes {
      if byte == UInt8(ascii: "\n") {
        state.lineStart.removeAll(keepingCapacity: true)
      } else if state.lineStart.count < exitPrefix.count {
        state.lineStart.append(byte)
        if state.lineStart == exitPrefix { state.sawExit = true }
      }
    } // End of loop over the chunk's bytes
  } // End of static func scanForExit(_:state:)

  /// Whether `processID` has exited, without reaping it (`WNOWAIT`).
  private static func hasExited(_ processID: pid_t) -> Bool {
    var info = siginfo_t()
    while true {
      if waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
        return info.si_pid != 0
      }
      if errno != EINTR { return true }
    }
  } // End of static func hasExited(_:)

  /// Polls every 50 ms, up to `time`, until `processID` has exited. Returns whether it did.
  private static func waitUntilExited(_ processID: pid_t, within time: Duration) async -> Bool {
    let deadline = ContinuousClock.now + time
    while !hasExited(processID) {
      guard ContinuousClock.now < deadline else { return false }
      try? await Task.sleep(for: .milliseconds(50))
    }
    return true
  }

  /// Sends `signal` to the group `processID` leads and to the process itself (only while it is
  /// unreaped, so neither id can have been reused).
  private static func signalGroup(_ processID: pid_t, _ signal: Int32) {
    _ = kill(-processID, signal)
    _ = kill(processID, signal)
  }

  /// A pipe with close-on-exec set on both ends.
  private static func makePipe() throws -> (read: Int32, write: Int32) {
    var descriptors: [Int32] = [-1, -1]
    guard pipe(&descriptors) == 0 else {
      throw ProcessRunnerError.systemCallFailed(name: "pipe", errno: errno)
    }
    for descriptor in descriptors { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
    return (descriptors[0], descriptors[1])
  }

  /// Closes every descriptor in `descriptors`.
  private static func closeAll(_ descriptors: [Int32]) {
    for descriptor in descriptors { _ = Darwin.close(descriptor) }
  }

  /// Spawns `executable` in a new process group with default signal dispositions, an empty
  /// signal mask and only descriptors 0–2 open (`POSIX_SPAWN_CLOEXEC_DEFAULT`), and returns its
  /// process id.
  private static func spawn(
    executable: String,
    arguments: [String],
    environment: [String: String],
    standardInput: Int32,
    standardOutput: Int32,
    standardError: Int32
  ) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    posix_spawn_file_actions_init(&actions)
    posix_spawnattr_init(&attributes)
    defer {
      posix_spawn_file_actions_destroy(&actions)
      posix_spawnattr_destroy(&attributes)
    }
    posix_spawn_file_actions_adddup2(&actions, standardInput, 0)
    posix_spawn_file_actions_adddup2(&actions, standardOutput, 1)
    posix_spawn_file_actions_adddup2(&actions, standardError, 2)
    let flags =
      POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF
      | POSIX_SPAWN_CLOEXEC_DEFAULT
    posix_spawnattr_setflags(&attributes, Int16(flags))
    posix_spawnattr_setpgroup(&attributes, 0)
    var blocked = sigset_t()
    sigemptyset(&blocked)
    posix_spawnattr_setsigmask(&attributes, &blocked)
    var defaults = sigset_t()
    sigfillset(&defaults)
    sigdelset(&defaults, SIGKILL)
    sigdelset(&defaults, SIGSTOP)
    posix_spawnattr_setsigdefault(&attributes, &defaults)
    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp =
      environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
      + [nil]
    defer {
      for pointer in argv + envp { free(pointer) }
    }
    var processID: pid_t = 0
    let code = posix_spawn(&processID, executable, &actions, &attributes, argv, envp)
    guard code == 0 else { throw ProcessRunnerError.spawnFailed(errno: code) }
    return processID
  } // End of static func spawn(executable:arguments:environment:standardInput:…)
}
