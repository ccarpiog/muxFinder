import Darwin
import Foundation
import os

/// Why a `ByteStream` operation failed.
enum ByteStreamError: Error, Sendable, Hashable {
  /// Nothing could be read or written before the deadline.
  case timedOut
  /// The stream was shut down on this side.
  case shutDown
  /// The peer closed the connection while bytes were still being written.
  case closedByPeer
  /// A system call failed with `errno`.
  case systemCallFailed(name: String, errno: Int32)
}

/// A bidirectional byte transport whose every wait is bounded by a deadline.
///
/// The WebSocket layer talks to iTerm2 through this protocol, so tests can drive it with a fake
/// that delivers bytes in arbitrary chunks. At most one thread reads and one thread writes at a
/// time; the two may be different threads, and `shutDown()` may be called from any thread.
protocol ByteStream: Sendable {
  /// Reads at most `maximumLength` bytes (at least 1), waiting until `deadline` for some to
  /// arrive. Returns an empty array at end of stream: the peer closed the connection, or this
  /// side was shut down.
  ///
  /// - Throws: `ByteStreamError.timedOut` when nothing arrived before the deadline.
  func read(
    maximumLength: Int,
    deadline: ContinuousClock.Instant
  ) throws(ByteStreamError) -> [UInt8]

  /// Writes every byte of `bytes`, waiting until `deadline` for buffer space.
  func write(_ bytes: [UInt8], deadline: ContinuousClock.Instant) throws(ByteStreamError)

  /// Stops all I/O: a blocked read returns end of stream at once and later writes fail. Safe to
  /// call more than once and from any thread.
  func shutDown()
}

/// Converts the time left until `deadline` to a `poll()` timeout in milliseconds, rounded up so
/// a wait never ends just before its deadline, and capped at `Int32.max`.
func pollTimeoutMilliseconds(until deadline: ContinuousClock.Instant) -> Int32 {
  let remaining = deadline - ContinuousClock.now
  guard remaining > .zero else { return 0 }
  let (seconds, attoseconds) = remaining.components
  let milliseconds = seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
  return Int32(clamping: milliseconds)
}

/// A connected `AF_UNIX` stream socket: the production `ByteStream`.
///
/// The descriptor is non-blocking, close-on-exec and has `SO_NOSIGPIPE` set, so a write to a
/// closed peer reports `closedByPeer` instead of killing the process with `SIGPIPE`. Every wait
/// goes through `poll()` with the caller's deadline. `shutDown()` only calls `shutdown(2)`; the
/// descriptor is closed when the stream is deallocated, after every user has let go of it, so a
/// late call can never reach a descriptor number the system has reused.
final class UnixSocketStream: ByteStream {
  /// The connected socket.
  private let descriptor: Int32
  /// Whether `shutDown()` has run.
  private let isShutDown = OSAllocatedUnfairLock(initialState: false)

  /// Adopts a connected socket descriptor. The stream owns and eventually closes it.
  init(adopting descriptor: Int32) {
    self.descriptor = descriptor
  }

  /// Closes the descriptor.
  deinit {
    Darwin.close(descriptor)
  }

  /// Connects to the Unix socket at `path`, waiting until `deadline` if the connection does not
  /// complete at once.
  ///
  /// - Throws: `systemCallFailed(name: "connect", …)` with `ENOENT` when nothing is at `path`,
  ///   `ECONNREFUSED` when nobody listens there, `ENAMETOOLONG` when the path does not fit in
  ///   `sockaddr_un`; `timedOut` when the deadline passes.
  static func connect(
    toPath path: String,
    deadline: ContinuousClock.Instant
  ) throws(ByteStreamError) -> UnixSocketStream {
    var address = sockaddr_un()
    let pathBytes = Array(path.utf8)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    guard !pathBytes.isEmpty, pathBytes.count < capacity, !pathBytes.contains(0) else {
      throw .systemCallFailed(name: "connect", errno: ENAMETOOLONG)
    }
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
      buffer.copyBytes(from: pathBytes)
    }
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw .systemCallFailed(name: "socket", errno: errno) }
    let stream = UnixSocketStream(adopting: descriptor)
    try stream.configure()
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
        Darwin.connect(descriptor, socketAddress, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    if result != 0 {
      let code = errno
      guard code == EINPROGRESS || code == EINTR || code == EALREADY else {
        throw .systemCallFailed(name: "connect", errno: code)
      }
      try stream.finishConnecting(deadline: deadline)
    }
    return stream
  } // End of func connect(toPath:deadline:)

  /// Creates a connected pair of streams with `socketpair()`. Tests use it to exercise the real
  /// POSIX transport without any server.
  static func makePair() throws(ByteStreamError) -> (UnixSocketStream, UnixSocketStream) {
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
      throw .systemCallFailed(name: "socketpair", errno: errno)
    }
    let first = UnixSocketStream(adopting: descriptors[0])
    let second = UnixSocketStream(adopting: descriptors[1])
    try first.configure()
    try second.configure()
    return (first, second)
  } // End of func makePair()

  /// Sets close-on-exec, `SO_NOSIGPIPE` and non-blocking mode.
  private func configure() throws(ByteStreamError) {
    guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0 else {
      throw .systemCallFailed(name: "fcntl", errno: errno)
    }
    var enabled: Int32 = 1
    let size = socklen_t(MemoryLayout<Int32>.size)
    guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, size) == 0 else {
      throw .systemCallFailed(name: "setsockopt", errno: errno)
    }
    let flags = fcntl(descriptor, F_GETFL)
    guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
      throw .systemCallFailed(name: "fcntl", errno: errno)
    }
  } // End of func configure()

  /// Waits for a non-blocking connect that is still in progress and reports its result.
  private func finishConnecting(deadline: ContinuousClock.Instant) throws(ByteStreamError) {
    try wait(for: Int16(POLLOUT), until: deadline)
    var socketError: Int32 = 0
    var size = socklen_t(MemoryLayout<Int32>.size)
    guard getsockopt(descriptor, SOL_SOCKET, SO_ERROR, &socketError, &size) == 0 else {
      throw .systemCallFailed(name: "getsockopt", errno: errno)
    }
    if socketError != 0 { throw .systemCallFailed(name: "connect", errno: socketError) }
  }

  /// Reads at most `maximumLength` bytes. See `ByteStream.read(maximumLength:deadline:)`.
  func read(
    maximumLength: Int,
    deadline: ContinuousClock.Instant
  ) throws(ByteStreamError) -> [UInt8] {
    precondition(maximumLength > 0, "a read must ask for at least one byte")
    while true {
      if isShutDown.withLock({ $0 }) { return [] }
      try wait(for: Int16(POLLIN), until: deadline)
      var readError: Int32 = 0
      let bytes = [UInt8](unsafeUninitializedCapacity: maximumLength) { buffer, count in
        let result = Darwin.read(descriptor, buffer.baseAddress, maximumLength)
        count = max(result, 0)
        if result < 0 { readError = errno }
      }
      if !bytes.isEmpty { return bytes }
      switch readError {
      case 0, ECONNRESET: return []
      case EAGAIN, EINTR: continue
      default: throw .systemCallFailed(name: "read", errno: readError)
      }
    } // End of loop until bytes, end of stream or an error
  } // End of func read(maximumLength:deadline:)

  /// Writes every byte. See `ByteStream.write(_:deadline:)`.
  func write(_ bytes: [UInt8], deadline: ContinuousClock.Instant) throws(ByteStreamError) {
    var offset = 0
    while offset < bytes.count {
      if isShutDown.withLock({ $0 }) { throw .shutDown }
      try wait(for: Int16(POLLOUT), until: deadline)
      let result = bytes[offset...].withUnsafeBytes { buffer in
        Darwin.write(descriptor, buffer.baseAddress, buffer.count)
      }
      if result > 0 {
        offset += result
        continue
      }
      let code = errno
      switch code {
      case EAGAIN, EINTR: continue
      case EPIPE, ECONNRESET: throw .closedByPeer
      default: throw .systemCallFailed(name: "write", errno: code)
      }
    } // End of loop over unwritten bytes
  } // End of func write(_:deadline:)

  /// Shuts the socket down in both directions, waking any blocked `poll()`.
  func shutDown() {
    let isFirstCall = isShutDown.withLock { isShutDown in
      defer { isShutDown = true }
      return !isShutDown
    }
    if isFirstCall { _ = Darwin.shutdown(descriptor, SHUT_RDWR) }
  }

  /// Waits until the socket reports `events` (or an error or hang-up, which the next read or
  /// write then reports), or throws `timedOut` at the deadline.
  private func wait(for events: Int16, until deadline: ContinuousClock.Instant)
    throws(ByteStreamError)
  {
    while true {
      var entry = pollfd(fd: descriptor, events: events, revents: 0)
      let timeout = pollTimeoutMilliseconds(until: deadline)
      let result = poll(&entry, 1, timeout)
      if result > 0 { return }
      if result == 0 {
        if ContinuousClock.now >= deadline { throw .timedOut }
        continue
      }
      let code = errno
      if code != EINTR { throw .systemCallFailed(name: "poll", errno: code) }
    } // End of loop until ready, timed out or failed
  } // End of func wait(for:until:)
}
