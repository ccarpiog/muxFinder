import Foundation

/// Why the WebSocket layer stopped.
enum WebSocketError: Error, Sendable, Hashable {
  /// Nothing complete arrived before the deadline. Partial input is kept, so the call can be
  /// repeated.
  case timedOut
  /// The stream ended without a close handshake: the peer went away, or this side shut the
  /// stream down.
  case endOfStream
  /// The connection ended with a close handshake. `code` is the peer's status code, if it sent
  /// one.
  case closed(code: UInt16?)
  /// The peer broke RFC 6455 or the handshake rules. The text names the rule, never the data.
  case protocolViolation(String)
  /// A message (all its fragments together) is longer than the limit, in bytes.
  case messageTooLarge(limit: Int)
  /// The server answered the opening handshake with an HTTP status other than 101.
  case handshakeRejected(status: Int)
  /// The byte stream failed.
  case transport(ByteStreamError)
}

/// Why a received close frame's payload is invalid, and the status code to answer it with.
struct InvalidClosePayload: Error, Sendable, Hashable {
  /// The close code to send back: 1002 (protocol error) or 1007 (invalid payload data).
  let replyCode: UInt16
  /// The rule the payload breaks; it never quotes the payload.
  let rule: String
}

/// A WebSocket frame opcode (RFC 6455 §5.2). Values 3–7 and 11–15 are reserved and rejected.
enum WebSocketOpcode: UInt8, Sendable, Hashable {
  /// Continues a fragmented message.
  case continuation = 0x0
  /// Starts a UTF-8 text message.
  case text = 0x1
  /// Starts a binary message.
  case binary = 0x2
  /// Starts or answers the close handshake.
  case close = 0x8
  /// Asks the peer for a pong with the same payload.
  case ping = 0x9
  /// Answers a ping.
  case pong = 0xA

  /// Whether this is a control frame (close, ping, pong). Control frames are never fragmented
  /// and carry at most 125 bytes, but may arrive between the fragments of a message.
  var isControl: Bool { rawValue & 0x8 != 0 }
}

/// One WebSocket frame.
struct WebSocketFrame: Sendable, Hashable {
  /// The longest payload a control frame may carry.
  static let maximumControlPayloadLength = 125
  /// The status code for a normal closure.
  static let normalClosure: UInt16 = 1000
  /// The status code for closing because the peer broke the protocol.
  static let protocolErrorClosure: UInt16 = 1002
  /// The status code for closing because received data is not consistent with its type (here:
  /// a close reason that is not valid UTF-8).
  static let invalidPayloadClosure: UInt16 = 1007
  /// The status code for closing because a message is too big to process.
  static let messageTooBigClosure: UInt16 = 1009

  /// FIN: whether this is the last frame of its message.
  var isFinal: Bool
  /// The opcode.
  var opcode: WebSocketOpcode
  /// The payload, already unmasked.
  var payload: [UInt8]
  /// The masking key the frame carried on the wire; `nil` for unmasked frames.
  var maskingKey: [UInt8]?

  /// Creates a frame.
  init(isFinal: Bool = true, opcode: WebSocketOpcode, payload: [UInt8], maskingKey: [UInt8]? = nil)
  {
    self.isFinal = isFinal
    self.opcode = opcode
    self.payload = payload
    self.maskingKey = maskingKey
  }

  /// The payload of a close frame carrying `code`, or an empty payload for `nil`.
  static func closePayload(code: UInt16?) -> [UInt8] {
    guard let code else { return [] }
    return [UInt8(code >> 8), UInt8(code & 0xFF)]
  }

  /// The status code in a close frame's payload, or `nil` when it carries none. Does not
  /// validate anything; received close frames go through `receivedCloseCode(in:)`.
  static func closeCode(in payload: [UInt8]) -> UInt16? {
    guard payload.count >= 2 else { return nil }
    return UInt16(payload[0]) << 8 | UInt16(payload[1])
  }

  /// Validates the payload of a close frame received from the peer (RFC 6455 §5.5.1, §7.4)
  /// and returns its status code, or `nil` for an empty payload. A non-empty payload must hold
  /// a two-byte status code that may appear on the wire (`isValidWireCloseCode(_:)`), followed
  /// by a reason that is valid UTF-8.
  ///
  /// - Throws: `InvalidClosePayload` with reply code 1002 for a one-byte payload or a code that
  ///   must not appear on the wire, and 1007 for a reason that is not valid UTF-8.
  static func receivedCloseCode(in payload: [UInt8]) throws(InvalidClosePayload) -> UInt16? {
    if payload.isEmpty { return nil }
    guard let code = closeCode(in: payload) else {
      throw InvalidClosePayload(
        replyCode: protocolErrorClosure, rule: "close frame payload is a single byte")
    }
    guard isValidWireCloseCode(code) else {
      throw InvalidClosePayload(
        replyCode: protocolErrorClosure,
        rule: "close frame carries a status code that must not appear on the wire")
    }
    guard isValidUTF8(payload.dropFirst(2)) else {
      throw InvalidClosePayload(
        replyCode: invalidPayloadClosure, rule: "close frame reason is not valid UTF-8")
    }
    return code
  } // End of func receivedCloseCode(in:)

  /// Whether `code` may appear in a close frame on the wire (RFC 6455 §7.4.1 and §7.4.2, and the
  /// IANA registry): 1000–1003, 1007–1014 and 3000–4999. Codes below 1000 are unused, 1004 is
  /// reserved, 1005, 1006 and 1015 must never be sent, 1016–2999 are unassigned, and 5000 and
  /// above are undefined.
  static func isValidWireCloseCode(_ code: UInt16) -> Bool {
    (1000...1003).contains(code) || (1007...1014).contains(code) || (3000...4999).contains(code)
  }

  /// Whether `bytes` are well-formed UTF-8: no stray continuation bytes, overlong forms,
  /// surrogates, values above U+10FFFF or truncated sequences.
  static func isValidUTF8(_ bytes: some Collection<UInt8>) -> Bool {
    var decoder = Unicode.UTF8()
    var iterator = bytes.makeIterator()
    while true {
      switch decoder.decode(&iterator) {
      case .scalarValue: continue
      case .emptyInput: return true
      case .error: return false
      }
    }
  } // End of func isValidUTF8(_:)

  /// Encodes a frame. With `maskingKey` (4 bytes), the mask bit is set and the payload is
  /// masked, as every client-to-server frame must be (RFC 6455 §5.3). The payload length uses
  /// the shortest of the three encodings: 7 bits up to 125, 16 bits up to 65,535, 64 bits beyond.
  static func encode(
    opcode: WebSocketOpcode,
    payload: [UInt8],
    isFinal: Bool = true,
    maskingKey: [UInt8]?
  ) -> [UInt8] {
    var frame: [UInt8] = []
    frame.reserveCapacity(payload.count + 14)
    frame.append((isFinal ? 0x80 : 0) | opcode.rawValue)
    let maskBit: UInt8 = maskingKey == nil ? 0 : 0x80
    if payload.count <= 125 {
      frame.append(maskBit | UInt8(payload.count))
    } else if payload.count <= 0xFFFF {
      frame.append(maskBit | 126)
      frame.append(UInt8(payload.count >> 8))
      frame.append(UInt8(payload.count & 0xFF))
    } else {
      frame.append(maskBit | 127)
      let length = UInt64(payload.count)
      for shift in stride(from: 56, through: 0, by: -8) {
        frame.append(UInt8((length >> UInt64(shift)) & 0xFF))
      }
    }
    guard let maskingKey else { return frame + payload }
    precondition(maskingKey.count == 4, "a WebSocket masking key has 4 bytes")
    frame.append(contentsOf: maskingKey)
    for (index, byte) in payload.enumerated() {
      frame.append(byte ^ maskingKey[index & 3])
    }
    return frame
  } // End of func encode(opcode:payload:isFinal:maskingKey:)
}

/// Incremental WebSocket frame decoder: bytes go in as they arrive, whole frames come out.
///
/// A client decodes the server's frames, which must be unmasked; tests use the server side to
/// decode what the client wrote, which must be masked. Malformed frames throw
/// `WebSocketError.protocolViolation`; a data frame longer than the caller's limit throws
/// `messageTooLarge` as soon as its header is complete, before any payload is buffered.
struct WebSocketFrameDecoder: Sendable {
  /// Whether incoming frames must be masked (`true` when decoding a client's frames).
  let expectsMaskedFrames: Bool
  /// Received bytes; those before `start` are already decoded.
  private var buffer: [UInt8] = []
  /// Index of the first undecoded byte in `buffer`.
  private var start = 0

  /// Creates a decoder for frames written by a server (`expectsMaskedFrames: false`) or by a
  /// client (`true`).
  init(expectsMaskedFrames: Bool) {
    self.expectsMaskedFrames = expectsMaskedFrames
  }

  /// The number of received bytes not yet decoded into a frame.
  var bufferedByteCount: Int { buffer.count - start }

  /// Adds received bytes.
  mutating func append(_ bytes: some Collection<UInt8>) {
    if start == buffer.count {
      buffer.removeAll(keepingCapacity: true)
      start = 0
    } else if start >= 64 * 1024, start * 2 >= buffer.count {
      buffer.removeSubrange(..<start)
      start = 0
    }
    buffer.append(contentsOf: bytes)
  }

  /// Decodes the next frame if all of it has arrived, or returns `nil` when more bytes are
  /// needed. A data or continuation frame longer than `maximumDataPayloadLength` throws
  /// `messageTooLarge(limit: messageLimit)`; control frames have their own 125-byte limit.
  mutating func nextFrame(
    maximumDataPayloadLength: Int,
    messageLimit: Int
  ) throws(WebSocketError) -> WebSocketFrame? {
    let available = buffer.count - start
    guard available >= 2 else { return nil }
    let first = buffer[start]
    let second = buffer[start + 1]
    guard first & 0x70 == 0 else {
      throw .protocolViolation("frame uses reserved bits without a negotiated extension")
    }
    guard let opcode = WebSocketOpcode(rawValue: first & 0x0F) else {
      throw .protocolViolation("frame uses a reserved opcode")
    }
    let isMasked = second & 0x80 != 0
    guard isMasked == expectsMaskedFrames else {
      throw .protocolViolation(
        isMasked ? "server frame is masked" : "client frame is not masked")
    }
    guard let lengthField = try payloadLength(second & 0x7F, available) else { return nil }
    let (payloadLength, lengthFieldEnd) = lengthField
    if opcode.isControl {
      guard first & 0x80 != 0 else { throw .protocolViolation("control frame is fragmented") }
      guard payloadLength <= UInt64(WebSocketFrame.maximumControlPayloadLength) else {
        throw .protocolViolation("control frame payload is longer than 125 bytes")
      }
    } else if payloadLength > UInt64(max(0, maximumDataPayloadLength)) {
      throw .messageTooLarge(limit: messageLimit)
    }
    let headerLength = lengthFieldEnd + (isMasked ? 4 : 0)
    guard available - headerLength >= Int(payloadLength) else { return nil }
    let payloadStart = start + headerLength
    let payloadEnd = payloadStart + Int(payloadLength)
    var payload = Array(buffer[payloadStart..<payloadEnd])
    var maskingKey: [UInt8]?
    if isMasked {
      let key = Array(buffer[(start + lengthFieldEnd)..<(start + lengthFieldEnd + 4)])
      for index in payload.indices { payload[index] ^= key[index & 3] }
      maskingKey = key
    }
    start = payloadEnd
    return WebSocketFrame(
      isFinal: first & 0x80 != 0, opcode: opcode, payload: payload, maskingKey: maskingKey)
  } // End of func nextFrame(maximumDataPayloadLength:messageLimit:)

  /// Reads the payload length that follows the first two header bytes. Returns the length and
  /// the header offset just past the length field, or `nil` when the extended length has not
  /// fully arrived.
  private func payloadLength(
    _ code: UInt8,
    _ available: Int
  ) throws(WebSocketError) -> (UInt64, Int)? {
    switch code {
    case 126:
      guard available >= 4 else { return nil }
      return (UInt64(buffer[start + 2]) << 8 | UInt64(buffer[start + 3]), 4)
    case 127:
      guard available >= 10 else { return nil }
      var length: UInt64 = 0
      for offset in 2..<10 { length = length << 8 | UInt64(buffer[start + offset]) }
      guard length >> 63 == 0 else {
        throw .protocolViolation("frame length has its most significant bit set")
      }
      return (length, 10)
    default:
      return (UInt64(code), 2)
    }
  } // End of func payloadLength(_:_:)
}
