import Darwin
import Foundation

/// Where the helper prints its explanation, and how it waits for Return.
public protocol LaunchTerminal: Sendable {
  /// Whether to wait for Return after a failure: only when a person can see the tab.
  var isInteractive: Bool { get }
  /// Writes `text` as is.
  func write(_ text: String)
  /// Returns once the user pressed Return, or the terminal went away.
  func waitForReturn() async
}

/// The helper's real terminal: standard error for text, standard input for Return.
///
/// It is interactive only when standard input is a terminal and `MUXFINDER_LAUNCH_NO_WAIT` is
/// not `1`, so a helper run by tests (stdin not a terminal) or with the variable set never
/// waits.
public struct StandardLaunchTerminal: LaunchTerminal {
  /// Set to `1` to never wait for Return.
  public static let noWaitVariable = "MUXFINDER_LAUNCH_NO_WAIT"

  /// See `LaunchTerminal.isInteractive`.
  public let isInteractive: Bool

  /// Decides interactivity from the helper's standard input and `environment`.
  public init(environment: [String: String]) {
    isInteractive = isatty(STDIN_FILENO) == 1 && environment[Self.noWaitVariable] != "1"
  }

  /// Writes `text` to standard error, retrying on `EINTR` and giving up on other errors.
  public func write(_ text: String) {
    var bytes = Array(text.utf8)[...]
    while !bytes.isEmpty {
      let count = bytes.withUnsafeBytes { Darwin.write(STDERR_FILENO, $0.baseAddress, $0.count) }
      if count > 0 {
        bytes = bytes.dropFirst(count)
      } else if count < 0, errno == EINTR {
        continue
      } else {
        return
      }
    } // End of loop over writes
  } // End of func write(_:)

  /// Restores the default SIGHUP, SIGINT and SIGTERM dispositions (the helper ignores them
  /// until its result is written, so now Ctrl-C or closing the tab ends the wait), discards
  /// input typed earlier, then reads standard input on a dedicated thread until a line ends
  /// (Return sends `\r` in raw mode, `\n` in canonical mode), end of file or an error.
  public func waitForReturn() async {
    for signalNumber in TerminalChildRunner.forwardedSignalNumbers {
      signal(signalNumber, SIG_DFL)
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      let thread = Thread {
        tcflush(STDIN_FILENO, TCIFLUSH)
        var byte: UInt8 = 0
        while true {
          let count = read(STDIN_FILENO, &byte, 1)
          if count == 1, byte != 0x0A, byte != 0x0D { continue }
          if count < 0, errno == EINTR { continue }
          break
        }
        continuation.resume()
      }
      thread.name = "cc.carpio.muxfinder.launch-wait"
      thread.start()
    }
  } // End of func waitForReturn()
}

/// `muxfinder-launch attach <launch id>`: the helper iTerm2 runs in a launch tab (PLAN.md D2,
/// D14).
///
/// It takes (reads and deletes) the request and runs two children (PLAN.md D14):
/// 1. the **check**, `LaunchGuard` with piped output, its own process group and a hard
///    deadline (`checkTimeout`); its stderr (tmux's sanitized error line) is copied to the tab
///    as printable ASCII;
/// 2. on success, the **attach**, `<tmux> -u -CC attach-session -t <id>` spawned directly
///    from the path the check printed, on the tab's own terminal, waited for until tmux exits.
///
/// Then it writes the `LaunchResult` and exits with `LaunchResult.exitStatus`. On failure it
/// prints `LaunchFailure.explanation` and, when the terminal is interactive and was not hung
/// up, waits for Return so the tab shows why. A signal before tmux attaches (the tab closed
/// during the check) ends the launch as `interrupted` without attaching.
///
/// Environment variables (development and tests; production sets none):
/// - `MUXFINDER_LAUNCH_DIRECTORY`: an absolute path used as the launch directory instead of
///   `~/Library/Application Support/muxFinder/launch`. A relative or empty value is refused as
///   `launchDirectoryUnusable`.
/// - `MUXFINDER_LAUNCH_TEST_MODE=1`: write an argv digest (`LaunchArgvDigest`); the
///   `test-mode` marker file in the launch directory does the same.
/// - `MUXFINDER_LAUNCH_NO_WAIT=1`: never wait for Return (`StandardLaunchTerminal`).
///
/// Diagnostics record failure kinds, exit statuses and counts only: never paths, names,
/// command lines or terminal content.
public struct LaunchHelper: Sendable {
  /// What the arguments asked for.
  enum Command: Equatable {
    /// `help`, `-h` or `--help`.
    case help
    /// `attach <launch id>`.
    case attach(LaunchToken)
  }

  /// Overrides the launch directory (absolute path).
  public static let directoryVariable = "MUXFINDER_LAUNCH_DIRECTORY"
  /// Set to `1` to turn on test mode.
  public static let testModeVariable = "MUXFINDER_LAUNCH_TEST_MODE"
  /// Prefix of the helper's own variables, removed from the child's environment.
  static let ownVariablePrefix = "MUXFINDER_LAUNCH_"
  /// The usage line.
  public static let usage = "usage: muxfinder-launch attach <launch id>"

  /// The launch files, or `nil` when the directory override is unusable.
  public var store: LaunchStore?
  /// The helper's environment; the child's is derived from it.
  public var environment: [String: String]
  /// Runs the check and the attach.
  public var childRunner: any LaunchChildRunner
  /// Where explanations go.
  public var terminal: any LaunchTerminal
  /// The diagnostics log.
  public var log: DiagnosticsLog
  /// The helper's process id, recorded in results and digests.
  public var processID: Int32
  /// The clock for timestamps.
  public var now: @Sendable () -> Date
  /// The check's hard deadline (`LaunchGuard.defaultTimeout` in production).
  public var checkTimeout: Duration

  /// Creates a helper from its parts. Tests pass fakes.
  public init(
    store: LaunchStore?,
    environment: [String: String],
    childRunner: any LaunchChildRunner,
    terminal: any LaunchTerminal,
    log: DiagnosticsLog,
    processID: Int32,
    now: @escaping @Sendable () -> Date = { Date() },
    checkTimeout: Duration = LaunchGuard.defaultTimeout
  ) {
    self.store = store
    self.environment = environment
    self.childRunner = childRunner
    self.terminal = terminal
    self.log = log
    self.processID = processID
    self.now = now
    self.checkTimeout = checkTimeout
  } // End of init(store:environment:childRunner:terminal:log:processID:now:checkTimeout:)

  /// The production helper: the store from `store(for:)`, a `TerminalChildRunner` whose control
  /// receives this process's SIGHUP, SIGINT and SIGTERM from now on
  /// (`TerminalChildControl.watchTerminalSignals()`), the real terminal and a diagnostics log
  /// mirrored to the unified log. Call it once, in the helper process, after ignoring those
  /// signals.
  public static func standard(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) -> LaunchHelper {
    let control = TerminalChildControl()
    control.watchTerminalSignals()
    return LaunchHelper(
      store: store(for: environment),
      environment: environment,
      childRunner: TerminalChildRunner(control: control),
      terminal: StandardLaunchTerminal(environment: environment),
      log: DiagnosticsLog(),
      processID: getpid()
    )
  } // End of func standard(environment:)

  /// The launch store for `environment`: the override in `MUXFINDER_LAUNCH_DIRECTORY` if set
  /// (`nil` when it is not absolute), otherwise the standard location.
  public static func store(
    for environment: [String: String],
    now: @escaping @Sendable () -> Date = { Date() }
  ) -> LaunchStore? {
    guard let override = environment[directoryVariable] else { return LaunchStore(now: now) }
    guard override.hasPrefix("/") else { return nil }
    return LaunchStore(directory: URL(fileURLWithPath: override, isDirectory: true), now: now)
  }

  /// Parses argv (argv[0] first). Returns `nil` for anything but `help` or exactly
  /// `attach <canonical launch id>`.
  static func parse(_ argv: [[UInt8]]) -> Command? {
    let words = argv.dropFirst().map { String(decoding: $0, as: UTF8.self) }
    if words.count == 1, ["help", "-h", "--help"].contains(words[0]) { return .help }
    guard words.count == 2, words[0] == "attach", let id = LaunchToken(words[1]) else {
      return nil
    }
    return .attach(id)
  }

  /// Runs the helper for `arguments` (argv[0] first) and returns its exit status.
  public func run(arguments: [String]) async -> Int32 {
    await run(argv: arguments.map { Array($0.utf8) })
  }

  /// Runs the helper for the raw `argv` (argv[0] first) and returns its exit status.
  public func run(argv: [[UInt8]]) async -> Int32 {
    let startedAt = now()
    if isTestMode { await recordArgvDigest(argv, at: startedAt) }
    switch Self.parse(argv) {
    case .help:
      terminal.write(Self.usage + "\n")
      return LaunchExitStatus.success
    case .attach(let id):
      return await attach(id, startedAt: startedAt)
    case nil:
      await log.record(
        .launch,
        outcome: .failure,
        detail: "Usage error (\(max(0, argv.count - 1)) arguments)."
      )
      terminal.write(Self.usage + "\n")
      await explain(.usage, terminalHungUp: false)
      return LaunchFailure.usage.exitStatus
    }
  } // End of func run(argv:)

  /// Whether test mode is on (the environment variable or the marker file).
  var isTestMode: Bool {
    environment[Self.testModeVariable] == "1" || (store?.testModeMarkerExists() ?? false)
  }

  /// Writes the argv digest; failures are only logged.
  func recordArgvDigest(_ argv: [[UInt8]], at time: Date) async {
    guard let store else { return }
    let digest = LaunchArgvDigest(argv: argv, helperPID: processID, recordedAt: time)
    do throws(LaunchStoreError) {
      try store.writeArgvDigest(digest)
      await log.record(
        .launch,
        outcome: .info,
        detail: "Argv digest written (\(digest.argumentCount) arguments)."
      )
    } catch {
      await log.record(.launch, outcome: .failure, detail: "Argv digest not written: \(error)")
    }
  } // End of func recordArgvDigest(_:at:)

  /// What the helper knows about its children when it finishes.
  struct ChildRecord {
    /// When the first child (the check) started.
    var startedAt: Date?
    /// How the last child that ran ended: the check after a check failure, tmux after an
    /// attach.
    var termination: ProcessResult.Termination?
    /// Whether a SIGHUP arrived, so nobody can see the tab any more.
    var terminalHungUp = false
  }

  /// What the check decided.
  enum CheckVerdict: Equatable {
    /// Attach with the tmux at this path.
    case attach(tmuxPath: String)
    /// Do not attach.
    case failed(LaunchFailure)
  }

  /// Takes the request for `id`, runs the check and the attach, and finishes.
  func attach(_ id: LaunchToken, startedAt: Date) async -> Int32 {
    guard let store else {
      return await finish(
        id,
        request: nil,
        failure: .launchDirectoryUnusable,
        child: ChildRecord(),
        startedAt: startedAt,
        resultStore: nil
      )
    }
    let request: LaunchRequest
    do throws(LaunchStoreError) {
      request = try store.takeRequest(id)
    } catch {
      let failure = error.launchFailure
      await log.record(.launch, outcome: .failure, detail: "Request refused: \(error)")
      return await finish(
        id,
        request: nil,
        failure: failure,
        child: ChildRecord(),
        startedAt: startedAt,
        resultStore: failure == .launchDirectoryUnusable ? nil : store
      )
    }
    _ = try? store.sweep()
    var child = ChildRecord(startedAt: now())
    let tmuxPath: String
    switch await check(request, child: &child) {
    case .failed(let failure):
      return await finish(
        id,
        request: request,
        failure: failure,
        child: child,
        startedAt: startedAt,
        resultStore: store
      )
    case .attach(let path):
      tmuxPath = path
    }
    let outcome: LaunchChildOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.run(
        executable: tmuxPath,
        arguments: LaunchGuard.attachArguments(for: request),
        environment: childEnvironment
      )
    } catch {
      return await finish(
        id,
        request: request,
        failure: .spawnFailed(errno: Self.errorNumber(of: error)),
        child: child,
        startedAt: startedAt,
        resultStore: store
      )
    }
    child.termination = outcome.termination
    child.terminalHungUp = outcome.terminalHungUp
    return await finish(
      id,
      request: request,
      failure: LaunchFailure.from(outcome.termination, host: request.host),
      child: child,
      startedAt: startedAt,
      resultStore: store
    )
  } // End of func attach(_:startedAt:)

  /// Runs the check for `request` and returns the tmux path to attach with, or the failure.
  /// Records the check's termination and any hang-up in `child`, and copies the check's stderr
  /// to the terminal.
  func check(
    _ request: LaunchRequest,
    child: inout ChildRecord
  ) async -> CheckVerdict {
    let outcome: LaunchCheckOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.runCheck(
        LaunchGuard.checkRequest(
          for: request,
          environment: childEnvironment,
          timeout: checkTimeout
        )
      )
    } catch {
      return .failed(.spawnFailed(errno: Self.errorNumber(of: error)))
    }
    let result: ProcessResult
    switch outcome {
    case .interrupted(let signals):
      child.terminalHungUp = outcome.terminalHungUp
      return .failed(.interrupted(signals.first ?? SIGTERM))
    case .finished(let finished):
      result = finished
    }
    child.termination = result.termination
    let message = Self.printableText(result.standardError)
    if !message.isEmpty { terminal.write(message) }
    if let failure = LaunchFailure.fromCheck(result.termination, timedOut: result.timedOut) {
      return .failed(failure)
    }
    guard
      let path = LaunchGuard.tmuxPath(fromCheckOutput: result.standardOutput, request: request)
    else {
      await log.record(.launch, outcome: .failure, detail: "The check printed no usable tmux path.")
      return .failed(.tmuxCheckFailed)
    }
    return .attach(tmuxPath: path)
  } // End of func check(_:child:)

  /// `data` as text for the terminal: printable ASCII and line feeds only (anything else
  /// becomes `?`), at most `LaunchGuard.outputLimit` bytes, ending with a line feed when not
  /// empty.
  static func printableText(_ data: Data) -> String {
    var bytes = data.prefix(LaunchGuard.outputLimit).map { byte -> UInt8 in
      byte == 0x0A || (0x20...0x7E).contains(byte) ? byte : 0x3F
    }
    if let last = bytes.last, last != 0x0A { bytes.append(0x0A) }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// The children's environment: the helper's own minus `TMUX`, `TMUX_PANE` and the
  /// `MUXFINDER_LAUNCH_*` variables, with the Homebrew directories on `PATH`.
  var childEnvironment: [String: String] {
    DiscoveryProbe.localEnvironment(base: environment).filter {
      !$0.key.hasPrefix(Self.ownVariablePrefix)
    }
  }

  /// Writes the result (when `resultStore` is set), logs, explains a failure and returns the
  /// exit status.
  func finish(
    _ id: LaunchToken,
    request: LaunchRequest?,
    failure: LaunchFailure?,
    child: ChildRecord,
    startedAt: Date,
    resultStore: LaunchStore?
  ) async -> Int32 {
    let result = LaunchResult(
      id: id,
      helperPID: processID,
      startedAt: startedAt,
      childStartedAt: child.startedAt,
      endedAt: now(),
      childTermination: child.termination,
      failure: failure
    )
    let hostID = request?.hostID.uuidString
    if let resultStore {
      do throws(LaunchStoreError) {
        try resultStore.writeResult(result)
      } catch {
        await log.record(
          .launch,
          outcome: .failure,
          hostID: hostID,
          detail: "Result not written: \(error)"
        )
      }
    }
    let durationMs = Int(result.endedAt.timeIntervalSince(startedAt) * 1000)
    if let failure {
      await log.record(
        .launch,
        outcome: .failure,
        hostID: hostID,
        durationMs: durationMs,
        detail: "Launch failed: \(failure.kind), exit status \(result.exitStatus)."
      )
      await explain(failure, terminalHungUp: child.terminalHungUp)
    } else {
      await log.record(
        .launch,
        outcome: .success,
        hostID: hostID,
        durationMs: durationMs,
        detail: "tmux ended normally."
      )
    }
    return result.exitStatus
  } // End of func finish(_:request:failure:child:startedAt:resultStore:)

  /// Prints the explanation and waits for Return when someone can see it.
  func explain(_ failure: LaunchFailure, terminalHungUp: Bool) async {
    terminal.write("\nmuxFinder: \(failure.explanation)\n")
    guard terminal.isInteractive, !terminalHungUp else { return }
    terminal.write("\nPress Return to close.")
    await terminal.waitForReturn()
    terminal.write("\n")
  }

  /// The errno behind a spawn failure (`EINVAL` for a request the runner refused).
  static func errorNumber(of error: ProcessRunnerError) -> Int32 {
    switch error {
    case .spawnFailed(let code), .systemCallFailed(_, let code): return code
    case .executableNotAbsolute, .argumentContainsNUL, .invalidEnvironmentVariable: return EINVAL
    }
  }
}
