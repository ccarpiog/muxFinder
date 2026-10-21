import Foundation
import Testing

@testable import MuxFinderCore

/// The opening handshake against a fake stream: the request iTerm2 needs, replies split over
/// reads, frame bytes after the reply, and every way a reply is refused.
@Suite("WebSocket handshake")
struct WebSocketHandshakeTests {
  /// Test credentials.
  static let credentials = try! ITerm2Credentials(cookie: "test-cookie", key: "test-key")

  /// The handshake muxFinder sends to iTerm2.
  static func handshake() throws -> WebSocketHandshake {
    try ITerm2APIClient.handshake(credentials: credentials)
  }

  /// A valid reply for `handshake`, optionally with extra header lines.
  static func reply(for handshake: WebSocketHandshake, extra: String = "") -> [UInt8] {
    let accept = WebSocketHandshake.acceptValue(forKey: handshake.key)
    return Array(
      ("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: \(accept)\r\n\(extra)\r\n").utf8)
  }

  /// The RFC 6455 §1.3 example key and accept value.
  @Test func acceptValueMatchesTheRFCExample() {
    #expect(
      WebSocketHandshake.acceptValue(forKey: "dGhlIHNhbXBsZSBub25jZQ==")
        == "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
  }

  /// The request has every header of the handshake verified against iTerm2, in order, with a
  /// random 16-byte key.
  @Test func requestCarriesEveryVerifiedHeader() throws {
    let handshake = try Self.handshake()
    let text = String(decoding: handshake.requestBytes, as: UTF8.self)
    let expected =
      "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Key: \(handshake.key)\r\nSec-WebSocket-Version: 13\r\n"
      + "Sec-WebSocket-Protocol: api.iterm2.com\r\nOrigin: ws://localhost/\r\n"
      + "x-iterm2-library-version: python 2.11\r\nx-iterm2-disable-auth-ui: true\r\n"
      + "x-iterm2-cookie: test-cookie\r\nx-iterm2-key: test-key\r\n"
      + "x-iterm2-advisory-name: muxFinder\r\n\r\n"
    #expect(text == expected)
    #expect(Data(base64Encoded: handshake.key)?.count == 16)
    #expect(try Self.handshake().key != handshake.key)
  }

  /// Header values with line breaks or other control characters are refused.
  @Test(arguments: ["a\r\nInjected: yes", "tab\there", "nul\u{0}", "ünï"])
  func refusesUnsafeHeaderValues(value: String) {
    #expect(throws: WebSocketError.self) {
      _ = try WebSocketHandshake(
        subprotocol: "api.iterm2.com", extraHeaders: [.init(name: "x-test", value: value)])
    }
  }

  /// A reply delivered one byte per read, followed by frame bytes, completes the handshake and
  /// returns exactly the frame bytes.
  @Test func replySplitAcrossReads() throws {
    let handshake = try Self.handshake()
    let stream = FakeByteStream()
    stream.deliverBytewise(Self.reply(for: handshake, extra: "X-iTerm2-Protocol-Version: 1.21\r\n"))
    let result = try handshake.perform(on: stream, deadline: .now + .seconds(5))
    #expect(result.response.status == 101)
    #expect(result.response.value(named: "x-iterm2-protocol-version") == "1.21")
    #expect(result.remainder.isEmpty)
    #expect(stream.written == handshake.requestBytes)
  }

  /// Frame bytes in the same read as the end of the reply are handed on, and the reader starts
  /// with them.
  @Test func frameBytesInTheSameReadAsTheHeaderTail() throws {
    let handshake = try Self.handshake()
    let frame = WebSocketFrame.encode(opcode: .binary, payload: [7, 8, 9], maskingKey: nil)
    let reply = Self.reply(for: handshake)
    let stream = FakeByteStream(chunks: [Array(reply[..<10]), Array(reply[10...]) + frame])
    let result = try handshake.perform(on: stream, deadline: .now + .seconds(5))
    #expect(result.remainder == frame)
    let writer = WebSocketWriter(stream: stream, writeTimeout: .seconds(1))
    var reader = WebSocketReader(stream: stream, writer: writer, initialBytes: result.remainder)
    #expect(try reader.receiveMessage(deadline: .now + .seconds(1)) == [7, 8, 9])
  }

  /// Replies that must be refused, and the error each gives.
  @Test(arguments: [
    ("HTTP/1.1 401 Unauthorized\r\n\r\n", WebSocketError.handshakeRejected(status: 401)),
    ("HTTP/1.1 406 Not Acceptable\r\n\r\n", .handshakeRejected(status: 406)),
    ("HTTP/1.1 500 Internal Server Error\r\n\r\n", .handshakeRejected(status: 500)),
    (
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: AAAAAAAAAAAAAAAAAAAAAAAAAAA=\r\n\r\n",
      .protocolViolation("handshake reply has a wrong Sec-WebSocket-Accept")
    ),
    (
      "HTTP/1.1 101 OK\r\nConnection: Upgrade\r\n\r\n",
      .protocolViolation("handshake reply lacks Upgrade: websocket")
    ),
    (
      "HTTP/1.1 101 OK\r\nUpgrade: websocket\r\n\r\n",
      .protocolViolation("handshake reply lacks Connection: Upgrade")
    ),
    ("garbage\r\n\r\n", .protocolViolation("handshake reply has a malformed status line")),
    (
      "HTTP/1.1 1010 Weird\r\n\r\n",
      .protocolViolation("handshake reply has a malformed status line")
    ),
    (
      "HTTP/1.1 101 OK\r\nno colon here\r\n\r\n",
      .protocolViolation("handshake reply has a malformed header line")
    ),
  ])
  func refusedReplies(reply: String, expected: WebSocketError) throws {
    let handshake = try Self.handshake()
    let stream = FakeByteStream(chunks: [Array(reply.utf8)])
    #expect(throws: expected) {
      _ = try handshake.perform(on: stream, deadline: .now + .seconds(5))
    }
  }

  /// A reply choosing another subprotocol or an extension is refused.
  @Test(arguments: ["Sec-WebSocket-Protocol: other\r\n", "Sec-WebSocket-Extensions: x\r\n"])
  func refusesUnrequestedNegotiation(extra: String) throws {
    let handshake = try Self.handshake()
    let stream = FakeByteStream(chunks: [Self.reply(for: handshake, extra: extra)])
    #expect(throws: WebSocketError.self) {
      _ = try handshake.perform(on: stream, deadline: .now + .seconds(5))
    }
  }

  /// The status-to-error mapping: 401 is `authRejected`; others are protocol errors.
  @Test func handshakeStatusMapping() {
    #expect(ITerm2Error(WebSocketError.handshakeRejected(status: 401)) == .authRejected)
    #expect(ITerm2Error(WebSocketError.handshakeRejected(status: 406)).kind == "protocolError")
    #expect(ITerm2Error(WebSocketError.handshakeRejected(status: 403)).kind == "protocolError")
    #expect(ITerm2Error(WebSocketError.endOfStream) == .disconnected)
    #expect(ITerm2Error(WebSocketError.timedOut) == .timedOut)
  }

  /// The server closing before the reply is complete, a reply that never ends, and a server
  /// that never answers.
  @Test func incompleteReplies() throws {
    let handshake = try Self.handshake()
    let closing = FakeByteStream(chunks: [Array("HTTP/1.1 101 Swi".utf8)])
    closing.deliverEndOfStream()
    #expect(throws: WebSocketError.endOfStream) {
      _ = try handshake.perform(on: closing, deadline: .now + .seconds(5))
    }
    let endless = FakeByteStream(chunks: [Array(repeating: UInt8(ascii: "a"), count: 17_000)])
    #expect(throws: WebSocketError.protocolViolation("handshake reply head is too long")) {
      _ = try handshake.perform(on: endless, deadline: .now + .seconds(5))
    }
    let silent = FakeByteStream()
    let start = ContinuousClock.now
    #expect(throws: WebSocketError.timedOut) {
      _ = try handshake.perform(on: silent, deadline: .now + .milliseconds(100))
    }
    #expect(ContinuousClock.now - start >= .milliseconds(100))
  } // End of func incompleteReplies()
}
