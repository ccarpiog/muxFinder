import Foundation
import MuxFinderCore

/// `muxfinder-probe update check …`: one update check against GitHub (PLAN.md D39, Phase
/// I-13a). The arguments, the check and the output are the core's (`UpdateProbe`, tested over
/// an injected transport); this file only wires the real `URLSessionUpdateTransport`, which
/// sends one anonymous `GET` to `api.github.com`. So its real run is the user's, never an
/// unattended run's (*Unattended-run rules* 3); `--help` contacts nothing.
enum UpdateCommand {
  /// Usage lines for this subcommand group.
  static let usage = UpdateProbe.usage

  /// Runs `update …` with the arguments after `update` and returns the exit status.
  static func run(_ arguments: [String]) async -> Int32 {
    await UpdateProbe.run(
      arguments,
      makeTransport: { URLSessionUpdateTransport(shortVersion: $0) },
      standardOutput: { print($0) },
      standardError: { printError($0) })
  }
}
