import AppKit
import Foundation
import MuxFinderCore

/// `muxfinder-probe attach --local | --ssh <destination> --session <$id>`: attaches one session
/// of the default tmux server of this Mac or of a remote host through the real path
/// (discovery, the existing-attachment check, launch request, a new iTerm2 window running
/// `muxfinder-launch`, which runs tmux or `ssh -t`, connection confirmation, identity check,
/// activation) and prints the outcome as JSON. It opens a real iTerm2 window and leaves the
/// session attached, or brings forward the tab of an existing attachment of the session. It
/// runs on the terminal seam: `ITerm2TerminalBackend` over the attach coordinator.
///
/// With `--terminal <id>` other than `iterm2` (PLAN.md D38, Phase I-12c3a) it attaches through
/// `PlainTerminalBackend` instead: definitions load as `terminals list` loads them, and before
/// anything is written, opened or sent it applies *Unattended-run rules* 8 itself
/// (`PlainRunGate`): the app must run and, for an AppleScript definition, its Automation
/// permission must read granted without a prompt; otherwise it exits 2 with the reason. The
/// window layer checks the same again right before the request write and every Apple event or
/// spawn (`PlainRunPolicy.unattended`), also exit 2.
enum AttachCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      attach --local | --ssh <destination> --session <$id> [--tmux-path <path>]
             [--profile <name>]
             [--terminal <id> [--builtin-directory <dir>] [--user-directory <dir>]]
          Attach one session of the default tmux server of this Mac (--local) or of a remote
          host (--ssh; the launch tab runs ssh -t there, so a password prompt appears in it)
          in a new iTerm2 window, the way the app does, and print the outcome as JSON (state
          changes go to stderr). Opens a real iTerm2 window and leaves the session attached;
          detach it from tmux. First asks every iTerm2 tmux connection which session it shows
          (a read-only display-message); when one shows this session, its tab is brought
          forward instead and nothing opens (state focused).
          --session    The session's id, such as '$3' (quote it for the shell).
          --tmux-path  Use this tmux executable only (the host's override).
          --profile    Open the tab with this iTerm2 profile instead of the default one.
          --terminal   iterm2 (the default, as above) or a terminal definition's id, such as
                       terminal or ghostty: attach in a new window of that app with a plain
                       tmux client, as the app does with that terminal chosen, and print the
                       result as JSON with the client record a bound detach needs. Definitions
                       load as for terminals list (--builtin-directory, --user-directory).
                       Before anything is written, opened or sent, and again right before
                       the request is written and each Apple event or start: the app must be
                       running and, for an AppleScript definition, its Automation permission
                       must read granted without a prompt (Unattended-run rules 8); otherwise
                       exit 2 with the reason. A session that is open in a terminal on this
                       Mac already is brought forward instead (state appFocused).
      detach --connection <id> --gateway <session id> [--launch-id <uuid>]
          Send detach-client on one iTerm2 tmux connection, wait for it to close and print
          the outcome as JSON. The ids come from attach's JSON (connectionID and
          gatewaySessionID): the command is sent only if iTerm2 still lists the connection as
          owned by that launch tab. It first waits 10 s, because a launch tab ending sooner
          after it opened makes iTerm2 show a blocking warning, and this process cannot know
          when the tab opened. With --launch-id, also wait for that launch's helper result (a
          clean detach exits 0).
    """

  /// The exit status of a plain run refused before anything happened (an unknown definition,
  /// or *Unattended-run rules* 8).
  static let refusedStatus: Int32 = 2

  /// Runs the subcommand with the arguments after `attach` and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    let options: AttachCommandOptions
    do throws(AttachCommandUsageError) {
      switch try AttachCommandOptions.parse(arguments) {
      case .help:
        print("usage:\n\(usage)")
        return 0
      case .attach(let parsed):
        options = parsed
      }
    } catch {
      printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    if case .plain(let definitionID) = options.terminal {
      return await runPlain(options, definitionID: definitionID)
    }
    let helperPath: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_UNAVAILABLE
    }
    let discovery = DiscoveryProbe()
    let found: DiscoveredSession
    switch await discover(options, with: discovery) {
    case .success(let session): found = session
    case .failure(let status): return status.code
    }
    let client = ITerm2APIClient()
    let backend = ITerm2TerminalBackend(
      coordinator: AttachCoordinator(
        iTerm2: client, discovery: discovery, store: LaunchStore(), helperPath: helperPath,
        onUpdate: { update in printError("state: \(update.state.kind)") }))
    let result = await backend.attach(AttachTarget(host: options.host, session: found))
    await client.disconnect()
    guard ITerm2Command.printJSON(AttachOutput(result)) else { return EX_SOFTWARE }
    return result.isAttached ? 0 : 1
  } // End of func run(_:)

  /// An exit status as an error.
  struct ExitStatus: Error {
    /// The status.
    let code: Int32
  }

  /// The session `options` names, as discovery lists it now (read-only), or the exit status
  /// after printing why there is none.
  static func discover(
    _ options: AttachCommandOptions,
    with discovery: DiscoveryProbe
  ) async -> Result<DiscoveredSession, ExitStatus> {
    do {
      let result = try await discovery.discover(options.host)
      guard
        let session = result.status.sessions.first(where: { $0.key.sessionID == options.sessionID })
      else {
        printError("muxfinder-probe: no session \(options.sessionID) (\(result.status.kind))")
        return .failure(ExitStatus(code: EX_UNAVAILABLE))
      }
      return .success(session)
    } catch {
      printError("muxfinder-probe: discovery was cancelled")
      return .failure(ExitStatus(code: EX_SOFTWARE))
    }
  } // End of static func discover(_:with:)

  /// `attach --terminal <id>` for a plain definition: loads the definitions, applies
  /// *Unattended-run rules* 8 (`PlainRunGate`, exit 2 with the reason, nothing written, opened
  /// or sent), then discovers the session and attaches it through `PlainTerminalBackend` over
  /// the real window layer with the `unattended` policy (the gate again right before the
  /// request is written and before every Apple event or spawn; a refusal there also exits 2,
  /// its request withdrawn), with This Mac's client attributor as the app passes it.
  static func runPlain(_ options: AttachCommandOptions, definitionID: String) async -> Int32 {
    let builtIn =
      options.builtInDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? TerminalsCommand.repositoryBuiltInDirectory()
    let user =
      options.userDirectory.map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? AppPaths.standard.terminalDefinitionsDirectory
    let catalog = TerminalDefinitionLoader(builtInDirectory: builtIn, userDirectory: user).load()
    guard let loaded = catalog.definition(withID: definitionID) else {
      printError(
        "muxfinder-probe: no usable terminal definition \(definitionID) "
          + "(\(catalog.definitions.count) loaded, \(catalog.problems.count) problems)")
      return refusedStatus
    }
    let facts = await MainActor.run { TerminalAppFacts.read(for: loaded.definition) }
    if let refusal = PlainRunGate.check(loaded.definition, facts: facts) {
      printError("muxfinder-probe: not attaching in \(definitionID): \(refusal.message)")
      return refusedStatus
    }
    let helperPath: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_UNAVAILABLE
    }
    let discovery = DiscoveryProbe()
    let found: DiscoveredSession
    switch await discover(options, with: discovery) {
    case .success(let session): found = session
    case .failure(let status): return status.code
    }
    // The gate again at every side effect: the app may quit, or its permission change, while
    // discovery runs (`PlainRunPolicy.unattended`).
    let windows = await MainActor.run {
      PlainTerminalWindows(
        runner: NSAppleScriptRunner(), inspector: WorkspaceTerminalAppInspector(),
        spawner: DetachedTerminalProcessSpawner(), activator: RunningApplicationActivator(),
        policy: .unattended)
    }
    let backend = PlainTerminalBackend(
      loaded: loaded, windows: windows, helperPath: helperPath, store: LaunchStore(),
      discovery: discovery,
      localClients: LocalClientAttributor(definitions: catalog.definitions),
      onUpdate: { update in printError("state: \(update.state.kind)") })
    let result = await backend.attach(AttachTarget(host: options.host, session: found))
    if let refusal = PlainRunGate.refusal(of: result) {
      printError("muxfinder-probe: not attaching in \(definitionID): \(refusal.message)")
      return refusedStatus
    }
    guard ITerm2Command.printJSON(AttachOutput(result)) else { return EX_SOFTWARE }
    return result.isAttached ? 0 : 1
  } // End of static func runPlain(_:definitionID:)

  /// Runs `detach` with the arguments after it and returns the exit status: 0 when the
  /// connection closed.
  static func runDetach(_ arguments: [String]) async -> Int32 {
    var connectionID: String?
    var gatewaySessionID: String?
    var launchID: LaunchToken?
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--connection":
        connectionID = remaining.popFirst()
      case "--gateway":
        gatewaySessionID = remaining.popFirst()
      case "--launch-id":
        guard let value = remaining.popFirst(), let token = LaunchToken(value) else {
          printError("muxfinder-probe: --launch-id needs a lowercase launch id\n\nusage:\n\(usage)")
          return EX_USAGE
        }
        launchID = token
      default:
        printError("muxfinder-probe: unknown option\n\nusage:\n\(usage)")
        return EX_USAGE
      }
    } // End of loop over arguments
    guard let connectionID, !connectionID.isEmpty else {
      printError("muxfinder-probe: --connection is required\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    guard let gatewaySessionID, !gatewaySessionID.isEmpty else {
      printError("muxfinder-probe: --gateway is required\n\nusage:\n\(usage)")
      return EX_USAGE
    }
    let helperPath: LaunchHelperPath
    do throws(LaunchHelperPathError) {
      helperPath = try LaunchHelperPath.locate()
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_UNAVAILABLE
    }
    let client = ITerm2APIClient()
    let coordinator = AttachCoordinator(
      iTerm2: client, discovery: DiscoveryProbe(), store: LaunchStore(), helperPath: helperPath)
    let wait = AttachCoordinator.Configuration().minimumLaunchTabAge
    printError("detach: waiting \(wait) so the launch tab is old enough")
    let result = await coordinator.detach(
      connectionID: connectionID, gatewaySessionID: gatewaySessionID, launchID: launchID)
    await client.disconnect()
    guard ITerm2Command.printJSON(DetachOutput(result)) else { return EX_SOFTWARE }
    return result.connectionClosed ? 0 : 1
  } // End of func runDetach(_:)

  /// An attach result as JSON: ids, states, kinds and timings; never names or titles. A plain
  /// result adds its window, its client record and the app it found the session open in
  /// (absent for iTerm2, so today's output is unchanged).
  struct AttachOutput: Encodable {
    /// `confirmed`, `focused` or `failed`.
    let state: String
    /// The failure, when failed.
    let failure: FailureOutput?
    /// The tmux session id.
    let sessionID: String
    /// The launch id.
    let launchID: String
    /// The launch tab's iTerm2 session.
    let gatewaySessionID: String?
    /// The tmux connection.
    let connectionID: String?
    /// `activated`, `noTab` or `failed`.
    let activation: String?
    /// The activated tab.
    let activatedTabID: String?
    /// What became of the launch tab (PLAN.md D29): `buried`, `skipped`, `failed`, `uncertain`
    /// or `restoredAfterEnd`, with its detail; absent unless confirmed.
    let burial: String?
    /// What the existing-attachment check found, by kind; absent when it did not run.
    let existingAttachments: AttachmentSnapshot.Counts?
    /// Milliseconds from the start of the attach to each step.
    let timingsMs: [String: Int]
    /// Plain backend: the window it opened or brought forward.
    let plainWindow: PlainWindowOutput?
    /// Plain backend: the confirmed client, as a bound detach needs it.
    let plainClient: PlainClientOutput?
    /// Plain backend: how bringing the window forward went (`TerminalFocusResult.kind`).
    let plainWindowFocus: String?
    /// Plain backend, `appFocused`: the app the session was found open in on this Mac.
    let appFocused: AppFocusOutput?

    /// Converts a result.
    init(_ result: AttachResult) {
      state = result.state.kind
      failure = result.failure.map(FailureOutput.init)
      sessionID = result.key.sessionID.rawValue
      launchID = result.launchID.rawValue
      gatewaySessionID = result.gatewaySessionID
      connectionID = result.connectionID
      existingAttachments = result.existingAttachments
      burial = result.burial.map { burial in
        burial.kind + (burial.detail.map { " (\($0))" } ?? "")
      }
      switch result.activation {
      case .activated(let tabID)?:
        activation = "activated"
        activatedTabID = tabID
      case .noTab?:
        activation = "noTab"
        activatedTabID = nil
      case .failed(let error)?:
        activation = "failed: \(error.errorDescription ?? error.kind)"
        activatedTabID = nil
      case nil:
        activation = nil
        activatedTabID = nil
      }
      timingsMs = Self.milliseconds(result.timings)
      plainWindow = result.plainWindow.map(PlainWindowOutput.init)
      plainClient = result.plainClient.map(PlainClientOutput.init)
      plainWindowFocus = result.plainWindowFocus?.kind
      appFocused = result.localAttachment.map { local in
        AppFocusOutput(
          bundleIdentifier: local.app.bundleIdentifier, definitionIDs: local.app.definitionIDs,
          activation: result.appActivation?.rawValue)
      }
    } // End of init(_:)

    /// The timings that were reached, in milliseconds.
    static func milliseconds(_ timings: AttachTimings) -> [String: Int] {
      let steps: [(String, Duration?)] = [
        ("revalidated", timings.revalidated), ("checked", timings.checked),
        ("launched", timings.launched),
        ("connected", timings.connected), ("confirmed", timings.confirmed),
        ("activated", timings.activated), ("buried", timings.buried),
        ("finished", timings.finished),
      ]
      var output: [String: Int] = [:]
      for (name, duration) in steps {
        if let duration { output[name] = Int(duration / .milliseconds(1)) }
      }
      return output
    } // End of func milliseconds(_:)
  } // End of struct AttachOutput

  /// A plain window as JSON: the definition that opened it and what its app reported.
  struct PlainWindowOutput: Encodable {
    /// The definition's id.
    let definitionID: String
    /// The window's id, when reported.
    let windowID: String?
    /// The window's terminal device, when reported.
    let tty: String?

    /// Converts a window.
    init(_ window: PlainTerminalWindow) {
      definitionID = window.definitionID
      windowID = window.windowID
      tty = window.tty
    }
  } // End of struct PlainWindowOutput

  /// A confirmed plain client as JSON: what D38's bound detach checks (the session by id,
  /// server and creation time; the client by name, pid and creation time) and the launch; never
  /// the session's name or socket path.
  struct PlainClientOutput: Encodable {
    /// The session's id.
    let sessionID: String
    /// The session's server pid.
    let serverPID: Int32
    /// The session's server start time (seconds since 1970).
    let serverStartTime: Int64
    /// The session's creation time (seconds since 1970).
    let sessionCreatedAt: Int64
    /// The client's name (its terminal on the host).
    let clientName: String
    /// The client's pid.
    let clientPID: Int32
    /// The client's creation time (seconds since 1970).
    let clientCreatedAt: Int64
    /// The launch id.
    let launchID: String
    /// SSH hosts: the token found at the end of the client's parent shell's arguments.
    let token: String?
    /// This Mac: the terminal the helper's early report named.
    let terminalPath: String?

    /// Converts a record.
    init(_ record: PlainClientRecord) {
      sessionID = record.session.sessionID.rawValue
      serverPID = record.session.serverPID
      serverStartTime = record.session.serverStartTime
      sessionCreatedAt = record.session.createdAt
      clientName = record.client.name
      clientPID = record.client.processID
      clientCreatedAt = record.client.created
      launchID = record.launchID.rawValue
      token = record.token?.rawValue
      terminalPath = record.terminalPath
    } // End of init(_:)
  } // End of struct PlainClientOutput

  /// The app a plain attach brought forward instead of opening a window (open on this Mac).
  struct AppFocusOutput: Encodable {
    /// The app's bundle identifier.
    let bundleIdentifier: String
    /// The loaded definitions sharing it.
    let definitionIDs: [String]
    /// `activated`, `notRunning` or `refused`.
    let activation: String?
  }

  /// A detach result as JSON.
  struct DetachOutput: Encodable {
    /// The connection.
    let connectionID: String
    /// Whether the connection closed in time.
    let connectionClosed: Bool
    /// The `detach-client` request's error kind, if any.
    let commandError: String?
    /// The connection listing's error kind, if any.
    let pollError: String?
    /// The helper's exit status, when its result arrived.
    let helperExitStatus: Int32?
    /// The helper's failure kind, when it reported one.
    let helperFailure: String?
    /// Whether the detach was clean (closed, and the helper reported exit 0).
    let clean: Bool

    /// Converts a result.
    init(_ result: DetachResult) {
      connectionID = result.connectionID
      connectionClosed = result.connectionClosed
      commandError = result.commandError?.kind
      pollError = result.pollError?.kind
      helperExitStatus = result.helperResult?.exitStatus
      helperFailure = result.helperResult?.failure?.kind
      clean = result.isClean
    }
  } // End of struct DetachOutput

  /// A failure as JSON.
  struct FailureOutput: Encodable {
    /// `AttachFailure.kind`.
    let kind: String
    /// `AttachFailure.detail`.
    let detail: String?
    /// `AttachFailure.message`.
    let message: String

    /// Converts a failure.
    init(_ failure: AttachFailure) {
      kind = failure.kind
      detail = failure.detail
      message = failure.message
    }
  }
}
