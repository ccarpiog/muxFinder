import Foundation

/// An `ITerm2Integration` that forwards every call to `base` unchanged and records, in order,
/// each request that buries, restores or closes something: `setBuried(_:sessionID:)`,
/// `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` and `close(_:)`. A request is recorded
/// before it is forwarded, whatever its outcome (refused, failed, not sent), so one that
/// reached iTerm2 is recorded by the time its effect can show in a listing.
///
/// The e2e harness hands it to its coordinators, so a step can prove that a launch tab left
/// iTerm2 by itself (PLAN.md D29): no restore or `Close` of the coordinator's (its recovery of
/// a dead buried tab) targeted the tab before the step saw it gone. It keeps session, tab and
/// window ids only, never content, and nothing leaves the process.
public actor RecordingITerm2Integration: ITerm2Integration {
  /// One recorded request.
  public enum Request: Sendable, Hashable {
    /// `setBuried(buried, sessionID:)`: a bury (`true`) or a restore (`false`).
    case setBuried(buried: Bool, sessionID: String)
    /// `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)`.
    case buryLaunchTab(sessionID: String)
    /// `close(_:)`.
    case close(ITerm2API.CloseRequest)
  }

  /// Where every call goes.
  private let base: any ITerm2Integration
  /// The recorded requests, oldest first.
  public private(set) var requests: [Request] = []

  /// Forwards to `base`, recording as described above.
  public init(base: any ITerm2Integration) {
    self.base = base
  }

  /// The recorded requests that may have restored or closed the session `sessionID`, oldest
  /// first: its restores (`setBuried(false, …)`), every `Close` naming it, and every `Close` of
  /// tabs or windows (one of them may hold it). Its buries are left out.
  public func restoresAndCloses(of sessionID: String) -> [Request] {
    requests.filter { request in
      switch request {
      case .setBuried(let buried, let id): return !buried && id == sessionID
      case .buryLaunchTab: return false
      case .close(let close):
        if case .sessions(let ids) = close.target { return ids.contains(sessionID) }
        return true
      }
    }
  } // End of func restoresAndCloses(of:)

  /// Forwards to `base`.
  public func isRunning() async -> Bool { await base.isRunning() }

  /// Forwards to `base`.
  public func status() async -> ITerm2Status { await base.status() }

  /// Forwards to `base`.
  public func ensureRunning() async throws { try await base.ensureRunning() }

  /// Forwards to `base`.
  public func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    try await base.listSessions()
  }

  /// Forwards to `base`.
  public func createTab(
    _ request: ITerm2API.CreateTabRequest
  ) async throws -> ITerm2API.CreateTabResponse {
    try await base.createTab(request)
  }

  /// Forwards to `base`.
  public func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection] {
    try await base.listTmuxConnections()
  }

  /// Forwards to `base`.
  public func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String {
    try await base.sendTmuxCommand(command, connectionID: connectionID)
  }

  /// Forwards to `base`.
  public func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String {
    try await base.sendTmuxCommand(command, connectionID: connectionID, ownedBy: owningSessionID)
  }

  /// Forwards to `base`.
  public func activate(_ request: ITerm2API.ActivateRequest) async throws {
    try await base.activate(request)
  }

  /// Forwards to `base`.
  public func activateFirstTab(
    ofTmuxConnection connectionID: String,
    ownedBy owningSessionID: String,
    options: ITerm2API.ActivateRequest
  ) async throws -> String? {
    try await base.activateFirstTab(
      ofTmuxConnection: connectionID, ownedBy: owningSessionID, options: options)
  }

  /// Records the request, then forwards it to `base`.
  public func setBuried(_ buried: Bool, sessionID: String) async throws {
    requests.append(.setBuried(buried: buried, sessionID: sessionID))
    try await base.setBuried(buried, sessionID: sessionID)
  }

  /// Records the request, then forwards it to `base`.
  public func buryLaunchTab(
    sessionID: String,
    ifOwnsTmuxConnection connectionID: String
  ) async throws {
    requests.append(.buryLaunchTab(sessionID: sessionID))
    try await base.buryLaunchTab(sessionID: sessionID, ifOwnsTmuxConnection: connectionID)
  }

  /// Forwards to `base`.
  public func listProfiles(
    properties: [String],
    guids: [String]
  ) async throws -> [ITerm2API.Profile] {
    try await base.listProfiles(properties: properties, guids: guids)
  }

  /// Records the request, then forwards it to `base`.
  public func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse {
    requests.append(.close(request))
    return try await base.close(request)
  }

  /// Forwards to `base`.
  public func disconnect() async { await base.disconnect() }
}
