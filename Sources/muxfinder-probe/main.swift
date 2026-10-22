// muxfinder-probe: developer and diagnostic CLI that drives the core without the GUI.

import Foundation
import MuxFinderCore

/// The usage text shown for `help` and for unknown subcommands.
let usage = """
  usage: muxfinder-probe <command>

  commands:
    help    Show this help.
  \(DiscoverCommand.usage)
  \(HostsCommand.usage)
  \(RefreshCommand.usage)
  \(ITerm2Command.usage)
  \(AttachCommand.usage)
  \(NewSessionCommand.usage)
  \(SSHSetupCommand.usage)
  \(E2ELocalCommand.usage)
  \(E2ERemoteCommand.usage)
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
case "hosts":
  exit(await HostsCommand.run(Array(arguments.dropFirst())))
case "refresh":
  exit(await RefreshCommand.run(Array(arguments.dropFirst())))
case "iterm2":
  exit(await ITerm2Command.run(Array(arguments.dropFirst())))
case "attach":
  exit(await AttachCommand.run(Array(arguments.dropFirst())))
case "new-session":
  exit(await NewSessionCommand.run(Array(arguments.dropFirst())))
case "ssh-setup":
  exit(await SSHSetupCommand.run(Array(arguments.dropFirst())))
case "detach":
  exit(await AttachCommand.runDetach(Array(arguments.dropFirst())))
case "e2e-local":
  exit(await E2ELocalCommand.run(Array(arguments.dropFirst())))
case "e2e-remote":
  exit(await E2ERemoteCommand.run(Array(arguments.dropFirst())))
default:
  printError(usage)
  exit(EX_USAGE)
}
