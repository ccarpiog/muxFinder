import CryptoKit
import Foundation

/// The client side of the WebSocket opening handshake (RFC 6455 §4).
///
/// The request is built from fixed header names and values the caller has already validated;
/// `init` refuses any value containing a byte outside printable ASCII, so nothing can inject a
/// header line. The reply may arrive across several reads, and frame bytes may follow its blank
/// line in the same read; those are returned to the caller.
struct WebSocketHandshake: Sendable {
  /// The GUID RFC 6455 appends to the key before hashing it into `Sec-WebSocket-Accept`.
  static let acceptGUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"
  /// The longest reply head (status line and headers) accepted.
  static let maximumResponseHeadLength = 16 * 1024
  /// How many bytes one handshake read asks for.
  static let readChunkLength = 4096

  /// A parsed reply head.
  struct Response: Sendable, Hashable {
    /// The HTTP status code.
    var status: Int
    /// Header names and values in order, as received (values trimmed).
    var headers: [Header]

    /// The value of the last header named `name` (case-insensitive), if any.
    func value(named name: String) -> String? {
      headers.last { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
  }

  /// One header line.
  struct Header: Sendable, Hashable {
    /// The header name.
    var name: String
    /// The header value.
    var value: String
  }

  /// The `Sec-WebSocket-Key`: 16 random bytes, base64-encoded.
  let key: String
  /// The subprotocol requested in `Sec-WebSocket-Protocol`.
  let subprotocol: String
  /// The request's header lines after the request line, in order.
  let headers: [Header]

  /// Builds a request for `GET /` on `host` asking for `subprotocol`, followed by
  /// `extraHeaders` in order.
  ///
  /// - Throws: `protocolViolation` if a header name or value contains anything but printable
  ///   ASCII (and, for names, a space or colon).
  init(
    host: String = "localhost",
    subprotocol: String,
    extraHeaders: [Header],
    key: String = WebSocketHandshake.makeKey()
  ) throws(WebSocketError) {
    self.key = key
    self.subprotocol = subprotocol
    let headers =
      [
        Header(name: "Host", value: host),
        Header(name: "Upgrade", value: "websocket"),
        Header(name: "Connection", value: "Upgrade"),
        Header(name: "Sec-WebSocket-Key", value: key),
        Header(name: "Sec-WebSocket-Version", value: "13"),
        Header(name: "Sec-WebSocket-Protocol", value: subprotocol),
      ] + extraHeaders
    for header in headers {
      guard Self.isValidHeaderName(header.name), Self.isValidHeaderValue(header.value) else {
        throw .protocolViolation("a handshake header contains a forbidden character")
      }
    }
    self.headers = headers
  } // End of init(host:subprotocol:extraHeaders:key:)

  /// A fresh random key: 16 bytes from the system's secure generator, base64-encoded.
  static func makeKey() -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).base64EncodedString()
  }

  /// The `Sec-WebSocket-Accept` value a server must answer `key` with.
  static func acceptValue(forKey key: String) -> String {
    let digest = Insecure.SHA1.hash(data: Data((key + acceptGUID).utf8))
    return Data(digest).base64EncodedString()
  }

  /// Whether `name` is a header name this client may send: printable ASCII without spaces or
  /// colons.
  static func isValidHeaderName(_ name: String) -> Bool {
    !name.isEmpty && name.utf8.allSatisfy { $0 > 0x20 && $0 < 0x7F && $0 != UInt8(ascii: ":") }
  }

  /// Whether `value` is a header value this client may send: printable ASCII, spaces allowed,
  /// no line breaks or other control characters.
  static func isValidHeaderValue(_ value: String) -> Bool {
    value.utf8.allSatisfy { $0 >= 0x20 && $0 < 0x7F }
  }

  /// The request bytes: request line, header lines and the blank line.
  var requestBytes: [UInt8] {
    var text = "GET / HTTP/1.1\r\n"
    for header in headers { text += "\(header.name): \(header.value)\r\n" }
    text += "\r\n"
    return Array(text.utf8)
  }

  /// Sends the request on `stream`, reads the reply head and validates it.
  ///
  /// - Returns: the reply and the bytes that followed its blank line (the start of the first
  ///   frames, if the server sent any at once).
  /// - Throws: `handshakeRejected` for a status other than 101, `protocolViolation` for a
  ///   malformed or invalid reply, `timedOut` at the deadline, `endOfStream` if the server
  ///   closes the connection before the reply head is complete.
  func perform(
    on stream: any ByteStream,
    deadline: ContinuousClock.Instant
  ) throws(WebSocketError) -> (response: Response, remainder: [UInt8]) {
    do throws(ByteStreamError) {
      try stream.write(requestBytes, deadline: deadline)
    } catch .timedOut {
      throw .timedOut
    } catch {
      throw .transport(error)
    }
    var received: [UInt8] = []
    while true {
      if let parsed = try Self.parseResponseHead(received) {
        try validate(parsed.response)
        return (parsed.response, Array(received[parsed.headLength...]))
      }
      let chunk: [UInt8]
      do throws(ByteStreamError) {
        chunk = try stream.read(maximumLength: Self.readChunkLength, deadline: deadline)
      } catch .timedOut {
        throw .timedOut
      } catch {
        throw .transport(error)
      }
      if chunk.isEmpty { throw .endOfStream }
      received += chunk
    } // End of loop until the reply head is complete
  } // End of func perform(on:deadline:)

  /// Parses a reply head if `bytes` contains all of it (up to and including the blank line).
  /// Returns the reply and the head's length in bytes, or `nil` when more bytes are needed.
  static func parseResponseHead(
    _ bytes: [UInt8]
  ) throws(WebSocketError) -> (response: Response, headLength: Int)? {
    let terminator: [UInt8] = [13, 10, 13, 10]
    guard let end = bytes.firstRange(of: terminator) else {
      guard bytes.count <= maximumResponseHeadLength else {
        throw .protocolViolation("handshake reply head is too long")
      }
      return nil
    }
    guard end.lowerBound <= maximumResponseHeadLength else {
      throw .protocolViolation("handshake reply head is too long")
    }
    let head = String(decoding: bytes[..<end.lowerBound], as: UTF8.self)
    var lines = head.components(separatedBy: "\r\n")[...]
    let statusLine = lines.popFirst() ?? ""
    let parts = statusLine.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: false)
    guard parts.count >= 2, parts[0].hasPrefix("HTTP/1."), parts[1].count == 3,
      parts[1].allSatisfy(\.isASCII), let status = Int(parts[1])
    else {
      throw .protocolViolation("handshake reply has a malformed status line")
    }
    var headers: [Header] = []
    for line in lines {
      guard let colon = line.firstIndex(of: ":"), colon != line.startIndex else {
        throw .protocolViolation("handshake reply has a malformed header line")
      }
      let name = String(line[..<colon])
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      headers.append(Header(name: name, value: value))
    } // End of loop over header lines
    return (Response(status: status, headers: headers), end.upperBound)
  } // End of func parseResponseHead(_:)

  /// Checks a reply head: status 101, `Upgrade: websocket`, a `Connection` header with the
  /// `upgrade` token, the right `Sec-WebSocket-Accept`, no subprotocol other than the one
  /// requested, and no extensions.
  func validate(_ response: Response) throws(WebSocketError) {
    guard response.status == 101 else { throw .handshakeRejected(status: response.status) }
    guard response.value(named: "Upgrade")?.lowercased() == "websocket" else {
      throw .protocolViolation("handshake reply lacks Upgrade: websocket")
    }
    let connectionTokens = (response.value(named: "Connection") ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    guard connectionTokens.contains("upgrade") else {
      throw .protocolViolation("handshake reply lacks Connection: Upgrade")
    }
    guard response.value(named: "Sec-WebSocket-Accept") == Self.acceptValue(forKey: key) else {
      throw .protocolViolation("handshake reply has a wrong Sec-WebSocket-Accept")
    }
    if let chosen = response.value(named: "Sec-WebSocket-Protocol"), chosen != subprotocol {
      throw .protocolViolation("handshake reply selected a different subprotocol")
    }
    if let extensions = response.value(named: "Sec-WebSocket-Extensions"), !extensions.isEmpty {
      throw .protocolViolation("handshake reply selected an extension that was not offered")
    }
  } // End of func validate(_:)
}
