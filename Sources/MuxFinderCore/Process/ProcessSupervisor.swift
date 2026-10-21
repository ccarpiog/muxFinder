import Darwin
import Foundation

/// Spawns one child process and supervises it until it has ended and been reaped.
///
/// Every method blocks. Only the dedicated thread that `PosixSpawnProcessRunner` creates per run
/// calls them. One kqueue watches the child's stdout and stderr pipes, its stdin pipe (when the
/// request supplies data), its exit (`EVFILT_PROC`) and the cancellation wakeup (`EVFILT_USER`).
///
/// The child is observed with `NOTE_EXIT` and `waitid(WNOWAIT)` but reaped only at the very end.
/// Until then it is a zombie that keeps its pid, and therefore its process group id, reserved,
/// so signalling the group can never reach an unrelated process that reused the id.
///
/// Once a timeout or cancellation has sent SIGTERM, the group keeps its whole grace period even
/// if the child dies at once: supervision goes on, still reading output, until no live member
/// is left or the escalation deadline has passed and SIGKILL has gone out.
struct ProcessSupervisor: Sendable {
  /// The process to run.
  let request: ProcessRequest
  /// Delay between SIGTERM and SIGKILL when stopping the group.
  let terminationGracePeriod: Duration
  /// How long to keep reading the pipes after the child has exited.
  let outputDrainGracePeriod: Duration
  /// Cancellation channel shared with the async caller.
  let control: ProcessRunControl

  /// Bytes per `read` and largest single `write` to the child's stdin.
  static let chunkSize = 64 * 1024
  /// Polling interval for child exit, used only if the kqueue process watch is unavailable.
  static let exitPollInterval: Duration = .milliseconds(10)
  /// Polling interval for the group emptying after a SIGTERM; no kernel event reports it.
  static let groupPollInterval: Duration = .milliseconds(10)

  /// Validated launch parameters, ready to be converted to C strings.
  struct LaunchParameters {
    /// Absolute path of the executable.
    let path: String
    /// argv, starting with the executable path.
    let argv: [String]
    /// `NAME=value` entries, sorted by name.
    let environment: [String]
  }

  /// The parent's side of a freshly spawned child.
  struct SpawnedChild {
    /// Child pid, which is also its process group id.
    let processID: pid_t
    /// Non-blocking read end of the child's stdout.
    let standardOutput: Int32
    /// Non-blocking read end of the child's stderr.
    let standardError: Int32
    /// Non-blocking write end of the child's stdin, or -1 when stdin is `/dev/null`.
    let standardInput: Int32
  }

  /// What the supervision loop observed.
  struct SupervisionReport {
    /// Collected stdout.
    var standardOutput: OutputCollector
    /// Collected stderr.
    var standardError: OutputCollector
    /// Whether the timeout fired.
    var timedOut: Bool
    /// Whether the calling task was cancelled before the run finished.
    var cancelled: Bool
    /// Whether the group was sent SIGTERM (because of a timeout or cancellation). If so, the
    /// group had settled by the time the report was made.
    var stoppedGroup: Bool
  }

  /// Mutable state of the supervision loop.
  struct LoopState {
    /// When the request's timeout fires, if it has one.
    let timeoutDeadline: ContinuousClock.Instant?
    /// Set once the child has exited (it is not reaped yet).
    var childExited = false
    /// Set once the timeout has fired.
    var timedOut = false
    /// Set once cancellation has been observed.
    var cancelled = false
    /// When SIGKILL follows the SIGTERM already sent, or `nil` if no SIGTERM was sent.
    var escalationDeadline: ContinuousClock.Instant?
    /// Set once SIGKILL has been sent.
    var killSent = false
    /// Set once, after a SIGTERM, the group was seen to have no live member left.
    var groupEmptied = false
    /// When to stop waiting for pipe end-of-file once the child exited and the group settled.
    var drainDeadline: ContinuousClock.Instant?

    /// Whether the group needs no more waiting: no SIGTERM was sent, the escalation SIGKILL has
    /// gone out, or no live member is left.
    var groupSettled: Bool { escalationDeadline == nil || killSent || groupEmptied }
  }

  /// Runs the request to completion and reports the outcome.
  func run() -> SupervisionOutcome {
    if control.isCancellationRequested { return .cancelled }
    let argv: CStringArray
    let envp: CStringArray
    let path: String
    do throws(ProcessRunnerError) {
      let parameters = try validatedLaunchParameters()
      argv = try CStringArray(parameters.argv)
      envp = try CStringArray(parameters.environment)
      path = parameters.path
    } catch {
      return .failed(error)
    }

    let queue = kqueue()
    guard queue >= 0 else { return .failed(.systemCallFailed(name: "kqueue", errno: errno)) }
    defer {
      control.detachWakeup()
      close(queue)
    }
    let wakeup = KernelQueue.register(
      queue: queue,
      ident: ProcessRunControl.wakeupIdentifier,
      filter: EVFILT_USER,
      flags: EV_CLEAR
    )
    guard wakeup == 0 else { return .failed(.systemCallFailed(name: "kevent", errno: wakeup)) }
    if control.attachWakeup(queue: queue) { return .cancelled }

    let clock = ContinuousClock()
    let start = clock.now
    let child: SpawnedChild
    do throws(ProcessRunnerError) {
      child = try spawn(path: path, argv: argv, envp: envp)
    } catch {
      return .failed(error)
    }
    let report = supervise(child, queue: queue, start: start, clock: clock)
    if report.stoppedGroup {
      // `supervise` returns only once the group has no live member or the escalation SIGKILL
      // has gone out, so this cannot cut a cleanup short; it catches a member forked while that
      // SIGKILL was being delivered. Safe: the unreaped child still pins the pgid.
      Self.signalGroup(ledBy: child.processID, with: SIGKILL)
    }
    let status: Int32
    switch Self.reap(child.processID) {
    case .success(let value): status = value
    case .failure(let error): return .failed(error)
    }
    if report.cancelled { return .cancelled }
    return .finished(
      ProcessResult(
        processID: child.processID,
        termination: Self.termination(fromWaitStatus: status),
        standardOutput: report.standardOutput.data,
        standardError: report.standardError.data,
        standardOutputTruncated: report.standardOutput.truncated,
        standardErrorTruncated: report.standardError.truncated,
        duration: start.duration(to: clock.now),
        timedOut: report.timedOut
      )
    )
  } // End of func run()

  /// Checks the request for values `posix_spawn` cannot represent and flattens it to strings.
  func validatedLaunchParameters() throws(ProcessRunnerError) -> LaunchParameters {
    let url = request.executableURL
    let path = url.path(percentEncoded: false)
    guard url.isFileURL, path.hasPrefix("/"), !path.utf8.contains(0) else {
      throw .executableNotAbsolute
    }
    for (index, argument) in request.arguments.enumerated() where argument.utf8.contains(0) {
      throw .argumentContainsNUL(index: index)
    }
    var environment: [String] = []
    for (name, value) in request.environment.sorted(by: { $0.key < $1.key }) {
      let validName = !name.isEmpty && !name.contains("=") && !name.utf8.contains(0)
      guard validName, !value.utf8.contains(0) else {
        throw .invalidEnvironmentVariable(name: name)
      }
      environment.append("\(name)=\(value)")
    }
    return LaunchParameters(path: path, argv: [path] + request.arguments, environment: environment)
  } // End of func validatedLaunchParameters()

  /// Creates the pipes and spawns the child in a new process group.
  ///
  /// The child gets stdin (`/dev/null` or a pipe), stdout and stderr through `dup2` file
  /// actions. `POSIX_SPAWN_CLOEXEC_DEFAULT` closes every other descriptor in the child, and the
  /// explicit close actions make the intent visible. The parent closes the child's pipe ends as
  /// soon as the spawn returns, so end-of-file arrives when the child's side is gone.
  func spawn(path: String, argv: CStringArray, envp: CStringArray) throws(ProcessRunnerError)
    -> SpawnedChild
  {
    var parentEnds: [Int32] = []
    var childEnds: [Int32] = []
    var spawned = false
    defer {
      for descriptor in childEnds { close(descriptor) }
      if !spawned {
        for descriptor in parentEnds { close(descriptor) }
      }
    }
    let output = try PipePair.make()
    parentEnds.append(output.readEnd)
    childEnds.append(output.writeEnd)
    let errors = try PipePair.make()
    parentEnds.append(errors.readEnd)
    childEnds.append(errors.writeEnd)
    var input: PipePair?
    if case .data = request.standardInput {
      let pipe = try PipePair.make()
      parentEnds.append(pipe.writeEnd)
      childEnds.append(pipe.readEnd)
      input = pipe
    }

    var actions = try SpawnFileActions()
    defer { actions.destroy() }
    if let input {
      try actions.duplicate(input.readEnd, to: STDIN_FILENO)
    } else {
      try actions.openNullDevice(as: STDIN_FILENO)
    }
    try actions.duplicate(output.writeEnd, to: STDOUT_FILENO)
    try actions.duplicate(errors.writeEnd, to: STDERR_FILENO)
    for descriptor in parentEnds + childEnds where descriptor > STDERR_FILENO {
      try actions.close(descriptor)
    }
    var attributes = try SpawnAttributes()
    defer { attributes.destroy() }

    var processID: pid_t = 0
    let code = argv.withUnsafePointer { argvPointer in
      envp.withUnsafePointer { envPointer in
        posix_spawn(&processID, path, &actions.raw, &attributes.raw, argvPointer, envPointer)
      }
    }
    guard code == 0 else { throw .spawnFailed(errno: code) }
    spawned = true
    for descriptor in parentEnds {
      _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
    }
    if let input {
      // Writing after the child closed stdin must yield EPIPE, not kill this process.
      _ = fcntl(input.writeEnd, F_SETNOSIGPIPE, 1)
    }
    return SpawnedChild(
      processID: processID,
      standardOutput: output.readEnd,
      standardError: errors.readEnd,
      standardInput: input?.writeEnd ?? -1
    )
  } // End of func spawn(path:argv:envp:)

  /// Pumps output and input until the child has exited, the group has settled (see
  /// `LoopState.groupSettled`) and the pipes are drained (or the drain grace period ends),
  /// applying the timeout and cancellation along the way. A cancelled run skips the drain.
  func supervise(
    _ child: SpawnedChild,
    queue: Int32,
    start: ContinuousClock.Instant,
    clock: ContinuousClock
  ) -> SupervisionReport {
    let processID = child.processID
    var output = OutputCollector(descriptor: child.standardOutput, limit: request.outputLimit)
    var errors = OutputCollector(descriptor: child.standardError, limit: request.outputLimit)
    var input = InputFeeder(descriptor: child.standardInput, data: requestInputData)
    var state = LoopState(timeoutDeadline: request.timeout.map { start + $0 })

    // Registration failures are never expected; closing the stream keeps the loop from waiting
    // on a descriptor it cannot watch.
    if !KernelQueue.watchReadable(output.descriptor, queue: queue) { output.close() }
    if !KernelQueue.watchReadable(errors.descriptor, queue: queue) { errors.close() }
    input.feed()
    if input.isOpen,
      KernelQueue.register(queue: queue, ident: UInt(input.descriptor), filter: EVFILT_WRITE) != 0
    {
      input.close()
    }
    let exitWatch = KernelQueue.register(
      queue: queue,
      ident: UInt(processID),
      filter: EVFILT_PROC,
      fflags: UInt32(NOTE_EXIT)
    )
    var pollForExit = exitWatch != 0
    // The child may have exited before the watch was registered; a NOTE_EXIT would be lost.
    if Self.hasExited(processID) { state.childExited = true }

    var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
    var events = [KernelEvent](repeating: KernelEvent(), count: 8)
    while true {
      let now = clock.now
      if !state.cancelled, control.isCancellationRequested {
        state.cancelled = true
        beginTermination(of: processID, state: &state, now: now)
      }
      if !state.childExited, state.escalationDeadline == nil, let deadline = state.timeoutDeadline,
        now >= deadline
      {
        state.timedOut = true
        beginTermination(of: processID, state: &state, now: now)
      }
      if let deadline = state.escalationDeadline, !state.killSent, now >= deadline {
        Self.signalGroup(ledBy: processID, with: SIGKILL)
        state.killSent = true
      }
      if state.childExited {
        input.close()
        // Survivors of a SIGTERM keep the full grace period for their cleanup, however soon
        // the child died or its pipes closed. Their output keeps being read meanwhile.
        if !state.groupSettled, Self.groupHasNoLiveMember(processID) { state.groupEmptied = true }
        if state.groupSettled {
          // A cancelled run's output is discarded, so there is nothing to drain for.
          if state.cancelled || (!output.isOpen && !errors.isOpen) { break }
          let drainDeadline = state.drainDeadline ?? now + outputDrainGracePeriod
          state.drainDeadline = drainDeadline
          if now >= drainDeadline { break }
        }
      } // End of handling for an exited child

      let wait = Self.timeUntilNextDeadline(state: state, pollForExit: pollForExit, now: now)
      let count = KernelQueue.wait(queue: queue, into: &events, timeout: wait)
      if count < 0 {
        if errno != EINTR {
          // Never expected. Fall back to polling so the loop still notices the exit.
          pollForExit = true
          usleep(10_000)
        }
        continue
      }
      for event in events.prefix(Int(count)) where event.flags & UInt16(EV_ERROR) == 0 {
        switch Int32(event.filter) {
        case EVFILT_READ:
          let descriptor = Int32(truncatingIfNeeded: event.ident)
          if descriptor == output.descriptor {
            output.drain(using: &buffer)
          } else if descriptor == errors.descriptor {
            errors.drain(using: &buffer)
          }
        case EVFILT_WRITE:
          input.feed()
        case EVFILT_PROC:
          if event.fflags & UInt32(NOTE_EXIT) != 0 { state.childExited = true }
        default:
          break // EVFILT_USER wakeup: cancellation is checked at the top of the loop.
        }
      } // End of loop over kqueue events
      if pollForExit, !state.childExited, Self.hasExited(processID) { state.childExited = true }
    } // End of supervision loop

    output.close()
    errors.close()
    input.close()
    return SupervisionReport(
      standardOutput: output,
      standardError: errors,
      timedOut: state.timedOut,
      cancelled: state.cancelled,
      stoppedGroup: state.escalationDeadline != nil
    )
  } // End of func supervise(_:queue:start:clock:)

  /// The bytes to feed to the child's stdin, empty for `/dev/null`.
  var requestInputData: Data {
    if case .data(let data) = request.standardInput { return data }
    return Data()
  }

  /// Sends SIGTERM to the group once and schedules the SIGKILL escalation.
  func beginTermination(of processID: pid_t, state: inout LoopState, now: ContinuousClock.Instant) {
    guard state.escalationDeadline == nil else { return }
    state.escalationDeadline = now + terminationGracePeriod
    Self.signalGroup(ledBy: processID, with: SIGTERM)
  }

  /// How long the loop may block before a deadline needs attention; `nil` means indefinitely.
  static func timeUntilNextDeadline(
    state: LoopState,
    pollForExit: Bool,
    now: ContinuousClock.Instant
  ) -> Duration? {
    var deadlines: [ContinuousClock.Instant] = []
    if !state.childExited, state.escalationDeadline == nil, let deadline = state.timeoutDeadline {
      deadlines.append(deadline)
    }
    if let deadline = state.escalationDeadline, !state.killSent { deadlines.append(deadline) }
    // The drain deadline only ends the loop once the group has settled. Before that, a drain
    // deadline already in the past would make every wait zero, a busy loop.
    if state.groupSettled, let deadline = state.drainDeadline { deadlines.append(deadline) }
    if pollForExit, !state.childExited { deadlines.append(now + exitPollInterval) }
    if state.childExited, !state.groupSettled { deadlines.append(now + groupPollInterval) }
    guard let earliest = deadlines.min() else { return nil }
    return max(.zero, now.duration(to: earliest))
  } // End of func timeUntilNextDeadline(state:pollForExit:now:)

  /// Signals the child's process group and the child itself (in case it changed groups).
  ///
  /// Only called while the child is unreaped, so its pid and pgid cannot have been reused.
  static func signalGroup(ledBy processID: pid_t, with signal: Int32) {
    _ = kill(-processID, signal)
    _ = kill(processID, signal)
  }

  /// Whether the child's process group has no live member left that a signal could reach.
  ///
  /// Only called while the child is an unreaped zombie. The zombie keeps its pid reserved, and
  /// no other process can create a group with that id, so the group probed is still ours.
  /// `kill(-pgid, 0)` skips zombies. Measured on macOS 27.2: with only the zombie leader left it
  /// fails with EPERM (the group still exists, nothing in it can be signalled); once the group
  /// is gone it fails with ESRCH. EPERM would also cover live members this process may not
  /// signal, but those are beyond the reach of a SIGKILL anyway, so waiting longer is pointless.
  static func groupHasNoLiveMember(_ processID: pid_t) -> Bool {
    guard kill(-processID, 0) == -1 else { return false }
    let code = errno
    return code == ESRCH || code == EPERM
  }

  /// Whether the child has exited, without reaping it (`WNOWAIT`).
  static func hasExited(_ processID: pid_t) -> Bool {
    var info = siginfo_t()
    while true {
      if waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
        return info.si_pid != 0
      }
      // ECHILD means there is nothing left to wait for; report an exit so the loop cannot hang.
      if errno != EINTR { return true }
    }
  }

  /// Reaps the child and returns its raw wait status.
  static func reap(_ processID: pid_t) -> Result<Int32, ProcessRunnerError> {
    var status: Int32 = 0
    while true {
      if waitpid(processID, &status, 0) == processID { return .success(status) }
      let code = errno
      if code != EINTR { return .failure(.systemCallFailed(name: "waitpid", errno: code)) }
    }
  }

  /// Decodes a `waitpid` status (the `WIFEXITED` / `WTERMSIG` macros are not available in
  /// Swift).
  static func termination(fromWaitStatus status: Int32) -> ProcessResult.Termination {
    let signal = status & 0x7f
    if signal == 0 { return .exited((status >> 8) & 0xff) }
    return .signaled(signal)
  }
}
