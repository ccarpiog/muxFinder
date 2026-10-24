import Foundation

/// A scripted `ITerm2Integration` for tests: it never touches iTerm2, its socket, AppleScript or
/// `NSWorkspace`. Each operation returns queued results first, then a fallback, and every call
/// is logged.
///
/// It mirrors the real client's guard rails: while `script.isRunning` is `false`, every request
/// throws `notRunning`, and while `script.socketPresent` is `false`, `apiDisabled`, before any
/// scripted result is used. A successful `ensureRunning()` makes iTerm2 "run" with its socket
/// present.
///
/// It keeps buried state the way iTerm2 3.7.6 does (PLAN.md Phase 13, S2, S3, S8) on top of the
/// scripted listings: a successful bury (`setBuried(true, …)`, or `buryLaunchTab` once its
/// check passed) moves the session out of its tab (a tab or window left empty goes too) into
/// `buried_sessions`; a successful restore of a buried session brings it back in a new window
/// of its own; both are idempotent (a second bury, or a restore of a session that is not
/// buried, changes nothing); and a session a `close(_:)` answered `OK` for is listed no more.
/// Only sessions a scripted listing names are placed this way, so a script that leaves the
/// launch tab out still leaves it out.
public actor FakeITerm2Integration: ITerm2Integration {
  /// Where the fake's buries, restores and closes put one session, over the scripted listings.
  public enum Placement: Sendable, Hashable {
    /// In `buried_sessions`, in no tab.
    case buried
    /// Restored after a bury, alone in the window `windowID` (S8).
    case restored(windowID: String)
    /// Closed: listed nowhere.
    case closed
  }

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
    /// `sendTmuxCommand(_:connectionID:ownedBy:)`, logged whether or not the command was sent.
    case sendOwnedTmuxCommand(command: String, connectionID: String, owningSessionID: String)
    /// `activate(_:)`, and the activation `activateFirstTab(ofTmuxConnection:ownedBy:options:)`
    /// sends once its checks passed.
    case activate(ITerm2API.ActivateRequest)
    /// `activateFirstTab(ofTmuxConnection:ownedBy:options:)`, logged whether or not anything
    /// was activated.
    case activateOwnedTmuxTab(connectionID: String, owningSessionID: String)
    /// `setBuried(_:sessionID:)`, and the bury `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)`
    /// sends once its check passed.
    case setBuried(buried: Bool, sessionID: String)
    /// `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)`, logged whether or not the bury was
    /// sent.
    case buryLaunchTab(sessionID: String, connectionID: String)
    /// `listProfiles(properties:guids:)`.
    case listProfiles(properties: [String], guids: [String])
    /// `close(_:)`.
    case close(ITerm2API.CloseRequest)
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
    /// Results of `sendTmuxCommand(_:connectionID:)`, and of
    /// `sendTmuxCommand(_:connectionID:ownedBy:)` once its ownership check passed.
    public var sendTmuxCommand = Responses(.success(""))
    /// Results of `activate(_:)`.
    public var activate = Responses<Void>(.success(()))
    /// Results of `setBuried(_:sessionID:)`, and of
    /// `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` once its ownership check passed.
    public var setBuried = Responses<Void>(.success(()))
    /// Results of `listProfiles(properties:guids:)`.
    public var listProfiles = Responses<[ITerm2API.Profile]>(.success([]))
    /// Results of `close(_:)`.
    public var close = Responses(.success(ITerm2API.CloseResponse()))

    /// Creates the default script: iTerm2 runs, the socket exists, every request succeeds with
    /// an empty result.
    public init() {}
  }

  /// The current script.
  public private(set) var script: Script
  /// Every call so far, oldest first.
  public private(set) var calls: [Call] = []
  /// The sessions the fake's buries, restores and closes moved, by session id.
  public private(set) var placements: [String: Placement] = [:]
  /// Numbers the windows restores open.
  private var restoredWindows = 0

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

  /// Logs `listSessions()` and returns the next scripted result, with the buried state applied.
  public func listSessions() async throws -> ITerm2API.ListSessionsResponse {
    calls.append(.listSessions)
    try checkReachable()
    return placed(try script.listSessions.next().get())
  }

  /// Whether the fake buried `sessionID` (and has not restored or closed it since).
  public func isBuried(_ sessionID: String) -> Bool {
    placements[sessionID] == .buried
  }

  /// What the helper's `Disinter` does (PLAN.md Phase 13, S7): restores `sessionID` if it is
  /// buried, as a successful restore would, without a request or a log entry.
  public func restoreAsTheHelperWould(_ sessionID: String) {
    restore(sessionID)
  }

  /// Applies a successful bury of `sessionID` (S2, S3): idempotent, and never for a closed one.
  private func bury(_ sessionID: String) {
    guard placements[sessionID] != .closed else { return }
    placements[sessionID] = .buried
  }

  /// Applies a successful restore of `sessionID`: a buried one comes back in a new window
  /// (S8); any other is left as it is (S2).
  private func restore(_ sessionID: String) {
    guard placements[sessionID] == .buried else { return }
    restoredWindows += 1
    placements[sessionID] = .restored(windowID: "fake-restored-window-\(restoredWindows)")
  }

  /// `listing` with every session the fake moved placed where it is now: out of its tab (a
  /// tab or window left without sessions is dropped), then into `buried_sessions`, a window of
  /// its own, or nowhere. A session the listing does not name stays unnamed.
  private func placed(_ listing: ITerm2API.ListSessionsResponse) -> ITerm2API.ListSessionsResponse {
    let moved = Set(placements.keys).intersection(listing.allSessionIDs)
    guard !moved.isEmpty else { return listing }
    var result = listing
    result.windows = listing.windows.compactMap { window in
      var kept = window
      kept.tabs = window.tabs.compactMap { tab in
        guard tab.sessions.contains(where: { moved.contains($0.uniqueIdentifier ?? "") }) else {
          return tab
        }
        var keptTab = tab
        keptTab.root = tab.root.flatMap { Self.node($0, without: moved) }
        keptTab.minimizedSessions = tab.minimizedSessions.filter {
          !moved.contains($0.uniqueIdentifier ?? "")
        }
        return keptTab.sessions.isEmpty ? nil : keptTab
      }
      return kept.tabs.isEmpty && !window.tabs.isEmpty ? nil : kept
    } // End of map over the listed windows
    result.buriedSessions = listing.buriedSessions.filter {
      !moved.contains($0.uniqueIdentifier ?? "")
    }
    for sessionID in moved.sorted() {
      switch placements[sessionID] {
      case .buried:
        result.buriedSessions.append(.init(uniqueIdentifier: sessionID))
      case .restored(let windowID):
        result.windows.append(
          .init(
            windowID: windowID,
            tabs: [
              .init(
                tabID: "\(windowID)-tab",
                root: .init(links: [.session(.init(uniqueIdentifier: sessionID))]))
            ]))
      case .closed, nil:
        continue
      }
    } // End of loop over the moved sessions
    return result
  } // End of func placed(_:)

  /// `node` without the sessions in `removed` (at any depth); `nil` when nothing is left.
  private static func node(
    _ node: ITerm2API.SplitTreeNode,
    without removed: Set<String>
  ) -> ITerm2API.SplitTreeNode? {
    var kept = node
    kept.links = node.links.compactMap { link -> ITerm2API.SplitTreeNode.Link? in
      switch link {
      case .session(let summary):
        return removed.contains(summary.uniqueIdentifier ?? "") ? nil : link
      case .node(let nested):
        return Self.node(nested, without: removed).map(ITerm2API.SplitTreeNode.Link.node)
      }
    }
    return kept.links.isEmpty ? nil : kept
  } // End of static func node(_:without:)

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

  /// Logs `sendTmuxCommand(_:connectionID:ownedBy:)` and checks ownership as the real client
  /// does: it takes the next `listTmuxConnections` result (a failure becomes `notSent`), throws
  /// `tmuxConnectionNotOwned` unless a listed connection has that id and owner, and only then
  /// takes the next `sendTmuxCommand` result.
  public func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String {
    calls.append(
      .sendOwnedTmuxCommand(
        command: command, connectionID: connectionID, owningSessionID: owningSessionID))
    try checkReachable()
    try requireTmuxConnection(connectionID, ownedBy: owningSessionID)
    return try script.sendTmuxCommand.next().get()
  } // End of func sendTmuxCommand(_:connectionID:ownedBy:)

  /// Logs `activate(_:)` and returns the next scripted result.
  public func activate(_ request: ITerm2API.ActivateRequest) async throws {
    calls.append(.activate(request))
    try checkReachable()
    try script.activate.next().get()
  }

  /// Logs `activateFirstTab(ofTmuxConnection:ownedBy:options:)` and checks as the real client
  /// does: it takes the next `listTmuxConnections` result (a failure becomes `notSent`), throws
  /// `tmuxConnectionNotOwned` unless a listed connection has that id and owner, then takes the
  /// next `listSessions` result (a failure becomes `notSent`) and, when a tab carries the
  /// connection, logs the activation as `activate(_:)` and takes the next `activate` result.
  public func activateFirstTab(
    ofTmuxConnection connectionID: String,
    ownedBy owningSessionID: String,
    options: ITerm2API.ActivateRequest
  ) async throws -> String? {
    calls.append(
      .activateOwnedTmuxTab(connectionID: connectionID, owningSessionID: owningSessionID))
    try checkReachable()
    try requireTmuxConnection(connectionID, ownedBy: owningSessionID)
    let sessions: ITerm2API.ListSessionsResponse
    switch script.listSessions.next() {
    case .success(let listed): sessions = placed(listed)
    case .failure(let error): throw error.isNotSent ? error : ITerm2Error.notSent(error)
    }
    guard
      let tabID = sessions.tabs(ofTmuxConnection: connectionID).lazy.compactMap(\.tabID)
        .first(where: { !$0.isEmpty })
    else { return nil }
    var request = options
    request.target = .tab(tabID)
    calls.append(.activate(request))
    try script.activate.next().get()
    return tabID
  } // End of func activateFirstTab(ofTmuxConnection:ownedBy:options:)

  /// Logs `setBuried(_:sessionID:)` and returns the next scripted result; a success buries or
  /// restores the session (see the type's documentation).
  public func setBuried(_ buried: Bool, sessionID: String) async throws {
    calls.append(.setBuried(buried: buried, sessionID: sessionID))
    try checkReachable()
    try script.setBuried.next().get()
    if buried { bury(sessionID) } else { restore(sessionID) }
  }

  /// Logs `buryLaunchTab(sessionID:ifOwnsTmuxConnection:)` and checks as the real client does:
  /// it takes the next `listTmuxConnections` result (a failure becomes `notSent`), throws
  /// `tmuxConnectionNotOwned` unless a listed connection has that id and is owned by
  /// `sessionID`, then logs the bury as `setBuried(true, sessionID:)` and takes the next
  /// `setBuried` result; a success buries the session.
  public func buryLaunchTab(
    sessionID: String,
    ifOwnsTmuxConnection connectionID: String
  ) async throws {
    calls.append(.buryLaunchTab(sessionID: sessionID, connectionID: connectionID))
    try checkReachable()
    try requireTmuxConnection(connectionID, ownedBy: sessionID)
    calls.append(.setBuried(buried: true, sessionID: sessionID))
    try script.setBuried.next().get()
    bury(sessionID)
  } // End of func buryLaunchTab(sessionID:ifOwnsTmuxConnection:)

  /// Takes the next `listTmuxConnections` result as a bound request's listing: a failure
  /// becomes `notSent`, and a listing without a connection of that id and owner is
  /// `tmuxConnectionNotOwned`.
  private func requireTmuxConnection(_ connectionID: String, ownedBy owningSessionID: String)
    throws
  {
    let connections: [ITerm2API.TmuxConnection]
    switch script.listTmuxConnections.next() {
    case .success(let listed): connections = listed
    case .failure(let error): throw error.isNotSent ? error : ITerm2Error.notSent(error)
    }
    guard
      connections.contains(where: {
        $0.connectionID == connectionID && $0.owningSessionID == owningSessionID
      })
    else { throw ITerm2Error.tmuxConnectionNotOwned }
  } // End of func requireTmuxConnection(_:ownedBy:)

  /// Logs `listProfiles(properties:guids:)` and returns the next scripted result.
  public func listProfiles(
    properties: [String],
    guids: [String]
  ) async throws -> [ITerm2API.Profile] {
    calls.append(.listProfiles(properties: properties, guids: guids))
    try checkReachable()
    return try script.listProfiles.next().get()
  }

  /// Logs `close(_:)` and returns the next scripted result; every session it answers `OK` for
  /// is listed no more.
  public func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse {
    calls.append(.close(request))
    try checkReachable()
    let response = try script.close.next().get()
    if case .sessions(let ids) = request.target {
      for (id, status) in zip(ids, response.statuses) where status == .ok {
        placements[id] = .closed
      }
    }
    return response
  } // End of func close(_:)

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
