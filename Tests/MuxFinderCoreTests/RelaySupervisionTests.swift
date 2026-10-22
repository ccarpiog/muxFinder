import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The standard error relay never stalls the attach child's supervision (PLAN.md D17): one pump
/// reads a bounded amount, a descendant that never stops writing does not hide the child's
/// exit, and a destination that takes nothing (a full pipe, a terminal nobody reads) blocks
/// neither the passing on of a signal nor the reaping. Each test fails on a relay that drains
/// its pipe in one go and writes to the tab with blocking writes; such a relay is unblocked at
/// the end (the writer killed, the destination drained), so a failing test still ends.
@Suite("Terminal child runner (relay supervision)")
struct RelaySupervisionTests {
  /// What a test's blocked destination is.
  enum DestinationKind: String, Sendable, CaseIterable, CustomTestStringConvertible {
    /// The write end of a pipe (blocking), written only when `poll` says it takes bytes.
    case pipe
    /// The slave side of a pseudo-terminal, which the relay opens again with `O_NONBLOCK`.
    case terminal

    /// The kind's name.
    var testDescription: String { rawValue }
  }

  /// A destination nobody reads until the test drains it: a pipe or a pseudo-terminal.
  struct BlockedDestination {
    /// The descriptor the relay writes to (the pipe's write end, the terminal's slave side).
    let writeEnd: Int32
    /// The other end (the pipe's read end, the terminal's master side).
    let readEnd: Int32

    /// Opens a destination of `kind`, every descriptor close-on-exec.
    static func make(_ kind: DestinationKind) throws -> BlockedDestination {
      var first: Int32 = -1
      var second: Int32 = -1
      switch kind {
      case .pipe:
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw POSIXError(.EIO) }
        (first, second) = (descriptors[1], descriptors[0])
      case .terminal:
        guard openpty(&second, &first, nil, nil, nil) == 0 else { throw POSIXError(.EIO) }
      }
      for descriptor in [first, second] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
      _ = fcntl(second, F_SETFL, fcntl(second, F_GETFL) | O_NONBLOCK)
      return BlockedDestination(writeEnd: first, readEnd: second)
    } // End of func make(_:)

    /// Whether the write end takes bytes now.
    var isWritable: Bool {
      var poller = pollfd(fd: writeEnd, events: Int16(POLLOUT), revents: 0)
      return poll(&poller, 1, 0) == 1 && poller.revents & Int16(POLLOUT) != 0
    }

    /// Reads (and discards) what waits at the read end now.
    func drain() {
      var buffer = [UInt8](repeating: 0, count: 65536)
      let descriptor = readEnd
      while buffer.withUnsafeMutableBytes({ read(descriptor, $0.baseAddress, $0.count) }) > 0 {}
    }

    /// Closes both ends.
    func close() {
      Darwin.close(writeEnd)
      Darwin.close(readEnd)
    }
  } // End of struct BlockedDestination

  /// Where a run's outcome lands, so a test can look for it without awaiting the run.
  final class OutcomeSlot: Sendable {
    /// The outcome, once the run ended.
    private let state = OSAllocatedUnfairLock<Result<LaunchChildOutcome, ProcessRunnerError>?>(
      initialState: nil)

    /// The outcome, or `nil` while the run goes on.
    var outcome: Result<LaunchChildOutcome, ProcessRunnerError>? { state.withLock { $0 } }

    /// Stores the outcome.
    func fill(_ outcome: Result<LaunchChildOutcome, ProcessRunnerError>) {
      state.withLock { $0 = outcome }
    }
  }

  /// Starts `script` through `/bin/sh` (with `arguments`) under a runner that relays its
  /// standard error to `destination` and takes signals from `control`. Returns the run's task
  /// and the slot its outcome lands in.
  static func start(
    _ script: String,
    arguments: [String] = [],
    destination: Int32,
    control: TerminalChildControl = .init()
  ) -> (task: Task<Void, Never>, slot: OutcomeSlot) {
    let slot = OutcomeSlot()
    let runner = TerminalChildRunner(control: control, standardErrorDestination: destination)
    let task = Task {
      do throws(ProcessRunnerError) {
        let outcome = try await runner.run(
          executable: "/bin/sh", arguments: ["-c", script, "muxfinder-test"] + arguments,
          environment: TestSupport.environment, relaysStandardError: true)
        slot.fill(.success(outcome))
      } catch {
        slot.fill(.failure(error))
      }
    }
    return (task, slot)
  } // End of func start(_:arguments:destination:control:)

  /// One pump reads at most `readBudget` bytes although four times as many wait, so the
  /// supervision loop gets control back; later pumps read the rest, and a destination that
  /// takes everything loses nothing.
  @Test func boundsEachPump() throws {
    var pair: [Int32] = [-1, -1]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
    defer { close(pair[1]) }
    var size: Int32 = 1 << 20
    for descriptor in pair {
      for option in [SO_SNDBUF, SO_RCVBUF] {
        _ = setsockopt(
          descriptor, SOL_SOCKET, option, &size, socklen_t(MemoryLayout<Int32>.size))
      }
    }
    _ = fcntl(pair[1], F_SETFL, fcntl(pair[1], F_GETFL) | O_NONBLOCK)
    let budget = StandardErrorRelay.readBudget
    let chunk = [UInt8](repeating: 0x78, count: 8192)
    var written = 0
    while written < 4 * budget {
      let count = chunk.withUnsafeBytes { write(pair[1], $0.baseAddress, $0.count) }
      guard count > 0 else { break }
      written += count
    } // End of loop filling the socket
    try #require(written == 4 * budget)
    let sink = open("/dev/null", O_WRONLY | O_CLOEXEC)
    try #require(sink >= 0)
    defer { close(sink) }
    var relay = StandardErrorRelay(source: pair[0], destination: sink, limit: 16 * 1024)
    defer { relay.close() }
    var buffer = [UInt8](repeating: 0, count: 4096)
    relay.pump(using: &buffer)
    #expect(relay.source >= 0)
    #expect(relay.readByteCount == budget)
    #expect(relay.captured.count == 16 * 1024)
    var pumps = 1
    while relay.readByteCount < written, pumps < 100 {
      relay.pump(using: &buffer)
      pumps += 1
    }
    #expect(pumps == 4)
    #expect(relay.readByteCount == written)
    #expect(relay.droppedByteCount == 0)
  } // End of func boundsEachPump()

  /// Reads a destination's other end on a thread of its own, at most 4 KiB per millisecond:
  /// a tab that keeps reading, only more slowly than a runaway writer writes.
  final class SlowReader: Sendable {
    /// Whether to stop, and whether the thread has stopped.
    private let state = OSAllocatedUnfairLock(initialState: (stop: false, stopped: false))

    /// Starts reading the non-blocking `descriptor`.
    init(_ descriptor: Int32) {
      let state = self.state
      let thread = Thread {
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !state.withLock({ $0.stop }) {
          _ = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
          usleep(1000)
        }
        state.withLock { $0.stopped = true }
      }
      thread.name = "muxfinder-test.slow-reader"
      thread.start()
    } // End of init(_:)

    /// Stops the thread and waits (briefly) until it no longer reads.
    func stop() async {
      state.withLock { $0.stop = true }
      _ = await TestSupport.eventually { self.state.withLock { $0.stopped } }
    }
  } // End of class SlowReader

  /// A background descendant that writes to the relayed pipe without pause (`yes`), to a tab
  /// that reads more slowly than that, does not hide the child's exit: the run ends within
  /// about the drain time after the child exits, and closing the pipe then ends the writer.
  @Test(.timeLimit(.minutes(1)), arguments: DestinationKind.allCases)
  func sustainedDescendantOutputDoesNotHideTheExit(_ kind: DestinationKind) async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let destination = try BlockedDestination.make(kind)
    defer { destination.close() }
    let reader = SlowReader(destination.readEnd)
    let started = ContinuousClock.now
    let run = Self.start(
      #"/usr/bin/yes muxfinder-test >&2 & printf '%s\n' "$!" > "$1/writer"; exec /bin/sleep 0.3"#,
      arguments: [directory.path(percentEncoded: false)], destination: destination.writeEnd)
    let ended = await TestSupport.eventually(within: .seconds(5)) { run.slot.outcome != nil }
    let elapsed = ContinuousClock.now - started
    let writer = TestSupport.processIDs(inFile: "writer", in: directory)
    let writerGone = await TestSupport.eventually(within: .seconds(5)) {
      writer.allSatisfy(TestSupport.processIsGone)
    }
    // A relay stuck reading the pipe gets its end of file once the writer is gone.
    if !writerGone { for processID in writer { _ = kill(processID, SIGKILL) } }
    await run.task.value
    await reader.stop()
    #expect(ended)
    #expect(elapsed < .seconds(3))
    #expect(writer.count == 1)
    #expect(writerGone)
    let outcome = try #require(run.slot.outcome).get()
    #expect(outcome.termination == .exited(0))
    #expect(outcome.capturedStandardError.count == TerminalChildRunner.capturedStandardErrorLimit)
  } // End of func sustainedDescendantOutputDoesNotHideTheExit()

  /// A destination that stops taking bytes (a full pipe, a terminal whose other side nobody
  /// reads) while the child writes 256 KiB: a signal is still passed on at once and the child
  /// reaped, within about the drain time; the capture is complete.
  @Test(.timeLimit(.minutes(1)), arguments: DestinationKind.allCases)
  func aDestinationThatTakesNothingDoesNotBlockSupervision(
    _ kind: DestinationKind
  ) async throws {
    let destination = try BlockedDestination.make(kind)
    defer { destination.close() }
    let control = TerminalChildControl()
    let run = Self.start(
      "/usr/bin/head -c 262144 /dev/zero >&2; exec /bin/sleep 30",
      destination: destination.writeEnd, control: control)
    let full = await TestSupport.eventually(within: .seconds(5)) { !destination.isWritable }
    try await Task.sleep(for: .milliseconds(200))
    let forwardedAt = ContinuousClock.now
    control.forward(SIGTERM)
    let ended = await TestSupport.eventually(within: .seconds(5)) { run.slot.outcome != nil }
    let elapsed = ContinuousClock.now - forwardedAt
    // A relay blocked in write(2) goes on once the destination is drained.
    while run.slot.outcome == nil {
      destination.drain()
      try? await Task.sleep(for: .milliseconds(10))
    }
    await run.task.value
    #expect(full)
    #expect(ended)
    #expect(elapsed < .seconds(3))
    let outcome = try #require(run.slot.outcome).get()
    #expect(outcome.termination == .signaled(SIGTERM))
    #expect(outcome.forwardedSignals == [SIGTERM])
    #expect(outcome.capturedStandardError.count == TerminalChildRunner.capturedStandardErrorLimit)
  } // End of func aDestinationThatTakesNothingDoesNotBlockSupervision(_:)
}
