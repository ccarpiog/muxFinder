import Foundation

/// What to create: a new detached tmux session on a host's default server (PLAN.md Phase 6,
/// D18). The values are as the user typed them; `TmuxCommands` validates them before any
/// process runs.
public struct NewSessionRequest: Sendable, Hashable {
  /// The host: this Mac, or a remote Mac reached with noninteractive ssh.
  public var host: HostConfig
  /// The session name as typed (`Validation.sessionName(_:)` trims and checks it).
  public var name: String
  /// The working directory of the first window, as typed, or `nil` (or empty) for the home
  /// directory on the host. A leading `~` or `~/` and any path not starting with `/` are taken
  /// from the home directory on the host, by the static script there.
  public var workingDirectory: String?
  /// The command the first pane runs, as argv; empty (the default) for the user's shell, as in a
  /// new terminal window. Test harnesses use it to run `sleep` instead of a login shell.
  public var command: [String]

  /// Creates a request.
  public init(
    host: HostConfig,
    name: String,
    workingDirectory: String? = nil,
    command: [String] = []
  ) {
    self.host = host
    self.name = name
    self.workingDirectory = workingDirectory
    self.command = command
  } // End of init(host:name:workingDirectory:command:)
}

/// Why a session could not be created. `message` is English, sentence case, without user data.
public enum SessionCreationError: Error, Sendable, Hashable {
  /// How a name collision was found.
  public enum CollisionCheck: String, Sendable, Hashable, Codable, CaseIterable {
    /// `has-session -t '=<name>'` found a session with that exact name before creating.
    case hasSession
    /// `new-session` itself refused with tmux's `duplicate session` error (a session with that
    /// name appeared after the check).
    case duplicateSession
  }

  /// The name is not acceptable (`Validation.sessionName(_:)`); nothing was run.
  case invalidName(ValidationError)
  /// The working directory is not acceptable (`Validation.workingDirectory(_:)`); nothing was
  /// run.
  case invalidDirectory(ValidationError)
  /// The host's SSH destination is not usable; nothing was run.
  case invalidDestination(ValidationError)
  /// The host's tmux path override is not usable; nothing was run.
  case invalidTmuxPath(ValidationError)
  /// A session with this name exists already. Nothing was created, replaced or changed.
  case sessionExists(CollisionCheck)
  /// The working directory does not exist on the host (or is not a directory you can enter).
  /// Nothing was created.
  case directoryMissing
  /// No usable tmux was found on the host (PLAN.md D5). Nothing was created.
  case tmuxMissing
  /// ssh itself failed (exit status 255) before the remote command could run, with the class
  /// its standard error showed (`TmuxCommands.failedBeforeRemoteCommand(standardError:)`):
  /// the host could not be reached, the login failed or the host key was refused. Creation runs
  /// noninteractive (`BatchMode`), so a password or host-key question fails here; nothing was
  /// created. `classify(_:transport:)` never gives `.other`: an ssh error it cannot place
  /// before the remote command is `connectionLost`. `.other`, if built elsewhere, is treated as
  /// `connectionLost` is (`mayHaveCreated`).
  case sshFailed(SSHFailureClass)
  /// ssh ended with its own error (exit status 255) without showing a failure before the
  /// remote command could run: the connection was lost after it was up (a keepalive timeout, a
  /// reset, the remote end closing it, the remote tmux killed by a signal), or ssh's message is
  /// not one muxFinder knows. The script may have created the session before the connection
  /// ended, so the session may exist.
  case connectionLost
  /// tmux refused to create the session for another reason; its first error line, printable
  /// ASCII, at most 200 characters (`ErrorClassifier.firstLine(of:)`).
  case tmuxFailed(String)
  /// tmux reported success but its output was not one valid session record. The session
  /// probably exists.
  case unexpectedOutput
  /// The run did not end within its deadline; its process group was killed. The session may
  /// have been created.
  case timedOut
  /// The process could not be started.
  case couldNotRun(ProcessRunnerError)
  /// The script ended in a way none of the above covers (another exit status, or a signal).
  /// A signal, or an exit status above 128 (how a shell or ssh reports a child killed by signal
  /// `status - 128`), may have come after tmux created the session (`mayHaveCreated`).
  case scriptFailed(ProcessResult.Termination)
  /// The caller was cancelled while the process ran (its group was killed). The session may
  /// have been created.
  case cancelled

  /// A short machine-readable name, such as `sessionExists`.
  public var kind: String {
    switch self {
    case .invalidName: return "invalidName"
    case .invalidDirectory: return "invalidDirectory"
    case .invalidDestination: return "invalidDestination"
    case .invalidTmuxPath: return "invalidTmuxPath"
    case .sessionExists: return "sessionExists"
    case .directoryMissing: return "directoryMissing"
    case .tmuxMissing: return "tmuxMissing"
    case .sshFailed: return "sshFailed"
    case .connectionLost: return "connectionLost"
    case .tmuxFailed: return "tmuxFailed"
    case .unexpectedOutput: return "unexpectedOutput"
    case .timedOut: return "timedOut"
    case .couldNotRun: return "couldNotRun"
    case .scriptFailed: return "scriptFailed"
    case .cancelled: return "cancelled"
    }
  } // End of var kind

  /// A detail for diagnostics and the probe's JSON (never user data): the collision check, the
  /// ssh failure class, or the validation rule.
  public var detail: String? {
    switch self {
    case .invalidName(let error), .invalidDirectory(let error), .invalidDestination(let error),
      .invalidTmuxPath(let error):
      return "\(error)"
    case .sessionExists(let check): return check.rawValue
    case .sshFailed(let failureClass): return failureClass.rawValue
    case .couldNotRun(let error): return error.description
    case .scriptFailed(.exited(let status)): return "exit status \(status)"
    case .scriptFailed(.signaled(let signal)): return "signal \(signal)"
    default: return nil
    }
  } // End of var detail

  /// Whether the session may exist although creation did not report it: the output was lost
  /// or unreadable, the connection ended after it was up, or the run was stopped (a deadline, a
  /// cancelled caller, a signal). A caller refreshes before offering to try again. Only
  /// failures known to come before tmux could create anything (validation, a collision, a
  /// missing directory or tmux, ssh failing before the remote command, a spawn error, tmux's
  /// own refusal) are `false`.
  public var mayHaveCreated: Bool {
    switch self {
    case .unexpectedOutput, .timedOut, .cancelled, .connectionLost, .sshFailed(.other):
      return true
    case .scriptFailed(.signaled):
      return true
    case .scriptFailed(.exited(let status)):
      return status > LaunchExitStatus.signalBase
    default:
      return false
    }
  } // End of var mayHaveCreated

  /// Whether the host's session list is worth refreshing now: a session muxFinder did not show
  /// exists (a collision), or one may have been created.
  public var triggersRefresh: Bool {
    if case .sessionExists = self { return true }
    return mayHaveCreated
  }

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .invalidName(let error), .invalidDirectory(let error):
      return error.message
    case .invalidDestination(let error):
      return "muxFinder cannot reach this host: \(error.message)"
    case .invalidTmuxPath(let error):
      return "The tmux path in this host's settings is not usable: \(error.message)"
    case .sessionExists:
      return "A session with this name already exists on this host. Open it, or choose another "
        + "name."
    case .directoryMissing:
      return "The working directory does not exist on this host, or you can't open it. Choose "
        + "another one, or leave it empty for your home folder."
    case .tmuxMissing:
      return "muxFinder could not find tmux on this host. Install tmux, or check the tmux path in "
        + "muxFinder's host settings."
    case .sshFailed(.authFailed):
      return "muxFinder could not log in to this host without asking for a password. Set up SSH "
        + "in iTerm2 first, then try again."
    case .sshFailed(.hostKeyProblem):
      return "ssh did not accept this host's key (it is unknown or changed). Set up SSH in iTerm2 "
        + "first, then try again; muxFinder never changes your known hosts."
    case .sshFailed(.unreachable):
      return "ssh could not reach this host. Check that it is on and connected, then try again."
    case .sshFailed(.other), .connectionLost:
      return "The connection to this host ended before muxFinder learned the result. The session "
        + "may have been created; refresh to see it."
    case .tmuxFailed(let line):
      return line.isEmpty
        ? "tmux could not create the session."
        : "tmux could not create the session: \(line)"
    case .unexpectedOutput:
      return "tmux created the session but its answer could not be read. Refresh to see it."
    case .timedOut:
      return "The host did not answer in time. The session may have been created; refresh to see "
        + "it."
    case .couldNotRun:
      return "muxFinder could not start tmux or ssh to create the session."
    case .scriptFailed where mayHaveCreated:
      return "Creating the session was interrupted. It may have been created; refresh to see it."
    case .scriptFailed:
      return "Creating the session failed unexpectedly. Try again."
    case .cancelled:
      return "Creating the session was cancelled. It may have been created; refresh to see it."
    }
  } // End of var message
}

/// Creates tmux sessions. `TmuxCommands` is the production implementation; tests pass fakes,
/// so `AttachCoordinator.createAndAttach(_:)` never runs a process in `swift test`.
public protocol SessionCreating: Sendable {
  /// Creates the session `request` describes; see `TmuxCommands.createSession(_:)`.
  func createSession(_ request: NewSessionRequest) async throws(SessionCreationError)
    -> CreatedSession
}

/// tmux commands that change a host's default server (PLAN.md Phase 6, D18): for now, the
/// detached creation of a named session.
///
/// - Local hosts: `/bin/sh -c <script> muxfinder <override> <name> <directory> [command…]`,
///   data only as argv, with the local environment minus `TMUX` and `TMUX_PANE` (D3, D9).
/// - SSH hosts: `/usr/bin/ssh <D6 options> -n -T -- <destination> <D3 string>`: noninteractive
///   (`BatchMode=yes`), the user's own configuration, nothing that weakens host-key checking.
///   The D3 string is `ShellQuoting.remoteCommand(script:args:)` with the same arguments.
///
/// The name, directory, destination and override are validated before any process runs. Every
/// run is bounded by `timeout` (12 s, D6), after which the runner kills the process group.
///
/// On the host, `script`:
/// 1. unsets `TMUX` and `TMUX_PANE` and appends `/usr/bin:/bin` to `PATH`;
/// 2. checks its arguments (at least 3, a non-empty name not starting with `-`), else 68;
/// 3. locates tmux (`TmuxLocator`, D5), else 66;
/// 4. runs `tmux -u has-session -t '=<name>'` (exact name; output discarded): a session with
///    that name exits 80, and nothing else runs;
/// 5. resolves the directory there: empty or `~` is `$HOME`, `~/rest` is `$HOME/rest`, any
///    other path not starting with `/` is relative to `$HOME`; a path that is not a directory
///    it can enter exits 81, and nothing is created;
/// 6. doubles every `#` in the name and the directory (tmux expands formats in `-s` and `-c`,
///    and `##` is its escape for `#`; verified with tmux 3.8, *Verified facts*), so tmux stores
///    the name and uses the directory exactly as given;
/// 7. `exec`s `tmux -u new-session -d -P -F <CreatedSession.format> -s <name> -c <directory>
///    [command…]`. Never `-A`: an existing session is never attached, replaced or changed, and
///    tmux's own `duplicate session` error (a session that appeared after step 4) is a
///    collision too.
///
/// Every value it hands tmux as an argument (the `has-session` target, the name, the directory,
/// each command word) first has a trailing `;` written `\;`: tmux reads an argument ending in
/// `;` as a command separator even when it arrives as its own argv element, and `\;` is its
/// escape for a literal one (tmux(1), *Commands*; verified with tmux 3.8, *Verified facts*).
/// Only the last character matters, so `x\;` becomes `x\\;`, which tmux reads as `x\;`.
///
/// So the run's exit status is the script's (66, 68, 80, 81), tmux's own (0 or 1), or, over
/// ssh, 255 for ssh's errors. `classify(_:transport:)` maps it.
public struct TmuxCommands: SessionCreating {
  /// Exit statuses of `script` besides tmux's own 0 and 1.
  public enum ExitStatus {
    /// No usable tmux was found (the guard's code, `LaunchExitStatus.tmuxMissing`).
    public static let tmuxMissing: Int32 = 66
    /// Wrong arguments; means a bug in muxFinder (the guard's code).
    public static let usage: Int32 = 68
    /// `has-session` found a session with the exact name.
    public static let sessionExists: Int32 = 80
    /// The working directory is not a directory the script can enter.
    public static let directoryMissing: Int32 = 81
  }

  /// The hard limit on one run (PLAN.md D6).
  public static let defaultTimeout: Duration = DiscoveryProbe.defaultTimeout

  /// The most output kept from each of the run's stdout and stderr: one session record and
  /// tmux's error line need far less.
  public static let outputLimit = 16 * 1024

  /// Two shell functions shared by every static script that hands tmux a name it must store
  /// or find exactly (this creation script, and the persistent profile's remote script,
  /// `ProfileLaunch.remoteScript`, PLAN.md D26): `muxfinder_double_hash` sets `h` to its
  /// argument with every `#` doubled; `muxfinder_tmux_word` sets `w` to its argument with a
  /// trailing `;` written `\;`. `TmuxWord.escaped(_:)` is the same transformation in Swift.
  public static let wordFunctions: StaticShellScript = #"""
    muxfinder_double_hash() {
      h= r=$1
      while :; do
        case $r in
          *"#"*) h=$h${r%%"#"*}"##"; r=${r#*"#"} ;;
          *) h=$h$r; return 0 ;;
        esac
      done
    }
    muxfinder_tmux_word() {
      case $1 in
        *';') w=${1%';'}'\;' ;;
        *) w=$1 ;;
      esac
    }

    """#

  /// The first lines of `body`: the environment and the argument checks.
  static let prelude: StaticShellScript = #"""
    unset TMUX TMUX_PANE
    PATH=${PATH:-/usr/bin:/bin}:/usr/bin:/bin
    export PATH
    if [ "$#" -lt 3 ]; then exit 68; fi
    case $2 in '' | -*) exit 68 ;; esac

    """#

  /// The script after the locator fragment (steps 1–7): `prelude`, `wordFunctions`, then
  /// `steps`. The `-F` format must match `CreatedSession.format` (a unit test checks it).
  static let body: StaticShellScript = prelude + wordFunctions + steps

  /// The steps of `body` after the word functions.
  static let steps: StaticShellScript = #"""
    muxfinder_locate_tmux "$1"
    if [ -z "$t" ]; then exit 66; fi
    muxfinder_tmux_word "=$2"
    if "$t" -u has-session -t "$w" </dev/null >/dev/null 2>&1; then exit 80; fi
    d=$3
    case $d in
      '' | '~') d=${HOME-} ;;
      '~/'*) d=${HOME-}/${d#"~/"} ;;
      /*) ;;
      *) d=${HOME-}/$d ;;
    esac
    if [ -z "$d" ] || [ ! -d "$d" ] || [ ! -x "$d" ]; then exit 81; fi
    muxfinder_double_hash "$2"
    muxfinder_tmux_word "$h"
    n=$w
    muxfinder_double_hash "$d"
    muxfinder_tmux_word "$h"
    c=$w
    shift 3
    for a do
      shift
      muxfinder_tmux_word "$a"
      set -- "$@" "$w"
    done
    tab=$(printf '\t')
    f="#{session_id}$tab#{session_created}$tab#{pid}$tab#{start_time}$tab#{socket_path}"
    f="$f$tab#{session_name}"
    exec "$t" -u new-session -d -P -F "$f" -s "$n" -c "$c" "$@"

    """#

  /// The complete creation script: the tmux locator followed by `body`.
  public static let script: StaticShellScript = TmuxLocator.script + body

  /// Runs the processes.
  public var runner: any ProcessRunner
  /// The environment the child environment is built from (normally this process's).
  public var baseEnvironment: [String: String]
  /// The hard limit on one run.
  public var timeout: Duration

  /// Creates the commands. Tests pass a fake runner and an explicit environment.
  public init(
    runner: any ProcessRunner = PosixSpawnProcessRunner(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
    timeout: Duration = TmuxCommands.defaultTimeout
  ) {
    self.runner = runner
    self.baseEnvironment = baseEnvironment
    self.timeout = timeout
  } // End of init(runner:baseEnvironment:timeout:)

  /// Creates the session `request` describes, detached, and returns it as tmux reported it: its
  /// server (socket path, pid, start time), id, creation time and name, ready to become an
  /// attach target (`CreatedSession.attachTarget(on:)`).
  ///
  /// Invalid input throws before any process runs. A session with the same name is never
  /// replaced, attached or changed (`sessionExists`).
  public func createSession(
    _ request: NewSessionRequest
  ) async throws(SessionCreationError) -> CreatedSession {
    let processRequest = try self.processRequest(for: request)
    let result: ProcessResult
    do {
      result = try await runner.run(processRequest)
    } catch let error as ProcessRunnerError {
      throw .couldNotRun(error)
    } catch {
      throw .cancelled
    }
    let transport: DiscoveryTransport = request.host.mode == .local ? .local : .ssh
    return try Self.classify(result, transport: transport).get()
  } // End of func createSession(_:)

  /// The process request that creates `request`'s session, after validating the name, the
  /// directory, the tmux override and (for an SSH host) the destination. Exposed so tests can
  /// inspect it without running anything.
  public func processRequest(
    for request: NewSessionRequest
  ) throws(SessionCreationError) -> ProcessRequest {
    let arguments = try Self.scriptArguments(for: request)
    let environment = DiscoveryProbe.localEnvironment(base: baseEnvironment)
    switch request.host.mode {
    case .local:
      return ProcessRequest(
        executableURL: DiscoveryProbe.shellURL,
        arguments: ["-c", Self.script.source, ShellQuoting.scriptName] + arguments,
        environment: environment, timeout: timeout, outputLimit: Self.outputLimit)
    case .ssh:
      let destination: String
      do throws(ValidationError) {
        destination = try Validation.sshDestination(request.host.sshDestination)
      } catch {
        throw .invalidDestination(error)
      }
      return ProcessRequest(
        executableURL: DiscoveryProbe.sshURL,
        arguments: DiscoveryProbe.sshOptions
          + ["-n", "-T", "--", destination, Self.remoteCommand(arguments: arguments)],
        environment: environment, timeout: timeout, outputLimit: Self.outputLimit)
    }
  } // End of func processRequest(for:)

  /// The script's positional parameters for `request`, data only: the tmux override (empty
  /// when the host has none), the validated name, the directory (empty for the home directory)
  /// and the command words (argv, never parsed by a shell; the runner refuses a NUL byte in
  /// any of them).
  public static func scriptArguments(
    for request: NewSessionRequest
  ) throws(SessionCreationError) -> [String] {
    let name: String
    do throws(ValidationError) {
      name = try Validation.sessionName(request.name)
    } catch {
      throw .invalidName(error)
    }
    var directory = ""
    if let raw = request.workingDirectory {
      do throws(ValidationError) {
        directory = try Validation.workingDirectory(raw)
      } catch {
        throw .invalidDirectory(error)
      }
    }
    var override = ""
    if let raw = request.host.tmuxPathOverride {
      do throws(ValidationError) {
        override = try Validation.executablePath(raw)
      } catch {
        throw .invalidTmuxPath(error)
      }
    }
    return [override, name, directory] + request.command
  } // End of func scriptArguments(for:)

  /// The D3 command string ssh hands the remote login shell for the script's `arguments`.
  public static func remoteCommand(arguments: [String]) -> String {
    ShellQuoting.remoteCommand(script: script, args: arguments)
  }

  /// Maps how a creation run ended. Pure and total:
  /// - a timeout is `timedOut`; over ssh, exit 255 is `sshFailed` with the class from stderr
  ///   when stderr shows ssh failed before the remote command could run
  ///   (`failedBeforeRemoteCommand(standardError:)`), else `connectionLost`;
  /// - 66, 80 and 81 are the script's refusals; 1 with tmux's `duplicate session` error is a
  ///   collision, any other 1 is `tmuxFailed` with tmux's first error line;
  /// - 0 needs exactly one line of valid UTF-8 that `CreatedSession.parse(_:)` accepts (stdout
  ///   not cut by the cap), else `unexpectedOutput`;
  /// - anything else (68, another status, a signal) is `scriptFailed`.
  public static func classify(
    _ result: ProcessResult,
    transport: DiscoveryTransport
  ) -> Result<CreatedSession, SessionCreationError> {
    if result.timedOut { return .failure(.timedOut) }
    switch result.termination {
    case .signaled:
      return .failure(.scriptFailed(result.termination))
    case .exited(ErrorClassifier.sshErrorExitStatus) where transport == .ssh:
      guard let failureClass = failedBeforeRemoteCommand(standardError: result.standardError)
      else { return .failure(.connectionLost) }
      return .failure(.sshFailed(failureClass))
    case .exited(0):
      guard !result.standardOutputTruncated,
        let text = String(data: result.standardOutput, encoding: .utf8),
        text.utf8.last == UInt8(ascii: "\n"),
        let created = CreatedSession.parse(text)
      else { return .failure(.unexpectedOutput) }
      return .success(created)
    case .exited(1):
      let stderr = String(decoding: result.standardError, as: UTF8.self).lowercased()
      if stderr.contains("duplicate session") { return .failure(.sessionExists(.duplicateSession)) }
      return .failure(.tmuxFailed(ErrorClassifier.firstLine(of: result.standardError)))
    case .exited(ExitStatus.tmuxMissing):
      return .failure(.tmuxMissing)
    case .exited(ExitStatus.sessionExists):
      return .failure(.sessionExists(.hasSession))
    case .exited(ExitStatus.directoryMissing):
      return .failure(.directoryMissing)
    case .exited:
      return .failure(.scriptFailed(result.termination))
    }
  } // End of func classify(_:transport:)

  /// Lowercased parts of OpenSSH messages printed only once the connection was up (or that can
  /// be printed then), so an ssh error showing one may have come after the remote command
  /// started: a keepalive timeout (`Timeout, server … not responding.`), a failed read or write
  /// on the session (`Read from remote host …:`, `client_loop: …`, `packet_write_wait: …`,
  /// `Broken pipe`, `Connection reset`), a fatal packet error at any stage
  /// (`ssh_dispatch_run_fatal: …`), the remote end closing the session (`Connection to … closed
  /// by remote host.`) or the remote command killed by a signal (`Killed by signal …`).
  static let afterConnectionMarkers = [
    "timeout, server", "read from remote host", "client_loop", "packet_write", "broken pipe",
    "connection reset", "ssh_dispatch_run_fatal", "closed by remote host", "killed by signal",
  ]

  /// The class of an ssh failure (exit status 255) whose standard error shows that ssh failed
  /// before the remote command could run, or `nil`. That needs one of discovery's patterns
  /// (`SSHFailureClass`: the host unreachable, refused or timing out on connect, the name not
  /// resolving, the login refused, the host key unknown or changed) and none of
  /// `afterConnectionMarkers`; anything else (an unclassified message, none at all, a lost
  /// connection) may have come after the script created the session.
  static func failedBeforeRemoteCommand(standardError: Data) -> SSHFailureClass? {
    let text = String(decoding: standardError, as: UTF8.self).lowercased()
    guard !afterConnectionMarkers.contains(where: { text.contains($0) }) else { return nil }
    let failureClass = SSHFailureClass(standardError: standardError)
    return failureClass == .other ? nil : failureClass
  }
}
