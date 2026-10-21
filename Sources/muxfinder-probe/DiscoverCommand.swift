import Foundation
import MuxFinderCore

/// `muxfinder-probe discover`: runs the discovery probe once and prints the classified result as
/// JSON (or, with `--raw`, the probe's raw report).
enum DiscoverCommand {
  /// Usage lines for this subcommand.
  static let usage = """
      discover --local [--tmux-path <path>] [--raw]
      discover --ssh <destination> [--tmux-path <path>] [--strict-known-hosts <file>] [--raw]
          Run the discovery probe once and print the result as JSON.
          --tmux-path           Use this tmux executable only (the host's override).
          --strict-known-hosts  Test harness: StrictHostKeyChecking=yes with <file> as the only
                                known-hosts file, and no connection sharing (ControlPath=none).
                                Stricter than your SSH config, never weaker.
          --raw                 Print the probe's raw report instead of JSON.
    """

  /// Parsed command-line options.
  struct Options {
    /// The host to probe.
    var host: HostConfig
    /// Host-key policy for SSH runs.
    var hostKeyPolicy: DiscoveryProbe.HostKeyPolicy = .userConfiguration
    /// Whether to print the raw report.
    var raw = false
  }

  /// Why the arguments were rejected.
  struct UsageError: Error {
    /// What is wrong, in English.
    let message: String
  }

  /// Runs the subcommand with the arguments after `discover` and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    let options: Options
    do {
      options = try parse(arguments)
    } catch let error as UsageError {
      printError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return EX_USAGE
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_USAGE
    }
    let probe = DiscoveryProbe(hostKeyPolicy: options.hostKeyPolicy)
    do {
      if options.raw { return try await printRawReport(probe: probe, host: options.host) }
      let result = try await probe.discover(options.host)
      print(try json(for: result, host: options.host))
      return 0
    } catch {
      printError("muxfinder-probe: \(error)")
      return EX_SOFTWARE
    }
  } // End of func run(_:)

  /// Parses the subcommand's arguments.
  static func parse(_ arguments: [String]) throws -> Options {
    var mode: HostConfig.ConnectionMode?
    var destination = ""
    var tmuxPath: String?
    var knownHostsFile: String?
    var raw = false
    var remaining = arguments[...]
    while let argument = remaining.popFirst() {
      switch argument {
      case "--local":
        guard mode == nil else { throw UsageError(message: "use either --local or --ssh") }
        mode = .local
      case "--ssh":
        guard mode == nil else { throw UsageError(message: "use either --local or --ssh") }
        guard let value = remaining.popFirst() else {
          throw UsageError(message: "--ssh needs a destination")
        }
        mode = .ssh
        destination = value
      case "--tmux-path":
        guard let value = remaining.popFirst() else {
          throw UsageError(message: "--tmux-path needs a path")
        }
        tmuxPath = value
      case "--strict-known-hosts":
        guard let value = remaining.popFirst() else {
          throw UsageError(message: "--strict-known-hosts needs a file")
        }
        knownHostsFile = value
      case "--raw":
        raw = true
      default:
        throw UsageError(message: "unknown option")
      }
    } // End of loop over arguments
    guard let mode else { throw UsageError(message: "use --local or --ssh <destination>") }
    if knownHostsFile != nil, mode != .ssh {
      throw UsageError(message: "--strict-known-hosts only applies to --ssh")
    }
    let host = HostConfig(
      displayName: mode == .local ? "This Mac" : destination,
      mode: mode,
      sshDestination: destination,
      tmuxPathOverride: tmuxPath
    )
    var options = Options(host: host, raw: raw)
    if let knownHostsFile { options.hostKeyPolicy = .strict(knownHostsFile: knownHostsFile) }
    return options
  } // End of func parse(_:)

  /// Runs the probe's process directly and copies its stdout and stderr through unchanged.
  /// Returns the probe's exit status (or 128 + signal).
  static func printRawReport(probe: DiscoveryProbe, host: HostConfig) async throws -> Int32 {
    let request: ProcessRequest
    do throws(DiscoveryConfigurationError) {
      request = try probe.request(for: host)
    } catch {
      printError("muxfinder-probe: \(error.message)")
      return EX_USAGE
    }
    let result = try await probe.runner.run(request)
    FileHandle.standardOutput.write(result.standardOutput)
    FileHandle.standardError.write(result.standardError)
    if result.timedOut { printError("muxfinder-probe: the probe timed out") }
    return result.exitCode ?? 128 + (result.signal ?? 0)
  } // End of func printRawReport(probe:host:)

  /// The JSON document printed for `result`.
  static func json(for result: DiscoveryResult, host: HostConfig) throws -> String {
    let output = Output(
      host: HostOutput(
        mode: host.mode.rawValue,
        destination: host.mode == .ssh ? host.sshDestination : nil,
        tmuxPathOverride: host.tmuxPathOverride
      ),
      status: StatusOutput(result.status),
      nodeName: result.report?.nodeName,
      tmuxPath: result.report?.tmuxPath,
      tmuxVersion: result.report?.tmuxVersion,
      durationMs: Int(result.duration / .milliseconds(1))
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return String(decoding: try encoder.encode(output), as: UTF8.self)
  } // End of func json(for:host:)

  /// The top-level JSON object.
  struct Output: Encodable {
    /// What was probed.
    let host: HostOutput
    /// The classified status.
    let status: StatusOutput
    /// `uname -n` of the host, when a report was received.
    let nodeName: String?
    /// The tmux executable the probe used.
    let tmuxPath: String?
    /// `tmux -V` of that executable.
    let tmuxVersion: String?
    /// How long the probe ran, in milliseconds.
    let durationMs: Int
  }

  /// The probed host, as given on the command line.
  struct HostOutput: Encodable {
    /// `local` or `ssh`.
    let mode: String
    /// The SSH destination, for `ssh`.
    let destination: String?
    /// The tmux override, when given.
    let tmuxPathOverride: String?
  }

  /// A `HostStatus` as JSON: `kind`, plus `reason`, `message` or `sessions` when the case has
  /// them.
  struct StatusOutput: Encodable {
    /// `HostStatus.kind`.
    let kind: String
    /// The unreachable reason or host-key problem.
    let reason: String?
    /// The probe error message.
    let message: String?
    /// The sessions, for `ok`.
    let sessions: [DiscoveredSession]?

    /// Converts `status`.
    init(_ status: HostStatus) {
      kind = status.kind
      switch status {
      case .unreachable(let reason):
        self.reason = reason.rawValue
      case .hostKeyProblem(let problem):
        self.reason = problem.rawValue
      default:
        self.reason = nil
      }
      if case .probeError(let message) = status { self.message = message } else { message = nil }
      if case .ok(let sessions) = status { self.sessions = sessions } else { sessions = nil }
    } // End of init(_:)
  }
}
