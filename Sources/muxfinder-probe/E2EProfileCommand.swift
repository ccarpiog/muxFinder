import Foundation
import MuxFinderCore

/// `muxfinder-probe e2e-profile --local | --ssh <destination>`: the real run of a persistent
/// work profile for Phase 11b (PLAN.md D26). It writes a real `DynamicProfiles/muxFinder.json`
/// (refusing to start when one exists) and opens a real iTerm2 window, so it only runs when
/// asked for, never from `swift test`. The steps and their safety rules are
/// `PersistentProfileRun`'s; this file wires the real parts and races the steps against signals
/// and an overall limit, like `E2ECommand`.
enum E2EProfileCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      e2e-profile --local | --ssh <destination>
          Real run of a persistent work profile; writes DynamicProfiles/muxFinder.json and
          opens an iTerm2 window. Refuses to start when muxFinder.json exists there (it is
          yours then) or a session named muxfinder-test-profile exists. Takes a hash
          snapshot of iTerm2's other profiles, creates muxfinder-test-profile (panes run
          sleep 600) on the default tmux server of this Mac or of the destination (over ssh
          with BatchMode), installs a profile for a test host (its host list is a test file
          in muxFinder's launch folder, read by the helper in test mode; your hosts.json is
          never read or written), waits until iTerm2 lists it, opens it with CreateTab,
          checks that its tab gets a control-mode connection to that session, compares the
          snapshot, detaches through the tab's own connection once the tab is 10 s old,
          kills only that session, removes only the file it wrote, waits until iTerm2 drops
          the profile and compares the snapshot again, printing a PASS or FAIL line per
          step. Cleans up after itself, also on failure or Ctrl-C. Asks only its own tab's
          tmux connection. Needs iTerm2 running with its API on and TMUX_TMPDIR unset. Run
          swift build first: iTerm2 runs the muxfinder-launch next to this executable.
    """

  /// How long the whole run may take before it is stopped and cleaned up.
  static let overallLimit: Duration = .seconds(180)

  /// tmux for the run, over the e2e harness's local or remote tmux.
  struct Tmux: ProfileRunTmux {
    /// The harness's tmux.
    let base: any HarnessTmux

    /// Where tmux runs.
    var location: String { base.location }

    /// `tmux -V`.
    func version() async -> String? { await base.version() }

    /// `new-session -d -P -F <format> -s <name> sleep 600`.
    func createSession(named name: String) async throws -> CreatedSession {
      let made = try await base.run([
        "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", name, "sleep", "600",
      ])
      guard made.succeeded, made.lines.count == 1, let record = CreatedSession.parse(made.lines[0]),
        record.name == name
      else {
        throw ProfileRunFailure(
          "new-session failed: \(ErrorClassifier.firstLine(of: Data(made.standardError.utf8)))")
      }
      return record
    } // End of func createSession(named:)

    /// The one session named exactly `name` in `list-sessions`, or `nil` (also with no server).
    func findSession(named name: String) async throws -> CreatedSession? {
      let listing = try await base.run(["list-sessions", "-F", CreatedSession.format])
      guard listing.succeeded else {
        let first = listing.standardError.split(separator: "\n").first.map(String.init) ?? ""
        if listing.status == 1, ErrorClassifier.isNoServerMessage(first) { return nil }
        throw ProfileRunFailure("list-sessions failed")
      }
      let matches = listing.lines.compactMap(CreatedSession.parse).filter { $0.name == name }
      guard matches.count <= 1 else {
        throw ProfileRunFailure("several sessions are named \(name)")
      }
      return matches.first
    } // End of func findSession(named:)

    /// The one-command conditional kill.
    func killIfUnchanged(_ record: CreatedSession) async throws -> CreatedSession.KillOutcome {
      guard record.name == PersistentProfileRun.sessionName,
        let arguments = record.killIfUnchangedArguments
      else { return .notThisSession }
      let result = try await base.run(arguments)
      guard !result.timedOut else { return .failed }
      return CreatedSession.killOutcome(
        exitStatus: result.status, standardOutput: result.standardOutput,
        standardError: result.standardError)
    } // End of func killIfUnchanged(_:)
  } // End of struct Tmux

  /// Runs the subcommand and returns the exit status: 0 when every step passed.
  static func run(_ arguments: [String]) async -> Int32 {
    let kind: PersistentProfileRun.Kind
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
        "muxfinder-probe: e2e-profile takes --local or --ssh <destination>\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    guard ProcessInfo.processInfo.environment["TMUX_TMPDIR"] == nil else {
      printError(
        "muxfinder-probe: unset TMUX_TMPDIR; muxfinder-launch in iTerm2 always uses the default "
          + "tmux server")
      return EX_USAGE
    }
    let helper: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helper = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_UNAVAILABLE
    }
    let base: any HarnessTmux
    var localTmuxPath: String?
    switch kind {
    case .local:
      guard let tmux = TestTmux.locate() else {
        printError("muxfinder-probe: tmux was not found")
        return EX_UNAVAILABLE
      }
      base = tmux
      localTmuxPath = tmux.path
    case .remote(let destination):
      base = RemoteTestTmux(destination: destination)
    }
    let client = ITerm2APIClient()
    let snapshotter = ITerm2ProfileSnapshotter()
    let parts = PersistentProfileRun.Parts(
      iTerm2: client, installer: PersistentProfileInstaller(),
      snapshot: { try await snapshotter.snapshot() }, store: LaunchStore(),
      tmux: Tmux(base: base), discovery: DiscoveryProbe(), clock: SystemAttachClock(),
      output: output)
    let harness = PersistentProfileRun(
      kind: kind, helper: helper, localTmuxPath: localTmuxPath, parts: parts)
    let status = await run(harness, tmux: base)
    await client.disconnect()
    return status
  } // End of func run(_:)

  /// Writes `line` to standard output at once (unbuffered, so lines appear as steps end).
  @Sendable static func output(_ line: String) {
    FileHandle.standardOutput.write(Data((line + "\n").utf8))
  }

  /// The header, the steps raced against signals and the overall limit, cleanup and the
  /// summary. Returns 0 when every step passed, 128 + n after signal n, 1 otherwise.
  static func run(_ harness: PersistentProfileRun, tmux: any HarnessTmux) async -> Int32 {
    let watcher = SignalWatcher()
    let started = ContinuousClock.now
    let version = await tmux.version()
    output(
      "\(harness.name): macOS \(ProcessInfo.processInfo.operatingSystemVersionString), "
        + "\(version ?? "tmux unknown") \(tmux.location), helper \(harness.helper.path), "
        + "session \(PersistentProfileRun.sessionName)")
    let steps = Task { await harness.runSteps() }
    let ending = await E2ECommand.waitForEnding(of: steps, watcher: watcher, limit: overallLimit)
    switch ending {
    case .finished: break
    case .signal(let number): output("Interrupted by signal \(number); cleaning up.")
    case .timeLimit: output("The run took longer than \(overallLimit); cleaning up.")
    }
    await steps.value
    await Task { await harness.cleanUp() }.value
    watcher.stop()
    let passed = await harness.passedCount
    let total = milliseconds(ContinuousClock.now - started)
    output(
      "\(harness.name): \(passed) of \(PersistentProfileRun.stepCount) steps passed in "
        + "\(String(format: "%.1f", Double(total) / 1000)) s")
    if case .signal(let number) = ending { return 128 + number }
    return passed == PersistentProfileRun.stepCount && ending == .finished ? 0 : 1
  } // End of func run(_:tmux:)
}
