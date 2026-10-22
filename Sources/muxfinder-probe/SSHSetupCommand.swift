import Foundation
import MuxFinderCore

/// `muxfinder-probe ssh-setup --ssh <destination> [--profile <name>]`: "Set up SSH in iTerm2…"
/// the way the app does it (PLAN.md D24): `SSHSetupLauncher` writes an ssh setup request and
/// opens a launch tab in a new iTerm2 window whose helper runs plain interactive
/// `/usr/bin/ssh -- <destination>`. It prints how the opening went as JSON and leaves the tab
/// to the user (ssh may ask for a password or a host key answer there). Real-run only: it opens
/// a real iTerm2 window and starts a real ssh login.
enum SSHSetupCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      ssh-setup --ssh <destination> [--profile <name>]
          Open a new iTerm2 window running plain interactive ssh to the destination (the app's
          "Set up SSH in iTerm2…"); print how the opening went as JSON. Opens a real iTerm2
          window and starts a real ssh login there; close the tab when done.
          --profile  Open the tab with this iTerm2 profile instead of the default one.
    """

  /// Runs the subcommand with the arguments after `ssh-setup` and returns the exit status: 0
  /// when the tab opened.
  static func run(_ arguments: [String]) async -> Int32 {
    let host: HostConfig
    do {
      host = try parse(arguments)
    } catch let error as DiscoverCommand.UsageError {
      printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return EX_USAGE
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_USAGE
    }
    let client = ITerm2APIClient()
    let launcher = SSHSetupLauncher(iTerm2: client, store: LaunchStore())
    let result = await launcher.openSSHSetup(for: host)
    await client.disconnect()
    guard ITerm2Command.printJSON(Output(result)) else { return EX_SOFTWARE }
    if case .opened = result { return 0 }
    return 1
  } // End of func run(_:)

  /// Parses the subcommand's arguments into a host (its destination is validated by the
  /// launcher before anything runs).
  static func parse(_ arguments: [String]) throws -> HostConfig {
    var destination: String?
    var profile: String?
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--ssh":
        guard let value = remaining.popFirst() else {
          throw DiscoverCommand.UsageError(message: "--ssh needs a destination")
        }
        destination = value
      case "--profile":
        guard let value = remaining.popFirst(), !value.isEmpty else {
          throw DiscoverCommand.UsageError(message: "--profile needs a profile name")
        }
        profile = value
      default:
        throw DiscoverCommand.UsageError(message: "unknown option")
      }
    } // End of loop over arguments
    guard let destination else { throw DiscoverCommand.UsageError(message: "--ssh is required") }
    return HostConfig(
      displayName: "Remote host", mode: .ssh, sshDestination: destination,
      iTermProfileName: profile)
  } // End of func parse(_:)

  /// The opening as JSON: the tab's session id or the failure's kind and message; never the
  /// destination.
  struct Output: Encodable {
    /// Whether the tab opened.
    let opened: Bool
    /// The tab's iTerm2 session id, when it opened.
    let sessionID: String?
    /// `SSHSetupFailure.kind`, when it did not.
    let failure: String?
    /// `SSHSetupFailure.message`, when it did not.
    let message: String?

    /// Converts a result.
    init(_ result: SSHSetupResult) {
      switch result {
      case .opened(let sessionID):
        (opened, self.sessionID, failure, message) = (true, sessionID, nil, nil)
      case .failed(let reason):
        (opened, sessionID, failure, message) = (false, nil, reason.kind, reason.message)
      }
    }
  } // End of struct Output
}
