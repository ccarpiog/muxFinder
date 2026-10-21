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

  /// Creates an outcome.
  public init(
    processID: Int32,
    termination: ProcessResult.Termination,
    startedAt: Date,
    endedAt: Date,
    forwardedSignals: [Int32] = []
  ) {
    self.processID = processID
    self.termination = termination
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.forwardedSignals = forwardedSignals
  }

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
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome
}

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
/// - The child inherits descriptors 0, 1 and 2 as they are (the iTerm2 tab's PTY), never
///   pipes, so `tmux -CC` talks to iTerm2 directly. A closed descriptor among them becomes
///   `/dev/null`. `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every other descriptor in the child.
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

  /// The signal channel shared by both stages.
  public var control: TerminalChildControl
  /// Runs the check child.
  public var checkRunner: any ProcessRunner

  /// Creates a runner. Tests pass a runner with short grace periods.
  public init(
    control: TerminalChildControl = .init(),
    checkRunner: any ProcessRunner = PosixSpawnProcessRunner()
  ) {
    self.control = control
    self.checkRunner = checkRunner
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

  /// Runs the attach child on a dedicated thread. Cancelling the calling task sends it SIGTERM.
  public func run(
    executable: String,
    arguments: [String],
    environment: [String: String]
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: executable),
      arguments: arguments,
      environment: environment
    )
    let control = control
    let result = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<Result<LaunchChildOutcome, ProcessRunnerError>, Never>)
        in
        let thread = Thread {
          continuation.resume(returning: Self.supervise(request, control: control))
        }
        thread.name = "cc.carpio.muxfinder.launch-child"
        thread.start()
      }
    } onCancel: {
      control.forward(SIGTERM)
    }
    return try result.get()
  } // End of func run(executable:arguments:environment:)

  /// Spawns the attach child and waits for it, forwarding signals. Blocks; runs on its own
  /// thread.
  static func supervise(
    _ request: ProcessRequest,
    control: TerminalChildControl
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

    let startedAt = Date()
    let processID: pid_t
    do throws(ProcessRunnerError) {
      processID = try spawn(path: path, argv: argv, envp: envp)
    } catch {
      return .failure(error)
    }
    let forwarded = wait(for: processID, queue: queue, control: control)
    let status: Int32
    switch ProcessSupervisor.reap(processID) {
    case .success(let value): status = value
    case .failure(let error): return .failure(error)
    }
    return .success(
      LaunchChildOutcome(
        processID: processID,
        termination: ProcessSupervisor.termination(fromWaitStatus: status),
        startedAt: startedAt,
        endedAt: Date(),
        forwardedSignals: forwarded
      )
    )
  } // End of func supervise(_:control:)

  /// Spawns the child with the terminal descriptors inherited and in this process group.
  static func spawn(
    path: String,
    argv: CStringArray,
    envp: CStringArray
  ) throws(ProcessRunnerError) -> pid_t {
    var actions = try SpawnFileActions()
    defer { actions.destroy() }
    for descriptor in [STDIN_FILENO, STDOUT_FILENO, STDERR_FILENO] {
      if fcntl(descriptor, F_GETFD) != -1 {
        try actions.inherit(descriptor)
      } else {
        try actions.openNullDevice(as: descriptor)
      }
    }
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
  /// `control`. Returns the signals passed on.
  static func wait(for processID: pid_t, queue: Int32, control: TerminalChildControl) -> [Int32] {
    var forwarded: [Int32] = []
    _ = KernelQueue.register(
      queue: queue,
      ident: UInt(processID),
      filter: EVFILT_PROC,
      fflags: UInt32(NOTE_EXIT)
    )
    var events = [KernelEvent](repeating: KernelEvent(), count: 8)
    while true {
      // Only sent while the child is unreaped, so its pid cannot belong to another process.
      for signalNumber in control.takePending() {
        _ = kill(processID, signalNumber)
        forwarded.append(signalNumber)
      }
      // Checked every round: a NOTE_EXIT can be lost if the child exited before the watch.
      if ProcessSupervisor.hasExited(processID) { break }
      // Wakeups (signals) and the exit both end the wait; the loop looks at both anyway.
      _ = KernelQueue.wait(queue: queue, into: &events, timeout: exitPollInterval)
    } // End of wait loop
    // A signal queued while the child was exiting has nobody left to reach.
    _ = control.takePending()
    return forwarded
  } // End of func wait(for:queue:control:)
}
