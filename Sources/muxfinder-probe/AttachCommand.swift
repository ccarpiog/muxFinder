import Foundation
import MuxFinderCore

/// `muxfinder-probe attach --local --session <$id>`: attaches one session of this Mac's default
/// tmux server through the real path (discovery, launch request, a new iTerm2 window running
/// `muxfinder-launch`, connection confirmation, identity check, activation) and prints the
/// outcome as JSON. It opens a real iTerm2 window and leaves the session attached.
enum AttachCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      attach --local --session <$id> [--tmux-path <path>] [--profile <name>]
          Attach one session of this Mac's default tmux server in a new iTerm2 window, the
          way the app does, and print the outcome as JSON (state changes go to stderr). Opens
          a real iTerm2 window and leaves the session attached; detach it from tmux.
          --session    The session's id, such as '$3' (quote it for the shell).
          --tmux-path  Use this tmux executable only (the host's override).
          --profile    Open the tab with this iTerm2 profile instead of the default one.
      detach --connection <id> --gateway <session id> [--launch-id <uuid>]
          Send detach-client on one iTerm2 tmux connection, wait for it to close and print
          the outcome as JSON. The ids come from attach's JSON (connectionID and
          gatewaySessionID): the command is sent only if iTerm2 still lists the connection as
          owned by that launch tab. It first waits 10 s, because a launch tab ending sooner
          after it opened makes iTerm2 show a blocking warning, and this process cannot know
          when the tab opened. With --launch-id, also wait for that launch's helper result (a
          clean detach exits 0).
    """

  /// Parsed options.
  struct Options {
    /// The session to attach.
    var sessionID: TmuxSessionID
    /// The host, "This Mac".
    var host: HostConfig
  }

  /// Runs the subcommand with the arguments after `attach` and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    let options: Options
    do {
      options = try parse(arguments)
    } catch let error as DiscoverCommand.UsageError {
      printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return EX_USAGE
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_USAGE
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
    do {
      let result = try await discovery.discover(options.host)
      guard
        let session = result.status.sessions.first(where: { $0.key.sessionID == options.sessionID })
      else {
        printError("muxfinder-probe: no session \(options.sessionID) (\(result.status.kind))")
        return EX_UNAVAILABLE
      }
      found = session
    } catch {
      printError("muxfinder-probe: discovery was cancelled")
      return EX_SOFTWARE
    }
    let client = ITerm2APIClient()
    let coordinator = AttachCoordinator(
      iTerm2: client, discovery: discovery, store: LaunchStore(), helperPath: helperPath,
      onUpdate: { update in printError("state: \(update.state.kind)") })
    let result = await coordinator.attach(AttachTarget(host: options.host, session: found))
    await client.disconnect()
    guard ITerm2Command.printJSON(AttachOutput(result)) else { return EX_SOFTWARE }
    return result.isConfirmed ? 0 : 1
  } // End of func run(_:)

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

  /// Parses the subcommand's arguments.
  static func parse(_ arguments: [String]) throws -> Options {
    var local = false
    var sessionID: TmuxSessionID?
    var tmuxPath: String?
    var profile: String?
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--local":
        local = true
      case "--session":
        guard let value = remaining.popFirst(), let id = TmuxSessionID(value) else {
          throw DiscoverCommand.UsageError(message: "--session needs an id such as '$3'")
        }
        sessionID = id
      case "--tmux-path":
        guard let value = remaining.popFirst() else {
          throw DiscoverCommand.UsageError(message: "--tmux-path needs a path")
        }
        tmuxPath = value
      case "--profile":
        guard let value = remaining.popFirst(), !value.isEmpty else {
          throw DiscoverCommand.UsageError(message: "--profile needs a profile name")
        }
        profile = value
      default:
        throw DiscoverCommand.UsageError(message: "unknown option")
      }
    } // End of loop over arguments
    guard local else {
      throw DiscoverCommand.UsageError(message: "only --local is supported so far")
    }
    guard let sessionID else { throw DiscoverCommand.UsageError(message: "--session is required") }
    let host = HostConfig(
      displayName: "This Mac", mode: .local, tmuxPathOverride: tmuxPath, iTermProfileName: profile)
    return Options(sessionID: sessionID, host: host)
  } // End of func parse(_:)

  /// An attach result as JSON: ids, states, kinds and timings; never names or titles.
  struct AttachOutput: Encodable {
    /// `confirmed` or `failed`.
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
    /// Milliseconds from the start of the attach to each step.
    let timingsMs: [String: Int]

    /// Converts a result.
    init(_ result: AttachResult) {
      state = result.state.kind
      failure = result.failure.map(FailureOutput.init)
      sessionID = result.key.sessionID.rawValue
      launchID = result.launchID.rawValue
      gatewaySessionID = result.gatewaySessionID
      connectionID = result.connectionID
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
    } // End of init(_:)

    /// The timings that were reached, in milliseconds.
    static func milliseconds(_ timings: AttachTimings) -> [String: Int] {
      let steps: [(String, Duration?)] = [
        ("revalidated", timings.revalidated), ("launched", timings.launched),
        ("connected", timings.connected), ("confirmed", timings.confirmed),
        ("activated", timings.activated), ("finished", timings.finished),
      ]
      var output: [String: Int] = [:]
      for (name, duration) in steps {
        if let duration { output[name] = Int(duration / .milliseconds(1)) }
      }
      return output
    } // End of func milliseconds(_:)
  } // End of struct AttachOutput

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
