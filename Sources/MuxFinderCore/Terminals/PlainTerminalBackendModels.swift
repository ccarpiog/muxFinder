import Foundation

/// The window half the plain backend (`PlainTerminalBackend`, PLAN.md D38, Phase I-12c1) needs
/// from the plain window layer: open and focus (it never closes a window by itself). The app
/// passes `PlainTerminalWindows`; tests pass `FakePlainTerminalWindowLayer`, whose open may
/// start a real helper on a pseudo-terminal of the test's. Main actor, as the layer is.
@MainActor
public protocol PlainTerminalWindowLayer: AnyObject, Sendable {
  /// `PlainTerminalWindows.open(_:helperPath:token:)`: opens a window of `loaded`'s app
  /// running `<helperPath> attach-plain <token>`.
  func open(
    _ loaded: LoadedTerminalDefinition,
    helperPath: String,
    token: LaunchToken
  ) throws(PlainTerminalWindowError) -> PlainTerminalWindow

  /// `PlainTerminalWindows.focus(_:of:)`: brings `window` forward by `loaded`'s focus kind.
  func focus(
    _ window: PlainTerminalWindow,
    of loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError)

  /// `PlainTerminalWindows.checkRunPolicy(for:)`: the layer's run policy for `loaded`'s app,
  /// asked right before a launch request is written (`unattendedRunRefused` refuses it).
  func checkRunPolicy(for loaded: LoadedTerminalDefinition) throws(PlainTerminalWindowError)
} // End of protocol PlainTerminalWindowLayer

/// The launch files the plain backend writes and reads (PLAN.md D14 *Plain modes*): the attach
/// coordinator's, plus the helper's early report, only ever peeked. `LaunchStore` is the
/// production implementation (tests use one on a private folder).
public protocol PlainLaunchRequestStore: LaunchRequestStore {
  /// Reads the early report for `id` without taking it, or `nil` while there is none; see
  /// `LaunchStore.peekReport(_:)`.
  func peekReport(_ id: LaunchToken) throws(LaunchStoreError) -> PlainLaunchReport?
}

extension LaunchStore: PlainLaunchRequestStore {}

/// A confirmed plain tmux client, as the bound commands need it (PLAN.md D38): the session's
/// identity (all six fields: id, creation time, server pid and start time, socket path and
/// name), the client's name, pid and creation time, and the launch that attached it (on an SSH
/// host also its token, the launch id at the end of the client's parent shell's arguments).
public struct PlainClientRecord: Sendable, Hashable {
  /// The session the client is attached to, as discovery reported it right before the launch.
  public let session: BoundSessionIdentity
  /// The client: its name (its terminal on that host), pid and creation time.
  public let client: OtherClient
  /// The launch that attached it (its request and result files' name).
  public let launchID: LaunchToken
  /// SSH hosts: the token the confirmation found at the end of the client's parent shell's
  /// arguments (the launch id); `nil` on This Mac.
  public let token: LaunchToken?
  /// This Mac: the terminal the helper's early report named (the client's `client_tty`);
  /// `nil` on an SSH host.
  public let terminalPath: String?

  /// Creates a record.
  public init(
    session: BoundSessionIdentity,
    client: OtherClient,
    launchID: LaunchToken,
    token: LaunchToken?,
    terminalPath: String?
  ) {
    self.session = session
    self.client = client
    self.launchID = launchID
    self.token = token
    self.terminalPath = terminalPath
  } // End of init(session:client:launchID:token:terminalPath:)

  /// The identity of `session` as discovery reported it, every field included (the name and
  /// socket path too, as `PlainClientDetach` needs them).
  public static func identity(of session: DiscoveredSession) -> BoundSessionIdentity {
    BoundSessionIdentity(
      sessionID: session.key.sessionID, serverPID: session.key.server.pid,
      serverStartTime: session.key.server.startTime, createdAt: session.createdAt,
      socketPath: session.key.server.socketPath, name: session.name)
  }
} // End of struct PlainClientRecord

/// One attachment the plain backend opened and confirmed (PLAN.md D38, requirement 7's
/// "sessions muxFinder opened"), kept in memory only: dropped once its helper's result appears
/// or a bound check finds its client gone, and never outliving the backend.
public struct PlainAttachment: Sendable, Hashable {
  /// The loaded definition whose window shows it.
  public let loaded: LoadedTerminalDefinition
  /// The window.
  public let window: PlainTerminalWindow
  /// The confirmed client.
  public let client: PlainClientRecord
  /// Where its bound commands run: This Mac or the SSH destination, with the host's override.
  public let target: PlainTmuxCommands.Target

  /// Creates an attachment.
  public init(
    loaded: LoadedTerminalDefinition,
    window: PlainTerminalWindow,
    client: PlainClientRecord,
    target: PlainTmuxCommands.Target
  ) {
    self.loaded = loaded
    self.window = window
    self.client = client
    self.target = target
  } // End of init(loaded:window:client:target:)

  /// The launch that opened it.
  public var launchID: LaunchToken { client.launchID }
} // End of struct PlainAttachment

/// How the plain backend's detach of its attachment's client went (PLAN.md D38; the plain part
/// of `SessionDetachResult`).
public struct PlainDetachResult: Sendable, Equatable {
  /// The client the bound detach was for.
  public var client: PlainClientRecord
  /// What the bound detach answered (`detached` or `notThisClient`); `nil` when it failed or
  /// did not run (see `failure`).
  public var outcome: PlainClientDetach.Outcome?
  /// Why the bound detach gave no answer (`cancelled` when the caller was cancelled before
  /// anything ran, `notWritable` when it cannot be written); `nil` when it answered.
  public var failure: PlainTmuxCommandFailure?
  /// The helper's result once its client was detached, when it arrived in time.
  public var helperResult: LaunchResult?

  /// Creates a result.
  public init(
    client: PlainClientRecord,
    outcome: PlainClientDetach.Outcome? = nil,
    failure: PlainTmuxCommandFailure? = nil,
    helperResult: LaunchResult? = nil
  ) {
    self.client = client
    self.outcome = outcome
    self.failure = failure
    self.helperResult = helperResult
  } // End of init(client:outcome:failure:helperResult:)
} // End of struct PlainDetachResult
