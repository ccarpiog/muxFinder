import Foundation

/// iTerm2's backend of the terminal seam (PLAN.md D38, Phase I-12b3): an adapter over
/// `AttachCoordinator`. Every operation forwards to the coordinator's method of the same name
/// with the same arguments, in the caller's task (so cancellation reaches the coordinator as
/// before), and returns its result unchanged; iTerm2 keeps native control mode, launch tabs,
/// confirmation by tmux connection and burial exactly as they are (requirement 2).
///
/// A focus forwards an iTerm2 launch tab to `AttachCoordinator.showLaunchTab(_:)`; a plain
/// window is refused (`handleOfAnotherTerminal`) and nothing reaches the coordinator or
/// iTerm2. An `.app` handle (a session open in that app on This Mac, Phase I-12c2) activates
/// the running app through `appActivator`, never through the coordinator or iTerm2's API.
public struct ITerm2TerminalBackend: TerminalBackend {
  /// The coordinator every operation forwards to.
  public let coordinator: AttachCoordinator
  /// Brings an `.app` handle's app forward; `nil` uses `RunningApplicationActivator`.
  public let appActivator: (any TerminalAppActivating)?

  /// A backend over `coordinator`; `appActivator` brings `.app` handles forward (tests pass a
  /// fake).
  public init(coordinator: AttachCoordinator, appActivator: (any TerminalAppActivating)? = nil) {
    self.coordinator = coordinator
    self.appActivator = appActivator
  }

  /// Always `.iterm2`.
  public var terminal: LaunchTerminalApp { .iterm2 }

  /// `AttachCoordinator.attach(_:)`, unchanged.
  public func attach(_ target: AttachTarget) async -> AttachResult {
    await coordinator.attach(target)
  }

  /// `AttachCoordinator.moveHere(_:confirmation:)`, unchanged.
  public func moveHere(
    _ target: AttachTarget,
    confirmation: MoveHereConfirmation
  ) async -> AttachResult {
    await coordinator.moveHere(target, confirmation: confirmation)
  }

  /// `AttachCoordinator.createAndAttach(_:onCreated:)`, unchanged.
  public func createAndAttach(
    _ request: NewSessionRequest,
    onCreated: (@Sendable (CreatedSession) -> Void)?
  ) async -> CreateAndAttachResult {
    await coordinator.createAndAttach(request, onCreated: onCreated)
  }

  /// `AttachCoordinator.currentSession(named:on:)`, unchanged.
  public func currentSession(
    named name: String,
    on host: HostConfig
  ) async -> Result<AttachTarget, AttachFailure> {
    await coordinator.currentSession(named: name, on: host)
  }

  /// `AttachCoordinator.detach(session:on:)`, unchanged.
  public func detach(session key: SessionKey, on host: HostConfig) async -> SessionDetachResult {
    await coordinator.detach(session: key, on: host)
  }

  /// `AttachCoordinator.detachOtherClients(of:confirmation:)`, unchanged.
  public func detachOtherClients(
    of target: AttachTarget,
    confirmation: DetachOtherClientsConfirmation
  ) async -> DetachOtherClientsResult {
    await coordinator.detachOtherClients(of: target, confirmation: confirmation)
  }

  /// `AttachCoordinator.state(of:)`, unchanged.
  public func state(of key: SessionKey) async -> AttachState? {
    await coordinator.state(of: key)
  }

  /// A launch tab: `AttachCoordinator.showLaunchTab(_:)`'s result, unchanged. A plain window:
  /// `handleOfAnotherTerminal`, nothing run. An app: `appActivation` with the activator's
  /// outcome.
  public func focus(_ handle: TerminalAttachmentHandle) async -> TerminalFocusResult {
    switch handle {
    case .iTerm2LaunchTab(let sessionID):
      return .launchTab(await coordinator.showLaunchTab(sessionID))
    case .plainWindow:
      return .handleOfAnotherTerminal
    case .app(let app):
      return .appActivation(await RunningApplicationActivator.activate(app, with: appActivator))
    }
  }
} // End of struct ITerm2TerminalBackend
