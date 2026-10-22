import CryptoKit
import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Runs the built `muxfinder-launch` binary as a child of the test, with a private launch
/// directory (`MUXFINDER_LAUNCH_DIRECTORY`), `MUXFINDER_LAUNCH_NO_WAIT=1` and stdin that is not
/// a terminal, so it never waits for Return. The attach path runs against the fake tmux (no
/// real tmux client is ever attached); real tmux is used only on a private server for failure
/// paths. Skipped if the binary is not next to the test bundle.
@Suite("Launch helper binary")
struct LaunchHelperBinaryTests {
  /// The helper built alongside the tests: SwiftPM puts every product in the directory that
  /// holds the `.xctest` bundle (`swift test` builds the executables too), so the bundle's
  /// ancestors are searched.
  static let helperURL: URL? = {
    var directory = Bundle(for: FakeLaunchChildRunner.self).bundleURL
    for _ in 0..<4 {
      directory = directory.deletingLastPathComponent()
      let candidate = directory.appending(path: LaunchHelperPath.executableName)
      if FileManager.default.isExecutableFile(atPath: candidate.path(percentEncoded: false)) {
        return candidate
      }
    }
    return nil
  }()

  /// The helper's environment: a private launch directory plus `extra`.
  static func environment(
    launchDirectory: URL,
    _ extra: [String: String] = [:]
  ) -> [String: String] {
    var environment = [
      "PATH": ProcessEnvironment.systemSearchPath,
      "HOME": NSHomeDirectory(),
      LaunchHelper.directoryVariable: launchDirectory.path(percentEncoded: false),
      StandardLaunchTerminal.noWaitVariable: "1",
    ]
    environment.merge(extra) { _, new in new }
    return environment
  } // End of func environment(launchDirectory:_:)

  /// Runs the helper with `arguments`.
  static func runHelper(
    _ arguments: [String],
    environment: [String: String],
    standardInput: ProcessRequest.StandardInput = .nullDevice
  ) async throws -> ProcessResult {
    let helper = try #require(helperURL)
    return try await TestSupport.fastRunner.run(
      ProcessRequest(
        executableURL: helper,
        arguments: arguments,
        environment: environment,
        standardInput: standardInput,
        timeout: .seconds(20)
      )
    )
  } // End of func runHelper(_:environment:standardInput:)

  /// The text of `data`.
  static func text(_ data: Data) -> String {
    String(decoding: data, as: UTF8.self)
  }

  /// Bad usage exits 2; a missing request exits 70 with a result file and, in test mode, an
  /// argv digest of exactly what the process received.
  @Test(.enabled(if: helperURL != nil), .timeLimit(.minutes(1)))
  func refusesUsageErrorsAndMissingRequests() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let environment = Self.environment(launchDirectory: store.directory)

    let usage = try await Self.runHelper([], environment: environment)
    #expect(usage.termination == .exited(LaunchExitStatus.usage))
    #expect(Self.text(usage.standardError).hasPrefix(LaunchHelper.usage))
    let bad = try await Self.runHelper(["attach", "../../etc"], environment: environment)
    #expect(bad.termination == .exited(LaunchExitStatus.usage))

    let id = LaunchToken()
    var testMode = environment
    testMode[LaunchHelper.testModeVariable] = "1"
    let missing = try await Self.runHelper(["attach", id.rawValue], environment: testMode)
    #expect(missing.termination == .exited(LaunchExitStatus.requestMissing))
    #expect(Self.text(missing.standardError).contains(LaunchFailure.requestMissing.explanation))
    #expect(try store.takeResult(id)?.failure == .requestMissing)

    let digest = try #require(try store.takeArgvDigests().first)
    #expect(digest.helperPID == missing.processID)
    #expect(digest.argumentCount == 3)
    #expect(digest.launchID == id)
    let helperPath = try #require(Self.helperURL).path(percentEncoded: false)
    #expect(digest.arguments[0].byteLength == helperPath.utf8.count)
    let pathHash = SHA256.hash(data: Data(helperPath.utf8))
    #expect(digest.arguments[0].sha256 == pathHash.map { String(format: "%02x", $0) }.joined())
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
  } // End of func refusesUsageErrorsAndMissingRequests()

  /// Through the check to the (fake) tmux attach: tmux is the helper's direct child (no shell
  /// in between), in the helper's process group, reading the helper's stdin and writing to its
  /// stdout and stderr (not pipes of the helper's own); its status becomes the helper's and
  /// the result's.
  @Test(.enabled(if: helperURL != nil), .timeLimit(.minutes(1)))
  func runsTheAttachOnTheHelpersTerminal() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    for exitStatus: Int32 in [0, 1] {
      let request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
      try store.writeRequest(request)
      let result = try await Self.runHelper(
        ["attach", request.id.rawValue],
        environment: Self.environment(
          launchDirectory: store.directory,
          [
            "MUXFINDER_FAKE_IDENTITY": LaunchTestSupport.identity(of: request),
            "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
            "MUXFINDER_FAKE_EXIT": String(exitStatus),
            "TMUX": "/private/tmp/muxfinder-test-nonexistent/default,1,0",
          ]
        ),
        standardInput: .data(Data("hello\n".utf8))
      )
      #expect(result.termination == .exited(exitStatus), "\(Self.text(result.standardError))")
      #expect(Self.text(result.standardOutput) == "stdin:hello\n")
      let record = try String(contentsOf: root.appending(path: "attach"), encoding: .utf8)
      #expect(record == "$3 \(result.processID) \(result.processID)\n")
      let stored = try #require(try store.takeResult(request.id))
      #expect(stored.helperPID == result.processID)
      #expect(stored.childTermination == .exited(exitStatus))
      if exitStatus == 0 {
        #expect(stored.succeeded)
        #expect(Self.text(result.standardError) == "stderr-ok\n")
      } else {
        #expect(stored.failure == .childExited(1))
        #expect(Self.text(result.standardError).contains("tmux ended with exit status 1."))
      }
      #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
    } // End of loop over child exit statuses
  } // End of func runsTheAttachOnTheHelpersTerminal()

  /// SIGTERM and SIGHUP sent to the helper alone are passed on to tmux (the fake exits 43 and
  /// 44 from its traps); the helper survives them, records the result and exits with tmux's
  /// status.
  @Test(
    .enabled(if: helperURL != nil),
    .timeLimit(.minutes(1)),
    arguments: [(SIGTERM, Int32(43)), (SIGHUP, Int32(44))]
  )
  func forwardsSignalsToTmux(signalNumber: Int32, expected: Int32) async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
    try store.writeRequest(request)
    let environment = Self.environment(
      launchDirectory: store.directory,
      [
        "MUXFINDER_FAKE_IDENTITY": LaunchTestSupport.identity(of: request),
        "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
        "MUXFINDER_FAKE_ATTACH": "wait",
      ]
    )
    let running = Task {
      try await Self.runHelper(["attach", request.id.rawValue], environment: environment)
    }
    let ready = await TestSupport.eventually(within: .seconds(10)) {
      TestSupport.fileExists("ready", in: root)
    }
    #expect(ready)
    let record = try String(contentsOf: root.appending(path: "attach"), encoding: .utf8)
    let helperPID = try #require(record.split(separator: " ").last.flatMap { pid_t($0.dropLast()) })
    #expect(kill(helperPID, signalNumber) == 0)
    let result = try await running.value
    #expect(result.processID == helperPID)
    #expect(result.termination == .exited(expected), "\(Self.text(result.standardError))")
    #expect(try store.takeResult(request.id)?.failure == .childExited(expected))
  } // End of func forwardsSignalsToTmux(signalNumber:expected:)

  /// SIGTERM or SIGHUP sent to the helper alone while the check hangs (the fake tmux stalls
  /// in `display-message`, ignoring SIGTERM, with a background sleeper) ends the launch as
  /// `interrupted` (128 + n) with a result, and the check's whole process group is gone, so
  /// nothing is orphaned. The check is a separate group, out of this test runner's reach, so
  /// only the helper's own cleanup can have removed it.
  @Test(
    .enabled(if: helperURL != nil),
    .timeLimit(.minutes(1)),
    arguments: [SIGTERM, SIGHUP]
  )
  func stopsTheCheckWhenSignaled(signalNumber: Int32) async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
    try store.writeRequest(request)
    let environment = Self.environment(
      launchDirectory: store.directory,
      [
        "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
        "MUXFINDER_FAKE_DISPLAY_STALL": "1",
      ]
    )
    let running = Task {
      try await Self.runHelper(["attach", request.id.rawValue], environment: environment)
    }
    let ready = await TestSupport.eventually(within: .seconds(10)) {
      LaunchTestSupport.stallRecord(in: root) != nil
    }
    let record = try #require(LaunchTestSupport.stallRecord(in: root), "check never stalled")
    #expect(ready)
    // The helper leads the group this test's runner made for it; the check leads its own.
    try #require(record.checkParent > 1 && record.checkParent != getpid())
    try #require(getpgid(record.checkParent) == record.checkParent)
    #expect(record.group != getpgrp() && record.group != record.checkParent)
    #expect(kill(record.checkParent, signalNumber) == 0)
    let result = try await running.value
    #expect(result.processID == record.checkParent)
    #expect(
      result.termination == .exited(128 + signalNumber), "\(Self.text(result.standardError))")
    #expect(try store.takeResult(request.id)?.failure == .interrupted(signalNumber))
    #expect(
      Self.text(result.standardError).contains(LaunchFailure.interrupted(signalNumber).explanation))
    #expect(!TestSupport.fileExists("attach", in: root))
    #expect(await LaunchTestSupport.waitUntilGone(record))
  } // End of func stopsTheCheckWhenSignaled(signalNumber:)

  /// Real tmux on a private server: no server is gone (64) and a wrong `session_created` is
  /// changed (65); the request is consumed and the result records the typed failure.
  @Test(
    .enabled(if: helperURL != nil && DiscoveryEndToEndTests.tmuxPath != nil),
    .timeLimit(.minutes(1))
  )
  func reportsGuardFailuresWithRealTmux() async throws {
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let socketDirectory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: socketDirectory) }
    let tmuxEnvironment = DiscoveryEndToEndTests.tmuxEnvironment(socketDirectory)
    let environment = Self.environment(launchDirectory: store.directory, tmuxEnvironment)

    let none = LaunchTestSupport.request(createdAt: Date(), sessionID: "$0")
    try store.writeRequest(none)
    let gone = try await Self.runHelper(["attach", none.id.rawValue], environment: environment)
    #expect(gone.termination == .exited(LaunchExitStatus.sessionGone))
    #expect(Self.text(gone.standardError).contains(LaunchFailure.sessionGone.explanation))
    #expect(try store.takeResult(none.id)?.failure == .sessionGone)

    let probe = DiscoveryProbe(runner: TestSupport.fastRunner, baseEnvironment: tmuxEnvironment)
    try await DiscoveryEndToEndTests.withTestSessions(
      ["muxfinder-test-helper"],
      tmux: tmux,
      environment: tmuxEnvironment
    ) { _ in
      let discovered = try await probe.discover(HostConfig(displayName: "This Mac", mode: .local))
      let session = try #require(discovered.status.sessions.first, "\(discovered.status)")
      var request = LaunchRequest(
        createdAt: Date(),
        host: .local,
        tmuxPathOverride: nil,
        session: session
      )
      request.expectedSessionCreated += 1
      try store.writeRequest(request)
      let changed = try await Self.runHelper(
        ["attach", request.id.rawValue], environment: environment)
      #expect(changed.termination == .exited(LaunchExitStatus.sessionChanged))
      #expect(try store.takeResult(request.id)?.failure == .sessionChanged)
    }
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
  } // End of func reportsGuardFailuresWithRealTmux()
}

/// Runs the built `muxfinder-launch` in a pseudo-terminal (`PseudoTerminalHelper`), so it is
/// interactive: after a failure it waits for Return, then holds its tab until it is as old as
/// `MUXFINDER_LAUNCH_MINIMUM_LIFETIME_MS` says. Every run asks for a launch id that has no
/// request, so it fails at once (70) and starts no child. Signals and Return are repeated
/// every 50 ms: one that arrives just before a wait sets its dispositions (or, for Return,
/// before it discards earlier input) is ignored, so a single one could be lost under load.
@Suite("Launch helper binary (terminal)")
struct LaunchHelperTerminalTests {
  /// The prompt the helper prints before it waits for Return.
  static let prompt = "Press Return to close."

  /// When a test starts sending its signal.
  enum Moment: String, Sendable, CaseIterable {
    /// At the failure prompt, and on through the hold if the helper gets there.
    case atThePrompt
    /// Only once Return ended the wait, so the signal reaches the hold alone.
    case duringTheHold
  }

  /// Starts the helper for a fresh launch id with no request, in `store`'s directory, with a
  /// minimum lifetime of `lifetimeMilliseconds`. Returns the running helper and the id.
  static func start(
    lifetimeMilliseconds: Int,
    store: LaunchStore
  ) throws -> (terminal: PseudoTerminalHelper, id: LaunchToken) {
    let helper = try #require(LaunchHelperBinaryTests.helperURL)
    let id = LaunchToken()
    var environment = LaunchHelperBinaryTests.environment(launchDirectory: store.directory)
    environment[StandardLaunchTerminal.noWaitVariable] = nil
    environment[LaunchHelper.minimumLifetimeVariable] = String(lifetimeMilliseconds)
    let terminal = try PseudoTerminalHelper(
      helper: helper,
      arguments: ["attach", id.rawValue],
      environment: environment
    )
    return (terminal, id)
  } // End of func start(lifetimeMilliseconds:store:)

  /// Waits (up to 10 s) until the helper printed the prompt.
  static func waitForPrompt(_ terminal: PseudoTerminalHelper) async throws {
    let prompted = await TestSupport.eventually(within: .seconds(10)) {
      terminal.text.contains(prompt)
    }
    try #require(prompted, "no prompt: \(terminal.text)")
  }

  /// Repeats `action` until the line end the helper writes once its wait returned shows, or
  /// the helper exits (up to 10 s). Returns the instant that was seen.
  static func endWait(
    _ terminal: PseudoTerminalHelper,
    with action: () -> Void
  ) async throws -> ContinuousClock.Instant {
    let ended = await PseudoTerminalHelper.repeating(
      action,
      until: { terminal.text.contains(prompt + "\n") || terminal.hasExited },
      within: .seconds(10)
    )
    return try #require(ended, "the wait for Return never ended: \(terminal.text)")
  }

  /// Sends `signalNumber` every 50 ms until the helper exits (up to `limit`). Returns the
  /// instant the exit was seen.
  static func signalUntilExit(
    _ terminal: PseudoTerminalHelper,
    _ signalNumber: Int32,
    within limit: Duration
  ) async throws -> ContinuousClock.Instant {
    let exited = await PseudoTerminalHelper.repeating(
      { terminal.send(signalNumber) },
      until: { terminal.hasExited },
      within: limit
    )
    return try #require(exited, "the helper did not exit: \(terminal.text)")
  }

  /// SIGINT (Ctrl-C) or SIGTERM, at the failure prompt or only during the hold after Return,
  /// never ends the helper before its minimum lifetime (3 s here): at the prompt it finishes the
  /// wait like Return, the hold ignores it, and the helper exits normally (70, its result
  /// written) once it is old enough, and soon after.
  @Test(
    .enabled(if: LaunchHelperBinaryTests.helperURL != nil),
    .timeLimit(.minutes(1)),
    arguments: [SIGINT, SIGTERM], Moment.allCases
  )
  func holdsThroughInterrupts(signalNumber: Int32, moment: Moment) async throws {
    let lifetime = Duration.seconds(3)
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let (terminal, id) = try Self.start(lifetimeMilliseconds: 3000, store: store)
    defer { terminal.stop() }
    try await Self.waitForPrompt(terminal)
    let waitEnded = try await Self.endWait(terminal) {
      if moment == .atThePrompt { terminal.send(signalNumber) } else { terminal.pressReturn() }
    }
    let exitedAt = try await Self.signalUntilExit(terminal, signalNumber, within: .seconds(30))
    let termination = terminal.reap()
    #expect(termination == .exited(LaunchExitStatus.requestMissing), "\(terminal.text)")
    #expect(exitedAt - terminal.startedAt >= lifetime)
    #expect(exitedAt - max(terminal.startedAt + lifetime, waitEnded) < .seconds(5))
    #expect(terminal.text.contains(Self.prompt + "\n"))
    #expect(try store.takeResult(id)?.failure == .requestMissing)
  } // End of func holdsThroughInterrupts(signalNumber:moment:)

  /// SIGHUP (the tab closed, so nobody can see the helper end) still ends it at once, at the
  /// prompt and during the hold, long before its minimum lifetime (60 s here); its result was
  /// written before.
  @Test(
    .enabled(if: LaunchHelperBinaryTests.helperURL != nil),
    .timeLimit(.minutes(1)),
    arguments: Moment.allCases
  )
  func endsAtOnceOnHangUp(moment: Moment) async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let (terminal, id) = try Self.start(lifetimeMilliseconds: 60_000, store: store)
    defer { terminal.stop() }
    try await Self.waitForPrompt(terminal)
    if moment == .duringTheHold {
      _ = try await Self.endWait(terminal) { terminal.pressReturn() }
    }
    let exitedAt = try await Self.signalUntilExit(terminal, SIGHUP, within: .seconds(20))
    #expect(terminal.reap() == .signaled(SIGHUP), "\(terminal.text)")
    #expect(exitedAt - terminal.startedAt < .seconds(30))
    #expect(terminal.text.contains(Self.prompt + "\n") == (moment == .duringTheHold))
    #expect(try store.takeResult(id)?.failure == .requestMissing)
  } // End of func endsAtOnceOnHangUp(moment:)
}
