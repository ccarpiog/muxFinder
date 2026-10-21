import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for POSIX quoting and the remote-command builder, including round trips through real
/// local shells.
@Suite("Shell quoting")
struct ShellQuotingTests {
  /// A static script that prints `$0` and every argument, each followed by a NUL byte.
  static let echoArguments: StaticShellScript = #"printf '%s\0' "$0" "$@""#

  /// Outer shells that stand in for the remote login shell. zsh runs with `-f` so the user's
  /// startup files are not read.
  static let loginShells: [[String]] = [["/bin/sh"], ["/bin/zsh", "-f"], ["/bin/bash"]]

  /// Single-quote escaping follows the `'\''` rule.
  @Test func quotesSingleWords() {
    #expect(ShellQuoting.posixSingleQuote("") == "''")
    #expect(ShellQuoting.posixSingleQuote("abc") == "'abc'")
    #expect(ShellQuoting.posixSingleQuote("it's") == #"'it'\''s'"#)
    #expect(ShellQuoting.posixSingleQuote("$(x) `y`") == "'$(x) `y`'")
  }

  /// The remote command has the exact shape from PLAN.md D3.
  @Test func buildsTheRemoteCommandShape() {
    let script: StaticShellScript = #"echo "$1""#
    let command = ShellQuoting.remoteCommand(script: script, args: ["a b", "it's"])
    #expect(command == #"/bin/sh -c 'echo "$1"' muxfinder 'a b' 'it'\''s'"#)
    #expect(ShellQuoting.remoteCommand(script: "true", args: []) == "/bin/sh -c 'true' muxfinder")
  }

  /// Joining static scripts concatenates their sources.
  @Test func joinsStaticScripts() {
    let joined: StaticShellScript = "set -eu\n" + "echo ok"
    #expect(joined.source == "set -eu\necho ok")
  }

  /// Each adversarial argument survives `/bin/sh -c <remote command>` byte for byte.
  @Test(arguments: TestSupport.adversarialArguments)
  func roundTripsEachArgument(argument: String) async throws {
    let output = try await Self.runThroughLoginShell(["/bin/sh"], arguments: [argument])
    #expect(output == TestSupport.nulTerminated([ShellQuoting.scriptName, argument]))
  }

  /// The whole corpus survives in one command through sh, zsh and bash login shells.
  @Test(arguments: loginShells)
  func roundTripsTheCorpus(loginShell: [String]) async throws {
    let corpus = TestSupport.adversarialArguments
    let output = try await Self.runThroughLoginShell(loginShell, arguments: corpus)
    #expect(output == TestSupport.nulTerminated([ShellQuoting.scriptName] + corpus))
  }

  /// Runs `loginShell -c <remoteCommand(echoArguments, arguments)>` through the real
  /// `posix_spawn` runner, the way OpenSSH hands the command to the remote login shell, and
  /// returns stdout.
  static func runThroughLoginShell(_ loginShell: [String], arguments: [String]) async throws
    -> Data
  {
    let command = ShellQuoting.remoteCommand(script: echoArguments, args: arguments)
    let result = try await TestSupport.fastRunner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: loginShell[0]),
        arguments: Array(loginShell.dropFirst()) + ["-c", command],
        environment: TestSupport.environment,
        timeout: .seconds(10)
      )
    )
    #expect(result.termination == .exited(0))
    #expect(result.standardError.isEmpty)
    return result.standardOutput
  } // End of func runThroughLoginShell(_:arguments:)
}
