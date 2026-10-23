// muxfinder-launch: the helper iTerm2 runs inside a launch tab, as
// `<path>/muxfinder-launch attach <launch id>` (PLAN.md D2, D14) or, for "Set up SSH in
// iTerm2…", `<path>/muxfinder-launch ssh-setup <launch id>` (D24), and inside a "Persistent
// work" profile's tab as `<path>/muxfinder-launch profile <host id>` (D26). All logic lives in
// `LaunchHelper` in MuxFinderCore; this file only wires the process to it. The login shell
// that `profile` mode may start replaces this process with default signal dispositions.

import Darwin
import MuxFinderCore

// A terminal or pipe that went away must make writes fail with EPIPE instead of killing the
// helper before it records its result. The child starts with default dispositions.
signal(SIGPIPE, SIG_IGN)
// The helper is never stopped by these before its result is written. `LaunchHelper.standard()`
// starts `TerminalChildControl.watchTerminalSignals()` right after this (EVFILT_SIGNAL records
// ignored signals): one that arrives before tmux attaches ends the launch as `interrupted`
// (killing the check's process group), one that arrives later is passed on to tmux.
// For the final wait and hold, `StandardLaunchTerminal` restores SIGHUP's default (closing the
// tab ends the helper at once) and keeps SIGINT and SIGTERM ignored (Ctrl-C finishes the wait
// like Return but never ends the helper before its minimum lifetime). Only a signal in the
// instant between these two steps is dropped.
for signalNumber in TerminalChildRunner.forwardedSignalNumbers {
  signal(signalNumber, SIG_IGN)
}

/// The raw bytes of every argument, argv[0] first, exactly as the process received them.
let argv: [[UInt8]] = (0..<Int(CommandLine.argc)).map { index in
  guard let pointer = CommandLine.unsafeArgv[index] else { return [] }
  return UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)).map { $0 }
}

exit(await LaunchHelper.standard().run(argv: argv))
