import Foundation
import Testing

@testable import MuxFinderCore

/// The built `muxfinder-launch` in `profile` mode (PLAN.md D26), run as a child of the test with
/// a private launch directory, test mode, `MUXFINDER_LAUNCH_NO_WAIT=1` and stdin that is not a
/// terminal, so it never starts a login shell, never reads the user's `hosts.json` (each run's
/// host is in a test host list) and never runs real tmux (the host's override is a fake that
/// records its argv). Skipped if the binary is not next to the test bundle.
@Suite("Launch helper binary, profile mode")
struct LaunchHelperProfileBinaryTests {
  /// The helper's environment in test mode, plus `extra`.
  static func environment(
    launchDirectory: URL,
    _ extra: [String: String] = [:]
  ) -> [String: String] {
    LaunchHelperBinaryTests.environment(
      launchDirectory: launchDirectory, [LaunchHelper.testModeVariable: "1"].merging(extra) { $1 })
  }

  /// The login shell the helper would start for this user: argv[0] `-<name>`.
  static var expectedShellArgv0: String? {
    LoginShell.candidates(passwdShell: LoginShell.passwdShell()).first?.argv0
  }

  /// The nesting guard, through either variable: exit 77, one explanation line, the test-mode
  /// line, and a digest of exactly `<helper> profile <host id>` whose child is the login shell,
  /// recorded and never started; nothing else is left in the launch directory.
  @Test(
    .enabled(if: LaunchHelperBinaryTests.helperURL != nil), .timeLimit(.minutes(1)),
    arguments: [
      ("TMUX", "/private/tmp/muxfinder-test-nonexistent/default,1,0"), ("MUXFINDER_LAUNCHED", "1"),
    ])
  func nestingGuard(variable: String, value: String) async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let hostID = UUID()
    let result = try await LaunchHelperBinaryTests.runHelper(
      ["profile", LaunchToken(uuid: hostID).rawValue],
      environment: Self.environment(launchDirectory: store.directory, [variable: value]))
    #expect(result.termination == .exited(LaunchExitStatus.nestedLaunch))
    let text = LaunchHelperBinaryTests.text(result.standardError)
    #expect(text.contains("(\(variable) is set)"))
    #expect(text.contains("muxFinder test mode: the login shell was not started."))
    let digest = try #require(try store.takeArgvDigests().first)
    #expect(digest.helperPID == result.processID)
    #expect(digest.argumentCount == 3)
    #expect(digest.launchID == LaunchToken(uuid: hostID))
    #expect(digest.arguments[1] == LaunchArgvDigest.Argument(bytes: Array("profile".utf8)))
    let shell = try #require(Self.expectedShellArgv0)
    #expect(
      digest.attachChild
        == LaunchArgvDigest.AttachChild(
          executable: shell, arguments: [], detachesOtherClients: false, startsLoginShell: true))
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
  } // End of func nestingGuard(variable:value:)

  /// This Mac from a test host list: the check finds the override, tmux (the fake) gets
  /// `-u -CC new-session -A -s <name>` with `MUXFINDER_LAUNCHED=1` and no `TMUX`, its status
  /// becomes the helper's, and the digest records exactly that child.
  @Test(.enabled(if: LaunchHelperBinaryTests.helperURL != nil), .timeLimit(.minutes(1)))
  func startsTheSessionFromATestHostList() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try ProfileLaunchTests.installFakeTmux(in: root)
    let host = HostConfig(
      displayName: "muxFinder test", mode: .local, tmuxPathOverride: tmux,
      persistentProfileEnabled: true, defaultSessionName: "muxfinder-test-profile #1")
    try store.writeProfileTestHosts(try HostList([host]), forHostID: host.id)
    let result = try await LaunchHelperBinaryTests.runHelper(
      ["profile", LaunchToken(uuid: host.id).rawValue],
      environment: Self.environment(
        launchDirectory: store.directory,
        ["MUXFINDER_FAKE_DIR": root.path(percentEncoded: false), "TMUX": ""]))
    #expect(
      result.termination == .exited(0), "\(LaunchHelperBinaryTests.text(result.standardError))")
    let arguments = ProfileLaunch.tmuxArguments(sessionName: "muxfinder-test-profile #1")
    #expect(try ProfileLaunchTests.recordedArguments(in: root) == arguments)
    #expect(try String(contentsOf: root.appending(path: "launched"), encoding: .utf8) == "1")
    let digest = try #require(try store.takeArgvDigests().first)
    #expect(
      digest.attachChild
        == LaunchArgvDigest.AttachChild(
          executable: tmux, arguments: arguments, detachesOtherClients: false))
    #expect(try store.removeProfileTestHosts(forHostID: host.id))
  } // End of func startsTheSessionFromATestHostList()

  /// A failing tmux (exit 1) and a host the test list does not have each explain, start no
  /// shell (not interactive, test mode) and exit with their status.
  @Test(.enabled(if: LaunchHelperBinaryTests.helperURL != nil), .timeLimit(.minutes(1)))
  func failuresExitWithTheirStatus() async throws {
    let (store, root) = try LaunchTestSupport.makeStore(now: Date())
    defer { try? FileManager.default.removeItem(at: root) }
    let tmux = try ProfileLaunchTests.installFakeTmux(in: root)
    let host = HostConfig(
      displayName: "muxFinder test", mode: .local, tmuxPathOverride: tmux,
      persistentProfileEnabled: true)
    try store.writeProfileTestHosts(try HostList([host]), forHostID: host.id)
    let environment = Self.environment(
      launchDirectory: store.directory,
      ["MUXFINDER_FAKE_DIR": root.path(percentEncoded: false), "MUXFINDER_FAKE_EXIT": "1"])
    let failed = try await LaunchHelperBinaryTests.runHelper(
      ["profile", LaunchToken(uuid: host.id).rawValue], environment: environment)
    #expect(failed.termination == .exited(1))
    #expect(
      LaunchHelperBinaryTests.text(failed.standardError).contains("tmux ended with exit status 1."))

    let other = UUID()
    try store.writeProfileTestHosts(try HostList([host]), forHostID: other)
    let unknown = try await LaunchHelperBinaryTests.runHelper(
      ["profile", LaunchToken(uuid: other).rawValue], environment: environment)
    #expect(unknown.termination == .exited(LaunchExitStatus.profileHostUnavailable))
    #expect(
      LaunchHelperBinaryTests.text(unknown.standardError).contains(
        "no longer in muxFinder's host list"))
    _ = try store.takeArgvDigests()
    try store.removeProfileTestHosts(forHostID: host.id)
    try store.removeProfileTestHosts(forHostID: other)
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
  } // End of func failuresExitWithTheirStatus()
}
