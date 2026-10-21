import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The real POSIX transport, exercised with `socketpair()` and private sockets under `/tmp`;
/// never iTerm2's socket.
@Suite("Unix socket stream")
struct UnixSocketStreamTests {
  /// Bytes written on one end arrive on the other, in both directions.
  @Test func bytesCrossThePair() async throws {
    let (left, right) = try UnixSocketStream.makePair()
    try left.write([1, 2, 3], deadline: .now + .seconds(1))
    #expect(try right.read(maximumLength: 64, deadline: .now + .seconds(1)) == [1, 2, 3])
    let writer = Task {
      try await DedicatedThread.run(name: "test-writer") {
        try right.write(Array(repeating: 7, count: 200_000), deadline: .now + .seconds(5))
      }
    }
    let received = try await DedicatedThread.run(name: "test-reader") {
      var received = 0
      while received < 200_000 {
        received += try left.read(maximumLength: 65_536, deadline: .now + .seconds(5)).count
      }
      return received
    }
    try await writer.value
    #expect(received == 200_000)
  } // End of func bytesCrossThePair()

  /// A read with nothing to read times out at its deadline.
  @Test func readTimesOut() throws {
    let (left, right) = try UnixSocketStream.makePair()
    let start = ContinuousClock.now
    #expect(throws: ByteStreamError.timedOut) {
      _ = try left.read(maximumLength: 16, deadline: .now + .milliseconds(80))
    }
    #expect(ContinuousClock.now - start >= .milliseconds(80))
    withExtendedLifetime(right) {}
  }

  /// `shutDown()` from another thread wakes a blocked read, which reports end of stream; later
  /// writes fail.
  @Test func shutDownWakesABlockedRead() async throws {
    let (left, right) = try UnixSocketStream.makePair()
    let start = ContinuousClock.now
    let reader = Task {
      try await DedicatedThread.run(name: "test-reader") {
        try left.read(maximumLength: 16, deadline: .now + .seconds(10))
      }
    }
    try await Task.sleep(for: .milliseconds(50))
    left.shutDown()
    #expect(try await reader.value == [])
    #expect(ContinuousClock.now - start < .seconds(5))
    #expect(throws: ByteStreamError.shutDown) {
      try left.write([1], deadline: .now + .seconds(1))
    }
    withExtendedLifetime(right) {}
  }

  /// When the peer goes away, reads report end of stream and writes fail with `closedByPeer`
  /// instead of raising `SIGPIPE`.
  @Test func peerCloseIsEndOfStream() throws {
    let left = try UnixSocketStream.makePair().0
    #expect(try left.read(maximumLength: 16, deadline: .now + .seconds(1)) == [])
    #expect(throws: ByteStreamError.closedByPeer) {
      try left.write(Array(repeating: 1, count: 1024), deadline: .now + .seconds(1))
    }
  }

  /// Connecting to a missing path, or to a socket file nobody listens on, is `apiDisabled`.
  @Test func unreachableSocketsAreAPIDisabled() throws {
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let missing = directory.appending(path: "missing").path(percentEncoded: false)
    #expect(throws: ITerm2Error.apiDisabled) {
      _ = try UnixSocketConnector(path: missing).connect(deadline: .now + .seconds(1))
    }
    #expect(!UnixSocketConnector(path: missing).endpointExists())

    let stale = directory.appending(path: "stale").path(percentEncoded: false)
    try Self.bindAndClose(stale)
    #expect(UnixSocketConnector(path: stale).endpointExists())
    #expect(throws: ITerm2Error.apiDisabled) {
      _ = try UnixSocketConnector(path: stale).connect(deadline: .now + .seconds(1))
    }
  } // End of func unreachableSocketsAreAPIDisabled()

  /// A path too long for `sockaddr_un` is refused before any system call.
  @Test func overlongPath() {
    let path = "/tmp/" + String(repeating: "x", count: 200)
    #expect(throws: ByteStreamError.systemCallFailed(name: "connect", errno: ENAMETOOLONG)) {
      _ = try UnixSocketStream.connect(toPath: path, deadline: .now + .seconds(1))
    }
  }

  /// A full WebSocket exchange over the real transport: a server thread on the other end of a
  /// socket pair answers the handshake and echoes one request id back.
  @Test func connectionOverARealSocketPair() async throws {
    let (client, server) = try UnixSocketStream.makePair()
    let serverThread = Task {
      try await DedicatedThread.run(name: "test-server") { try Self.serveOneRequest(on: server) }
    }
    let handshake = try ITerm2APIClient.handshake(
      credentials: try ITerm2Credentials(cookie: "c", key: "k"))
    let opened = try await DedicatedThread.run(name: "test-handshake") {
      try handshake.perform(on: client, deadline: .now + .seconds(5)).remainder
    }
    let connection = await ITerm2Connection.start(
      stream: client, initialBytes: opened, protocolVersion: nil,
      settings: fastConnectionSettings)
    let response = try await connection.send(.listSessions(.init()))
    #expect(response == .listSessions(.init(windows: [.init(windowID: "socketpair-window")])))
    let closing = Task { await connection.close() }
    try await serverThread.value
    await closing.value
    #expect(await !connection.isOpen)
  } // End of func connectionOverARealSocketPair()

  /// The server side of `connectionOverARealSocketPair`: answers the handshake, reads one
  /// request and answers it, then answers the client's close.
  static func serveOneRequest(on stream: UnixSocketStream) throws {
    let deadline = ContinuousClock.now + .seconds(5)
    var received: [UInt8] = []
    let terminator: [UInt8] = [13, 10, 13, 10]
    while received.firstRange(of: terminator) == nil {
      received += try stream.read(maximumLength: 4096, deadline: deadline)
    }
    let head = String(decoding: received, as: UTF8.self)
    let keyLine = head.components(separatedBy: "\r\n").first { $0.hasPrefix("Sec-WebSocket-Key:") }
    let key = String(keyLine?.dropFirst("Sec-WebSocket-Key: ".count) ?? "")
    let reply =
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
      + "Sec-WebSocket-Accept: \(WebSocketHandshake.acceptValue(forKey: key))\r\n\r\n"
    try stream.write(Array(reply.utf8), deadline: deadline)
    var decoder = WebSocketFrameDecoder(expectsMaskedFrames: true)
    decoder.append(received[received.firstRange(of: terminator)!.upperBound...])
    var frames: [WebSocketFrame] = []
    while frames.count < 2 {
      if let frame = try decoder.nextFrame(maximumDataPayloadLength: .max, messageLimit: .max) {
        frames.append(frame)
        if frame.opcode == .binary {
          let request = try ClientRequest(frame.payload)
          let response = ServerMessage.listSessions(id: request.id, window: "socketpair-window")
          try stream.write(
            WebSocketFrame.encode(opcode: .binary, payload: response, maskingKey: nil),
            deadline: deadline)
        }
        continue
      }
      decoder.append(try stream.read(maximumLength: 4096, deadline: deadline))
    } // End of loop over the client's frames
    #expect(frames.map(\.opcode) == [.binary, .close])
    try stream.write(
      WebSocketFrame.encode(
        opcode: .close, payload: WebSocketFrame.closePayload(code: 1000), maskingKey: nil),
      deadline: deadline)
  } // End of func serveOneRequest(on:)

  /// Creates a Unix socket file at `path` with no listener behind it.
  static func bindAndClose(_ path: String) throws {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    #expect(descriptor >= 0)
    defer { close(descriptor) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8)) }
    let result = withUnsafePointer(to: &address) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
      }
    }
    #expect(result == 0)
  } // End of func bindAndClose(_:)
}
