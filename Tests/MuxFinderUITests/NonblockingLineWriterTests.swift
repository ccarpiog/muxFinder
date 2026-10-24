import Darwin
import Dispatch
import Foundation
import Testing

@testable import MuxFinderUI

/// The popover placement diagnostic's output (`NonblockingLineWriter`, PLAN.md Phase I-1): a
/// reader that stopped reading never blocks the caller, whether the descriptor blocks (the
/// writing queue waits, later lines are dropped at the capacity) or not (`EAGAIN` drops the
/// line); drops are counted; lines arrive whole once the reader reads.
@Suite("Nonblocking line writer")
struct NonblockingLineWriterTests {
  /// A pipe whose write end raises no `SIGPIPE`, and whose buffer is full: written in
  /// nonblocking mode until `EAGAIN`, then left in `blocking` mode as asked.
  static func fullPipe(blocking: Bool) throws -> (read: Int32, write: Int32) {
    var ends: [Int32] = [0, 0]
    try #require(pipe(&ends) == 0)
    _ = fcntl(ends[1], F_SETNOSIGPIPE, 1)
    let flags = fcntl(ends[1], F_GETFL)
    _ = fcntl(ends[1], F_SETFL, flags | O_NONBLOCK)
    let chunk = [UInt8](repeating: 0x2E, count: 4096)
    while chunk.withUnsafeBytes({ Darwin.write(ends[1], $0.baseAddress, $0.count) }) > 0 {}
    while Darwin.write(ends[1], [UInt8(0x2E)], 1) > 0 {}
    if blocking { _ = fcntl(ends[1], F_SETFL, flags & ~O_NONBLOCK) }
    return (ends[0], ends[1])
  } // End of static func fullPipe(blocking:)

  /// Reads and discards everything the pipe holds now, without blocking.
  static func drain(_ descriptor: Int32) {
    let flags = fcntl(descriptor, F_GETFL)
    _ = fcntl(descriptor, F_SETFL, flags | O_NONBLOCK)
    var buffer = [UInt8](repeating: 0, count: 65536)
    while buffer.withUnsafeMutableBytes({ read(descriptor, $0.baseAddress, $0.count) }) > 0 {}
    _ = fcntl(descriptor, F_SETFL, flags)
  }

  /// A blocking descriptor whose reader stopped reading (a stalled standard output): 200
  /// lines return at once from another thread, the queue holds at most the capacity, the rest
  /// is dropped and counted, and nothing is written until the reader reads again.
  @Test func stalledBlockingReaderNeverBlocksTheCaller() throws {
    let pipe = try Self.fullPipe(blocking: true)
    defer {
      close(pipe.write)
      close(pipe.read)
    }
    let writer = NonblockingLineWriter(fileDescriptor: pipe.write, capacity: 1024)
    let line = String(repeating: "x", count: 99)
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
      for _ in 0..<200 { writer.write(line) }
      returned.signal()
    }
    #expect(returned.wait(timeout: .now() + 2) == .success, "write(_:) blocked the caller")
    #expect(writer.droppedLines >= 190)
    #expect(writer.writtenLines == 0)
    #expect(!writer.flush(timeout: 0.2), "the stalled pipe let a line through")
    let deadline = ContinuousClock.now + .seconds(5)
    while !writer.flush(timeout: 0.05), ContinuousClock.now < deadline { Self.drain(pipe.read) }
    #expect(writer.flush(timeout: 1))
    #expect(writer.writtenLines + writer.droppedLines == 200)
    #expect(writer.writtenLines >= 1 && writer.writtenLines <= 10)
  } // End of func stalledBlockingReaderNeverBlocksTheCaller()

  /// A full nonblocking pipe: each line's write would block, so it is dropped and counted at
  /// once; once the pipe is read, a line arrives whole with its line feed.
  @Test func fullNonblockingPipeDropsAndCounts() throws {
    let pipe = try Self.fullPipe(blocking: false)
    defer {
      close(pipe.write)
      close(pipe.read)
    }
    let writer = NonblockingLineWriter(fileDescriptor: pipe.write)
    for index in 0..<5 { #expect(writer.write("line \(index)")) }
    #expect(writer.flush(timeout: 2))
    #expect(writer.droppedLines == 5)
    #expect(writer.writtenLines == 0)
    Self.drain(pipe.read)
    writer.write("muxFinder popover placement: exit 4")
    #expect(writer.flush(timeout: 2))
    #expect(writer.writtenLines == 1)
    var buffer = [UInt8](repeating: 0, count: 256)
    let count = buffer.withUnsafeMutableBytes { read(pipe.read, $0.baseAddress, $0.count) }
    #expect(
      String(decoding: buffer.prefix(max(0, count)), as: UTF8.self)
        == "muxFinder popover placement: exit 4\n")
  } // End of func fullNonblockingPipeDropsAndCounts()

  /// A line longer than the capacity is dropped at once and counted.
  @Test func lineLongerThanTheCapacityIsDropped() throws {
    let pipe = try Self.fullPipe(blocking: false)
    defer {
      close(pipe.write)
      close(pipe.read)
    }
    Self.drain(pipe.read)
    let writer = NonblockingLineWriter(fileDescriptor: pipe.write, capacity: 8)
    #expect(!writer.write("123456789"))
    #expect(writer.write("1234567"))
    #expect(writer.flush(timeout: 2))
    #expect(writer.droppedLines == 1)
    #expect(writer.writtenLines == 1)
  } // End of func lineLongerThanTheCapacityIsDropped()
}
