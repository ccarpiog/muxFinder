import Foundation

/// Why a tmux command of the plain backend (PLAN.md D38, Phase I-12c1) gave no usable answer.
/// It holds no argument, output or error text (they may carry user data), only what went wrong.
public enum PlainTmuxCommandFailure: Error, Sendable, Hashable {
  /// The process could not be started (no shell, no ssh, a refused argument).
  case couldNotRun(ProcessRunnerError)
  /// It ran past its time limit (12 s, D6) and was stopped.
  case timedOut
  /// ssh failed (exit 255): the host was not reached, or the connection broke.
  case sshFailed
  /// No usable tmux was found on the session's host (the static script's 66).
  case tmuxMissing
  /// tmux (or the static script) ended with another status, or by a signal.
  case exited(ProcessResult.Termination)
  /// It ended well, but its answer was not in the command's format.
  case unreadable
  /// The bound command cannot be written for this session or client (a session name with
  /// characters tmux formats cannot compare exactly, such as `{` or `[`). Nothing ran.
  case notWritable
  /// The caller was cancelled while the command ran (it may have run).
  case cancelled

  /// A short machine-readable name, such as `sshFailed`.
  public var kind: String {
    switch self {
    case .couldNotRun: return "couldNotRun"
    case .timedOut: return "timedOut"
    case .sshFailed: return "sshFailed"
    case .tmuxMissing: return "tmuxMissing"
    case .exited: return "exited"
    case .unreadable: return "unreadable"
    case .notWritable: return "notWritable"
    case .cancelled: return "cancelled"
    }
  }

  /// Whether the command may have reached tmux: every failure but one that never ran.
  public var mayHaveRun: Bool {
    switch self {
    case .couldNotRun, .notWritable: return false
    default: return true
    }
  }

  /// A plain English sentence for the UI (no paths, names or command text).
  public var message: String {
    switch self {
    case .couldNotRun:
      return "muxFinder could not run tmux."
    case .timedOut:
      return "tmux did not answer in time."
    case .sshFailed:
      return "ssh could not reach the session's host."
    case .tmuxMissing:
      return "muxFinder could not find tmux on the session's host."
    case .exited:
      return "tmux ended with an error."
    case .unreadable:
      return "tmux answered in a way muxFinder does not understand."
    case .notWritable:
      return "The session's name holds characters muxFinder cannot compare safely in a tmux "
        + "command."
    case .cancelled:
      return "The check was cancelled."
    }
  } // End of var message
} // End of enum PlainTmuxCommandFailure

/// The read-only check whether one identified plain client still holds its session (PLAN.md
/// D38, the plain backend's attachment records): one tmux command with `PlainClientDetach`'s
/// condition, which prints `presentMarker` when the session is exactly the recorded one and
/// exactly one client with the recorded name, pid and creation time is attached to it, and
/// `PlainClientDetach.notThisClientMarker` otherwise. It only prints (`display-message -p`):
/// nothing is attached, detached or changed.
public enum PlainClientPresence {
  /// What the command prints (with a line break) when the client still holds the session.
  public static let presentMarker = "muxfinder-client-present"

  /// How a presence check ended.
  public enum Outcome: String, Sendable, Hashable {
    /// The client still holds the session.
    case present
    /// The client, its session or the server is not exactly the recorded one, or there is no
    /// server: the client is gone.
    case notThisClient
    /// tmux failed, or its answer was neither: nothing is known.
    case failed
  }

  /// The tmux arguments (after `tmux -u`) of the check of `client` in `session`, or `nil` when
  /// `PlainClientDetach.condition(of:in:)` cannot be written.
  public static func arguments(of client: OtherClient, in session: BoundSessionIdentity)
    -> [String]?
  {
    guard let condition = PlainClientDetach.condition(of: client, in: session) else { return nil }
    return [
      "if-shell", "-F", "-t", session.sessionID.rawValue, condition,
      "display-message -p \(presentMarker)",
      "display-message -p \(PlainClientDetach.notThisClientMarker)",
    ]
  } // End of static func arguments(of:in:)

  /// How a run of `arguments(of:in:)` ended: exit 0 with exactly the present marker line is
  /// `present`; exit 0 with exactly the other marker line, or exit 1 with tmux's "no server"
  /// error, `notThisClient`; anything else `failed`.
  public static func outcome(
    exitStatus: Int32?,
    standardOutput: String,
    standardError: String
  ) -> Outcome {
    switch exitStatus {
    case 0? where standardOutput == presentMarker + "\n":
      return .present
    case 0? where standardOutput == PlainClientDetach.notThisClientMarker + "\n":
      return .notThisClient
    case 1?:
      let firstLine = standardError.split(separator: "\n").first.map(String.init) ?? ""
      return ErrorClassifier.isNoServerMessage(firstLine) ? .notThisClient : .failed
    default:
      return .failed
    }
  } // End of static func outcome(exitStatus:standardOutput:standardError:)
} // End of enum PlainClientPresence

/// tmux's clock and one session's clients, as one read-only command printed them (PLAN.md
/// D37's listing for the plain backend's "Detach other clients…", D38).
public struct PlainSessionClients: Sendable, Hashable {
  /// tmux's clock when it answered, whole seconds since 1970 (`display-message -p '%s'`).
  public var serverTime: Int64
  /// The session's clients, in listing order.
  public var clients: [OtherClient]

  /// Creates a listing.
  public init(serverTime: Int64, clients: [OtherClient]) {
    self.serverTime = serverTime
    self.clients = clients
  }

  /// The tmux arguments (after `tmux -u`): `display-message -p '%s'`, then (after a `;`
  /// argument, tmux's command separator) `list-clients -F PlainClientIdentification
  /// .localFormat` over every client of the server, so nothing from the run is put into a
  /// format; the reading keeps the session's.
  public static let arguments = [
    "display-message", "-p", "%s", ";", "list-clients", "-F",
    PlainClientIdentification.localFormat,
  ]

  /// Reads the command's output for the session `sessionID`: a first line with a canonical
  /// number of seconds, then lines of five tab-separated fields; the clients of that session
  /// must each be one `OtherClient` accepts. `nil` for anything else.
  public static func read(_ output: String, sessionID: TmuxSessionID) -> PlainSessionClients? {
    guard let lines = PlainClientIdentification.lines(of: output), let first = lines.first,
      let time = ConnectionIdentity.canonicalInteger(first, as: Int64.self)
    else { return nil }
    var listing = PlainSessionClients(serverTime: time, clients: [])
    for line in lines.dropFirst() {
      let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard fields.count == 5 else { return nil }
      guard fields[0] == sessionID.rawValue else { continue }
      guard let client = OtherClient(processID: fields[1], created: fields[2], name: fields[4])
      else { return nil }
      listing.clients.append(client)
    } // End of loop over the listing's lines
    return listing
  } // End of static func read(_:sessionID:)
} // End of struct PlainSessionClients

/// The tmux commands the plain backend runs (PLAN.md D38, Phase I-12c1): its readings (the
/// confirmation's client listing on This Mac, the token reading on an SSH host, the session's
/// clients for "Detach other clients…") and its bound commands (`PlainClientPresence`,
/// `PlainClientDetach`).
///
/// Every command is one static script with its values as positional parameters (PLAN.md D3):
/// on This Mac `/bin/sh -c <script> muxfinder <values…>` with the local environment minus
/// `TMUX` and `TMUX_PANE` (D9); on an SSH host D6's noninteractive `/usr/bin/ssh` (BatchMode,
/// the user's own configuration, no connection prompt) with
/// `ShellQuoting.remoteCommand(script:args:)`, exactly as discovery runs. tmux itself is found
/// on the host by `TmuxLocator` (the host's override alone when set, D5). Every run is bounded
/// (12 s, D6). Nothing here writes a file or keeps a connection.
public struct PlainTmuxCommands: Sendable {
  /// Where a command runs: This Mac or an SSH destination (already validated), with the host's
  /// tmux override.
  public struct Target: Sendable, Hashable {
    /// `.local`, or `.ssh` with a destination `Validation.sshDestination(_:)` accepted.
    public var host: LaunchHost
    /// The host's explicit tmux path, used alone when set (PLAN.md D5).
    public var tmuxPathOverride: String?

    /// Creates a target.
    public init(host: LaunchHost, tmuxPathOverride: String?) {
      self.host = host
      self.tmuxPathOverride = tmuxPathOverride
    }
  } // End of struct Target

  /// The static script that runs tmux with its arguments: `$1` is the tmux override (empty for
  /// none), the rest tmux's arguments after `-u`. Exit 68 without arguments, 66 when no tmux is
  /// found, else tmux's own status.
  public static let script: StaticShellScript =
    TmuxLocator.script
      + #"""
      unset TMUX TMUX_PANE
      PATH=${PATH:-/usr/bin:/bin}:/usr/bin:/bin
      export PATH
      if [ "$#" -lt 2 ]; then exit 68; fi
      muxfinder_locate_tmux "$1"
      if [ -z "$t" ]; then exit 66; fi
      shift
      exec "$t" -u "$@"

      """#

  /// The most output kept from each of a run's stdout and stderr.
  public static let outputLimit = 256 * 1024

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
    timeout: Duration = DiscoveryProbe.defaultTimeout
  ) {
    self.runner = runner
    self.baseEnvironment = baseEnvironment
    self.timeout = timeout
  } // End of init(runner:baseEnvironment:timeout:)

  // MARK: - Requests

  /// The process request that runs `script` with `arguments` on `host`: `/bin/sh -c` locally,
  /// D6's noninteractive ssh with the D3 string remotely.
  public func request(
    _ script: StaticShellScript,
    arguments: [String],
    on host: LaunchHost
  ) -> ProcessRequest {
    let environment = DiscoveryProbe.localEnvironment(base: baseEnvironment)
    switch host {
    case .local:
      return ProcessRequest(
        executableURL: DiscoveryProbe.shellURL,
        arguments: ["-c", script.source, ShellQuoting.scriptName] + arguments,
        environment: environment, timeout: timeout, outputLimit: Self.outputLimit)
    case .ssh(let destination):
      return ProcessRequest(
        executableURL: DiscoveryProbe.sshURL,
        arguments: DiscoveryProbe.sshOptions
          + [
            "-n", "-T", "--", destination,
            ShellQuoting.remoteCommand(script: script, args: arguments),
          ],
        environment: environment, timeout: timeout, outputLimit: Self.outputLimit)
    }
  } // End of func request(_:arguments:on:)

  /// The process request that runs `tmux -u <arguments>` at `target` (`script`).
  public func tmuxRequest(_ arguments: [String], at target: Target) -> ProcessRequest {
    request(Self.script, arguments: [target.tmuxPathOverride ?? ""] + arguments, on: target.host)
  }

  // MARK: - Readings

  /// This Mac's confirmation reading (PLAN.md D38): `list-clients -F
  /// PlainClientIdentification.localFormat` read for the session `sessionID` and the terminal
  /// `terminal`. No server is a reading with no client (the session is gone; its helper's
  /// result says so).
  public func localReading(
    of sessionID: TmuxSessionID,
    terminal: String,
    at target: Target
  ) async -> Result<PlainClientIdentification.Reading, PlainTmuxCommandFailure> {
    let request = tmuxRequest(
      ["list-clients", "-F", PlainClientIdentification.localFormat], at: target)
    let result: ProcessResult
    switch await run(request) {
    case .success(let ran): result = ran
    case .failure(let failure): return .failure(failure)
    }
    let output: String
    if Self.isNoServer(result) {
      output = ""
    } else if let failure = Self.failure(of: result, remote: target.host.isRemote) {
      return .failure(failure)
    } else {
      output = String(decoding: result.standardOutput, as: UTF8.self)
    }
    guard !result.standardOutputTruncated,
      let reading = PlainClientIdentification.local(
        listing: output, sessionID: sessionID, terminal: terminal)
    else { return .failure(.unreadable) }
    return .success(reading)
  } // End of func localReading(of:terminal:at:)

  /// An SSH host's confirmation reading (PLAN.md D38): `PlainClientIdentification.remoteScript`
  /// with the host's override, the session id and the launch token, over discovery's
  /// noninteractive ssh, its answer read by `PlainClientIdentification.remote(output:)`.
  public func remoteReading(
    of sessionID: TmuxSessionID,
    token: LaunchToken,
    at target: Target
  ) async -> Result<PlainClientIdentification.Reading, PlainTmuxCommandFailure> {
    let request = self.request(
      PlainClientIdentification.remoteScript,
      arguments: PlainClientIdentification.remoteArguments(
        tmuxPathOverride: target.tmuxPathOverride, sessionID: sessionID, token: token),
      on: target.host)
    let result: ProcessResult
    switch await run(request) {
    case .success(let ran): result = ran
    case .failure(let failure): return .failure(failure)
    }
    if let failure = Self.failure(of: result, remote: target.host.isRemote) {
      return .failure(failure)
    }
    guard !result.standardOutputTruncated,
      let reading = PlainClientIdentification.remote(
        output: String(decoding: result.standardOutput, as: UTF8.self))
    else { return .failure(.unreadable) }
    return .success(reading)
  } // End of func remoteReading(of:token:at:)

  /// tmux's clock and the clients of the session `sessionID` (`PlainSessionClients`), the
  /// read-only listing of "Detach other clients…".
  public func sessionClients(
    of sessionID: TmuxSessionID,
    at target: Target
  ) async -> Result<PlainSessionClients, PlainTmuxCommandFailure> {
    let result: ProcessResult
    switch await run(tmuxRequest(PlainSessionClients.arguments, at: target)) {
    case .success(let ran): result = ran
    case .failure(let failure): return .failure(failure)
    }
    if let failure = Self.failure(of: result, remote: target.host.isRemote) {
      return .failure(failure)
    }
    guard !result.standardOutputTruncated,
      let listing = PlainSessionClients.read(
        String(decoding: result.standardOutput, as: UTF8.self), sessionID: sessionID)
    else { return .failure(.unreadable) }
    return .success(listing)
  } // End of func sessionClients(of:at:)

  // MARK: - Bound commands

  /// The read-only presence check of `client` in `session` (`PlainClientPresence`): `present`
  /// or `notThisClient`; a failed run or an answer that is neither is a failure.
  public func presence(
    of client: OtherClient,
    in session: BoundSessionIdentity,
    at target: Target
  ) async -> Result<PlainClientPresence.Outcome, PlainTmuxCommandFailure> {
    guard let arguments = PlainClientPresence.arguments(of: client, in: session) else {
      return .failure(.notWritable)
    }
    let result: ProcessResult
    switch await run(tmuxRequest(arguments, at: target)) {
    case .success(let ran): result = ran
    case .failure(let failure): return .failure(failure)
    }
    let outcome = PlainClientPresence.outcome(
      exitStatus: result.timedOut ? nil : result.exitCode,
      standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
      standardError: String(decoding: result.standardError, as: UTF8.self))
    guard outcome != .failed else {
      return .failure(Self.failure(of: result, remote: target.host.isRemote) ?? .unreadable)
    }
    return .success(outcome)
  } // End of func presence(of:in:at:)

  /// The bound detach of `client` from `session` (`PlainClientDetach`, PLAN.md D38), which
  /// with `kept` the server runs only while `kept` still holds the session
  /// (`PlainClientDetach.arguments(of:keeping:in:)`): `detached` or `notThisClient` (either
  /// client, the session or the server not the recorded one); a failed run or an answer that
  /// is neither is a failure (the detach may have run, unless it could not be written).
  public func detach(
    _ client: OtherClient,
    keeping kept: OtherClient? = nil,
    from session: BoundSessionIdentity,
    at target: Target
  ) async -> Result<PlainClientDetach.Outcome, PlainTmuxCommandFailure> {
    guard let arguments = PlainClientDetach.arguments(of: client, keeping: kept, in: session)
    else {
      return .failure(.notWritable)
    }
    let result: ProcessResult
    switch await run(tmuxRequest(arguments, at: target)) {
    case .success(let ran): result = ran
    case .failure(let failure): return .failure(failure)
    }
    let outcome = PlainClientDetach.outcome(
      exitStatus: result.timedOut ? nil : result.exitCode,
      standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
      standardError: String(decoding: result.standardError, as: UTF8.self))
    guard outcome != .failed else {
      return .failure(Self.failure(of: result, remote: target.host.isRemote) ?? .unreadable)
    }
    return .success(outcome)
  } // End of func detach(_:keeping:from:at:)

  // MARK: - Running

  /// Runs `request`; a runner failure or the caller's cancellation is a failure.
  func run(_ request: ProcessRequest) async -> Result<ProcessResult, PlainTmuxCommandFailure> {
    do {
      return .success(try await runner.run(request))
    } catch let error as ProcessRunnerError {
      return .failure(.couldNotRun(error))
    } catch {
      return .failure(.cancelled)
    }
  } // End of func run(_:)

  /// The failure a finished run shows, or `nil` when it exited 0 in time: a timeout, ssh's 255
  /// (remotely), the script's 66, or any other end.
  static func failure(of result: ProcessResult, remote: Bool) -> PlainTmuxCommandFailure? {
    if result.timedOut { return .timedOut }
    switch result.termination {
    case .exited(0): return nil
    case .exited(ErrorClassifier.sshErrorExitStatus) where remote: return .sshFailed
    case .exited(TmuxCommands.ExitStatus.tmuxMissing): return .tmuxMissing
    default: return .exited(result.termination)
    }
  } // End of static func failure(of:remote:)

  /// Whether `result` is tmux's exit 1 with its "no server" error.
  static func isNoServer(_ result: ProcessResult) -> Bool {
    guard !result.timedOut, result.termination == .exited(1) else { return false }
    return ErrorClassifier.isNoServerMessage(ErrorClassifier.firstLine(of: result.standardError))
  }
} // End of struct PlainTmuxCommands
