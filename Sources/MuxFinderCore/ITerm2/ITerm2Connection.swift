import Foundation

/// Runs blocking work on a thread of its own, so it never occupies a thread of Swift's
/// cooperative pool.
enum DedicatedThread {
  /// Runs `work` on a new thread named `name` and returns its result.
  static func run<Value: Sendable>(
    name: String,
    _ work: @escaping @Sendable () throws -> Value
  ) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      let thread = Thread {
        continuation.resume(with: Result { try work() })
      }
      thread.name = name
      thread.start()
    }
  } // End of func run(name:_:)
}

/// Opens the byte stream to iTerm2's API socket. Behind a protocol so tests can hand out fake
/// streams.
protocol ITerm2SocketConnector: Sendable {
  /// Whether something exists at the socket path (cheap; no connection is made).
  func endpointExists() -> Bool
  /// Connects, waiting at most until `deadline`. Blocking: call it on a dedicated thread.
  ///
  /// - Throws: `ITerm2Error.apiDisabled` when the socket is missing or refuses connections,
  ///   `timedOut`, or `connectionFailed`.
  func connect(deadline: ContinuousClock.Instant) throws -> any ByteStream
}

/// The production connector: an `AF_UNIX` stream socket at a path.
struct UnixSocketConnector: ITerm2SocketConnector {
  /// The socket path.
  let path: String

  /// Whether a file exists at `path`.
  func endpointExists() -> Bool {
    FileManager.default.fileExists(atPath: path)
  }

  /// Connects to `path`, mapping "nothing there" and "nobody listening" to `apiDisabled`.
  func connect(deadline: ContinuousClock.Instant) throws -> any ByteStream {
    do throws(ByteStreamError) {
      return try UnixSocketStream.connect(toPath: path, deadline: deadline)
    } catch .systemCallFailed(_, let number)
      where number == ENOENT || number == ECONNREFUSED || number == ENOTSOCK
    {
      throw ITerm2Error.apiDisabled
    } catch {
      throw ITerm2Error(error)
    }
  } // End of func connect(deadline:)
}

/// One authenticated connection to iTerm2's API: sends requests and matches responses to them
/// by `id`.
///
/// A dedicated reader thread runs the `WebSocketReader` and hands whole messages to this actor
/// in order through an `AsyncStream`; writes go through the `WebSocketWriter`'s serial queue.
/// Neither blocks the cooperative pool. Request ids increase monotonically from 1. Responses may
/// arrive in any order; notifications (no `id`) and responses to unknown or abandoned ids are
/// ignored. A server `error` submessage fails only its request (`requestFailed`). A message that
/// cannot be decoded, or the end of the stream, fails every pending request and closes the
/// connection for good; the client then opens a new one with a fresh cookie.
///
/// Each request's frame is a `QueuedMessage` with the request's absolute deadline. A request
/// that fails before its frame has started writing (deadline, cancellation, connection end)
/// withdraws the frame, so iTerm2 never sees it, and the writer itself never starts a frame
/// after its deadline; such a request fails with `ITerm2Error.notSent(reason)`. A request that
/// fails once its frame has started writing keeps the plain reason (`timedOut`, `disconnected`,
/// …): the frame is still written whole and iTerm2 may act on it.
actor ITerm2Connection {
  /// Timing and size limits.
  struct Settings: Sendable {
    /// How long a request waits for its response.
    var requestTimeout: Duration = .seconds(10)
    /// How long one frame may take to write.
    var writeTimeout: Duration = .seconds(5)
    /// How long each read on the reader thread waits before it checks the connection again.
    var receivePollInterval: Duration = .seconds(5)
    /// How long a partly received message may go without new bytes before the connection is
    /// treated as stalled and closed (`timedOut`).
    var stallTimeout: Duration = .seconds(30)
    /// How long `close()` waits for the server's close reply.
    var closeTimeout: Duration = .seconds(1)
    /// The longest message accepted.
    var maximumMessageLength = WebSocketReader.defaultMaximumMessageLength
  }

  /// What the reader thread reports.
  enum ReceiveEvent: Sendable {
    /// A whole binary message.
    case message([UInt8])
    /// The connection ended; nothing follows.
    case ended(WebSocketError)
  }

  /// A request waiting for its response.
  private struct PendingRequest {
    /// Resumed with the response or the failure.
    let continuation: CheckedContinuation<ITerm2API.ServerOriginatedMessage.Response, any Error>
    /// Fails the request when its time is up; cancelled when it resolves first.
    let timeoutTask: Task<Void, Never>
    /// The request's frame in the writer's queue.
    let message: QueuedMessage
  }

  /// The writer shared with the reader thread.
  nonisolated let writer: WebSocketWriter
  /// The `X-iTerm2-Protocol-Version` header of the handshake reply, if iTerm2 sent one.
  nonisolated let protocolVersion: String?
  /// Timing and size limits.
  private let settings: Settings
  /// The id the next request gets.
  private var nextRequestID: Int64 = 1
  /// Requests waiting for responses, by id.
  private var pending: [Int64: PendingRequest] = [:]
  /// Why the connection is closed; `nil` while it is open.
  private var endReason: ITerm2Error?
  /// Whether the reader thread has finished.
  private var receiveEnded = false
  /// The task that consumes the reader thread's events.
  private var receiveTask: Task<Void, Never>?

  /// Creates a connection on an open stream; `start` begins receiving.
  private init(stream: any ByteStream, protocolVersion: String?, settings: Settings) {
    writer = WebSocketWriter(stream: stream, writeTimeout: settings.writeTimeout)
    self.protocolVersion = protocolVersion
    self.settings = settings
  }

  /// Shuts the stream down, which ends the reader thread, if nothing else did.
  deinit {
    writer.stream.shutDown()
  }

  /// Starts a connection on a stream whose WebSocket handshake has completed. `initialBytes`
  /// are bytes that arrived after the handshake reply.
  static func start(
    stream: any ByteStream,
    initialBytes: [UInt8],
    protocolVersion: String?,
    settings: Settings
  ) async -> ITerm2Connection {
    let connection = ITerm2Connection(
      stream: stream, protocolVersion: protocolVersion, settings: settings)
    let (events, continuation) = AsyncStream.makeStream(of: ReceiveEvent.self)
    let writer = connection.writer
    let thread = Thread {
      runReceiveLoop(
        stream: stream, writer: writer, initialBytes: initialBytes, settings: settings,
        events: continuation)
    }
    thread.name = "cc.carpio.muxfinder.iterm2-reader"
    thread.start()
    await connection.consume(events)
    return connection
  } // End of func start(stream:initialBytes:protocolVersion:settings:)

  /// The reader thread's body: reads messages until the connection ends and reports them.
  ///
  /// Each read waits at most `receivePollInterval`, so the thread never blocks forever. An idle
  /// connection is fine; a message that stops arriving halfway for `stallTimeout` ends the
  /// connection with `timedOut`.
  nonisolated static func runReceiveLoop(
    stream: any ByteStream,
    writer: WebSocketWriter,
    initialBytes: [UInt8],
    settings: Settings,
    events: AsyncStream<ReceiveEvent>.Continuation
  ) {
    var reader = WebSocketReader(
      stream: stream, writer: writer, initialBytes: initialBytes,
      maximumMessageLength: settings.maximumMessageLength)
    var progress = (byteCount: reader.receivedByteCount, since: ContinuousClock.now)
    while true {
      do throws(WebSocketError) {
        let message = try reader.receiveMessage(deadline: .now + settings.receivePollInterval)
        events.yield(.message(message))
      } catch .timedOut {
        let now = ContinuousClock.now
        if reader.receivedByteCount != progress.byteCount || !reader.hasPartialMessage {
          progress = (reader.receivedByteCount, now)
        } else if now - progress.since >= settings.stallTimeout {
          stream.shutDown()
          events.yield(.ended(.timedOut))
          break
        }
      } catch {
        events.yield(.ended(error))
        break
      }
    } // End of loop over received messages
    events.finish()
  } // End of func runReceiveLoop(stream:writer:initialBytes:settings:events:)

  /// Starts the task that hands the reader thread's events to this actor, in order.
  private func consume(_ events: AsyncStream<ReceiveEvent>) {
    receiveTask = Task { [weak self] in
      for await event in events {
        await self?.handle(event)
      }
    }
  }

  /// Whether the connection can still carry requests.
  var isOpen: Bool { endReason == nil }

  /// How many requests have been handed to the writer since the connection started (tests).
  private(set) var queuedRequestCount = 0

  /// Sends `request` and returns iTerm2's response.
  ///
  /// The request's deadline is `timeout` (default: the settings' request timeout) from now.
  /// Cancelling the calling task withdraws the request's frame at once if its write has not
  /// started, so it is then never sent.
  ///
  /// - Throws: `ITerm2Error.requestFailed` for an `error` submessage; `notSent(reason)` when
  ///   the request failed before its frame was written whole (`timedOut` at the deadline, or the
  ///   connection's end reason); the plain `timedOut` when the frame was written but no response
  ///   arrived by the deadline, or the plain end reason (`disconnected`, `protocolError`, …) when
  ///   the connection ended after the frame started writing; `CancellationError` if the calling
  ///   task is cancelled (sent or not).
  func send(
    _ request: ITerm2API.ClientOriginatedMessage.Request,
    timeout: Duration? = nil
  ) async throws -> ITerm2API.ServerOriginatedMessage.Response {
    if let endReason { throw ITerm2Error.notSent(endReason) }
    let id = nextRequestID
    nextRequestID += 1
    let message = QueuedMessage(
      payload: [UInt8](ITerm2API.ClientOriginatedMessage(id: id, request: request).encode()),
      deadline: .now + (timeout ?? settings.requestTimeout))
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        register(id: id, message: message, continuation: continuation)
      }
    } onCancel: {
      message.withdraw()
      Task { await self.abandon(id, with: CancellationError()) }
    }
  } // End of func send(_:timeout:)

  /// Records a request as pending, arms its timeout for the message's deadline and queues the
  /// message.
  private func register(
    id: Int64,
    message: QueuedMessage,
    continuation: CheckedContinuation<ITerm2API.ServerOriginatedMessage.Response, any Error>
  ) {
    if Task.isCancelled {
      continuation.resume(throwing: CancellationError())
      return
    }
    if let endReason {
      continuation.resume(throwing: ITerm2Error.notSent(endReason))
      return
    }
    let deadline = message.deadline ?? .now + settings.requestTimeout
    let timeoutTask = Task { [weak self] in
      do {
        try await Task.sleep(until: deadline, clock: .continuous)
      } catch {
        return
      }
      await self?.abandon(id, with: ITerm2Error.timedOut)
    }
    pending[id] = PendingRequest(
      continuation: continuation, timeoutTask: timeoutTask, message: message)
    writer.enqueue(message) { [weak self] result in
      guard case .failure(let failure) = result else { return }
      Task { await self?.abandon(id, with: ITerm2Error(failure)) }
    }
    queuedRequestCount += 1
  } // End of func register(id:message:continuation:)

  /// Fails the pending request `id`, if it is still pending; see `fail(_:with:)`. A response
  /// that arrives for it later is ignored.
  private func abandon(_ id: Int64, with error: any Error) {
    guard let request = pending.removeValue(forKey: id) else { return }
    fail(request, with: error)
  }

  /// Fails a request that is no longer pending. Its frame is withdrawn if its write has not
  /// started; when the frame is certain never to be written whole, an `ITerm2Error` becomes
  /// `notSent(error)`. `CancellationError` stays as it is.
  private func fail(_ request: PendingRequest, with error: any Error) {
    request.timeoutTask.cancel()
    let neverSent = request.message.withdraw()
    if neverSent, let reason = error as? ITerm2Error {
      request.continuation.resume(throwing: ITerm2Error.notSent(reason))
    } else {
      request.continuation.resume(throwing: error)
    }
  } // End of func fail(_:with:)

  /// Acts on one event from the reader thread.
  private func handle(_ event: ReceiveEvent) {
    switch event {
    case .message(let bytes):
      handleMessage(bytes)
    case .ended(let error):
      receiveEnded = true
      end(with: ITerm2Error(error))
    }
  }

  /// Routes one message to the request it answers.
  private func handleMessage(_ bytes: [UInt8]) {
    let message: ITerm2API.ServerOriginatedMessage
    do {
      message = try ITerm2API.ServerOriginatedMessage(decoding: Data(bytes))
    } catch {
      end(with: .protocolError("a message could not be decoded"))
      return
    }
    guard let id = message.id, let request = pending.removeValue(forKey: id) else { return }
    request.timeoutTask.cancel()
    switch message.response {
    case .error(let text)?:
      request.continuation.resume(throwing: ITerm2Error.requestFailed(text))
    case nil:
      request.continuation.resume(
        throwing: ITerm2Error.protocolError("a response carried no content"))
    case let response?:
      request.continuation.resume(returning: response)
    }
  } // End of func handleMessage(_:)

  /// Closes the connection for good: records `reason`, fails every pending request with it
  /// (withdrawing frames not yet started) and shuts the stream down once frames already queued
  /// (such as the reply to a server's close) are written. Later calls keep the first reason.
  private func end(with reason: ITerm2Error) {
    if endReason == nil { endReason = reason }
    let failed = pending
    pending = [:]
    for request in failed.values {
      fail(request, with: endReason ?? reason)
    }
    writer.shutDownAfterQueuedFrames()
  } // End of func end(with:)

  /// Closes the connection with the WebSocket close handshake: fails pending requests with
  /// `disconnected` (withdrawing frames not yet started), sends a close frame, waits up to the
  /// close timeout for the server's reply (not at all once the calling task is cancelled), then
  /// shuts the stream down.
  func close() async {
    guard endReason == nil else { return }
    endReason = .disconnected
    let failed = pending
    pending = [:]
    for request in failed.values {
      fail(request, with: ITerm2Error.disconnected)
    }
    let writer = self.writer
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      if !writer.enqueueClose(
        code: WebSocketFrame.normalClosure, completion: { _ in continuation.resume() })
      {
        continuation.resume()
      }
    }
    let deadline = ContinuousClock.now + settings.closeTimeout
    while !receiveEnded, ContinuousClock.now < deadline {
      do {
        try await Task.sleep(for: .milliseconds(10))
      } catch {
        break
      }
    } // End of loop waiting for the server's close reply
    writer.stream.shutDown()
  } // End of func close()
}
