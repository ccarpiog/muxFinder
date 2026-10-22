import Foundation

/// The remote attach the helper runs for an SSH host (PLAN.md D3, D4, D17): one interactive
/// `/usr/bin/ssh` child on the launch tab's terminal,
/// `/usr/bin/ssh -t -o ConnectTimeout=10 -- <destination> <D3 string>`, never with
/// `BatchMode`, so a person can answer a password or host-key prompt in the tab.
///
/// The D3 string is `ShellQuoting.remoteCommand(script: …, args: …)`: the static `script` (or,
/// for a move here, the static `moveHereScript`, PLAN.md D21) and the same five positional
/// parameters as the local check (`LaunchGuard.checkArguments(for:)`:
/// override, session id, server pid, server start time, creation time), each POSIX
/// single-quoted. No runtime value is ever part of shell source; the destination is one argv
/// element after `--`, validated first (`Validation.sshDestination(_:)`: no leading `-`, no
/// whitespace or control characters).
///
/// On the remote host the script locates tmux (`TmuxLocator`, D5), runs the guard's D4 identity
/// check (`LaunchGuard.check`, exit 64 gone, 65 changed, 66 tmux missing, 67 check failed, 68
/// usage) and, on a match, `exec`s `tmux -u -CC attach-session -t <id>` (`-d -t <id>` for a
/// move here) on the remote pseudo-terminal, so the check and the attach are one process a few
/// instructions apart. ssh
/// exits with the remote status (the guard's codes, or tmux's 0 after a detach) or 255 for its
/// own errors, which `LaunchFailure.from(_:host:sshStandardError:)` maps.
public enum RemoteLaunch {
  /// The ssh client.
  public static let sshPath = "/usr/bin/ssh"

  /// How long ssh may take to open the TCP connection, in seconds: an unreachable host fails in
  /// the tab within this bound instead of the system's 75 s, before the attach's 20 s budget.
  /// It does not limit authentication.
  public static let connectTimeoutSeconds = 10

  /// The options before `--`: a pseudo-terminal for the remote side (tmux's control mode needs
  /// one), and the connect timeout. Nothing here weakens host-key checking, and the user's own
  /// configuration, keys and agent apply as they are.
  public static let sshOptions = ["-t", "-o", "ConnectTimeout=\(connectTimeoutSeconds)"]

  /// The last step on the remote host, after a matching check: replace the shell with tmux's
  /// control-mode client, attached to the checked session id.
  static let attachTail: StaticShellScript = #"""
    exec "$t" -u -CC attach-session -t "$id"

    """#

  /// The last step of a move here (PLAN.md D21): the same attach with `-d`, so tmux detaches the
  /// session's other clients as it attaches.
  static let moveHereTail: StaticShellScript = #"""
    exec "$t" -u -CC attach-session -d -t "$id"

    """#

  /// The complete remote script: the tmux locator, the guard's identity check, then the attach.
  public static let script: StaticShellScript = TmuxLocator.script + LaunchGuard.check + attachTail

  /// The remote script of a move here: `script` with `moveHereTail` as its last step. A second
  /// static script rather than a switch inside one: the choice is made here, and the remote
  /// shell only ever receives constant text plus the five quoted check values (D3).
  public static let moveHereScript: StaticShellScript =
    TmuxLocator.script + LaunchGuard.check + moveHereTail

  /// The remote script for `request`: `moveHereScript` when it detaches the session's other
  /// clients (`LaunchRequest.detachesOtherClients`), otherwise `script`.
  public static func remoteScript(for request: LaunchRequest) -> StaticShellScript {
    request.detachesOtherClients ? moveHereScript : script
  }

  /// The D3 command string ssh hands the remote login shell for `request`.
  public static func command(for request: LaunchRequest) -> String {
    ShellQuoting.remoteCommand(
      script: remoteScript(for: request), args: LaunchGuard.checkArguments(for: request))
  }

  /// The ssh arguments after argv[0] for `request`, or `nil` when it is not an SSH request with
  /// a valid destination.
  public static func sshArguments(for request: LaunchRequest) -> [String]? {
    guard case .ssh(let raw) = request.host,
      let destination = try? Validation.sshDestination(raw)
    else { return nil }
    return sshOptions + ["--", destination, command(for: request)]
  } // End of func sshArguments(for:)
}
