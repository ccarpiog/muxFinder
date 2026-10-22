import Darwin
import Foundation
import MuxFinderCore
import os

/// tmux as the e2e harness drives it, on this Mac (`TestTmux`) or on a remote host
/// (`RemoteTestTmux`): the default server only, always `-u` (D12), a deadline on every call.
/// The harness only ever names its own session, by id.
protocol HarnessTmux: Sendable {
  /// Where tmux runs, for the header: `at <path>` or `on <destination>`.
  var location: String { get }
  /// Whether tmux runs on this Mac (so pane processes can be checked with `kill(pid, 0)`).
  var isLocal: Bool { get }
  /// Runs `tmux -u <arguments>` with the implementation's deadline.
  func run(_ arguments: [String]) async throws -> TestTmux.Output
  /// `tmux -V`, or `nil`.
  func version() async -> String?
  /// The command of a plain control client, `tmux -u -C attach-session -t '=<name>'`, attached
  /// to the session named exactly `name` (one of the run's `muxfinder-test-*` names), for
  /// `BackgroundControlClient` (the Move here step, PLAN.md D21).
  func controlClientCommand(attachingTo name: String) -> HarnessCommand
}

/// One process the harness starts itself: the executable, its arguments after argv[0], and
/// its complete environment.
struct HarnessCommand: Sendable {
  /// The absolute path of the executable.
  let executable: String
  /// The arguments after argv[0].
  let arguments: [String]
  /// The environment.
  let environment: [String: String]
}

/// The tmux arguments of a plain control client attached to the session named exactly `name`.
func controlClientArguments(attachingTo name: String) -> [String] {
  ["-C", "attach-session", "-t", "=" + name]
}

/// tmux on this Mac for the e2e harness: the default server only (the one `muxfinder-launch`
/// sees inside iTerm2), argv only, always `-u` (D12), `TMUX` and `TMUX_PANE` removed, a
/// deadline on every call.
struct TestTmux: HarnessTmux {
  /// The PLAN.md D5 search order, without the `command -v` fallback.
  static let candidates = [
    "/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/opt/local/bin/tmux", "/usr/bin/tmux",
  ]

  /// The tmux executable.
  let path: String
  /// Runs tmux with its own process group and a hard deadline.
  let runner = PosixSpawnProcessRunner()
  /// This process's environment for local tools, without `TMUX` and `TMUX_PANE`.
  let environment = DiscoveryProbe.localEnvironment(base: ProcessInfo.processInfo.environment)

  /// The first executable candidate, or `nil`.
  static func locate() -> TestTmux? {
    candidates.first { access($0, X_OK) == 0 }.map { TestTmux(path: $0) }
  }

  /// What one tmux call printed and how it ended.
  struct Output: Sendable {
    /// The exit status, or `nil` when tmux was killed by a signal.
    let status: Int32?
    /// Standard output.
    let standardOutput: String
    /// Standard error.
    let standardError: String
    /// Whether the deadline killed it.
    let timedOut: Bool

    /// Exit status 0 within the deadline.
    var succeeded: Bool { status == 0 && !timedOut }

    /// Standard output without its trailing line break, split into lines.
    var lines: [String] {
      var text = Substring(standardOutput)
      while text.last == "\n" { text.removeLast() }
      return text.isEmpty
        ? []
        : text.split(separator: "\n", omittingEmptySubsequences: false)
          .map(String.init)
    }
  } // End of struct Output

  /// `at <path>`.
  var location: String { "at \(path)" }

  /// Always `true`.
  var isLocal: Bool { true }

  /// Runs `tmux -u <arguments>` with a 5 s deadline.
  func run(_ arguments: [String]) async throws -> Output {
    try await run(arguments, timeout: .seconds(5))
  }

  /// Runs `tmux -u <arguments>`.
  func run(_ arguments: [String], timeout: Duration) async throws -> Output {
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: path), arguments: ["-u"] + arguments,
      environment: environment, timeout: timeout)
    let result = try await runner.run(request)
    return Output(
      status: result.exitCode,
      standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
      standardError: String(decoding: result.standardError, as: UTF8.self),
      timedOut: result.timedOut)
  } // End of func run(_:timeout:)

  /// `tmux -V`, or `nil`.
  func version() async -> String? {
    guard let output = try? await run(["-V"]), output.succeeded else { return nil }
    return output.lines.first
  }

  /// `<path> -u -C attach-session -t =<name>`, argv only, with the local environment.
  func controlClientCommand(attachingTo name: String) -> HarnessCommand {
    HarnessCommand(
      executable: path, arguments: ["-u"] + controlClientArguments(attachingTo: name),
      environment: environment)
  }
}

/// tmux on a remote host for the e2e harness, over ssh (PLAN.md D3, D6):
/// `/usr/bin/ssh <discovery's noninteractive options> -n -T -- <destination> <D3 string>`, the
/// static `script` with every tmux argument POSIX single-quoted, and a 12 s deadline that kills
/// the whole process group. On the remote host the script unsets `TMUX` and `TMUX_PANE`, locates
/// tmux with the D5 rules and runs `tmux -u <arguments>`; it writes no file there itself.
struct RemoteTestTmux: HarnessTmux {
  /// The remote script: the tmux locator, then tmux with the script's positional parameters.
  /// Exit 127 when no tmux is found.
  static let script: StaticShellScript =
    TmuxLocator.script
      + #"""
      unset TMUX TMUX_PANE
      muxfinder_locate_tmux ''
      if [ -z "$t" ]; then
        printf 'tmux not found\n' >&2
        exit 127
      fi
      exec "$t" -u "$@"

      """#

  /// The SSH destination, validated.
  let destination: String
  /// Runs ssh with its own process group and a hard deadline.
  let runner = PosixSpawnProcessRunner()
  /// This process's environment for local tools, without `TMUX` and `TMUX_PANE`.
  let environment = DiscoveryProbe.localEnvironment(base: ProcessInfo.processInfo.environment)

  /// `on <destination>`.
  var location: String { "on \(destination)" }

  /// Always `false`.
  var isLocal: Bool { false }

  /// Runs `tmux -u <arguments>` on the remote host. An ssh failure is exit status 255.
  func run(_ arguments: [String]) async throws -> TestTmux.Output {
    let command = ShellQuoting.remoteCommand(script: Self.script, args: arguments)
    let request = ProcessRequest(
      executableURL: DiscoveryProbe.sshURL,
      arguments: DiscoveryProbe.sshOptions + ["-n", "-T", "--", destination, command],
      environment: environment, timeout: DiscoveryProbe.defaultTimeout)
    let result = try await runner.run(request)
    return TestTmux.Output(
      status: result.exitCode,
      standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
      standardError: String(decoding: result.standardError, as: UTF8.self),
      timedOut: result.timedOut)
  } // End of func run(_:)

  /// `tmux -V` on the remote host, or `nil` (also when ssh failed).
  func version() async -> String? {
    guard let output = try? await run(["-V"]), output.succeeded else { return nil }
    return output.lines.first
  }

  /// The ssh options of the background control client: discovery's noninteractive ones
  /// (`BatchMode=yes`, the connect timeout, the keepalive) plus no connection sharing
  /// (`ControlMaster=no`, `ControlPath=none`), so the client is one ssh connection of its own
  /// that ends with it and never becomes or uses a shared master. `-T`: no terminal (a plain
  /// control client needs none), and no `-n`, since its standard input is the harness's pipe.
  static let controlClientSSHOptions =
    DiscoveryProbe.sshOptions + ["-o", "ControlMaster=no", "-o", "ControlPath=none", "-T"]

  /// `/usr/bin/ssh <controlClientSSHOptions> -- <destination> <D3 string>`: the static `script`
  /// with the control client's tmux arguments single-quoted, so the remote side runs
  /// `tmux -u -C attach-session -t =<name>` and writes no file.
  func controlClientCommand(attachingTo name: String) -> HarnessCommand {
    let command = ShellQuoting.remoteCommand(
      script: Self.script, args: controlClientArguments(attachingTo: name))
    return HarnessCommand(
      executable: DiscoveryProbe.sshURL.path(percentEncoded: false),
      arguments: Self.controlClientSSHOptions + ["--", destination, command],
      environment: environment)
  } // End of func controlClientCommand(attachingTo:)
}

/// The launch store of `e2e-remote`'s `still waiting` step: the real store, except that every
/// request it writes asks for the helper's test-only launch delay
/// (`LaunchRequest.testLaunchDelaySeconds`, PLAN.md D14 *Test mode*). The helper honors it
/// only in test mode, which the run's setup turns on, and then waits that long before it would
/// start ssh, so its launch tab stays open with no login and no tmux connection past the
/// attach's 20 s budget.
struct TestLaunchDelayStore: LaunchRequestStore {
  /// The real store.
  let base: LaunchStore
  /// The delay every request asks for, in seconds (`LaunchRequest.testLaunchDelayRange`).
  let seconds: Int

  /// Writes `request` with the delay through the real store.
  func writeRequest(_ request: LaunchRequest) throws(LaunchStoreError) {
    var delayed = request
    delayed.testLaunchDelaySeconds = seconds
    try base.writeRequest(delayed)
  }

  /// The real store's `discardRequest(_:)`.
  @discardableResult
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    try base.discardRequest(id)
  }

  /// The real store's `takeResult(_:)`.
  func takeResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult? {
    try base.takeResult(id)
  }

  /// The real store's `sweep()`.
  @discardableResult
  func sweep() throws(LaunchStoreError) -> Int {
    try base.sweep()
  }
} // End of struct TestLaunchDelayStore

/// The real process runner, counting every process it is asked to run, so the invalid-name
/// step can prove that validation refused the names before anything ran.
final class CountingProcessRunner: ProcessRunner {
  /// The real runner.
  private let base = PosixSpawnProcessRunner()
  /// Runs so far.
  private let runs = OSAllocatedUnfairLock(initialState: 0)

  /// How many processes were asked for so far.
  var count: Int { runs.withLock { $0 } }

  /// Counts the run, then runs `request` with the real runner.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    runs.withLock { $0 += 1 }
    return try await base.run(request)
  }
}

/// Discovery that reports a wrong `session_created` for one session, so the coordinator writes
/// a stale request and the helper's guard must refuse it (e2e step 8). Everything else is the
/// real probe's answer.
struct StaleCreationDiscovery: HostDiscovering {
  /// The real discovery.
  let base: DiscoveryProbe
  /// The session whose creation time is falsified.
  let sessionID: TmuxSessionID
  /// Added to its `session_created`.
  let offset: Int64

  /// The real probe's result with the one creation time shifted.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    var result = try await base.discover(host)
    if case .ok(var sessions) = result.status {
      for index in sessions.indices where sessions[index].key.sessionID == sessionID {
        sessions[index].createdAt += offset
      }
      result.status = .ok(sessions)
    }
    return result
  } // End of func discover(_:)
}

/// Watches SIGINT, SIGTERM and SIGHUP (ignored as signals, seen through dispatch sources) so the
/// harness can clean up before it exits.
final class SignalWatcher: Sendable {
  /// The watched signals.
  static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

  /// The signals as they arrive.
  let stream: AsyncStream<Int32>
  /// The dispatch sources; kept alive for the life of the watcher.
  private let sources: OSAllocatedUnfairLock<[any DispatchSourceSignal]>

  /// Starts watching.
  init() {
    var continuation: AsyncStream<Int32>.Continuation!
    stream = AsyncStream { continuation = $0 }
    let sink = continuation!
    var created: [any DispatchSourceSignal] = []
    for number in Self.signals {
      signal(number, SIG_IGN)
      let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
      source.setEventHandler { sink.yield(number) }
      source.resume()
      created.append(source)
    }
    sources = OSAllocatedUnfairLock(initialState: created)
  } // End of init()

  /// Stops watching and restores the default dispositions.
  func stop() {
    sources.withLock { list in
      for source in list { source.cancel() }
      list.removeAll()
    }
    for number in Self.signals { signal(number, SIG_DFL) }
  }
}

/// What the harness learned about one launch from the coordinator's updates: the states in
/// order and the launch tab's session, recorded as soon as iTerm2 reports it.
final class UpdateRecorder: Sendable {
  /// Recorded updates and launch tab sessions.
  private struct State {
    /// Every update, oldest first.
    var updates: [AttachUpdate] = []
    /// Every launch tab session reported by a `launched` state.
    var gatewaySessionIDs: [String] = []
    /// When each launch tab session was reported.
    var launchedAt: [String: ContinuousClock.Instant] = [:]
  }

  /// The recorded state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Records one update (the coordinator's update handler).
  func record(_ update: AttachUpdate) {
    state.withLock { state in
      state.updates.append(update)
      if case .launched(let sessionID) = update.state {
        state.gatewaySessionIDs.append(sessionID)
        state.launchedAt[sessionID] = .now
      }
    }
  }

  /// Every launch tab session reported so far.
  var gatewaySessionIDs: [String] { state.withLock { $0.gatewaySessionIDs } }

  /// Whether `sessionID` is a launch tab reported so far (the run's attachment index asks only
  /// connections such tabs own).
  func isLaunchTab(_ sessionID: String) -> Bool {
    state.withLock { $0.launchedAt[sessionID] != nil }
  }

  /// When the latest of `sessionIDs` was launched, or `nil` if none was.
  func latestLaunch(of sessionIDs: [String]) -> ContinuousClock.Instant? {
    state.withLock { state in sessionIDs.compactMap { state.launchedAt[$0] }.max() }
  }

  /// How long ago the launch tab `sessionID` was reported open, in seconds with one decimal
  /// (`"?"` when it never was). It opened a moment before iTerm2 reported it, so the tab is
  /// slightly older than this.
  func age(of sessionID: String) -> String {
    guard let launched = state.withLock({ $0.launchedAt[sessionID] }) else { return "?" }
    return String(format: "%.1f", Double(milliseconds(.now - launched)) / 1000)
  }

  /// The state kinds of `launchID`'s updates, in order.
  func stateKinds(of launchID: LaunchToken) -> [String] {
    state.withLock { $0.updates.filter { $0.launchID == launchID }.map(\.state.kind) }
  }

  /// How many updates were recorded so far: a mark for `updates(after:)`.
  var count: Int { state.withLock { $0.updates.count } }

  /// The updates recorded after the first `mark` ones, oldest first.
  func updates(after mark: Int) -> [AttachUpdate] {
    state.withLock { Array($0.updates.dropFirst(mark)) }
  }

  /// When the launch tab `sessionID` was reported open, or `nil`.
  func launchedAt(_ sessionID: String) -> ContinuousClock.Instant? {
    state.withLock { $0.launchedAt[sessionID] }
  }

  /// How many `launched` states were reported for `key` so far.
  func launchCount(for key: SessionKey) -> Int {
    state.withLock { state in
      state.updates.filter { update in
        guard update.key == key, case .launched = update.state else { return false }
        return true
      }.count
    }
  }
}

/// Polls `condition` every 200 ms until it returns a value or `timeout` passes. Runs on the
/// caller's actor, so the condition may use the caller's state.
func poll<Value: Sendable>(
  isolation: isolated (any Actor)? = #isolation,
  timeout: Duration,
  _ condition: () async throws -> Value?
) async throws -> Value? {
  let deadline = ContinuousClock.now + timeout
  while true {
    if let value = try await condition() { return value }
    guard ContinuousClock.now < deadline else { return nil }
    try await Task.sleep(for: .milliseconds(200))
  }
} // End of func poll(isolation:timeout:_:)

/// Whole milliseconds of `duration`.
func milliseconds(_ duration: Duration) -> Int {
  Int(duration / .milliseconds(1))
}
