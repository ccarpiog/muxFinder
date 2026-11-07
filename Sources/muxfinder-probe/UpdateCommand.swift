import Foundation
import MuxFinderCore

/// `muxfinder-probe update …`: the update check against GitHub (PLAN.md D39, Phase I-13a) and
/// the verification of a release zip (Phase I-13b1). The arguments, the steps and the output
/// are the core's (`UpdateProbe`, `UpdateVerifyProbe`, tested over injected transports); this
/// file only wires the real `URLSessionUpdateTransport` (one anonymous `GET` to
/// `api.github.com`) and, through `UpdateVerifyProbe.Environment.live`, the real download
/// transport, `ditto` and Security.framework. So `update check` and `update verify --latest`
/// are the user's real runs, never an unattended run's (*Unattended-run rules* 3); `update
/// verify --zip` contacts no server; `--help` contacts nothing.
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
