import Foundation
import Testing

@testable import MuxFinderCore

/// The receiving side against a fake stream: fragmented and partial reads, control frames
/// inside fragmented messages, the close handshake and close payload validation, the 16 MiB
/// cap and read timeouts.
@Suite("WebSocket reader")
struct WebSocketReaderTests {
  /// A reader and its writer on a fake stream.
  struct Harness {
    /// The fake stream.
    let stream: FakeByteStream
    /// The writer (pongs and close replies).
    let writer: WebSocketWriter
    /// The reader under test.
    var reader: WebSocketReader
  }

  /// A reader and writer on a fresh fake stream whose first reads return `chunks`.
  static func makeReader(chunks: [[UInt8]] = []) -> Harness {
    let stream = FakeByteStream(chunks: chunks)
    let writer = WebSocketWriter(stream: stream, writeTimeout: .seconds(1))
    return Harness(
      stream: stream, writer: writer, reader: WebSocketReader(stream: stream, writer: writer))
  }

  /// A server frame.
  static func frame(
    _ opcode: WebSocketOpcode,
    _ payload: [UInt8],
    final isFinal: Bool = true
  ) -> [UInt8] {
    WebSocketFrame.encode(opcode: opcode, payload: payload, isFinal: isFinal, maskingKey: nil)
  }

  /// Decodes every frame the client wrote.
  static func clientFrames(_ stream: FakeByteStream) throws -> [WebSocketFrame] {
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: true)
    decoder.append(stream.written)
    var frames: [WebSocketFrame] = []
    while let frame = try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max) {
      frames.append(frame)
    }
    return frames
  }

  /// A deadline far enough away for any test.
  static var later: ContinuousClock.Instant { .now + .seconds(5) }

  /// A message in three fragments, with a ping between fragments, delivered one byte per read,
  /// is reassembled, and the ping is answered with a pong carrying the same payload.
  @Test func fragmentedMessageWithInterleavedPingBytewise() throws {
    let bytes =
      Self.frame(.binary, [1, 2], final: false) + Self.frame(.ping, [0xAA, 0xBB])
      + Self.frame(.continuation, [3], final: false) + Self.frame(.pong, [5])
      + Self.frame(.continuation, [4, 5, 6])
    var harness = Self.makeReader()
    harness.stream.deliverBytewise(bytes)
    #expect(try harness.reader.receiveMessage(deadline: Self.later) == [1, 2, 3, 4, 5, 6])
    harness.writer.flush()
    let replies = try Self.clientFrames(harness.stream)
    #expect(replies.map(\.opcode) == [.pong])
    #expect(replies.first?.payload == [0xAA, 0xBB])
    #expect(replies.first?.maskingKey != nil)
    #expect(!harness.reader.hasPartialMessage)
  } // End of func fragmentedMessageWithInterleavedPingBytewise()

  /// Several frames in one read come out as separate messages, in order.
  @Test func severalFramesInOneRead() throws {
    let bytes = Self.frame(.binary, [1]) + Self.frame(.binary, [2, 2]) + Self.frame(.binary, [])
    var harness = Self.makeReader(chunks: [bytes])
    #expect(try harness.reader.receiveMessage(deadline: Self.later) == [1])
    #expect(try harness.reader.receiveMessage(deadline: Self.later) == [2, 2])
    #expect(try harness.reader.receiveMessage(deadline: Self.later) == [])
  }

  /// Frames split mid-header (inside the extended length) and mid-payload, with the next frame
  /// starting in the same read, all decode.
  @Test func framesSplitMidHeader() throws {
    let big = (0..<300).map { UInt8(truncatingIfNeeded: $0) }
    let huge = (0..<70_000).map { UInt8(truncatingIfNeeded: $0 / 3) }
    let bytes = Self.frame(.binary, big) + Self.frame(.binary, huge) + Self.frame(.binary, [9])
    for split in [1, 2, 3, 150, 303, 304, 305, 307, 312, 10_000] {
      var harness = Self.makeReader(chunks: [
        Array(bytes[..<split]), Array(bytes[split..<(split + 4)]), Array(bytes[(split + 4)...]),
      ])
      #expect(try harness.reader.receiveMessage(deadline: Self.later) == big)
      #expect(try harness.reader.receiveMessage(deadline: Self.later) == huge)
      #expect(try harness.reader.receiveMessage(deadline: Self.later) == [9])
    }
  }

  /// A server close is answered with the same status code, then the stream is shut down and
  /// every later call reports the close.
  @Test func serverCloseIsAnswered() throws {
    let close = Self.frame(.close, WebSocketFrame.closePayload(code: 1001))
    var harness = Self.makeReader(chunks: [Self.frame(.binary, [1]) + close])
    #expect(try harness.reader.receiveMessage(deadline: Self.later) == [1])
    #expect(throws: WebSocketError.closed(code: 1001)) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
    harness.writer.flush()
    let replies = try Self.clientFrames(harness.stream)
    #expect(replies.map(\.opcode) == [.close])
    #expect(WebSocketFrame.closeCode(in: replies[0].payload) == 1001)
    #expect(harness.stream.isShutDown)
    #expect(throws: WebSocketError.closed(code: 1001)) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
  } // End of func serverCloseIsAnswered()

  /// After this side sent a close, the server's close reply is not answered again; the stream
  /// is shut down.
  @Test func clientInitiatedClose() throws {
    var harness = Self.makeReader()
    #expect(harness.writer.enqueueClose(code: WebSocketFrame.normalClosure))
    harness.writer.flush()
    harness.stream.deliver(Self.frame(.close, WebSocketFrame.closePayload(code: 1000)))
    #expect(throws: WebSocketError.closed(code: 1000)) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
    harness.writer.flush()
    let frames = try Self.clientFrames(harness.stream)
    #expect(frames.map(\.opcode) == [.close])
    #expect(harness.stream.isShutDown)
  }

  /// A close frame without a status code is answered with an empty close frame.
  @Test func closeWithoutCode() throws {
    var harness = Self.makeReader(chunks: [Self.frame(.close, [])])
    #expect(throws: WebSocketError.closed(code: nil)) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
    harness.writer.flush()
    #expect(try Self.clientFrames(harness.stream).map(\.payload) == [[]])
  }

  /// A close frame with a status code allowed on the wire and a UTF-8 reason is answered with
  /// the same code.
  @Test(arguments: [1000, 1003, 1007, 1014, 3000, 4999] as [UInt16])
  func validCloseIsEchoed(code: UInt16) throws {
    let payload = WebSocketFrame.closePayload(code: code) + Array("bye ✓".utf8)
    var harness = Self.makeReader(chunks: [Self.frame(.close, payload)])
    #expect(throws: WebSocketError.closed(code: code)) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
    harness.writer.flush()
    let replies = try Self.clientFrames(harness.stream)
    #expect(replies.map(\.opcode) == [.close])
    #expect(replies.first?.payload == WebSocketFrame.closePayload(code: code))
    #expect(harness.stream.isShutDown)
  } // End of func validCloseIsEchoed(code:)

  /// Malformed close payloads (RFC 6455 §5.5.1, §7.4) are protocol violations answered with
  /// 1002, or 1007 for a reason that is not UTF-8, never with the received code: a single
  /// byte; codes that must not appear on the wire (the review's `88 02 03 ED` is 1005); a
  /// reason with an invalid byte, a surrogate or an overlong form.
  @Test(
    arguments: [
      ([0x03], 1002),
      ([0x03, 0xED], 1002),
      ([0x03, 0xEE], 1002),
      ([0x03, 0xE7], 1002),
      ([0x0B, 0xB7], 1002),
      ([0x03, 0xEC], 1002),
      ([0x03, 0xF7], 1002),
      ([0x03, 0xF8], 1002),
      ([0x00, 0x00], 1002),
      ([0x13, 0x88], 1002),
      ([0x03, 0xE8, 0xFF], 1007),
      ([0x03, 0xE8, 0x6F, 0x6B, 0xED, 0xA0, 0x80], 1007),
      ([0x03, 0xE8, 0xC0, 0xAF], 1007),
    ] as [([UInt8], UInt16)])
  func malformedCloseIsAProtocolViolation(payload: [UInt8], replyCode: UInt16) throws {
    var harness = Self.makeReader(chunks: [Self.frame(.close, payload)])
    let error = #expect(throws: WebSocketError.self) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
    guard case .protocolViolation(let detail)? = error else {
      Issue.record("expected a protocol violation, got \(String(describing: error))")
      return
    }
    #expect(detail.hasPrefix("close frame"))
    harness.writer.flush()
    let replies = try Self.clientFrames(harness.stream)
    #expect(replies.map(\.opcode) == [.close])
    #expect(replies.map(\.payload) == [WebSocketFrame.closePayload(code: replyCode)])
    #expect(harness.stream.isShutDown)
    #expect(throws: WebSocketError.protocolViolation(detail)) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
  } // End of func malformedCloseIsAProtocolViolation(payload:replyCode:)

  /// Fragments adding up to exactly 16 MiB are accepted; one more byte is refused with close
  /// code 1009 before the payload arrives.
  @Test func sixteenMebibyteCap() throws {
    let limit = WebSocketReader.defaultMaximumMessageLength
    let half = [UInt8](repeating: 0x5A, count: limit / 2)
    var harness = Self.makeReader(chunks: [
      Self.frame(.binary, half, final: false), Self.frame(.continuation, half),
    ])
    #expect(try harness.reader.receiveMessage(deadline: Self.later).count == limit)

    let header = Array(
      Self.frame(.continuation, [UInt8](repeating: 0, count: limit / 2 + 1)).prefix(10))
    var oversized = Self.makeReader(chunks: [
      Self.frame(.binary, half, final: false), header,
    ])
    #expect(throws: WebSocketError.messageTooLarge(limit: limit)) {
      _ = try oversized.reader.receiveMessage(deadline: Self.later)
    }
    oversized.writer.flush()
    let replies = try Self.clientFrames(oversized.stream)
    #expect(replies.map(\.opcode) == [.close])
    #expect(WebSocketFrame.closeCode(in: replies[0].payload) == 1009)
    #expect(oversized.stream.isShutDown)
  } // End of func sixteenMebibyteCap()

  /// A single frame declaring more than the limit is refused from its header alone.
  @Test func oversizedSingleFrame() {
    var harness = Self.makeReader(
      chunks: [[0x82, 127, 0, 0, 0, 0, 0x01, 0x00, 0x00, 0x01]])
    #expect(throws: WebSocketError.messageTooLarge(limit: 16 * 1024 * 1024)) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
  }

  /// A read that gets nothing times out at its deadline; partial input survives the timeout.
  @Test func readTimeoutKeepsPartialInput() throws {
    let message = Self.frame(.binary, [1, 2, 3, 4])
    var harness = Self.makeReader(chunks: [Array(message.prefix(3))])
    let start = ContinuousClock.now
    #expect(throws: WebSocketError.timedOut) {
      _ = try harness.reader.receiveMessage(deadline: .now + .milliseconds(80))
    }
    let elapsed = ContinuousClock.now - start
    #expect(elapsed >= .milliseconds(80))
    #expect(elapsed < .seconds(3))
    #expect(harness.reader.hasPartialMessage)
    harness.stream.deliver(Array(message.dropFirst(3)))
    #expect(try harness.reader.receiveMessage(deadline: Self.later) == [1, 2, 3, 4])
  }

  /// Protocol violations close the connection with code 1002.
  @Test(arguments: [
    (frame(.text, [0x41]), "text message"),
    (frame(.continuation, [1]), "continuation frame without"),
    (frame(.binary, [1], final: false) + frame(.binary, [2]), "new message started"),
  ])
  func protocolViolations(bytes: [UInt8], rule: String) throws {
    var harness = Self.makeReader(chunks: [bytes])
    let error = #expect(throws: WebSocketError.self) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
    guard case .protocolViolation(let detail)? = error else {
      Issue.record("expected a protocol violation, got \(String(describing: error))")
      return
    }
    #expect(detail.contains(rule))
    harness.writer.flush()
    #expect(
      try Self.clientFrames(harness.stream).map { WebSocketFrame.closeCode(in: $0.payload) } == [
        1002
      ])
    #expect(harness.stream.isShutDown)
  } // End of func protocolViolations(bytes:rule:)

  /// The stream ending mid-frame reports end of stream.
  @Test func endOfStreamMidFrame() {
    var harness = Self.makeReader(chunks: [[0x82, 0x05, 1, 2]])
    harness.stream.deliverEndOfStream()
    #expect(throws: WebSocketError.endOfStream) {
      _ = try harness.reader.receiveMessage(deadline: Self.later)
    }
  }
}
