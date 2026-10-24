import Foundation

/// An `ITerm2Integration` that forwards every call to `base` unchanged and records, in order,
/// each request that buries, restores or closes something: `setBuried(_:sessionID:)`,
/// `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` and `close(_:)`. A request is recorded
/// before it is forwarded, whatever its outcome (refused, failed, not sent), so one that
/// reached iTerm2 is recorded by the time its effect can show in a listing.
///
/// The e2e harnesses and the app's self-tests hand it to their coordinators, so a step can
/// prove that a launch tab left iTerm2 by itself (PLAN.md D29): no restore or `Close` of the
/// coordinator's (its recovery of a dead buried tab) targeted the tab before the step saw it
/// gone. An optional hook (`setBeforeBury(_:)`) runs right before each bury goes out, so
/// `e2e-bury` can look at the launch tab then and release a detach together with the bury; and
/// each bury's answer is recorded too (`buryAnswers`: answered `OK`, refused by its ownership
/// check, or failed, with when it was forwarded and when it returned), so that step can tell a
/// bury that was sent from one that was refused. It keeps session, tab and window ids and
/// times only, never content, and nothing leaves the process.
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

  /// What runs before a bury is recorded and forwarded: it gets the launch tab's session id
  /// and the connection the bury is bound to, and the bury waits until it returns.
  public typealias BuryHook = @Sendable (_ sessionID: String, _ connectionID: String) async -> Void

  /// How one `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` the recorder forwarded ended.
  public struct BuryAnswer: Sendable, Hashable {
    /// What `base` answered.
    public enum Outcome: Sendable, Hashable {
      /// It returned: iTerm2 answered the bury `OK`.
      case ok
      /// It threw this error (`tmuxConnectionNotOwned`: refused by its ownership check, so
      /// nothing was sent).
      case failed(ITerm2Error)
      /// It threw an error that is no `ITerm2Error` (a cancellation): the outcome is unknown.
      case failedOtherwise
    }

    /// The launch tab's session id.
    public var sessionID: String
    /// When the bury was forwarded to `base` (after the hook), wall clock.
    public var forwardedAt: Date
    /// When `base` returned or threw, wall clock.
    public var answeredAt: Date
    /// What `base` answered.
    public var outcome: Outcome

    /// Creates a record.
    public init(sessionID: String, forwardedAt: Date, answeredAt: Date, outcome: Outcome) {
      self.sessionID = sessionID
      self.forwardedAt = forwardedAt
      self.answeredAt = answeredAt
      self.outcome = outcome
    }
  } // End of struct BuryAnswer

  /// Where every call goes.
  private let base: any ITerm2Integration
  /// The recorded requests, oldest first.
  public private(set) var requests: [Request] = []
  /// How each forwarded bury ended, in the order the answers came.
  public private(set) var buryAnswers: [BuryAnswer] = []
  /// The hook run before each `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)`, if any.
  private var beforeBury: BuryHook?

  /// Forwards to `base`, recording as described above.
  public init(base: any ITerm2Integration) {
    self.base = base
  }

  /// Sets the hook run before each later `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` is
  /// recorded and forwarded (`nil` clears it). `setBuried(_:sessionID:)` never runs it.
  public func setBeforeBury(_ hook: BuryHook?) {
    beforeBury = hook
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

  /// How the forwarded buries of the session `sessionID` ended, in the order the answers came.
  public func buryAnswers(of sessionID: String) -> [BuryAnswer] {
    buryAnswers.filter { $0.sessionID == sessionID }
  }

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

  /// Runs the hook (`setBeforeBury(_:)`) if one is set and waits for it, then records the
  /// request, forwards it to `base` and records its answer (`buryAnswers`), passing any error
  /// on unchanged.
  public func buryLaunchTab(
    sessionID: String,
    ifOwnsTmuxConnection connectionID: String
  ) async throws {
    if let beforeBury { await beforeBury(sessionID, connectionID) }
    requests.append(.buryLaunchTab(sessionID: sessionID))
    let forwardedAt = Date()
    let record = { (outcome: BuryAnswer.Outcome) in
      BuryAnswer(
        sessionID: sessionID, forwardedAt: forwardedAt, answeredAt: Date(), outcome: outcome)
    }
    do {
      try await base.buryLaunchTab(sessionID: sessionID, ifOwnsTmuxConnection: connectionID)
      buryAnswers.append(record(.ok))
    } catch let error as ITerm2Error {
      buryAnswers.append(record(.failed(error)))
      throw error
    } catch {
      buryAnswers.append(record(.failedOtherwise))
      throw error
    }
  } // End of func buryLaunchTab(sessionID:ifOwnsTmuxConnection:)

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
