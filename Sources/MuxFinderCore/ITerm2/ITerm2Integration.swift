import Foundation

/// What `ITerm2Integration.status()` found out about iTerm2's API.
public struct ITerm2Status: Sendable, Hashable {
  /// Whether iTerm2 is running.
  public var isRunning: Bool
  /// Whether the API socket file exists.
  public var socketPresent: Bool
  /// Whether an authenticated API connection is open.
  public var isConnected: Bool
  /// The `X-iTerm2-Protocol-Version` header of the handshake reply, when connected and sent.
  public var protocolVersion: String?
  /// Why no connection could be opened; `nil` when connected.
  public var error: ITerm2Error?

  /// Creates a status.
  public init(
    isRunning: Bool,
    socketPresent: Bool,
    isConnected: Bool,
    protocolVersion: String? = nil,
    error: ITerm2Error? = nil
  ) {
    self.isRunning = isRunning
    self.socketPresent = socketPresent
    self.isConnected = isConnected
    self.protocolVersion = protocolVersion
    self.error = error
  } // End of init(isRunning:socketPresent:isConnected:protocolVersion:error:)
}

/// The boundary between muxFinder and iTerm2 (PLAN.md D1). The app depends only on this
/// protocol, so the backend can be replaced; `ITerm2APIClient` implements it with iTerm2's
/// native API and `FakeITerm2Integration` with scripted results for tests.
///
/// Every method that talks to iTerm2 connects on demand with a fresh cookie and never launches
/// iTerm2; only `ensureRunning()` may launch it, and only the attach path calls that. Failures
/// are `ITerm2Error`s (or `CancellationError` when the calling task is cancelled); the
/// `ITerm2Error` documentation says which ones mean a request was not sent, answered, or sent
/// with an unknown outcome.
public protocol ITerm2Integration: Sendable {
  /// Whether iTerm2 is running. Never launches it.
  func isRunning() async -> Bool

  /// Reports whether iTerm2 runs, whether its API socket exists and whether an authenticated
  /// connection succeeds (opening one if needed). Never launches iTerm2.
  func status() async -> ITerm2Status

  /// Launches iTerm2 if needed and waits until its API socket exists. Attach path only.
  func ensureRunning() async throws

  /// Every window, tab and session.
  func listSessions() async throws -> ITerm2API.ListSessionsResponse

  /// Opens a tab. Throws `createTabFailed` unless iTerm2 reports `OK`.
  func createTab(_ request: ITerm2API.CreateTabRequest) async throws
    -> ITerm2API.CreateTabResponse

  /// Every tmux integration (`tmux -CC`) connection.
  func listTmuxConnections() async throws -> [ITerm2API.TmuxConnection]

  /// Runs `command` on the tmux connection `connectionID` and returns its output. Throws
  /// `tmuxRequestFailed` unless iTerm2 reports `OK`.
  func sendTmuxCommand(_ command: String, connectionID: String) async throws -> String

  /// Runs `command` on the tmux connection `connectionID` only while iTerm2 lists that
  /// connection as owned by the session `owningSessionID`: it lists the connections and, if one
  /// has that id and owner, sends the command on the same API connection, never reconnecting in
  /// between. Connection ids are short names (`"tmux"`) that iTerm2 hands out again, for
  /// example after a restart, so every command meant for a connection muxFinder opened is bound
  /// to the launch tab that owns it this way.
  ///
  /// - Throws: `tmuxConnectionNotOwned` when no listed connection has that id and owner, and
  ///   `notSent(reason)` when the listing failed (in both cases the command was not sent);
  ///   otherwise what `sendTmuxCommand(_:connectionID:)` throws.
  func sendTmuxCommand(
    _ command: String,
    connectionID: String,
    ownedBy owningSessionID: String
  ) async throws -> String

  /// Brings a window, tab or session (and optionally iTerm2) forward. Throws `activateFailed`
  /// unless iTerm2 reports `OK`.
  func activate(_ request: ITerm2API.ActivateRequest) async throws

  /// Profiles with the requested properties (`properties` empty: all of them), limited to
  /// `guids` (empty: every profile).
  func listProfiles(properties: [String], guids: [String]) async throws -> [ITerm2API.Profile]

  /// Closes sessions, tabs or windows by id and returns one status per id. Only for things the
  /// caller created itself (the e2e harness's own launch tabs); never used to detach tmux.
  func close(_ request: ITerm2API.CloseRequest) async throws -> ITerm2API.CloseResponse

  /// Closes the connection, if one is open, and invalidates a connection attempt in progress
  /// (its callers fail, and a connection it still opens is closed). The next call reconnects
  /// with a fresh cookie.
  func disconnect() async
}
