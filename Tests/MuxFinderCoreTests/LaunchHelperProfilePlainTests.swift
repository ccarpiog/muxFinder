import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// `muxfinder-launch profile-plain <host id>` in this process (PLAN.md D26, D38; Phase I-12b2):
/// `profile` without `-CC`, with the same host list, nesting guard, fallbacks and hold; its
/// tmux (or ssh) child on the terminal opened read-write; test mode recording the child's pid.
/// `profile` itself is unchanged (control mode, inherited standard input). Nothing real is
/// started.
@Suite("Launch helper plain profile mode")
struct LaunchHelperProfilePlainTests {
  /// Everything one test needs.
  struct Fixture {
    /// The helper under test.
    let helper: LaunchHelper
    /// The fake child runner.
    let base: FakeLaunchChildRunner
    /// The runner the helper uses, recording each call's standard input.
    let runner: StandardInputRecordingRunner
    /// The fake terminal.
    let terminal: FakeLaunchTerminal
    /// The fake login shell.
    let shell: FakeLoginShell
    /// The launch store.
    let store: LaunchStore
    /// The temporary root to remove.
    let root: URL
    /// A real executable the passing check prints.
    let tmuxPath: String
  }

  /// Builds a helper over a host list holding `hosts` (`LaunchHelperProfileTests`' hosts), with
  /// a fixed clock (so every hold is the whole minimum lifetime).
  static func fixture(
    hosts: [HostConfig]? = [
      LaunchHelperProfileTests.local, LaunchHelperProfileTests.remote, LaunchHelperProfileTests.off,
    ],
    _ behavior: FakeLaunchChildRunner.Behavior = .termination(.exited(0), forwarded: []),
    interactive: Bool = true,
    environment: [String: String] = ["LANG": "en_US.UTF-8", "HOME": "/Users/tester"]
  ) async throws -> Fixture {
    let (store, root) = try LaunchTestSupport.makeStore()
    let tmuxPath = try LaunchTestSupport.installFakeTmux(in: root)
    let support = root.appending(path: "support", directoryHint: .isDirectory)
    let hostStore = HostStore(fileURL: support.appending(path: HostStore.fileName))
    if let hosts {
      try FileManager.default.createDirectory(
        at: support, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      try await hostStore.save(try HostList(hosts))
    }
    let base = FakeLaunchChildRunner(behavior, check: .passes(tmuxPath: tmuxPath))
    let runner = StandardInputRecordingRunner(base)
    let terminal = FakeLaunchTerminal(isInteractive: interactive)
    let shell = FakeLoginShell()
    let start = LaunchTestSupport.requestTime
    let helper = LaunchHelper(
      store: store, environment: environment, childRunner: runner, terminal: terminal,
      log: DiagnosticsLog(writesToSystemLog: false), processID: 4321,
      now: { start.addingTimeInterval(1) }, checkTimeout: .seconds(7), hostStore: hostStore,
      loginShell: shell, plainFacts: PlainLaunchTestSupport.facts)
    return Fixture(
      helper: helper, base: base, runner: runner, terminal: terminal, shell: shell, store: store,
      root: root, tmuxPath: tmuxPath)
  } // End of func fixture(hosts:_:interactive:environment:)

  /// Runs `<mode> <host id>`.
  static func run(
    _ fixture: Fixture,
    hostID: UUID,
    mode: LaunchHelperMode = .profilePlain
  ) async -> Int32 {
    await fixture.helper.run(
      arguments: [LaunchHelperTests.helperPath, mode.word, LaunchToken(uuid: hostID).rawValue])
  }

  /// On This Mac: the same locator check as `profile`, then tmux with `-u new-session -A -s
  /// <escaped name>` (no `-CC`) on the terminal opened read-write; a detach ends it after the
  /// hold, as `profile`. `profile` for the same host still runs `-CC` on the inherited input.
  @Test func localPlainProfile() async throws {
    var calls: [[String]] = []
    for mode in [LaunchHelperMode.profilePlain, .profile] {
      let fixture = try await Self.fixture()
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      #expect(await Self.run(fixture, hostID: LaunchHelperProfileTests.local.id, mode: mode) == 0)
      let check = try #require(fixture.base.checks.first)
      #expect(
        check.arguments
          == ProfileLaunch.locateRequest(override: nil, environment: [:], timeout: .seconds(7))
          .arguments)
      let call = try #require(fixture.base.calls.first)
      #expect(call.executable == fixture.tmuxPath && !call.relaysStandardError)
      #expect(call.environment["MUXFINDER_LAUNCHED"] == "1")
      #expect(
        fixture.runner.standardInputs == [mode == .profilePlain ? .terminalReadWrite : .inherited])
      #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
      #expect(fixture.shell.execs.isEmpty && fixture.terminal.statusReports.isEmpty)
      #expect(try LaunchTestSupport.names(in: fixture.store.directory).isEmpty)
      calls.append(call.arguments)
    } // End of loop over the two modes
    #expect(calls[0] == ["-u", "new-session", "-A", "-s", #"work ##1\;"#])
    #expect(calls[0] == ProfileLaunch.plainTmuxArguments(sessionName: "work #1;"))
    #expect(calls[1] == ProfileLaunch.tmuxArguments(sessionName: "work #1;"))
  } // End of func localPlainProfile()

  /// On an SSH host: D17's interactive ssh with `plainRemoteScript` and the two quoted values,
  /// its standard error relayed, on the terminal opened read-write.
  @Test func remotePlainProfile() async throws {
    let fixture = try await Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: LaunchHelperProfileTests.remote.id) == 0)
    #expect(fixture.base.checks.isEmpty)
    let call = try #require(fixture.base.calls.first)
    #expect(call.executable == "/usr/bin/ssh" && call.relaysStandardError)
    let expected = try #require(
      ProfileLaunch.plainSSHArguments(
        destination: "tester@remote.example.test", override: "/opt/x/tmux", sessionName: "main"))
    #expect(call.arguments == expected)
    #expect(
      call.arguments.last
        == ShellQuoting.remoteCommand(
          script: ProfileLaunch.plainRemoteScript, args: ["/opt/x/tmux", "main"]))
    #expect(fixture.runner.standardInputs == [.terminalReadWrite])
  } // End of func remotePlainProfile()

  /// The plain remote script is the profile's with `-CC` taken out of its one tmux line, and
  /// run by a stand-in login shell it `exec`s the plain `new-session -A` with the escaped name.
  @Test(arguments: ProfileLaunchTests.hostileNames)
  func plainRemoteScriptRunsPlainTmux(name: String) async throws {
    #expect(
      ProfileLaunch.plainRemoteScript.source
        == ProfileLaunch.remoteScript.source.replacingOccurrences(
          of: #"exec "$t" -u -CC new-session"#, with: #"exec "$t" -u new-session"#))
    #expect(!ProfileLaunch.plainRemoteScript.source.contains("-CC"))
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tmux = try ProfileLaunchTests.installFakeTmux(in: directory)
    let result = try await TestSupport.fastRunner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: "/bin/sh"),
        arguments: ["-c", ProfileLaunch.plainRemoteCommand(override: tmux, sessionName: name)],
        environment: [
          "PATH": ProcessEnvironment.systemSearchPath, "TMUX": "/tmp/x,1,0",
          "MUXFINDER_FAKE_DIR": directory.path(percentEncoded: false),
        ],
        timeout: .seconds(10)))
    #expect(result.termination == .exited(0))
    #expect(
      try ProfileLaunchTests.recordedArguments(in: directory)
        == ["-u", "new-session", "-A", "-s", TmuxWord.escaped(name)])
  } // End of func plainRemoteScriptRunsPlainTmux(name:)

  /// The fallbacks are `profile`'s: the nesting guard starts the login shell before anything
  /// (77 when it cannot), an unknown host and a failed tmux explain and start it too.
  @Test func fallsBackLikeProfile() async throws {
    let nested = try await Self.fixture(
      environment: ["TMUX": "/private/tmp/tmux-501/default,1,0", "HOME": "/Users/tester"])
    defer { try? FileManager.default.removeItem(at: nested.root) }
    #expect(
      await Self.run(nested, hostID: LaunchHelperProfileTests.local.id)
        == LaunchExitStatus.nestedLaunch)
    #expect(nested.base.checks.isEmpty && nested.base.calls.isEmpty)
    #expect(nested.shell.execs.count == 1)

    let unknown = try await Self.fixture()
    defer { try? FileManager.default.removeItem(at: unknown.root) }
    #expect(
      await Self.run(unknown, hostID: UUID()) == LaunchExitStatus.profileHostUnavailable)
    #expect(unknown.base.calls.isEmpty && unknown.shell.execs.count == 1)

    let failed = try await Self.fixture(.termination(.exited(1), forwarded: []))
    defer { try? FileManager.default.removeItem(at: failed.root) }
    #expect(await Self.run(failed, hostID: LaunchHelperProfileTests.local.id) == 1)
    #expect(failed.shell.execs.count == 1)
    #expect(failed.terminal.text.contains("Starting your login shell instead."))
  } // End of func fallsBackLikeProfile()

  /// Test mode: the digest records the plain child and its process id; the login shell is
  /// recorded, not started, when the profile falls back.
  @Test func testModeDigest() async throws {
    let fixture = try await Self.fixture(
      environment: [LaunchHelper.testModeVariable: "1", "HOME": "/Users/tester"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: LaunchHelperProfileTests.local.id) == 0)
    let digest = try #require(try fixture.store.takeArgvDigests().first)
    #expect(
      digest.attachChild
        == LaunchArgvDigest.AttachChild(
          executable: fixture.tmuxPath,
          arguments: ProfileLaunch.plainTmuxArguments(sessionName: "work #1;"),
          detachesOtherClients: false))
    #expect(digest.attachChildProcessID == FakeLaunchChildRunner.childProcessID)

    let profile = try await Self.fixture(
      environment: [LaunchHelper.testModeVariable: "1", "HOME": "/Users/tester"])
    defer { try? FileManager.default.removeItem(at: profile.root) }
    #expect(
      await Self.run(profile, hostID: LaunchHelperProfileTests.local.id, mode: .profile) == 0)
    let unchanged = try #require(try profile.store.takeArgvDigests().first)
    #expect(unchanged.attachChildProcessID == nil)

    let fallback = try await Self.fixture(
      .termination(.exited(1), forwarded: []),
      environment: [LaunchHelper.testModeVariable: "1", "HOME": "/Users/tester"])
    defer { try? FileManager.default.removeItem(at: fallback.root) }
    #expect(await Self.run(fallback, hostID: LaunchHelperProfileTests.local.id) == 1)
    #expect(fallback.shell.execs.isEmpty)
    let recorded = try #require(try fallback.store.takeArgvDigests().first)
    #expect(recorded.attachChild?.startsLoginShell == true)
  } // End of func testModeDigest()
} // End of struct LaunchHelperProfilePlainTests
