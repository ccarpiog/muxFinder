import Dispatch
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// An in-memory `ByteStream` that hands out exactly the chunks a test delivers, one per read (a
/// chunk longer than the read's limit is split), and records everything written. Reads block on
/// the reader's own thread until a chunk arrives, the stream ends or the deadline passes. While
/// writes are held, a write blocks on the writer's thread before writing anything, until the
/// test releases writes, the stream is shut down or the write's deadline passes.
final class FakeByteStream: ByteStream {
  /// Lock-protected state.
  private struct State {
    /// Chunks not yet read, first one next.
    var chunks: [[UInt8]] = []
    /// Whether the peer "closed" after the queued chunks.
    var endOfStream = false
    /// Whether `shutDown()` ran.
    var isShutDown = false
    /// Every byte written, in order.
    var written: [UInt8] = []
    /// When set, every write fails with this error.
    var writeFailure: ByteStreamError?
    /// Whether writes block until released.
    var writesHeld = false
    /// How many writes are blocked right now.
    var blockedWrites = 0
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())
  /// Signalled whenever something a blocked read waits for may have happened.
  private let readable = DispatchSemaphore(value: 0)
  /// Signalled whenever something a blocked write waits for may have happened.
  private let writable = DispatchSemaphore(value: 0)

  /// Creates a stream whose first reads return `chunks`.
  init(chunks: [[UInt8]] = []) {
    state.withLock { $0.chunks = chunks }
  }

  /// Queues bytes for the client to read, as one chunk.
  func deliver(_ chunk: [UInt8]) {
    state.withLock { $0.chunks.append(chunk) }
    readable.signal()
  }

  /// Queues every byte of `bytes` as a chunk of its own.
  func deliverBytewise(_ bytes: [UInt8]) {
    for byte in bytes { deliver([byte]) }
  }

  /// Makes reads report end of stream once the queued chunks are gone.
  func deliverEndOfStream() {
    state.withLock { $0.endOfStream = true }
    readable.signal()
  }

  /// Makes every later write fail with `error`.
  func failWrites(with error: ByteStreamError) {
    state.withLock { $0.writeFailure = error }
  }

  /// Makes later writes block, before writing anything, until `releaseWrites()`.
  func holdWrites() {
    state.withLock { $0.writesHeld = true }
  }

  /// Lets blocked and later writes proceed.
  func releaseWrites() {
    state.withLock { $0.writesHeld = false }
    writable.signal()
  }

  /// Everything written so far.
  var written: [UInt8] { state.withLock { $0.written } }

  /// Whether `shutDown()` ran.
  var isShutDown: Bool { state.withLock { $0.isShutDown } }

  /// How many writes are blocked by `holdWrites()` right now.
  var blockedWrites: Int { state.withLock { $0.blockedWrites } }

  /// The `DispatchTime` `duration` from now, for semaphore waits.
  private static func dispatchTime(after duration: Duration) -> DispatchTime {
    let nanoseconds =
      duration.components.seconds * 1_000_000_000 + duration.components.attoseconds
      / 1_000_000_000
    return .now() + .nanoseconds(Int(nanoseconds) + 1)
  }

  /// Returns the next chunk; see `ByteStream.read(maximumLength:deadline:)`.
  func read(
    maximumLength: Int,
    deadline: ContinuousClock.Instant
  ) throws(ByteStreamError) -> [UInt8] {
    while true {
      let next: [UInt8]? = state.withLock { state in
        if state.isShutDown { return [] }
        if !state.chunks.isEmpty {
          let chunk = state.chunks.removeFirst()
          guard chunk.count > maximumLength else { return chunk }
          state.chunks.insert(Array(chunk[maximumLength...]), at: 0)
          return Array(chunk[..<maximumLength])
        }
        return state.endOfStream ? [] : nil
      }
      if let next { return next }
      let remaining = deadline - ContinuousClock.now
      guard remaining > .zero else { throw .timedOut }
      _ = readable.wait(timeout: Self.dispatchTime(after: remaining))
    } // End of loop until a chunk, end of stream or the deadline
  } // End of func read(maximumLength:deadline:)

  /// Records `bytes` all at once, or fails as configured. While writes are held it first
  /// blocks, writing nothing, until they are released, the stream is shut down or `deadline`
  /// passes (`timedOut`).
  func write(_ bytes: [UInt8], deadline: ContinuousClock.Instant) throws(ByteStreamError) {
    let held = state.withLock { state in
      if state.writesHeld { state.blockedWrites += 1 }
      return state.writesHeld
    }
    if held {
      defer { state.withLock { $0.blockedWrites -= 1 } }
      while state.withLock({ $0.writesHeld && !$0.isShutDown }) {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { throw .timedOut }
        _ = writable.wait(timeout: Self.dispatchTime(after: remaining))
      }
    }
    let failure: ByteStreamError? = state.withLock { state in
      if state.isShutDown { return .shutDown }
      if let failure = state.writeFailure { return failure }
      state.written.append(contentsOf: bytes)
      return nil
    }
    if let failure { throw failure }
  } // End of func write(_:deadline:)

  /// Ends the stream for reads and writes.
  func shutDown() {
    state.withLock { $0.isShutDown = true }
    readable.signal()
    writable.signal()
  }
}

/// Waits (asynchronously, polling) until `condition` holds, failing after `timeout`.
func waitUntil(
  timeout: Duration = .seconds(5),
  _ what: String,
  _ condition: () async throws -> Bool
) async throws {
  let deadline = ContinuousClock.now + timeout
  while try await !condition() {
    guard ContinuousClock.now < deadline else {
      Issue.record("timed out waiting until \(what)")
      throw CancellationError()
    }
    try await Task.sleep(for: .milliseconds(2))
  }
} // End of func waitUntil(timeout:_:_:)

/// Plays iTerm2's side of a `FakeByteStream`: answers the handshake, decodes the client's
/// (masked) frames and sends unmasked server frames.
struct FakeITerm2Peer {
  /// The stream shared with the client.
  let stream: FakeByteStream
  /// Decodes what the client wrote.
  private var decoder = WebSocketFrameDecoder(expectsMaskedFrames: true)
  /// How many written bytes have been fed to `decoder`.
  private var consumed = 0
  /// The handshake request, once received.
  private(set) var handshakeRequest = ""

  /// Creates a peer for `stream`.
  init(stream: FakeByteStream) {
    self.stream = stream
  }

  /// A request header's value from the received handshake, if present.
  func handshakeHeader(_ name: String) -> String? {
    for line in handshakeRequest.components(separatedBy: "\r\n") {
      guard let colon = line.firstIndex(of: ":") else { continue }
      if line[..<colon].caseInsensitiveCompare(name) == .orderedSame {
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      }
    }
    return nil
  }

  /// Waits for the client's handshake request and answers it: by default with a valid
  /// `101 Switching Protocols` reply, or with `status` (and no WebSocket headers) when given.
  /// `trailing` bytes are delivered in the same chunk as the reply.
  mutating func answerHandshake(status: Int = 101, trailing: [UInt8] = []) async throws {
    let terminator: [UInt8] = [13, 10, 13, 10]
    try await waitUntil("the client sent its handshake") {
      stream.written.firstRange(of: terminator) != nil
    }
    let written = stream.written
    let end = written.firstRange(of: terminator)!.upperBound
    handshakeRequest = String(decoding: written[..<end], as: UTF8.self)
    consumed = end
    let reply: String
    if status == 101 {
      let accept = WebSocketHandshake.acceptValue(forKey: handshakeHeader("Sec-WebSocket-Key")!)
      reply =
        "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
        + "Sec-WebSocket-Accept: \(accept)\r\nSec-WebSocket-Protocol: api.iterm2.com\r\n"
        + "X-iTerm2-Protocol-Version: 1.21\r\n\r\n"
    } else {
      reply = "HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\n\r\n"
    }
    stream.deliver(Array(reply.utf8) + trailing)
  } // End of func answerHandshake(status:trailing:)

  /// Waits for the client's next frame.
  mutating func nextFrame(timeout: Duration = .seconds(5)) async throws -> WebSocketFrame {
    let deadline = ContinuousClock.now + timeout
    while true {
      let written = stream.written
      if written.count > consumed {
        decoder.append(written[consumed...])
        consumed = written.count
      }
      if let frame = try decoder.nextFrame(
        maximumDataPayloadLength: .max, messageLimit: .max)
      {
        return frame
      }
      guard ContinuousClock.now < deadline else {
        Issue.record("timed out waiting for a client frame")
        throw CancellationError()
      }
      try await Task.sleep(for: .milliseconds(2))
    } // End of loop until a frame is complete
  } // End of func nextFrame(timeout:)

  /// Waits for the client's next request and returns its id and submessage field number.
  mutating func nextRequest() async throws -> ClientRequest {
    let frame = try await nextFrame()
    #expect(frame.opcode == .binary)
    #expect(frame.maskingKey != nil)
    return try ClientRequest(frame.payload)
  }

  /// Sends `payload` as one unmasked binary frame.
  func send(_ payload: [UInt8]) {
    stream.deliver(WebSocketFrame.encode(opcode: .binary, payload: payload, maskingKey: nil))
  }

  /// Sends `fixture`'s server message as the response to request `id` (an `id` field appended
  /// at the end overrides the fixture's own, as protobuf keeps the last value).
  func respond(to id: Int64, withFixture fixture: String) throws {
    send(try Array(ITerm2Fixture.data(fixture)) + ServerMessage.idField(id))
  }
}

/// A request the fake peer received: its id and the field number of its submessage.
struct ClientRequest {
  /// `id` (1).
  var id: Int64
  /// The submessage's field number (106 list sessions, 124 tmux, …).
  var fieldNumber: Int
  /// The raw protobuf bytes.
  var bytes: [UInt8]

  /// Decodes the envelope fields muxFinder sends.
  init(_ bytes: [UInt8]) throws {
    var reader = ProtoReader(bytes: bytes)
    var id: Int64 = -1
    var fieldNumber = 0
    while let field = try reader.nextField() {
      if field.number == 1, field.wireType == .varint {
        id = try reader.readInt64()
      } else {
        fieldNumber = field.number
        try reader.skip(field.wireType)
      }
    }
    self.id = id
    self.fieldNumber = fieldNumber
    self.bytes = bytes
  } // End of init(_:)
}

/// Builds server messages for the fake peer.
enum ServerMessage {
  /// The `id` field (1) on its own.
  static func idField(_ id: Int64) -> [UInt8] {
    var writer = ProtoWriter()
    writer.writeInt64(1, id)
    return writer.bytes
  }

  /// A message with `id` (when given) and an embedded submessage at `fieldNumber`.
  static func message(
    id: Int64?,
    fieldNumber: Int,
    _ build: (inout ProtoWriter) -> Void = { _ in }
  ) -> [UInt8] {
    var writer = ProtoWriter()
    if let id { writer.writeInt64(1, id) }
    writer.writeMessage(fieldNumber, build)
    return writer.bytes
  }

  /// A list-sessions response (106) holding one window with the id `window`.
  static func listSessions(id: Int64?, window: String) -> [UInt8] {
    message(id: id, fieldNumber: 106) { response in
      response.writeMessage(1) { $0.writeString(2, window) }
    }
  }

  /// An `error` (2) response.
  static func error(id: Int64, _ text: String) -> [UInt8] {
    var writer = ProtoWriter()
    writer.writeInt64(1, id)
    writer.writeString(2, text)
    return writer.bytes
  }
}

/// A cookie provider that hands out queued results and counts its calls.
final class FakeCookieProvider: ITerm2CookieProvider {
  /// Results still to hand out; the last one repeats.
  private let results: OSAllocatedUnfairLock<[Result<ITerm2Credentials, ITerm2Error>]>
  /// Calls so far.
  private let callCount = OSAllocatedUnfairLock(initialState: 0)

  /// Creates a provider returning `results` in order.
  init(_ results: [Result<ITerm2Credentials, ITerm2Error>]) {
    self.results = OSAllocatedUnfairLock(initialState: results)
  }

  /// Creates a provider returning `cookie-1`/`key-1`, `cookie-2`/`key-2`, … on successive calls.
  static func numbered(_ count: Int = 5) -> FakeCookieProvider {
    FakeCookieProvider(
      (1...count).map { .success(try! ITerm2Credentials(cookie: "cookie-\($0)", key: "key-\($0)")) }
    )
  }

  /// How many times credentials were requested.
  var calls: Int { callCount.withLock { $0 } }

  /// Returns the next result.
  func requestCredentials() async throws -> ITerm2Credentials {
    callCount.withLock { $0 += 1 }
    let result = results.withLock { results in
      results.count > 1 ? results.removeFirst() : results[0]
    }
    return try result.get()
  }
}

/// A cookie provider whose first request suspends until the test calls `release()`; every
/// call `n` then returns `cookie-n`/`key-n`. As a safety net against a test that fails before
/// releasing, the first request also resumes on its own after `safetyTimeout`.
final class GatedCookieProvider: ITerm2CookieProvider {
  /// Lock-protected state.
  private struct State {
    /// Calls so far.
    var calls = 0
    /// Whether `release()` ran.
    var released = false
    /// The suspended first request, if it is waiting.
    var waiter: CheckedContinuation<Void, Never>?
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())
  /// How long the first request waits at most.
  private let safetyTimeout: Duration

  /// Creates a provider whose first request waits at most `safetyTimeout`.
  init(safetyTimeout: Duration = .seconds(10)) {
    self.safetyTimeout = safetyTimeout
  }

  /// How many times credentials were requested.
  var calls: Int { state.withLock { $0.calls } }

  /// Lets the first request continue.
  func release() {
    let waiter = state.withLock { state in
      state.released = true
      defer { state.waiter = nil }
      return state.waiter
    }
    waiter?.resume()
  }

  /// Returns numbered credentials, the first time only after `release()`.
  func requestCredentials() async throws -> ITerm2Credentials {
    let call = state.withLock { state in
      state.calls += 1
      return state.calls
    }
    if call == 1 {
      let safetyTimeout = self.safetyTimeout
      let safetyNet = Task { [weak self] in
        try? await Task.sleep(for: safetyTimeout)
        self?.release()
      }
      await withCheckedContinuation { continuation in
        let resumeNow = state.withLock { state in
          if state.released { return true }
          state.waiter = continuation
          return false
        }
        if resumeNow { continuation.resume() }
      }
      safetyNet.cancel()
    }
    return try ITerm2Credentials(cookie: "cookie-\(call)", key: "key-\(call)")
  } // End of func requestCredentials()
}

/// An app control with a settable running state that counts launches.
final class FakeAppControl: ITerm2AppControl {
  /// Whether iTerm2 "runs", and how often `launch()` ran.
  private let state: OSAllocatedUnfairLock<(running: Bool, launches: Int)>
  /// Runs on every launch (for example to make the socket appear).
  private let onLaunch: @Sendable () -> Void

  /// Creates a control.
  init(running: Bool = true, onLaunch: @escaping @Sendable () -> Void = {}) {
    state = OSAllocatedUnfairLock(initialState: (running, 0))
    self.onLaunch = onLaunch
  }

  /// How many times `launch()` ran.
  var launches: Int { state.withLock { $0.launches } }

  /// Whether iTerm2 "runs".
  func isRunning() async -> Bool { state.withLock { $0.running } }

  /// "Launches" iTerm2.
  func launch() async throws {
    state.withLock {
      $0.running = true
      $0.launches += 1
    }
    onLaunch()
  }
}

/// A connector that hands out queued fake streams.
final class FakeConnector: ITerm2SocketConnector {
  /// Lock-protected state.
  private struct State {
    /// Whether the socket "exists".
    var exists = true
    /// Streams still to hand out.
    var streams: [FakeByteStream] = []
    /// When set, `connect` throws it.
    var connectError: ITerm2Error?
    /// How many times `connect` ran.
    var connects = 0
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a connector handing out `streams` in order.
  init(streams: [FakeByteStream] = [], exists: Bool = true) {
    state.withLock {
      $0.streams = streams
      $0.exists = exists
    }
  }

  /// Sets whether the socket "exists".
  func setExists(_ exists: Bool) { state.withLock { $0.exists = exists } }
  /// Makes `connect` throw `error`.
  func setConnectError(_ error: ITerm2Error?) { state.withLock { $0.connectError = error } }
  /// How many times `connect` ran.
  var connects: Int { state.withLock { $0.connects } }

  /// Whether the socket "exists".
  func endpointExists() -> Bool { state.withLock { $0.exists } }

  /// Hands out the next stream.
  func connect(deadline: ContinuousClock.Instant) throws -> any ByteStream {
    let result: Result<FakeByteStream, ITerm2Error> = state.withLock { state in
      state.connects += 1
      if let error = state.connectError { return .failure(error) }
      guard !state.streams.isEmpty else { return .failure(.apiDisabled) }
      return .success(state.streams.removeFirst())
    }
    return try result.get()
  }
}

/// Connection settings that keep tests fast.
let fastConnectionSettings: ITerm2Connection.Settings = {
  var settings = ITerm2Connection.Settings()
  settings.requestTimeout = .seconds(5)
  settings.writeTimeout = .seconds(2)
  settings.receivePollInterval = .milliseconds(20)
  settings.stallTimeout = .milliseconds(300)
  settings.closeTimeout = .milliseconds(300)
  return settings
}()
