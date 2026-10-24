import Darwin
import Foundation
import os

/// How the helper's attach child ended.
public struct LaunchChildOutcome: Sendable, Equatable {
  /// The child's process id.
  public var processID: Int32
  /// How it ended.
  public var termination: ProcessResult.Termination
  /// When it was spawned.
  public var startedAt: Date
  /// When it was reaped.
  public var endedAt: Date
  /// The signals passed on to it, in order.
  public var forwardedSignals: [Int32]
  /// The first bytes the child wrote on its standard error, when it was relayed (an ssh child,
  /// PLAN.md D17); empty otherwise. Used only to classify a failure, never logged.
  public var capturedStandardError: Data

  /// Creates an outcome.
  public init(
    processID: Int32,
    termination: ProcessResult.Termination,
    startedAt: Date,
    endedAt: Date,
    forwardedSignals: [Int32] = [],
    capturedStandardError: Data = Data()
  ) {
    self.processID = processID
    self.termination = termination
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.forwardedSignals = forwardedSignals
    self.capturedStandardError = capturedStandardError
  } // End of init(processID:termination:startedAt:endedAt:forwardedSignals:…)

  /// Whether a SIGHUP was passed on, meaning the terminal went away (the tab was closed).
  public var terminalHungUp: Bool { forwardedSignals.contains(SIGHUP) }
}

/// How the helper's check child ended.
public enum LaunchCheckOutcome: Sendable, Equatable {
  /// The check ran to completion or was stopped by its deadline (`ProcessResult.timedOut`).
  case finished(ProcessResult)
  /// A signal for the helper (never empty, in order) arrived before the check ended. The
  /// check's process group was killed, or the check was never started.
  case interrupted(signals: [Int32])

  /// Whether one of the signals was SIGHUP, meaning the terminal went away.
  public var terminalHungUp: Bool {
    if case .interrupted(let signals) = self { return signals.contains(SIGHUP) }
    return false
  }
}

/// Runs the helper's two children. The production implementation is `TerminalChildRunner`;
/// tests substitute fakes.
public protocol LaunchChildRunner: Sendable {
  /// Runs the check child `request` to completion with piped output, in its own process group
  /// and with the request's deadline. A signal for the helper that arrives before it ends
  /// kills its whole group and yields `.interrupted`.
  func runCheck(_ request: ProcessRequest) async throws(ProcessRunnerError) -> LaunchCheckOutcome

  /// Spawns the attach child `executable` with `arguments` (after argv[0]) and exactly
  /// `environment` on the helper's terminal, and returns once it has ended and been reaped.
  /// With `relaysStandardError`, the child's standard error is a pipe whose bytes are copied to
  /// the helper's terminal as they arrive, and the first of them are returned in
  /// `LaunchChildOutcome.capturedStandardError` (the ssh child, PLAN.md D17). `onSpawn`, when
  /// given, gets the child's process id right after the spawn, while the child runs and before
  /// it can be reaped (the helper's test mode records it, PLAN.md Phase 13a); it runs on the
  /// thread that supervises the child, so it must not block for long.
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    relaysStandardError: Bool,
    onSpawn: (@Sendable (Int32) -> Void)?
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome
}

extension LaunchChildRunner {
  /// Spawns the attach child without an `onSpawn` callback.
  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    relaysStandardError: Bool
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    try await run(
      executable: executable, arguments: arguments, environment: environment,
      relaysStandardError: relaysStandardError, onSpawn: nil)
  }

  /// Spawns the attach child with all three terminal descriptors inherited (no relay).
  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    try await run(
      executable: executable, arguments: arguments, environment: environment,
      relaysStandardError: false, onSpawn: nil)
  }
}

/// Copies what the attach child writes on its standard error to `destination` (the helper's
/// terminal) as it arrives, and keeps the first `limit` bytes, so the helper can classify an
/// ssh failure while the tab still shows ssh's own message (PLAN.md D17). ssh writes its
/// prompts to `/dev/tty`, not to standard error, so they are not affected.
///
/// Neither side of the relay can stall the supervision loop that drives it (passing on
/// signals, noticing the child's exit, the drain deadline):
/// - **Bounded reads:** one `pump(using:)` reads at most `readBudget` bytes, so a descendant
///   that never stops writing (an ssh `ProxyCommand`, say) hands the loop back after each
///   budget; the read watch is level-triggered, so the next round goes on reading at once.
/// - **Writes that never block:** when the destination is a terminal, the relay writes through
///   a descriptor of its own, opened on the same terminal with `O_NONBLOCK`. That is a separate
///   open file description, so the child's descriptors for the terminal stay blocking. Any
///   other destination is written only when `poll` reports it writable, at most `PIPE_BUF`
///   bytes at a time, which a pipe, socket or file then takes without blocking (a device
///   `poll` does not support, such as `/dev/null`, is written to directly).
/// - **Back-pressure, then dropping:** bytes the destination does not take at once wait in a
///   buffer of at most `pendingLimit` bytes; while it is full the relay reads nothing more
///   (`wantsInput`), so the child waits on its pipe as it would on a slow terminal, while the
///   loop goes on supervising. Bytes still waiting when the relay finishes (the destination
///   stayed blocked past the drain deadline) are dropped from the tab, and so is everything
///   once writing failed (the tab is gone); `droppedByteCount` counts them. The capture comes
///   from what was read, so a slow tab never costs the classification any bytes.
struct StandardErrorRelay {
  /// At most this many bytes are read per `pump(using:)`.
  static let readBudget = 64 * 1024
  /// At most this many bytes wait for the destination.
  static let pendingLimit = 64 * 1024

  /// The non-blocking read end of the child's standard error pipe, or -1 once closed.
  private(set) var source: Int32
  /// Where the bytes are copied to.
  let destination: Int32
  /// The descriptor the relay writes: its own non-blocking descriptor for the destination's
  /// terminal, or `destination` itself; -1 once closed.
  private(set) var output: Int32
  /// Whether `output` was opened here (and is closed here).
  let ownsOutput: Bool
  /// Whether writes to `output` return instead of blocking (`O_NONBLOCK`); otherwise each write
  /// waits for `poll` to report it writable and takes at most `PIPE_BUF` bytes.
  let outputIsNonBlocking: Bool
  /// How many bytes are kept.
  let limit: Int
  /// The first `limit` bytes the child wrote.
  private(set) var captured = Data()
  /// Bytes read but not yet written, at most `pendingLimit`.
  private var pending: [UInt8] = []
  /// Whether writing failed (or the relay was closed), so nothing more is written.
  private var outputFailed = false
  /// Bytes read from the pipe so far.
  private(set) var readByteCount = 0
  /// Bytes read but never written to the destination.
  private(set) var droppedByteCount = 0

  /// Relays from `source` (made non-blocking here) to `destination`. A terminal destination is
  /// opened again for non-blocking writes (`openNonBlockingTerminal(like:)`).
  init(source: Int32, destination: Int32, limit: Int) {
    _ = fcntl(source, F_SETFL, fcntl(source, F_GETFL) | O_NONBLOCK)
    self.source = source
    self.destination = destination
    self.limit = max(0, limit)
    if let terminal = Self.openNonBlockingTerminal(like: destination) {
      output = terminal
      ownsOutput = true
      outputIsNonBlocking = true
    } else {
      output = destination
      ownsOutput = false
      let flags = fcntl(destination, F_GETFL)
      outputIsNonBlocking = flags >= 0 && flags & O_NONBLOCK != 0
    }
  } // End of init(source:destination:limit:)

  /// A new write-only descriptor (`O_NONBLOCK`, `O_NOCTTY`, `O_CLOEXEC`) for the terminal
  /// `descriptor` refers to, or `nil` when it is not a terminal or cannot be opened again (or
  /// the path names another device). Its `O_NONBLOCK` stays on its own open file description
  /// (`NonBlockingTerminal.reopen(_:access:)`).
  static func openNonBlockingTerminal(like descriptor: Int32) -> Int32? {
    NonBlockingTerminal.reopen(descriptor, access: O_WRONLY)
  }

  /// Whether the relay reads more: the pipe is open and the pending bytes leave room.
  var wantsInput: Bool { source >= 0 && pending.count < Self.pendingLimit }

  /// The descriptor to watch for writability while bytes wait for it, else `nil`.
  var blockedOutput: Int32? { pending.isEmpty || outputFailed ? nil : output }

  /// Reads what is available now (at most `readBudget` bytes, and only while the pending bytes
  /// leave room) and writes what the destination takes without blocking. Closes the pipe at
  /// end-of-file or on an error.
  mutating func pump(using buffer: inout [UInt8]) {
    var budget = Self.readBudget
    while wantsInput, budget > 0 {
      let descriptor = source
      let wanted = min(buffer.count, budget, Self.pendingLimit - pending.count)
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, wanted) }
      if count > 0 {
        budget -= count
        accept(buffer[0..<count])
        flush()
        continue
      }
      if count < 0 && errno == EINTR { continue }
      if count < 0 && errno == EAGAIN { break }
      closeSource()
    } // End of loop over reads
    flush()
  } // End of func pump(using:)

  /// Captures the first bytes and queues `bytes` for the destination (or drops them once
  /// writing failed).
  private mutating func accept(_ bytes: ArraySlice<UInt8>) {
    readByteCount += bytes.count
    let room = limit - captured.count
    if room > 0 { captured.append(contentsOf: bytes.prefix(room)) }
    if outputFailed {
      droppedByteCount += bytes.count
    } else {
      pending.append(contentsOf: bytes)
    }
  }

  /// Writes pending bytes until the destination would block, or writing fails (then every
  /// pending byte is dropped and nothing more is written).
  private mutating func flush() {
    while !pending.isEmpty, !outputFailed {
      var chunk = pending.count
      if !outputIsNonBlocking {
        var poller = pollfd(fd: output, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&poller, 1, 0)
        if ready < 0, errno == EINTR { continue }
        if ready == 0 { return }
        // `POLLNVAL` for an open descriptor is a device `poll` does not support (`/dev/null`
        // on macOS); such a device is written to directly.
        let unusable =
          poller.revents & Int16(POLLERR | POLLHUP) != 0
          || (poller.revents & Int16(POLLNVAL) != 0 && fcntl(output, F_GETFD) == -1)
        if ready < 0 || unusable {
          failOutput()
          return
        }
        chunk = min(chunk, Int(PIPE_BUF))
      }
      let descriptor = output
      let count = pending.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, chunk) }
      if count > 0 {
        pending.removeFirst(count)
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN {
        return
      } else {
        failOutput()
      }
    } // End of loop over writes
  } // End of func flush()

  /// Stops writing for good (the tab may be gone) and drops what waits.
  private mutating func failOutput() {
    outputFailed = true
    droppedByteCount += pending.count
    pending.removeAll()
  }

  /// After the child has exited: copies until end-of-file and until the pending bytes are
  /// written, for at most `time` (a descendant that outlived the child, such as an ssh
  /// `ProxyCommand`, may still hold the pipe open, and the tab may not take more), then
  /// closes the relay, dropping what still waits.
  mutating func finish(within time: Duration, using buffer: inout [UInt8]) {
    let deadline = ContinuousClock.now + time
    while true {
      pump(using: &buffer)
      guard source >= 0 || blockedOutput != nil else { break }
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { break }
      let milliseconds = Int32(max(1, min(100, remaining / .milliseconds(1))))
      var pollers: [pollfd] = []
      if wantsInput { pollers.append(pollfd(fd: source, events: Int16(POLLIN), revents: 0)) }
      if let blocked = blockedOutput {
        pollers.append(pollfd(fd: blocked, events: Int16(POLLOUT), revents: 0))
      }
      _ = poll(&pollers, nfds_t(pollers.count), milliseconds)
    } // End of loop draining the pipe and the pending bytes
    close()
  } // End of func finish(within:using:)

  /// Closes the read end if it is still open.
  mutating func closeSource() {
    guard source >= 0 else { return }
    Darwin.close(source)
    source = -1
  }

  /// Closes the read end and the relay's own terminal descriptor, dropping what still waits.
  mutating func close() {
    closeSource()
    failOutput()
    if ownsOutput, output >= 0 { Darwin.close(output) }
    output = -1
  }
} // End of struct StandardErrorRelay

/// The channel through which signals for the helper reach whichever child is running.
///
/// `watchTerminalSignals()` feeds it the process's own SIGHUP, SIGINT and SIGTERM for the rest
/// of the process's life; tests call `forward(_:)` directly instead, so they exercise
/// forwarding without changing the test process's signal dispositions; task cancellation
/// forwards SIGTERM. A signal stays pending until a stage takes it: the check stage turns it
/// into `.interrupted` (killing the check's group), the attach stage sends it to tmux (right
/// after the spawn if it arrived before).
public final class TerminalChildControl: Sendable {
  /// Lock-protected state.
  private struct State: Sendable {
    /// Signals waiting to be taken.
    var pending: [Int32] = []
    /// The attach stage's kqueue, or -1 while none is registered.
    var queue: Int32 = -1
    /// What the check stage runs when a signal arrives, if it is waiting.
    var interruptHandler: (@Sendable () -> Void)?
  }

  /// Identifier of the `EVFILT_USER` wakeup event.
  static let wakeupIdentifier: UInt = 1

  /// The shared state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a control with nothing pending.
  public init() {}

  /// Queues `signal`, wakes the attach stage if it is waiting and interrupts the check stage
  /// if it is running.
  public func forward(_ signal: Int32) {
    let handler = state.withLock { state -> (@Sendable () -> Void)? in
      state.pending.append(signal)
      if state.queue >= 0 { Self.wake(state.queue) }
      return state.interruptHandler
    }
    handler?()
  } // End of func forward(_:)

  /// Starts passing this process's SIGHUP, SIGINT and SIGTERM to `forward(_:)` for the rest of
  /// the process's life: a dedicated thread waits on a kqueue with `EVFILT_SIGNAL` for each,
  /// which records deliveries even while the signal is ignored. The caller ignores the signals
  /// first (`SIG_IGN`), so none stops the process before its result is written. Returns
  /// whether the watch is in place. Only the helper process calls this, once.
  @discardableResult
  public func watchTerminalSignals() -> Bool {
    let queue = kqueue()
    guard queue >= 0 else { return false }
    for signalNumber in TerminalChildRunner.forwardedSignalNumbers {
      let ident = UInt(signalNumber)
      guard KernelQueue.register(queue: queue, ident: ident, filter: EVFILT_SIGNAL) == 0 else {
        close(queue)
        return false
      }
    }
    let thread = Thread { [self] in
      var events = [KernelEvent](repeating: KernelEvent(), count: 8)
      while true {
        let count = KernelQueue.wait(queue: queue, into: &events, timeout: nil)
        if count < 0, errno != EINTR { break }
        for event in events.prefix(Int(max(0, count))) where event.flags & UInt16(EV_ERROR) == 0 {
          guard Int32(event.filter) == EVFILT_SIGNAL else { continue }
          forward(Int32(truncatingIfNeeded: event.ident))
        }
      } // End of signal watch loop
    }
    thread.name = "cc.carpio.muxfinder.launch-signals"
    thread.start()
    return true
  } // End of func watchTerminalSignals()

  /// Publishes the attach stage's kqueue.
  func attach(queue: Int32) {
    state.withLock { $0.queue = queue }
  }

  /// Withdraws the kqueue. Called before the attach stage closes it.
  func detach() {
    state.withLock { $0.queue = -1 }
  }

  /// Installs (or with `nil` removes) the check stage's interrupt handler. A signal already
  /// pending runs the new handler at once, so none slips through between a look at the
  /// pending signals and the installation.
  func setInterruptHandler(_ handler: (@Sendable () -> Void)?) {
    let runNow = state.withLock { state -> Bool in
      state.interruptHandler = handler
      return !state.pending.isEmpty
    }
    if runNow { handler?() }
  }

  /// Removes and returns the pending signals.
  func takePending() -> [Int32] {
    state.withLock { state in
      defer { state.pending.removeAll() }
      return state.pending
    }
  }

  /// Triggers the wakeup event on `queue`.
  private static func wake(_ queue: Int32) {
    var change = KernelEvent(
      ident: wakeupIdentifier,
      filter: Int16(EVFILT_USER),
      flags: 0,
      fflags: UInt32(NOTE_TRIGGER),
      data: 0,
      udata: nil
    )
    _ = kevent(queue, &change, 1, nil, 0, nil)
  } // End of func wake(_:)
}

/// Runs the helper's two children (PLAN.md D2, D14).
///
/// **Check** (`runCheck(_:)`): through `checkRunner` (a `PosixSpawnProcessRunner` in
/// production), so the check gets pipes instead of the terminal, leads its own process group
/// and has a hard deadline that kills the whole group (SIGTERM, then SIGKILL after the runner's
/// grace period). A signal for the helper cancels the run, which stops the group the same way;
/// nothing the check started survives it.
///
/// **Attach** (`run(executable:arguments:environment:)`): spawned on the helper's own terminal.
/// - The child inherits descriptors 0, 1 and 2 as they are (the iTerm2 tab's PTY), so
///   `tmux -CC` (or ssh carrying it) talks to iTerm2 directly. The one exception is the ssh
///   child's standard error, which may be a pipe relayed to the tab
///   (`relaysStandardError`, `StandardErrorRelay`), so the helper can classify an ssh failure;
///   with `-t`, the remote side's output reaches ssh's standard output, not that pipe. The
///   relay reads a bounded amount per round and never blocks on the tab, so neither a
///   descendant that keeps writing nor a tab that stops reading delays signals or the exit.
///   A closed descriptor among them becomes `/dev/null`. `POSIX_SPAWN_CLOEXEC_DEFAULT` closes
///   every other descriptor in the child.
/// - The child stays in the helper's process group, which is the terminal's foreground group,
///   so tmux can read the terminal (a background group would be stopped with `SIGTTIN`).
/// - The child starts with default signal dispositions and an empty signal mask.
/// - Signals reaching `control` are passed on to the child, so closing the tab or stopping the
///   helper never orphans tmux. Signals the terminal sends reach the child twice (the whole
///   foreground group gets them, then the forward); that is harmless, since the tmux client
///   exits on the first SIGHUP or SIGTERM and ignores SIGINT.
/// - All blocking work happens on a dedicated thread, never on Swift's cooperative pool.
///
/// Nothing here changes this process's signal dispositions; the helper ignores the signals and
/// starts `TerminalChildControl.watchTerminalSignals()` itself.
public struct TerminalChildRunner: LaunchChildRunner {
  /// The signals passed on to the children.
  public static let forwardedSignalNumbers: [Int32] = [SIGHUP, SIGINT, SIGTERM]
  /// Polling interval for the attach child's exit, a backstop for the kqueue exit watch.
  static let exitPollInterval: Duration = .milliseconds(250)
  /// How many bytes of a relayed standard error are kept for classification.
  public static let capturedStandardErrorLimit = 16 * 1024
  /// How long a relayed standard error may stay open, and its pending bytes wait for the tab,
  /// after the child exited.
  static let relayDrainTime: Duration = .milliseconds(500)

  /// The signal channel shared by both stages.
  public var control: TerminalChildControl
  /// Runs the check child.
  public var checkRunner: any ProcessRunner
  /// Where a relayed standard error is copied to: the helper's own standard error (the tab) in
  /// production; tests pass another descriptor.
  public var standardErrorDestination: Int32

  /// Creates a runner. Tests pass a runner with short grace periods.
  public init(
    control: TerminalChildControl = .init(),
    checkRunner: any ProcessRunner = PosixSpawnProcessRunner(),
    standardErrorDestination: Int32 = STDERR_FILENO
  ) {
    self.control = control
    self.checkRunner = checkRunner
    self.standardErrorDestination = standardErrorDestination
  }

  /// Runs the check. Returns `.interrupted` without starting it when a signal is already
  /// pending, and `.interrupted` after stopping its group when one arrives while it runs (or
  /// just as it ends: any signal before this returns means no attach). Cancelling the calling
  /// task counts as SIGTERM.
  public func runCheck(
    _ request: ProcessRequest
  ) async throws(ProcessRunnerError) -> LaunchCheckOutcome {
    let control = control
    let runner = checkRunner
    let early = control.takePending()
    if !early.isEmpty { return .interrupted(signals: early) }
    let check = Task { try await runner.run(request) }
    let ending = await withTaskCancellationHandler {
      control.setInterruptHandler { check.cancel() }
      let ending = await check.result
      control.setInterruptHandler(nil)
      return ending
    } onCancel: {
      control.forward(SIGTERM)
    }
    let signals = control.takePending()
    if !signals.isEmpty { return .interrupted(signals: signals) }
    switch ending {
    case .success(let result):
      return .finished(result)
    case .failure(let error as ProcessRunnerError):
      throw error
    case .failure:
      // Only a cancellation gets here, and every cancellation queued a signal first.
      return .interrupted(signals: [SIGTERM])
    }
  } // End of func runCheck(_:)

  /// Runs the attach child on a dedicated thread, calling `onSpawn` with its process id right
  /// after the spawn. Cancelling the calling task sends it SIGTERM.
  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    relaysStandardError: Bool,
    onSpawn: (@Sendable (Int32) -> Void)?
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments,
      environment: environment
    )
    let control = control
    let destination = relaysStandardError ? standardErrorDestination : nil
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<Result<LaunchChildOutcome, ProcessRunnerError>, Never>)
        in
        let thread = Thread {
          continuation.resume(
            returning: Self.supervise(
              request, control: control, relayingTo: destination, onSpawn: onSpawn))
        }
        thread.name = "cc.carpio.muxfinder.launch-child"
        thread.start()
      }
    } onCancel: {
      control.forward(SIGTERM)
    }
    return try result.get()
  } // End of func run(executable:arguments:environment:relaysStandardError:onSpawn:)

  /// Spawns the attach child and waits for it, forwarding signals. With a `destination`, the
  /// child's standard error is a pipe relayed there (`StandardErrorRelay`). `onSpawn` gets the
  /// child's process id right after the spawn (the child is unreaped until the wait ends, so
  /// the id cannot name another process meanwhile). Blocks; runs on its own thread.
  static func supervise(
    _ request: ProcessRequest,
    control: TerminalChildControl,
    relayingTo destination: Int32? = nil,
    onSpawn: (@Sendable (Int32) -> Void)? = nil
  ) -> Result<LaunchChildOutcome, ProcessRunnerError> {
    let argv: CStringArray
    let envp: CStringArray
    let path: String
    do throws(ProcessRunnerError) {
      let parameters = try ProcessSupervisor.launchParameters(for: request)
      argv = try CStringArray(parameters.argv)
      envp = try CStringArray(parameters.environment)
      path = parameters.path
    } catch {
      return .failure(error)
    }
    let queue = kqueue()
    guard queue >= 0 else { return .failure(.systemCallFailed(name: "kqueue", errno: errno)) }
    defer {
      control.detach()
      close(queue)
    }
    let wakeup = KernelQueue.register(
      queue: queue,
      ident: TerminalChildControl.wakeupIdentifier,
      filter: EVFILT_USER,
      flags: EV_CLEAR
    )
    guard wakeup == 0 else { return .failure(.systemCallFailed(name: "kevent", errno: wakeup)) }
    control.attach(queue: queue)

    var relay: StandardErrorRelay?
    var errorPipe: PipePair?
    if let destination {
      do throws(ProcessRunnerError) {
        let pipe = try PipePair.make()
        errorPipe = pipe
        relay = StandardErrorRelay(
          source: pipe.readEnd, destination: destination, limit: capturedStandardErrorLimit)
      } catch {
        return .failure(error)
      }
    }
    let startedAt = Date()
    let processID: pid_t
    do throws(ProcessRunnerError) {
      processID = try spawn(path: path, argv: argv, envp: envp, standardError: errorPipe?.writeEnd)
    } catch {
      if let errorPipe { close(errorPipe.writeEnd) }
      relay?.close()
      return .failure(error)
    }
    if let errorPipe { close(errorPipe.writeEnd) }
    onSpawn?(processID)
    let forwarded = wait(for: processID, queue: queue, control: control, relay: &relay)
    let status: Int32
    switch ProcessSupervisor.reap(processID) {
    case .success(let value): status = value
    case .failure(let error):
      relay?.close()
      return .failure(error)
    }
    var buffer = [UInt8](repeating: 0, count: 4096)
    relay?.finish(within: relayDrainTime, using: &buffer)
    return .success(
      LaunchChildOutcome(
        processID: processID,
        termination: ProcessSupervisor.termination(fromWaitStatus: status),
        startedAt: startedAt,
        endedAt: Date(),
        forwardedSignals: forwarded,
        capturedStandardError: relay?.captured ?? Data()
      )
    )
  } // End of func supervise(_:control:relayingTo:onSpawn:)

  /// Spawns the child with the terminal descriptors inherited (standard error replaced by
  /// `standardError` when given, the write end of the relay's pipe) and in this process group.
  static func spawn(
    path: String,
    argv: CStringArray,
    envp: CStringArray,
    standardError: Int32? = nil
  ) throws(ProcessRunnerError) -> pid_t {
    var actions = try SpawnFileActions()
    defer { actions.destroy() }
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
      if descriptor == STDERR_FILENO, let standardError {
        try actions.duplicate(standardError, to: STDERR_FILENO)
      } else if fcntl(descriptor, F_GETFD) != -1 {
        try actions.inherit(descriptor)
      } else {
        try actions.openNullDevice(as: descriptor)
      }
    } // End of loop over the terminal descriptors
    var attributes = try SpawnAttributes(newProcessGroup: false)
    defer { attributes.destroy() }
    var processID: pid_t = 0
    let code = argv.withUnsafePointer { argvPointer in
      envp.withUnsafePointer { envPointer in
        posix_spawn(&processID, path, &actions.raw, &attributes.raw, argvPointer, envPointer)
      }
    }
    guard code == 0 else { throw .spawnFailed(errno: code) }
    return processID
  } // End of func spawn(path:argv:envp:)

  /// Waits until the child has exited (without reaping it), passing on the signals that reach
  /// `control` and pumping `relay`, if any, whenever its pipe is readable or its destination
  /// writable again. Each round's relay work is bounded and never blocks
  /// (`StandardErrorRelay`), so signals and the exit are looked at every round however much
  /// the child writes and however slow the tab is. Returns the signals passed on.
  static func wait(
    for processID: pid_t,
    queue: Int32,
    control: TerminalChildControl,
    relay: inout StandardErrorRelay?
  ) -> [Int32] {
    var forwarded: [Int32] = []
    _ = KernelQueue.register(
      queue: queue,
      ident: UInt(processID),
      filter: EVFILT_PROC,
      fflags: UInt32(NOTE_EXIT)
    )
    var readWatched = false
    if let source = relay?.source, source >= 0 {
      readWatched = KernelQueue.watchReadable(source, queue: queue)
    }
    var events = [KernelEvent](repeating: KernelEvent(), count: 8)
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      // Only sent while the child is unreaped, so its pid cannot belong to another process.
      for signalNumber in control.takePending() {
        _ = kill(processID, signalNumber)
        forwarded.append(signalNumber)
      }
      // Closing the pipe at its end also removes its read watch from the queue.
      relay?.pump(using: &buffer)
      if let current = relay {
        readWatched = updateRelayWatches(current, queue: queue, readWatched: readWatched)
      }
      // Checked every round: a NOTE_EXIT can be lost if the child exited before the watch.
      if ProcessSupervisor.hasExited(processID) { break }
      // Wakeups (signals), output, a writable tab and the exit end the wait; the loop looks at
      // all of them.
      _ = KernelQueue.wait(queue: queue, into: &events, timeout: exitPollInterval)
    } // End of wait loop
    // A signal queued while the child was exiting has nobody left to reach.
    _ = control.takePending()
    return forwarded
  } // End of func wait(for:queue:control:relay:)

  /// Matches the queue's relay watches to `relay`: the pipe's read watch is enabled only while
  /// the relay reads (disabled while its pending bytes are full, so a level-triggered watch
  /// does not spin), and a one-shot write watch wakes the loop once a blocked destination takes
  /// bytes again. Returns whether the read watch is enabled now.
  static func updateRelayWatches(
    _ relay: StandardErrorRelay,
    queue: Int32,
    readWatched: Bool
  ) -> Bool {
    var watched = readWatched
    if relay.source >= 0, relay.wantsInput != readWatched {
      let flags = relay.wantsInput ? EV_ENABLE : EV_DISABLE
      if KernelQueue.register(
        queue: queue, ident: UInt(relay.source), filter: EVFILT_READ, flags: flags) == 0
      {
        watched = relay.wantsInput
      }
    }
    if let blocked = relay.blockedOutput {
      _ = KernelQueue.register(
        queue: queue, ident: UInt(blocked), filter: EVFILT_WRITE, flags: EV_ONESHOT)
    }
    return watched
  } // End of func updateRelayWatches(_:queue:readWatched:)
}
