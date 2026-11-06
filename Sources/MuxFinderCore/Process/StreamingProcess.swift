import Darwin
import Foundation
import os

/// A long-lived child process whose standard input stays open for the caller to write to, and
/// whose standard output is handed over as it arrives (PLAN.md D36; the runner,
/// `PosixSpawnProcessRunner`, only runs a child to completion).
///
/// It is spawned like the runner's children (`ProcessSupervisor.spawn(path:argv:envp:)`): argv
/// and the environment exactly as requested, no shell, a process group of its own, an empty
/// signal mask, default dispositions and only descriptors 0–2 open. One serial queue watches
/// standard output and standard error (dispatch read sources) and the child's exit (a process
/// source). Standard output goes to `onOutput` on that queue, chunk by chunk; returning `false`
/// stops reading it. Standard error keeps its first `errorLimit` bytes and discards the rest.
///
/// The child is reaped only after it has exited and its group has been sent SIGKILL for any
/// member left (the unreaped leader pins the group id, so the signal cannot reach another
/// process), once both pipes reached end of file or `drainGracePeriod` has passed; then `onEnd`
/// runs, once, with how it ended and its standard error. `terminate(gracePeriod:killAfter:)`
/// ends it on every way out: it closes standard input, waits, then signals the group (SIGTERM,
/// then SIGKILL) and returns once the child is reaped. Signals go out only while the child is
/// unreaped.
final class StreamingProcess: Sendable {
  /// What the queue's handlers and the caller share.
  private struct State {
    /// The write end of the child's standard input, or -1 once closed.
    var standardInput: Int32
    /// Whether standard output is still read.
    var outputOpen = true
    /// Whether standard error is still read.
    var errorOpen = true
    /// The first bytes of standard error.
    var errorPrefix = Data()
    /// Whether the child has exited (it may not be reaped yet).
    var exited = false
    /// Whether the drain grace period after the exit has passed.
    var drainOver = false
    /// How the child ended, once reaped.
    var termination: ProcessResult.Termination?
    /// Whether the child was reaped; no signal goes out after that.
    var reaped = false
  }

  /// The dispatch sources, kept until the child is reaped. Touched only before they are
  /// resumed and then on the queue, so the unchecked conformance holds.
  private final class Sources: @unchecked Sendable {
    /// The sources.
    var list: [any DispatchSourceProtocol] = []
  }

  /// How long to wait for the pipes after the child exited before reaping it anyway (a process
  /// that left the group may hold them open).
  static let drainGracePeriod: Duration = .milliseconds(500)
  /// Bytes per read.
  static let chunkSize = 64 * 1024
  /// The most reads per readable event, so one stream cannot starve the other.
  static let maximumReadsPerEvent = 16

  /// The child's process id, also its process group id.
  let processID: pid_t
  /// The shared state.
  private let state: OSAllocatedUnfairLock<State>
  /// The queue every handler runs on.
  private let queue: DispatchQueue
  /// The dispatch sources.
  private let sources = Sources()
  /// How many standard error bytes are kept.
  private let errorLimit: Int
  /// Receives standard output; `false` stops reading it.
  private let onOutput: @Sendable (Data) -> Bool
  /// Runs once, after the child was reaped.
  private let onEnd: @Sendable (ProcessResult.Termination?, Data) -> Void

  /// Wraps a spawned child.
  private init(
    processID: pid_t, standardInput: Int32, errorLimit: Int,
    onOutput: @escaping @Sendable (Data) -> Bool,
    onEnd: @escaping @Sendable (ProcessResult.Termination?, Data) -> Void
  ) {
    self.processID = processID
    self.errorLimit = errorLimit
    self.onOutput = onOutput
    self.onEnd = onEnd
    state = OSAllocatedUnfairLock(initialState: State(standardInput: standardInput))
    queue = DispatchQueue(label: "cc.carpio.muxfinder.streaming-process")
  } // End of init(processID:standardInput:errorLimit:onOutput:onEnd:)

  /// Starts `request` (its standard input, timeout and output limits are ignored) and begins
  /// watching it. Throws `ProcessRunnerError` when it cannot be started.
  static func start(
    _ request: ProcessRequest,
    errorLimit: Int,
    onOutput: @escaping @Sendable (Data) -> Bool,
    onEnd: @escaping @Sendable (ProcessResult.Termination?, Data) -> Void
  ) throws(ProcessRunnerError) -> StreamingProcess {
    var spawnRequest = request
    spawnRequest.standardInput = .data(Data())
    let parameters = try ProcessSupervisor.launchParameters(for: spawnRequest)
    let argv = try CStringArray(parameters.argv)
    let envp = try CStringArray(parameters.environment)
    let supervisor = ProcessSupervisor(
      request: spawnRequest, terminationGracePeriod: .zero, outputDrainGracePeriod: .zero,
      control: ProcessRunControl())
    let child = try supervisor.spawn(path: parameters.path, argv: argv, envp: envp)
    let process = StreamingProcess(
      processID: child.processID, standardInput: child.standardInput, errorLimit: errorLimit,
      onOutput: onOutput, onEnd: onEnd)
    process.watch(output: child.standardOutput, errors: child.standardError)
    return process
  } // End of static func start(_:errorLimit:onOutput:onEnd:)

  // MARK: - Writing

  /// Writes all of `data` to the child's standard input without blocking. Returns `false` when
  /// it is closed, the child closed its end, or the pipe is full (never expected for the small
  /// lines this carries).
  func write(_ data: Data) -> Bool {
    state.withLock { state -> Bool in
      let descriptor = state.standardInput
      guard descriptor >= 0 else { return false }
      var offset = 0
      while offset < data.count {
        let written = data.withUnsafeBytes { bytes -> Int in
          guard let base = bytes.baseAddress else { return 0 }
          return Darwin.write(descriptor, base + offset, data.count - offset)
        }
        if written > 0 {
          offset += written
        } else if written < 0, errno == EINTR {
          continue
        } else {
          return false
        }
      } // End of loop over writes
      return true
    }
  } // End of func write(_:)

  /// Closes the child's standard input, once; it then reads end of file.
  func closeInput() {
    let descriptor = state.withLock { state -> Int32 in
      defer { state.standardInput = -1 }
      return state.standardInput
    }
    if descriptor >= 0 { _ = Darwin.close(descriptor) }
  }

  // MARK: - Ending

  /// Whether the child has been reaped.
  var isReaped: Bool { state.withLock { $0.reaped } }

  /// How the child ended, once reaped.
  var termination: ProcessResult.Termination? { state.withLock { $0.termination } }

  /// Ends the child: closes standard input, waits up to `gracePeriod` for it to end, then sends
  /// its group SIGTERM, waits up to `killAfter`, then SIGKILL, and returns once it is reaped.
  func terminate(gracePeriod: Duration, killAfter: Duration) async {
    closeInput()
    if await waitUntilReaped(within: gracePeriod) { return }
    signalGroup(SIGTERM)
    if await waitUntilReaped(within: killAfter) { return }
    signalGroup(SIGKILL)
    while !(await waitUntilReaped(within: .seconds(5))) {
      signalGroup(SIGKILL)
    } // End of loop waiting for the killed child
  } // End of func terminate(gracePeriod:killAfter:)

  /// Polls every 10 ms, up to `time`, until the child is reaped. A child seen to have exited
  /// without its exit event is handled here too. Returns whether it was reaped.
  func waitUntilReaped(within time: Duration) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + time
    while !isReaped {
      if Self.hasExited(processID) {
        queue.async { self.childExited() }
      }
      guard clock.now < deadline else { return isReaped }
      try? await Task.sleep(for: .milliseconds(10))
    } // End of loop polling for the reap
    return true
  } // End of func waitUntilReaped(within:)

  /// Sends `signal` to the child's group and to the child, only while it is unreaped.
  func signalGroup(_ signal: Int32) {
    state.withLock { state in
      guard !state.reaped else { return }
      _ = kill(-processID, signal)
      _ = kill(processID, signal)
    }
  }

  // MARK: - Watching

  /// Creates and starts the read sources for `output` and `errors` and the exit source.
  private func watch(output: Int32, errors: Int32) {
    let outputSource = DispatchSource.makeReadSource(fileDescriptor: output, queue: queue)
    outputSource.setEventHandler { [self] in readOutput(output, source: outputSource) }
    outputSource.setCancelHandler { _ = Darwin.close(output) }
    let errorSource = DispatchSource.makeReadSource(fileDescriptor: errors, queue: queue)
    errorSource.setEventHandler { [self] in readErrors(errors, source: errorSource) }
    errorSource.setCancelHandler { _ = Darwin.close(errors) }
    let exitSource = DispatchSource.makeProcessSource(
      identifier: processID, eventMask: .exit, queue: queue)
    exitSource.setEventHandler { [self] in childExited() }
    sources.list = [outputSource, errorSource, exitSource]
    outputSource.resume()
    errorSource.resume()
    exitSource.resume()
    // An exit before the process source was registered has no event.
    queue.async { [self] in
      if Self.hasExited(processID) { childExited() }
    }
  } // End of func watch(output:errors:)

  /// Reads what standard output holds now and hands it to `onOutput`; stops at end of file,
  /// on an error, or when `onOutput` returns `false`.
  private func readOutput(_ descriptor: Int32, source: any DispatchSourceRead) {
    var buffer = [UInt8](repeating: 0, count: Self.chunkSize)
    for _ in 0..<Self.maximumReadsPerEvent {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        if onOutput(Data(buffer[..<count])) { continue }
      } else if count < 0, errno == EINTR {
        continue
      } else if count < 0, errno == EAGAIN {
        return
      }
      source.cancel()
      state.withLock { $0.outputOpen = false }
      settle()
      return
    } // End of loop over reads
  } // End of func readOutput(_:source:)

  /// Reads what standard error holds now, keeping at most `errorLimit` bytes in all.
  private func readErrors(_ descriptor: Int32, source: any DispatchSourceRead) {
    var buffer = [UInt8](repeating: 0, count: 4096)
    for _ in 0..<Self.maximumReadsPerEvent {
      let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        let chunk = Data(buffer[..<count])
        let limit = errorLimit
        state.withLock { state in
          let room = limit - state.errorPrefix.count
          if room > 0 { state.errorPrefix.append(chunk.prefix(room)) }
        }
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN { return }
      source.cancel()
      state.withLock { $0.errorOpen = false }
      settle()
      return
    } // End of loop over reads
  } // End of func readErrors(_:source:)

  /// Records the child's exit, kills what is left of its group and starts the drain grace
  /// period. Runs on the queue; only the first call counts.
  private func childExited() {
    let first = state.withLock { state -> Bool in
      guard !state.exited else { return false }
      state.exited = true
      if kill(-processID, 0) == 0 { _ = kill(-processID, SIGKILL) }
      return true
    }
    guard first else { return }
    queue.asyncAfter(deadline: .now() + .milliseconds(Self.milliseconds(Self.drainGracePeriod))) {
      [self] in
      state.withLock { $0.drainOver = true }
      settle()
    }
    settle()
  } // End of func childExited()

  /// Reaps the child once it has exited and its pipes are done (or the drain is over), then
  /// runs `onEnd`. Runs on the queue.
  private func settle() {
    let ready = state.withLock { state -> Bool in
      guard state.exited, !state.reaped else { return false }
      guard state.drainOver || (!state.outputOpen && !state.errorOpen) else { return false }
      state.reaped = true
      return true
    }
    guard ready else { return }
    let termination = Self.reap(processID)
    closeInput()
    let errors = state.withLock { state -> Data in
      state.termination = termination
      return state.errorPrefix
    }
    for source in sources.list where !source.isCancelled { source.cancel() }
    sources.list = []
    onEnd(termination, errors)
  } // End of func settle()

  /// Reaps `processID` and returns how it ended, or `nil` when `waitpid` failed.
  static func reap(_ processID: pid_t) -> ProcessResult.Termination? {
    var status: Int32 = 0
    while true {
      if waitpid(processID, &status, 0) == processID {
        return ProcessSupervisor.termination(fromWaitStatus: status)
      }
      if errno != EINTR { return nil }
    } // End of loop reaping the child
  }

  /// Whether `processID` has exited, without reaping it (`WNOWAIT`).
  static func hasExited(_ processID: pid_t) -> Bool {
    var info = siginfo_t()
    while true {
      if waitid(P_PID, id_t(processID), &info, WEXITED | WNOHANG | WNOWAIT) == 0 {
        return info.si_pid != 0
      }
      if errno != EINTR { return true }
    }
  } // End of static func hasExited(_:)

  /// `duration` in whole milliseconds.
  static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }
}
