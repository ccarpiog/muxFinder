import Darwin
import Foundation

/// How the helper's request for a device status report ended (PLAN.md Phase 13 item 4).
public enum TerminalStatusReport: Sendable, Hashable {
  /// The terminal answered `ESC [ 0 n` this long after the request was written.
  case answered(after: Duration)
  /// No answer arrived within the wait, or the terminal went away first.
  case unanswered
  /// Standard input or output is not a terminal, or the terminal's modes could not be read or
  /// set: nothing was written.
  case unavailable

  /// A stable name for logs and the test-mode digest: `answered`, `unanswered` or
  /// `unavailable`.
  public var kind: String {
    switch self {
    case .answered: return "answered"
    case .unanswered: return "unanswered"
    case .unavailable: return "unavailable"
    }
  }
} // End of enum TerminalStatusReport

/// Finds the terminal's status report answer, `ESC [ 0 n`, in bytes that arrive in pieces,
/// ignoring every other byte (input typed meanwhile, other reports).
struct StatusAnswerScanner {
  /// How many bytes of the answer the latest bytes matched.
  private var matched = 0

  /// Creates a scanner that has seen nothing.
  init() {}

  /// Feeds `bytes`; returns `true` once the whole answer has been seen. The answer's first byte
  /// (`ESC`) occurs in it only once, so after a mismatch matching starts again at that byte.
  mutating func feed(_ bytes: some Sequence<UInt8>) -> Bool {
    let answer = TerminalStatusRequest.answer
    for byte in bytes {
      if byte == answer[matched] {
        matched += 1
        if matched == answer.count { return true }
      } else {
        matched = byte == answer[0] ? 1 : 0
      }
    } // End of loop over the bytes
    return false
  } // End of func feed(_:)
} // End of struct StatusAnswerScanner

/// The device status report exchange behind
/// `StandardLaunchTerminal.requestStatusReport(after:timeout:)`, on explicit descriptors so
/// tests can run it on a pseudo-terminal they play the terminal on.
///
/// It completes within its timeout on every path (PLAN.md D29): one absolute deadline, taken
/// first, bounds the writes and the read of the answer; every write and read goes through a
/// non-blocking descriptor (`Descriptors`) after a `poll` bounded by that deadline, so a
/// terminal that takes no output (back-pressure) or input another reader took first cannot
/// hold it. It must be the terminal's only reader while it runs:
/// `StandardLaunchTerminal.waitForReturn()` returns only once its reader has stopped.
enum TerminalStatusRequest {
  /// The request, DSR `ESC [ 5 n` ("report your status").
  static let request: [UInt8] = [0x1B, 0x5B, 0x35, 0x6E]
  /// The answer of a terminal in working order, `ESC [ 0 n`.
  static let answer: [UInt8] = [0x1B, 0x5B, 0x30, 0x6E]
  /// How many bytes one read takes at most.
  static let readSize = 256

  /// Runs the exchange: unless `input` and `output` are both terminals, returns `.unavailable`
  /// at once. Otherwise it takes non-blocking descriptors for both (`Descriptors.open`), puts
  /// `input`'s terminal in raw mode (non-canonical, no echo, reads returning what is there),
  /// discards input typed so far, writes `prefix` followed by the request, and reads until the
  /// answer arrives, the terminal ends, or `timeout` (counted from the call, writes included)
  /// passes; every other byte read is dropped. The terminal's modes, and any file status flag
  /// changed on a shared descriptor, are restored on every path. SIGINT and SIGTERM, which the
  /// helper ignores, cannot interrupt it. Blocks for at most `timeout`: run it on a dedicated
  /// thread. `reopening: false` (tests only) takes the fallback of `Descriptors.open`.
  static func perform(
    input: Int32,
    output: Int32,
    prefix: [UInt8],
    timeout: Duration,
    reopening: Bool = true
  ) -> TerminalStatusReport {
    let deadline = ContinuousClock.now + timeout
    guard isatty(input) == 1, isatty(output) == 1 else { return .unavailable }
    guard let descriptors = Descriptors.open(input: input, output: output, reopening: reopening)
    else { return .unavailable }
    defer { descriptors.close() }
    var saved = termios()
    guard tcgetattr(input, &saved) == 0 else { return .unavailable }
    var raw = saved
    raw.c_lflag &= ~tcflag_t(ICANON | ECHO | ECHONL | IEXTEN)
    withUnsafeMutableBytes(of: &raw.c_cc) { characters in
      characters[Int(VMIN)] = 1
      characters[Int(VTIME)] = 0
    }
    guard tcsetattr(input, TCSANOW, &raw) == 0 else { return .unavailable }
    defer { _ = tcsetattr(input, TCSANOW, &saved) }
    _ = tcflush(input, TCIFLUSH)
    let start = ContinuousClock.now
    switch writeAll(prefix + request, to: descriptors.output, until: deadline) {
    case .complete: break
    case .nothing: return .unavailable
    case .partial, .timedOut: return .unanswered
    }
    return awaitAnswer(on: descriptors.input, until: deadline, since: start)
  } // End of static func perform(input:output:prefix:timeout:reopening:)

  /// The two descriptors one exchange reads and writes, both non-blocking, so no write or read
  /// can outlast the exchange's deadline.
  ///
  /// Each is the terminal opened again with `O_NONBLOCK` (`NonBlockingTerminal.reopen`), a
  /// separate open file description, so the helper's own descriptors, shared with its attach
  /// child, never change. Only when that fails does it fall back to the given descriptor with
  /// `O_NONBLOCK` set on it for the exchange; `close()` puts the original flags back.
  struct Descriptors {
    /// Read for the answer.
    let input: Int32
    /// Written with the prefix and the request.
    let output: Int32
    /// The descriptors opened here, which `close()` closes.
    private let opened: [Int32]
    /// The shared descriptors whose flags were changed here, with their original flags, in the
    /// order they were changed.
    private let changed: [(descriptor: Int32, flags: Int32)]

    /// Takes non-blocking descriptors for `input` (read) and `output` (written): opened again
    /// unless `reopening` is `false` or that fails, else the descriptor itself with
    /// `O_NONBLOCK` added. Every original flag is read before any is changed, since `input` and
    /// `output` may share one open file description. `nil` (nothing left changed or open) when
    /// a flag cannot be read or set.
    static func open(input: Int32, output: Int32, reopening: Bool) -> Descriptors? {
      var opened: [Int32] = []
      var shared: [Int32] = []
      /// A reopened descriptor for `descriptor` with `access`, else `descriptor` itself.
      func take(_ descriptor: Int32, access: Int32) -> Int32 {
        if reopening, let own = NonBlockingTerminal.reopen(descriptor, access: access) {
          opened.append(own)
          return own
        }
        shared.append(descriptor)
        return descriptor
      }
      let reading = take(input, access: O_RDONLY)
      let writing = take(output, access: O_WRONLY)
      let originals = shared.map { (descriptor: $0, flags: fcntl($0, F_GETFL)) }
      var changed: [(descriptor: Int32, flags: Int32)] = []
      var usable = originals.allSatisfy { $0.flags >= 0 }
      for original in originals where usable && original.flags & O_NONBLOCK == 0 {
        if fcntl(original.descriptor, F_SETFL, original.flags | O_NONBLOCK) == 0 {
          changed.append(original)
        } else {
          usable = false
        }
      }
      let descriptors = Descriptors(
        input: reading, output: writing, opened: opened, changed: changed)
      guard usable else {
        descriptors.close()
        return nil
      }
      return descriptors
    } // End of static func open(input:output:reopening:)

    /// Puts back the flags changed on shared descriptors (in reverse order, so a description
    /// changed twice ends with its original flags) and closes the descriptors opened here.
    func close() {
      for original in changed.reversed() {
        _ = fcntl(original.descriptor, F_SETFL, original.flags)
      }
      for descriptor in opened { Darwin.close(descriptor) }
    }
  } // End of struct Descriptors

  /// Reads the non-blocking `input` until the answer arrives (`.answered`, timed from
  /// `start`), `deadline` passes, or the terminal ends or fails (`.unanswered`). A read that
  /// finds nothing after `poll` reported input (another reader took it) waits again, within
  /// the same deadline.
  static func awaitAnswer(
    on input: Int32,
    until deadline: ContinuousClock.Instant,
    since start: ContinuousClock.Instant
  ) -> TerminalStatusReport {
    var scanner = StatusAnswerScanner()
    var buffer = [UInt8](repeating: 0, count: readSize)
    while true {
      guard NonBlockingTerminal.wait(for: Int16(POLLIN), on: input, until: deadline) == .ready
      else { return .unanswered }
      let count = read(input, &buffer, buffer.count)
      if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        return .unanswered
      }
      guard count > 0 else { return .unanswered }
      if scanner.feed(buffer[0..<count]) { return .answered(after: ContinuousClock.now - start) }
    } // End of loop reading until the answer or the deadline
  } // End of static func awaitAnswer(on:until:since:)

  /// How much of a write went out.
  enum WriteOutcome: Equatable {
    /// Every byte.
    case complete
    /// Some bytes, then an error or a hang-up.
    case partial
    /// No byte (the first write failed, or the terminal hung up).
    case nothing
    /// The deadline passed before every byte went out (the terminal took no more).
    case timedOut
  }

  /// Writes `bytes` to the non-blocking `descriptor` by `deadline`: whatever it takes at once,
  /// then, while it takes nothing (`EAGAIN`), waits for it to be writable within the deadline.
  /// Retries on `EINTR` and gives up on any other error.
  static func writeAll(
    _ bytes: [UInt8],
    to descriptor: Int32,
    until deadline: ContinuousClock.Instant
  ) -> WriteOutcome {
    var remaining = bytes[...]
    while !remaining.isEmpty {
      let count = remaining.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
      if count > 0 {
        remaining = remaining.dropFirst(count)
        continue
      }
      if count < 0, errno == EINTR { continue }
      if count < 0, errno == EAGAIN {
        switch NonBlockingTerminal.wait(for: Int16(POLLOUT), on: descriptor, until: deadline) {
        case .ready: continue
        case .timedOut: return .timedOut
        case .failed: break
        }
      }
      return remaining.count == bytes.count ? .nothing : .partial
    } // End of loop over writes
    return .complete
  } // End of static func writeAll(_:to:until:)
} // End of enum TerminalStatusRequest
