import Foundation

/// "Set up SSH in iTerm2…" on the helper's side (PLAN.md D24): the one child that
/// `muxfinder-launch ssh-setup <launch id>` runs on its launch tab's terminal,
/// `/usr/bin/ssh -- <destination>`, plain and interactive, so the user can accept a host key,
/// sign in or unlock a key the way they always do, with their own configuration, keys and
/// agent.
///
/// The argv is built from data only: the fixed path, `--` (so nothing after it is read as an
/// option) and the destination, validated first (`Validation.sshDestination(_:)`: not empty, no
/// whitespace or control characters, no leading `-`). No option is added, nothing weakens
/// host-key checking, no remote command is sent (ssh starts the user's login shell there), and
/// no shell or AppleScript source is ever built.
public enum SSHSetup {
  /// The ssh client.
  public static let sshPath = RemoteLaunch.sshPath

  /// The ssh arguments after argv[0] for `destination`: `["--", destination]`, or `nil` when
  /// the destination fails `Validation.sshDestination(_:)`.
  public static func sshArguments(destination: String) -> [String]? {
    guard let valid = try? Validation.sshDestination(destination) else { return nil }
    return ["--", valid]
  }

  /// The ssh arguments after argv[0] for `request` (see `sshArguments(destination:)`).
  public static func sshArguments(for request: SSHSetupRequest) -> [String]? {
    sshArguments(destination: request.destination)
  }

  /// Maps how ssh ended to a failure, or `nil` when ssh reached the host. ssh exits with the
  /// remote login shell's status once it connected and signed in, and with 255 for its own
  /// errors: so any status but 255 means the setup did what it is for (the user logged out,
  /// whatever their last command returned), 255 is `sshFailed` with the class read from what
  /// ssh wrote on its standard error, and a signal is `childSignaled`.
  public static func failure(
    for termination: ProcessResult.Termination,
    sshStandardError: Data
  ) -> LaunchFailure? {
    switch termination {
    case .signaled(let signal):
      return .childSignaled(signal)
    case .exited(LaunchExitStatus.sshFailure):
      return .sshFailed(SSHFailureClass(standardError: sshStandardError))
    case .exited:
      return nil
    }
  } // End of func failure(for:sshStandardError:)
}

extension LaunchFailure {
  /// The plain one-paragraph explanation the helper prints in an ssh setup tab (PLAN.md D24),
  /// worded for ssh rather than for attaching a session. English, sentence case, no user data.
  public var sshSetupExplanation: String {
    switch self {
    case .sshFailed(.unreachable):
      return "ssh could not reach the host. Check that the host is on and connected, then "
        + "choose Set up SSH in iTerm2 again in muxFinder."
    case .sshFailed(.authFailed):
      return "ssh could not log in to the host. Any message from ssh is shown above."
    case .sshFailed(.hostKeyProblem):
      return "ssh did not accept the host's key (it is unknown or changed). Check the message "
        + "from ssh above; muxFinder never changes your known hosts."
    case .sshFailed(.other):
      return "ssh ended with an error. Any message from ssh is shown above."
    case .requestMissing:
      return "muxFinder's request for this tab was not found, so ssh was not started. It may "
        + "have been used already. Choose Set up SSH in iTerm2 again in muxFinder."
    case .requestExpired:
      return "muxFinder's request for this tab expired before the tab started, so ssh was not "
        + "started. Choose Set up SSH in iTerm2 again in muxFinder."
    case .requestUnreadable:
      return "muxFinder's request for this tab could not be used, so ssh was not started. "
        + "Choose Set up SSH in iTerm2 again in muxFinder."
    case .spawnFailed(let code):
      return "muxFinder could not start ssh: \(String(cString: strerror(code)))."
    case .interrupted(let signal):
      return "muxFinder was stopped by signal \(signal) before ssh started."
    case .childSignaled(let signal):
      return "ssh was stopped by signal \(signal)."
    case .childExited(let status):
      return "ssh ended with exit status \(status)."
    case .sessionGone, .sessionChanged, .tmuxMissing, .tmuxCheckFailed, .guardUsage, .usage,
      .launchDirectoryUnusable, .checkTimedOut:
      return explanation
    }
  } // End of var sshSetupExplanation
}
