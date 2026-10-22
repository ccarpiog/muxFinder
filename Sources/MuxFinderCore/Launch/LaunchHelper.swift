import Darwin
import Foundation
import os

/// Where the helper prints its explanation, and how it waits for Return.
///
/// Both waits run while the tab may still be visible, so only a SIGHUP (the tab closed, nobody
/// can see it end) may end the helper during them; a SIGINT (Ctrl-C) or SIGTERM never ends it
/// before its minimum lifetime (PLAN.md D14).
public protocol LaunchTerminal: Sendable {
  /// Whether to wait for Return after a failure, and to hold the tab open until the helper's
  /// minimum lifetime: only when a person can see the tab.
  var isInteractive: Bool { get }
  /// Writes `text` as is.
  func write(_ text: String)
  /// Returns once the user pressed Return, the terminal went away, or a SIGINT (Ctrl-C) or
  /// SIGTERM arrived: those finish the wait like Return, so the hold that follows still keeps
  /// the tab until the minimum lifetime. Closing the tab (SIGHUP) ends the helper at once.
  func waitForReturn() async
  /// Keeps the helper, and so its tab, running for `duration`. Closing the tab (SIGHUP) still
  /// ends it at once; SIGINT (Ctrl-C) and SIGTERM do not end it early.
  func holdOpen(for duration: Duration) async
}

/// Ends one `StandardLaunchTerminal.waitForReturn()` exactly once, whichever comes first: a
/// line end or end of file on standard input, or a finishing signal. It also works when the
/// end comes before the wait's continuation exists.
final class LaunchWaitGate: Sendable {
  /// Where the wait stands.
  private enum State: Sendable {
    /// No continuation yet, nothing ended the wait.
    case open
    /// Waiting with this continuation.
    case armed(CheckedContinuation<Void, Never>)
    /// The wait ended; later ends do nothing.
    case finished
  }

  /// The shared state.
  private let state = OSAllocatedUnfairLock<State>(initialState: .open)

  /// Creates an open gate.
  init() {}

  /// Stores `continuation`, or resumes it at once when the wait already ended. Returns whether
  /// the wait is still going on.
  func arm(_ continuation: CheckedContinuation<Void, Never>) -> Bool {
    let ended = state.withLock { state -> Bool in
      if case .finished = state { return true }
      state = .armed(continuation)
      return false
    }
    if ended { continuation.resume() }
    return !ended
  }

  /// Ends the wait: resumes the stored continuation the first time, does nothing afterwards.
  func finish() {
    let continuation = state.withLock { state -> CheckedContinuation<Void, Never>? in
      defer { state = .finished }
      if case .armed(let continuation) = state { return continuation }
      return nil
    }
    continuation?.resume()
  }
}

/// The helper's real terminal: standard error for text, standard input for Return.
///
/// It is interactive only when standard input is a terminal and `MUXFINDER_LAUNCH_NO_WAIT` is
/// not `1`, so a helper run by tests (stdin not a terminal) or with the variable set never
/// waits for Return and never holds its tab open.
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

  /// The signals that finish `waitForReturn()` like Return and never end `holdOpen(for:)`:
  /// Ctrl-C, or a request to stop, while the tab may still be visible.
  static let finishingSignalNumbers: [Int32] = [SIGINT, SIGTERM]

  /// Sets the dispositions for both waits: SIGHUP's default again (the helper ignores it until
  /// its result is written; now closing the tab ends the helper at once, unseen), and SIGINT and
  /// SIGTERM ignored, so neither ends the helper before its minimum lifetime.
  static func setWaitDispositions() {
    signal(SIGHUP, SIG_DFL)
    for signalNumber in finishingSignalNumbers {
      signal(signalNumber, SIG_IGN)
    }
  }

  /// Sets the wait dispositions (`setWaitDispositions()`), then waits for the first of: a line
  /// end (Return sends `\r` in raw mode, `\n` in canonical mode), end of file or an error on
  /// standard input, read on a dedicated thread after discarding input typed earlier; or a
  /// SIGINT or SIGTERM, seen through dispatch signal sources while ignored. The wait returns
  /// exactly once; a read thread still blocked after a signal stays blocked until the process
  /// exits, which the minimum-lifetime hold that follows bounds.
  public func waitForReturn() async {
    Self.setWaitDispositions()
    let gate = LaunchWaitGate()
    let sources = Self.finishingSignalNumbers.map { signalNumber in
      let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
      source.setEventHandler { gate.finish() }
      source.resume()
      return source
    }
    defer {
      for source in sources { source.cancel() }
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      guard gate.arm(continuation) else { return }
      let thread = Thread {
        tcflush(STDIN_FILENO, TCIFLUSH)
        var byte: UInt8 = 0
        while true {
          let count = read(STDIN_FILENO, &byte, 1)
          if count == 1, byte != 0x0A, byte != 0x0D { continue }
          if count < 0, errno == EINTR { continue }
          break
        }
        gate.finish()
      }
      thread.name = "cc.carpio.muxfinder.launch-wait"
      thread.start()
    }
  } // End of func waitForReturn()

  /// Sets the wait dispositions (`setWaitDispositions()`: closing the tab ends the helper at
  /// once, SIGINT and SIGTERM do not), then sleeps for `duration`.
  public func holdOpen(for duration: Duration) async {
    Self.setWaitDispositions()
    try? await Task.sleep(for: duration)
  }
}

/// `muxfinder-launch attach <launch id>` and `muxfinder-launch ssh-setup <launch id>`: the
/// helper iTerm2 runs in a launch tab (PLAN.md D2, D14, D24).
///
/// Each mode takes (reads and deletes) only a request of its own kind (`LaunchRequestKind`); a
/// well-formed request of the other kind is refused as `requestUnreadable` (72) and runs
/// nothing.
///
/// `ssh-setup` ("Set up SSH in iTerm2…", PLAN.md D24) runs one child on the tab's terminal,
/// plain interactive `/usr/bin/ssh -- <destination>` (`SSHSetup`), its standard error relayed
/// so a failure is classified, and then finishes exactly like an attach: the result, the
/// explanation (worded for ssh), the wait for Return and the hold below.
///
/// `attach` takes the request. For a local host it runs two children (PLAN.md D14):
/// 1. the **check**, `LaunchGuard` with piped output, its own process group and a hard
///    deadline (`checkTimeout`); its stderr (tmux's sanitized error line) is copied to the tab
///    as printable ASCII;
/// 2. on success, the **attach**, `<tmux> -u -CC attach-session -t <id>` spawned directly
///    from the path the check printed, on the tab's own terminal, waited for until tmux exits;
///    `attach-session -d -t <id>` when the request moves the session here (its
///    `detachOtherClients` is `true`, PLAN.md D21), so tmux detaches the session's other
///    clients.
///
/// For an SSH host it runs one child on the tab's terminal (PLAN.md D17):
/// `/usr/bin/ssh -t -o ConnectTimeout=10 -- <destination> <D3 string>` (`RemoteLaunch`),
/// interactive (no `BatchMode`), so a person can answer a password or host-key prompt in the
/// tab. The remote script (`RemoteLaunch.moveHereScript` for a move here, whose tmux gets
/// `-d`) runs the same D4 check and then `exec`s tmux; ssh exits with the
/// guard's codes, tmux's status, or 255 for its own errors, classified from its standard error
/// (relayed to the tab as it arrives).
///
/// Then it writes the `LaunchResult` and exits with `LaunchResult.exitStatus`. On failure it
/// prints `LaunchFailure.explanation` and, when the terminal is interactive and was not hung
/// up, waits for Return so the tab shows why. A signal before tmux attaches (the tab closed
/// during the check) ends the launch as `interrupted` without attaching. Every remote failure
/// (ssh failing fast on authentication or an unreachable host, a guard refusal on the remote
/// host) ends the same way, through the explanation, the wait and the hold below.
///
/// On that same interactive, not hung-up terminal it never exits before it is
/// `minimumLifetime` old, whatever the outcome: iTerm2 blocks its whole API behind a modal
/// warning when a session ends within seconds of starting (PLAN.md D14, *Verified facts*), and
/// tmux can end right after attaching (an early detach, a killed session), Return can be
/// pressed at once, or Ctrl-C typed (SIGINT and SIGTERM finish the wait like Return and never
/// end the hold; only SIGHUP, a closed tab, ends the helper early). The result is written
/// before that hold, so nobody waits for it.
///
/// Environment variables (development and tests; production sets none):
/// - `MUXFINDER_LAUNCH_DIRECTORY`: an absolute path used as the launch directory instead of
///   `~/Library/Application Support/muxFinder/launch`. A relative or empty value is refused as
///   `launchDirectoryUnusable`.
/// - `MUXFINDER_LAUNCH_TEST_MODE=1`: write an argv digest (`LaunchArgvDigest`, written again
///   with the attach child, or the ssh setup's ssh child, just before it starts) and honor a
///   request's `testLaunchDelaySeconds` (`testLaunchDelay(_:child:)`); the `test-mode` marker
///   file in the launch directory does the same. Outside test mode that field is ignored.
/// - `MUXFINDER_LAUNCH_NO_WAIT=1`: never wait for Return nor hold the tab open
///   (`StandardLaunchTerminal`).
/// - `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS`: the minimum lifetime in milliseconds (1 to 7
///   decimal digits; anything else keeps `defaultMinimumLifetime`), so tests can run the
///   binary in a pseudo-terminal without waiting 10 s.
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
    /// `ssh-setup <launch id>` (PLAN.md D24).
    case sshSetup(LaunchToken)
  }

  /// What a launch is for, which decides the wording of its explanation.
  enum Purpose: Equatable {
    /// Attaching (or moving here) a session on this host.
    case attach(LaunchHost)
    /// "Set up SSH in iTerm2…": plain interactive ssh (PLAN.md D24).
    case sshSetup
  }

  /// Overrides the launch directory (absolute path).
  public static let directoryVariable = "MUXFINDER_LAUNCH_DIRECTORY"
  /// Set to `1` to turn on test mode.
  public static let testModeVariable = "MUXFINDER_LAUNCH_TEST_MODE"
  /// Prefix of the helper's own variables, removed from the child's environment.
  static let ownVariablePrefix = "MUXFINDER_LAUNCH_"
  /// The usage line.
  public static let usage = "usage: muxfinder-launch attach|ssh-setup <launch id>"
  /// The production `minimumLifetime`. iTerm2 3.7.6 warns about sessions that end within 3 s of
  /// starting (its `shortLivedSessionDuration` default); 10 s matches the attach coordinator's
  /// minimum launch tab age (PLAN.md D15).
  public static let defaultMinimumLifetime: Duration = .seconds(10)
  /// Overrides the minimum lifetime with a whole number of milliseconds (tests only).
  public static let minimumLifetimeVariable = "MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS"

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
  /// How old the helper must be, counted from the start of `run`, before it exits while someone
  /// can see its tab (`defaultMinimumLifetime` in production).
  public var minimumLifetime: Duration

  /// Creates a helper from its parts. Tests pass fakes.
  public init(
    store: LaunchStore?,
    environment: [String: String],
    childRunner: any LaunchChildRunner,
    terminal: any LaunchTerminal,
    log: DiagnosticsLog,
    processID: Int32,
    now: @escaping @Sendable () -> Date = { Date() },
    checkTimeout: Duration = LaunchGuard.defaultTimeout,
    minimumLifetime: Duration = LaunchHelper.defaultMinimumLifetime
  ) {
    self.store = store
    self.environment = environment
    self.childRunner = childRunner
    self.terminal = terminal
    self.log = log
    self.processID = processID
    self.now = now
    self.checkTimeout = checkTimeout
    self.minimumLifetime = minimumLifetime
  } // End of init(store:environment:childRunner:terminal:log:processID:now:checkTimeout:…)

  /// The production helper: the store from `store(for:)`, a `TerminalChildRunner` whose control
  /// receives this process's SIGHUP, SIGINT and SIGTERM from now on
  /// (`TerminalChildControl.watchTerminalSignals()`), the real terminal, a diagnostics log
  /// mirrored to the unified log and the minimum lifetime from `minimumLifetime(for:)`. Call it
  /// once, in the helper process, after ignoring those signals.
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
      processID: getpid(),
      minimumLifetime: minimumLifetime(for: environment)
    )
  } // End of func standard(environment:)

  /// The minimum lifetime for `environment`: `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` when it is
  /// 1 to 7 decimal digits (milliseconds), otherwise `defaultMinimumLifetime`.
  static func minimumLifetime(for environment: [String: String]) -> Duration {
    guard let text = environment[minimumLifetimeVariable],
      (1...7).contains(text.utf8.count),
      text.utf8.allSatisfy({ (0x30...0x39).contains($0) }),
      let milliseconds = Int(text)
    else { return defaultMinimumLifetime }
    return .milliseconds(milliseconds)
  }

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
  /// `attach <canonical launch id>` or `ssh-setup <canonical launch id>`.
  static func parse(_ argv: [[UInt8]]) -> Command? {
    let words = argv.dropFirst().map { String(decoding: $0, as: UTF8.self) }
    if words.count == 1, ["help", "-h", "--help"].contains(words[0]) { return .help }
    guard words.count == 2, let id = LaunchToken(words[1]) else { return nil }
    switch words[0] {
    case LaunchRequestKind.attach.helperMode: return .attach(id)
    case LaunchRequestKind.sshSetup.helperMode: return .sshSetup(id)
    default: return nil
    }
  } // End of static func parse(_:)

  /// Runs the helper for `arguments` (argv[0] first) and returns its exit status.
  public func run(arguments: [String]) async -> Int32 {
    await run(argv: arguments.map { Array($0.utf8) })
  }

  /// Runs the helper for the raw `argv` (argv[0] first) and returns its exit status.
  public func run(argv: [[UInt8]]) async -> Int32 {
    let startedAt = now()
    let digest = isTestMode ? await recordArgvDigest(argv, at: startedAt) : nil
    switch Self.parse(argv) {
    case .help:
      terminal.write(Self.usage + "\n")
      return LaunchExitStatus.success
    case .attach(let id):
      return await attach(id, startedAt: startedAt, argvDigest: digest)
    case .sshSetup(let id):
      return await sshSetup(id, startedAt: startedAt, argvDigest: digest)
    case nil:
      await log.record(
        .launch,
        outcome: .failure,
        detail: "Usage error (\(max(0, argv.count - 1)) arguments)."
      )
      terminal.write(Self.usage + "\n")
      await explain(.usage, purpose: .attach(.local), terminalHungUp: false)
      await holdUntilMinimumLifetime(since: startedAt, terminalHungUp: false)
      return LaunchFailure.usage.exitStatus
    }
  } // End of func run(argv:)

  /// Whether test mode is on (the environment variable or the marker file).
  var isTestMode: Bool {
    environment[Self.testModeVariable] == "1" || (store?.testModeMarkerExists() ?? false)
  }

  /// Writes the argv digest and returns it (`nil` without a store); failures are only logged.
  func recordArgvDigest(_ argv: [[UInt8]], at time: Date) async -> LaunchArgvDigest? {
    guard let store else { return nil }
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
    return digest
  } // End of func recordArgvDigest(_:at:)

  /// Writes `digest` again with the attach child (`executable` and `arguments`, and whether it
  /// detaches the session's other clients), just before that child starts (test mode only, so
  /// a check can tell a move here from a normal attach, PLAN.md D21); failures are only logged.
  func recordAttachChild(
    in digest: LaunchArgvDigest,
    executable: String,
    arguments: [String],
    detachesOtherClients: Bool
  ) async {
    guard let store else { return }
    var updated = digest
    updated.attachChild = LaunchArgvDigest.AttachChild(
      executable: executable, arguments: arguments, detachesOtherClients: detachesOtherClients)
    do throws(LaunchStoreError) {
      try store.writeArgvDigest(updated)
      await log.record(
        .launch, outcome: .info,
        detail: "Argv digest written with the attach child (\(arguments.count + 1) arguments, "
          + "detaching other clients: \(detachesOtherClients)).")
    } catch {
      await log.record(.launch, outcome: .failure, detail: "Argv digest not written: \(error)")
    }
  } // End of func recordAttachChild(in:executable:arguments:detachesOtherClients:)

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

  /// Takes the request for `id`, runs the check and the attach (or, for an SSH host, the ssh
  /// child that does both on the remote host), and finishes. The attach detaches the session's
  /// other clients (`-d`) only when the request asks for it (a move here, PLAN.md D21). In
  /// test mode, `argvDigest` (the digest already written) is written again with the attach
  /// child just before it starts.
  func attach(
    _ id: LaunchToken,
    startedAt: Date,
    argvDigest: LaunchArgvDigest? = nil
  ) async -> Int32 {
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
    if let seconds = request.testLaunchDelaySeconds, isTestMode,
      let failure = await testLaunchDelay(seconds, child: &child)
    {
      return await finish(
        id,
        request: request,
        failure: failure,
        child: child,
        startedAt: startedAt,
        resultStore: store
      )
    }
    let executable: String
    let arguments: [String]
    switch request.host {
    case .local:
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
        (executable, arguments) = (path, LaunchGuard.attachArguments(for: request))
      }
    case .ssh:
      // `takeRequest` accepted only a valid destination; refuse anything else all the same.
      guard let sshArguments = RemoteLaunch.sshArguments(for: request) else {
        return await finish(
          id,
          request: request,
          failure: .requestUnreadable,
          child: ChildRecord(),
          startedAt: startedAt,
          resultStore: store
        )
      }
      (executable, arguments) = (RemoteLaunch.sshPath, sshArguments)
    }
    if let argvDigest {
      await recordAttachChild(
        in: argvDigest, executable: executable, arguments: arguments,
        detachesOtherClients: request.detachesOtherClients)
    }
    let outcome: LaunchChildOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.run(
        executable: executable,
        arguments: arguments,
        environment: childEnvironment,
        relaysStandardError: request.host.isRemote
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
    let failure = LaunchFailure.from(
      outcome.termination, host: request.host, sshStandardError: outcome.capturedStandardError)
    return await finish(
      id,
      request: request,
      failure: failure,
      child: child,
      startedAt: startedAt,
      resultStore: store
    )
  } // End of func attach(_:startedAt:argvDigest:)

  /// "Set up SSH in iTerm2…" (PLAN.md D24): takes the ssh setup request for `id` (an attach
  /// request is refused as `requestUnreadable`, 72, and runs nothing), then runs plain
  /// interactive `/usr/bin/ssh -- <destination>` on the tab's terminal with its standard error
  /// relayed, and finishes like an attach: the result first, the explanation worded for ssh, the
  /// wait for Return after a failure and the hold until the helper is `minimumLifetime` old, on
  /// every way out. In test mode, `argvDigest` is written again with the ssh child just before
  /// it starts.
  func sshSetup(
    _ id: LaunchToken,
    startedAt: Date,
    argvDigest: LaunchArgvDigest? = nil
  ) async -> Int32 {
    guard let store else {
      return await finish(
        id, hostID: nil, purpose: .sshSetup, failure: .launchDirectoryUnusable,
        child: ChildRecord(), startedAt: startedAt, resultStore: nil)
    }
    let request: SSHSetupRequest
    do throws(LaunchStoreError) {
      request = try store.takeSSHSetupRequest(id)
    } catch {
      let failure = error.launchFailure
      await log.record(.launch, outcome: .failure, detail: "SSH setup request refused: \(error)")
      return await finish(
        id, hostID: nil, purpose: .sshSetup, failure: failure, child: ChildRecord(),
        startedAt: startedAt, resultStore: failure == .launchDirectoryUnusable ? nil : store)
    }
    _ = try? store.sweep()
    // `takeSSHSetupRequest` accepted only a valid destination; refuse anything else all the
    // same, before any process starts.
    guard let arguments = SSHSetup.sshArguments(for: request) else {
      return await finish(
        id, hostID: request.hostID, purpose: .sshSetup, failure: .requestUnreadable,
        child: ChildRecord(), startedAt: startedAt, resultStore: store)
    }
    if let argvDigest {
      await recordAttachChild(
        in: argvDigest, executable: SSHSetup.sshPath, arguments: arguments,
        detachesOtherClients: false)
    }
    var child = ChildRecord(startedAt: now())
    let outcome: LaunchChildOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.run(
        executable: SSHSetup.sshPath,
        arguments: arguments,
        environment: childEnvironment,
        relaysStandardError: true
      )
    } catch {
      return await finish(
        id, hostID: request.hostID, purpose: .sshSetup,
        failure: .spawnFailed(errno: Self.errorNumber(of: error)), child: child,
        startedAt: startedAt, resultStore: store)
    }
    child.termination = outcome.termination
    child.terminalHungUp = outcome.terminalHungUp
    let failure = SSHSetup.failure(
      for: outcome.termination, sshStandardError: outcome.capturedStandardError)
    return await finish(
      id, hostID: request.hostID, purpose: .sshSetup, failure: failure, child: child,
      startedAt: startedAt, resultStore: store)
  } // End of func sshSetup(_:startedAt:argvDigest:)

  /// The test-only launch delay (PLAN.md D14 *Test mode*): in test mode, a request's
  /// `testLaunchDelaySeconds` keeps the helper waiting that long before its first child, with
  /// no check, tmux or ssh running, so the coordinator sees a launch tab that is open with no
  /// connection and no result. The wait is a check-stage child, `/bin/sleep <seconds>`
  /// (`testLaunchDelayRequest(seconds:environment:)`: its own process group, a deadline,
  /// stdin `/dev/null`), so a signal for the helper ends it exactly as it ends a check: the
  /// launch fails as `interrupted(n)` without attaching, and a SIGHUP (the tab closed) marks
  /// the terminal as hung up. Returns that failure, or `nil` once the delay ran out (the launch
  /// then goes on as usual). Callers check test mode first.
  func testLaunchDelay(_ seconds: Int, child: inout ChildRecord) async -> LaunchFailure? {
    terminal.write("muxFinder test mode: waiting \(seconds) s before starting.\n")
    await log.record(.launch, outcome: .info, detail: "Test launch delay (\(seconds) s).")
    let outcome: LaunchCheckOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.runCheck(
        Self.testLaunchDelayRequest(seconds: seconds, environment: childEnvironment))
    } catch {
      return .spawnFailed(errno: Self.errorNumber(of: error))
    }
    guard case .interrupted(let signals) = outcome else { return nil }
    child.terminalHungUp = outcome.terminalHungUp
    return .interrupted(signals.first ?? SIGTERM)
  } // End of func testLaunchDelay(_:child:)

  /// The child that waits out a test launch delay: `/bin/sleep <seconds>` with `environment`
  /// and a deadline 5 s past the delay.
  static func testLaunchDelayRequest(
    seconds: Int,
    environment: [String: String]
  ) -> ProcessRequest {
    ProcessRequest(
      executableURL: URL(fileURLWithPath: "/bin/sleep"),
      arguments: [String(seconds)],
      environment: environment,
      timeout: .seconds(seconds + 5)
    )
  } // End of func testLaunchDelayRequest(seconds:environment:)

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

  /// Finishes an attach of `request` (`nil` when none was taken), worded for its host: see
  /// `finish(_:hostID:purpose:failure:child:startedAt:resultStore:)`.
  func finish(
    _ id: LaunchToken,
    request: LaunchRequest?,
    failure: LaunchFailure?,
    child: ChildRecord,
    startedAt: Date,
    resultStore: LaunchStore?
  ) async -> Int32 {
    await finish(
      id, hostID: request?.hostID, purpose: .attach(request?.host ?? .local), failure: failure,
      child: child, startedAt: startedAt, resultStore: resultStore)
  } // End of func finish(_:request:failure:child:startedAt:resultStore:)

  /// Writes the result (when `resultStore` is set), logs, explains a failure (worded for
  /// `purpose`), holds the tab open until the helper is `minimumLifetime` old, and returns the
  /// exit status. Every way a launch ends goes through here, so the hold is never skipped.
  func finish(
    _ id: LaunchToken,
    hostID configuredHostID: UUID?,
    purpose: Purpose,
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
    let hostID = configuredHostID?.uuidString
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
      await explain(failure, purpose: purpose, terminalHungUp: child.terminalHungUp)
    } else {
      await log.record(
        .launch,
        outcome: .success,
        hostID: hostID,
        durationMs: durationMs,
        detail: purpose == .sshSetup ? "ssh ended normally." : "tmux ended normally."
      )
    }
    await holdUntilMinimumLifetime(since: startedAt, terminalHungUp: child.terminalHungUp)
    return result.exitStatus
  } // End of func finish(_:hostID:purpose:failure:child:startedAt:resultStore:)

  /// Prints the explanation (worded for `purpose`: an attach on its host, or ssh setup) and
  /// waits for Return when someone can see it.
  func explain(_ failure: LaunchFailure, purpose: Purpose, terminalHungUp: Bool) async {
    let text: String
    switch purpose {
    case .attach(let host): text = failure.explanation(for: host)
    case .sshSetup: text = failure.sshSetupExplanation
    }
    terminal.write("\nmuxFinder: \(text)\n")
    guard terminal.isInteractive, !terminalHungUp else { return }
    terminal.write("\nPress Return to close.")
    await terminal.waitForReturn()
    terminal.write("\n")
  } // End of func explain(_:purpose:terminalHungUp:)

  /// When someone can see the tab (an interactive terminal that was not hung up), keeps the
  /// helper running until it is `minimumLifetime` old, counted from `startedAt`, so its tab
  /// never ends inside iTerm2's short-lived-session window. A clock that went backwards counts
  /// as no time passed.
  func holdUntilMinimumLifetime(since startedAt: Date, terminalHungUp: Bool) async {
    guard terminal.isInteractive, !terminalHungUp else { return }
    let elapsed = Duration.seconds(max(0, now().timeIntervalSince(startedAt)))
    let remaining = minimumLifetime - elapsed
    guard remaining > .zero else { return }
    await terminal.holdOpen(for: remaining)
  }

  /// The errno behind a spawn failure (`EINVAL` for a request the runner refused).
  static func errorNumber(of error: ProcessRunnerError) -> Int32 {
    switch error {
    case .spawnFailed(let code), .systemCallFailed(_, let code): return code
    case .executableNotAbsolute, .argumentContainsNUL, .invalidEnvironmentVariable: return EINVAL
    }
  }
}
