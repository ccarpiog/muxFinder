import Foundation
import MuxFinderCore

/// `muxfinder-probe e2e-local`: the real local integration proof (PLAN.md Phases 4, 5a, 6a, 6b). It
/// opens real iTerm2 windows, so it only runs when asked for, never from `swift test`. The
/// steps and their safety rules are `E2ERun`'s.
enum E2ELocalCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      e2e-local
          Real end-to-end check on this Mac; opens iTerm2 windows. Creates a
          muxfinder-test-<random> session on the default tmux server, then discovers it,
          attaches it, checks its tabs and split, attaches it again (which must focus the
          existing tab and open nothing), detaches it by session, reattaches, attaches twice
          at once and tries a stale launch; then attaches a session killed after discovery
          (sessionGone, nothing opened), creates one with the existing name (sessionExists),
          with invalid names (nothing run) and in a missing directory (directoryMissing),
          creates and attaches muxfinder-test-<random>-new in a private directory with
          spaces and Unicode, and finally moves its session here: a plain tmux control
          client it started on that session must be detached by the move here
          (attach-session -d) while the iTerm2 attachment stays, printing a PASS or FAIL
          line per step. Cleans up after itself, also on failure or Ctrl-C. Asks only its
          own launch tabs' tmux
          connections which session they show; other connections get no command. Needs
          iTerm2 running with its API on, and TMUX_TMPDIR unset (the helper in iTerm2 always
          uses the default server). Run swift build first: iTerm2 runs the muxfinder-launch
          next to this executable.
    """

  /// Runs the subcommand and returns the exit status: 0 when every step passed.
  static func run(_ arguments: [String]) async -> Int32 {
    guard arguments.isEmpty else {
      printError("muxfinder-probe: e2e-local takes no options\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    guard ProcessInfo.processInfo.environment["TMUX_TMPDIR"] == nil else {
      printError(
        "muxfinder-probe: unset TMUX_TMPDIR; muxfinder-launch in iTerm2 always uses the default "
          + "tmux server")
      return EX_USAGE
    }
    guard let tmux = TestTmux.locate() else {
      printError("muxfinder-probe: tmux was not found")
      return EX_UNAVAILABLE
    }
    let helperPath: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_UNAVAILABLE
    }
    return await E2ECommand.run { E2ERun(kind: .local, tmux: tmux, helperPath: helperPath) }
  } // End of func run(_:)
}

/// `muxfinder-probe e2e-remote <destination>`: the real integration proof over SSH (PLAN.md
/// Phases 5b, 6a, 6b; D17). It opens real iTerm2 windows on this Mac whose launch tabs run ssh to the
/// destination, so it only runs when asked for, never from `swift test`. The steps and their
/// safety rules are `E2ERun`'s.
enum E2ERemoteCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      e2e-remote <destination>
          Real end-to-end check over SSH; opens iTerm2 windows on this Mac. Creates a
          muxfinder-test-<random> session on the destination's default tmux server (over
          ssh with BatchMode, a static script and quoted arguments), then discovers it,
          attaches it (the launch tab runs ssh -t to the destination), checks its tabs and
          split, detaches it by session, reattaches, attaches it again (which must focus
          the existing tab and open nothing), detaches it, tries a stale launch (refused by
          the guard on the remote host), and attaches it once more with the helper's
          test-only launch delay, so the launch tab waits before starting ssh (no login, no
          prompt; the attach must report stillWaiting after its 20 s budget, never success,
          until the test closes that tab); then the session-creation steps of e2e-local, with
          ~/Library/Application Support as the existing directory and a missing one under ~
          (nothing is written there), and the move here of e2e-local, its plain control
          client started over ssh (BatchMode, no connection sharing), printing a PASS or
          FAIL line per step. Cleans up after
          itself (kills only its own sessions), also on failure or Ctrl-C. Asks only
          its own launch tabs' tmux connections which session they show. Needs key
          authentication to the destination, tmux there, iTerm2 running with its API on.
          Run swift build first: iTerm2 runs the muxfinder-launch next to this executable.
    """

  /// Runs the subcommand and returns the exit status: 0 when every step passed.
  static func run(_ arguments: [String]) async -> Int32 {
    guard arguments.count == 1 else {
      printError("muxfinder-probe: e2e-remote takes one destination\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    let destination: String
    do throws(ValidationError) {
      destination = try Validation.sshDestination(arguments[0])
    } catch {
      printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    let helperPath: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_UNAVAILABLE
    }
    let tmux = RemoteTestTmux(destination: destination)
    return await E2ECommand.run {
      E2ERun(kind: .remote(destination: destination), tmux: tmux, helperPath: helperPath)
    }
  } // End of func run(_:)
}

/// The run loop both e2e commands share: header, steps raced against signals and the overall
/// limit, cleanup, summary.
enum E2ECommand {
  /// How long the whole run may take before it is stopped and cleaned up.
  static let overallLimit: Duration = .seconds(300)

  /// How the steps ended.
  enum Ending: Sendable, Equatable {
    /// They ran to the end (passing or not).
    case finished
    /// A signal arrived.
    case signal(Int32)
    /// The overall limit passed.
    case timeLimit
  }

  /// Watches signals, creates the run with `makeHarness`, runs its steps until they finish, a
  /// signal arrives or the overall limit passes, then always cleans up and prints the summary.
  /// Returns 0 when every step passed, 128 + n after signal n, 1 otherwise.
  static func run(_ makeHarness: () -> E2ERun) async -> Int32 {
    let watcher = SignalWatcher()
    let started = ContinuousClock.now
    let harness = makeHarness()
    await harness.printHeader()
    let steps = Task { await harness.runSteps() }
    let ending = await waitForEnding(of: steps, watcher: watcher)
    switch ending {
    case .finished:
      break
    case .signal(let number):
      harness.output("Interrupted by signal \(number); cleaning up.")
    case .timeLimit:
      harness.output("The run took longer than \(overallLimit); cleaning up.")
    }
    await steps.value
    let cleanup = Task { await harness.cleanUp() }
    await cleanup.value
    watcher.stop()
    let passed = await harness.passedCount
    let total = milliseconds(ContinuousClock.now - started)
    harness.output(
      "\(harness.name): \(passed) of \(harness.stepCount) steps passed in "
        + "\(String(format: "%.1f", Double(total) / 1000)) s")
    if case .signal(let number) = ending { return 128 + number }
    return passed == harness.stepCount && ending == .finished ? 0 : 1
  } // End of func run(_:)

  /// Waits until the steps finish, a signal arrives or the overall limit passes; in the last
  /// two cases the steps are cancelled.
  static func waitForEnding(of steps: Task<Void, Never>, watcher: SignalWatcher) async -> Ending {
    await withTaskGroup(of: Ending.self) { group in
      group.addTask {
        await steps.value
        return .finished
      }
      group.addTask {
        for await number in watcher.stream { return .signal(number) }
        return .finished
      }
      group.addTask {
        do {
          try await Task.sleep(for: overallLimit)
          return .timeLimit
        } catch {
          return .finished
        }
      }
      let first = await group.next() ?? .finished
      if first != .finished { steps.cancel() }
      group.cancelAll()
      return first
    } // End of task group racing the steps against signals and the limit
  } // End of func waitForEnding(of:watcher:)
}
