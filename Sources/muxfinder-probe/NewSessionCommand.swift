import Foundation
import MuxFinderCore

/// `muxfinder-probe new-session --local | --ssh <destination> --name <name> [--dir <dir>]`:
/// creates a detached session on the default tmux server of this Mac or of a remote host
/// (noninteractive; over ssh with BatchMode, a static script and quoted arguments, PLAN.md D18)
/// and attaches it through the real path, the way the app's "New session" does, then prints
/// the outcome as JSON. It opens a real iTerm2 window and leaves the session attached. A
/// session created a moment ago cannot be attached anywhere yet, so, unlike `attach`, it asks
/// none of iTerm2's tmux connections anything.
enum NewSessionCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      new-session --local | --ssh <destination> --name <name> [--dir <directory>]
                  [--tmux-path <path>] [--profile <name>]
          Create a detached tmux session on the default server of this Mac (--local) or of a
          remote host (--ssh; noninteractive, BatchMode) and attach it in a new iTerm2 window,
          the way the app does; print the outcome as JSON (state changes go to stderr). An
          existing session with that name is never replaced or attached (sessionExists).
          Opens a real iTerm2 window and leaves the session attached; detach it from tmux.
          --name       The new session's name (validated before anything runs).
          --dir        Its working directory; ~ and ~/… are taken from the home directory on
                       the host, and a missing directory creates nothing. Default: home.
          --tmux-path  Use this tmux executable only (the host's override).
          --profile    Open the tab with this iTerm2 profile instead of the default one.
    """

  /// Runs the subcommand with the arguments after `new-session` and returns the exit status:
  /// 0 when the new session is attached.
  static func run(_ arguments: [String]) async -> Int32 {
    let request: NewSessionRequest
    do {
      request = try parse(arguments)
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
    let client = ITerm2APIClient()
    let coordinator = AttachCoordinator(
      iTerm2: client, discovery: DiscoveryProbe(), store: LaunchStore(), helperPath: helperPath,
      onUpdate: { update in printError("state: \(update.state.kind)") })
    let result = await coordinator.createAndAttach(request)
    await client.disconnect()
    guard ITerm2Command.printJSON(Output(result)) else { return EX_SOFTWARE }
    return result.isAttached ? 0 : 1
  } // End of func run(_:)

  /// Parses the subcommand's arguments into a request (validated later, by `TmuxCommands`).
  static func parse(_ arguments: [String]) throws -> NewSessionRequest {
    var mode: HostConfig.ConnectionMode?
    var destination = ""
    var name: String?
    var directory: String?
    var tmuxPath: String?
    var profile: String?
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--local", "--ssh":
        guard mode == nil else {
          throw DiscoverCommand.UsageError(message: "use either --local or --ssh")
        }
        if argument == "--ssh" {
          guard let value = remaining.popFirst() else {
            throw DiscoverCommand.UsageError(message: "--ssh needs a destination")
          }
          destination = value
        }
        mode = argument == "--ssh" ? .ssh : .local
      case "--name":
        guard let value = remaining.popFirst() else {
          throw DiscoverCommand.UsageError(message: "--name needs a session name")
        }
        name = value
      case "--dir":
        guard let value = remaining.popFirst() else {
          throw DiscoverCommand.UsageError(message: "--dir needs a directory")
        }
        directory = value
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
    guard let mode else { throw DiscoverCommand.UsageError(message: "use --local or --ssh") }
    guard let name else { throw DiscoverCommand.UsageError(message: "--name is required") }
    let host = HostConfig(
      displayName: mode == .local ? "This Mac" : "Remote host", mode: mode,
      sshDestination: destination, tmuxPathOverride: tmuxPath, iTermProfileName: profile)
    return NewSessionRequest(host: host, name: name, workingDirectory: directory)
  } // End of func parse(_:)

  /// A create-and-attach result as JSON: ids, kinds and timings; never names, paths or titles.
  struct Output: Encodable {
    /// The created session's id, when it was created.
    let createdSessionID: String?
    /// The created session's creation time (seconds since 1970).
    let createdAt: Int64?
    /// The created session's server pid.
    let serverPID: Int32?
    /// Why creation failed, when it did.
    let creationFailure: CreationFailureOutput?
    /// The attach, when creation succeeded.
    let attach: AttachCommand.AttachOutput?
    /// Whether the host's session list should be refreshed now.
    let triggersRefresh: Bool

    /// Converts a result.
    init(_ result: CreateAndAttachResult) {
      createdSessionID = result.created?.sessionID.rawValue
      createdAt = result.created?.createdAt
      serverPID = result.created?.server.pid
      creationFailure = result.creationFailure.map(CreationFailureOutput.init)
      attach = result.attach.map(AttachCommand.AttachOutput.init)
      triggersRefresh = result.triggersRefresh
    }
  } // End of struct Output

  /// A creation failure as JSON.
  struct CreationFailureOutput: Encodable {
    /// `SessionCreationError.kind`.
    let kind: String
    /// `SessionCreationError.detail`.
    let detail: String?
    /// `SessionCreationError.message`.
    let message: String
    /// `SessionCreationError.mayHaveCreated`.
    let mayHaveCreated: Bool

    /// Converts a failure.
    init(_ failure: SessionCreationError) {
      kind = failure.kind
      detail = failure.detail
      message = failure.message
      mayHaveCreated = failure.mayHaveCreated
    }
  } // End of struct CreationFailureOutput
}
