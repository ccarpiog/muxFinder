import Foundation

/// Why the persistent profile's helper starts the login shell instead of the persistent
/// session (PLAN.md D26). `explanation` is the one paragraph it prints in the tab: English,
/// sentence case, no user data.
public enum ProfileLaunchProblem: Error, Sendable, Hashable {
  /// `TMUX` or `MUXFINDER_LAUNCHED` (this variable) is set and not empty: the tab already runs
  /// inside tmux or inside something a muxFinder helper started (the nesting guard).
  case nested(variable: String)
  /// There is no `hosts.json`, so no host is known.
  case hostListMissing
  /// `hosts.json` cannot be used (left as it is).
  case hostListUnusable(HostFileProblem)
  /// `hosts.json`'s folder cannot be read.
  case hostListUnreadable(HostStoreError)
  /// No host in the list has the profile's host id.
  case hostUnknown
  /// The host's persistent profile is turned off.
  case notOptedIn
  /// The host's default session name is not usable.
  case invalidSessionName(ValidationError)
  /// The SSH host has no valid destination.
  case invalidDestination(ValidationError)
  /// The host's tmux path is not usable.
  case invalidTmuxPath(ValidationError)
  /// tmux (or ssh carrying it) failed on this host.
  case launchFailed(LaunchFailure, host: LaunchHost)

  /// A short machine-readable name (diagnostics hold this, never a value).
  public var kind: String {
    switch self {
    case .nested: return "nested"
    case .hostListMissing: return "hostListMissing"
    case .hostListUnusable: return "hostListUnusable"
    case .hostListUnreadable: return "hostListUnreadable"
    case .hostUnknown: return "hostUnknown"
    case .notOptedIn: return "notOptedIn"
    case .invalidSessionName: return "invalidSessionName"
    case .invalidDestination: return "invalidDestination"
    case .invalidTmuxPath: return "invalidTmuxPath"
    case .launchFailed(let failure, _): return "launchFailed." + failure.kind
    }
  } // End of var kind

  /// The helper's exit status when it ends without starting the login shell (test mode, a
  /// terminal that is not interactive, a closed tab, or a shell that cannot start, which
  /// reports `LaunchExitStatus.spawnFailed` instead): 77 for the nesting guard, 76 for every
  /// host-list problem, and the failure's own status for a failed launch.
  public var exitStatus: Int32 {
    switch self {
    case .nested: return LaunchExitStatus.nestedLaunch
    case .hostListMissing, .hostListUnusable, .hostListUnreadable, .hostUnknown, .notOptedIn,
      .invalidSessionName, .invalidDestination, .invalidTmuxPath:
      return LaunchExitStatus.profileHostUnavailable
    case .launchFailed(let failure, _): return failure.exitStatus
    }
  } // End of var exitStatus

  /// The explanation printed in the tab.
  public var explanation: String {
    switch self {
    case .nested(let variable):
      return "This tab already runs inside tmux or inside a tab muxFinder started (\(variable) "
        + "is set), so muxFinder doesn't start another tmux session here."
    case .hostListMissing:
      return "muxFinder has no saved host list, so this persistent work profile's host is "
        + "unknown."
    case .hostListUnusable(let problem):
      return "muxFinder couldn't use its host list, so the persistent session was not started. "
        + problem.message
    case .hostListUnreadable:
      return "muxFinder couldn't read its host list, so the persistent session was not started."
    case .hostUnknown:
      return "This persistent work profile's host is no longer in muxFinder's host list. "
        + "Remove the profile in muxFinder's settings, or add the host again."
    case .notOptedIn:
      return "This host's persistent work profile is turned off in muxFinder's settings, so "
        + "the persistent session was not started."
    case .invalidSessionName(let error):
      return "This host's default session name isn't usable, so the persistent session was "
        + "not started. " + error.message
    case .invalidDestination:
      return "This host has no valid SSH destination in muxFinder's settings, so the "
        + "persistent session was not started."
    case .invalidTmuxPath:
      return "The tmux path in this host's settings isn't usable, so the persistent session "
        + "was not started."
    case .launchFailed(let failure, let host):
      return ProfileLaunch.explanation(for: failure, host: host)
    }
  } // End of var explanation
}

/// What a persistent profile's tab runs, resolved from the host list (PLAN.md D26).
public struct ProfileLaunchPlan: Sendable, Hashable {
  /// The configured host.
  public var hostID: UUID
  /// Where tmux runs: this Mac, or a remote Mac over ssh.
  public var host: LaunchHost
  /// The host's tmux path, used alone when set (PLAN.md D5).
  public var tmuxPathOverride: String?
  /// The session `new-session -A -s` attaches or creates.
  public var sessionName: String

  /// The plan for the host `hostID` in `load`, or why there is none: the list must be saved,
  /// the host there with its persistent profile on, its default session name usable
  /// (`Validation.persistentSessionName`), its tmux path (when set) usable, and an SSH host's
  /// destination valid. The host's discovery switch (`isEnabled`) does not matter.
  public static func make(
    hostID: UUID,
    from load: HostStoreLoadResult
  ) -> Result<ProfileLaunchPlan, ProfileLaunchProblem> {
    switch load.state {
    case .notSavedYet: return .failure(.hostListMissing)
    case .invalid(let problem): return .failure(.hostListUnusable(problem))
    case .saved: break
    }
    guard let host = load.hosts.host(withID: hostID) else { return .failure(.hostUnknown) }
    guard host.persistentProfileEnabled else { return .failure(.notOptedIn) }
    let name: String
    do throws(ValidationError) {
      name = try Validation.persistentSessionName(host.effectiveDefaultSessionName)
    } catch {
      return .failure(.invalidSessionName(error))
    }
    var override: String?
    if let raw = host.tmuxPathOverride {
      do throws(ValidationError) {
        override = try Validation.executablePath(raw)
      } catch {
        return .failure(.invalidTmuxPath(error))
      }
    }
    let launchHost: LaunchHost
    switch host.mode {
    case .local:
      launchHost = .local
    case .ssh:
      do throws(ValidationError) {
        launchHost = .ssh(destination: try Validation.sshDestination(host.sshDestination))
      } catch {
        return .failure(.invalidDestination(error))
      }
    }
    return .success(
      ProfileLaunchPlan(
        hostID: hostID, host: launchHost, tmuxPathOverride: override, sessionName: name))
  } // End of func make(hostID:from:)
}

/// `muxfinder-launch profile <host id>`: what a "Persistent work" profile's tab runs (PLAN.md
/// D26). The pure parts live here; `LaunchHelper` runs them.
///
/// - **Locally** two children, as an attach has (D14): a **check**, `/bin/sh -c <locateScript>
///   muxfinder <override>` (the D5 locator, its own process group, a deadline), which prints
///   the tmux path; then tmux itself on the tab's terminal, by argv:
///   `<tmux> -u -CC new-session -A -s <name>` (D12's `-u`; `-A` attaches the session when it
///   exists and creates it otherwise), the name written as `TmuxWord.escaped(_:)` makes it
///   (every `#` doubled, a trailing `;` written `\;`) so tmux stores and finds it exactly.
/// - **On an SSH host** one child, D17's interactive ssh:
///   `/usr/bin/ssh -t -o ConnectTimeout=10 -- <destination> <D3 string>`, the D3 string running
///   the static `remoteScript` with two POSIX single-quoted arguments, the tmux path override
///   (empty for none) and the name; the script locates tmux, escapes the name the same way
///   (`TmuxCommands.wordFunctions`) and `exec`s `tmux -u -CC new-session -A -s <name>`.
///
/// No runtime value is ever part of shell source. Exit statuses: 0 when tmux ended normally
/// (a detach); the locator's 66 (tmux missing) and 68 (usage); tmux's own; over ssh, 255 for
/// ssh's errors (`failure(for:host:sshStandardError:)`).
public enum ProfileLaunch {
  /// The helper's first argument for a persistent profile.
  public static let helperMode = "profile"
  /// Set (to `launchedValue`) in the environment of everything the helper starts, in every
  /// mode, so a helper started from inside one of those processes sees it (the nesting guard).
  public static let launchedVariable = "MUXFINDER_LAUNCHED"
  /// `launchedVariable`'s value.
  public static let launchedValue = "1"
  /// The variables of the nesting guard, in the order they are checked: set to anything but the
  /// empty string, each means the tab already runs inside tmux or inside something a muxFinder
  /// helper started. Empty counts as unset, as tmux itself treats `TMUX=`.
  public static let nestingVariables = ["TMUX", launchedVariable]

  /// The first nesting variable set to a non-empty value in `environment`, or `nil`.
  public static func nestingVariable(in environment: [String: String]) -> String? {
    nestingVariables.first { environment[$0].map { !$0.isEmpty } ?? false }
  }

  /// The local check after the locator fragment: the default server only (`TMUX` and
  /// `TMUX_PANE` unset), one argument (the override, empty for none), else 68; no tmux, 66;
  /// otherwise it prints the path.
  static let locateBody: StaticShellScript = #"""
    unset TMUX TMUX_PANE
    PATH=${PATH:-/usr/bin:/bin}:/usr/bin:/bin
    export PATH
    if [ "$#" -ne 1 ]; then exit 68; fi
    muxfinder_locate_tmux "$1"
    if [ -z "$t" ]; then exit 66; fi
    printf '%s\n' "$t"

    """#

  /// The complete local check: the tmux locator, then `locateBody`.
  public static let locateScript: StaticShellScript = TmuxLocator.script + locateBody

  /// The local check's process: `/bin/sh -c <locateScript> muxfinder <override>`, stdin
  /// `/dev/null`, `environment`, `timeout` and the guard's output limit.
  public static func locateRequest(
    override: String?,
    environment: [String: String],
    timeout: Duration
  ) -> ProcessRequest {
    ProcessRequest(
      executableURL: URL(fileURLWithPath: LaunchGuard.shellPath),
      arguments: ["-c", locateScript.source, ShellQuoting.scriptName, override ?? ""],
      environment: environment,
      timeout: timeout,
      outputLimit: LaunchGuard.outputLimit)
  } // End of func locateRequest(override:environment:timeout:)

  /// The remote script's first lines: the default server only, a usable `PATH`, and the
  /// arguments checked (two of them, a name that is not empty and does not start with `-`).
  static let remotePrelude: StaticShellScript = #"""
    unset TMUX TMUX_PANE
    PATH=${PATH:-/usr/bin:/bin}:/usr/bin:/bin
    export PATH
    if [ "$#" -ne 2 ]; then exit 68; fi
    case $2 in '' | -*) exit 68 ;; esac

    """#

  /// The remote script's last lines: tmux located (66 without one), the name escaped, then
  /// tmux's control-mode client replaces the shell.
  static let remoteTail: StaticShellScript = #"""
    muxfinder_locate_tmux "$1"
    if [ -z "$t" ]; then exit 66; fi
    muxfinder_double_hash "$2"
    muxfinder_tmux_word "$h"
    exec "$t" -u -CC new-session -A -s "$w"

    """#

  /// The complete remote script.
  public static let remoteScript: StaticShellScript =
    TmuxLocator.script + remotePrelude + TmuxCommands.wordFunctions + remoteTail

  /// tmux's arguments after its path, locally: `-u -CC new-session -A -s <escaped name>`.
  public static func tmuxArguments(sessionName: String) -> [String] {
    ["-u", "-CC", "new-session", "-A", "-s", TmuxWord.escaped(sessionName)]
  }

  /// The D3 string ssh hands the remote login shell: `remoteScript` with the override (empty
  /// for none) and the name, each POSIX single-quoted.
  public static func remoteCommand(override: String?, sessionName: String) -> String {
    ShellQuoting.remoteCommand(script: remoteScript, args: [override ?? "", sessionName])
  }

  /// ssh's arguments after argv[0]: D17's options, `--`, the validated destination and the D3
  /// string; `nil` when the destination is not valid.
  public static func sshArguments(
    destination: String,
    override: String?,
    sessionName: String
  ) -> [String]? {
    guard let valid = try? Validation.sshDestination(destination) else { return nil }
    return RemoteLaunch.sshOptions
      + ["--", valid, remoteCommand(override: override, sessionName: sessionName)]
  }

  /// How the tmux (or ssh) child ended, as a failure, or `nil` for exit status 0: a signal is
  /// `childSignaled`; over ssh 66 is `tmuxMissing`, 68 `guardUsage` (the remote script's codes)
  /// and 255 `sshFailed` with the class read from ssh's standard error; any other status is
  /// `childExited`.
  public static func failure(
    for termination: ProcessResult.Termination,
    host: LaunchHost,
    sshStandardError: Data = Data()
  ) -> LaunchFailure? {
    switch termination {
    case .signaled(let signal):
      return .childSignaled(signal)
    case .exited(LaunchExitStatus.success):
      return nil
    case .exited(LaunchExitStatus.tmuxMissing) where host.isRemote:
      return .tmuxMissing
    case .exited(LaunchExitStatus.guardUsage) where host.isRemote:
      return .guardUsage
    case .exited(LaunchExitStatus.sshFailure) where host.isRemote:
      return .sshFailed(SSHFailureClass(standardError: sshStandardError))
    case .exited(let status):
      return .childExited(status)
    }
  } // End of func failure(for:host:sshStandardError:)

  /// The explanation for a failed persistent session on `host`, worded for a profile tab.
  public static func explanation(for failure: LaunchFailure, host: LaunchHost) -> String {
    let remote = host.isRemote
    switch failure {
    case .tmuxMissing:
      return "muxFinder could not find tmux " + (remote ? "on the remote host" : "on this Mac")
        + ", so the persistent session was not started. Install tmux, or check the tmux path "
        + "in muxFinder's host settings."
    case .sshFailed(.unreachable):
      return "ssh could not reach the host, so the persistent session was not started. Check "
        + "that the host is on and connected, then open a new tab with this profile."
    case .sshFailed(.authFailed):
      return "ssh could not log in to the host, so the persistent session was not started. Any "
        + "message from ssh is shown above."
    case .sshFailed(.hostKeyProblem):
      return "ssh did not accept the host's key (it is unknown or changed), so the persistent "
        + "session was not started. Check the message from ssh above; muxFinder never changes "
        + "your known hosts."
    case .sshFailed(.other):
      return "ssh ended with an error, so the persistent session was not started. Any message "
        + "from ssh is shown above."
    case .spawnFailed(let code):
      return "muxFinder could not start " + (remote ? "ssh" : "tmux") + ": "
        + "\(String(cString: strerror(code)))."
    case .checkTimedOut:
      return "tmux did not answer in time, so the persistent session was not started. tmux may "
        + "be busy or stuck."
    case .tmuxCheckFailed:
      return "muxFinder could not check tmux on this Mac, so the persistent session was not "
        + "started."
    case .guardUsage:
      return "muxFinder started tmux incorrectly. This is a bug in muxFinder."
    case .interrupted(let signal):
      return "muxFinder was stopped by signal \(signal) before tmux started."
    case .childSignaled(let signal):
      return (remote ? "ssh" : "tmux") + " was stopped by signal \(signal)."
    case .childExited(let status):
      return (remote ? "The remote session" : "tmux") + " ended with exit status \(status)."
    case .sessionGone, .sessionChanged, .usage, .requestMissing, .requestExpired,
      .requestUnreadable, .launchDirectoryUnusable:
      return failure.explanation(for: host)
    }
  } // End of func explanation(for:host:)
}
