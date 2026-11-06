import Foundation

/// The terminal seam (PLAN.md D38, Phase I-12b3): the session operations the app and the
/// self-tests ask of whichever terminal app opens attachments, with the attach coordinator's
/// present signatures and result types.
///
/// The seam sits at the session operations, not below the coordinator: iTerm2's open,
/// confirmation by tmux connection, burial and detach are one flow over its API (D15, D29), so
/// iTerm2's backend (`ITerm2TerminalBackend`) forwards each operation to `AttachCoordinator`
/// unchanged. The plain backend for Terminal.app, Ghostty and other definitions
/// (`PlainTerminalBackend`, Phase I-12c1) builds on the plain window layer
/// (`PlainTerminalWindowLayer`, `PlainTerminalWindows`) and confirms, detaches and moves here
/// through tmux; the result types carry its plain states and payloads alongside iTerm2's.
/// "Open on this Mac" (Phase I-12c2) comes from process ancestry over discovery's
/// `client_pid`, `client_tty` and `client_created` (`LocalClientAttributor`): the plain
/// backend's attach brings such an app forward instead of opening a window (`appFocused`), and
/// every backend focuses an `.app` handle by activating that app. iTerm2's backend attaches as
/// before (no ancestry check).
///
/// Since Phase I-12c3a the app runs every session action on the seam: `AppModel` asks
/// `AppEnvironment.makeTerminalBackend` for the chosen terminal's backend (resolved from the
/// terminal setting, `TerminalChoice`) and keeps one per terminal id; the self-tests build
/// iTerm2's through the same seam, and the probe's `attach` and `new-session` run on it. The
/// connection detach (`AttachCoordinator.detach(connectionID:gatewaySessionID:launchID:)`) and
/// the `e2e-*` harnesses stay on the coordinator.
public protocol TerminalBackend: Sendable {
  /// The terminal app this backend opens attachments in.
  var terminal: LaunchTerminalApp { get }

  /// `AttachCoordinator.attach(_:)`: attaches `target`'s session, or focuses an attachment
  /// that exists already.
  func attach(_ target: AttachTarget) async -> AttachResult

  /// `AttachCoordinator.moveHere(_:confirmation:)` (PLAN.md D21): attaches `target`'s session
  /// here while tmux detaches its other clients; only with `confirmation` naming the session.
  func moveHere(
    _ target: AttachTarget,
    confirmation: MoveHereConfirmation
  ) async -> AttachResult

  /// `AttachCoordinator.createAndAttach(_:onCreated:)` (PLAN.md D18, D25): creates the session
  /// `request` describes, then attaches it; `onCreated` gets the created session first.
  func createAndAttach(
    _ request: NewSessionRequest,
    onCreated: (@Sendable (CreatedSession) -> Void)?
  ) async -> CreateAndAttachResult

  /// `AttachCoordinator.currentSession(named:on:)` (PLAN.md D25): the session named exactly
  /// `name` on `host` as discovery reports it now. Read-only.
  func currentSession(
    named name: String,
    on host: HostConfig
  ) async -> Result<AttachTarget, AttachFailure>

  /// `AttachCoordinator.detach(session:on:)` (PLAN.md D16): detaches every attachment of the
  /// session `key` this Mac shows.
  func detach(session key: SessionKey, on host: HostConfig) async -> SessionDetachResult

  /// `AttachCoordinator.detachOtherClients(of:confirmation:)` (PLAN.md D37): keeps this Mac's
  /// attachment and detaches every other client of the session; only with `confirmation`
  /// naming the session.
  func detachOtherClients(
    of target: AttachTarget,
    confirmation: DetachOtherClientsConfirmation
  ) async -> DetachOtherClientsResult

  /// `AttachCoordinator.state(of:)`: the latest state of `key`'s most recent attach, or `nil`
  /// if it was never attached.
  func state(of key: SessionKey) async -> AttachState?

  /// Whether this backend holds a launch of `key` that may still attach the session (PLAN.md
  /// D21, D38): one that runs, or one that ended without proof that its helper ended (no helper
  /// result seen yet). Read-only: nothing is written, sent or settled, and no terminal app is
  /// asked. `AppModel` asks every other backend it built before an Open or a Move here, so a
  /// change of terminal never starts a second attach of a session an earlier launch may still
  /// attach (Phase I-12c3a review fix).
  func hasUnresolvedLaunch(for key: SessionKey) async -> Bool

  /// Brings forward an attachment this backend opened, by its terminal-neutral handle. A
  /// handle of another terminal's backend is refused (`handleOfAnotherTerminal`) with nothing
  /// sent. An `.app` handle (a session open in that app on This Mac) belongs to no backend:
  /// every backend activates the running app (`appActivation`), launching nothing.
  func focus(_ handle: TerminalAttachmentHandle) async -> TerminalFocusResult
} // End of protocol TerminalBackend

extension TerminalBackend {
  /// `createAndAttach(_:onCreated:)` with no `onCreated`, as the coordinator's default.
  public func createAndAttach(_ request: NewSessionRequest) async -> CreateAndAttachResult {
    await createAndAttach(request, onCreated: nil)
  }
}

/// An attachment a terminal backend opened, as every backend names it for a focus (PLAN.md
/// D38, Phase I-12b3).
public enum TerminalAttachmentHandle: Sendable, Hashable {
  /// iTerm2: the launch tab's iTerm2 session id (`AttachResult.gatewaySessionID`), brought
  /// forward with `AttachCoordinator.showLaunchTab(_:)` ("Show tab", PLAN.md D25).
  case iTerm2LaunchTab(sessionID: String)
  /// Another terminal app's window, as `PlainTerminalWindows.open(_:helperPath:token:)`
  /// returned it.
  case plainWindow(PlainTerminalWindow)
  /// A terminal app on This Mac that a client of the session runs in, as process ancestry
  /// named it (PLAN.md D38, Phase I-12c2): brought forward by activating the running app
  /// through `TerminalAppActivating` (no Apple event, never a launch), by any backend.
  case app(LocalTerminalApp)

  /// The terminal app the handle belongs to (for `.app`, the app's own terminal: iTerm2, or
  /// its first definition's).
  public var terminal: LaunchTerminalApp {
    switch self {
    case .iTerm2LaunchTab: return .iterm2
    case .plainWindow(let window): return .plain(definitionID: window.definitionID)
    case .app(let app): return app.terminal
    }
  }
} // End of enum TerminalAttachmentHandle

/// How a focus through the terminal seam ended.
public enum TerminalFocusResult: Sendable, Hashable {
  /// iTerm2: what `AttachCoordinator.showLaunchTab(_:)` returned, unchanged.
  case launchTab(LaunchTabShowResult)
  /// A plain window was brought forward (or, with a definition's `app` focus, its app).
  case plainWindowFocused
  /// A plain window could not be brought forward; nothing was retried (D13).
  case plainWindowFailed(PlainTerminalWindowError)
  /// The handle belongs to another terminal's backend (a plain window given to iTerm2's, an
  /// iTerm2 launch tab given to a plain one): nothing was sent.
  case handleOfAnotherTerminal
  /// An `.app` handle: how activating the running app went (`notRunning`: nothing launched;
  /// `refused`: macOS's cooperative activation did not bring it forward).
  case appActivation(TerminalAppActivation)

  /// A short machine-readable name: `launchTab`, `plainWindowFocused`, `plainWindowFailed`,
  /// `handleOfAnotherTerminal` or `appActivation`.
  public var kind: String {
    switch self {
    case .launchTab: return "launchTab"
    case .plainWindowFocused: return "plainWindowFocused"
    case .plainWindowFailed: return "plainWindowFailed"
    case .handleOfAnotherTerminal: return "handleOfAnotherTerminal"
    case .appActivation: return "appActivation"
    }
  } // End of var kind
} // End of enum TerminalFocusResult
