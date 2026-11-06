import Foundation
import os

// The seams of `e2e-plain` (PLAN.md D38 *The plain runs (I-12c3b)*): what the run needs from the
// host's tmux, from the plain control clients it attaches itself and from the window layer's
// close, so the probe passes the real parts and the tests pass fakes or a private tmux server.

/// What one tmux call of the run printed and how it ended.
public struct E2EPlainTmuxOutput: Sendable, Hashable {
  /// The exit status, or `nil` when tmux was killed by a signal.
  public let status: Int32?
  /// Standard output.
  public let standardOutput: String
  /// Standard error.
  public let standardError: String
  /// Whether the deadline killed it.
  public let timedOut: Bool

  /// An output of these values.
  public init(status: Int32?, standardOutput: String, standardError: String, timedOut: Bool) {
    self.status = status
    self.standardOutput = standardOutput
    self.standardError = standardError
    self.timedOut = timedOut
  }

  /// The output of a finished process run.
  public init(_ result: ProcessResult) {
    self.init(
      status: result.exitCode,
      standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
      standardError: String(decoding: result.standardError, as: UTF8.self),
      timedOut: result.timedOut)
  }

  /// Exit status 0 within the deadline.
  public var succeeded: Bool { status == 0 && !timedOut }

  /// Standard output without its trailing line breaks, split into lines.
  public var lines: [String] {
    var text = Substring(standardOutput)
    while text.last == "\n" { text.removeLast() }
    return text.isEmpty
      ? [] : text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
  }
} // End of struct E2EPlainTmuxOutput

/// One process the run starts itself: the executable, its arguments after argv[0], and its
/// complete environment.
public struct E2EPlainProcessCommand: Sendable, Hashable {
  /// The absolute path of the executable.
  public let executable: String
  /// The arguments after argv[0].
  public let arguments: [String]
  /// The environment.
  public let environment: [String: String]

  /// A command of these values.
  public init(executable: String, arguments: [String], environment: [String: String]) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
  }
} // End of struct E2EPlainProcessCommand

/// tmux on the host under test, as the run drives it: the default server only (the one the
/// helper attaches to), always `-u` (D12), a deadline on every call; locally argv only,
/// remotely over BatchMode ssh with a static script (D3). The run only ever names its own
/// session.
public protocol E2EPlainHostTmux: Sendable {
  /// Where tmux runs, for the header: `at <path>` or `on <destination>`.
  var location: String { get }
  /// Runs `tmux -u <arguments>` with the implementation's deadline.
  func run(_ arguments: [String]) async throws -> E2EPlainTmuxOutput
  /// `tmux -V`, or `nil` (also when the host does not answer).
  func version() async -> String?
  /// The command of a plain control client of the run's own, `tmux -u -C attach-session -t
  /// '=<name>'` attached to the session named exactly `name` (remotely through noninteractive
  /// ssh with no connection sharing).
  func controlClientCommand(attachingTo name: String) -> E2EPlainProcessCommand
}

/// A plain tmux control client the run started and keeps attached in the background (the
/// probe's `BackgroundControlClient`): nothing it prints is kept, only whether a line started
/// with `%exit`.
public protocol E2EPlainControlClient: AnyObject, Sendable {
  /// Its process id.
  var processID: Int32 { get }
  /// Whether it still runs.
  var isRunning: Bool { get }
  /// Whether a line of its standard output started with `%exit`.
  var sawExitNotification: Bool { get }
  /// The first bytes of its standard error, printable ASCII only.
  var errorText: String { get }
  /// Waits up to `time` for it to exit by itself and returns how it ended; `nil` while it runs.
  func waitForExit(within time: Duration) async -> ProcessResult.Termination?
  /// Ends it on every way out (its input closed, then its process group ended) and returns how
  /// it ended (`nil` only if it could not be reaped).
  @discardableResult
  func stop() async -> ProcessResult.Termination?
}

/// Starts one plain control client of the run's own from its command.
public typealias E2EPlainControlClientStarter =
  @Sendable (E2EPlainProcessCommand) throws -> any E2EPlainControlClient

/// The window layer's close as `e2e-plain` needs it (PLAN.md D38): close a window only by the id
/// the layer's own open recorded, and only once the window's process has ended (the run waits
/// for that first). `PlainTerminalWindows` conforms (its unattended policy rechecks the gate
/// right before the Apple event); tests pass `FakePlainTerminalWindowLayer`. Main actor, as the
/// layer is.
@MainActor
public protocol PlainTerminalWindowClosing: AnyObject, Sendable {
  /// `PlainTerminalWindows.close(_:of:)`: closes `window`, which `loaded` itself opened.
  func close(
    _ window: PlainTerminalWindow,
    of loaded: LoadedTerminalDefinition
  ) throws(PlainTerminalWindowError)
}

/// What the kernel says of one pid now, as `e2e-plain` reads it for its own helpers (PLAN.md
/// D38 *The plain runs (I-12c3b)*). A window is closed only on positive evidence that its
/// helper ended, so a reading that failed is never taken for an ended process.
public enum E2EPlainProcessState: Sendable, Hashable {
  /// The kernel answered that no process has the pid.
  case absent
  /// A process has the pid; its kernel start time.
  case running(start: ProcessStartTime)
  /// The kernel's answer could not be read: nothing is known.
  case unreadable
}

/// The kernel as `e2e-plain` uses it for its own helpers (PLAN.md D38 *The plain runs
/// (I-12c3b)*): it reads a pid, and asks one positively identified helper to stop. A seam: the
/// probe uses `E2EPlainKernelProcesses`, tests a fake.
public protocol E2EPlainHelperProcesses: Sendable {
  /// What the kernel says of `processID` now. Read-only.
  func state(of processID: Int32) -> E2EPlainProcessState
  /// Sends SIGTERM (the helper's own request to stop: it finishes its wait for Return) to
  /// `processID` only while it is still the process that started at `start` and runs the
  /// executable at `executable`; returns whether it was sent. Nothing else is ever signalled.
  func terminate(_ processID: Int32, startedAt start: ProcessStartTime, executable: String) -> Bool
}

/// The real kernel: `sysctl` `KERN_PROC_PID` for a pid's state (`SystemProcessTable`'s
/// reading: no data is `absent`, an error or an unusable answer `unreadable`), and for
/// `terminate` that reading and `proc_pidpath` again right before `kill(SIGTERM)`, so a pid that
/// names another process by then is left alone.
public struct E2EPlainKernelProcesses: E2EPlainHelperProcesses {
  /// The kernel's reader.
  public init() {}

  /// `sysctl` `KERN_PROC_PID` for `processID` (a pid below 1 is `unreadable`: it names no
  /// process of its own).
  public func state(of processID: Int32) -> E2EPlainProcessState {
    guard processID > 0 else { return .unreadable }
    switch SystemProcessTable.kernelEntry(processID) {
    case .gone: return .absent
    case .unreadable: return .unreadable
    case .found(let entry): return .running(start: entry.startTime)
    }
  }

  /// Checks that `processID` (above 1) still has the start time `start` and runs `executable`
  /// (both paths with their symbolic links resolved), then sends SIGTERM to that process alone.
  public func terminate(
    _ processID: Int32,
    startedAt start: ProcessStartTime,
    executable: String
  ) -> Bool {
    guard processID > 1, state(of: processID) == .running(start: start),
      let path = SystemProcessTable.executablePath(processID),
      Self.resolved(path) == Self.resolved(executable)
    else { return false }
    return kill(processID, SIGTERM) == 0
  } // End of func terminate(_:startedAt:executable:)

  /// `path` with every symbolic link resolved (`realpath`), or `path` itself when that fails.
  static func resolved(_ path: String) -> String {
    guard let real = realpath(path, nil) else { return path }
    defer { free(real) }
    return String(cString: real)
  }
} // End of struct E2EPlainKernelProcesses

/// Discovery that counts its calls, so the run can prove a call ran none.
final class E2EPlainCountingDiscovery: HostDiscovering {
  /// The discovery asked.
  let base: any HostDiscovering
  /// Calls so far.
  private let calls = OSAllocatedUnfairLock(initialState: 0)

  /// Wraps `base`.
  init(base: any HostDiscovering) {
    self.base = base
  }

  /// Counts the call, then forwards it to `base`.
  func discover(_ host: HostConfig) async throws -> DiscoveryResult {
    calls.withLock { $0 += 1 }
    return try await base.discover(host)
  }

  /// Calls so far.
  var count: Int { calls.withLock { $0 } }
} // End of class E2EPlainCountingDiscovery

/// The plain backend's updates as the run saw them: every state in order and every window an
/// open reported (`plainLaunched`), so cleanup knows each window the run opened even when the
/// call that opened it was cancelled.
final class E2EPlainUpdateLog: Sendable {
  /// Recorded updates and windows.
  private struct State {
    /// Every update, oldest first.
    var updates: [AttachUpdate] = []
    /// Every launch with an update, in order of its first one.
    var launchIDs: [LaunchToken] = []
    /// The window each launch opened.
    var windows: [LaunchToken: PlainTerminalWindow] = [:]
  }

  /// The recorded state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Records one update (the backend's update handler).
  func record(_ update: AttachUpdate) {
    state.withLock { state in
      state.updates.append(update)
      if !state.launchIDs.contains(update.launchID) { state.launchIDs.append(update.launchID) }
      switch update.state {
      case .plainLaunched(let window), .plainStillWaiting(let window):
        state.windows[update.launchID] = window
      default:
        break
      }
    }
  } // End of func record(_:)

  /// How many updates were recorded so far: a mark for `updates(after:)`.
  var count: Int { state.withLock { $0.updates.count } }

  /// The updates recorded after the first `mark` ones, oldest first.
  func updates(after mark: Int) -> [AttachUpdate] {
    state.withLock { Array($0.updates.dropFirst(mark)) }
  }

  /// Every launch with an update, in order.
  var launchIDs: [LaunchToken] { state.withLock { $0.launchIDs } }

  /// The windows the launches opened, in launch order.
  var windows: [(launchID: LaunchToken, window: PlainTerminalWindow)] {
    state.withLock { state in
      state.launchIDs.compactMap { id in state.windows[id].map { (id, $0) } }
    }
  }

  /// The state kinds of `launchID`'s updates, in order.
  func stateKinds(of launchID: LaunchToken) -> [String] {
    state.withLock { $0.updates.filter { $0.launchID == launchID }.map(\.state.kind) }
  }

  /// The failure of `launchID`'s last `failed` update, if it had one.
  func failure(of launchID: LaunchToken) -> AttachFailure? {
    state.withLock { state in
      for update in state.updates.reversed() where update.launchID == launchID {
        if case .failed(let failure) = update.state { return failure }
      }
      return nil
    }
  }
} // End of class E2EPlainUpdateLog
