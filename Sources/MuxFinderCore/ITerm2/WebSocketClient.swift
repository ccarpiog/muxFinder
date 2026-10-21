import Dispatch
import Foundation
import os

/// A binary message waiting in a `WebSocketWriter`'s queue, as one frame.
///
/// Until its write starts the message can be withdrawn, and the writer skips it when it reaches
/// it after its deadline or after a close frame was queued; a skipped or withdrawn message has
/// none of its bytes written. The writer decides under the same lock that `withdraw()` takes,
/// so a message is either withdrawn or written, never both. Once its write has started it is
/// written whole, or the write fails and the stream is shut down, so a partial frame is never
/// followed by another frame.
final class QueuedMessage: Sendable {
  /// Where the message is in its life.
  enum State: Sendable, Hashable {
    /// Waiting for the writer.
    case queued
    /// The writer is writing it; it can no longer be withdrawn.
    case writing
    /// Every byte was written.
    case written
    /// The write started but failed; the stream was shut down before the frame was complete.
    case failed
    /// Its sender withdrew it before its write started.
    case withdrawn
    /// The writer skipped it: its deadline had passed or a close frame had been queued.
    case skipped
  }

  /// What the writer does with a message it reaches.
  enum Disposition: Sendable, Hashable {
    /// Write it.
    case write
    /// Skip it and report `error` to its completion.
    case skip(ByteStreamError)
    /// Skip it without reporting anything: its sender withdrew it and reports the failure.
    case discard
  }

  /// The message's payload.
  let payload: [UInt8]
  /// When the writer stops being willing to start writing it; `nil` for no limit.
  let deadline: ContinuousClock.Instant?
  /// The lock-protected state.
  private let state = OSAllocatedUnfairLock(initialState: State.queued)

  /// Creates a message that has not been queued yet.
  init(payload: [UInt8], deadline: ContinuousClock.Instant? = nil) {
    self.payload = payload
    self.deadline = deadline
  }

  /// Where the message is now.
  var currentState: State { state.withLock { $0 } }

  /// Withdraws the message if its write has not started, and returns whether the message is
  /// certain never to be written whole: `true` when it was still queued (it is now withdrawn)
  /// or was already withdrawn, skipped or failed; `false` while it is being written and once it
  /// has been written, because the peer may then have received it.
  @discardableResult
  func withdraw() -> Bool {
    state.withLock { state in
      switch state {
      case .queued, .withdrawn:
        state = .withdrawn
        return true
      case .skipped, .failed:
        return true
      case .writing, .written:
        return false
      }
    }
  } // End of func withdraw()

  /// Decides, for the writer, what to do with the message it has reached: start writing it if
  /// it is still queued, no close frame has been queued and its deadline has not passed.
  func dispose(closeQueued: Bool) -> Disposition {
    let now = ContinuousClock.now
    return state.withLock { state in
      guard state == .queued else { return .discard }
      if closeQueued {
        state = .skipped
        return .skip(.shutDown)
      }
      if let deadline, now >= deadline {
        state = .skipped
        return .skip(.timedOut)
      }
      state = .writing
      return .write
    }
  } // End of func dispose(closeQueued:)

  /// Records, for the writer, how the write ended.
  func finishWrite(succeeded: Bool) {
    state.withLock { $0 = succeeded ? .written : .failed }
  }
}

/// The sending half of a client WebSocket connection (RFC 6455).
///
/// Every frame goes through one serial dispatch queue, so frames are written whole and in the
/// order they were queued, and no caller ever blocks on the socket: neither an actor nor the
/// reader thread (which queues pongs and close replies here). Each frame is masked with a fresh
/// random key. Binary messages are `QueuedMessage`s: one withdrawn before its write starts is
/// never written, and the writer skips one whose deadline has passed when it reaches it. Once a
/// close frame has been queued, binary messages whose write has not started are skipped. Any
/// write failure shuts the stream down, which also ends the reader.
final class WebSocketWriter: Sendable {
  /// What the writer has done so far.
  private struct State: Sendable {
    /// Whether a close frame has been queued.
    var closeQueued = false
  }

  /// The stream frames are written to.
  let stream: any ByteStream
  /// The serial queue that performs the writes.
  private let queue: DispatchQueue
  /// How long one frame may take to write.
  private let writeTimeout: Duration
  /// Produces the 4-byte masking key for each frame.
  private let makeMaskingKey: @Sendable () -> [UInt8]
  /// Lock-protected state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a writer. Tests pass their own `makeMaskingKey` to observe the keys.
  init(
    stream: any ByteStream,
    writeTimeout: Duration,
    makeMaskingKey: @escaping @Sendable () -> [UInt8] = WebSocketWriter.randomMaskingKey
  ) {
    self.stream = stream
    self.writeTimeout = writeTimeout
    self.makeMaskingKey = makeMaskingKey
    queue = DispatchQueue(label: "cc.carpio.muxfinder.websocket-writer")
  }

  /// Four bytes from the system's secure random generator.
  @Sendable static func randomMaskingKey() -> [UInt8] {
    var generator = SystemRandomNumberGenerator()
    return (0..<4).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
  }

  /// Whether a close frame has been queued.
  var closeQueued: Bool { state.withLock { $0.closeQueued } }

  /// Queues a binary message as one frame and returns it, so the caller can withdraw it until
  /// its write starts. See `enqueue(_:completion:)`.
  @discardableResult
  func enqueueBinary(
    _ payload: [UInt8],
    deadline: ContinuousClock.Instant? = nil,
    completion: @escaping @Sendable (Result<Void, ByteStreamError>) -> Void = { _ in }
  ) -> QueuedMessage {
    let message = QueuedMessage(payload: payload, deadline: deadline)
    enqueue(message, completion: completion)
    return message
  }

  /// Queues `message` as one binary frame. `completion` runs on the writer's queue once the
  /// frame is written, or with the failure: `timedOut` when the writer reached the message after
  /// its deadline, `shutDown` when a close frame had been queued by then, or the write's own
  /// failure. It does not run for a message withdrawn before its write started.
  func enqueue(
    _ message: QueuedMessage,
    completion: @escaping @Sendable (Result<Void, ByteStreamError>) -> Void = { _ in }
  ) {
    queue.async { [self] in
      switch message.dispose(closeQueued: closeQueued) {
      case .discard:
        return
      case .skip(let error):
        completion(.failure(error))
      case .write:
        let result = write(.binary, payload: message.payload)
        if case .success = result {
          message.finishWrite(succeeded: true)
        } else {
          message.finishWrite(succeeded: false)
        }
        completion(result)
      }
    }
  } // End of func enqueue(_:completion:)

  /// Queues a pong carrying `payload` (the ping's payload).
  func enqueuePong(_ payload: [UInt8]) {
    enqueue(.pong, payload: payload) { _ in }
  }

  /// Queues a close frame carrying `code` unless one was already queued, and returns whether it
  /// queued one. `completion` runs after the write either way it ends; it does not run when
  /// nothing was queued.
  @discardableResult
  func enqueueClose(
    code: UInt16?,
    completion: @escaping @Sendable (Result<Void, ByteStreamError>) -> Void = { _ in }
  ) -> Bool {
    let isFirst = state.withLock { state in
      defer { state.closeQueued = true }
      return !state.closeQueued
    }
    guard isFirst else { return false }
    enqueue(.close, payload: WebSocketFrame.closePayload(code: code), completion: completion)
    return true
  }

  /// Waits until every frame queued so far has been written (or has failed).
  func flush() {
    queue.sync {}
  }

  /// Shuts the stream down once every frame queued so far has been written (or has failed), so
  /// a close reply queued by the reader still goes out.
  func shutDownAfterQueuedFrames() {
    queue.async { [stream] in stream.shutDown() }
  }

  /// Queues one control frame.
  private func enqueue(
    _ opcode: WebSocketOpcode,
    payload: [UInt8],
    completion: @escaping @Sendable (Result<Void, ByteStreamError>) -> Void
  ) {
    queue.async { [self] in
      completion(write(opcode, payload: payload))
    }
  }

  /// Writes one frame on the writer's queue, masked with a key drawn now, and shuts the stream
  /// down if the write fails.
  private func write(_ opcode: WebSocketOpcode, payload: [UInt8]) -> Result<Void, ByteStreamError> {
    let frame = WebSocketFrame.encode(
      opcode: opcode, payload: payload, maskingKey: makeMaskingKey())
    do throws(ByteStreamError) {
      try stream.write(frame, deadline: .now + writeTimeout)
      return .success(())
    } catch {
      stream.shutDown()
      return .failure(error)
    }
  } // End of func write(_:payload:)
}

/// The receiving half of a client WebSocket connection (RFC 6455).
///
/// Used by one thread at a time (it is not `Sendable`). It returns whole binary messages,
/// reassembling continuation frames, and handles control frames itself, including ones that
/// arrive between the fragments of a message: a ping is answered with a pong carrying the same
/// payload, a pong is ignored, and a valid close frame is answered with its status code (or an
/// empty close frame), unless this side already sent one, before the stream is shut down. A
/// malformed close frame (see `WebSocketFrame.receivedCloseCode(in:)`), a message longer than
/// `maximumMessageLength` or any other protocol violation sends the matching close code (1007
/// for a reason that is not UTF-8, 1009 for an oversized message, 1002 otherwise), shuts the
/// stream down and throws.
struct WebSocketReader {
  /// iTerm2's messages are small; 16 MiB is far beyond any real one and bounds memory.
  static let defaultMaximumMessageLength = 16 * 1024 * 1024
  /// How many bytes one read asks for.
  static let readChunkLength = 64 * 1024

  /// The stream messages are read from.
  let stream: any ByteStream
  /// The writer used for pongs and close replies.
  let writer: WebSocketWriter
  /// The longest message accepted, all fragments together.
  let maximumMessageLength: Int
  /// Frames received but not yet decoded.
  private var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
  /// The fragments of the message being reassembled, or `nil` between messages.
  private var fragments: [UInt8]?
  /// How the connection ended, once it has.
  private var ending: WebSocketError?
  /// Every byte received so far, including the handshake remainder.
  private(set) var receivedByteCount = 0

  /// Creates a reader. `initialBytes` are bytes that arrived with the handshake reply.
  init(
    stream: any ByteStream,
    writer: WebSocketWriter,
    initialBytes: [UInt8] = [],
    maximumMessageLength: Int = WebSocketReader.defaultMaximumMessageLength
  ) {
    self.stream = stream
    self.writer = writer
    self.maximumMessageLength = maximumMessageLength
    decoder.append(initialBytes)
    receivedByteCount = initialBytes.count
  } // End of init(stream:writer:initialBytes:maximumMessageLength:)

  /// Whether part of a message (or of a frame) has arrived but not all of it.
  var hasPartialMessage: Bool { fragments != nil || decoder.bufferedByteCount > 0 }

  /// Returns the next whole binary message, waiting at most until `deadline`.
  ///
  /// - Throws: `timedOut` at the deadline (partial input is kept, so the call can be
  ///   repeated); `closed` after a close handshake; `endOfStream` when the stream ended without
  ///   one; `protocolViolation` or `messageTooLarge` when the server broke the rules (the
  ///   connection is then closed). After anything but `timedOut`, every later call throws the
  ///   same error.
  mutating func receiveMessage(
    deadline: ContinuousClock.Instant
  ) throws(WebSocketError) -> [UInt8] {
    if let ending { throw ending }
    while true {
      let assembled = fragments?.count ?? 0
      let frame: WebSocketFrame?
      do throws(WebSocketError) {
        frame = try decoder.nextFrame(
          maximumDataPayloadLength: maximumMessageLength - assembled,
          messageLimit: maximumMessageLength)
      } catch {
        throw fail(error)
      }
      if let frame {
        if let message = try handle(frame) { return message }
        continue
      }
      let chunk: [UInt8]
      do throws(ByteStreamError) {
        chunk = try stream.read(maximumLength: Self.readChunkLength, deadline: deadline)
      } catch .timedOut {
        throw .timedOut
      } catch {
        throw end(.transport(error))
      }
      if chunk.isEmpty { throw end(.endOfStream) }
      receivedByteCount += chunk.count
      decoder.append(chunk)
    } // End of loop until a whole message arrives
  } // End of func receiveMessage(deadline:)

  /// Acts on one frame. Returns a message when `frame` completes one.
  private mutating func handle(_ frame: WebSocketFrame) throws(WebSocketError) -> [UInt8]? {
    switch frame.opcode {
    case .ping:
      writer.enqueuePong(frame.payload)
      return nil
    case .pong:
      return nil
    case .close:
      let code: UInt16?
      do throws(InvalidClosePayload) {
        code = try WebSocketFrame.receivedCloseCode(in: frame.payload)
      } catch {
        throw fail(.protocolViolation(error.rule), closeCode: error.replyCode)
      }
      let stream = self.stream
      let replied = writer.enqueueClose(code: code) { _ in stream.shutDown() }
      if !replied { stream.shutDown() }
      throw end(.closed(code: code))
    case .text:
      throw fail(.protocolViolation("server sent a text message; only binary messages are used"))
    case .binary:
      guard fragments == nil else {
        throw fail(.protocolViolation("a new message started inside a fragmented message"))
      }
      if frame.isFinal { return frame.payload }
      fragments = frame.payload
      return nil
    case .continuation:
      guard fragments != nil else {
        throw fail(.protocolViolation("continuation frame without a message to continue"))
      }
      fragments?.append(contentsOf: frame.payload)
      guard frame.isFinal else { return nil }
      defer { fragments = nil }
      return fragments
    }
  } // End of func handle(_:)

  /// Records `error` as the end of the connection and returns it.
  private mutating func end(_ error: WebSocketError) -> WebSocketError {
    ending = error
    fragments = nil
    return error
  }

  /// Closes the connection because the server broke the rules: sends `closeCode`, or by default
  /// the code matching `error` (1009 for an oversized message, 1002 otherwise), shuts the stream
  /// down once it is written, and returns `error`.
  private mutating func fail(_ error: WebSocketError, closeCode: UInt16? = nil) -> WebSocketError {
    let code: UInt16
    if let closeCode {
      code = closeCode
    } else if case .messageTooLarge = error {
      code = WebSocketFrame.messageTooBigClosure
    } else {
      code = WebSocketFrame.protocolErrorClosure
    }
    let stream = self.stream
    if !writer.enqueueClose(code: code, completion: { _ in stream.shutDown() }) {
      stream.shutDown()
    }
    return end(error)
  } // End of func fail(_:closeCode:)
}
