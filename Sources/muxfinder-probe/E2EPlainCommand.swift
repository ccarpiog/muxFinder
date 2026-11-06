import Foundation
import MuxFinderCore

/// `muxfinder-probe e2e-plain --terminal <id> --local | --ssh saturno-m4`: the real run of the
/// plain backend in a terminal app other than iTerm2 (PLAN.md D38 *The plain runs
/// (I-12c3b)*). It opens real windows of that app, so it only runs when asked for, never from
/// `swift test`. The arguments, the gate, the steps and the cleanup are the core's
/// (`E2EPlainOptions`, `E2EPlainRun`, tested hermetically); this file loads the definitions as
/// `terminals list` does, applies *Unattended-run rules* 8 before anything else, wires the real
/// parts (the window layer with the `unattended` run policy, so the gate is checked again
/// before every open, focus and close) and races the steps against signals and a watchdog.
enum E2EPlainCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      e2e-plain --terminal <id> --local | --ssh saturno-m4
                [--builtin-directory <dir>] [--user-directory <dir>]
          Real check of the plain backend in a terminal app other than iTerm2 (PLAN.md D38):
          opens windows of that app. First, before anything is created, written, discovered or
          sent: the app must be running and, for an AppleScript definition, its Automation
          permission must read granted without a prompt (Unattended-run rules 8); otherwise it
          prints the reason and the command owed to the user and exits 2. The window layer
          checks the same again before every open, focus and close. Then (9 steps): creates
          muxfinder-test-<random> (one window running sleep 600) on the default tmux server of
          this Mac or of saturno-m4 (over ssh with BatchMode); discovers it; opens it in a new
          window (confirmed from the helper's report and tmux's clients, or the launch token
          remotely); opens it again (its window brought forward, nothing opened); detaches it
          with the bound detach and closes that window by its recorded id once its helper
          ended; Move here over a plain control client of its own (tmux -u -C), a move here
          confirmed for another session running nothing; Detach other clients over a second
          one (once it is 10 s old); detaches again and closes that window. Prints a PASS or
          FAIL line per step. Cleans up after itself (ends its control clients, detaches its
          own client, kills only its own session, asks its own helpers that still run to stop
          with SIGTERM, closes only its own windows by recorded id once their process is seen
          ended), also on failure or Ctrl-C. Never types into a window, never launches the
          app, never contacts iTerm2. Exit 0 every step passed, 1 a step
          failed or a signal stopped it, 2 usage or the gate refused, 3 the watchdog.
          --terminal           A terminal definition's id, such as terminal or ghostty (not
                               iterm2: iTerm2 has its own e2e runs).
          --ssh                Only saturno-m4.
          --builtin-directory  --user-directory  Where definitions load from, as for
                               terminals list.
          Needs TMUX_TMPDIR unset. Run swift build first: the window runs the
          muxfinder-launch next to this executable.
    """

  /// How long the whole run may take before the watchdog stops it (exit 3) and cleans up.
  static let overallLimit: Duration = .seconds(300)

  /// Runs the subcommand and returns the exit status (see the usage); `--help` prints the
  /// usage and contacts nothing.
  static func run(_ arguments: [String]) async -> Int32 {
    let options: E2EPlainOptions
    do throws(E2EPlainUsageError) {
      switch try E2EPlainOptions.parse(arguments) {
      case .help:
        print("usage:\n\(usage)")
        return 0
      case .run(let parsed):
        options = parsed
      }
    } catch {
      printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return E2EPlainRun.refusedStatus
    }
    guard ProcessInfo.processInfo.environment["TMUX_TMPDIR"] == nil else {
      printError(
        "muxfinder-probe: unset TMUX_TMPDIR; the helper in the terminal app always uses the "
          + "default tmux server")
      return E2EPlainRun.refusedStatus
    }
    let builtIn =
      options.builtInDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? TerminalsCommand.repositoryBuiltInDirectory()
    let user =
      options.userDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? AppPaths.standard.terminalDefinitionsDirectory
    let catalog = TerminalDefinitionLoader(builtInDirectory: builtIn, userDirectory: user).load()
    let loaded: LoadedTerminalDefinition
    switch options.definition(in: catalog) {
    case .success(let found):
      loaded = found
    case .failure(let refusal):
      printError("muxfinder-probe: \(refusal.message)")
      return E2EPlainRun.refusedStatus
    }
    // Unattended-run rules 8, before anything is created, written, discovered or sent.
    let inspector = WorkspaceTerminalAppInspector()
    if let refusal = await E2EPlainRun.gateRefusal(for: loaded, inspector: inspector) {
      print("\(options.runName): not run: \(refusal.message)")
      print(
        "\(options.runName): nothing was created, written, discovered or sent; owed to the "
          + "user: \(options.owedCommand)")
      return E2EPlainRun.refusedStatus
    }
    return await run(options, loaded: loaded, catalog: catalog, inspector: inspector)
  } // End of func run(_:)

  /// The run itself, once the gate let it go ahead: the real parts, the steps raced against
  /// signals and `overallLimit`, cleanup, the exit status.
  static func run(
    _ options: E2EPlainOptions,
    loaded: LoadedTerminalDefinition,
    catalog: TerminalDefinitionCatalog,
    inspector: WorkspaceTerminalAppInspector
  ) async -> Int32 {
    let helperPath: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return E2EPlainRun.refusedStatus
    }
    let tmux: any HarnessTmux
    switch options.target {
    case .local:
      guard let local = TestTmux.locate() else {
        printError("muxfinder-probe: tmux was not found")
        return E2EPlainRun.refusedStatus
      }
      tmux = local
    case .ssh(let destination):
      tmux = RemoteTestTmux(destination: destination)
    }
    // The gate again at every side effect (open, focus, close, the request's write).
    let windows = await MainActor.run {
      PlainTerminalWindows(
        runner: NSAppleScriptRunner(), inspector: inspector,
        spawner: DetachedTerminalProcessSpawner(), activator: RunningApplicationActivator(),
        policy: .unattended)
    }
    let parts = E2EPlainRun.Parts(
      name: options.runName, owedCommand: options.owedCommand, loaded: loaded,
      host: options.host, tmux: E2EPlainHarnessTmux(base: tmux),
      startControlClient: { command in
        try BackgroundControlClient.start(
          executable: command.executable, arguments: command.arguments,
          environment: command.environment)
      },
      windows: windows, inspector: inspector, helperPath: helperPath, store: LaunchStore(),
      discovery: DiscoveryProbe(),
      localClients: LocalClientAttributor(definitions: catalog.definitions))
    let watcher = SignalWatcher()
    let status = await E2EPlainRun(parts: parts).execute(
      limit: overallLimit, interrupts: watcher.stream)
    watcher.stop()
    return status
  } // End of static func run(_:loaded:catalog:inspector:)
} // End of enum E2EPlainCommand

/// The e2e harness's tmux (`TestTmux` on this Mac, `RemoteTestTmux` over BatchMode ssh) as the
/// core's `E2EPlainHostTmux`.
struct E2EPlainHarnessTmux: E2EPlainHostTmux {
  /// The harness's tmux.
  let base: any HarnessTmux

  /// `base`'s location.
  var location: String { base.location }

  /// `base`'s run, its output carried over unchanged.
  func run(_ arguments: [String]) async throws -> E2EPlainTmuxOutput {
    let output = try await base.run(arguments)
    return E2EPlainTmuxOutput(
      status: output.status, standardOutput: output.standardOutput,
      standardError: output.standardError, timedOut: output.timedOut)
  }

  /// `base`'s `tmux -V`.
  func version() async -> String? {
    await base.version()
  }

  /// `base`'s control client command, unchanged.
  func controlClientCommand(attachingTo name: String) -> E2EPlainProcessCommand {
    let command = base.controlClientCommand(attachingTo: name)
    return E2EPlainProcessCommand(
      executable: command.executable, arguments: command.arguments,
      environment: command.environment)
  }
} // End of struct E2EPlainHarnessTmux

/// The harness's background control client is `e2e-plain`'s control client as it is.
extension BackgroundControlClient: E2EPlainControlClient {}
