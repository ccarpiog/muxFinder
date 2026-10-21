import Darwin
import Foundation
import os

/// The production `ProcessRunner`, built on `posix_spawn`.
///
/// - The child gets argv and the environment exactly as requested; no shell is involved.
/// - The child leads a new process group (`POSIX_SPAWN_SETPGROUP`), so a timeout or Task
///   cancellation can signal it together with every descendant that stayed in the group:
///   SIGTERM first, SIGKILL after `terminationGracePeriod`. Members that handle SIGTERM keep
///   the whole grace period for their cleanup even if the child dies at once; the run returns
///   as soon as no live member is left. A child that exits on its own is not followed by any
///   signal.
/// - stdout and stderr are drained concurrently through one kqueue, so a chatty stream never
///   blocks the child, and each is capped at `ProcessRequest.outputLimit`.
/// - After the child exits, the runner waits at most `outputDrainGracePeriod` for the pipes to
///   reach end-of-file, so a background grandchild that inherited them cannot stall it.
/// - All blocking work (spawn, kqueue wait, `waitpid`) happens on a dedicated thread per run,
///   never on the caller's executor or the main thread.
///
/// Processes that leave the group on purpose (`setsid`, `setpgid`) are outside its reach.
public struct PosixSpawnProcessRunner: ProcessRunner {
  /// Delay between SIGTERM and SIGKILL when a timeout or cancellation stops the group.
  public var terminationGracePeriod: Duration
  /// How long to keep reading output after the child exits while its pipes are still open.
  public var outputDrainGracePeriod: Duration

  /// Creates a runner. The defaults match PLAN.md; tests shorten them to stay fast.
  public init(
    terminationGracePeriod: Duration = .seconds(2),
    outputDrainGracePeriod: Duration = .milliseconds(500)
  ) {
    self.terminationGracePeriod = terminationGracePeriod
    self.outputDrainGracePeriod = outputDrainGracePeriod
  }

  /// Runs `request` on a dedicated supervising thread. See `ProcessRunner.run(_:)`.
  public func run(_ request: ProcessRequest) async throws -> ProcessResult {
    try Task.checkCancellation()
    let control = ProcessRunControl()
    let supervisor = ProcessSupervisor(
      request: request,
      terminationGracePeriod: terminationGracePeriod,
      outputDrainGracePeriod: outputDrainGracePeriod,
      control: control
    )
    let outcome = await withTaskCancellationHandler {
      await withCheckedContinuation {
        (continuation: CheckedContinuation<SupervisionOutcome, Never>) in
        let thread = Thread {
          continuation.resume(returning: supervisor.run())
        }
        thread.name = "cc.carpio.muxfinder.process"
        thread.start()
      }
    } onCancel: {
      control.requestCancellation()
    }
    switch outcome {
    case .finished(let result):
      return result
    case .cancelled:
      throw CancellationError()
    case .failed(let error):
      throw error
    }
  } // End of func run(_:)
}

/// What a supervising thread reports back to the async caller.
enum SupervisionOutcome: Sendable {
  /// The child ran to completion or was stopped by its timeout.
  case finished(ProcessResult)
  /// The calling task was cancelled; the process group has been killed and the child reaped.
  case cancelled
  /// The process could not be started.
  case failed(ProcessRunnerError)
}

/// Cancellation channel between an async caller and the thread supervising its process.
///
/// The supervising thread blocks in `kevent`. Cancellation sets a flag and, if the thread has
/// registered its kqueue, triggers a user event on it so the wait returns at once. The kqueue
/// descriptor is published and withdrawn under the same lock that the trigger runs under, so a
/// late cancellation can never touch a closed (or reused) descriptor.
final class ProcessRunControl: Sendable {
  /// Lock-protected state shared by the caller and the supervising thread.
  private struct State: Sendable {
    /// Set once the calling task has been cancelled.
    var cancellationRequested = false
    /// The supervising thread's kqueue, or -1 while none is registered.
    var wakeupQueue: Int32 = -1
  }

  /// Identifier of the `EVFILT_USER` event used for wakeups.
  static let wakeupIdentifier: UInt = 1

  /// The shared state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a control with no cancellation requested.
  init() {}

  /// Whether the calling task has been cancelled.
  var isCancellationRequested: Bool {
    state.withLock { $0.cancellationRequested }
  }

  /// Records a cancellation and wakes the supervising thread if it is waiting.
  func requestCancellation() {
    state.withLock { state in
      state.cancellationRequested = true
      if state.wakeupQueue >= 0 {
        Self.triggerWakeup(on: state.wakeupQueue)
      }
    }
  }

  /// Publishes the supervising thread's kqueue. Returns whether cancellation was already
  /// requested, so the caller can stop before spawning.
  func attachWakeup(queue: Int32) -> Bool {
    state.withLock { state in
      state.wakeupQueue = queue
      return state.cancellationRequested
    }
  }

  /// Withdraws the kqueue. Must be called before the supervising thread closes it.
  func detachWakeup() {
    state.withLock { $0.wakeupQueue = -1 }
  }

  /// Triggers the wakeup user event on `queue`.
  private static func triggerWakeup(on queue: Int32) {
    var change = kevent(
      ident: wakeupIdentifier,
      filter: Int16(EVFILT_USER),
      flags: 0,
      fflags: UInt32(NOTE_TRIGGER),
      data: 0,
      udata: nil
    )
    _ = kevent(queue, &change, 1, nil, 0, nil)
  } // End of func triggerWakeup(on:)
}
