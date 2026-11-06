import Darwin
import Foundation
import os

/// `muxfinder-launch attach-plain <launch id>`: what a terminal app other than iTerm2 runs in
/// the window muxFinder opens for a launch (PLAN.md D14, D38; requirements 4 and 5 of
/// `autoclaude/processed/110-other-terminal-apps.md`). Chosen only by its mode word, never from
/// `TERM_PROGRAM`, `TERM` or any other environment.
///
/// It is `attach` with the attach made plain and bound, and everything iTerm2-specific left out:
/// 1. **The request:** it takes only a plain request (`LaunchStore.takePlainRequest(_:)`: the
///    request's `terminal` a definition's id); an iTerm2 request, with `"terminal":"iterm2"` or
///    none, is refused as `requestUnreadable` (72) and runs nothing, as `attach` refuses a plain
///    one.
/// 2. **The children:** on This Mac D14's check (`LaunchGuard`, the same as `attach`'s), then
///    the tmux it printed with `PlainLaunch.localAttachArguments(for:)`: one bound
///    `if-shell -F` that attaches only while the session is exactly the request's (65
///    otherwise), never `-CC`, with `-d` for a move here (`LaunchRequest.detachesOtherClients`).
///    On an SSH host D17's `/usr/bin/ssh -t … -- <destination> <D3 string>` with
///    `PlainLaunch.remoteScript` (`remoteMoveHereScript` for a move here) and the launch id as
///    the token (`PlainLaunch.sshArguments(for:)`). The attach child's standard input is the
///    helper's terminal opened again read-write (`LaunchChildStandardInput.terminalReadWrite`),
///    since tmux draws through it. Exit statuses map to the result kinds as `attach`'s do
///    (`LaunchFailure.from(_:host:sshStandardError:)`: 65 a changed session, 68 a bad token…).
/// 3. **The early report:** right after the attach child starts and before the helper waits on
///    it, `<launch id>.report.json` (`PlainLaunchReport`: the helper's pid, its terminal's path
///    from its standard input with `ttyname` or none, the attach child's pid and its kernel
///    start time), written atomically 0600 by `LaunchStore.writeReport(_:)`. A report that
///    cannot be written is logged and the attach goes on (the coordinator then cannot confirm).
/// 4. **The end:** the result exactly as `attach` writes it, the explanation and the wait for
///    Return after a failure; no OSC 1337 sequence, no status report request and no wait for
///    one, nothing buried or restored; the 10 s minimum lifetime only when the request's
///    `keepsMinimumLifetime` is `true` (before a request is taken, never).
///
/// Test mode writes the argv digest with the attach child and its process id, as `attach`
/// does, and honors `testLaunchDelaySeconds`; `testSuppressDisinter` has nothing to suppress.
extension LaunchHelper {
  /// Runs `attach-plain <launch id>` for `id` (see the extension's documentation).
  func attachPlain(
    _ id: LaunchToken,
    startedAt: Date,
    argvDigest: LaunchArgvDigest? = nil
  ) async -> Int32 {
    guard let store else {
      return await finish(
        id, request: nil, failure: .launchDirectoryUnusable, child: ChildRecord(),
        startedAt: startedAt, resultStore: nil, holdsMinimumLifetime: false)
    }
    let request: LaunchRequest
    do throws(LaunchStoreError) {
      request = try store.takePlainRequest(id)
    } catch {
      let failure = error.launchFailure
      await log.record(.launch, outcome: .failure, detail: "Plain request refused: \(error)")
      return await finish(
        id, request: nil, failure: failure, child: ChildRecord(), startedAt: startedAt,
        resultStore: failure == .launchDirectoryUnusable ? nil : store,
        holdsMinimumLifetime: false)
    }
    _ = try? store.sweep()
    let holds = request.holdsMinimumLifetimeInPlainMode
    var child = ChildRecord(startedAt: now())
    if let seconds = request.testLaunchDelaySeconds, isTestMode,
      let failure = await testLaunchDelay(seconds, child: &child)
    {
      return await finish(
        id, request: request, failure: failure, child: child, startedAt: startedAt,
        resultStore: store, holdsMinimumLifetime: holds)
    }
    let executable: String
    let arguments: [String]
    switch await plainAttachChild(for: request, child: &child) {
    case .failed(let failure):
      return await finish(
        id, request: request, failure: failure, child: child, startedAt: startedAt,
        resultStore: store, holdsMinimumLifetime: holds)
    case .run(let path, let argv):
      (executable, arguments) = (path, argv)
    }
    var recorder: LaunchDigestRecorder?
    if let argvDigest {
      let written = await recordAttachChild(
        in: argvDigest, executable: executable, arguments: arguments,
        detachesOtherClients: request.detachesOtherClients)
      recorder = LaunchDigestRecorder(store: store, digest: written)
    }
    let digestRecorder = recorder
    let reporter = PlainLaunchReporter(
      store: store, id: id, helperPID: processID, terminalPath: plainFacts.terminalPath(),
      startTime: plainFacts.startTime)
    let onSpawn: @Sendable (Int32) -> Void = { processID in
      reporter.report(childProcessID: processID)
      digestRecorder?.update { $0.attachChildProcessID = processID }
    }
    let outcome: LaunchChildOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.run(
        executable: executable, arguments: arguments, environment: childEnvironment,
        relaysStandardError: request.host.isRemote, standardInput: .terminalReadWrite,
        onSpawn: onSpawn)
    } catch {
      return await finish(
        id, request: request, failure: .spawnFailed(errno: Self.errorNumber(of: error)),
        child: child, startedAt: startedAt, resultStore: store, holdsMinimumLifetime: holds)
    }
    await logReport(reporter.outcome, hostID: request.hostID)
    child.termination = outcome.termination
    child.terminalHungUp = outcome.terminalHungUp
    let failure = LaunchFailure.from(
      outcome.termination, host: request.host, sshStandardError: outcome.capturedStandardError)
    return await finish(
      id, request: request, failure: failure, child: child, startedAt: startedAt,
      resultStore: store, holdsMinimumLifetime: holds)
  } // End of func attachPlain(_:startedAt:argvDigest:)

  /// What `plainAttachChild(for:child:)` decided.
  enum PlainAttachChild: Equatable {
    /// Run this executable with these arguments (after argv[0]).
    case run(executable: String, arguments: [String])
    /// Run nothing.
    case failed(LaunchFailure)
  }

  /// The plain attach child for `request`: on This Mac the check (`check(_:child:)`, recording
  /// its end in `child`) and then the tmux it printed with `PlainLaunch.localAttachArguments(
  /// for:)`; on an SSH host `/usr/bin/ssh` with `PlainLaunch.sshArguments(for:)`. A request
  /// whose values the builders refuse (never one `takePlainRequest` accepted) is
  /// `requestUnreadable`, with nothing run.
  func plainAttachChild(
    for request: LaunchRequest,
    child: inout ChildRecord
  ) async -> PlainAttachChild {
    switch request.host {
    case .local:
      guard let arguments = PlainLaunch.localAttachArguments(for: request) else {
        return .failed(.requestUnreadable)
      }
      switch await check(request, child: &child) {
      case .failed(let failure): return .failed(failure)
      case .attach(let path): return .run(executable: path, arguments: arguments)
      }
    case .ssh:
      guard let arguments = PlainLaunch.sshArguments(for: request) else {
        return .failed(.requestUnreadable)
      }
      return .run(executable: RemoteLaunch.sshPath, arguments: arguments)
    }
  } // End of func plainAttachChild(for:child:)

  /// Logs how the early report went (kinds only: never the terminal's path).
  func logReport(_ outcome: PlainLaunchReporter.Outcome, hostID: UUID) async {
    switch outcome {
    case .written(let hasTerminal):
      await log.record(
        .launch, outcome: .info, hostID: hostID.uuidString,
        detail: "Early report written (terminal known: \(hasTerminal)).")
    case .notYet:
      await log.record(
        .launch, outcome: .failure, hostID: hostID.uuidString,
        detail: "Early report not written: the attach child was not reported.")
    case .startTimeUnreadable:
      await log.record(
        .launch, outcome: .failure, hostID: hostID.uuidString,
        detail: "Early report not written: the attach child's start time is unreadable.")
    case .notWritten(let error):
      await log.record(
        .launch, outcome: .failure, hostID: hostID.uuidString,
        detail: "Early report not written: \(error)")
    }
  } // End of func logReport(_:hostID:)
} // End of extension LaunchHelper

/// Writes `attach-plain`'s early report (PLAN.md D38) from the thread that supervises the attach
/// child, right after the spawn and before the wait (the child is unreaped, so its pid and start
/// time name it), and keeps how that went for the log.
final class PlainLaunchReporter: Sendable {
  /// How the report went.
  enum Outcome: Sendable, Equatable {
    /// No child was reported (the spawn failed, or the runner never called back).
    case notYet
    /// The report was written; whether it names a terminal.
    case written(hasTerminal: Bool)
    /// The child's start time could not be read, so no report was written.
    case startTimeUnreadable
    /// The store refused the write.
    case notWritten(LaunchStoreError)
  }

  /// Where the report goes.
  let store: LaunchStore
  /// The launch id.
  let id: LaunchToken
  /// The helper's pid.
  let helperPID: Int32
  /// The helper's terminal, read before the spawn.
  let terminalPath: String?
  /// Reads the child's start time.
  let startTime: @Sendable (Int32) -> ProcessStartTime?
  /// The outcome so far.
  private let state = OSAllocatedUnfairLock<Outcome>(initialState: .notYet)

  /// Creates a reporter for one launch.
  init(
    store: LaunchStore,
    id: LaunchToken,
    helperPID: Int32,
    terminalPath: String?,
    startTime: @escaping @Sendable (Int32) -> ProcessStartTime?
  ) {
    self.store = store
    self.id = id
    self.helperPID = helperPID
    self.terminalPath = terminalPath
    self.startTime = startTime
  } // End of init(store:id:helperPID:terminalPath:startTime:)

  /// Writes the report for the attach child `childProcessID` and records the outcome.
  func report(childProcessID: Int32) {
    guard let start = startTime(childProcessID) else {
      state.withLock { $0 = .startTimeUnreadable }
      return
    }
    let report = PlainLaunchReport(
      id: id, helperPID: helperPID, terminalPath: terminalPath, attachChildPID: childProcessID,
      attachChildStartTime: start)
    let outcome: Outcome
    do throws(LaunchStoreError) {
      try store.writeReport(report)
      outcome = .written(hasTerminal: terminalPath != nil)
    } catch {
      outcome = .notWritten(error)
    }
    state.withLock { $0 = outcome }
  } // End of func report(childProcessID:)

  /// How the report went so far.
  var outcome: Outcome { state.withLock { $0 } }
} // End of class PlainLaunchReporter
