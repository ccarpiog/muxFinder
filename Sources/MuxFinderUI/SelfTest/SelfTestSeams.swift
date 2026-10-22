import Foundation
import MuxFinderCore
import os

/// The app's hidden self-tests (PLAN.md D25): `--selftest attach-local` and
/// `--selftest new-session-local`.
public enum SelfTestKind: String, Sendable, Hashable, CaseIterable {
  /// Create a `muxfinder-test-*` session, Open it (confirmed; a burst of five clicks gives one
  /// launch), Open it again (focused, no second launch), Detach from this Mac, kill it.
  case attachLocal = "attach-local"
  /// New session with a `muxfinder-test-*` name (created and confirmed), the same name again
  /// (collision), Detach from this Mac, kill it.
  case newSessionLocal = "new-session-local"
}

/// A self-test asked for on the command line.
public struct SelfTestRequest: Sendable, Hashable {
  /// Which self-test.
  public var kind: SelfTestKind
  /// `--selftest-keep`: after the attachment is confirmed, print the session name, the iTerm2
  /// connection id and the gateway session id, then wait for SIGTERM and quit through the
  /// normal `AppTermination` path, leaving the session and the connection in place.
  public var keep: Bool

  /// Creates a request.
  public init(kind: SelfTestKind, keep: Bool = false) {
    self.kind = kind
    self.keep = keep
  }
}

/// The bounds of every wait of a self-test, in real time.
public struct SelfTestTimeouts: Sendable {
  /// For the engine to list the test session (or This Mac).
  public var listing: Duration
  /// For an Open, a New session or a move to end (the coordinator's own budgets are 15 s to a
  /// connection, 5 s for the tab, plus discovery).
  public var attach: Duration
  /// For a "Detach from this Mac" to end (it waits until the tab is 10 s old, then up to 10 s
  /// for the connection to close and 5 s for the helper's result).
  public var detach: Duration
  /// How old every launch tab of the run must be before cleanup ends its session: iTerm2
  /// blocks its API behind a modal warning for a session that ends within 3 s of starting, so
  /// cleanup keeps the coordinator's 10 s, plus a margin.
  public var launchTabAge: Duration
  /// The pause between two looks at the model.
  public var pollInterval: Duration

  /// Creates timeouts; the defaults are the real runs'.
  public init(
    listing: Duration = .seconds(20),
    attach: Duration = .seconds(45),
    detach: Duration = .seconds(45),
    launchTabAge: Duration = .seconds(11),
    pollInterval: Duration = .milliseconds(100)
  ) {
    self.listing = listing
    self.attach = attach
    self.detach = detach
    self.launchTabAge = launchTabAge
    self.pollInterval = pollInterval
  } // End of init(listing:attach:detach:launchTabAge:pollInterval:)
}

/// tmux as a self-test drives it outside the app's own paths: creating its test session (for
/// `attach-local`), killing it only while it is still exactly that session, and finding it by
/// its exact name when its creation's output was lost. Only `muxfinder-test-*` sessions on This
/// Mac's default server.
public protocol SelfTestTmux: Sendable {
  /// Creates the detached session `name` on `host` (This Mac), its pane running `command`.
  func createSession(
    named name: String,
    command: [String],
    on host: HostConfig
  ) async throws(SessionCreationError) -> CreatedSession

  /// Kills `session` only while it is still exactly that session
  /// (`CreatedSession.killIfUnchangedArguments`, one tmux command).
  func kill(_ session: CreatedSession) async -> CreatedSession.KillOutcome

  /// The one session named exactly `name` created at or after `earliest` (seconds since
  /// 1970), or `nil`.
  func findSession(named name: String, createdNoEarlierThan earliest: Int64) async
    -> CreatedSession?
}

/// Everything a self-test runs on. `production(sessionName:helperPath:output:)` wires the real
/// iTerm2 client, discovery, launch store, tmux and clock; the hermetic tests pass a fake
/// iTerm2 integration, fake discovery and tmux, an in-memory store and a manual clock.
public struct SelfTestSeams: Sendable {
  /// iTerm2 (the coordinator's, and the setup's read-only status check).
  public var iTerm2: any ITerm2Integration
  /// Discovery, for the engine and the coordinator.
  public var discovery: any HostDiscovering
  /// The launch files.
  public var store: any LaunchRequestStore
  /// The helper iTerm2 runs in the launch tab.
  public var helperPath: LaunchHelperPath
  /// The coordinator's clock.
  public var clock: any AttachClock
  /// The attachment index's clock (its 3 s question timeout).
  public var indexClock: any AttachClock
  /// The coordinator's budgets.
  public var coordinatorConfiguration: AttachCoordinator.Configuration
  /// What New session creates sessions with (`TmuxCommands` in production).
  public var sessionCreator: any SessionCreating
  /// tmux outside the app's paths.
  public var tmux: any SelfTestTmux
  /// The bounds of every wait.
  public var timeouts: SelfTestTimeouts
  /// The test session's name (`muxfinder-test-<8 hex digits>`).
  public var sessionName: String
  /// Seconds since 1970, now (to find a session whose creation output was lost).
  public var wallClock: @Sendable () -> Int64
  /// Where the step log goes (standard output in production).
  public var output: @Sendable (String) -> Void
  /// The coordinator's operation log, printed after a failure (kinds only, no user data).
  public var diagnostics: DiagnosticsLog?

  /// Creates seams from their parts.
  public init(
    iTerm2: any ITerm2Integration,
    discovery: any HostDiscovering,
    store: any LaunchRequestStore,
    helperPath: LaunchHelperPath,
    clock: any AttachClock = SystemAttachClock(),
    indexClock: any AttachClock = SystemAttachClock(),
    coordinatorConfiguration: AttachCoordinator.Configuration = .init(),
    sessionCreator: any SessionCreating = TmuxCommands(),
    tmux: any SelfTestTmux,
    timeouts: SelfTestTimeouts = SelfTestTimeouts(),
    sessionName: String = SelfTestSeams.newSessionName(),
    wallClock: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) },
    output: @escaping @Sendable (String) -> Void,
    diagnostics: DiagnosticsLog? = nil
  ) {
    self.iTerm2 = iTerm2
    self.discovery = discovery
    self.store = store
    self.helperPath = helperPath
    self.clock = clock
    self.indexClock = indexClock
    self.coordinatorConfiguration = coordinatorConfiguration
    self.sessionCreator = sessionCreator
    self.tmux = tmux
    self.timeouts = timeouts
    self.sessionName = sessionName
    self.wallClock = wallClock
    self.output = output
    self.diagnostics = diagnostics
  } // End of init(iTerm2:discovery:store:helperPath:clock:indexClock:…)

  /// A fresh `muxfinder-test-<8 hex digits>` name.
  public static func newSessionName() -> String {
    "muxfinder-test-" + String(format: "%08x", UInt32.random(in: .min ... .max))
  }

  /// The real parts: one `ITerm2APIClient`, `DiscoveryProbe`, the real `LaunchStore`, the
  /// bundled helper, the system clocks, `TmuxCommands` and This Mac's tmux (located by
  /// discovery, D5), the default timeouts and a fresh session name; the log on standard output.
  public static func production(helperPath: LaunchHelperPath) -> SelfTestSeams {
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let discovery = DiscoveryProbe()
    return SelfTestSeams(
      iTerm2: ITerm2APIClient(diagnostics: diagnostics), discovery: discovery,
      store: LaunchStore(), helperPath: helperPath,
      tmux: LocalSelfTestTmux(discovery: discovery),
      output: { line in FileHandle.standardOutput.write(Data((line + "\n").utf8)) },
      diagnostics: diagnostics)
  } // End of static func production(helperPath:)
}

/// This Mac's tmux for the self-tests: creation through `TmuxCommands` (the core's static
/// script, argv only, never replacing a session), and the kill and the lookup through the tmux
/// that discovery located (`ProbeReport.tmuxPath`, D5), run by argv with the local environment
/// without `TMUX` and `TMUX_PANE` and a 5 s deadline. Only ever names its own session.
public struct LocalSelfTestTmux: SelfTestTmux {
  /// Locates tmux.
  let discovery: DiscoveryProbe
  /// Runs tmux.
  let runner = PosixSpawnProcessRunner()

  /// Creates the tmux of `discovery`'s This Mac.
  public init(discovery: DiscoveryProbe) {
    self.discovery = discovery
  }

  /// Creates the session through `TmuxCommands`.
  public func createSession(
    named name: String,
    command: [String],
    on host: HostConfig
  ) async throws(SessionCreationError) -> CreatedSession {
    try await TmuxCommands().createSession(
      NewSessionRequest(host: host, name: name, command: command))
  }

  /// Runs `tmux -u <killIfUnchangedArguments>` and reads its outcome.
  public func kill(_ session: CreatedSession) async -> CreatedSession.KillOutcome {
    guard let arguments = session.killIfUnchangedArguments,
      let output = await run(arguments)
    else { return .failed }
    return CreatedSession.killOutcome(
      exitStatus: output.exitCode,
      standardOutput: String(decoding: output.standardOutput, as: UTF8.self),
      standardError: String(decoding: output.standardError, as: UTF8.self))
  }

  /// Lists the sessions with `CreatedSession.format` and picks the one named exactly `name`.
  public func findSession(
    named name: String,
    createdNoEarlierThan earliest: Int64
  ) async -> CreatedSession? {
    guard let output = await run(["list-sessions", "-F", CreatedSession.format]),
      output.exitCode == 0
    else { return nil }
    let lines = String(decoding: output.standardOutput, as: UTF8.self)
      .split(separator: "\n").map(String.init)
    return CreatedSession.find(named: name, createdNoEarlierThan: earliest, in: lines)
  } // End of func findSession(named:createdNoEarlierThan:)

  /// Runs `<tmux> -u <arguments>` on This Mac's default server; `nil` when tmux cannot be
  /// located or run.
  private func run(_ arguments: [String]) async -> ProcessResult? {
    let host = HostConfig(displayName: "This Mac", mode: .local)
    guard let found = try? await discovery.discover(host), let path = found.report?.tmuxPath,
      path.hasPrefix("/")
    else { return nil }
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: path), arguments: ["-u"] + arguments,
      environment: DiscoveryProbe.localEnvironment(base: ProcessInfo.processInfo.environment),
      timeout: .seconds(5))
    return try? await runner.run(request)
  } // End of func run(_:)
}

/// What a self-test learned from the coordinator's updates: the launch tabs it opened (its
/// attachment index asks only connections they own) and when, and the launches per session.
public final class LaunchTabRecorder: Sendable {
  /// The recorded state.
  private struct State {
    /// When each launch tab was reported open (real time).
    var openedAt: [String: ContinuousClock.Instant] = [:]
    /// `launched` updates per session.
    var launches: [SessionKey: Int] = [:]
  }

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates an empty recorder.
  public init() {}

  /// Records one update (before the model sees it).
  public func record(_ update: AttachUpdate) {
    guard case .launched(let sessionID) = update.state else { return }
    state.withLock { state in
      state.openedAt[sessionID] = state.openedAt[sessionID] ?? .now
      state.launches[update.key, default: 0] += 1
    }
  }

  /// Whether `sessionID` is a launch tab this run opened.
  public func isLaunchTab(_ sessionID: String) -> Bool {
    state.withLock { $0.openedAt[sessionID] != nil }
  }

  /// How many launch tabs were opened for `key`.
  public func launchCount(for key: SessionKey) -> Int {
    state.withLock { $0.launches[key, default: 0] }
  }

  /// When the newest launch tab was opened, if any.
  public var newestLaunch: ContinuousClock.Instant? {
    state.withLock { $0.openedAt.values.max() }
  }

  /// Every launch tab opened so far.
  public var launchTabs: Set<String> {
    state.withLock { Set($0.openedAt.keys) }
  }
}
