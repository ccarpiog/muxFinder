// muxfinder-probe: developer and diagnostic CLI that drives the core without the GUI.
// Placeholder; real subcommands (discovery, e2e checks) arrive in later phases.

import Foundation
import MuxFinderCore

/// The usage text shown for `help` and for unknown subcommands.
let usage = """
  usage: muxfinder-probe <command>

  commands:
    help    Show this help.
  """

/// Writes `message` and a newline to standard error.
func printError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "help", "-h", "--help":
  print(usage)
default:
  printError(usage)
  exit(EX_USAGE)
}
