import Foundation

/// Exit statuses of the guard script and of `muxfinder-launch` (PLAN.md D14).
///
/// The guard (the check child) owns 64–68. tmux itself only exits 0 or 1, and `/bin/sh` uses
/// 126/127 for an executable that cannot run and 128 + n for signals, so none of them collide.
/// The helper adds 2 (usage) and 70–75 for failures before or around its children, and 128 + n
/// when signal n stopped it before tmux attached; otherwise it exits with tmux's status (128 +
/// n when tmux was killed by signal n).
public enum LaunchExitStatus {
  /// The child exited 0: tmux attached and later detached normally.
  public static let success: Int32 = 0
  /// The helper was called with an unknown subcommand or a malformed launch id.
  public static let usage: Int32 = 2
  /// Guard: the session no longer exists, or no tmux server is running (PLAN.md D4).
  public static let sessionGone: Int32 = 64
  /// Guard: a session with this id exists but its server pid, server start time or creation
  /// time differs from the request (PLAN.md D4).
  public static let sessionChanged: Int32 = 65
  /// Guard: no usable tmux was found (PLAN.md D5), the same rule discovery reports as
  /// `HostStatus.tmuxNotFound`.
  public static let tmuxMissing: Int32 = 66
  /// Guard: tmux failed the check for another reason (for example permission denied on the
  /// socket, a protocol mismatch, or output the guard did not expect).
  public static let tmuxCheckFailed: Int32 = 67
  /// Guard: called with the wrong number or shape of arguments. Means a bug in muxFinder.
  public static let guardUsage: Int32 = 68
  /// Helper: no request file for the id (never written, already used, or swept).
  public static let requestMissing: Int32 = 70
  /// Helper: the request was older than `LaunchStore.timeToLive`; it was deleted.
  public static let requestExpired: Int32 = 71
  /// Helper: the request file was unsafe, too large, malformed or for another id.
  public static let requestUnreadable: Int32 = 72
  /// Helper: the launch directory is a symbolic link, not a directory or not owned by the user.
  public static let launchDirectoryUnusable: Int32 = 73
  /// Helper: a child process could not be started.
  public static let spawnFailed: Int32 = 74
  /// Helper: the check did not finish within its deadline; its process group was killed.
  public static let checkTimedOut: Int32 = 75
  /// Added to the signal number when the child was killed by a signal (shell convention).
  public static let signalBase: Int32 = 128
  /// The status ssh uses for its own errors (a remote attach, PLAN.md D17).
  public static let sshFailure: Int32 = 255
}

/// What kind of ssh failure ended a remote launch (ssh exited 255, PLAN.md D17), read from what
/// ssh wrote on its standard error with discovery's patterns (`ErrorClassifier`).
public enum SSHFailureClass: String, Sendable, Hashable, Codable, CaseIterable {
  /// The host could not be reached.
  case unreachable
  /// Authentication failed or needs interaction.
  case authFailed
  /// The host key is unknown or changed.
  case hostKeyProblem
  /// ssh failed for a reason that was not classified.
  case other

  /// The class of an ssh failure whose standard error was `standardError`: the case of the
  /// first `ErrorClassifier` pattern it contains (a changed host key before a failed
  /// verification), `other` when none matches.
  public init(standardError: Data) {
    switch ErrorClassifier.sshFailureStatus(stderr: standardError) {
    case .unreachable: self = .unreachable
    case .authFailed: self = .authFailed
    case .hostKeyProblem: self = .hostKeyProblem
    default: self = .other
    }
  }
}

/// Why a launch failed. Stored in result files as `{"kind": …}` plus the case's number, so
/// the encoding stays stable when cases are added.
public enum LaunchFailure: Sendable, Hashable, Codable {
  /// The session no longer exists, or no tmux server is running (guard exit 64).
  case sessionGone
  /// The session id now belongs to a different server or session (guard exit 65).
  case sessionChanged
  /// No usable tmux was found (guard exit 66).
  case tmuxMissing
  /// tmux could not run the identity check (guard exit 67).
  case tmuxCheckFailed
  /// The guard was called incorrectly (guard exit 68).
  case guardUsage
  /// ssh itself failed (exit status 255 of a remote attach), with the class its standard error
  /// showed (PLAN.md D17).
  case sshFailed(SSHFailureClass)
  /// The helper's arguments were not `attach <launch id>`.
  case usage
  /// No request file exists for the id.
  case requestMissing
  /// The request had expired; it was deleted.
  case requestExpired
  /// The request file could not be used.
  case requestUnreadable
  /// The launch directory is not safe to use.
  case launchDirectoryUnusable
  /// A child could not be started; `posix_spawn` failed with this errno.
  case spawnFailed(errno: Int32)
  /// The check did not finish within its deadline (a hung tmux server, for example); its
  /// whole process group was killed and nothing was attached.
  case checkTimedOut
  /// The helper received this signal (SIGHUP when the tab closed, SIGINT or SIGTERM) before
  /// tmux attached; the check, if running, was killed with its process group and nothing was
  /// attached.
  case interrupted(Int32)
  /// The attach child (tmux) was killed by this signal.
  case childSignaled(Int32)
  /// The attach child (tmux) exited with this status, which is none of the guard's own codes.
  case childExited(Int32)

  /// Maps how the check child ended to a failure, or `nil` for exit status 0 (the caller then
  /// validates the tmux path it printed, `LaunchGuard.tmuxPath(fromCheckOutput:request:)`).
  ///
  /// Pure and total: a timeout is `checkTimedOut` whatever the status, 64–68 are the guard's
  /// codes, and any other status or a signal means the check itself broke, `tmuxCheckFailed`.
  public static func fromCheck(
    _ termination: ProcessResult.Termination,
    timedOut: Bool
  ) -> LaunchFailure? {
    if timedOut { return .checkTimedOut }
    guard case .exited(let status) = termination else { return .tmuxCheckFailed }
    switch status {
    case LaunchExitStatus.success: return nil
    case LaunchExitStatus.sessionGone: return .sessionGone
    case LaunchExitStatus.sessionChanged: return .sessionChanged
    case LaunchExitStatus.tmuxMissing: return .tmuxMissing
    case LaunchExitStatus.guardUsage: return .guardUsage
    default: return .tmuxCheckFailed
    }
  } // End of func fromCheck(_:timedOut:)

  /// Maps how the attach child ended to a failure, or `nil` for exit status 0.
  ///
  /// Pure and total: 64–68 are the guard's codes (a remote attach runs the guard in the same
  /// command, and ssh exits with its status, PLAN.md D17), any other non-zero status is
  /// `childExited`, a signal is `childSignaled`. For an SSH host, 255 is ssh's own error,
  /// `sshFailed` with the class read from `sshStandardError` (what ssh wrote on its standard
  /// error); for a local launch 255 is an ordinary exit status.
  public static func from(
    _ termination: ProcessResult.Termination,
    host: LaunchHost,
    sshStandardError: Data = Data()
  ) -> LaunchFailure? {
    switch termination {
    case .signaled(let signal):
      return .childSignaled(signal)
    case .exited(let status):
      switch status {
      case LaunchExitStatus.success: return nil
      case LaunchExitStatus.sessionGone: return .sessionGone
      case LaunchExitStatus.sessionChanged: return .sessionChanged
      case LaunchExitStatus.tmuxMissing: return .tmuxMissing
      case LaunchExitStatus.tmuxCheckFailed: return .tmuxCheckFailed
      case LaunchExitStatus.guardUsage: return .guardUsage
      case LaunchExitStatus.sshFailure where host.isRemote:
        return .sshFailed(SSHFailureClass(standardError: sshStandardError))
      default:
        return .childExited(status)
      }
    }
  } // End of func from(_:host:sshStandardError:)

  /// The helper's exit status for this failure.
  public var exitStatus: Int32 {
    switch self {
    case .sessionGone: return LaunchExitStatus.sessionGone
    case .sessionChanged: return LaunchExitStatus.sessionChanged
    case .tmuxMissing: return LaunchExitStatus.tmuxMissing
    case .tmuxCheckFailed: return LaunchExitStatus.tmuxCheckFailed
    case .guardUsage: return LaunchExitStatus.guardUsage
    case .sshFailed: return LaunchExitStatus.sshFailure
    case .usage: return LaunchExitStatus.usage
    case .requestMissing: return LaunchExitStatus.requestMissing
    case .requestExpired: return LaunchExitStatus.requestExpired
    case .requestUnreadable: return LaunchExitStatus.requestUnreadable
    case .launchDirectoryUnusable: return LaunchExitStatus.launchDirectoryUnusable
    case .spawnFailed: return LaunchExitStatus.spawnFailed
    case .checkTimedOut: return LaunchExitStatus.checkTimedOut
    case .interrupted(let signal): return LaunchExitStatus.signalBase + signal
    case .childSignaled(let signal): return LaunchExitStatus.signalBase + signal
    case .childExited(let status): return status
    }
  } // End of var exitStatus

  /// A short machine-readable name, such as `sessionGone`. Used in result files and
  /// diagnostics.
  public var kind: String {
    switch self {
    case .sessionGone: return "sessionGone"
    case .sessionChanged: return "sessionChanged"
    case .tmuxMissing: return "tmuxMissing"
    case .tmuxCheckFailed: return "tmuxCheckFailed"
    case .guardUsage: return "guardUsage"
    case .sshFailed: return "sshFailed"
    case .usage: return "usage"
    case .requestMissing: return "requestMissing"
    case .requestExpired: return "requestExpired"
    case .requestUnreadable: return "requestUnreadable"
    case .launchDirectoryUnusable: return "launchDirectoryUnusable"
    case .spawnFailed: return "spawnFailed"
    case .checkTimedOut: return "checkTimedOut"
    case .interrupted: return "interrupted"
    case .childSignaled: return "childSignaled"
    case .childExited: return "childExited"
    }
  } // End of var kind

  /// The plain one-paragraph explanation the helper prints in the tab. English, sentence case,
  /// no user data.
  public var explanation: String {
    switch self {
    case .sessionGone:
      return "This tmux session no longer exists, or tmux is no longer running, so there is "
        + "nothing to attach. Refresh muxFinder to see the current sessions."
    case .sessionChanged:
      return "This tmux session changed since muxFinder last looked (for example, tmux "
        + "restarted and reused its id), so muxFinder did not attach it. Refresh muxFinder "
        + "and try again."
    case .tmuxMissing:
      return "muxFinder could not find tmux on this Mac. Install tmux, or check the tmux path "
        + "in muxFinder's host settings."
    case .tmuxCheckFailed:
      return "tmux could not check the session before attaching, so muxFinder did not attach "
        + "it. Any message from tmux is shown above."
    case .guardUsage:
      return "muxFinder started its session check incorrectly. This is a bug in muxFinder."
    case .sshFailed(.unreachable):
      return "ssh could not reach the host, so the session was not attached. Check that the "
        + "host is on and connected, then try again."
    case .sshFailed(.authFailed):
      return "ssh could not log in to the host, so the session was not attached. Any message "
        + "from ssh is shown above."
    case .sshFailed(.hostKeyProblem):
      return "ssh did not accept the host's key (it is unknown or changed), so the session was "
        + "not attached. Check the message from ssh above; muxFinder never changes your known "
        + "hosts."
    case .sshFailed(.other):
      return "ssh ended with an error, so the session was not attached. Any message from ssh "
        + "is shown above."
    case .usage:
      return "This helper only runs in tabs that muxFinder opens. Start the session from "
        + "muxFinder instead."
    case .requestMissing:
      return "muxFinder's launch request for this tab was not found. It may have been used "
        + "already. Start the session again from muxFinder."
    case .requestExpired:
      return "muxFinder's launch request for this tab expired before the tab started. Start "
        + "the session again from muxFinder."
    case .requestUnreadable:
      return "muxFinder's launch request for this tab could not be read, so nothing was "
        + "attached. Start the session again from muxFinder."
    case .launchDirectoryUnusable:
      return "muxFinder's launch folder is not safe to use: it must be a private folder owned "
        + "by you, not a link, with no access control list. Remove ~/Library/Application "
        + "Support/muxFinder/launch and try again."
    case .spawnFailed(let code):
      return "muxFinder could not start tmux or its session check: "
        + "\(String(cString: strerror(code)))."
    case .checkTimedOut:
      return "tmux did not answer muxFinder's session check in time, so muxFinder did not "
        + "attach the session. tmux may be busy or stuck. Try again in a moment."
    case .interrupted(let signal):
      return "muxFinder was stopped by signal \(signal) before tmux attached, so nothing was "
        + "attached."
    case .childSignaled(let signal):
      return "tmux was stopped by signal \(signal)."
    case .childExited(let status):
      return "tmux ended with exit status \(status)."
    }
  } // End of var explanation

  /// The explanation for a launch on `host`: `explanation`, with the wording that names this
  /// Mac or tmux alone adjusted for a remote host (tmux missing there, ssh not started).
  public func explanation(for host: LaunchHost) -> String {
    guard host.isRemote else { return explanation }
    switch self {
    case .tmuxMissing:
      return "muxFinder could not find tmux on the remote host. Install tmux there, or check the "
        + "tmux path in muxFinder's host settings."
    case .spawnFailed(let code):
      return "muxFinder could not start ssh: \(String(cString: strerror(code)))."
    case .childExited(let status):
      return "The remote session ended with exit status \(status)."
    case .childSignaled(let signal):
      return "ssh was stopped by signal \(signal)."
    default:
      return explanation
    }
  } // End of func explanation(for:)

  /// The JSON keys.
  private enum CodingKeys: String, CodingKey {
    /// `kind`.
    case kind
    /// The exit status of `childExited`.
    case status
    /// The signal of `childSignaled` and `interrupted`.
    case signal
    /// The errno of `spawnFailed`.
    case errno
    /// The class of `sshFailed`.
    case sshClass
  }

  /// Decodes `{"kind": …}` plus the case's field.
  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(String.self, forKey: .kind)
    switch kind {
    case "sessionGone": self = .sessionGone
    case "sessionChanged": self = .sessionChanged
    case "tmuxMissing": self = .tmuxMissing
    case "tmuxCheckFailed": self = .tmuxCheckFailed
    case "guardUsage": self = .guardUsage
    case "sshFailed":
      self = .sshFailed(try container.decode(SSHFailureClass.self, forKey: .sshClass))
    case "usage": self = .usage
    case "requestMissing": self = .requestMissing
    case "requestExpired": self = .requestExpired
    case "requestUnreadable": self = .requestUnreadable
    case "launchDirectoryUnusable": self = .launchDirectoryUnusable
    case "spawnFailed": self = .spawnFailed(errno: try container.decode(Int32.self, forKey: .errno))
    case "checkTimedOut": self = .checkTimedOut
    case "interrupted": self = .interrupted(try container.decode(Int32.self, forKey: .signal))
    case "childSignaled": self = .childSignaled(try container.decode(Int32.self, forKey: .signal))
    case "childExited": self = .childExited(try container.decode(Int32.self, forKey: .status))
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .kind,
        in: container,
        debugDescription: "Unknown launch failure."
      )
    }
  } // End of init(from:)

  /// Encodes `{"kind": …}` plus the case's field.
  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    switch self {
    case .sshFailed(let failureClass): try container.encode(failureClass, forKey: .sshClass)
    case .spawnFailed(let code): try container.encode(code, forKey: .errno)
    case .interrupted(let signal): try container.encode(signal, forKey: .signal)
    case .childSignaled(let signal): try container.encode(signal, forKey: .signal)
    case .childExited(let status): try container.encode(status, forKey: .status)
    default: break
    }
  } // End of func encode(to:)
}
