import Foundation

/// The attach steps the iTerm2 coordinator (`AttachCoordinator`) and the plain backend
/// (`PlainTerminalBackend`, PLAN.md D38) both run, factored out of the coordinator unchanged so
/// neither copies them: the revalidation by discovery (D15 step 1), the lookup of a session by
/// name (D25) and the creation of a session (D18).
enum AttachSharedSteps {
  /// D15 step 1: discovers `target`'s host again and returns the session as it is now, if it is
  /// still the one `target` names (same key, same `session_created`), with the host as the
  /// attachment index matches it (`nil` when the discovery result carries no report). A key
  /// whose session id now names another session is `sessionChanged`; no such session, or no
  /// server, `sessionGone`; tmux missing `tmuxMissing`; any other discovery failure
  /// `discoveryFailed`; a cancelled caller `cancelled`.
  static func revalidate(
    _ target: AttachTarget,
    discovery: any HostDiscovering
  ) async -> Result<(DiscoveredSession, AttachmentIndex.Host?), AttachFailure> {
    let result: DiscoveryResult
    do {
      result = try await discovery.discover(target.host)
    } catch {
      return .failure(.cancelled)
    }
    switch result.status {
    case .ok(let sessions):
      if let fresh = sessions.first(where: { $0.key == target.key }) {
        guard fresh.createdAt == target.session.createdAt else { return .failure(.sessionChanged) }
        return .success((fresh, AttachmentIndex.Host(result)))
      }
      let reused = sessions.contains { $0.key.sessionID == target.key.sessionID }
      return .failure(reused ? .sessionChanged : .sessionGone)
    case .noServer:
      return .failure(.sessionGone)
    case .tmuxNotFound:
      return .failure(.tmuxMissing)
    default:
      return .failure(.discoveryFailed(result.status.kind))
    }
  } // End of static func revalidate(_:discovery:)

  /// The session named exactly `name` on `host` as discovery reports it now, as an attach
  /// target (PLAN.md D25). No session with exactly that name (none listed, or no server) is
  /// `sessionGone`; tmux missing `tmuxMissing`; any other discovery failure `discoveryFailed`;
  /// a cancelled caller `cancelled`. Read-only.
  static func currentSession(
    named name: String,
    on host: HostConfig,
    discovery: any HostDiscovering
  ) async -> Result<AttachTarget, AttachFailure> {
    let result: DiscoveryResult
    do {
      result = try await discovery.discover(host)
    } catch {
      return .failure(.cancelled)
    }
    switch result.status {
    case .ok(let sessions):
      guard let session = sessions.first(where: { $0.name == name }) else {
        return .failure(.sessionGone)
      }
      return .success(AttachTarget(host: host, session: session))
    case .noServer:
      return .failure(.sessionGone)
    case .tmuxNotFound:
      return .failure(.tmuxMissing)
    default:
      return .failure(.discoveryFailed(result.status.kind))
    }
  } // End of static func currentSession(named:on:discovery:)

  /// D18's creation: creates the session `request` describes through `creator` and records how
  /// it went (kinds and duration only). On success `onCreated` gets the created session first,
  /// then the success is recorded; a failure is recorded and returned, with nothing else run.
  static func createSession(
    _ request: NewSessionRequest,
    creator: any SessionCreating,
    clock: any AttachClock,
    diagnostics: DiagnosticsLog?,
    onCreated: (@Sendable (CreatedSession) -> Void)?
  ) async -> Result<CreatedSession, SessionCreationError> {
    let start = clock.now()
    let created: CreatedSession
    do throws(SessionCreationError) {
      created = try await creator.createSession(request)
    } catch {
      let detail = error.detail.map { " (\($0))" } ?? ""
      await diagnostics?.record(
        .attach, outcome: error == .timedOut ? .timedOut : .failure,
        hostID: request.host.id.uuidString,
        durationMs: AttachCoordinator.milliseconds(clock.now() - start),
        detail: "new session failed: \(error.kind)\(detail)")
      return .failure(error)
    }
    onCreated?(created)
    await diagnostics?.record(
      .attach, outcome: .success, hostID: request.host.id.uuidString,
      durationMs: AttachCoordinator.milliseconds(clock.now() - start),
      detail: "new session created")
    return .success(created)
  } // End of static func createSession(_:creator:clock:diagnostics:onCreated:)
} // End of enum AttachSharedSteps
