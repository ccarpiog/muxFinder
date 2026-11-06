import AppKit
import Darwin
import Foundation

/// What an `exec` terminal definition starts (PLAN.md D38): its executable inside the app
/// LaunchServices found, its argv after argv[0], and its whole environment.
public struct TerminalSpawnRequest: Sendable, Hashable {
  /// The executable's absolute file URL.
  public let executable: URL
  /// The arguments after argv[0] (argv[0] is the executable's path).
  public let arguments: [String]
  /// The child's whole environment; nothing else is inherited.
  public let environment: [String: String]

  /// A request with these values.
  public init(executable: URL, arguments: [String], environment: [String: String]) {
    self.executable = executable
    self.arguments = arguments
    self.environment = environment
  }
} // End of struct TerminalSpawnRequest

/// Starts an `exec` definition's program without a shell (PLAN.md D38, Phase I-12b3). A seam:
/// the app uses `DetachedTerminalProcessSpawner`, tests `FakeTerminalProcessSpawner`.
///
/// The spawn returns as soon as the program started: it never waits for the terminal app to
/// exit, and nothing ends the program when the call returns.
public protocol TerminalProcessSpawning: Sendable {
  /// Starts `request`'s program and returns its process id.
  func spawn(_ request: TerminalSpawnRequest) throws(ProcessRunnerError) -> Int32
}

/// The real spawner: `posix_spawn` with an argv (never a shell), the child in a session of its
/// own (`POSIX_SPAWN_SETSID`: no controlling terminal, its own process group, so no signal
/// meant for muxFinder's group or terminal reaches it), standard input, output and error on
/// `/dev/null`, every other descriptor closed (`POSIX_SPAWN_CLOEXEC_DEFAULT`), no blocked
/// signals and default dispositions. It returns right after the spawn; `DetachedChildReaper`
/// reaps the program whenever it exits, so it never stays a zombie, and nothing ever signals
/// it. When muxFinder quits first, the program goes on (launchd adopts it).
public struct DetachedTerminalProcessSpawner: TerminalProcessSpawning {
  /// The reaper every program started here is handed to.
  let reaper: DetachedChildReaper

  /// A spawner whose programs the shared reaper reaps.
  public init() {
    reaper = .shared
  }

  /// A spawner whose programs `reaper` reaps (tests).
  init(reaper: DetachedChildReaper) {
    self.reaper = reaper
  }

  /// Spawns `request`'s program detached and hands it to the reaper.
  public func spawn(_ request: TerminalSpawnRequest) throws(ProcessRunnerError) -> Int32 {
    let parameters = try ProcessSupervisor.launchParameters(
      for: ProcessRequest(
        executableURL: request.executable, arguments: request.arguments,
        environment: request.environment))
    let argv = try CStringArray(parameters.argv)
    let envp = try CStringArray(parameters.environment)
    var actions = try SpawnFileActions()
    defer { actions.destroy() }
    try actions.openNullDevice(as: STDIN_FILENO)
    for target in [STDOUT_FILENO, STDERR_FILENO] {
      try checkSpawnCall(
        posix_spawn_file_actions_addopen(&actions.raw, target, "/dev/null", O_WRONLY, 0),
        "posix_spawn_file_actions_addopen")
    }
    var attributes = try SpawnAttributes(newProcessGroup: false)
    defer { attributes.destroy() }
    var flags: Int16 = 0
    try checkSpawnCall(
      posix_spawnattr_getflags(&attributes.raw, &flags), "posix_spawnattr_getflags")
    try checkSpawnCall(
      posix_spawnattr_setflags(&attributes.raw, flags | Int16(POSIX_SPAWN_SETSID)),
      "posix_spawnattr_setflags")
    var processID: pid_t = 0
    let code = argv.withUnsafePointer { argvPointer in
      envp.withUnsafePointer { envPointer in
        posix_spawn(
          &processID, parameters.path, &actions.raw, &attributes.raw, argvPointer, envPointer)
      }
    }
    guard code == 0 else { throw .spawnFailed(errno: code) }
    reaper.watch(processID)
    return processID
  } // End of func spawn(_:)
} // End of struct DetachedTerminalProcessSpawner

/// Reaps the programs `DetachedTerminalProcessSpawner` started, whenever each exits (a dispatch
/// process source per child, on one serial queue), without ever waiting on one in a caller or
/// signalling it. Its state is touched only on its queue.
///
/// The exit event can come before the child can be waited for (XNU posts `NOTE_EXIT` before it
/// makes the process a zombie), so the nonblocking wait may answer 0 at first. The child then
/// stays pending and is waited for again after 1, 2, 4, … ms, never more than
/// `maximumRetryDelayMilliseconds` apart, until the wait answers its pid (reaped) or a failure
/// other than `EINTR` (`ECHILD`: nothing left to reap; `EINTR` is waited again at once). Only
/// then is its watch dropped.
final class DetachedChildReaper: @unchecked Sendable {
  /// One nonblocking wait's answer: `waitpid`'s return value, and `errno` when it is -1.
  struct WaitAnswer: Sendable, Hashable {
    /// `waitpid`'s return value: the pid (reaped), 0 (not waitable yet) or -1 (failed).
    let result: pid_t
    /// `errno` when `result` is -1, else 0.
    let error: Int32
  }

  /// A child not reaped yet. Queue only.
  private struct Pending {
    /// Its exit source.
    let source: any DispatchSourceProcess
    /// How many waits answered 0 so far.
    var notYetCount = 0
    /// Whether a later wait is scheduled.
    var retryScheduled = false
  }

  /// The reaper every spawner shares.
  static let shared = DetachedChildReaper(wait: DetachedChildReaper.waitWithoutBlocking)
  /// The longest pause between two waits for one child, in milliseconds.
  static let maximumRetryDelayMilliseconds = 1000

  /// The queue every source and every reap runs on.
  private let queue = DispatchQueue(label: "muxFinder.terminal-child-reaper")
  /// One nonblocking wait for a child (`waitWithoutBlocking`; a seam for tests).
  private let wait: @Sendable (pid_t) -> WaitAnswer
  /// The children not reaped yet, by process id. Queue only.
  private var pending: [pid_t: Pending] = [:]

  /// A reaper that waits for its children with `wait`.
  init(wait: @escaping @Sendable (pid_t) -> WaitAnswer) {
    self.wait = wait
  }

  /// One `waitpid(processID, WNOHANG)`, its status discarded.
  static func waitWithoutBlocking(_ processID: pid_t) -> WaitAnswer {
    var status: Int32 = 0
    let result = waitpid(processID, &status, WNOHANG)
    return WaitAnswer(result: result, error: result == -1 ? errno : 0)
  }

  /// The pause before the next wait once `notYetCount` waits answered 0: 1, 2, 4, … ms, at most
  /// `maximumRetryDelayMilliseconds`.
  static func retryDelayMilliseconds(afterNotYet notYetCount: Int) -> Int {
    min(1 << min(max(notYetCount - 1, 0), 10), maximumRetryDelayMilliseconds)
  }

  /// Watches `processID` (a child of this process) and reaps it once it exited, also when it
  /// exited before the watch began.
  func watch(_ processID: pid_t) {
    queue.async { [self] in
      let source = DispatchSource.makeProcessSource(
        identifier: processID, eventMask: .exit, queue: queue)
      source.setEventHandler { [self] in reap(processID) }
      pending[processID] = Pending(source: source)
      source.resume()
      // An exit before the source was registered has no event.
      if StreamingProcess.hasExited(processID) { reap(processID) }
    }
  } // End of func watch(_:)

  /// Waits for `processID` without blocking. Reaped, or nothing left to reap: stops watching
  /// it. Not waitable yet (0): keeps it pending and schedules the next wait, unless one is
  /// scheduled already. Queue only.
  private func reap(_ processID: pid_t) {
    guard var entry = pending[processID], !entry.retryScheduled else { return }
    var answer = wait(processID)
    while answer.result == -1, answer.error == EINTR { answer = wait(processID) }
    if answer.result == 0 {
      entry.notYetCount += 1
      entry.retryScheduled = true
      pending[processID] = entry
      let delay = Self.retryDelayMilliseconds(afterNotYet: entry.notYetCount)
      queue.asyncAfter(deadline: .now() + .milliseconds(delay)) { [self] in
        pending[processID]?.retryScheduled = false
        reap(processID)
      }
      return
    }
    // Its pid (reaped), or a failure retrying cannot mend (`ECHILD`: nothing left to reap).
    pending.removeValue(forKey: processID)?.source.cancel()
  } // End of func reap(_:)

  /// How many children are watched and not reaped yet. For tests.
  var watchedCount: Int { queue.sync { pending.count } }
} // End of class DetachedChildReaper

/// How bringing a running app forward went.
public enum TerminalAppActivation: String, Sendable, Hashable {
  /// A running instance was asked to come forward and agreed.
  case activated
  /// No instance runs: nothing was launched.
  case notRunning
  /// An instance runs, but macOS did not bring it forward.
  case refused
}

/// Brings a running app forward by bundle identifier, with no Apple event and never launching
/// it (a definition's `app` focus, PLAN.md D38, and since Phase I-12c2 the focus of an `.app`
/// handle: a session open in that app on This Mac). A seam: the app uses
/// `RunningApplicationActivator`, tests `FakeTerminalAppActivator`.
@MainActor
public protocol TerminalAppActivating: Sendable {
  /// Asks the running app with `bundleIdentifier` to come forward.
  func activate(bundleIdentifier: String) -> TerminalAppActivation
}

/// The real activator: `NSRunningApplication` (no Apple event), the first instance that has not
/// terminated; when none runs it does nothing, so it never launches the app.
public struct RunningApplicationActivator: TerminalAppActivating {
  /// An activator.
  public init() {}

  /// Activates the first running instance of `bundleIdentifier`, if any.
  public func activate(bundleIdentifier: String) -> TerminalAppActivation {
    let instances = NSRunningApplication.runningApplications(
      withBundleIdentifier: bundleIdentifier)
    guard let instance = instances.first(where: { !$0.isTerminated }) else { return .notRunning }
    return instance.activate(options: []) ? .activated : .refused
  }

  /// Brings `app` forward on the main actor through `activator`, or a
  /// `RunningApplicationActivator` when it is `nil` (an `.app` handle's focus, Phase I-12c2).
  public static func activate(
    _ app: LocalTerminalApp,
    with activator: (any TerminalAppActivating)?
  ) async -> TerminalAppActivation {
    let bundleIdentifier = app.bundleIdentifier
    return await MainActor.run {
      (activator ?? RunningApplicationActivator()).activate(bundleIdentifier: bundleIdentifier)
    }
  }
} // End of struct RunningApplicationActivator
