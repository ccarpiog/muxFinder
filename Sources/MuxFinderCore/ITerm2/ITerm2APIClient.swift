import Foundation

/// The production `ITerm2Integration`: a native client of iTerm2's API (PLAN.md D1).
///
/// It connects on demand to `~/Library/Application Support/iTerm2/private/socket` with a
/// hand-written WebSocket client, authenticates with a fresh single-use cookie per connection,
/// and keeps the connection for later calls. When the connection ends (iTerm2 quit, a protocol
/// error, a stall), the next call opens a new one with a new cookie. Concurrent callers share
/// one connection attempt; each attempt has a generation, and `disconnect()` invalidates the
/// attempt in progress, so a connection it completes late is closed rather than kept. An
/// attempt whose callers were all cancelled stops before asking for the cookie or connecting,
/// whichever comes next, and a cancelled task sends no request, so cancelling a caller (the
/// popover closing) leaves nothing behind that contacts iTerm2 later. Requests are never
/// retried automatically: a request may already have taken effect when its connection broke
/// (`ITerm2Error` says which failures mean it was not sent).
///
/// Connecting checks, in order: iTerm2 is running (`notRunning` otherwise; nothing is launched),
/// the socket file exists (`apiDisabled`; no cookie is requested), the cookie request succeeds,
/// the socket accepts the connection (`apiDisabled` when refused), and the handshake succeeds
/// (`authRejected` for HTTP 401).
public actor ITerm2APIClient: ITerm2Integration {
  /// Connection settings.
  public struct Configuration: Sendable {
    /// iTerm2's API socket: `~/Library/Application Support/iTerm2/private/socket`.
    public static var defaultSocketPath: String {
      FileManager.default.homeDirectoryForCurrentUser
        .appending(path: "Library/Application Support/iTerm2/private/socket")
        .path(percentEncoded: false)
    }
    /// The name iTerm2 shows for this client in its script console.
    public static let advisoryName = "muxFinder"
    /// The library version this client announces. iTerm2 refuses versions it considers too old
    /// (HTTP 406); this is the version of the reference Python module the protocol facts were
    /// checked against.
    public static let libraryVersion = "python 2.11"
    /// The WebSocket subprotocol iTerm2's API uses.
    public static let subprotocol = "api.iterm2.com"

    /// The API socket to connect to.
    public var socketPath: String
    /// How long connecting and the WebSocket handshake may take together.
    public var connectTimeout: Duration
    /// How long a request waits for its response.
    public var requestTimeout: Duration
    /// How long `ensureRunning()` waits for the API socket after launching iTerm2.
    public var launchSocketTimeout: Duration

    /// Creates a configuration; the defaults suit the app.
    public init(
      socketPath: String = Configuration.defaultSocketPath,
      connectTimeout: Duration = .seconds(5),
      requestTimeout: Duration = .seconds(10),
      launchSocketTimeout: Duration = .seconds(20)
    ) {
      self.socketPath = socketPath
      self.connectTimeout = connectTimeout
      self.requestTimeout = requestTimeout
      self.launchSocketTimeout = launchSocketTimeout
    } // End of init(socketPath:connectTimeout:requestTimeout:launchSocketTimeout:)
  }

  /// Connection settings.
  public nonisolated let configuration: Configuration
  /// Supplies a fresh cookie for every connection.
  private let cookieProvider: any ITerm2CookieProvider
  /// Tells whether iTerm2 runs, and launches it for `ensureRunning()`.
  private let appControl: any ITerm2AppControl
  /// Opens the API socket.
  private let connector: any ITerm2SocketConnector
  /// Limits for each connection.
  private let connectionSettings: ITerm2Connection.Settings
  /// Where connection outcomes are recorded, if anywhere.
  private let diagnostics: DiagnosticsLog?
  /// The current connection, open or ended.
  private var connection: ITerm2Connection?
  /// The connection attempt in progress, shared by concurrent callers.
  private var attempt: ConnectionAttempt?
  /// The generation of the most recently started connection attempt.
  private var attemptGeneration: UInt64 = 0
  /// The id the next caller waiting for a connection attempt gets.
  private var nextWaiterID: UInt64 = 0

  /// A connection attempt in progress and the callers waiting for its outcome.
  private struct ConnectionAttempt {
    /// Tells this attempt apart from earlier and later ones; an attempt whose generation is no
    /// longer current was invalidated by `disconnect()`.
    let generation: UInt64
    /// The work: running check, cookie, connect, handshake.
    let task: Task<Void, Never>
    /// The callers waiting for the outcome, by waiter id.
    var waiters: [UInt64: CheckedContinuation<ITerm2Connection, any Error>] = [:]
  }

  /// Creates a client. Nothing connects until the first call.
  public init(
    configuration: Configuration = Configuration(),
    appControl: any ITerm2AppControl = WorkspaceITerm2AppControl(),
    cookieProvider: (any ITerm2CookieProvider)? = nil,
    diagnostics: DiagnosticsLog? = nil
  ) {
    var settings = ITerm2Connection.Settings()
    settings.requestTimeout = configuration.requestTimeout
    self.init(
      configuration: configuration,
      appControl: appControl,
      cookieProvider: cookieProvider ?? AppleScriptCookieProvider(appControl: appControl),
      connector: UnixSocketConnector(path: configuration.socketPath),
      connectionSettings: settings,
      diagnostics: diagnostics)
  } // End of init(configuration:appControl:cookieProvider:diagnostics:)

  /// Creates a client with an explicit connector and connection settings (tests).
  init(
    configuration: Configuration,
    appControl: any ITerm2AppControl,
    cookieProvider: any ITerm2CookieProvider,
    connector: any ITerm2SocketConnector,
    connectionSettings: ITerm2Connection.Settings,
    diagnostics: DiagnosticsLog? = nil
  ) {
    self.configuration = configuration
    self.appControl = appControl
    self.cookieProvider = cookieProvider
    self.connector = connector
    self.connectionSettings = connectionSettings
    self.diagnostics = diagnostics
  } // End of init(…connector:connectionSettings:diagnostics:)

  // MARK: - ITerm2Integration

  /// Whether iTerm2 is running. Never launches it.
  public func isRunning() async -> Bool {
    await appControl.isRunning()
  }

  /// Reports what is known about iTerm2's API, connecting if iTerm2 runs. Never launches it.
  public func status() async -> ITerm2Status {
    let running = await appControl.isRunning()
    let socketPresent = connector.endpointExists()
    guard running else {
      return ITerm2Status(
        isRunning: false, socketPresent: socketPresent, isConnected: false, error: .notRunning)
    }
    do {
      let connection = try await openConnection()
      return ITerm2Status(
        isRunning: true, socketPresent: socketPresent, isConnected: true,
        protocolVersion: connection.protocolVersion)
    } catch {
      return ITerm2Status(
        isRunning: true, socketPresent: socketPresent, isConnected: false,
        error: error as? ITerm2Error ?? .disconnected)
    }
  } // End of func status()

  /// Launches iTerm2 if it is not running and waits until its API socket exists.
  ///
  /// - Throws: `apiDisabled` when iTerm2 runs (or was launched) but its API socket does not
  ///   appear, or the launch failure.
  public func ensureRunning() async throws {
    if await appControl.isRunning() {
      guard connector.endpointExists() else { throw ITerm2Error.apiDisabled }
      return
    }
    try await appControl.launch()
    let deadline = ContinuousClock.now + configuration.launchSocketTimeout
    while !connector.endpointExists() {
      guard ContinuousClock.now < deadline else { throw ITerm2Error.apiDisabled }
      try await Task.sleep(for: .milliseconds(100))
    }
  } // End of func ensureRunning()

  /// Every window, tab and session.
  public func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    guard case .listSessions(let response) = try await send(.listSessions(.init())) else {
      throw Self.unexpectedResponse
    }
    return response
  }

  /// Opens a tab; see `ITerm2Integration.createTab(_:)`.
  public func createTab(
    _ request: ITerm2API.CreateTabRequest
  ) async throws -> ITerm2API.CreateTabResponse {
    guard case .createTab(let response) = try await send(.createTab(request)) else {
      throw Self.unexpectedResponse
    }
    guard response.status == .ok else { throw ITerm2Error.createTabFailed(response.status) }
    return response
  }

  /// Every tmux integration connection. iTerm2 omits the payload when there are none.
  public func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] {
    let response = try await sendTmux(.listConnections)
    switch response.payload {
    case .listConnections(let connections)?: return connections
    case nil: return []
    default: throw Self.unexpectedResponse
    }
  }

  /// Runs a tmux command on a connection and returns its output (empty when iTerm2 sends
  /// none).
  public func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    let response = try await sendTmux(.sendCommand(connectionID: connectionID, command: command))
    switch response.payload {
    case .sendCommand(let output)?: return output ?? ""
    case nil: return ""
    default: throw Self.unexpectedResponse
    }
  }

  /// Runs a tmux command on a connection only while iTerm2 lists it as owned by
  /// `owningSessionID`; see `ITerm2Integration.sendTmuxCommand(_:connectionID:ownedBy:)`. The
  /// listing and the command go out on one API connection: if that connection ends in between,
  /// the command fails with `notSent(reason)` instead of reconnecting, so a restarted iTerm2
  /// whose new connection reuses the id never receives it.
  public func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String {
    let connection = try await requestConnection()
    try await requireTmuxConnection(connectionID, ownedBy: owningSessionID, on: connection)
    let response = try await sendTmux(
      .sendCommand(connectionID: connectionID, command: command), on: connection)
    switch response.payload {
    case .sendCommand(let output)?: return output ?? ""
    case nil: return ""
    default: throw Self.unexpectedResponse
    }
  } // End of func sendTmuxCommand(_:connectionID:ownedBy:)

  /// Brings a window, tab or session forward.
  public func activate(_ request: ITerm2API.ActivateRequest) async throws {
    guard case .activate(let response) = try await send(.activate(request)) else {
      throw Self.unexpectedResponse
    }
    guard response.status == .ok else { throw ITerm2Error.activateFailed(response.status) }
  }

  /// Activates the first tab of a tmux connection only while iTerm2 lists it as owned by
  /// `owningSessionID`; see `ITerm2Integration.activateFirstTab(ofTmuxConnection:ownedBy:options:)`.
  /// Both listings and the activation go out on one API connection: if it ends in between,
  /// the call fails (`notSent(reason)` before the activation) instead of reconnecting.
  public func activateFirstTab(
    ofTmuxConnection connectionID: String,
    ownedBy owningSessionID: String,
    options: ITerm2API.ActivateRequest
  ) async throws -> String? {
    let connection = try await requestConnection()
    try await requireTmuxConnection(connectionID, ownedBy: owningSessionID, on: connection)
    let sessions: ITerm2API.ListSessionsResponse
    do {
      let answer = try await connection.send(
        .listSessions(.init()), timeout: configuration.requestTimeout)
      guard case .listSessions(let listed) = answer else { throw Self.unexpectedResponse }
      sessions = listed
    } catch let error as ITerm2Error {
      // Whatever happened to the listing, the activation itself was never sent.
      throw error.isNotSent ? error : ITerm2Error.notSent(error)
    }
    guard
      let tabID = sessions.tabs(ofTmuxConnection: connectionID).lazy.compactMap(\.tabID)
        .first(where: { !$0.isEmpty })
    else { return nil }
    var request = options
    request.target = .tab(tabID)
    let answer = try await connection.send(
      .activate(request), timeout: configuration.requestTimeout)
    guard case .activate(let response) = answer else { throw Self.unexpectedResponse }
    guard response.status == .ok else { throw ITerm2Error.activateFailed(response.status) }
    return tabID
  } // End of func activateFirstTab(ofTmuxConnection:ownedBy:options:)

  /// Buries or restores a session; see `ITerm2Integration.setBuried(_:sessionID:)`.
  public func setBuried(_ buried: Bool, sessionID: String) async throws {
    try Self.requireSetPropertyOK(
      try await send(.setProperty(.buried(buried, sessionID: sessionID))))
  }

  /// Buries a launch tab only while iTerm2 lists `connectionID` as owned by it; see
  /// `ITerm2Integration.buryLaunchTab(sessionID:ifOwnsTmuxConnection:)`. The listing and the
  /// bury go out on one API connection: if it ends in between, the call fails
  /// (`notSent(reason)`) instead of reconnecting.
  public func buryLaunchTab(
    sessionID: String,
    ifOwnsTmuxConnection connectionID: String
  ) async throws {
    let connection = try await requestConnection()
    try await requireTmuxConnection(connectionID, ownedBy: sessionID, on: connection)
    let answer = try await connection.send(
      .setProperty(.buried(true, sessionID: sessionID)), timeout: configuration.requestTimeout)
    try Self.requireSetPropertyOK(answer)
  } // End of func buryLaunchTab(sessionID:ifOwnsTmuxConnection:)

  /// The JSON value of the session `sessionID`'s property `name` (`GetPropertyRequest`), or
  /// `nil` when iTerm2 sent none; for example `ITerm2API.SessionProperty.buried`, `true` or
  /// `false`. Not part of `ITerm2Integration`: only the probe's `e2e-bury` spike reads
  /// properties (PLAN.md Phase 13a).
  ///
  /// - Throws: `getPropertyFailed` unless iTerm2 reports `OK`.
  public func sessionProperty(_ name: String, sessionID: String) async throws -> String? {
    let request = ITerm2API.GetPropertyRequest(target: .session(sessionID), name: name)
    guard case .getProperty(let response) = try await send(.getProperty(request)) else {
      throw Self.unexpectedResponse
    }
    guard response.status == .ok else { throw ITerm2Error.getPropertyFailed(response.status) }
    return response.jsonValue
  } // End of func sessionProperty(_:sessionID:)

  /// Throws unless `answer` is a set-property response with status `OK`: `setPropertyFailed`
  /// for another status, a protocol error for another response type.
  private static func requireSetPropertyOK(
    _ answer: ITerm2API.ServerOriginatedMessage.Response
  ) throws {
    guard case .setProperty(let response) = answer else { throw unexpectedResponse }
    guard response.status == .ok else { throw ITerm2Error.setPropertyFailed(response.status) }
  }

  /// Lists the tmux connections on `connection` and throws unless one has the id `connectionID`
  /// and the owner `owningSessionID`: `tmuxConnectionNotOwned`, or `notSent(reason)` when the
  /// listing failed. Either way the request it guards was not sent.
  private func requireTmuxConnection(
    _ connectionID: String,
    ownedBy owningSessionID: String,
    on connection: ITerm2Connection
  ) async throws {
    let listing: ITerm2API.TmuxResponse
    do {
      listing = try await sendTmux(.listConnections, on: connection)
    } catch let error as ITerm2Error {
      // Whatever happened to the listing, the guarded request was never sent.
      throw error.isNotSent ? error : ITerm2Error.notSent(error)
    }
    let connections: [ITerm2API.TmuxConnection]
    switch listing.payload {
    case .listConnections(let listed)?: connections = listed
    case nil: connections = []
    default: throw ITerm2Error.notSent(Self.unexpectedResponse)
    }
    guard
      connections.contains(where: {
        $0.connectionID == connectionID && $0.owningSessionID == owningSessionID
      })
    else { throw ITerm2Error.tmuxConnectionNotOwned }
  } // End of func requireTmuxConnection(_:ownedBy:on:)

  /// Profiles with the requested properties.
  public func listProfiles(
    properties: [String],
    guids: [String]
  ) async throws -> [ITerm2API.Profile] {
    let request = ITerm2API.ListProfilesRequest(properties: properties, guids: guids)
    guard case .listProfiles(let response) = try await send(.listProfiles(request)) else {
      throw Self.unexpectedResponse
    }
    return response.profiles
  }

  /// Closes sessions, tabs or windows; see `ITerm2Integration.close(_:)`.
  public func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse {
    guard case .close(let response) = try await send(.close(request)) else {
      throw Self.unexpectedResponse
    }
    return response
  }

  /// Closes the connection with the WebSocket close handshake, if one is open, and invalidates
  /// any connection attempt in progress: its callers fail at once with `disconnected` (a
  /// request method reports `notSent(.disconnected)`), its remaining steps are cancelled, and a
  /// connection it still completes is closed instead of being kept.
  public func disconnect() async {
    if let invalidated = attempt {
      attempt = nil
      invalidated.task.cancel()
      for waiter in invalidated.waiters.values {
        waiter.resume(throwing: ITerm2Error.disconnected)
      }
    }
    let current = connection
    connection = nil
    await current?.close()
  } // End of func disconnect()

  // MARK: - Connection management

  /// The error for a response of the wrong type.
  private static let unexpectedResponse = ITerm2Error.protocolError(
    "the response type does not match the request")

  /// Sends a request on the open connection, connecting first if needed.
  ///
  /// - Throws: see `ITerm2Error` for what each failure says about the request's effect. A
  ///   connection failure that could otherwise read as "sent, outcome unknown" (`timedOut`,
  ///   `disconnected`, `protocolError`, `connectionFailed`) is reported as `notSent(reason)`,
  ///   because no request was sent.
  private func send(
    _ request: ITerm2API.ClientOriginatedMessage.Request
  ) async throws -> ITerm2API.ServerOriginatedMessage.Response {
    let connection = try await requestConnection()
    return try await connection.send(request, timeout: configuration.requestTimeout)
  }

  /// The open connection, or a new one, for a request about to be sent. A connection failure
  /// that could otherwise read as "sent, outcome unknown" (`timedOut`, `disconnected`,
  /// `protocolError`, `connectionFailed`) is reported as `notSent(reason)`, because no request
  /// was sent.
  private func requestConnection() async throws -> ITerm2Connection {
    do {
      return try await openConnection()
    } catch let error as ITerm2Error {
      switch error {
      case .timedOut, .disconnected, .protocolError, .connectionFailed:
        throw ITerm2Error.notSent(error)
      default:
        throw error
      }
    }
  } // End of func requestConnection()

  /// Sends a tmux request and checks its status: on `connection` when given (never
  /// reconnecting), otherwise on the open connection or a new one.
  private func sendTmux(
    _ request: ITerm2API.TmuxRequest,
    on connection: ITerm2Connection? = nil
  ) async throws -> ITerm2API.TmuxResponse {
    let answer: ITerm2API.ServerOriginatedMessage.Response
    if let connection {
      answer = try await connection.send(.tmux(request), timeout: configuration.requestTimeout)
    } else {
      answer = try await send(.tmux(request))
    }
    guard case .tmux(let response) = answer else { throw Self.unexpectedResponse }
    guard response.status == .ok else { throw ITerm2Error.tmuxRequestFailed(response.status) }
    return response
  } // End of func sendTmux(_:on:)

  /// The open connection, or a new one. Concurrent callers share one connection attempt.
  ///
  /// - Throws: the attempt's failure; `disconnected` when `disconnect()` invalidates the attempt
  ///   first; `CancellationError` when the calling task is cancelled before or while it waits
  ///   (the attempt carries on for the other callers, and stops before its next iTerm2 contact
  ///   if none is left).
  private func openConnection() async throws -> ITerm2Connection {
    if let current = connection, await current.isOpen, current === connection { return current }
    let waiterID = nextWaiterID
    nextWaiterID += 1
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        join(waiterID, continuation)
      }
    } onCancel: {
      Task { await self.leave(waiterID) }
    }
  } // End of func openConnection()

  /// Adds a caller to the connection attempt in progress, starting a new attempt (with a new
  /// generation) if none is in progress.
  private func join(
    _ waiterID: UInt64,
    _ continuation: CheckedContinuation<ITerm2Connection, any Error>
  ) {
    if Task.isCancelled {
      continuation.resume(throwing: CancellationError())
      return
    }
    if attempt == nil {
      attemptGeneration += 1
      let generation = attemptGeneration
      let task = Task { await self.runAttempt(generation) }
      attempt = ConnectionAttempt(generation: generation, task: task)
    }
    attempt?.waiters[waiterID] = continuation
  } // End of func join(_:_:)

  /// Fails a caller whose task was cancelled while it waited for the connection attempt. The
  /// attempt goes on, but stops at its next step that would contact iTerm2 if no caller waits
  /// for it by then (`attemptIsWanted(_:)`).
  private func leave(_ waiterID: UInt64) {
    guard let continuation = attempt?.waiters.removeValue(forKey: waiterID) else { return }
    continuation.resume(throwing: CancellationError())
  }

  /// How many callers wait for the connection attempt in progress; 0 when none is (tests).
  var attemptWaiterCount: Int { attempt?.waiters.count ?? 0 }

  /// Whether connection attempt `generation` may go on to its next step that contacts iTerm2
  /// (the cookie request, then the connection): it is still the attempt in progress (not
  /// invalidated by `disconnect()`) and a caller still waits for it. An attempt every caller
  /// has left (each cancelled) is abandoned here: it stops being the attempt in progress, so a
  /// later caller starts a fresh one with a fresh cookie. A caller that joins before that keeps
  /// it going, so reopening the popover during a cookie request asks for no second cookie.
  private func attemptIsWanted(_ generation: UInt64) -> Bool {
    guard let current = attempt, current.generation == generation else { return false }
    guard current.waiters.isEmpty else { return true }
    attempt = nil
    return false
  }

  /// Runs the connection attempt of `generation` and hands its outcome to the attempt's
  /// callers. If `disconnect()` invalidated the attempt meanwhile (its callers already failed),
  /// a connection it opened anyway is closed instead of being kept.
  private func runAttempt(_ generation: UInt64) async {
    let result: Result<ITerm2Connection, any Error>
    do {
      result = .success(try await establishConnection(generation))
    } catch {
      result = .failure(error)
    }
    guard let current = attempt, current.generation == generation else {
      if case .success(let stale) = result { await stale.close() }
      return
    }
    attempt = nil
    if case .success(let opened) = result { connection = opened }
    for waiter in current.waiters.values {
      waiter.resume(with: result)
    }
  } // End of func runAttempt(_:)

  /// Opens and authenticates a new connection for attempt `generation`, recording the outcome
  /// in the diagnostics log (the error kind only).
  private func establishConnection(_ generation: UInt64) async throws -> ITerm2Connection {
    let start = ContinuousClock.now
    do {
      let connection = try await connectAndAuthenticate(generation)
      await diagnostics?.record(
        .iTerm2, outcome: .success, durationMs: Self.milliseconds(since: start),
        detail: "connected to the iTerm2 API")
      return connection
    } catch {
      let kind = (error as? ITerm2Error)?.kind ?? "cancelled"
      await diagnostics?.record(
        .iTerm2, outcome: .failure, durationMs: Self.milliseconds(since: start),
        detail: "iTerm2 API connection failed: \(kind)")
      throw error
    }
  } // End of func establishConnection()

  /// The connection steps of attempt `generation`, in order: running check, socket check,
  /// fresh cookie, connect, handshake (the last two on a dedicated thread, bounded by
  /// `connectTimeout`). Right before asking for the cookie and right before connecting, the
  /// attempt makes sure it is still wanted (`attemptIsWanted(_:)`) and otherwise stops with
  /// `CancellationError`: one invalidated by `disconnect()`, or left by every caller, contacts
  /// iTerm2 no further.
  private func connectAndAuthenticate(_ generation: UInt64) async throws -> ITerm2Connection {
    guard await appControl.isRunning() else { throw ITerm2Error.notRunning }
    guard connector.endpointExists() else { throw ITerm2Error.apiDisabled }
    guard attemptIsWanted(generation) else { throw CancellationError() }
    let credentials = try await cookieProvider.requestCredentials()
    guard attemptIsWanted(generation) else { throw CancellationError() }
    let handshake: WebSocketHandshake
    do throws(WebSocketError) {
      handshake = try Self.handshake(credentials: credentials)
    } catch {
      throw ITerm2Error(error)
    }
    let connector = self.connector
    let deadline = ContinuousClock.now + configuration.connectTimeout
    let opened = try await DedicatedThread.run(name: "cc.carpio.muxfinder.iterm2-connect") {
      let stream = try connector.connect(deadline: deadline)
      do throws(WebSocketError) {
        let result = try handshake.perform(on: stream, deadline: deadline)
        return OpenedStream(
          stream: stream, remainder: result.remainder,
          protocolVersion: result.response.value(named: "X-iTerm2-Protocol-Version"))
      } catch {
        stream.shutDown()
        throw ITerm2Error(error)
      }
    }
    return await ITerm2Connection.start(
      stream: opened.stream, initialBytes: opened.remainder,
      protocolVersion: opened.protocolVersion, settings: connectionSettings)
  } // End of func connectAndAuthenticate()

  /// A stream whose handshake has completed.
  private struct OpenedStream: Sendable {
    /// The stream.
    let stream: any ByteStream
    /// Bytes that followed the handshake reply.
    let remainder: [UInt8]
    /// The reply's `X-iTerm2-Protocol-Version`.
    let protocolVersion: String?
  }

  /// The opening handshake iTerm2 accepts (PLAN.md *Verified facts*): the standard WebSocket
  /// headers with subprotocol `api.iterm2.com`, then `Origin`, the library version, the flag
  /// that keeps iTerm2 from showing its own authorization dialog, the cookie and key, and the
  /// advisory name.
  static func handshake(credentials: ITerm2Credentials) throws(WebSocketError)
    -> WebSocketHandshake
  {
    try WebSocketHandshake(
      subprotocol: Configuration.subprotocol,
      extraHeaders: [
        .init(name: "Origin", value: "ws://localhost/"),
        .init(name: "x-iterm2-library-version", value: Configuration.libraryVersion),
        .init(name: "x-iterm2-disable-auth-ui", value: "true"),
        .init(name: "x-iterm2-cookie", value: credentials.cookie),
        .init(name: "x-iterm2-key", value: credentials.key),
        .init(name: "x-iterm2-advisory-name", value: Configuration.advisoryName),
      ])
  } // End of func handshake(credentials:)

  /// Whole milliseconds elapsed since `start`.
  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    Int((ContinuousClock.now - start) / .milliseconds(1))
  }
}
