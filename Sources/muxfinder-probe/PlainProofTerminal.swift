import Darwin
import Foundation
import MuxFinderCore
import os

/// A pseudo-terminal `plain-proof` opens itself, standing in for a terminal app's window
/// (PLAN.md D38, Phase I-12a): a master end it drains, and a slave end whose path
/// (`/dev/ttysNNN`) is what tmux reports as a client's `client_tty`.
///
/// Everything the children write to it is read and discarded at once; only the number of bytes
/// is kept, never a byte of the output (PLAN.md *Unattended-run rules* 7). The harness keeps its
/// own descriptor of the slave end open (`O_NOCTTY`, never its controlling terminal), so the
/// master never reads end of file while children come and go, and a pseudo-terminal with no
/// child stays a real, unused terminal. The window size is 80 × 24.
final class ProofTerminal: @unchecked Sendable {
  /// The slave end's path.
  let path: String
  /// The harness's own descriptor of the slave end, until `close()`.
  private let slave: OSAllocatedUnfairLock<Int32>
  /// The read source draining the master end; its cancel handler closes the master.
  private let source: any DispatchSourceRead
  /// Bytes read and discarded so far.
  private let discarded = OSAllocatedUnfairLock(initialState: 0)

  /// Wraps an opened pair and starts draining the master.
  private init(master: Int32, slave: Int32, path: String) {
    self.path = path
    self.slave = OSAllocatedUnfairLock(initialState: slave)
    let queue = DispatchQueue(label: "cc.carpio.muxfinder.plain-proof.drain")
    source = DispatchSource.makeReadSource(fileDescriptor: master, queue: queue)
    let source = self.source
    let discarded = self.discarded
    source.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 16 * 1024)
      while true {
        let count = buffer.withUnsafeMutableBytes { read(master, $0.baseAddress, $0.count) }
        if count > 0 {
          discarded.withLock { $0 += count }
          continue
        }
        if count < 0, errno == EINTR { continue }
        if count < 0, errno == EAGAIN { return }
        source.cancel()
        return
      } // End of loop reading what is waiting
    } // End of the drain's event handler
    source.setCancelHandler { _ = Darwin.close(master) }
    source.resume()
  } // End of init(master:slave:path:)

  /// Opens a new pseudo-terminal (`posix_openpt`, `grantpt`, `unlockpt`), opens its slave end
  /// with `O_NOCTTY`, sets the window size and starts draining. Throws a `StepFailure` when a
  /// call fails.
  static func open() throws -> ProofTerminal {
    let master = posix_openpt(O_RDWR | O_NOCTTY)
    guard master >= 0 else { throw StepFailure("posix_openpt failed (errno \(errno))") }
    var name = [CChar](repeating: 0, count: 128)
    guard grantpt(master) == 0, unlockpt(master) == 0,
      ptsname_r(master, &name, name.count) == 0
    else {
      _ = Darwin.close(master)
      throw StepFailure("the pseudo-terminal could not be prepared (errno \(errno))")
    }
    let path = String(
      decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    let slave = Darwin.open(path, O_RDWR | O_NOCTTY)
    guard slave >= 0 else {
      _ = Darwin.close(master)
      throw StepFailure("the pseudo-terminal's slave end could not be opened (errno \(errno))")
    }
    for descriptor in [master, slave] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    var size = winsize(ws_row: 24, ws_col: 80, ws_xpixel: 0, ws_ypixel: 0)
    _ = ioctl(slave, TIOCSWINSZ, &size)
    return ProofTerminal(master: master, slave: slave, path: path)
  } // End of static func open()

  /// Bytes read from the master end and discarded so far.
  var discardedByteCount: Int { discarded.withLock { $0 } }

  /// Closes the harness's slave descriptor and the master end (the terminal hangs up for any
  /// child still on it). Safe to call more than once.
  func close() {
    let descriptor = slave.withLock { value -> Int32 in
      defer { value = -1 }
      return value
    }
    if descriptor >= 0 { _ = Darwin.close(descriptor) }
    source.cancel()
  }
} // End of class ProofTerminal

/// One child `plain-proof` runs on a `ProofTerminal`: a plain tmux client, or `/usr/bin/ssh -t`
/// running the plain remote attach (PLAN.md D38), as a terminal app would run it.
///
/// It is spawned in a new session (`POSIX_SPAWN_SETSID`, so it is its own process group) with
/// every signal at its default disposition and only descriptors 0–2 open (`/dev/null` at first),
/// through the static `trampoline`: `/bin/sh -c <trampoline> muxfinder <terminal> <executable>
/// <arguments>…`, data only as argv (PLAN.md D3). The shell, already the session's leader,
/// opens the terminal's slave end without `O_NOCTTY` as standard input, output and error, which
/// makes it the session's controlling terminal when no other session has it, then `exec`s the
/// command, so the child's pid is the command's. (A spawn file action opens the terminal before
/// macOS makes the new session, so it cannot make it the controlling terminal itself.)
///
/// It is observed with `waitid(WNOWAIT)` and reaped only after its group was signalled for the
/// last time, so a signal for the group never reaches a process that reused its id.
final class ProofChild: Sendable {
  /// The child's process id, also its process group and session id.
  let processID: pid_t
  /// The terminal it runs on.
  let terminal: ProofTerminal
  /// How it ended, once reaped.
  private let ended = OSAllocatedUnfairLock<ProcessResult.Termination?>(initialState: nil)

  /// The shell that runs `trampoline`.
  static let shellPath = "/bin/sh"

  /// Opens the terminal (`$1`) once, read-write (tmux's server also writes to the descriptor a
  /// client passes as its standard input, so a read-only one gets no screen), as standard
  /// input, output and error, then replaces the shell with the command (`$2` and the rest).
  /// Exit 126 when the terminal cannot be opened.
  static let trampoline: StaticShellScript = #"""
    t=$1
    shift
    exec "$@" 0<>"$t" 1>&0 2>&0
    exit 126
    """#

  /// Wraps a spawned child.
  private init(processID: pid_t, terminal: ProofTerminal) {
    self.processID = processID
    self.terminal = terminal
  }

  /// Spawns `command` on `terminal`. Throws a `StepFailure` when it cannot be started.
  static func start(_ command: HarnessCommand, on terminal: ProofTerminal) throws -> ProofChild {
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
    let words =
      [
        shellPath, "-c", trampoline.source, ShellQuoting.scriptName, terminal.path,
        command.executable,
      ] + command.arguments
    let argv = words.map { strdup($0) } + [nil]
    let envp =
      command.environment.sorted { $0.key < $1.key }.map { strdup("\($0.key)=\($0.value)") }
      + [nil]
    defer {
      for pointer in argv + envp { free(pointer) }
    }
    var processID: pid_t = 0
    let code = posix_spawn(&processID, shellPath, &actions, &attributes, argv, envp)
    guard code == 0 else { throw StepFailure("posix_spawn failed (errno \(code))") }
    return ProofChild(processID: processID, terminal: terminal)
  } // End of static func start(_:on:)

  /// How it ended, once reaped.
  var termination: ProcessResult.Termination? { ended.withLock { $0 } }

  /// Whether it is still running (not exited).
  var isRunning: Bool { termination == nil && !BackgroundControlClient.hasExited(processID) }

  /// Waits up to `time` for the child to exit by itself, then reaps it and returns how it
  /// ended; `nil` when it still runs.
  func waitForExit(within time: Duration) async -> ProcessResult.Termination? {
    if let done = termination { return done }
    guard await BackgroundControlClient.waitUntilExited(processID, within: time) else {
      return nil
    }
    return reap()
  }

  /// Ends the child on every way out: SIGTERM to its group, up to 3 s, then SIGKILL, and reaps
  /// it. Returns how it ended (`nil` only if it could not be reaped).
  @discardableResult
  func stop() async -> ProcessResult.Termination? {
    if let done = termination { return done }
    if BackgroundControlClient.hasExited(processID) { return reap() }
    _ = kill(-processID, SIGTERM)
    _ = kill(processID, SIGTERM)
    if await BackgroundControlClient.waitUntilExited(processID, within: .seconds(3)) {
      return reap()
    }
    _ = kill(-processID, SIGKILL)
    _ = kill(processID, SIGKILL)
    _ = await BackgroundControlClient.waitUntilExited(processID, within: .seconds(2))
    return reap()
  } // End of func stop()

  /// Reaps the exited child, after sending SIGKILL to whatever is left of its group (the
  /// unreaped leader still pins the group id), and records how it ended.
  private func reap() -> ProcessResult.Termination? {
    if let done = termination { return done }
    if kill(-processID, 0) == 0 { _ = kill(-processID, SIGKILL) }
    var status: Int32 = 0
    while waitpid(processID, &status, 0) != processID {
      if errno != EINTR { return nil }
    }
    let signal = status & 0x7f
    let result: ProcessResult.Termination =
      signal == 0 ? .exited((status >> 8) & 0xff) : .signaled(signal)
    ended.withLock { $0 = result }
    return result
  } // End of func reap()
} // End of class ProofChild

/// The process ids of this process's children still known to the kernel (running or not yet
/// reaped), read with `proc_listchildpids`.
func ownChildProcessIDs() -> [pid_t] {
  var buffer = [pid_t](repeating: 0, count: 256)
  let count = buffer.withUnsafeMutableBytes {
    proc_listchildpids(getpid(), $0.baseAddress, Int32($0.count))
  }
  guard count > 0 else { return [] }
  return Array(buffer.prefix(Int(count))).filter { $0 > 0 }
}
