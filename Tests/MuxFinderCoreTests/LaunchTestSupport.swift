import Darwin
import Foundation
import os

@testable import MuxFinderCore

/// A fake `tmux` for the guard and helper tests, driven by environment variables:
///
/// - `-V` answers `tmux 9.9-fake`.
/// - `-u display-message -p -t <id> <format>` prints `MUXFINDER_FAKE_IDENTITY` and exits 0,
///   or, when `MUXFINDER_FAKE_DISPLAY_FAIL` is set, prints it to stderr and exits 1. It exits
///   96 if the format is not the guard's. With `MUXFINDER_FAKE_DISPLAY_STALL` set it hangs
///   instead, like a stuck server: it ignores HUP, INT and TERM, starts a background
///   `sleep 30` (which inherits that), writes `<own pid> <sleep pid> <pgid> <pgid leader's
///   parent>` to `$MUXFINDER_FAKE_DIR/stall` and waits; only SIGKILL ends it early.
/// - `-u -CC attach-session -t <id>` writes `<id> <pgid> <ppid>` to `$MUXFINDER_FAKE_DIR/attach`;
///   `-u -CC attach-session -d -t <id>` (a move here) also creates
///   `$MUXFINDER_FAKE_DIR/detach-others` first, so a test can tell the two apart.
///   Then, with `MUXFINDER_FAKE_ATTACH=wait`, it traps TERM (exit 43) and HUP (exit 44),
///   creates `$MUXFINDER_FAKE_DIR/ready` and waits (at most 30 s, then exit 45). Otherwise it
///   reads one line from stdin, prints `stdin:<line>` to stdout and `stderr-ok` to stderr, and
///   exits with `MUXFINDER_FAKE_EXIT` (default 0).
///
/// It exits 98 if `TMUX` or `TMUX_PANE` reached it, 99 if `-u` is missing, 97 for anything else.
let fakeLaunchTmuxScript = #"""
  #!/bin/sh
  if [ "$1" = -V ]; then echo "tmux 9.9-fake"; exit 0; fi
  if [ -n "${TMUX-}" ] || [ -n "${TMUX_PANE-}" ]; then echo "TMUX leaked" >&2; exit 98; fi
  if [ "$1" != -u ]; then echo "missing -u" >&2; exit 99; fi
  case "$2:$3:$4" in
    display-message:-p:-t)
      if [ "$6" != '#{session_id}:#{pid}:#{start_time}:#{session_created}' ]; then exit 96; fi
      if [ -n "${MUXFINDER_FAKE_DISPLAY_STALL-}" ]; then
        trap '' HUP INT TERM
        sleep 30 &
        g=$(ps -o pgid= -p $$ | tr -d ' ')
        h=$(ps -o ppid= -p "$g" | tr -d ' ')
        printf '%s %s %s %s\n' "$$" "$!" "$g" "$h" > "$MUXFINDER_FAKE_DIR/stall"
        wait
        exit 95
      fi
      if [ -n "${MUXFINDER_FAKE_DISPLAY_FAIL-}" ]; then
        printf '%s\n' "$MUXFINDER_FAKE_DISPLAY_FAIL" >&2
        exit 1
      fi
      printf '%s\n' "${MUXFINDER_FAKE_IDENTITY-}"
      exit 0 ;;
    -CC:attach-session:-t | -CC:attach-session:-d)
      if [ "$4" = -d ]; then
        if [ "$5" != -t ]; then echo "unexpected call" >&2; exit 97; fi
        : > "$MUXFINDER_FAKE_DIR/detach-others"
        shift
      fi
      printf '%s %s %s\n' "$5" "$(ps -o pgid= -p $$ | tr -d ' ')" "$PPID" > "$MUXFINDER_FAKE_DIR/attach"
      if [ "${MUXFINDER_FAKE_ATTACH-}" = wait ]; then
        trap 'exit 43' TERM
        trap 'exit 44' HUP
        : > "$MUXFINDER_FAKE_DIR/ready"
        i=0
        while [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
        exit 45
      fi
      read -r line
      printf 'stdin:%s\n' "$line"
      echo stderr-ok >&2
      exit "${MUXFINDER_FAKE_EXIT:-0}" ;;
  esac
  echo "unexpected call" >&2
  exit 97
  """#

/// Helpers for the launch tests.
enum LaunchTestSupport {
  /// A fixed request time with whole seconds, so JSON round trips compare equal.
  static let requestTime = Date(timeIntervalSince1970: 1_792_600_000)

  /// A request for `$3` on a synthetic server, on this Mac unless `host` says otherwise.
  static func request(
    id: LaunchToken = LaunchToken(),
    createdAt: Date = requestTime,
    host: LaunchHost = .local,
    tmuxPathOverride: String? = nil,
    sessionID: String = "$3",
    pid: Int32 = 4242,
    startTime: Int64 = 1_792_599_999,
    created: Int64 = 1_792_600_001
  ) -> LaunchRequest {
    LaunchRequest(
      id: id,
      createdAt: createdAt,
      host: host,
      hostID: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!,
      tmuxPathOverride: tmuxPathOverride,
      sessionID: TmuxSessionID(sessionID)!,
      expectedServerPID: pid,
      expectedServerStartTime: startTime,
      expectedSessionCreated: created
    )
  } // End of func request(id:createdAt:host:tmuxPathOverride:sessionID:pid:startTime:created:)

  /// The identity line the fake tmux should print for `request`.
  static func identity(of request: LaunchRequest) -> String {
    "\(request.sessionID):\(request.expectedServerPID):\(request.expectedServerStartTime):"
      + "\(request.expectedSessionCreated)"
  }

  /// A store in a fresh temporary directory (created, 0700), with a clock fixed at `now`.
  static func makeStore(now: Date = requestTime) throws -> (store: LaunchStore, root: URL) {
    let root = try TestSupport.makeTemporaryDirectory()
    let store = LaunchStore(directory: root.appending(path: "launch"), now: { now })
    try store.prepareDirectory()
    return (store, root)
  }

  /// Writes `fakeLaunchTmuxScript` as an executable `tmux` in `directory` and returns its path.
  static func installFakeTmux(in directory: URL) throws -> String {
    let executable = directory.appending(path: "tmux")
    try Data(fakeLaunchTmuxScript.utf8).write(to: executable)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755],
      ofItemAtPath: executable.path(percentEncoded: false)
    )
    return executable.path(percentEncoded: false)
  }

  /// `lstat` of `url`; fails the test if it does not exist.
  static func status(of url: URL) throws -> stat {
    var info = stat()
    guard lstat(url.path(percentEncoded: false), &info) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    return info
  }

  /// The permission bits of `url` (from `lstat`).
  static func permissions(of url: URL) throws -> mode_t {
    try status(of: url).st_mode & 0o7777
  }

  /// Whether anything (even a dangling link) exists at `url`.
  static func exists(_ url: URL) -> Bool {
    var info = stat()
    return lstat(url.path(percentEncoded: false), &info) == 0
  }

  /// The names in `directory`, sorted.
  static func names(in directory: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))
      .sorted()
  }

  /// The stall record the fake tmux writes (`fakeLaunchTmuxScript`): its own pid, its
  /// background sleeper's pid, their process group and the group leader's parent.
  struct StallRecord {
    /// The fake tmux.
    let tmux: pid_t
    /// Its background `sleep 30`.
    let sleeper: pid_t
    /// The check's process group (its leader is the guard shell).
    let group: pid_t
    /// The guard shell's parent, the process that ran the check.
    let checkParent: pid_t

    /// Whether the fake, its sleeper and their whole group are gone.
    var isGone: Bool {
      TestSupport.processIsGone(tmux) && TestSupport.processIsGone(sleeper)
        && TestSupport.processGroupIsGone(group)
    }
  }

  /// The stall record in `directory`, once completely written.
  static func stallRecord(in directory: URL) -> StallRecord? {
    let numbers = TestSupport.processIDs(inFile: "stall", in: directory)
    guard numbers.count == 4 else { return nil }
    return StallRecord(
      tmux: numbers[0],
      sleeper: numbers[1],
      group: numbers[2],
      checkParent: numbers[3]
    )
  } // End of func stallRecord(in:)

  /// Waits (up to 10 s) until everything in `record` is gone and returns whether it is. If not,
  /// the group (still alive, so still the check's) is killed so the test leaves nothing behind.
  static func waitUntilGone(_ record: StallRecord) async -> Bool {
    let gone = await TestSupport.eventually(within: .seconds(10)) { record.isGone }
    if !gone { _ = kill(-record.group, SIGKILL) }
    return gone
  }

  /// An ACL granting the `everyone` group read access.
  static let everyoneReadACL =
    "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:allow:read\n"
  /// An ACL granting the `everyone` group read and search access, inherited by new files and
  /// directories.
  static let everyoneInheritedACL =
    "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:"
    + "allow,file_inherit,directory_inherit:read,execute\n"
  /// A deny-only ACL, like the one macOS puts on home folders.
  static let everyoneDenyDeleteACL =
    "!#acl 1\ngroup:ABCDEFAB-CDEF-ABCD-EFAB-CDEF0000000C:everyone:12:deny:delete\n"

  /// Sets the extended ACL in `text` (`acl_from_text` format) on `url` itself, never on a link
  /// target.
  static func setACL(_ text: String, on url: URL) throws {
    guard let acl = acl_from_text(text) else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EINVAL)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    guard acl_set_link_np(url.path(percentEncoded: false), ACL_TYPE_EXTENDED, acl) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
  } // End of func setACL(_:on:)

  /// How many extended ACL entries `url` itself carries (0 when it has no ACL).
  static func aclEntryCount(of url: URL) throws -> Int {
    guard let acl = acl_get_link_np(url.path(percentEncoded: false), ACL_TYPE_EXTENDED) else {
      if errno == ENOENT { return 0 }
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { acl_free(UnsafeMutableRawPointer(acl)) }
    var entry: acl_entry_t?
    var count = 0
    var which = Int32(ACL_FIRST_ENTRY.rawValue)
    while acl_get_entry(acl, which, &entry) == 0 {
      count += 1
      which = Int32(ACL_NEXT_ENTRY.rawValue)
    }
    return count
  } // End of func aclEntryCount(of:)
}

/// A `LaunchChildRunner` that records its calls and plays canned outcomes for the check and
/// the attach.
final class FakeLaunchChildRunner: LaunchChildRunner {
  /// One recorded attach call.
  struct Call: Sendable, Equatable {
    /// The executable.
    var executable: String
    /// The arguments after argv[0].
    var arguments: [String]
    /// The environment.
    var environment: [String: String]
    /// Whether the child's standard error was to be relayed (the ssh child).
    var relaysStandardError = false
  }

  /// What `run` (the attach) does.
  enum Behavior: Sendable {
    /// End with this termination, after passing on these signals, having written
    /// `standardError` (returned as captured only when the call relays it).
    case termination(ProcessResult.Termination, forwarded: [Int32], standardError: String = "")
    /// Fail to spawn with this error.
    case error(ProcessRunnerError)
  }

  /// What `runCheck` does.
  enum CheckBehavior: Sendable {
    /// Exit with this status, printing `output` on stdout and `errors` on stderr.
    case exits(Int32, output: String = "", errors: String = "")
    /// Be stopped by the deadline (killed by SIGTERM, `timedOut`).
    case timesOut
    /// Be interrupted by these signals.
    case interrupted([Int32])
    /// Fail to spawn with this error.
    case error(ProcessRunnerError)

    /// A check that passes and prints `tmuxPath`.
    static func passes(tmuxPath: String) -> CheckBehavior {
      .exits(0, output: tmuxPath + "\n")
    }
  }

  /// The canned check behavior.
  let check: CheckBehavior
  /// The canned attach behavior.
  let behavior: Behavior
  /// Check requests and attach calls so far.
  private let recorded = OSAllocatedUnfairLock<(checks: [ProcessRequest], calls: [Call])>(
    initialState: ([], [])
  )

  /// Creates a fake.
  init(_ behavior: Behavior, check: CheckBehavior) {
    self.behavior = behavior
    self.check = check
  }

  /// The attach calls so far.
  var calls: [Call] { recorded.withLock { $0.calls } }
  /// The check requests so far.
  var checks: [ProcessRequest] { recorded.withLock { $0.checks } }

  /// Records the check request and plays the check behavior.
  func runCheck(
    _ request: ProcessRequest
  ) async throws(ProcessRunnerError) -> LaunchCheckOutcome {
    recorded.withLock { $0.checks.append(request) }
    switch check {
    case .exits(let status, let output, let errors):
      return .finished(
        ProcessResult(
          processID: 776,
          termination: .exited(status),
          standardOutput: Data(output.utf8),
          standardError: Data(errors.utf8)
        )
      )
    case .timesOut:
      return .finished(
        ProcessResult(processID: 776, termination: .signaled(SIGTERM), timedOut: true)
      )
    case .interrupted(let signals):
      return .interrupted(signals: signals)
    case .error(let error):
      throw error
    }
  } // End of func runCheck(_:)

  /// Records the call and plays the attach behavior.
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    relaysStandardError: Bool
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    recorded.withLock {
      $0.calls.append(
        Call(
          executable: executable, arguments: arguments, environment: environment,
          relaysStandardError: relaysStandardError))
    }
    switch behavior {
    case .termination(let termination, let forwarded, let standardError):
      return LaunchChildOutcome(
        processID: 777,
        termination: termination,
        startedAt: LaunchTestSupport.requestTime,
        endedAt: LaunchTestSupport.requestTime,
        forwardedSignals: forwarded,
        capturedStandardError: relaysStandardError ? Data(standardError.utf8) : Data()
      )
    case .error(let error):
      throw error
    }
  } // End of func run(executable:arguments:environment:relaysStandardError:)
}

/// A `LaunchTerminal` that records what was written, and every wait for Return and hold, in
/// order; both return at once.
final class FakeLaunchTerminal: LaunchTerminal {
  /// One wait or hold, in the order the helper asked for them.
  enum Pause: Equatable {
    /// `waitForReturn()`.
    case waitForReturn
    /// `holdOpen(for:)` with its duration.
    case hold(Duration)
  }

  /// Recorded state.
  private struct State {
    /// Everything written.
    var text = ""
    /// Every wait and hold, in order.
    var pauses: [Pause] = []
    /// Runs at the start of every hold, if set.
    var onHold: (@Sendable () -> Void)?
  }

  /// See `LaunchTerminal.isInteractive`.
  let isInteractive: Bool
  /// The recorded state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Creates a fake terminal.
  init(isInteractive: Bool) {
    self.isInteractive = isInteractive
  }

  /// Everything written so far.
  var text: String { state.withLock { $0.text } }
  /// How many times the helper waited for Return.
  var waits: Int { state.withLock { $0.pauses.filter { $0 == .waitForReturn }.count } }
  /// The durations of the helper's holds, in order.
  var holds: [Duration] {
    state.withLock { state in
      state.pauses.compactMap { pause in
        if case .hold(let duration) = pause { return duration }
        return nil
      }
    }
  }
  /// Every wait and hold, in order.
  var pauses: [Pause] { state.withLock { $0.pauses } }

  /// Runs `body` at the start of every later hold (to look at what exists by then).
  func onHold(_ body: @escaping @Sendable () -> Void) {
    state.withLock { $0.onHold = body }
  }

  /// Records `text`.
  func write(_ text: String) {
    state.withLock { $0.text += text }
  }

  /// Records a wait and returns at once.
  func waitForReturn() async {
    state.withLock { $0.pauses.append(.waitForReturn) }
  }

  /// Records a hold, runs the `onHold` body, and returns at once.
  func holdOpen(for duration: Duration) async {
    let body = state.withLock { state -> (@Sendable () -> Void)? in
      state.pauses.append(.hold(duration))
      return state.onHold
    }
    body?()
  }
} // End of class FakeLaunchTerminal

/// A built `muxfinder-launch` running in a pseudo-terminal, so it is interactive: its stdin is
/// the terminal's slave side, while its stdout and stderr share one pipe that a dedicated
/// thread reads. It leads its own process group, so signals reach the helper alone. The test
/// keeps the master side open (the helper never reads end of file) and types Return through
/// it. `stop()` kills (if needed) and reaps the helper and closes the master.
final class PseudoTerminalHelper: Sendable {
  /// The helper's pid; it stays this process's unreaped child until `reap()` or `stop()`.
  let processID: pid_t
  /// Just before the helper was spawned, so no instant of the helper's own life precedes it.
  let startedAt: ContinuousClock.Instant
  /// The terminal's master side (non-blocking, close-on-exec).
  private let master: Int32

  /// Lock-protected state.
  private struct State: Sendable {
    /// Everything the helper wrote so far.
    var output = Data()
    /// How the helper ended, once reaped.
    var termination: ProcessResult.Termination?
  }

  /// The shared state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// Spawns `helper` with `arguments` (after argv[0]) and exactly `environment`.
  init(helper: URL, arguments: [String], environment: [String: String]) throws {
    let start = ContinuousClock.now
    var master: Int32 = -1
    var slave: Int32 = -1
    guard openpty(&master, &slave, nil, nil, nil) == 0 else {
      throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }
    defer { close(slave) }
    for descriptor in [master, slave] { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }
    _ = fcntl(master, F_SETFL, fcntl(master, F_GETFL) | O_NONBLOCK)
    let output: PipePair
    do {
      output = try PipePair.make()
    } catch {
      close(master)
      throw error
    }
    defer { close(output.writeEnd) }
    let spawned: pid_t
    do {
      spawned = try Self.spawn(
        ProcessRequest(executableURL: helper, arguments: arguments, environment: environment),
        terminal: slave,
        output: output.writeEnd
      )
    } catch {
      close(master)
      close(output.readEnd)
      throw error
    }
    self.master = master
    processID = spawned
    startedAt = start
    let reader = Thread { [state] in
      var buffer = [UInt8](repeating: 0, count: 1024)
      while true {
        let count = read(output.readEnd, &buffer, buffer.count)
        if count < 0, errno == EINTR { continue }
        guard count > 0 else { break }
        let chunk = Data(buffer.prefix(count))
        state.withLock { $0.output.append(chunk) }
      }
      close(output.readEnd)
    }
    reader.name = "cc.carpio.muxfinder.test-pty-output"
    reader.start()
  } // End of init(helper:arguments:environment:)

  /// Spawns the request with stdin on `terminal`, stdout and stderr on `output`, in a new
  /// process group and with default signal dispositions.
  private static func spawn(
    _ request: ProcessRequest,
    terminal: Int32,
    output: Int32
  ) throws -> pid_t {
    let parameters = try ProcessSupervisor.launchParameters(for: request)
    let argv = try CStringArray(parameters.argv)
    let envp = try CStringArray(parameters.environment)
    var actions = try SpawnFileActions()
    defer { actions.destroy() }
    try actions.duplicate(terminal, to: STDIN_FILENO)
    try actions.duplicate(output, to: STDOUT_FILENO)
    try actions.duplicate(output, to: STDERR_FILENO)
    var attributes = try SpawnAttributes()
    defer { attributes.destroy() }
    var processID: pid_t = 0
    let code = argv.withUnsafePointer { argvPointer in
      envp.withUnsafePointer { envPointer in
        posix_spawn(
          &processID, parameters.path, &actions.raw, &attributes.raw, argvPointer, envPointer)
      }
    }
    guard code == 0 else { throw ProcessRunnerError.spawnFailed(errno: code) }
    return processID
  } // End of func spawn(_:terminal:output:)

  /// Everything the helper wrote so far, as text.
  var text: String {
    String(decoding: state.withLock { $0.output }, as: UTF8.self)
  }

  /// Types Return (a carriage return, which the terminal turns into a line end).
  func pressReturn() {
    var byte: UInt8 = 0x0D
    _ = write(master, &byte, 1)
  }

  /// Sends `signalNumber` to the helper alone, unless it was already reaped.
  func send(_ signalNumber: Int32) {
    guard state.withLock({ $0.termination == nil }) else { return }
    _ = kill(processID, signalNumber)
  }

  /// Whether the helper has exited (without reaping it).
  var hasExited: Bool {
    state.withLock { $0.termination != nil } || ProcessSupervisor.hasExited(processID)
  }

  /// Reaps the helper (blocking until it exits) and returns how it ended.
  func reap() -> ProcessResult.Termination? {
    if let termination = state.withLock({ $0.termination }) { return termination }
    guard case .success(let status) = ProcessSupervisor.reap(processID) else { return nil }
    let termination = ProcessSupervisor.termination(fromWaitStatus: status)
    state.withLock { $0.termination = termination }
    return termination
  }

  /// Kills the helper if it still runs, reaps it and closes the master side.
  func stop() {
    if state.withLock({ $0.termination == nil }) {
      if !ProcessSupervisor.hasExited(processID) { _ = kill(processID, SIGKILL) }
      _ = reap()
    }
    close(master)
  }

  /// Repeats `action` every 50 ms until `done` holds or `limit` passes; returns the instant
  /// `done` was first seen to hold, or `nil` on timeout.
  static func repeating(
    _ action: () -> Void,
    until done: () -> Bool,
    within limit: Duration
  ) async -> ContinuousClock.Instant? {
    let deadline = ContinuousClock.now + limit
    while ContinuousClock.now < deadline {
      if done() { return .now }
      action()
      try? await Task.sleep(for: .milliseconds(50))
    }
    return done() ? .now : nil
  } // End of func repeating(_:until:within:)
} // End of class PseudoTerminalHelper
