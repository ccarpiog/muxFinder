import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// A `LoginShellStarting` that never starts anything: it records each exec it is asked for and
/// answers with `result` (`.replaced` pretends the exec worked).
final class FakeLoginShell: LoginShellStarting {
  /// One recorded exec.
  struct Exec: Sendable, Equatable {
    /// The shell.
    var shell: LoginShell
    /// Its environment.
    var environment: [String: String]
  }

  /// The candidates offered.
  let offered: [LoginShell]
  /// Every exec's answer.
  let result: LoginShellExecResult
  /// The execs asked for so far.
  private let recorded = OSAllocatedUnfairLock<[Exec]>(initialState: [])

  /// Creates a fake offering `offered` and answering `result`.
  init(
    offered: [LoginShell] = [LoginShell(path: "/bin/test-zsh"), LoginShell(path: "/bin/test-sh")],
    result: LoginShellExecResult = .replaced
  ) {
    self.offered = offered
    self.result = result
  }

  /// The execs asked for so far.
  var execs: [Exec] { recorded.withLock { $0 } }

  /// The offered shells.
  func candidates() -> [LoginShell] { offered }

  /// Records the exec and answers `result`.
  func exec(_ shell: LoginShell, environment: [String: String]) -> LoginShellExecResult {
    recorded.withLock { $0.append(Exec(shell: shell, environment: environment)) }
    return result
  }
} // End of class FakeLoginShell

/// `muxfinder-launch profile <host id>` in this process (PLAN.md D26), with a fake child runner,
/// terminal and login shell, a private launch directory and a private host list: the nesting
/// guard (both variables), the host list fallbacks, the local and remote children, the failure
/// fallback to the login shell, test mode and the minimum lifetime. Nothing real is started.
@Suite("Launch helper profile mode")
struct LaunchHelperProfileTests {
  /// Everything one test needs.
  struct Fixture {
    /// The helper under test.
    let helper: LaunchHelper
    /// The fake child runner.
    let runner: FakeLaunchChildRunner
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

  /// This Mac with a profile, its session `work #1;`.
  static let local = HostConfig(
    id: UUID(uuidString: "0F8FAD5B-D9CB-469F-A165-70867728950E")!, displayName: "Local",
    mode: .local, persistentProfileEnabled: true, defaultSessionName: "work #1;")
  /// An SSH host with a profile and a tmux override, turned off for discovery.
  static let remote = HostConfig(
    id: UUID(uuidString: "7C9E6679-7425-40DE-944B-E07FC1F90AE7")!, displayName: "Remote",
    mode: .ssh, sshDestination: "tester@remote.example.test", tmuxPathOverride: "/opt/x/tmux",
    isEnabled: false, persistentProfileEnabled: true)
  /// A host without a profile.
  static let off = HostConfig(
    id: UUID(uuidString: "6F9619FF-8B86-D011-B42D-00C04FC964FF")!, displayName: "Off",
    mode: .ssh, sshDestination: "off.example.test")

  /// Builds a helper over a host list holding `hosts` (none: no `hosts.json`), with a fixed
  /// clock (so every hold is the whole minimum lifetime).
  static func fixture(
    hosts: [HostConfig]? = [local, remote, off],
    _ behavior: FakeLaunchChildRunner.Behavior = .termination(.exited(0), forwarded: []),
    check: FakeLaunchChildRunner.CheckBehavior? = nil,
    interactive: Bool = true,
    environment: [String: String] = ["LANG": "en_US.UTF-8", "HOME": "/Users/tester"],
    shell: FakeLoginShell = FakeLoginShell()
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
    let runner = FakeLaunchChildRunner(behavior, check: check ?? .passes(tmuxPath: tmuxPath))
    let terminal = FakeLaunchTerminal(isInteractive: interactive)
    let start = LaunchTestSupport.requestTime
    let helper = LaunchHelper(
      store: store, environment: environment, childRunner: runner, terminal: terminal,
      log: DiagnosticsLog(writesToSystemLog: false), processID: 4321,
      now: { start.addingTimeInterval(1) }, checkTimeout: .seconds(7),
      hostStore: hostStore, loginShell: shell)
    return Fixture(
      helper: helper, runner: runner, terminal: terminal, shell: shell, store: store, root: root,
      tmuxPath: tmuxPath)
  } // End of func fixture(hosts:_:check:interactive:environment:shell:)

  /// Runs `profile <id>` with argv[0] the app's helper path.
  static func run(_ fixture: Fixture, hostID: UUID) async -> Int32 {
    await fixture.helper.run(
      arguments: [LaunchHelperTests.helperPath, "profile", LaunchToken(uuid: hostID).rawValue])
  }

  // MARK: - Nesting guard

  /// With `TMUX` or `MUXFINDER_LAUNCHED` set, the helper prints one line and starts the login
  /// shell at once: no host list read, no check, no tmux, no hold; the shell keeps `TMUX`, gets
  /// `MUXFINDER_LAUNCHED=1` and loses the helper's own variables.
  @Test(arguments: [("TMUX", "/private/tmp/tmux-501/default,1,0"), ("MUXFINDER_LAUNCHED", "1")])
  func nestingGuardStartsTheLoginShell(variable: String, value: String) async throws {
    let fixture = try await Self.fixture(
      hosts: nil,
      environment: [
        variable: value, "HOME": "/Users/tester", "MUXFINDER_LAUNCH_NO_WAIT": "0",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let status = await Self.run(fixture, hostID: Self.local.id)
    #expect(status == LaunchExitStatus.nestedLaunch)
    #expect(fixture.runner.checks.isEmpty && fixture.runner.calls.isEmpty)
    #expect(fixture.terminal.pauses.isEmpty)
    let lines = fixture.terminal.text.split(separator: "\n")
    #expect(lines.count == 1)
    #expect(lines.first?.contains("(\(variable) is set)") == true)
    #expect(lines.first?.hasSuffix("Starting your login shell instead.") == true)
    let exec = try #require(fixture.shell.execs.first)
    #expect(fixture.shell.execs.count == 1)
    #expect(exec.shell.path == "/bin/test-zsh")
    #expect(exec.environment[variable] == value)
    #expect(exec.environment["MUXFINDER_LAUNCHED"] == "1")
    #expect(exec.environment["MUXFINDER_LAUNCH_NO_WAIT"] == nil)
    #expect(exec.environment["HOME"] == "/Users/tester")
  } // End of func nestingGuardStartsTheLoginShell(variable:value:)

  /// Empty `TMUX` and `MUXFINDER_LAUNCHED` count as unset, as tmux treats `TMUX=`.
  @Test func emptyNestingVariablesDoNotTrigger() async throws {
    let fixture = try await Self.fixture(environment: ["TMUX": "", "MUXFINDER_LAUNCHED": ""])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: Self.local.id) == 0)
    #expect(fixture.shell.execs.isEmpty)
    #expect(fixture.runner.calls.count == 1)
  }

  // MARK: - Host list

  /// No host list, an unknown host and a host without a profile each explain and start the
  /// login shell; nothing else runs and the host list is never written.
  @Test func unusableHostsFallBackToTheLoginShell() async throws {
    let cases: [([HostConfig]?, UUID, String)] = [
      (nil, Self.local.id, "no saved host list"),
      ([Self.local], UUID(), "no longer in muxFinder's host list"),
      ([Self.local, Self.off], Self.off.id, "turned off in muxFinder's settings"),
    ]
    for (hosts, hostID, wording) in cases {
      let fixture = try await Self.fixture(hosts: hosts)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      let support = fixture.root.appending(path: "support")
      let before = try? Data(contentsOf: support.appending(path: HostStore.fileName))
      #expect(await Self.run(fixture, hostID: hostID) == LaunchExitStatus.profileHostUnavailable)
      #expect(fixture.terminal.text.contains(wording))
      #expect(fixture.terminal.text.contains("Starting your login shell instead."))
      #expect(fixture.shell.execs.count == 1)
      #expect(fixture.runner.checks.isEmpty && fixture.runner.calls.isEmpty)
      #expect((try? Data(contentsOf: support.appending(path: HostStore.fileName))) == before)
      #expect(LaunchTestSupport.exists(support) == (hosts != nil))
    } // End of loop over the unusable hosts
  } // End of func unusableHostsFallBackToTheLoginShell()

  // MARK: - Local

  /// This Mac: the D5 check with the override argument and its deadline, then tmux by argv
  /// with `-u -CC new-session -A -s <escaped name>`, on the tab's terminal; `TMUX` never
  /// reaches the children, `MUXFINDER_LAUNCHED=1` does; a detach ends the helper (status 0)
  /// after the hold to the minimum lifetime, with no login shell.
  @Test func localStartsTmuxNewSessionA() async throws {
    let fixture = try await Self.fixture(environment: ["TMUX": "", "LANG": "en_US.UTF-8"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: Self.local.id) == 0)
    let check = try #require(fixture.runner.checks.first)
    #expect(check.executableURL.path(percentEncoded: false) == "/bin/sh")
    #expect(
      check.arguments == ["-c", ProfileLaunch.locateScript.source, "muxfinder", ""])
    #expect(check.timeout == .seconds(7))
    let call = try #require(fixture.runner.calls.first)
    #expect(call.executable == fixture.tmuxPath)
    #expect(call.arguments == ["-u", "-CC", "new-session", "-A", "-s", #"work ##1\;"#])
    #expect(!call.relaysStandardError)
    for environment in [check.environment, call.environment] {
      #expect(environment["TMUX"] == nil && environment["TMUX_PANE"] == nil)
      #expect(environment["MUXFINDER_LAUNCHED"] == "1")
      #expect(environment["LANG"] == "en_US.UTF-8")
    }
    #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
    #expect(fixture.shell.execs.isEmpty)
    #expect(fixture.terminal.text.isEmpty)
  } // End of func localStartsTmuxNewSessionA()

  /// A failed check (tmux missing) or a failed tmux (exit 1, a signal, a spawn error) explains
  /// in profile wording and starts the login shell; tmux never starts after a failed check.
  @Test func localFailuresFallBackToTheLoginShell() async throws {
    let cases:
      [(FakeLaunchChildRunner.Behavior, FakeLaunchChildRunner.CheckBehavior?, String, Int)] = [
        (.termination(.exited(0), forwarded: []), .exits(66), "could not find tmux on this Mac", 0),
        (.termination(.exited(0), forwarded: []), .timesOut, "did not answer in time", 0),
        (.termination(.exited(1), forwarded: []), nil, "tmux ended with exit status 1.", 1),
        (.termination(.signaled(SIGKILL), forwarded: []), nil, "tmux was stopped by signal 9.", 1),
        (.error(.spawnFailed(errno: ENOENT)), nil, "could not start tmux", 1),
      ]
    for (behavior, check, wording, tmuxRuns) in cases {
      let fixture = try await Self.fixture(behavior, check: check)
      defer { try? FileManager.default.removeItem(at: fixture.root) }
      _ = await Self.run(fixture, hostID: Self.local.id)
      #expect(fixture.runner.calls.count == tmuxRuns)
      #expect(fixture.terminal.text.contains(wording), "\(fixture.terminal.text)")
      #expect(fixture.terminal.text.contains("Starting your login shell instead."))
      #expect(fixture.shell.execs.count == 1)
      #expect(fixture.terminal.pauses.isEmpty)
    } // End of loop over the local failures
  } // End of func localFailuresFallBackToTheLoginShell()

  /// A tab closed while tmux ran (SIGHUP passed on) starts nothing and holds nothing.
  @Test func closedTabStartsNothing() async throws {
    let fixture = try await Self.fixture(.termination(.signaled(SIGHUP), forwarded: [SIGHUP]))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: Self.local.id) == 128 + SIGHUP)
    #expect(fixture.shell.execs.isEmpty)
    #expect(fixture.terminal.pauses.isEmpty)
    #expect(fixture.terminal.text.isEmpty)
  }

  // MARK: - Remote

  /// An SSH host: one ssh child, D17's interactive options, the destination after `--` and the
  /// D3 string with the override and `main` single-quoted, its standard error relayed; no
  /// local check. ssh's own failure (255, authentication) explains and starts the login shell.
  @Test func remoteRunsSSHWithTheStaticScript() async throws {
    let fixture = try await Self.fixture(
      .termination(
        .exited(255), forwarded: [],
        standardError: "tester@remote.example.test: Permission denied (publickey).\n"))
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: Self.remote.id) == 255)
    #expect(fixture.runner.checks.isEmpty)
    let call = try #require(fixture.runner.calls.first)
    #expect(call.executable == "/usr/bin/ssh")
    #expect(
      call.arguments == [
        "-t", "-o", "ConnectTimeout=10", "--", "tester@remote.example.test",
        ShellQuoting.remoteCommand(
          script: ProfileLaunch.remoteScript, args: ["/opt/x/tmux", "main"]),
      ])
    #expect(call.relaysStandardError)
    #expect(call.environment["MUXFINDER_LAUNCHED"] == "1")
    #expect(fixture.terminal.text.contains("ssh could not log in to the host"))
    #expect(fixture.shell.execs.count == 1)
  } // End of func remoteRunsSSHWithTheStaticScript()

  /// A remote detach ends the helper normally (0) after the hold.
  @Test func remoteDetachEndsNormally() async throws {
    let fixture = try await Self.fixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: Self.remote.id) == 0)
    #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
    #expect(fixture.shell.execs.isEmpty)
  }

  // MARK: - Minimum lifetime and no shell

  /// When the login shell cannot start (every candidate fails), the helper says so, waits for
  /// Return and holds the tab to the minimum lifetime, then exits 74; with no candidate at all
  /// the same, without an exec.
  @Test func shellThatCannotStartNeverEndsTheTabEarly() async throws {
    let failing = FakeLoginShell(result: .failed(errno: ENOENT))
    let fixture = try await Self.fixture(hosts: nil, shell: failing)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: Self.local.id) == LaunchExitStatus.spawnFailed)
    #expect(failing.execs.map(\.shell.path) == ["/bin/test-zsh", "/bin/test-sh"])
    #expect(fixture.terminal.text.contains("could not start your login shell"))
    #expect(fixture.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])

    let none = FakeLoginShell(offered: [])
    let empty = try await Self.fixture(hosts: nil, shell: none)
    defer { try? FileManager.default.removeItem(at: empty.root) }
    #expect(await Self.run(empty, hostID: Self.local.id) == LaunchExitStatus.profileHostUnavailable)
    #expect(none.execs.isEmpty)
    #expect(!empty.terminal.text.contains("Starting your login shell"))
    #expect(empty.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
  } // End of func shellThatCannotStartNeverEndsTheTabEarly()

  /// A terminal that is not interactive (tests, `MUXFINDER_LAUNCH_NO_WAIT=1`) never gets a
  /// login shell: the explanation, then the problem's status, without waits.
  @Test func nonInteractiveTerminalStartsNoShell() async throws {
    let fixture = try await Self.fixture(hosts: nil, interactive: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(
      await Self.run(fixture, hostID: Self.local.id) == LaunchExitStatus.profileHostUnavailable)
    #expect(fixture.shell.execs.isEmpty)
    #expect(fixture.terminal.pauses.isEmpty)
    #expect(!fixture.terminal.text.contains("Starting your login shell"))
  }

  // MARK: - Test mode

  /// In test mode the login shell is recorded in the argv digest (argv `[-<name>]`, marked
  /// `startsLoginShell`) and never started; the helper then waits and holds like a failure.
  @Test func testModeRecordsTheShellWithoutStartingIt() async throws {
    let fixture = try await Self.fixture(
      environment: ["MUXFINDER_LAUNCH_TEST_MODE": "1", "MUXFINDER_LAUNCHED": "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    #expect(await Self.run(fixture, hostID: Self.local.id) == LaunchExitStatus.nestedLaunch)
    #expect(fixture.shell.execs.isEmpty)
    #expect(fixture.terminal.text.contains("muxFinder test mode: the login shell was not started."))
    #expect(fixture.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
    let digest = try #require(try fixture.store.takeArgvDigests().first)
    #expect(digest.argumentCount == 3)
    #expect(digest.launchID == LaunchToken(uuid: Self.local.id))
    #expect(
      digest.attachChild
        == LaunchArgvDigest.AttachChild(
          executable: "-test-zsh", arguments: [], detachesOtherClients: false,
          startsLoginShell: true))
  } // End of func testModeRecordsTheShellWithoutStartingIt()

  /// In test mode a test host list for the profile's host in the launch directory replaces
  /// `hosts.json` (here missing); its tmux child is recorded in the digest; another host id
  /// still reads `hosts.json`.
  @Test func testModeReadsTheTestHostList() async throws {
    let fixture = try await Self.fixture(
      hosts: nil, environment: ["MUXFINDER_LAUNCH_TEST_MODE": "1"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let testHost = HostConfig(
      displayName: "muxFinder test", mode: .local, tmuxPathOverride: fixture.tmuxPath,
      persistentProfileEnabled: true, defaultSessionName: "muxfinder-test-profile")
    try fixture.store.writeProfileTestHosts(try HostList([testHost]), forHostID: testHost.id)
    let file = fixture.store.profileTestHostsURL(forHostID: testHost.id)
    #expect(try LaunchTestSupport.permissions(of: file) == 0o600)

    #expect(await Self.run(fixture, hostID: testHost.id) == 0)
    let call = try #require(fixture.runner.calls.first)
    #expect(call.arguments == ProfileLaunch.tmuxArguments(sessionName: "muxfinder-test-profile"))
    #expect(fixture.runner.checks.first?.arguments.last == fixture.tmuxPath)
    let digest = try #require(try fixture.store.takeArgvDigests().first)
    #expect(
      digest.attachChild
        == LaunchArgvDigest.AttachChild(
          executable: fixture.tmuxPath, arguments: call.arguments, detachesOtherClients: false))

    // Another host: no test list for it, so hosts.json (missing) decides.
    #expect(
      await Self.run(fixture, hostID: Self.local.id) == LaunchExitStatus.profileHostUnavailable)
    #expect(try fixture.store.removeProfileTestHosts(forHostID: testHost.id))
    #expect(!LaunchTestSupport.exists(file))
  } // End of func testModeReadsTheTestHostList()

  /// Outside test mode the test host list is ignored.
  @Test func testHostListNeedsTestMode() async throws {
    let fixture = try await Self.fixture(hosts: nil)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let testHost = HostConfig(
      displayName: "muxFinder test", mode: .local, persistentProfileEnabled: true)
    try fixture.store.writeProfileTestHosts(try HostList([testHost]), forHostID: testHost.id)
    #expect(await Self.run(fixture, hostID: testHost.id) == LaunchExitStatus.profileHostUnavailable)
    #expect(fixture.runner.calls.isEmpty)
  }

  // MARK: - Every mode

  /// The attach mode's children carry `MUXFINDER_LAUNCHED=1` too, so a profile tab started from
  /// inside an attached session's shell is caught by the nesting guard.
  @Test func attachChildrenCarryTheLaunchedVariable() async throws {
    let fixture = try LaunchHelperTests.fixture(environment: ["LANG": "en_US.UTF-8"])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    _ = try await LaunchHelperTests.attach(fixture)
    #expect(fixture.runner.checks.first?.environment["MUXFINDER_LAUNCHED"] == "1")
    #expect(fixture.runner.calls.first?.environment["MUXFINDER_LAUNCHED"] == "1")
  }

  /// Usage: `profile` takes exactly one canonical host id.
  @Test func parsesProfileMode() {
    let id = LaunchToken(uuid: Self.local.id)
    let argv = { (words: [String]) in words.map { Array($0.utf8) } }
    #expect(LaunchHelper.parse(argv(["h", "profile", id.rawValue])) == .profile(id))
    #expect(LaunchHelper.parse(argv(["h", "profile", id.rawValue.uppercased()])) == nil)
    #expect(LaunchHelper.parse(argv(["h", "profile"])) == nil)
    #expect(LaunchHelper.parse(argv(["h", "profile", id.rawValue, "x"])) == nil)
    #expect(LaunchHelper.usage.contains("profile <host id>"))
  }

  /// Login shell candidates: the passwd entry's when usable, then `/bin/zsh` and `/bin/sh`,
  /// each once and only when usable; argv[0] is `-<name>`.
  @Test func loginShellCandidates() {
    let usable: (String) -> Bool = { ["/opt/test/fish", "/bin/zsh", "/bin/sh"].contains($0) }
    #expect(
      LoginShell.candidates(passwdShell: "/opt/test/fish", isUsable: usable).map(\.path)
        == ["/opt/test/fish", "/bin/zsh", "/bin/sh"])
    #expect(
      LoginShell.candidates(passwdShell: "/missing/shell", isUsable: usable).map(\.path)
        == ["/bin/zsh", "/bin/sh"])
    #expect(
      LoginShell.candidates(passwdShell: "/bin/zsh", isUsable: usable).map(\.path)
        == ["/bin/zsh", "/bin/sh"])
    #expect(LoginShell.candidates(passwdShell: nil, isUsable: { _ in false }).isEmpty)
    #expect(LoginShell(path: "/bin/zsh").argv0 == "-zsh")
    #expect(LoginShell.isUsable("/bin/sh"))
    #expect(!LoginShell.isUsable("sh"))
    #expect(!LoginShell.isUsable("/nonexistent/muxfinder-test/sh"))
    #expect(!LoginShell.isUsable("/bin"))
  } // End of func loginShellCandidates()
}
