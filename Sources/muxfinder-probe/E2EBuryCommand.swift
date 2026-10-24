import Foundation
import MuxFinderCore

/// `muxfinder-probe e2e-bury --local | --ssh <destination>`: the spike harness of PLAN.md
/// Phase 13a, which learns how iTerm2 treats a launch tab buried through its API. It opens real
/// iTerm2 windows, so it only runs when asked for, never from `swift test`. The steps and their
/// safety rules are `E2EBuryRun`'s; this file parses the arguments, wires the real parts and
/// races the steps against signals and an overall limit, like `E2ECommand`.
enum E2EBuryCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      e2e-bury --local | --ssh <destination>
          Spike harness for PLAN.md Phase 13a (it records what iTerm2 does; it is not a
          regression check); opens iTerm2 windows. Creates muxfinder-test-<random> (one pane
          running sleep 600) on the default tmux server of this Mac or of the destination
          (over ssh with BatchMode) and attaches it three times through its own launch tabs,
          burying each launch tab through iTerm2's API once its first tmux tab is active:
          (a) the bury and where iTerm2 lists the tab; (c) a detach of the buried tab, then a
          bury during the helper's hold, with the helper's restores (Disinter, then a status
          report), sampled to tell whether each answer came after the restore; (b) the same
          with the helper's Disinter suppressed (test mode), then (d) what Close answers for
          the dead buried session; (e) SIGKILL of only the helper's attach child (the tmux -CC
          client; remotely the local ssh child, only when ssh -G shows no connection sharing)
          while buried, what follows, and (d) Close of the live buried tab. With iTerm2's
          "Automatically bury the tmux client session" setting on, it buries its own launch
          tab again where the default setting would have left it buried.
          Prints a PASS or FAIL line per step and OBSERVATION lines; FAIL means a harness or
          safety problem, not an unexpected answer. Cleans up after itself (restores, then
          closes, only its own launch tabs; kills only its own session), also on failure or
          Ctrl-C. Asks only its own launch tabs' tmux connections. Needs iTerm2 running with
          its API on and TMUX_TMPDIR unset. Run swift build first: iTerm2 runs the
          muxfinder-launch next to this executable.
    """

  /// How long the whole run may take before it is stopped and cleaned up.
  static let overallLimit: Duration = .seconds(300)

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
        "muxfinder-probe: e2e-bury takes --local or --ssh <destination>\n\nusage:\n\(usage)")
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
    return await run(E2EBuryRun(kind: kind, tmux: tmux, helperPath: helperPath))
  } // End of func run(_:)

  /// The header, the steps raced against signals and the overall limit, cleanup and the
  /// summary. Returns 0 when every step passed, 128 + n after signal n, 1 otherwise.
  static func run(_ harness: E2EBuryRun) async -> Int32 {
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
      "\(harness.name): \(passed) of \(E2EBuryRun.stepCount) steps passed in "
        + "\(String(format: "%.1f", Double(total) / 1000)) s")
    if case .signal(let number) = ending { return 128 + number }
    return passed == E2EBuryRun.stepCount && ending == .finished ? 0 : 1
  } // End of func run(_:)
} // End of enum E2EBuryCommand
