import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for `PosixSpawnProcessRunner` against real local processes (`/bin/sh`, `/bin/cat`, …).
@Suite("Process runner")
struct ProcessRunnerTests {
  /// The runner under test, with short grace periods.
  let runner = TestSupport.fastRunner

  /// stdout and stderr arrive separately, and the exit status is reported.
  @Test func capturesOutputStreamsAndExitStatus() async throws {
    let result = try await runner.run(
      TestSupport.shellRequest("printf out; printf err >&2; exit 3")
    )
    #expect(result.standardOutput == Data("out".utf8))
    #expect(result.standardError == Data("err".utf8))
    #expect(result.termination == .exited(3))
    #expect(result.exitCode == 3)
    #expect(result.signal == nil)
    #expect(!result.timedOut)
    #expect(!result.succeeded)
    #expect(!result.standardOutputTruncated && !result.standardErrorTruncated)
  } // End of func capturesOutputStreamsAndExitStatus()

  /// A successful run reports exit status 0 and `succeeded`.
  @Test func reportsSuccess() async throws {
    let result = try await runner.run(
      ProcessRequest(executableURL: URL(fileURLWithPath: "/usr/bin/true"), environment: [:])
    )
    #expect(result.termination == .exited(0))
    #expect(result.succeeded)
    #expect(result.duration > .zero)
  }

  /// A process killed by a signal reports that signal instead of an exit status.
  @Test func reportsTerminatingSignal() async throws {
    let result = try await runner.run(TestSupport.shellRequest("kill -KILL $$"))
    #expect(result.termination == .signaled(SIGKILL))
    #expect(result.signal == SIGKILL)
    #expect(result.exitCode == nil)
  }

  /// argv reaches the program byte for byte; no shell is involved.
  @Test func passesArgumentsVerbatim() async throws {
    let corpus = TestSupport.adversarialArguments
    let result = try await runner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/printf"),
        arguments: [#"%s\0"#] + corpus,
        environment: TestSupport.environment,
        timeout: .seconds(10)
      )
    )
    #expect(result.termination == .exited(0))
    #expect(result.standardOutput == TestSupport.nulTerminated(corpus))
  } // End of func passesArgumentsVerbatim()

  /// The child sees exactly the requested environment and nothing inherited.
  @Test func usesOnlyTheGivenEnvironment() async throws {
    let result = try await runner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: "/usr/bin/env"),
        environment: ["MUXFINDER_TEST": "value with spaces"],
        timeout: .seconds(10)
      )
    )
    #expect(result.standardOutput == Data("MUXFINDER_TEST=value with spaces\n".utf8))
  }

  /// stdin is `/dev/null` unless data is supplied, so `cat` ends at once.
  @Test func standardInputDefaultsToNullDevice() async throws {
    let result = try await runner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/cat"),
        environment: TestSupport.environment,
        timeout: .seconds(10)
      )
    )
    #expect(result.termination == .exited(0))
    #expect(result.standardOutput.isEmpty)
    #expect(!result.timedOut)
  } // End of func standardInputDefaultsToNullDevice()

  /// Supplied stdin data larger than a pipe buffer arrives intact while output is drained.
  @Test func feedsStandardInputData() async throws {
    let input = Data((0..<(256 * 1024)).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let result = try await runner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/cat"),
        environment: TestSupport.environment,
        standardInput: .data(input),
        timeout: .seconds(10)
      )
    )
    #expect(result.termination == .exited(0))
    #expect(result.standardOutput == input)
  } // End of func feedsStandardInputData()

  /// The child leads a new process group whose id is its pid.
  @Test func childLeadsItsOwnProcessGroup() async throws {
    let result = try await runner.run(TestSupport.shellRequest("/bin/ps -o pgid= -p $$"))
    #expect(result.termination == .exited(0))
    #expect(TestSupport.processIDs(in: result.standardOutput) == [result.processID])
  }

  /// A timeout sends SIGTERM to the whole group: the shell and its background grandchild die.
  @Test func timeoutKillsGrandchildren() async throws {
    let script = """
      sleep 30 &
      printf '%s\\n' "$!" > "$1/pids"
      : > "$1/armed"
      sleep 30
      """
    let armedRun = try await TestSupport.runArmedTimeoutScenario(
      script, runner: runner, firstTimeout: .milliseconds(300))
    let run = try #require(armedRun)
    defer { try? FileManager.default.removeItem(at: run.directory) }
    let result = run.result
    #expect(result.timedOut)
    #expect(result.termination == .signaled(SIGTERM))
    #expect(result.duration < run.timeout + .seconds(5))
    let grandchildren = TestSupport.processIDs(inFile: "pids", in: run.directory)
    #expect(grandchildren.count == 1)
    for grandchild in grandchildren {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(grandchild) })
    }
    #expect(await TestSupport.eventually { TestSupport.processGroupIsGone(result.processID) })
  } // End of func timeoutKillsGrandchildren()

  /// When the group ignores SIGTERM, SIGKILL follows after the grace period.
  @Test func timeoutEscalatesToSigkill() async throws {
    let script = """
      trap '' TERM
      sleep 30 &
      printf '%s\\n' "$!" > "$1/pids"
      : > "$1/armed"
      sleep 30
      """
    let armedRun = try await TestSupport.runArmedTimeoutScenario(
      script, runner: runner, firstTimeout: .milliseconds(200))
    let run = try #require(armedRun)
    defer { try? FileManager.default.removeItem(at: run.directory) }
    let result = run.result
    #expect(result.timedOut)
    #expect(result.termination == .signaled(SIGKILL))
    #expect(result.duration >= run.timeout + runner.terminationGracePeriod)
    #expect(result.duration < run.timeout + .seconds(5))
    let grandchildren = TestSupport.processIDs(inFile: "pids", in: run.directory)
    #expect(grandchildren.count == 1)
    for grandchild in grandchildren {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(grandchild) })
    }
    #expect(await TestSupport.eventually { TestSupport.processGroupIsGone(result.processID) })
  } // End of func timeoutEscalatesToSigkill()

  /// Cancelling the calling task kills the group and throws `CancellationError`.
  @Test func cancellationKillsTheGroup() async throws {
    let pidFile = TestSupport.temporaryURL(".pids")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let request = TestSupport.shellRequest(
      #"sleep 30 & printf '%s %s\n' "$$" "$!" > "$1"; sleep 30"#,
      arguments: [pidFile.path(percentEncoded: false)],
      timeout: .seconds(20)
    )
    let runner = self.runner
    let task = Task { try await runner.run(request) }
    let started = await TestSupport.eventually {
      (try? String(contentsOf: pidFile, encoding: .utf8))?.hasSuffix("\n") ?? false
    }
    #expect(started)
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(cancelledAt.duration(to: clock.now) < .seconds(5))
    let processIDs = TestSupport.processIDs(in: (try? Data(contentsOf: pidFile)) ?? Data())
    #expect(processIDs.count == 2)
    for processID in processIDs {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(processID) })
    }
    if let leader = processIDs.first {
      #expect(await TestSupport.eventually { TestSupport.processGroupIsGone(leader) })
    }
  } // End of func cancellationKillsTheGroup()

  /// Cancelling after the child exited, while a grandchild still holds the pipes, kills the
  /// grandchild too. The long drain grace period guarantees the cancellation lands in that phase.
  @Test func cancellationDuringDrainKillsGrandchildren() async throws {
    let pidFile = TestSupport.temporaryURL(".pids")
    defer { try? FileManager.default.removeItem(at: pidFile) }
    let request = TestSupport.shellRequest(
      #"sleep 30 & printf '%s\n' "$!" > "$1""#,
      arguments: [pidFile.path(percentEncoded: false)],
      timeout: .seconds(20)
    )
    let runner = PosixSpawnProcessRunner(
      terminationGracePeriod: .milliseconds(300),
      outputDrainGracePeriod: .seconds(20)
    )
    let task = Task { try await runner.run(request) }
    let started = await TestSupport.eventually {
      (try? String(contentsOf: pidFile, encoding: .utf8))?.hasSuffix("\n") ?? false
    }
    #expect(started)
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    let grandchildren = TestSupport.processIDs(in: (try? Data(contentsOf: pidFile)) ?? Data())
    #expect(grandchildren.count == 1)
    for grandchild in grandchildren {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(grandchild) })
    }
  } // End of func cancellationDuringDrainKillsGrandchildren()

  /// After a timeout, a descendant that handles SIGTERM finishes its cleanup although the
  /// leader died at once, its output still reaches the result, and the run ends as soon as the
  /// group is gone rather than at the 30 s escalation deadline.
  @Test func timeoutLeavesDescendantsTheirGracePeriod() async throws {
    let armedRun = try await TestSupport.runArmedTimeoutScenario(
      TestSupport.cleanupScript,
      runner: TestSupport.patientRunner,
      firstTimeout: .milliseconds(500)
    )
    let run = try #require(armedRun)
    defer { try? FileManager.default.removeItem(at: run.directory) }
    let result = run.result
    #expect(result.timedOut)
    #expect(result.termination == .signaled(SIGTERM))
    #expect(TestSupport.fileExists("cleaned", in: run.directory))
    #expect(result.standardOutput == Data("cleaned\n".utf8))
    #expect(result.duration < run.timeout + .seconds(15))
    let processIDs = TestSupport.processIDs(inFile: "pids", in: run.directory)
    #expect(processIDs.count == 2)
    #expect(processIDs.first == result.processID)
    for processID in processIDs {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(processID) })
    }
    #expect(await TestSupport.eventually { TestSupport.processGroupIsGone(result.processID) })
  } // End of func timeoutLeavesDescendantsTheirGracePeriod()

  /// After cancellation, a descendant that handles SIGTERM finishes its cleanup before
  /// `CancellationError` is thrown, and the throw follows soon after the group is gone.
  @Test func cancellationLeavesDescendantsTheirGracePeriod() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let request = TestSupport.shellRequest(
      TestSupport.cleanupScript,
      arguments: [directory.path(percentEncoded: false)],
      timeout: .seconds(60)
    )
    let runner = TestSupport.patientRunner
    let task = Task { try await runner.run(request) }
    let armed = await TestSupport.eventually(within: .seconds(30)) {
      TestSupport.fileExists("armed", in: directory)
    }
    #expect(armed)
    let clock = ContinuousClock()
    let cancelledAt = clock.now
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
    #expect(cancelledAt.duration(to: clock.now) < .seconds(15))
    #expect(TestSupport.fileExists("cleaned", in: directory))
    let processIDs = TestSupport.processIDs(inFile: "pids", in: directory)
    #expect(processIDs.count == 2)
    for processID in processIDs {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(processID) })
    }
    if let leader = processIDs.first {
      #expect(await TestSupport.eventually { TestSupport.processGroupIsGone(leader) })
    }
  } // End of func cancellationLeavesDescendantsTheirGracePeriod()

  /// A descendant that ignores SIGTERM outlives the leader until the escalation deadline and
  /// then gets SIGKILL, leaving no survivors. The run cannot end while a live member remains, so
  /// a duration of at least timeout + grace period shows nothing was killed early.
  @Test func timeoutKillsTermIgnoringDescendantsAtTheDeadline() async throws {
    let runner = PosixSpawnProcessRunner(
      terminationGracePeriod: .milliseconds(400),
      outputDrainGracePeriod: .milliseconds(200)
    )
    let script = """
      dir=$1
      (trap '' TERM; : > "$dir/ready"; exec sleep 30) &
      printf '%s %s\\n' "$$" "$!" > "$dir/pids"
      until [ -e "$dir/ready" ]; do sleep 0.01; done
      : > "$dir/armed"
      sleep 30
      """
    let armedRun = try await TestSupport.runArmedTimeoutScenario(
      script, runner: runner, firstTimeout: .milliseconds(500))
    let run = try #require(armedRun)
    defer { try? FileManager.default.removeItem(at: run.directory) }
    let result = run.result
    #expect(result.timedOut)
    #expect(result.termination == .signaled(SIGTERM))
    #expect(result.duration >= run.timeout + runner.terminationGracePeriod)
    #expect(result.duration < run.timeout + .seconds(10))
    let processIDs = TestSupport.processIDs(inFile: "pids", in: run.directory)
    #expect(processIDs.count == 2)
    for processID in processIDs {
      #expect(await TestSupport.eventually { TestSupport.processIsGone(processID) })
    }
    #expect(await TestSupport.eventually { TestSupport.processGroupIsGone(result.processID) })
  } // End of func timeoutKillsTermIgnoringDescendantsAtTheDeadline()

  /// A task cancelled before `run` is called throws without starting anything.
  @Test func cancellationBeforeStartThrows() async throws {
    let runner = self.runner
    let request = TestSupport.shellRequest("sleep 30")
    let task = Task {
      try? await Task.sleep(for: .seconds(10))
      return try await runner.run(request)
    }
    task.cancel()
    await #expect(throws: CancellationError.self) { try await task.value }
  }

  /// Output beyond the cap is drained and discarded on both streams; the child is never
  /// blocked, even though stderr floods before stdout is written.
  @Test func capsOutputWhileDrainingBothStreams() async throws {
    let script = "/usr/bin/head -c 3145728 /dev/zero >&2; /usr/bin/head -c 3145728 /dev/zero"
    let result = try await runner.run(TestSupport.shellRequest(script))
    #expect(result.termination == .exited(0))
    #expect(!result.timedOut)
    #expect(result.standardOutput.count == ProcessRequest.defaultOutputLimit)
    #expect(result.standardError.count == ProcessRequest.defaultOutputLimit)
    #expect(result.standardOutputTruncated)
    #expect(result.standardErrorTruncated)
    #expect(ProcessRequest.defaultOutputLimit == 1_048_576)
  } // End of func capsOutputWhileDrainingBothStreams()

  /// A custom cap keeps exactly that many bytes, and output at the cap is not truncated.
  @Test func honorsCustomOutputLimit() async throws {
    var request = TestSupport.shellRequest("printf 12345678; printf 1234 >&2")
    request.outputLimit = 4
    let result = try await runner.run(request)
    #expect(result.standardOutput == Data("1234".utf8))
    #expect(result.standardOutputTruncated)
    #expect(result.standardError == Data("1234".utf8))
    #expect(!result.standardErrorTruncated)
  }

  /// A background grandchild that inherited the pipes does not keep the run alive after the
  /// child exits.
  @Test func returnsWhenAGrandchildHoldsThePipes() async throws {
    let result = try await runner.run(TestSupport.shellRequest("sleep 30 & echo $!"))
    let grandchildren = TestSupport.processIDs(in: result.standardOutput)
    for grandchild in grandchildren { kill(grandchild, SIGKILL) }
    #expect(result.termination == .exited(0))
    #expect(!result.timedOut)
    #expect(grandchildren.count == 1)
    #expect(result.duration < .seconds(3))
  }

  /// Invalid requests are refused before anything is spawned.
  @Test func rejectsInvalidRequests() async throws {
    let relative = try #require(URL(string: "sh"))
    await #expect(throws: ProcessRunnerError.executableNotAbsolute) {
      try await runner.run(ProcessRequest(executableURL: relative, environment: [:]))
    }
    await #expect(throws: ProcessRunnerError.argumentContainsNUL(index: 1)) {
      try await runner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: "/bin/echo"),
          arguments: ["fine", "bad\0byte"],
          environment: [:]
        )
      )
    }
    await #expect(throws: ProcessRunnerError.invalidEnvironmentVariable(name: "A=B")) {
      try await runner.run(
        ProcessRequest(executableURL: URL(fileURLWithPath: "/bin/echo"), environment: ["A=B": "1"])
      )
    }
    await #expect(throws: ProcessRunnerError.invalidEnvironmentVariable(name: "A")) {
      try await runner.run(
        ProcessRequest(executableURL: URL(fileURLWithPath: "/bin/echo"), environment: ["A": "\0"])
      )
    }
  } // End of func rejectsInvalidRequests()

  /// Spawn failures surface the errno from `posix_spawn`.
  @Test func reportsSpawnFailures() async throws {
    await #expect(throws: ProcessRunnerError.spawnFailed(errno: ENOENT)) {
      try await runner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: "/nonexistent/muxfinder-test-binary"),
          environment: [:]
        )
      )
    }
    await #expect(throws: ProcessRunnerError.spawnFailed(errno: EACCES)) {
      try await runner.run(
        ProcessRequest(executableURL: URL(fileURLWithPath: "/etc/hosts"), environment: [:])
      )
    }
  } // End of func reportsSpawnFailures()

  /// Many concurrent runs each get their own output.
  @Test func runsConcurrently() async throws {
    let runner = self.runner
    let outputs = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
      for index in 0..<24 {
        group.addTask {
          let result = try await runner.run(
            ProcessRequest(
              executableURL: URL(fileURLWithPath: "/bin/echo"),
              arguments: ["run \(index)"],
              environment: [:],
              timeout: .seconds(10)
            )
          )
          return (index, result.standardOutput)
        }
      } // End of loop adding one echo task per index
      var collected: [Int: Data] = [:]
      for try await (index, output) in group { collected[index] = output }
      return collected
    }
    #expect(outputs.count == 24)
    for (index, output) in outputs {
      #expect(output == Data("run \(index)\n".utf8))
    }
  } // End of func runsConcurrently()

  /// Children that exit before the kqueue watch is registered are still reaped correctly.
  @Test func reapsImmediateExitsReliably() async throws {
    let request = ProcessRequest(
      executableURL: URL(fileURLWithPath: "/usr/bin/false"),
      environment: [:],
      timeout: .seconds(10)
    )
    for _ in 0..<40 {
      let result = try await runner.run(request)
      #expect(result.termination == .exited(1))
    }
  } // End of func reapsImmediateExitsReliably()

  /// Awaiting a run from the main actor leaves the main actor free to do other work.
  @MainActor @Test func doesNotBlockTheMainActor() async throws {
    let ticks = MainActorCounter()
    let ticker = Task { @MainActor in
      while !Task.isCancelled {
        ticks.value += 1
        try? await Task.sleep(for: .milliseconds(10))
      }
    }
    let result = try await runner.run(TestSupport.shellRequest("sleep 0.3"))
    ticker.cancel()
    #expect(result.termination == .exited(0))
    #expect(ticks.value >= 5)
  } // End of func doesNotBlockTheMainActor()
}

/// A counter mutated only on the main actor.
@MainActor final class MainActorCounter {
  /// The current count.
  var value = 0
}
