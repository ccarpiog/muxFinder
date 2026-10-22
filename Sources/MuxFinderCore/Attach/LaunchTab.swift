import Foundation

/// The launch tab (PLAN.md D15): the one way muxFinder opens anything in iTerm2, shared by
/// attaches (`AttachCoordinator`) and "Set up SSH in iTerm2…" (`SSHSetupLauncher`, D24).
///
/// The tab is opened with `CreateTab` without a window id, so it opens in a new window and
/// never in one of the user's, with the host's profile (or iTerm2's default), the helper's
/// command line instead of the login shell, and `Close Sessions On End = true`, so it closes by
/// itself when the helper exits (which the helper never does before its 10 s minimum lifetime
/// while the tab is visible, D14). The request is sent once (D13).
public enum LaunchTab {
  /// The `CreateTab` request for a launch tab running `commandLine` (the helper's validated
  /// `<path> <mode> <launch id>`, `LaunchHelperPath.commandLine(for:kind:)`), with
  /// `profileName` (`nil`: iTerm2's default profile).
  public static func request(
    commandLine: String,
    profileName: String?
  ) -> ITerm2API.CreateTabRequest {
    ITerm2API.CreateTabRequest(
      profileName: profileName,
      customProfileProperties: ITerm2API.ProfileProperty.customCommand(commandLine)
        + [ITerm2API.ProfileProperty.closeSessionsOnEnd(true)])
  }

  /// Sends `request` once, in a task of its own, so cancelling the caller never loses the new
  /// tab's session id, and returns that session id. A tab reported without a session id is
  /// `ITerm2Error.protocolError`; any other failure is what `createTab(_:)` threw.
  static func open(
    _ request: ITerm2API.CreateTabRequest,
    on iTerm2: any ITerm2Integration
  ) async -> Result<String, any Error> {
    let created = await Task { () -> Result<ITerm2API.CreateTabResponse, any Error> in
      do {
        return .success(try await iTerm2.createTab(request))
      } catch {
        return .failure(error)
      }
    }.value
    switch created {
    case .failure(let error):
      return .failure(error)
    case .success(let response):
      guard let sessionID = response.sessionID, !sessionID.isEmpty else {
        return .failure(ITerm2Error.protocolError("the new tab has no session id"))
      }
      return .success(sessionID)
    }
  } // End of static func open(_:on:)
}
