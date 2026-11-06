import Foundation
import os

/// A scripted `FolderSearchTransport` for tests (PLAN.md D36): it starts no process. Each open
/// makes a `FakeFolderSearchConnection` the test drives (a header, replies, an end) and inspects
/// (the lines sent, whether it was closed); `failNextOpens(_:with:)` makes opens throw.
public final class FakeFolderSearchTransport: FolderSearchTransport {
  /// Mutable state.
  private struct State {
    /// Every connection opened, in order.
    var connections: [FakeFolderSearchConnection] = []
    /// The hosts asked for, in order (failed opens included).
    var hosts: [FolderSearchHost] = []
    /// How many coming opens fail, and with what.
    var failures: [FolderSearchFailure] = []
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// A transport whose opens succeed.
  public init() {}

  /// Makes the next `count` opens throw `failure`.
  public func failNextOpens(_ count: Int, with failure: FolderSearchFailure) {
    state.withLock { $0.failures += Array(repeating: failure, count: count) }
  }

  /// Records the open and returns a new fake connection, or throws a failure set up first.
  public func open(
    _ host: FolderSearchHost
  ) async throws(FolderSearchFailure) -> any FolderSearchConnection {
    let outcome = state.withLock {
      state -> Result<FakeFolderSearchConnection, FolderSearchFailure> in
      state.hosts.append(host)
      if !state.failures.isEmpty { return .failure(state.failures.removeFirst()) }
      let connection = FakeFolderSearchConnection(host: host)
      state.connections.append(connection)
      return .success(connection)
    }
    return try outcome.get()
  } // End of func open(_:)

  /// Every connection opened, in order.
  public var connections: [FakeFolderSearchConnection] { state.withLock { $0.connections } }

  /// The hosts opens were asked for, in order.
  public var openedHosts: [FolderSearchHost] { state.withLock { $0.hosts } }

  /// The latest connection, if any.
  public var latest: FakeFolderSearchConnection? { connections.last }
}

/// One fake folder-search process: the test emits its events and reads what it was sent.
public final class FakeFolderSearchConnection: FolderSearchConnection {
  /// Mutable state.
  private struct State {
    /// The lines sent, as text.
    var lines: [String] = []
    /// Whether `close()` was called.
    var closed = false
    /// Whether the end was emitted.
    var ended = false
    /// Whether `send` fails.
    var sendFails = false
  }

  /// The host it was opened for.
  public let host: FolderSearchHost
  /// The events.
  public let events: AsyncStream<FolderSearchConnectionEvent>
  /// Where events go.
  private let sink: AsyncStream<FolderSearchConnectionEvent>.Continuation
  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// A connection for `host` with no events yet.
  init(host: FolderSearchHost) {
    self.host = host
    (events, sink) = AsyncStream.makeStream(of: FolderSearchConnectionEvent.self)
  }

  /// Emits `event`, unless the end was emitted already.
  public func emit(_ event: FolderSearchConnectionEvent) {
    let ended = state.withLock { state -> Bool in
      guard !state.ended else { return true }
      if case .ended = event { state.ended = true }
      return false
    }
    guard !ended else { return }
    sink.yield(event)
    if case .ended = event { sink.finish() }
  } // End of func emit(_:)

  /// Emits the end: the process exited with `code`, having written `standardError`.
  public func end(exitCode code: Int32 = 0, standardError: Data = Data()) {
    emit(
      .ended(FolderSearchConnectionEnd(termination: .exited(code), standardError: standardError)))
  }

  /// Makes every later `send` fail (or succeed again).
  public func setSendFails(_ fails: Bool) {
    state.withLock { $0.sendFails = fails }
  }

  /// Records `line`; fails when told to or once closed.
  public func send(_ line: Data) -> Bool {
    state.withLock { state -> Bool in
      guard !state.closed, !state.sendFails else { return false }
      state.lines.append(String(decoding: line, as: UTF8.self))
      return true
    }
  }

  /// Records the close and emits the end (exit 0) if it was not emitted yet.
  public func close() async {
    state.withLock { $0.closed = true }
    end()
  }

  /// The lines sent, as text, each with its line feed.
  public var sentLines: [String] { state.withLock { $0.lines } }

  /// Whether `close()` was called.
  public var isClosed: Bool { state.withLock { $0.closed } }

  /// The id of the `index`th line sent (0-based), if it has one.
  public func sentID(at index: Int) -> UInt64? {
    let lines = sentLines
    guard lines.indices.contains(index) else { return nil }
    return lines[index].split(separator: " ").first.flatMap { UInt64($0) }
  }
}
