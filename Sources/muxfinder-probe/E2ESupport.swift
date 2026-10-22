import Darwin
import Foundation
import MuxFinderCore
import os

/// tmux for the e2e harness: the default server only (the one `muxfinder-launch` sees inside
/// iTerm2), argv only, always `-u` (D12), `TMUX` and `TMUX_PANE` removed, a deadline on every
/// call. The harness only ever names its own session, by id.
struct TestTmux: Sendable {
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

  /// Runs `tmux -u <arguments>`.
  func run(_ arguments: [String], timeout: Duration = .seconds(5)) async throws -> Output {
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
