import Foundation

/// A scripted `ITerm2Integration` for tests: it never touches iTerm2, its socket, AppleScript or
/// `NSWorkspace`. Each operation returns queued results first, then a fallback, and every call
/// is logged.
///
/// It mirrors the real client's guard rails: while `script.isRunning` is `false`, every request
/// throws `notRunning`, and while `script.socketPresent` is `false`, `apiDisabled`, before any
/// scripted result is used. A successful `ensureRunning()` makes iTerm2 "run" with its socket
/// present.
public actor FakeITerm2Integration: ITerm2Integration {
  /// One recorded call, with its arguments.
  public enum Call: Sendable, Hashable {
    /// `isRunning()`.
    case isRunning
    /// `status()`.
    case status
    /// `ensureRunning()`.
    case ensureRunning
    /// `listSessions()`.
    case listSessions
    /// `createTab(_:)`.
    case createTab(ITerm2API.CreateTabRequest)
    /// `listTmuxConnections()`.
    case listTmuxConnections
    /// `sendTmuxCommand(_:connectionID:)`.
    case sendTmuxCommand(command: String, connectionID: String)
    /// `activate(_:)`.
    case activate(ITerm2API.ActivateRequest)
    /// `listProfiles(properties:guids:)`.
    case listProfiles(properties: [String], guids: [String])
    /// `disconnect()`.
    case disconnect
  }

  /// The results one operation returns: `queued` first, in order, then `fallback` forever.
  public struct Responses<Value: Sendable>: Sendable {
    /// Results still to be returned, first one next.
    public var queued: [Result<Value, ITerm2Error>]
    /// The result once `queued` is empty.
    public var fallback: Result<Value, ITerm2Error>

    /// Creates a sequence of results.
    public init(_ fallback: Result<Value, ITerm2Error>, queued: [Result<Value, ITerm2Error>] = []) {
      self.fallback = fallback
      self.queued = queued
    }

    /// Takes the next result.
    mutating func next() -> Result<Value, ITerm2Error> {
      queued.isEmpty ? fallback : queued.removeFirst()
    }
  }

  /// Everything the fake answers.
  public struct Script: Sendable {
    /// Whether iTerm2 "runs".
    public var isRunning = true
    /// Whether the API socket "exists".
    public var socketPresent = true
    /// The error `status()` reports while iTerm2 runs and the socket exists; `nil` reports a
    /// working connection.
    public var connectionError: ITerm2Error?
    /// `status()`'s protocol version when connected.
    public var protocolVersion: String?
    /// Results of `ensureRunning()`; success also sets `isRunning` and `socketPresent`.
    public var ensureRunning = Responses<Void>(.success(()))
    /// Results of `listSessions()`.
    public var listSessions = Responses(.success(ITerm2API.ListSessionsResponse()))
    /// Results of `createTab(_:)`.
    public var createTab = Responses(.success(ITerm2API.CreateTabResponse()))
    /// Results of `listTmuxConnections()`.
    public var listTmuxConnections = Responses<[ITerm2API.TmuxConnection]>(.success([]))
    /// Results of `sendTmuxCommand(_:connectionID:)`.
    public var sendTmuxCommand = Responses(.success(""))
    /// Results of `activate(_:)`.
    public var activate = Responses<Void>(.success(()))
    /// Results of `listProfiles(properties:guids:)`.
    public var listProfiles = Responses<[ITerm2API.Profile]>(.success([]))

    /// Creates the default script: iTerm2 runs, the socket exists, every request succeeds with
    /// an empty result.
    public init() {}
  }

  /// The current script.
  public private(set) var script: Script
  /// Every call so far, oldest first.
  public private(set) var calls: [Call] = []

  /// Creates a fake answering from `script`.
  public init(script: Script = Script()) {
    self.script = script
  }

  /// Changes the script.
  public func updateScript(_ change: @Sendable (inout Script) -> Void) {
    change(&script)
  }

  /// Forgets the recorded calls.
  public func clearCalls() {
    calls.removeAll()
  }

  /// Logs `isRunning()` and returns `script.isRunning`.
  public func isRunning() async -> Bool {
    calls.append(.isRunning)
    return script.isRunning
  }

  /// Logs `status()` and reports the script's state.
  public func status() async -> ITerm2Status {
    calls.append(.status)
    let error: ITerm2Error?
    if !script.isRunning {
      error = .notRunning
    } else if !script.socketPresent {
      error = .apiDisabled
    } else {
      error = script.connectionError
    }
    return ITerm2Status(
      isRunning: script.isRunning, socketPresent: script.socketPresent, isConnected: error == nil,
      protocolVersion: error == nil ? script.protocolVersion : nil, error: error)
  } // End of func status()

  /// Logs `ensureRunning()` and returns the next scripted result.
  public func ensureRunning() async throws {
    calls.append(.ensureRunning)
    try script.ensureRunning.next().get()
    script.isRunning = true
    script.socketPresent = true
  }

  /// Logs `listSessions()` and returns the next scripted result.
  public func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    calls.append(.listSessions)
    try checkReachable()
    return try script.listSessions.next().get()
  }

  /// Logs `createTab(_:)` and returns the next scripted result.
  public func createTab(
    _ request: ITerm2API.CreateTabRequest
  ) async throws -> ITerm2API.CreateTabResponse {
    calls.append(.createTab(request))
    try checkReachable()
    return try script.createTab.next().get()
  }

  /// Logs `listTmuxConnections()` and returns the next scripted result.
  public func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] {
    calls.append(.listTmuxConnections)
    try checkReachable()
    return try script.listTmuxConnections.next().get()
  }

  /// Logs `sendTmuxCommand(_:connectionID:)` and returns the next scripted result.
  public func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    calls.append(.sendTmuxCommand(command: command, connectionID: connectionID))
    try checkReachable()
    return try script.sendTmuxCommand.next().get()
  }

  /// Logs `activate(_:)` and returns the next scripted result.
  public func activate(_ request: ITerm2API.ActivateRequest) async throws {
    calls.append(.activate(request))
    try checkReachable()
    try script.activate.next().get()
  }

  /// Logs `listProfiles(properties:guids:)` and returns the next scripted result.
  public func listProfiles(
    properties: [String],
    guids: [String]
  ) async throws -> [ITerm2API.Profile] {
    calls.append(.listProfiles(properties: properties, guids: guids))
    try checkReachable()
    return try script.listProfiles.next().get()
  }

  /// Logs `disconnect()`.
  public func disconnect() async {
    calls.append(.disconnect)
  }

  /// Throws what the real client would before any request: `notRunning`, then `apiDisabled`.
  private func checkReachable() throws {
    guard script.isRunning else { throw ITerm2Error.notRunning }
    guard script.socketPresent else { throw ITerm2Error.apiDisabled }
  }
}
