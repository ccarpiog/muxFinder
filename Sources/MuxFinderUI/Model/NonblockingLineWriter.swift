import Darwin
import Dispatch
import Foundation
import os

/// Writes report lines to a file descriptor without ever blocking the caller: the popover
/// placement diagnostic's standard output (PLAN.md Phase I-1), whose deadlines and signal
/// handlers run on the main actor and must not wait for a reader.
///
/// `write(_:)` only queues the line; a dedicated serial queue makes the `write(2)` calls, so a
/// reader that stops reading blocks that queue and never the caller. At most `capacity` bytes
/// of lines wait to be written; a line that does not fit is dropped and counted. A write that
/// would block on a descriptor in nonblocking mode (`EAGAIN`) or fails (`EPIPE` when `SIGPIPE`
/// is ignored, for one) drops the rest of its line, counted the same way. `flush(timeout:)`
/// waits a bounded time for the lines queued so far.
public final class NonblockingLineWriter: Sendable {
  /// The counters shared between the caller and the writing queue.
  struct State: Sendable {
    /// Bytes queued and not yet written or dropped.
    var pendingBytes = 0
    /// Lines written in full.
    var writtenLines = 0
    /// Lines dropped, in full or in part.
    var droppedLines = 0
  }

  /// The descriptor written to.
  public let fileDescriptor: Int32
  /// The most bytes of queued lines waiting to be written.
  public let capacity: Int
  /// The serial queue making the `write(2)` calls.
  private let queue: DispatchQueue
  /// The counters.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// A writer to `fileDescriptor` holding at most `capacity` bytes of lines not yet written;
  /// the descriptor is neither changed nor closed.
  public init(fileDescriptor: Int32, capacity: Int = 64 * 1024) {
    self.fileDescriptor = fileDescriptor
    self.capacity = capacity
    queue = DispatchQueue(label: "cc.carpio.muxfinder.line-writer.\(fileDescriptor)")
  }

  /// Queues `line` and a line feed and returns at once; `false` when the line was dropped
  /// because the queued lines would exceed `capacity`.
  @discardableResult
  public func write(_ line: String) -> Bool {
    let bytes = Array((line + "\n").utf8)
    let accepted = state.withLock { state -> Bool in
      guard state.pendingBytes + bytes.count <= capacity else {
        state.droppedLines += 1
        return false
      }
      state.pendingBytes += bytes.count
      return true
    }
    guard accepted else { return false }
    queue.async { [self] in
      let complete = Self.writeAll(bytes, to: fileDescriptor)
      state.withLock { state in
        state.pendingBytes -= bytes.count
        if complete { state.writtenLines += 1 } else { state.droppedLines += 1 }
      }
    }
    return true
  } // End of func write(_:)

  /// Lines dropped so far, in full or in part.
  public var droppedLines: Int { state.withLock { $0.droppedLines } }

  /// Lines written in full so far.
  public var writtenLines: Int { state.withLock { $0.writtenLines } }

  /// Waits at most `timeout` seconds for every line queued so far to be written or dropped;
  /// `true` when they were.
  public func flush(timeout: TimeInterval) -> Bool {
    let done = DispatchSemaphore(value: 0)
    queue.async { done.signal() }
    return done.wait(timeout: .now() + timeout) == .success
  }

  /// Writes all of `bytes` to `descriptor`, again after an interrupted call; `false` when a
  /// write would block or failed, so the rest was not written.
  static func writeAll(_ bytes: [UInt8], to descriptor: Int32) -> Bool {
    var offset = 0
    while offset < bytes.count {
      let written = bytes.withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
      }
      if written > 0 {
        offset += written
      } else if written < 0, errno == EINTR {
        continue
      } else {
        return false
      }
    } // End of loop over the bytes left to write
    return true
  } // End of static func writeAll(_:to:)
}
