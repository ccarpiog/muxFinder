import Foundation
import Testing

@testable import MuxFinderCore

/// Request/response matching inside `ITerm2Connection`, against a fake peer: ids, out-of-order
/// responses, notifications, server errors, disconnects, timeouts and cancellation, and
/// requests abandoned before or while their frames are written.
@Suite("iTerm2 connection")
struct ITerm2ConnectionTests {
  /// A started connection on a fake stream, and the peer that plays iTerm2.
  static func makeConnection(
    settings: ITerm2Connection.Settings = fastConnectionSettings
  ) async -> (ITerm2Connection, FakeITerm2Peer) {
    let stream = FakeByteStream()
    let connection = await ITerm2Connection.start(
      stream: stream, initialBytes: [], protocolVersion: "1.21", settings: settings)
    return (connection, FakeITerm2Peer(stream: stream))
  }

  /// The window id a list-sessions response carries, or `nil` for anything else.
  static func windowID(_ response: ITerm2API.ServerOriginatedMessage.Response) -> String? {
    guard case .listSessions(let sessions) = response else { return nil }
    return sessions.windows.first?.windowID
  }

  /// Ids increase from 1; three concurrent requests answered in the order 3, 1, 2 each get
  /// their own response, with a notification and a response to an unknown id in between.
  @Test func outOfOrderResponsesWithNotifications() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let first = Task { try await connection.send(.listSessions(.init())) }
    var requests = [try await peer.nextRequest()]
    let second = Task { try await connection.send(.listSessions(.init())) }
    requests.append(try await peer.nextRequest())
    let third = Task { try await connection.send(.tmux(.listConnections)) }
    requests.append(try await peer.nextRequest())
    #expect(requests.map(\.id) == [1, 2, 3])
    #expect(requests.map(\.fieldNumber) == [106, 106, 124])

    try peer.respond(to: 3, withFixture: "tmux-list-connections-response")
    peer.send(ServerMessage.message(id: nil, fieldNumber: 1000))
    peer.send(ServerMessage.listSessions(id: 99, window: "unknown-id"))
    peer.send(ServerMessage.listSessions(id: 1, window: "window-1"))
    try peer.respond(to: 2, withFixture: "list-sessions-response")

    #expect(Self.windowID(try await first.value) == "window-1")
    let secondResponse = try await second.value
    let expectedSecond = try ITerm2Fixture.server("list-sessions-response").response
    #expect(secondResponse == expectedSecond)
    guard case .tmux(let tmux) = try await third.value,
      case .listConnections(let list)? = tmux.payload
    else {
      Issue.record("third request did not get the tmux response")
      return
    }
    #expect(list.count == 2)
    #expect(await connection.isOpen)
  } // End of func outOfOrderResponsesWithNotifications()

  /// A server `error` submessage fails only its own request, with iTerm2's text.
  @Test func serverErrorFailsOnlyItsRequest() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let failing = Task { try await connection.send(.listSessions(.init())) }
    let request = try await peer.nextRequest()
    peer.send(ServerMessage.error(id: request.id, "fixture-error"))
    await #expect(throws: ITerm2Error.requestFailed("fixture-error")) {
      _ = try await failing.value
    }
    let working = Task { try await connection.send(.listSessions(.init())) }
    let next = try await peer.nextRequest()
    #expect(next.id == request.id + 1)
    peer.send(ServerMessage.listSessions(id: next.id, window: "still-open"))
    #expect(Self.windowID(try await working.value) == "still-open")
  }

  /// The stream ending fails every pending request with `disconnected`, and the connection
  /// refuses new requests.
  @Test func disconnectFailsEveryPendingRequest() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let first = Task { try await connection.send(.listSessions(.init())) }
    let second = Task { try await connection.send(.tmux(.listConnections)) }
    _ = try await peer.nextRequest()
    _ = try await peer.nextRequest()
    peer.stream.deliverEndOfStream()
    await #expect(throws: ITerm2Error.disconnected) { _ = try await first.value }
    await #expect(throws: ITerm2Error.disconnected) { _ = try await second.value }
    #expect(await !connection.isOpen)
    await #expect(throws: ITerm2Error.notSent(.disconnected)) {
      _ = try await connection.send(.listSessions(.init()))
    }
    try await waitUntil("the stream was shut down") { peer.stream.isShutDown }
  }

  /// A request without a response fails with `timedOut`; its late response is ignored and the
  /// connection keeps working.
  @Test func requestTimeout() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let start = ContinuousClock.now
    let slow = Task {
      try await connection.send(.listSessions(.init()), timeout: .milliseconds(100))
    }
    let request = try await peer.nextRequest()
    await #expect(throws: ITerm2Error.timedOut) { _ = try await slow.value }
    #expect(ContinuousClock.now - start >= .milliseconds(100))
    peer.send(ServerMessage.listSessions(id: request.id, window: "late"))
    let next = Task { try await connection.send(.listSessions(.init())) }
    let nextRequest = try await peer.nextRequest()
    peer.send(ServerMessage.listSessions(id: nextRequest.id, window: "on-time"))
    #expect(Self.windowID(try await next.value) == "on-time")
  }

  /// A message that cannot be decoded closes the connection with a protocol error.
  @Test func undecodableMessage() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let pending = Task { try await connection.send(.listSessions(.init())) }
    _ = try await peer.nextRequest()
    peer.send([0xFF])
    await #expect(throws: ITerm2Error.protocolError("a message could not be decoded")) {
      _ = try await pending.value
    }
    #expect(await !connection.isOpen)
  }

  /// A response with an id but no content is a protocol error for that request only.
  @Test func emptyResponse() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let pending = Task { try await connection.send(.listSessions(.init())) }
    let request = try await peer.nextRequest()
    peer.send(ServerMessage.idField(request.id))
    await #expect(throws: ITerm2Error.protocolError("a response carried no content")) {
      _ = try await pending.value
    }
    #expect(await connection.isOpen)
  }

  /// Cancelling the calling task fails its request with `CancellationError`; a later response
  /// to it is ignored.
  @Test func cancellation() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let task = Task { try await connection.send(.listSessions(.init())) }
    let request = try await peer.nextRequest()
    task.cancel()
    await #expect(throws: CancellationError.self) { _ = try await task.value }
    peer.send(ServerMessage.listSessions(id: request.id, window: "ignored"))
    #expect(await connection.isOpen)
  }

  /// A server ping is answered with a pong carrying the same payload while a request waits.
  @Test func pingWhileWaiting() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let pending = Task { try await connection.send(.listSessions(.init())) }
    let request = try await peer.nextRequest()
    peer.stream.deliver(WebSocketFrame.encode(opcode: .ping, payload: [4, 2], maskingKey: nil))
    let pong = try await peer.nextFrame()
    #expect(pong.opcode == .pong)
    #expect(pong.payload == [4, 2])
    peer.send(ServerMessage.listSessions(id: request.id, window: "after-ping"))
    #expect(Self.windowID(try await pending.value) == "after-ping")
  }

  /// A server close fails pending requests with `disconnected` and is answered.
  @Test func serverClose() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let pending = Task { try await connection.send(.listSessions(.init())) }
    _ = try await peer.nextRequest()
    peer.stream.deliver(
      WebSocketFrame.encode(
        opcode: .close, payload: WebSocketFrame.closePayload(code: 1001), maskingKey: nil))
    await #expect(throws: ITerm2Error.disconnected) { _ = try await pending.value }
    let reply = try await peer.nextFrame()
    #expect(reply.opcode == .close)
    #expect(WebSocketFrame.closeCode(in: reply.payload) == 1001)
  }

  /// `close()` fails pending requests, sends a close frame (1000), and shuts the stream down
  /// once the server answers.
  @Test func clientClose() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let pending = Task { try await connection.send(.listSessions(.init())) }
    _ = try await peer.nextRequest()
    let closing = Task { await connection.close() }
    await #expect(throws: ITerm2Error.disconnected) { _ = try await pending.value }
    let frame = try await peer.nextFrame()
    #expect(frame.opcode == .close)
    #expect(WebSocketFrame.closeCode(in: frame.payload) == 1000)
    peer.stream.deliver(
      WebSocketFrame.encode(
        opcode: .close, payload: WebSocketFrame.closePayload(code: 1000), maskingKey: nil))
    await closing.value
    #expect(peer.stream.isShutDown)
    #expect(await !connection.isOpen)
  }

  /// A message that stops arriving halfway ends the connection with `timedOut` after the stall
  /// timeout; an idle connection stays open.
  @Test func stalledMessage() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    try await Task.sleep(for: .milliseconds(400))
    #expect(await connection.isOpen)
    let pending = Task { try await connection.send(.listSessions(.init())) }
    _ = try await peer.nextRequest()
    peer.stream.deliver([0x82, 0x10, 0x08])
    await #expect(throws: ITerm2Error.timedOut) { _ = try await pending.value }
    #expect(await !connection.isOpen)
  }

  /// A failed write fails its request as not sent (the frame never arrived whole) and ends the
  /// connection.
  @Test func writeFailure() async throws {
    let (connection, peer) = await Self.makeConnection()
    peer.stream.failWrites(with: .closedByPeer)
    await #expect(throws: ITerm2Error.notSent(.disconnected)) {
      _ = try await connection.send(.listSessions(.init()))
    }
    try await waitUntil("the connection closed") { await !connection.isOpen }
  }

  /// A server close frame with a code that must not appear on the wire (the review's bytes
  /// `88 02 03 ED`, code 1005) fails the pending request with a protocol error and is answered
  /// with 1002, not echoed.
  @Test func malformedServerClose() async throws {
    let (connection, initialPeer) = await Self.makeConnection()
    var peer = initialPeer
    let pending = Task { try await connection.send(.listSessions(.init())) }
    _ = try await peer.nextRequest()
    peer.stream.deliver([0x88, 0x02, 0x03, 0xED])
    await #expect(
      throws: ITerm2Error.protocolError(
        "close frame carries a status code that must not appear on the wire")
    ) { _ = try await pending.value }
    let reply = try await peer.nextFrame()
    #expect(reply.opcode == .close)
    #expect(WebSocketFrame.closeCode(in: reply.payload) == 1002)
    #expect(await !connection.isOpen)
  }

  /// How a test makes a request fail before iTerm2 answers.
  enum Abandonment: String, CaseIterable, Sendable {
    /// The calling task is cancelled.
    case cancelled
    /// The request's deadline passes.
    case expired

    /// The request timeout to send with: `expiry` for a request that is to expire, the
    /// connection's default otherwise.
    func timeout(expiring expiry: Duration) -> Duration? { self == .expired ? expiry : nil }
  }

  /// Settings whose writes wait for the test to release them, not for the write timeout.
  static var patientWriterSettings: ITerm2Connection.Settings {
    var settings = fastConnectionSettings
    settings.writeTimeout = .seconds(30)
    return settings
  }

  /// The ids of every request frame the client wrote to `stream`.
  static func writtenRequestIDs(_ stream: FakeByteStream) throws -> [Int64] {
    try WebSocketReaderTests.clientFrames(stream).map { try ClientRequest($0.payload).id }
  }

  /// The review's blocker: while request 1's write is blocked, request 2 is queued and then
  /// cancelled or expires. It fails as not sent (`CancellationError`, `notSent(.timedOut)`),
  /// and once the write is released its frame never reaches the stream: the next frame after
  /// request 1 is request 3.
  @Test(arguments: Abandonment.allCases)
  func queuedRequestAbandonedBehindABlockedWriteIsNeverSent(abandonment: Abandonment)
    async throws
  {
    let (connection, initialPeer) = await Self.makeConnection(settings: Self.patientWriterSettings)
    var peer = initialPeer
    peer.stream.holdWrites()
    let first = Task { try await connection.send(.listSessions(.init())) }
    try await waitUntil("request 1's write is blocked") { peer.stream.blockedWrites == 1 }
    let second = Task {
      try await connection.send(
        .tmux(.listConnections), timeout: abandonment.timeout(expiring: .milliseconds(100)))
    }
    try await waitUntil("request 2 is queued") { await connection.queuedRequestCount == 2 }
    switch abandonment {
    case .cancelled:
      second.cancel()
      await #expect(throws: CancellationError.self) { _ = try await second.value }
    case .expired:
      await #expect(throws: ITerm2Error.notSent(.timedOut)) { _ = try await second.value }
    }
    peer.stream.releaseWrites()
    let third = Task { try await connection.send(.listSessions(.init())) }
    let sent = [try await peer.nextRequest(), try await peer.nextRequest()]
    #expect(sent.map(\.id) == [1, 3])
    #expect(sent.map(\.fieldNumber) == [106, 106])
    peer.send(ServerMessage.listSessions(id: 1, window: "first"))
    peer.send(ServerMessage.listSessions(id: 3, window: "third"))
    #expect(Self.windowID(try await first.value) == "first")
    #expect(Self.windowID(try await third.value) == "third")
    #expect(try Self.writtenRequestIDs(peer.stream) == [1, 3])
    #expect(await connection.isOpen)
  } // End of func queuedRequestAbandonedBehindABlockedWriteIsNeverSent(abandonment:)

  /// A request cancelled or expired while its own frame is being written fails with the plain
  /// error (outcome unknown: `CancellationError`, `timedOut`, not `notSent`), and its frame is
  /// still written whole. The 1 s deadline only has to outlast the writer picking the frame up
  /// (a frame reached after its deadline is skipped instead, as the test above shows), which
  /// takes far less even on a loaded machine.
  @Test(arguments: Abandonment.allCases)
  func requestAbandonedMidWriteIsStillSentWhole(abandonment: Abandonment) async throws {
    let (connection, initialPeer) = await Self.makeConnection(settings: Self.patientWriterSettings)
    var peer = initialPeer
    peer.stream.holdWrites()
    let request = Task {
      try await connection.send(
        .listSessions(.init()), timeout: abandonment.timeout(expiring: .seconds(1)))
    }
    try await waitUntil("the request's write is blocked") { peer.stream.blockedWrites == 1 }
    switch abandonment {
    case .cancelled:
      request.cancel()
      await #expect(throws: CancellationError.self) { _ = try await request.value }
    case .expired:
      await #expect(throws: ITerm2Error.timedOut) { _ = try await request.value }
    }
    #expect(peer.stream.written.isEmpty)
    peer.stream.releaseWrites()
    let sent = try await peer.nextRequest()
    #expect(sent.id == 1)
    #expect(sent.fieldNumber == 106)
    #expect(await connection.isOpen)
  } // End of func requestAbandonedMidWriteIsStillSentWhole(abandonment:)

  /// When the connection ends while request 1 is being written and request 2 waits behind it,
  /// request 1 fails with `disconnected` (it may have been received) and request 2 with
  /// `notSent(.disconnected)`; only request 1's frame is ever written.
  @Test func connectionEndWithdrawsQueuedRequests() async throws {
    let (connection, peer) = await Self.makeConnection(settings: Self.patientWriterSettings)
    peer.stream.holdWrites()
    let first = Task { try await connection.send(.listSessions(.init())) }
    try await waitUntil("request 1's write is blocked") { peer.stream.blockedWrites == 1 }
    let second = Task { try await connection.send(.tmux(.listConnections)) }
    try await waitUntil("request 2 is queued") { await connection.queuedRequestCount == 2 }
    peer.stream.deliverEndOfStream()
    await #expect(throws: ITerm2Error.disconnected) { _ = try await first.value }
    await #expect(throws: ITerm2Error.notSent(.disconnected)) { _ = try await second.value }
    peer.stream.releaseWrites()
    try await waitUntil("the stream was shut down") { peer.stream.isShutDown }
    #expect(try Self.writtenRequestIDs(peer.stream) == [1])
  } // End of func connectionEndWithdrawsQueuedRequests()
}
