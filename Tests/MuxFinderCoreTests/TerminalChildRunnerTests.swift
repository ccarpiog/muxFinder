import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for `TerminalChildRunner` in this process, without watching this process's signals
/// (`TerminalChildControl.watchTerminalSignals()` is covered through the real helper binary in
/// `LaunchHelperBinaryTests`); signals go through the control. The attach children print
/// nothing: they inherit the test runner's own terminal descriptors.
@Suite("Terminal child runner")
struct TerminalChildRunnerTests {
  /// Runs `script` through `/bin/sh` with `arguments`.
  static func run(
    _ script: String,
    arguments: [String] = [],
    runner: TerminalChildRunner = TerminalChildRunner()
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    try await runner.run(
      executable: "/bin/sh",
      arguments: ["-c", script, "muxfinder-test"] + arguments,
      environment: TestSupport.environment
    )
  }

  /// Exit statuses and signals come back as terminations, with timestamps in order.
  @Test(.timeLimit(.minutes(1)))
  func reportsTerminations() async throws {
    let exited = try await Self.run("exit 7")
    #expect(exited.termination == .exited(7))
    #expect(exited.forwardedSignals.isEmpty)
    #expect(!exited.terminalHungUp)
    #expect(exited.startedAt <= exited.endedAt)
    let signaled = try await Self.run("kill -TERM $$")
    #expect(signaled.termination == .signaled(SIGTERM))
  }

  /// The child stays in this process's group and keeps only descriptors 0, 1 and 2: an
  /// inheritable descriptor of this process (number 100 or above, no close-on-exec) does not
  /// reach it. (`ls /dev/fd` itself opens 3 and 4 on macOS.)
  @Test(.timeLimit(.minutes(1)))
  func keepsTheProcessGroupAndOnlyTheTerminalDescriptors() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let opened = open("/dev/null", O_RDONLY | O_CLOEXEC)
    try #require(opened >= 0)
    defer { close(opened) }
    // F_DUPFD clears close-on-exec, so a plain posix_spawn would pass this one on.
    let inheritable = fcntl(opened, F_DUPFD, 100)
    try #require(inheritable >= 100)
    defer { close(inheritable) }
    let outcome = try await Self.run(
      #"ps -o pgid= -p $$ | tr -d ' ' > "$1/pgid"; ls /dev/fd > "$1/fds""#,
      arguments: [directory.path(percentEncoded: false)]
    )
    #expect(outcome.termination == .exited(0))
    let pgid = try String(contentsOf: directory.appending(path: "pgid"), encoding: .utf8)
    #expect(pgid.trimmingCharacters(in: .whitespacesAndNewlines) == String(getpgrp()))
    let fds = try String(contentsOf: directory.appending(path: "fds"), encoding: .utf8)
    #expect(fds.split(separator: "\n") == ["0", "1", "2", "3", "4"])
    #expect(!fds.split(separator: "\n").contains(Substring(String(inheritable))))
  } // End of func keepsTheProcessGroupAndOnlyTheTerminalDescriptors()

  /// Signals given to the control reach the running child: queued before the spawn, and sent
  /// while it waits.
  @Test(.timeLimit(.minutes(1)))
  func forwardsSignalsThroughTheControl() async throws {
    let early = TerminalChildControl()
    early.forward(SIGTERM)
    let first = try await Self.run(
      "exec /bin/sleep 30",
      runner: TerminalChildRunner(control: early)
    )
    #expect(first.termination == .signaled(SIGTERM))
    #expect(first.forwardedSignals == [SIGTERM])

    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = TerminalChildControl()
    let running = Task {
      try await Self.run(
        #": > "$1/ready"; exec /bin/sleep 30"#,
        arguments: [directory.path(percentEncoded: false)],
        runner: TerminalChildRunner(control: control)
      )
    }
    #expect(await TestSupport.eventually { TestSupport.fileExists("ready", in: directory) })
    control.forward(SIGHUP)
    let second = try await running.value
    #expect(second.termination == .signaled(SIGHUP))
    #expect(second.terminalHungUp)
  } // End of func forwardsSignalsThroughTheControl()

  /// Cancelling the calling task sends the child SIGTERM.
  @Test(.timeLimit(.minutes(1)))
  func cancellationStopsTheChild() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let running = Task {
      try await Self.run(
        #": > "$1/ready"; exec /bin/sleep 30"#,
        arguments: [directory.path(percentEncoded: false)]
      )
    }
    #expect(await TestSupport.eventually { TestSupport.fileExists("ready", in: directory) })
    running.cancel()
    let outcome = try await running.value
    #expect(outcome.termination == .signaled(SIGTERM))
  } // End of func cancellationStopsTheChild()

  /// The check runs with pipes in its own process group (not this process's) and its result
  /// comes back whole.
  @Test(.timeLimit(.minutes(1)))
  func runsTheCheckWithPipesInItsOwnGroup() async throws {
    let runner = TerminalChildRunner(checkRunner: TestSupport.fastRunner)
    let outcome = try await runner.runCheck(
      TestSupport.shellRequest(#"ps -o pgid= -p $$ | tr -d ' '; printf 'err' >&2; exit 3"#)
    )
    guard case .finished(let result) = outcome else {
      Issue.record("\(outcome)")
      return
    }
    #expect(result.termination == .exited(3))
    #expect(String(decoding: result.standardError, as: UTF8.self) == "err")
    let group = String(decoding: result.standardOutput, as: UTF8.self)
    #expect(group == "\(result.processID)\n")
    #expect(result.processID != getpgrp())
    #expect(!outcome.terminalHungUp)
  } // End of func runsTheCheckWithPipesInItsOwnGroup()

  /// A signal already pending interrupts the check before it starts: nothing is spawned.
  @Test(.timeLimit(.minutes(1)))
  func interruptsTheCheckBeforeItStarts() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = TerminalChildControl()
    control.forward(SIGINT)
    let runner = TerminalChildRunner(control: control, checkRunner: TestSupport.fastRunner)
    let outcome = try await runner.runCheck(
      TestSupport.shellRequest(
        #": > "$1/started""#, arguments: [directory.path(percentEncoded: false)])
    )
    #expect(outcome == .interrupted(signals: [SIGINT]))
    #expect(!TestSupport.fileExists("started", in: directory))
  } // End of func interruptsTheCheckBeforeItStarts()

  /// A signal while the check runs kills its whole process group, even a descendant that
  /// ignores SIGTERM, and yields `.interrupted`; SIGHUP marks the terminal as hung up.
  @Test(.timeLimit(.minutes(1)))
  func interruptsARunningCheckAndKillsItsGroup() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let control = TerminalChildControl()
    let runner = TerminalChildRunner(control: control, checkRunner: TestSupport.fastRunner)
    let script = #"""
      trap '' TERM
      sleep 30 &
      printf '%s %s\n' "$$" "$!" > "$1/pids"
      wait
      """#
    let running = Task {
      try await runner.runCheck(
        TestSupport.shellRequest(
          script, arguments: [directory.path(percentEncoded: false)], timeout: .seconds(30))
      )
    }
    let ready = await TestSupport.eventually(within: .seconds(10)) {
      TestSupport.processIDs(inFile: "pids", in: directory).count == 2
    }
    control.forward(SIGHUP)
    let outcome = try await running.value
    #expect(ready)
    #expect(outcome == .interrupted(signals: [SIGHUP]))
    #expect(outcome.terminalHungUp)
    let pids = TestSupport.processIDs(inFile: "pids", in: directory)
    try #require(pids.count == 2)
    let gone = await TestSupport.eventually(within: .seconds(10)) {
      pids.allSatisfy(TestSupport.processIsGone) && TestSupport.processGroupIsGone(pids[0])
    }
    if !gone { _ = kill(-pids[0], SIGKILL) }
    #expect(gone)
  } // End of func interruptsARunningCheckAndKillsItsGroup()

  /// Cancelling the calling task interrupts the check as SIGTERM.
  @Test(.timeLimit(.minutes(1)))
  func cancellationInterruptsTheCheck() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let runner = TerminalChildRunner(checkRunner: TestSupport.fastRunner)
    let running = Task {
      try await runner.runCheck(
        TestSupport.shellRequest(
          #": > "$1/ready"; exec /bin/sleep 30"#,
          arguments: [directory.path(percentEncoded: false)],
          timeout: .seconds(30)
        )
      )
    }
    #expect(await TestSupport.eventually { TestSupport.fileExists("ready", in: directory) })
    running.cancel()
    #expect(try await running.value == .interrupted(signals: [SIGTERM]))
  } // End of func cancellationInterruptsTheCheck()

  /// A missing executable is a spawn failure with its errno.
  @Test func reportsSpawnFailures() async {
    await #expect(throws: ProcessRunnerError.spawnFailed(errno: ENOENT)) {
      try await TerminalChildRunner().run(
        executable: "/nonexistent/muxfinder-test",
        arguments: [],
        environment: TestSupport.environment
      )
    }
    await #expect(throws: ProcessRunnerError.argumentContainsNUL(index: 0)) {
      try await TerminalChildRunner().run(
        executable: "/bin/sh",
        arguments: ["a\0b"],
        environment: TestSupport.environment
      )
    }
    await #expect(throws: ProcessRunnerError.spawnFailed(errno: ENOENT)) {
      try await TerminalChildRunner(checkRunner: TestSupport.fastRunner).runCheck(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: "/nonexistent/muxfinder-test"),
          environment: TestSupport.environment
        )
      )
    }
  } // End of func reportsSpawnFailures()
}
