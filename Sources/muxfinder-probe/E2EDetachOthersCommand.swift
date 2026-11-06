import Foundation
import MuxFinderCore

/// `muxfinder-probe e2e-detach-others --local | --ssh <destination>`: the real check of "Detach
/// other clients" (PLAN.md D37, Phase I-11a). It opens real iTerm2 windows, so it only runs
/// when asked for, never from `swift test`. The steps and their safety rules are
/// `E2EDetachOthersRun`'s; this file parses the arguments, wires the real parts and races the
/// steps against signals and an overall limit, like `E2EBuryCommand`.
enum E2EDetachOthersCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      e2e-detach-others --local | --ssh <destination>
          Real check of Detach other clients (PLAN.md D37); opens iTerm2 windows. Creates
          muxfinder-test-<random> (two windows running sleep 600) on the default tmux server of
          this Mac or of the destination (over ssh with BatchMode), attaches it through the
          coordinator (which buries the launch tab) and attaches a plain control client of its
          own (tmux -u -C, remotely over ssh with no connection sharing) (9 steps): a
          confirmation for another session runs nothing; the call detaches 1 client once it is
          10 s old, the plain client printing %exit and exiting 0 by itself within 10 s of the
          call's return; 2 s later the iTerm2 tabs
          and sessions showing the session's windows have the same ids (looked at every 250 ms,
          never closed or reopened), the launch tab still owns its connection, still in
          buried_sessions and in no tab, and the session alive with that attachment as its only
          client; then a detach by connection (the launch tab leaving by itself).
          Prints a PASS or FAIL line per step with note lines. Cleans up after itself (ends the
          plain client, restores, then closes, only its own launch tabs; kills only its own
          session), also on failure or Ctrl-C. Asks only its own launch tabs' tmux connections.
          Needs iTerm2 running with its API on and TMUX_TMPDIR unset. Run swift build first:
          iTerm2 runs the muxfinder-launch next to this executable.
    """

  /// How long the whole run may take before it is stopped and cleaned up.
  static let overallLimit: Duration = .seconds(180)

  /// Runs the subcommand and returns the exit status: 0 when every step passed; `--help`
  /// prints the usage and contacts nothing.
  static func run(_ arguments: [String]) async -> Int32 {
    if arguments.count == 1, ["--help", "-h", "help"].contains(arguments[0]) {
      print("usage:\n\(usage)")
      return 0
    }
    let kind: E2EBuryRun.Kind
    switch arguments.first {
    case "--local" where arguments.count == 1:
      kind = .local
    case "--ssh" where arguments.count == 2:
      do throws(ValidationError) {
        kind = .remote(destination: try Validation.sshDestination(arguments[1]))
      } catch {
        printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
        return EX_USAGE
      }
    default:
      printError(
        "muxfinder-probe: e2e-detach-others takes --local or --ssh <destination>\n\nusage:\n"
          + usage)
      return EX_USAGE
    }
    guard ProcessInfo.processInfo.environment["TMUX_TMPDIR"] == nil else {
      printError(
        "muxfinder-probe: unset TMUX_TMPDIR; muxfinder-launch in iTerm2 always uses the default "
          + "tmux server")
      return EX_USAGE
    }
    let helperPath: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_UNAVAILABLE
    }
    let tmux: any HarnessTmux
    switch kind {
    case .local:
      guard let local = TestTmux.locate() else {
        printError("muxfinder-probe: tmux was not found")
        return EX_UNAVAILABLE
      }
      tmux = local
    case .remote(let destination):
      tmux = RemoteTestTmux(destination: destination)
    }
    return await run(E2EDetachOthersRun(kind: kind, tmux: tmux, helperPath: helperPath))
  } // End of func run(_:)

  /// The header, the steps raced against signals and the overall limit, cleanup and the
  /// summary. Returns 0 when every step passed, 128 + n after signal n, 1 otherwise.
  static func run(_ harness: E2EDetachOthersRun) async -> Int32 {
    let watcher = SignalWatcher()
    let started = ContinuousClock.now
    await harness.printHeader()
    let steps = Task { await harness.runSteps() }
    let ending = await E2ECommand.waitForEnding(of: steps, watcher: watcher, limit: overallLimit)
    switch ending {
    case .finished: break
    case .signal(let number): harness.output("Interrupted by signal \(number); cleaning up.")
    case .timeLimit: harness.output("The run took longer than \(overallLimit); cleaning up.")
    }
    await steps.value
    await Task { await harness.cleanUp() }.value
    watcher.stop()
    let passed = await harness.passedCount
    let total = milliseconds(ContinuousClock.now - started)
    harness.output(
      "\(harness.name): \(passed) of \(E2EDetachOthersRun.stepCount) steps passed in "
        + "\(String(format: "%.1f", Double(total) / 1000)) s")
    if case .signal(let number) = ending { return 128 + number }
    return passed == E2EDetachOthersRun.stepCount && ending == .finished ? 0 : 1
  } // End of func run(_:)
} // End of enum E2EDetachOthersCommand
