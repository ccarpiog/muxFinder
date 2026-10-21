// muxfinder-probe: developer and diagnostic CLI that drives the core without the GUI.
// Later phases add the iTerm2, attach and e2e subcommands.

import Foundation
import MuxFinderCore

/// The usage text shown for `help` and for unknown subcommands.
let usage = """
  usage: muxfinder-probe <command>

  commands:
    help    Show this help.
  \(DiscoverCommand.usage)
  """

/// Writes `message` and a newline to standard error.
func printError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

/// The command-line arguments after the program name.
let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "help", "-h", "--help":
  print(usage)
case "discover":
  exit(await DiscoverCommand.run(Array(arguments.dropFirst())))
default:
  printError(usage)
  exit(EX_USAGE)
}
