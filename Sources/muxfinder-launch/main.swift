// muxfinder-launch: the helper iTerm2 runs inside a launch tab (PLAN.md D2).
// Placeholder until the launch phase; it only reports that it is not implemented yet.

import Foundation
import MuxFinderCore

/// Writes `message` and a newline to standard error.
func printError(_ message: String) {
  FileHandle.standardError.write(Data((message + "\n").utf8))
}

printError("muxfinder-launch: not implemented yet.")
exit(EX_USAGE)
