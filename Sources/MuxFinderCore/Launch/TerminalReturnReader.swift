import Darwin
import Foundation
import os

/// The reader behind `StandardLaunchTerminal.waitForReturn()`: it reads a terminal until a
/// line end, end of file or an error, or until `stop()` (a SIGINT or SIGTERM finishing the
/// wait), and it never blocks in a read, so `stop()` always ends it at once.
///
/// It must be stopped and have returned before anything else reads the terminal: the launch
/// tab's last restore (`TerminalStatusRequest`) reads the terminal's answer right after the
/// wait, and a reader still running could take it (PLAN.md D29). `run()` therefore reads only
/// after `poll`, through a non-blocking descriptor of its own for the terminal when one can be
/// opened (`NonBlockingTerminal.reopen`), and `poll` also watches a wake pipe that `stop()`
/// writes to.
final class TerminalReturnReader: Sendable {
  /// How `run()` ended.
  enum End: Equatable, Sendable {
    /// A line end arrived: Return (`\r` in raw mode, `\n` in canonical mode).
    case lineEnd
    /// End of file, or the terminal hung up.
    case endOfInput
    /// `stop()` was called.
    case stopped
    /// `poll` or a read failed with an error other than `EINTR` or `EAGAIN`.
    case failed
  }

  /// How often `run()` looks at the stop flag when no wake pipe could be made.
  static let stopCheckInterval: Int32 = 100

  /// The terminal read.
  let input: Int32
  /// The wake pipe's read end (non-blocking, close-on-exec), or -1 when none could be made.
  private let wakeReadEnd: Int32
  /// The wake pipe's write end (non-blocking, close-on-exec), or -1.
  private let wakeWriteEnd: Int32
  /// Whether `stop()` was called.
  private let stopped = OSAllocatedUnfairLock(initialState: false)

  /// Creates a reader for `input` with its wake pipe.
  init(input: Int32) {
    self.input = input
    var ends: [Int32] = [-1, -1]
    if pipe(&ends) == 0 {
      for end in ends {
        _ = fcntl(end, F_SETFD, FD_CLOEXEC)
        _ = fcntl(end, F_SETFL, fcntl(end, F_GETFL) | O_NONBLOCK)
      }
      wakeReadEnd = ends[0]
      wakeWriteEnd = ends[1]
    } else {
      wakeReadEnd = -1
      wakeWriteEnd = -1
    }
  } // End of init(input:)

  /// Closes the wake pipe.
  deinit {
    for end in [wakeReadEnd, wakeWriteEnd] where end >= 0 { Darwin.close(end) }
  }

  /// Whether `stop()` was called.
  var isStopped: Bool { stopped.withLock { $0 } }

  /// Ends `run()` at once, or makes a later `run()` return at once. Never blocks; safe from
  /// any thread, any number of times.
  func stop() {
    stopped.withLock { $0 = true }
    guard wakeWriteEnd >= 0 else { return }
    var byte: UInt8 = 1
    _ = Darwin.write(wakeWriteEnd, &byte, 1)
  }

  /// Discards input typed so far, then reads `input` one byte at a time until a line end, end
  /// of file, an error or `stop()`. Each read follows a `poll` that reported input, on the
  /// reader's own non-blocking descriptor for the terminal (or on `input` itself when the
  /// terminal cannot be opened again, where a read after `poll` cannot block either, since
  /// nothing else reads the terminal meanwhile). Blocks until then: run it on a dedicated
  /// thread. When it returns, the reader has stopped reading for good.
  func run() -> End {
    _ = tcflush(input, TCIFLUSH)
    let reopened = NonBlockingTerminal.reopen(input, access: O_RDONLY)
    defer { if let reopened { Darwin.close(reopened) } }
    let descriptor = reopened ?? input
    let timeout = wakeReadEnd >= 0 ? -1 : Self.stopCheckInterval
    var byte: UInt8 = 0
    while !isStopped {
      let wake = wakeReadEnd >= 0 ? [wakeReadEnd] : []
      var watched = ([descriptor] + wake).map { pollfd(fd: $0, events: Int16(POLLIN), revents: 0) }
      let ready = poll(&watched, nfds_t(watched.count), timeout)
      if ready < 0 {
        if errno == EINTR { continue }
        return .failed
      }
      if isStopped { break }
      let events = watched[0].revents
      if events & Int16(POLLIN) == 0 {
        if events & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return .endOfInput }
        continue
      }
      let count = read(descriptor, &byte, 1)
      if count == 1 {
        if byte == 0x0A || byte == 0x0D { return .lineEnd }
        continue
      }
      if count < 0, errno == EINTR || errno == EAGAIN { continue }
      return count == 0 ? .endOfInput : .failed
    } // End of loop reading until a line end, the end of input or a stop
    return .stopped
  } // End of func run()
} // End of class TerminalReturnReader
