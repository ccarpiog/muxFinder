import Foundation
import Testing

@testable import MuxFinderCore

/// `ITerm2APIClient` end to end against fakes: the connection lifecycle and its errors, a fresh
/// cookie for every connection, and the typed methods. Nothing touches iTerm2, its socket,
/// AppleScript or `NSWorkspace`.
@Suite("iTerm2 API client")
struct ITerm2APIClientTests {
  /// A client and its fakes.
  struct Harness {
    /// The client under test.
    let client: ITerm2APIClient
    /// The fake app control.
    let appControl: FakeAppControl
    /// The fake cookie provider.
    let cookies: FakeCookieProvider
    /// The fake connector.
    let connector: FakeConnector
  }

  /// A client whose connector hands out `streams`.
  static func makeClient(
    streams: [FakeByteStream] = [FakeByteStream()],
    running: Bool = true,
    socketExists: Bool = true,
    cookies: FakeCookieProvider = .numbered()
  ) -> Harness {
    let appControl = FakeAppControl(running: running)
    let connector = FakeConnector(streams: streams, exists: socketExists)
    var configuration = ITerm2APIClient.Configuration(socketPath: "/nonexistent/fake-socket")
    configuration.requestTimeout = .seconds(5)
    configuration.launchSocketTimeout = .milliseconds(300)
    let client = ITerm2APIClient(
      configuration: configuration, appControl: appControl, cookieProvider: cookies,
      connector: connector, connectionSettings: fastConnectionSettings)
    return Harness(client: client, appControl: appControl, cookies: cookies, connector: connector)
  } // End of func makeClient(streams:running:socketExists:cookies:)

  /// Answers the handshake on `stream` and the request that follows it with `fixture`.
  static func serve(
    _ stream: FakeByteStream,
    fixture: String,
    expecting fieldNumber: Int
  ) async throws -> FakeITerm2Peer {
    var peer = FakeITerm2Peer(stream: stream)
    try await peer.answerHandshake()
    let request = try await peer.nextRequest()
    #expect(request.fieldNumber == fieldNumber)
    try peer.respond(to: request.id, withFixture: fixture)
    return peer
  } // End of func serve(_:fixture:expecting:)

  /// A first call connects with the handshake iTerm2 needs and decodes the response.
  @Test func connectsAndListsSessions() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    let sessions = Task { try await harness.client.listSessions() }
    let peer = try await Self.serve(stream, fixture: "list-sessions-response", expecting: 106)
    guard
      case .listSessions(let expected)? = try ITerm2Fixture.server("list-sessions-response")
        .response
    else {
      Issue.record("the fixture is not a list-sessions response")
      return
    }
    #expect(try await sessions.value == expected)
    #expect(peer.handshakeHeader("x-iterm2-cookie") == "cookie-1")
    #expect(peer.handshakeHeader("x-iterm2-key") == "key-1")
    #expect(peer.handshakeHeader("x-iterm2-advisory-name") == "muxFinder")
    #expect(peer.handshakeHeader("x-iterm2-disable-auth-ui") == "true")
    #expect(peer.handshakeHeader("Sec-WebSocket-Protocol") == "api.iterm2.com")
    #expect(harness.appControl.launches == 0)
    let status = await harness.client.status()
    #expect(
      status
        == ITerm2Status(
          isRunning: true, socketPresent: true, isConnected: true, protocolVersion: "1.21"))
    #expect(harness.cookies.calls == 1)
  } // End of func connectsAndListsSessions()

  /// iTerm2 not running: `notRunning`, and neither a cookie nor a connection is requested and
  /// nothing is launched.
  @Test func notRunning() async throws {
    let harness = Self.makeClient(running: false)
    await #expect(throws: ITerm2Error.notRunning) { _ = try await harness.client.listSessions() }
    let status = await harness.client.status()
    #expect(
      status
        == ITerm2Status(
          isRunning: false, socketPresent: true, isConnected: false, error: .notRunning))
    #expect(harness.cookies.calls == 0)
    #expect(harness.connector.connects == 0)
    #expect(harness.appControl.launches == 0)
  }

  /// No socket file: `apiDisabled` without requesting a cookie.
  @Test func socketMissing() async throws {
    let harness = Self.makeClient(socketExists: false)
    await #expect(throws: ITerm2Error.apiDisabled) {
      _ = try await harness.client.listTmuxConnections()
    }
    let status = await harness.client.status()
    #expect(
      status
        == ITerm2Status(
          isRunning: true, socketPresent: false, isConnected: false, error: .apiDisabled))
    #expect(harness.cookies.calls == 0)
    #expect(harness.connector.connects == 0)
  }

  /// A refused connection (stale socket file) is `apiDisabled` too.
  @Test func connectionRefused() async throws {
    let harness = Self.makeClient()
    harness.connector.setConnectError(.apiDisabled)
    await #expect(throws: ITerm2Error.apiDisabled) { _ = try await harness.client.listSessions() }
  }

  /// Cookie failures surface unchanged, and no connection is attempted.
  @Test(arguments: [ITerm2Error.automationDenied, .cookieUnavailable(appleScriptError: -2741)])
  func cookieFailures(error: ITerm2Error) async throws {
    let harness = Self.makeClient(cookies: FakeCookieProvider([.failure(error)]))
    await #expect(throws: error) { _ = try await harness.client.listSessions() }
    #expect(harness.connector.connects == 0)
  }

  /// HTTP 401 on the handshake is `authRejected`, and the stream is shut down.
  @Test func authRejected() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    let sessions = Task { try await harness.client.listSessions() }
    var peer = FakeITerm2Peer(stream: stream)
    try await peer.answerHandshake(status: 401)
    await #expect(throws: ITerm2Error.authRejected) { _ = try await sessions.value }
    #expect(stream.isShutDown)
  }

  /// Every connection gets a fresh cookie: after iTerm2 drops the first connection, the next
  /// call reconnects with the second cookie.
  @Test func reconnectUsesAFreshCookie() async throws {
    let first = FakeByteStream()
    let second = FakeByteStream()
    let harness = Self.makeClient(streams: [first, second])
    let initial = Task { try await harness.client.listTmuxConnections() }
    let firstPeer = try await Self.serve(
      first, fixture: "tmux-list-connections-response", expecting: 124)
    #expect(try await initial.value.count == 2)
    #expect(firstPeer.handshakeHeader("x-iterm2-cookie") == "cookie-1")
    first.deliverEndOfStream()
    try await waitUntil("the first connection ended") { first.isShutDown }

    let again = Task { try await harness.client.listTmuxConnections() }
    let secondPeer = try await Self.serve(
      second, fixture: "tmux-list-connections-response", expecting: 124)
    #expect(try await again.value.count == 2)
    #expect(secondPeer.handshakeHeader("x-iterm2-cookie") == "cookie-2")
    #expect(secondPeer.handshakeHeader("x-iterm2-key") == "key-2")
    #expect(harness.cookies.calls == 2)
    #expect(harness.connector.connects == 2)
  } // End of func reconnectUsesAFreshCookie()

  /// Concurrent first calls share one connection attempt.
  @Test func concurrentCallsShareOneConnection() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    let one = Task { try await harness.client.listTmuxConnections() }
    let two = Task { try await harness.client.listTmuxConnections() }
    var peer = FakeITerm2Peer(stream: stream)
    try await peer.answerHandshake()
    for _ in 0..<2 {
      let request = try await peer.nextRequest()
      try peer.respond(to: request.id, withFixture: "tmux-list-connections-response")
    }
    #expect(try await one.value.count == 2)
    #expect(try await two.value.count == 2)
    #expect(harness.cookies.calls == 1)
    #expect(harness.connector.connects == 1)
  }

  /// Non-OK statuses become typed errors; tmux replies without a payload are empty results.
  @Test func typedStatusErrors() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    var peer = FakeITerm2Peer(stream: stream)
    let createTab = Task {
      try await harness.client.createTab(.init(profileName: "fixture-profile"))
    }
    try await peer.answerHandshake()
    var request = try await peer.nextRequest()
    #expect(request.fieldNumber == 108)
    try peer.respond(to: request.id, withFixture: "create-tab-response-invalid-profile")
    await #expect(throws: ITerm2Error.createTabFailed(.invalidProfileName)) {
      _ = try await createTab.value
    }

    let activate = Task {
      try await harness.client.activate(
        .init(
          target: .tab("fixture-tab"), orderWindowFront: true, selectTab: true, selectSession: true)
      )
    }
    request = try await peer.nextRequest()
    try peer.respond(to: request.id, withFixture: "activate-response-bad-identifier")
    await #expect(throws: ITerm2Error.activateFailed(.badIdentifier)) { try await activate.value }

    let send = Task { try await harness.client.sendTmuxCommand("list-sessions", connectionID: "x") }
    request = try await peer.nextRequest()
    try peer.respond(to: request.id, withFixture: "tmux-response-invalid-connection")
    await #expect(throws: ITerm2Error.tmuxRequestFailed(.invalidConnectionID)) {
      _ = try await send.value
    }

    let empty = Task { try await harness.client.listTmuxConnections() }
    request = try await peer.nextRequest()
    peer.send(ServerMessage.message(id: request.id, fieldNumber: 124) { $0.writeEnum(4, 0) })
    #expect(try await empty.value == [])
  } // End of func typedStatusErrors()

  /// The typed methods' successful results.
  @Test func successfulResults() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    var peer = FakeITerm2Peer(stream: stream)
    let created = Task { try await harness.client.createTab(.init()) }
    try await peer.answerHandshake()
    var request = try await peer.nextRequest()
    try peer.respond(to: request.id, withFixture: "create-tab-response-ok")
    let tab = try await created.value
    #expect(tab.status == .ok)
    #expect(tab.sessionID != nil)

    let output = Task { try await harness.client.sendTmuxCommand("display", connectionID: "c") }
    request = try await peer.nextRequest()
    try peer.respond(to: request.id, withFixture: "tmux-send-command-response")
    #expect(try await output.value == "4242")

    let profiles = Task {
      try await harness.client.listProfiles(properties: ["Guid", "Name"], guids: [])
    }
    request = try await peer.nextRequest()
    #expect(request.fieldNumber == 118)
    try peer.respond(to: request.id, withFixture: "list-profiles-response")
    #expect(try await profiles.value.map(\.guid).contains(ITerm2Fixture.guid1))

    let activated = Task {
      try await harness.client.activate(
        .init(target: .session("s"), orderWindowFront: true, selectTab: true, selectSession: true))
    }
    request = try await peer.nextRequest()
    try peer.respond(to: request.id, withFixture: "activate-response-ok")
    try await activated.value

    let closed = Task {
      try await harness.client.close(.init(target: .sessions(["s1", "s2", "s3"]), force: true))
    }
    request = try await peer.nextRequest()
    #expect(request.fieldNumber == 131)
    try peer.respond(to: request.id, withFixture: "close-response")
    #expect(try await closed.value.statuses == [.ok, .notFound, .userDeclined])
  } // End of func successfulResults()

  /// The review's finding: an ownership-bound tmux command first lists the connections and
  /// sends the command, on the same API connection, only when the listed owner matches; for
  /// another owner only the listing goes out (`tmuxConnectionNotOwned`). A listing lost with
  /// its connection reports the command as not sent, and nothing reconnects to send it.
  @Test func ownedTmuxCommand() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    var peer = FakeITerm2Peer(stream: stream)
    let owner = ITerm2Fixture.session(4)
    let owned = Task {
      try await harness.client.sendTmuxCommand(
        "display-message -p x", connectionID: "fixture-connection-1", ownedBy: owner)
    }
    try await peer.answerHandshake()
    var request = try await peer.nextRequest()
    #expect(request.fieldNumber == 124)
    #expect(request.bytes.firstRange(of: Array("display-message".utf8)) == nil)
    try peer.respond(to: request.id, withFixture: "tmux-list-connections-response")
    request = try await peer.nextRequest()
    #expect(request.fieldNumber == 124)
    #expect(request.bytes.firstRange(of: Array("display-message -p x".utf8)) != nil)
    try peer.respond(to: request.id, withFixture: "tmux-send-command-response")
    #expect(try await owned.value == "4242")

    let refused = Task {
      try await harness.client.sendTmuxCommand(
        "detach-client", connectionID: "fixture-connection-1", ownedBy: ITerm2Fixture.session(6))
    }
    request = try await peer.nextRequest()
    try peer.respond(to: request.id, withFixture: "tmux-list-connections-response")
    await #expect(throws: ITerm2Error.tmuxConnectionNotOwned) { _ = try await refused.value }
    // The next frame is the next call's: no detach-client was written in between.
    let sessions = Task { try await harness.client.listSessions() }
    request = try await peer.nextRequest()
    #expect(request.fieldNumber == 106)
    try peer.respond(to: request.id, withFixture: "list-sessions-response")
    _ = try await sessions.value

    let lost = Task {
      try await harness.client.sendTmuxCommand(
        "detach-client", connectionID: "fixture-connection-1", ownedBy: owner)
    }
    request = try await peer.nextRequest()
    #expect(request.bytes.firstRange(of: Array("detach-client".utf8)) == nil)
    stream.deliverEndOfStream()
    await #expect(throws: ITerm2Error.notSent(.disconnected)) { _ = try await lost.value }
    #expect(harness.connector.connects == 1)
  } // End of func ownedTmuxCommand()

  /// A response of the wrong type is a protocol error.
  @Test func mismatchedResponseType() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    let sessions = Task { try await harness.client.listSessions() }
    _ = try await Self.serve(stream, fixture: "activate-response-ok", expecting: 106)
    await #expect(throws: ITerm2Error.protocolError("the response type does not match the request"))
    {
      _ = try await sessions.value
    }
  }

  /// `ensureRunning()` launches iTerm2 only when it is not running, then waits for the socket.
  @Test func ensureRunning() async throws {
    let connector = FakeConnector(exists: false)
    let appControl = FakeAppControl(running: false) { connector.setExists(true) }
    let client = ITerm2APIClient(
      configuration: .init(socketPath: "/nonexistent/fake-socket"), appControl: appControl,
      cookieProvider: FakeCookieProvider.numbered(), connector: connector,
      connectionSettings: fastConnectionSettings)
    try await client.ensureRunning()
    #expect(appControl.launches == 1)
    try await client.ensureRunning()
    #expect(appControl.launches == 1)
    connector.setExists(false)
    await #expect(throws: ITerm2Error.apiDisabled) { try await client.ensureRunning() }
    #expect(appControl.launches == 1)
  }

  /// A launch whose socket never appears ends with `apiDisabled` after the timeout.
  @Test func ensureRunningWithoutSocket() async throws {
    let harness = Self.makeClient(running: false, socketExists: false)
    await #expect(throws: ITerm2Error.apiDisabled) { try await harness.client.ensureRunning() }
    #expect(harness.appControl.launches == 1)
  }

  /// `disconnect()` runs the close handshake, and the next call reconnects with a new cookie.
  @Test func disconnectThenReconnect() async throws {
    let first = FakeByteStream()
    let second = FakeByteStream()
    let harness = Self.makeClient(streams: [first, second])
    let initial = Task { try await harness.client.listSessions() }
    var firstPeer = try await Self.serve(first, fixture: "list-sessions-response", expecting: 106)
    _ = try await initial.value
    let disconnecting = Task { await harness.client.disconnect() }
    let close = try await firstPeer.nextFrame()
    #expect(close.opcode == .close)
    await disconnecting.value
    #expect(first.isShutDown)
    let again = Task { try await harness.client.listSessions() }
    _ = try await Self.serve(second, fixture: "list-sessions-response", expecting: 106)
    _ = try await again.value
    #expect(harness.cookies.calls == 2)
  }

  /// The review's finding: `disconnect()` during the cookie request fails the waiting call at
  /// once with `notSent(.disconnected)`. When the cookie arrives later, the invalidated attempt
  /// stops before connecting, and the next call starts a fresh attempt with a fresh cookie.
  @Test func disconnectDuringCookieRequest() async throws {
    let stream = FakeByteStream()
    let cookies = GatedCookieProvider()
    let connector = FakeConnector(streams: [stream])
    let log = DiagnosticsLog(writesToSystemLog: false)
    let client = ITerm2APIClient(
      configuration: .init(socketPath: "/nonexistent/fake-socket"),
      appControl: FakeAppControl(running: true), cookieProvider: cookies, connector: connector,
      connectionSettings: fastConnectionSettings, diagnostics: log)
    let call = Task { try await client.listSessions() }
    try await waitUntil("the cookie was requested") { cookies.calls == 1 }
    await client.disconnect()
    await #expect(throws: ITerm2Error.notSent(.disconnected)) { _ = try await call.value }
    cookies.release()
    try await waitUntil("the invalidated attempt ended") { await !log.events().isEmpty }
    #expect(await log.events().map(\.detail) == ["iTerm2 API connection failed: cancelled"])
    #expect(connector.connects == 0)

    let again = Task { try await client.listSessions() }
    let peer = try await Self.serve(stream, fixture: "list-sessions-response", expecting: 106)
    _ = try await again.value
    #expect(peer.handshakeHeader("x-iterm2-cookie") == "cookie-2")
    #expect(cookies.calls == 2)
    #expect(connector.connects == 1)
  } // End of func disconnectDuringCookieRequest()

  /// `disconnect()` during the handshake fails the waiting call at once; the connection the
  /// invalidated attempt still completes is closed with the close handshake instead of being
  /// kept, and the next call opens a new one with a fresh cookie.
  @Test func disconnectDuringHandshake() async throws {
    let first = FakeByteStream()
    let second = FakeByteStream()
    let harness = Self.makeClient(streams: [first, second])
    let call = Task { try await harness.client.listSessions() }
    try await waitUntil("the client sent its handshake") {
      first.written.firstRange(of: [13, 10, 13, 10] as [UInt8]) != nil
    }
    await harness.client.disconnect()
    await #expect(throws: ITerm2Error.notSent(.disconnected)) { _ = try await call.value }
    var firstPeer = FakeITerm2Peer(stream: first)
    try await firstPeer.answerHandshake()
    let close = try await firstPeer.nextFrame()
    #expect(close.opcode == .close)
    #expect(WebSocketFrame.closeCode(in: close.payload) == 1000)
    try await waitUntil("the late connection was shut down") { first.isShutDown }

    let again = Task { try await harness.client.listSessions() }
    let secondPeer = try await Self.serve(second, fixture: "list-sessions-response", expecting: 106)
    _ = try await again.value
    #expect(secondPeer.handshakeHeader("x-iterm2-cookie") == "cookie-2")
    #expect(harness.cookies.calls == 2)
    #expect(harness.connector.connects == 2)
  } // End of func disconnectDuringHandshake()

  /// A caller cancelled while it waits for the connection attempt fails at once with
  /// `CancellationError`; the attempt carries on and its connection serves the next call.
  @Test func cancelledCallerLeavesTheAttempt() async throws {
    let stream = FakeByteStream()
    let harness = Self.makeClient(streams: [stream])
    let call = Task { try await harness.client.listSessions() }
    try await waitUntil("the client sent its handshake") {
      stream.written.firstRange(of: [13, 10, 13, 10] as [UInt8]) != nil
    }
    call.cancel()
    await #expect(throws: CancellationError.self) { _ = try await call.value }
    let again = Task { try await harness.client.listSessions() }
    _ = try await Self.serve(stream, fixture: "list-sessions-response", expecting: 106)
    _ = try await again.value
    #expect(harness.cookies.calls == 1)
    #expect(harness.connector.connects == 1)
  } // End of func cancelledCallerLeavesTheAttempt()

  /// Connection outcomes are recorded without user data: the error kind only.
  @Test func diagnosticsRecordOutcomes() async throws {
    let log = DiagnosticsLog(writesToSystemLog: false)
    let client = ITerm2APIClient(
      configuration: .init(socketPath: "/nonexistent/fake-socket"),
      appControl: FakeAppControl(running: true),
      cookieProvider: FakeCookieProvider([.failure(.automationDenied)]),
      connector: FakeConnector(), connectionSettings: fastConnectionSettings, diagnostics: log)
    await #expect(throws: ITerm2Error.automationDenied) { _ = try await client.listSessions() }
    let events = await log.events()
    #expect(events.map(\.detail) == ["iTerm2 API connection failed: automationDenied"])
    #expect(events.map(\.category) == [.iTerm2])
  }
}
