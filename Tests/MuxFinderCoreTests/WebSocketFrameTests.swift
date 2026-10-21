import Foundation
import Testing
import os

@testable import MuxFinderCore

/// How a queued frame's write ended, as reported to its completion.
enum WriteOutcome: Hashable, Sendable {
  /// Written whole.
  case written
  /// Not written, or not written whole, for this reason.
  case failed(ByteStreamError)
}

/// Collects the completions of queued frames by name.
final class WriteOutcomeLog: Sendable {
  /// The outcomes so far.
  private let outcomes = OSAllocatedUnfairLock<[String: WriteOutcome]>(initialState: [:])

  /// Every outcome recorded so far, by name.
  var all: [String: WriteOutcome] { outcomes.withLock { $0 } }

  /// A completion that records its result under `name`.
  func recorder(_ name: String) -> @Sendable (Result<Void, ByteStreamError>) -> Void {
    { [outcomes] result in
      let outcome: WriteOutcome
      switch result {
      case .success: outcome = .written
      case .failure(let error): outcome = .failed(error)
      }
      outcomes.withLock { $0[name] = outcome }
    }
  }
}

/// Frame encoding and decoding (RFC 6455 §5): the three payload-length encodings, client
/// masking, the writer's queue (withdrawn, expired and closing messages), close codes, and the
/// frames a client must reject.
@Suite("WebSocket frames")
struct WebSocketFrameTests {
  /// A fixed masking key.
  static let key: [UInt8] = [0x11, 0x22, 0x33, 0x44]

  /// Every payload-length encoding, at and around its boundaries: the header bytes, the mask
  /// bit and key, and the masked payload.
  @Test(arguments: [
    (0, [0 as UInt8]),
    (125, [125]),
    (126, [126, 0x00, 0x7E]),
    (65_535, [126, 0xFF, 0xFF]),
    (65_536, [127, 0, 0, 0, 0, 0, 0x01, 0x00, 0x00]),
    (70_000, [127, 0, 0, 0, 0, 0, 0x01, 0x11, 0x70]),
  ])
  func payloadLengthEncodings(length: Int, lengthField: [UInt8]) throws {
    let payload = (0..<length).map { UInt8(truncatingIfNeeded: $0 &* 7) }
    let frame = WebSocketFrame.encode(opcode: .binary, payload: payload, maskingKey: Self.key)
    let expectedLengthField = [0x80 | lengthField[0]] + lengthField.dropFirst()
    #expect(frame[0] == 0x82)
    #expect(Array(frame[1..<(1 + expectedLengthField.count)]) == expectedLengthField)
    let keyStart = 1 + expectedLengthField.count
    #expect(Array(frame[keyStart..<(keyStart + 4)]) == Self.key)
    let masked = Array(frame[(keyStart + 4)...])
    #expect(masked.count == length)
    for index in masked.indices {
      #expect(masked[index] == payload[index] ^ Self.key[index % 4])
      if masked[index] != payload[index] ^ Self.key[index % 4] { break }
    }
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: true)
    decoder.append(frame)
    let decoded = try #require(
      try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max))
    #expect(decoded.payload == payload)
    #expect(decoded.maskingKey == Self.key)
    #expect(decoder.bufferedByteCount == 0)
  } // End of func payloadLengthEncodings(length:lengthField:)

  /// Unmasked (server) frames use the same length encodings without the mask bit or key.
  @Test(arguments: [0, 125, 126, 65_535, 65_536])
  func unmaskedRoundTrip(length: Int) throws {
    let payload = [UInt8](repeating: 0xAB, count: length)
    let frame = WebSocketFrame.encode(
      opcode: .binary, payload: payload, isFinal: false, maskingKey: nil)
    #expect(frame[0] == 0x02)
    #expect(frame[1] & 0x80 == 0)
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
    decoder.append(frame)
    let decoded = try #require(
      try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max))
    #expect(decoded == WebSocketFrame(isFinal: false, opcode: .binary, payload: payload))
  } // End of func unmaskedRoundTrip(length:)

  /// The writer masks every frame with a key of its own, drawn when the frame is written.
  @Test func writerDrawsAFreshKeyForEveryFrame() throws {
    let stream = FakeByteStream()
    let counter = OSAllocatedUnfairLock(initialState: UInt8(0))
    let writer = WebSocketWriter(stream: stream, writeTimeout: .seconds(1)) {
      let next = counter.withLock { value in
        value += 1
        return value
      }
      return [next, next, next, next]
    }
    writer.enqueueBinary([1, 2, 3])
    writer.enqueuePong([9])
    writer.enqueueBinary([4, 5, 6])
    writer.flush()
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: true)
    decoder.append(stream.written)
    var frames: [WebSocketFrame] = []
    while let frame = try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max) {
      frames.append(frame)
    }
    #expect(frames.map(\.maskingKey) == [[1, 1, 1, 1], [2, 2, 2, 2], [3, 3, 3, 3]])
    #expect(frames.map(\.payload) == [[1, 2, 3], [9], [4, 5, 6]])
    #expect(frames.map(\.opcode) == [.binary, .pong, .binary])
  } // End of func writerDrawsAFreshKeyForEveryFrame()

  /// The default key source is random: two frames get different keys.
  @Test func defaultMaskingKeysDiffer() {
    let keys = (0..<4).map { _ in WebSocketWriter.randomMaskingKey() }
    #expect(keys.allSatisfy { $0.count == 4 })
    #expect(Set(keys).count > 1)
  }

  /// After a close frame, data frames are refused; the close frame is sent once.
  @Test func noDataAfterClose() throws {
    let stream = FakeByteStream()
    let writer = WebSocketWriter(stream: stream, writeTimeout: .seconds(1))
    #expect(writer.enqueueClose(code: 1000))
    #expect(!writer.enqueueClose(code: 1000))
    let refused = OSAllocatedUnfairLock<ByteStreamError?>(initialState: nil)
    writer.enqueueBinary([1]) { result in
      if case .failure(let error) = result { refused.withLock { $0 = error } }
    }
    writer.flush()
    #expect(refused.withLock { $0 } == .shutDown)
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: true)
    decoder.append(stream.written)
    let frame = try #require(
      try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max))
    #expect(frame.opcode == .close)
    #expect(WebSocketFrame.closeCode(in: frame.payload) == 1000)
    #expect(decoder.bufferedByteCount == 0)
  } // End of func noDataAfterClose()

  /// A failed write shuts the stream down.
  @Test func writeFailureShutsTheStreamDown() {
    let stream = FakeByteStream()
    stream.failWrites(with: .closedByPeer)
    let writer = WebSocketWriter(stream: stream, writeTimeout: .seconds(1))
    let failure = OSAllocatedUnfairLock<ByteStreamError?>(initialState: nil)
    writer.enqueueBinary([1]) { result in
      if case .failure(let error) = result { failure.withLock { $0 = error } }
    }
    writer.flush()
    #expect(failure.withLock { $0 } == .closedByPeer)
    #expect(stream.isShutDown)
  }

  /// While a write is blocked, a queued message that is withdrawn is never written (and its
  /// completion never runs), one whose deadline passes while it waits is skipped with
  /// `timedOut`, and the message being written can no longer be withdrawn and is written whole.
  @Test func writerSkipsWithdrawnAndExpiredMessages() async throws {
    let stream = FakeByteStream()
    let writer = WebSocketWriter(stream: stream, writeTimeout: .seconds(30))
    let outcomes = WriteOutcomeLog()
    stream.holdWrites()
    let first = writer.enqueueBinary([1], completion: outcomes.recorder("first"))
    try await waitUntil("the first write is blocked") { stream.blockedWrites == 1 }
    let withdrawn = writer.enqueueBinary([2], completion: outcomes.recorder("withdrawn"))
    let deadline = ContinuousClock.now + .milliseconds(20)
    let expired = writer.enqueueBinary(
      [3], deadline: deadline, completion: outcomes.recorder("expired"))
    let timely = writer.enqueueBinary(
      [4], deadline: .now + .seconds(30), completion: outcomes.recorder("timely"))
    #expect(withdrawn.withdraw())
    #expect(!first.withdraw())
    try await waitUntil("the deadline passed") { ContinuousClock.now >= deadline }
    stream.releaseWrites()
    try await waitUntil("the last message was written") { outcomes.all["timely"] != nil }
    #expect(outcomes.all == ["first": .written, "expired": .failed(.timedOut), "timely": .written])
    #expect(try WebSocketReaderTests.clientFrames(stream).map(\.payload) == [[1], [4]])
    #expect(first.currentState == .written)
    #expect(withdrawn.currentState == .withdrawn)
    #expect(expired.currentState == .skipped)
    #expect(expired.withdraw())
    #expect(!timely.withdraw())
  } // End of func writerSkipsWithdrawnAndExpiredMessages()

  /// Binary messages queued before a close frame but not yet started when it was queued are
  /// skipped with `shutDown`; the close frame still goes out.
  @Test func unsentDataBeforeACloseIsSkipped() async throws {
    let stream = FakeByteStream()
    let writer = WebSocketWriter(stream: stream, writeTimeout: .seconds(30))
    let outcomes = WriteOutcomeLog()
    stream.holdWrites()
    writer.enqueueBinary([1], completion: outcomes.recorder("first"))
    try await waitUntil("the first write is blocked") { stream.blockedWrites == 1 }
    let second = writer.enqueueBinary([2], completion: outcomes.recorder("second"))
    #expect(writer.enqueueClose(code: 1000, completion: outcomes.recorder("close")))
    stream.releaseWrites()
    try await waitUntil("the close frame was written") { outcomes.all["close"] != nil }
    #expect(outcomes.all == ["first": .written, "second": .failed(.shutDown), "close": .written])
    let frames = try WebSocketReaderTests.clientFrames(stream)
    #expect(frames.map(\.opcode) == [.binary, .close])
    #expect(frames.first?.payload == [1])
    #expect(second.currentState == .skipped)
  } // End of func unsentDataBeforeACloseIsSkipped()

  /// Exactly 1000–1003, 1007–1014 and 3000–4999 may appear in a close frame on the wire.
  @Test func wireCloseCodes() {
    let allowed = (UInt16.min...UInt16.max).filter(WebSocketFrame.isValidWireCloseCode)
    let expected =
      Array(UInt16(1000)...1003) + Array(UInt16(1007)...1014)
      + Array(UInt16(3000)...4999)
    #expect(allowed == expected)
  }

  /// UTF-8 validation accepts well-formed text and refuses stray continuation bytes, invalid
  /// lead bytes, overlong forms, surrogates, values above U+10FFFF and truncated sequences.
  @Test func utf8Validation() {
    for valid in ["", "bye", "é", "€", "𝄞", "normal closure ✓"] {
      #expect(WebSocketFrame.isValidUTF8(Array(valid.utf8)), "\(valid)")
    }
    let invalid: [[UInt8]] = [
      [0x80], [0xFF], [0xC0, 0xAF], [0xE0, 0x80, 0xAF], [0xED, 0xA0, 0x80],
      [0xF4, 0x90, 0x80, 0x80], [0xE2, 0x82], [0x41, 0xC3],
    ]
    for bytes in invalid {
      #expect(!WebSocketFrame.isValidUTF8(bytes), "\(bytes)")
    }
  } // End of func utf8Validation()

  /// Malformed or forbidden server frames and the rule each breaks.
  @Test(arguments: [
    ([0xC2, 0x00], "reserved bits"),
    ([0x83, 0x00], "reserved opcode"),
    ([0x82, 0x80, 1, 2, 3, 4], "masked"),
    ([0x09, 0x00], "fragmented"),
    ([0x89, 126, 0x00, 0x7E], "longer than 125"),
    ([0x82, 127, 0x80, 0, 0, 0, 0, 0, 0, 0], "most significant bit"),
  ])
  func rejectsMalformedServerFrames(bytes: [UInt8], rule: String) {
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
    decoder.append(bytes)
    let error = #expect(throws: WebSocketError.self) {
      _ = try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max)
    }
    guard case .protocolViolation(let detail)? = error else {
      Issue.record("expected a protocol violation, got \(String(describing: error))")
      return
    }
    #expect(detail.contains(rule))
  } // End of func rejectsMalformedServerFrames(bytes:rule:)

  /// A data frame longer than the limit is refused as soon as its header is complete, before
  /// any payload arrives.
  @Test func oversizedFrameRejectedFromItsHeader() {
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
    decoder.append([0x82, 127, 0, 0, 0, 0, 0x01, 0x00, 0x00, 0x01])
    #expect(throws: WebSocketError.messageTooLarge(limit: 16 * 1024 * 1024)) {
      _ = try decoder.nextFrame(
        maximumDataPayloadLength: 16 * 1024 * 1024, messageLimit: 16 * 1024 * 1024)
    }
  }

  /// A client frame without a mask is refused by the server-side decoder the tests use.
  @Test func serverSideRequiresMasking() {
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: true)
    decoder.append(WebSocketFrame.encode(opcode: .binary, payload: [1], maskingKey: nil))
    #expect(throws: WebSocketError.protocolViolation("client frame is not masked")) {
      _ = try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max)
    }
  }

  /// Every split of a frame's bytes decodes once all bytes are in, and not before.
  @Test(arguments: [0, 5, 200, 70_000])
  func decodesAtEverySplitPoint(length: Int) throws {
    let payload = (0..<length).map { UInt8(truncatingIfNeeded: $0) }
    let frame = WebSocketFrame.encode(opcode: .binary, payload: payload, maskingKey: nil)
    let splits = length > 1000 ? [1, 2, 3, 9, 10, 11, frame.count - 1] : Array(1..<frame.count)
    for split in splits {
      var decoder = WebSocketFrameDecoder(expectsMaskedFrames: false)
      decoder.append(frame[..<split])
      #expect(try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max) == nil)
      decoder.append(frame[split...])
      let decoded = try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max)
      #expect(decoded?.payload == payload)
    }
  } // End of func decodesAtEverySplitPoint(length:)
}
