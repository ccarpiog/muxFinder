import Foundation
import MuxFinderCore

/// `muxfinder-probe plain-proof --local | --ssh <destination>`: the proof of plain tmux attaches
/// for terminal apps without control mode (PLAN.md D38, Phase I-12a). It hosts plain tmux
/// clients on pseudo-terminals it opens itself, so it needs no terminal app, no Automation
/// permission and no iTerm2. The steps and their safety rules are `PlainProofRun`'s; this file
/// parses the arguments, wires the parts and races the steps against signals and an overall
/// limit, like `E2EDetachOthersCommand`.
enum PlainProofCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      plain-proof --local | --ssh <destination>
          Proof of plain tmux attaches outside iTerm2 (PLAN.md D38). Creates
          muxfinder-test-<random> (one window running sleep 600) on the default tmux server of
          this Mac or of the destination (over ssh with BatchMode) and attaches plain clients
          (tmux -u if-shell -F ... attach-session, no -CC: bound to the recorded session, so a
          changed one exits 65) on pseudo-terminals of its own; remotely each runs /usr/bin/ssh
          -t (BatchMode, key authentication, no connection sharing) with the plain remote
          script carrying a launch token. 9 steps: a client identified (locally by its
          client_tty, remotely by the token in its parent shell's arguments, read with ps over
          noninteractive ssh); a terminal or token with no client matches none, and a stale
          attach there attaches nothing; a second client told apart; two candidates (a second
          client on the same terminal, or with the same token) refused; a stale bound detach
          detaches nothing, the bound detach of one identified client ends only it; a stale
          move here detaches nobody, a move here (attach-session -d) leaves only the new
          client; its detach; cleanup. Prints a PASS or FAIL line per step. Output on the
          pseudo-terminals is discarded, never shown.
          Cleans up after itself (ends its children, kills only its own session), also on
          failure or Ctrl-C. Never contacts iTerm2 or any terminal app. Needs TMUX_TMPDIR
          unset.
    """

  /// How long the whole run may take before it is stopped and cleaned up.
  static let overallLimit: Duration = .seconds(150)

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
        "muxfinder-probe: plain-proof takes --local or --ssh <destination>\n\nusage:\n" + usage)
      return EX_USAGE
    }
    guard ProcessInfo.processInfo.environment["TMUX_TMPDIR"] == nil else {
      printError("muxfinder-probe: unset TMUX_TMPDIR; the proof uses the default tmux server")
      return EX_USAGE
    }
    let harness: PlainProofRun
    switch kind {
    case .local:
      guard let local = TestTmux.locate() else {
        printError("muxfinder-probe: tmux was not found")
        return EX_UNAVAILABLE
      }
      harness = PlainProofRun(kind: kind, tmux: local, localTmux: local, remoteTmux: nil)
    case .remote(let destination):
      let remote = RemoteTestTmux(destination: destination)
      harness = PlainProofRun(kind: kind, tmux: remote, localTmux: nil, remoteTmux: remote)
    }
    return await run(harness)
  } // End of func run(_:)

  /// The header, the steps raced against signals and the overall limit, cleanup and the
  /// summary. Returns 0 when every step passed, 128 + n after signal n, 1 otherwise.
  static func run(_ harness: PlainProofRun) async -> Int32 {
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
      "\(harness.name): \(passed) of \(PlainProofRun.stepCount) steps passed in "
        + "\(String(format: "%.1f", Double(total) / 1000)) s")
    if case .signal(let number) = ending { return 128 + number }
    return passed == PlainProofRun.stepCount && ending == .finished ? 0 : 1
  } // End of func run(_:)
} // End of enum PlainProofCommand
