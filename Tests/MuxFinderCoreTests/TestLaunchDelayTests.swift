import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The helper's test-only launch delay (PLAN.md D14 *Test mode*, D17's `still waiting` step):
/// a request's `testLaunchDelaySeconds` is honored only in test mode (the variable or the
/// marker), as a `/bin/sleep` check-stage child before the first real child; a signal ends it
/// like a check, without attaching and with the usual wait and hold unless the tab closed; a
/// value outside 1–120 makes the request unreadable.
@Suite("Launch helper (test launch delay)")
struct TestLaunchDelayTests {
  /// Shorthand.
  typealias Base = LaunchHelperTests

  /// How the helper's test mode is set in a test.
  enum Mode: String, Sendable, CaseIterable, CustomTestStringConvertible {
    /// Not in test mode.
    case off
    /// `MUXFINDER_LAUNCH_TEST_MODE=1`.
    case variable
    /// The `test-mode` marker file in the launch directory.
    case marker

    /// The mode's name.
    var testDescription: String { rawValue }
  }

  /// A helper fixture (interactive terminal) in `mode`, whose attach child ends with
  /// `behavior` and whose check-stage children behave as `check` (by default: exit 0, so a
  /// delay runs out and a local check passes).
  static func fixture(
    _ mode: Mode,
    behavior: FakeLaunchChildRunner.Behavior = .termination(.exited(0), forwarded: []),
    check: FakeLaunchChildRunner.CheckBehavior? = nil
  ) throws -> Base.Fixture {
    let environment = mode == .variable ? [LaunchHelper.testModeVariable: "1"] : [:]
    let fixture = try Base.fixture(
      behavior, check: check, interactive: true, environment: environment)
    if mode == .marker { try fixture.store.createTestModeMarker() }
    return fixture
  } // End of func fixture(_:behavior:check:)

  /// An SSH request for `$3` asking for a delay of `seconds`.
  static func request(delay seconds: Int?, host: LaunchHost = .ssh(destination: "fixture-remote"))
    -> LaunchRequest
  {
    var request = LaunchTestSupport.request(host: host)
    request.testLaunchDelaySeconds = seconds
    return request
  }

  /// In test mode the helper first runs `/bin/sleep 30` as a check-stage child (deadline 35 s,
  /// stdin `/dev/null`, the cleaned environment) and says so in the tab, then runs ssh as
  /// usual; outside test mode the field changes nothing: no extra child, nothing printed.
  /// Either way the result is a success and the tab is held until the minimum lifetime.
  @Test(arguments: Mode.allCases)
  func delaysOnlyInTestMode(_ mode: Mode) async throws {
    let fixture = try Self.fixture(mode)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.request(delay: 30)
    let (status, _) = try await Base.attach(fixture, request: request)
    #expect(status == 0)
    let call = try #require(fixture.runner.calls.first)
    #expect(fixture.runner.calls.count == 1)
    #expect(call.executable == RemoteLaunch.sshPath)
    #expect(call.arguments == RemoteLaunch.sshArguments(for: request))
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.succeeded)
    #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
    guard mode != .off else {
      #expect(fixture.runner.checks.isEmpty)
      #expect(fixture.terminal.text.isEmpty)
      return
    }
    let delay = try #require(fixture.runner.checks.first)
    #expect(fixture.runner.checks.count == 1)
    #expect(delay.executableURL.path(percentEncoded: false) == "/bin/sleep")
    #expect(delay.arguments == ["30"])
    #expect(delay.timeout == .seconds(35))
    #expect(delay.standardInput == .nullDevice)
    #expect(delay.environment.keys.allSatisfy { !$0.hasPrefix("MUXFINDER_LAUNCH_") })
    #expect(fixture.terminal.text == "muxFinder test mode: waiting 30 s before starting.\n")
  } // End of func delaysOnlyInTestMode(_:)

  /// A request without the field never waits, in test mode too; a local request in test mode
  /// waits before its check, which then runs as usual.
  @Test func delaysOnlyWhenAsked() async throws {
    let plain = try Self.fixture(.variable)
    defer { try? FileManager.default.removeItem(at: plain.root) }
    let (plainStatus, _) = try await Base.attach(plain, request: Self.request(delay: nil))
    #expect(plainStatus == 0)
    #expect(plain.runner.checks.isEmpty)
    #expect(plain.terminal.text.isEmpty)

    let local = try Self.fixture(.marker)
    defer { try? FileManager.default.removeItem(at: local.root) }
    var request = Self.request(delay: 5, host: .local)
    request.tmuxPathOverride = local.tmuxPath
    let (localStatus, _) = try await Base.attach(local, request: request)
    #expect(localStatus == 0)
    #expect(
      local.runner.checks.map { $0.executableURL.path(percentEncoded: false) } == [
        "/bin/sleep", LaunchGuard.shellPath,
      ])
    #expect(local.runner.checks.first?.arguments == ["5"])
    #expect(local.runner.calls.map(\.executable) == [local.tmuxPath])
  } // End of func delaysOnlyWhenAsked()

  /// A signal during the delay ends the launch like a signal during a check: `interrupted(n)`
  /// written as the result, no ssh started. After a SIGHUP (the tab closed) nobody can see the
  /// tab, so there is no wait and no hold; after a SIGINT or SIGTERM the explanation is
  /// followed by the wait for Return and the hold until the helper is 10 s old.
  @Test(arguments: [SIGHUP, SIGINT, SIGTERM])
  func aSignalEndsTheDelayLikeACheck(_ signalNumber: Int32) async throws {
    let fixture = try Self.fixture(.marker, check: .interrupted([signalNumber]))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.request(delay: 60)
    let (status, _) = try await Base.attach(fixture, request: request)
    #expect(status == 128 + signalNumber)
    #expect(fixture.runner.checks.count == 1)
    #expect(fixture.runner.calls.isEmpty)
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.failure == .interrupted(signalNumber))
    #expect(result.childTermination == nil)
    let explanation = LaunchFailure.interrupted(signalNumber).explanation(for: request.host)
    #expect(fixture.terminal.text.contains(explanation))
    if signalNumber == SIGHUP {
      #expect(fixture.terminal.pauses.isEmpty)
    } else {
      #expect(fixture.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
    }
  } // End of func aSignalEndsTheDelayLikeACheck(_:)

  /// A delay outside 1–120 s makes the request not well formed, so the helper refuses it as
  /// unreadable (72) without running anything, in test mode too; the bounds themselves are
  /// accepted, and the field survives a JSON round trip (absent when not set).
  @Test func refusesADelayOutsideItsRange() async throws {
    for seconds in [0, -1, 121, Int.max] {
      #expect(!Self.request(delay: seconds).isWellFormed)
      let fixture = try Self.fixture(.variable)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let (status, _) = try await Base.attach(fixture, request: Self.request(delay: seconds))
      #expect(status == LaunchExitStatus.requestUnreadable)
      #expect(fixture.runner.checks.isEmpty && fixture.runner.calls.isEmpty)
    } // End of loop over out-of-range delays
    #expect(Self.request(delay: 1).isWellFormed)
    #expect(Self.request(delay: 120).isWellFormed)
    let request = Self.request(delay: 45)
    let data = try LaunchCoding.encoder().encode(request)
    let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(object["testLaunchDelaySeconds"] as? Int == 45)
    #expect(try LaunchCoding.decoder().decode(LaunchRequest.self, from: data) == request)
    let plain = try LaunchCoding.encoder().encode(Self.request(delay: nil))
    #expect(!String(decoding: plain, as: UTF8.self).contains("testLaunchDelaySeconds"))
  } // End of func refusesADelayOutsideItsRange()

  /// With the real runner (marker set, a local request), the delay is a real `/bin/sleep`: the
  /// helper waits in it, and a SIGHUP passed on ends it at once as `interrupted` (129), long
  /// before the delay runs out; the check never runs (the fake tmux is never called).
  @Test(.timeLimit(.minutes(1)))
  func aPassedOnSignalEndsARealDelay() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    try store.createTestModeMarker()
    let tmux = try LaunchTestSupport.installFakeTmux(in: root)
    let control = TerminalChildControl()
    let terminal = FakeLaunchTerminal(isInteractive: true)
    let helper = LaunchHelper(
      store: store,
      environment: [
        "PATH": ProcessEnvironment.systemSearchPath,
        "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
      ],
      childRunner: TerminalChildRunner(control: control, checkRunner: TestSupport.fastRunner),
      terminal: terminal,
      log: DiagnosticsLog(writesToSystemLog: false),
      processID: getpid()
    )
    var request = LaunchTestSupport.request(createdAt: Date(), tmuxPathOverride: tmux)
    request.testLaunchDelaySeconds = 30
    try store.writeRequest(request)
    let launchID = request.id.rawValue
    let running = Task { await helper.run(arguments: ["muxfinder-launch", "attach", launchID]) }
    let waiting = await TestSupport.eventually(within: .seconds(10)) {
      terminal.text.contains("test mode: waiting 30 s")
    }
    try await Task.sleep(for: .milliseconds(300))
    let clock = ContinuousClock()
    let signaledAt = clock.now
    control.forward(SIGHUP)
    let status = await running.value
    #expect(waiting)
    #expect(signaledAt.duration(to: clock.now) < .seconds(5))
    #expect(status == 128 + SIGHUP)
    let result = try #require(try store.takeResult(request.id))
    #expect(result.failure == .interrupted(SIGHUP))
    #expect(terminal.pauses.isEmpty)
    #expect(!TestSupport.fileExists("attach", in: root))
  } // End of func aPassedOnSignalEndsARealDelay()
}
