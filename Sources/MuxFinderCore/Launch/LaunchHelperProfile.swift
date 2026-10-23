import Darwin
import Foundation

/// `muxfinder-launch profile <host id>`: what a "Persistent work" profile's tab runs (PLAN.md
/// D26). iTerm2 starts it from the profile's `Command`; no request file is involved, so the host
/// comes from the host list, read-only.
///
/// 1. **Nesting guard:** when `TMUX` or `MUXFINDER_LAUNCHED` is set and not empty (the tab
///    already runs inside tmux, or inside something a muxFinder helper started), it prints one
///    line and starts the login shell instead, before reading anything.
/// 2. **The plan:** it loads `hosts.json` through `HostStore` (read-only: no folder or file is
///    ever created or written) and resolves the host (`ProfileLaunchPlan.make(hostID:from:)`).
///    In test mode a test host list for this host id in the launch directory
///    (`LaunchStore.profileTestHostsURL(forHostID:)`), when present, is read instead.
/// 3. **The persistent session** (`ProfileLaunch`): locally the D5 check, then
///    `<tmux> -u -CC new-session -A -s <name>` on the tab's terminal; on an SSH host D17's
///    interactive ssh with the static remote script. Its environment carries
///    `MUXFINDER_LAUNCHED=1` (`childEnvironment`).
/// 4. **The end:** tmux ending normally (a detach) ends the helper, never before it is
///    `minimumLifetime` old while the tab is visible (D14), and the tab closes (the profile's
///    `Close Sessions On End`). Any problem or failure prints its explanation and starts the
///    login shell, so the tab stays usable and never ends inside iTerm2's short-lived-session
///    window. A closed tab (SIGHUP) starts nothing.
///
/// The login shell (`LoginShellStarting`) replaces the helper; it is not started in test mode
/// (recorded in the argv digest instead) or when the terminal is not interactive (tests, or
/// `MUXFINDER_LAUNCH_NO_WAIT=1`): the helper then ends like a failed attach, the explanation,
/// the wait for Return and the hold included, with `ProfileLaunchProblem.exitStatus`. A shell
/// that cannot start (every candidate failed) ends the same way with `spawnFailed` (74).
extension LaunchHelper {
  /// Runs `profile <host id>` for `hostToken` (see the extension's documentation).
  func profile(
    _ hostToken: LaunchToken,
    startedAt: Date,
    argvDigest: LaunchArgvDigest? = nil
  ) async -> Int32 {
    let hostID = hostToken.uuid
    if let variable = ProfileLaunch.nestingVariable(in: environment) {
      return await startLoginShell(
        instead: .nested(variable: variable), hostID: hostID, startedAt: startedAt,
        argvDigest: argvDigest, terminalHungUp: false)
    }
    let plan: ProfileLaunchPlan
    switch await profilePlan(for: hostID) {
    case .failure(let problem):
      return await startLoginShell(
        instead: problem, hostID: hostID, startedAt: startedAt, argvDigest: argvDigest,
        terminalHungUp: false)
    case .success(let resolved):
      plan = resolved
    }
    var child = ChildRecord(startedAt: now())
    let executable: String
    let arguments: [String]
    switch plan.host {
    case .local:
      switch await locateTmux(override: plan.tmuxPathOverride, child: &child) {
      case .failed(let failure):
        return await startLoginShell(
          instead: .launchFailed(failure, host: plan.host), hostID: hostID,
          startedAt: startedAt, argvDigest: argvDigest, terminalHungUp: child.terminalHungUp)
      case .attach(let path):
        (executable, arguments) = (path, ProfileLaunch.tmuxArguments(sessionName: plan.sessionName))
      }
    case .ssh(let destination):
      // `ProfileLaunchPlan` accepted only a valid destination; refuse anything else all the same.
      guard
        let sshArguments = ProfileLaunch.sshArguments(
          destination: destination, override: plan.tmuxPathOverride,
          sessionName: plan.sessionName)
      else {
        return await startLoginShell(
          instead: .invalidDestination(.sshDestinationEmpty), hostID: hostID,
          startedAt: startedAt, argvDigest: argvDigest, terminalHungUp: false)
      }
      (executable, arguments) = (RemoteLaunch.sshPath, sshArguments)
    }
    if let argvDigest {
      await recordAttachChild(
        in: argvDigest, executable: executable, arguments: arguments, detachesOtherClients: false)
    }
    let outcome: LaunchChildOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.run(
        executable: executable, arguments: arguments, environment: childEnvironment,
        relaysStandardError: plan.host.isRemote)
    } catch {
      return await startLoginShell(
        instead: .launchFailed(.spawnFailed(errno: Self.errorNumber(of: error)), host: plan.host),
        hostID: hostID, startedAt: startedAt, argvDigest: argvDigest, terminalHungUp: false)
    }
    if let failure = ProfileLaunch.failure(
      for: outcome.termination, host: plan.host, sshStandardError: outcome.capturedStandardError)
    {
      return await startLoginShell(
        instead: .launchFailed(failure, host: plan.host), hostID: hostID, startedAt: startedAt,
        argvDigest: argvDigest, terminalHungUp: outcome.terminalHungUp)
    }
    await log.record(
      .launch, outcome: .success, hostID: hostID.uuidString,
      durationMs: Int(now().timeIntervalSince(startedAt) * 1000),
      detail: "Persistent session ended normally.")
    await holdUntilMinimumLifetime(since: startedAt, terminalHungUp: outcome.terminalHungUp)
    return LaunchExitStatus.success
  } // End of func profile(_:startedAt:argvDigest:)

  /// The plan for `hostID`, from the host list (`profileHostList(for:)`), or why there is none.
  func profilePlan(for hostID: UUID) async -> Result<ProfileLaunchPlan, ProfileLaunchProblem> {
    do throws(HostStoreError) {
      return ProfileLaunchPlan.make(hostID: hostID, from: try await profileHostList(for: hostID))
    } catch {
      return .failure(.hostListUnreadable(error))
    }
  }

  /// The host list for `hostID`'s profile, loaded read-only: in test mode the test host list
  /// for that host in the launch directory when there is one (anything but `notSavedYet`),
  /// otherwise `hostStore` (`hosts.json`).
  func profileHostList(for hostID: UUID) async throws(HostStoreError) -> HostStoreLoadResult {
    if isTestMode, let store {
      let test = try await HostStore(fileURL: store.profileTestHostsURL(forHostID: hostID)).load()
      if test.state != .notSavedYet { return test }
    }
    return try await hostStore.load()
  } // End of func profileHostList(for:)

  /// The local check of `profile` mode: the D5 locator as a check-stage child
  /// (`ProfileLaunch.locateRequest`, its own process group and `checkTimeout`), whose printed
  /// path is accepted by `LaunchGuard.tmuxPath(fromCheckOutput:override:)`. Records the check's
  /// end and any hang-up in `child`.
  func locateTmux(override: String?, child: inout ChildRecord) async -> CheckVerdict {
    let outcome: LaunchCheckOutcome
    do throws(ProcessRunnerError) {
      outcome = try await childRunner.runCheck(
        ProfileLaunch.locateRequest(
          override: override, environment: childEnvironment, timeout: checkTimeout))
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
    if let failure = LaunchFailure.fromCheck(result.termination, timedOut: result.timedOut) {
      return .failed(failure)
    }
    guard
      let path = LaunchGuard.tmuxPath(fromCheckOutput: result.standardOutput, override: override)
    else {
      await log.record(.launch, outcome: .failure, detail: "The check printed no usable tmux path.")
      return .failed(.tmuxCheckFailed)
    }
    return .attach(tmuxPath: path)
  } // End of func locateTmux(override:child:)

  /// The login shell's environment: the helper's own minus the `MUXFINDER_LAUNCH_*` variables,
  /// with `MUXFINDER_LAUNCHED=1` (`TMUX`, when set, stays: the shell does run inside tmux).
  var loginShellEnvironment: [String: String] {
    var environment = environment.filter { !$0.key.hasPrefix(Self.ownVariablePrefix) }
    environment[ProfileLaunch.launchedVariable] = ProfileLaunch.launchedValue
    return environment
  }

  /// Explains `problem`, then starts the login shell in place of the helper. Nothing is shown
  /// or started once the tab is gone (`terminalHungUp`). In test mode, or on a terminal that is
  /// not interactive, the shell is not started (test mode records it in the argv digest): the
  /// helper ends like a failed launch, waiting for Return and holding the tab open until it is
  /// `minimumLifetime` old, with `problem.exitStatus`. When every shell fails to start, it says
  /// so and ends the same way with `spawnFailed` (74).
  func startLoginShell(
    instead problem: ProfileLaunchProblem,
    hostID: UUID,
    startedAt: Date,
    argvDigest: LaunchArgvDigest?,
    terminalHungUp: Bool
  ) async -> Int32 {
    await log.record(
      .launch, outcome: .failure, hostID: hostID.uuidString,
      durationMs: Int(now().timeIntervalSince(startedAt) * 1000),
      detail: "Persistent session not started: \(problem.kind), exit status "
        + "\(problem.exitStatus).")
    guard !terminalHungUp else { return problem.exitStatus }
    let candidates = loginShell.candidates()
    if let argvDigest, let shell = candidates.first {
      await recordAttachChild(
        in: argvDigest, executable: shell.argv0, arguments: [], detachesOtherClients: false,
        startsLoginShell: true)
    }
    let starts = terminal.isInteractive && !isTestMode && !candidates.isEmpty
    terminal.write(
      "\nmuxFinder: \(problem.explanation)"
        + (starts ? " Starting your login shell instead." : "") + "\n")
    guard starts else {
      if isTestMode { terminal.write("muxFinder test mode: the login shell was not started.\n") }
      await waitForReturnAndHold(since: startedAt)
      return problem.exitStatus
    }
    var failure = ENOENT
    for shell in candidates {
      switch loginShell.exec(shell, environment: loginShellEnvironment) {
      case .replaced:
        return problem.exitStatus
      case .failed(let code):
        failure = code
      }
    } // End of loop over the login shell candidates
    await log.record(
      .launch, outcome: .failure, hostID: hostID.uuidString,
      detail: "Login shell not started (\(candidates.count) tried).")
    terminal.write(
      "muxFinder: muxFinder could not start your login shell: "
        + "\(String(cString: strerror(failure))).\n")
    await waitForReturnAndHold(since: startedAt)
    return LaunchExitStatus.spawnFailed
  } // End of func startLoginShell(instead:hostID:startedAt:argvDigest:terminalHungUp:)

  /// When someone can see the tab: waits for Return, then holds it open until the helper is
  /// `minimumLifetime` old (D14).
  func waitForReturnAndHold(since startedAt: Date) async {
    if terminal.isInteractive {
      terminal.write("\nPress Return to close.")
      await terminal.waitForReturn()
      terminal.write("\n")
    }
    await holdUntilMinimumLifetime(since: startedAt, terminalHungUp: false)
  }
}
