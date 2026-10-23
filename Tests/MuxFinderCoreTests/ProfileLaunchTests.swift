import Foundation
import Testing

@testable import MuxFinderCore

/// The pure parts of `muxfinder-launch profile` (PLAN.md D26): the plan from the host list, the
/// nesting variables, tmux's argv with the name escaped, the remote D3 string and the failure
/// mapping. The static scripts run here with `/bin/sh` and a fake tmux that records its argv:
/// no real tmux or ssh, no remote host.
@Suite("Profile launch")
struct ProfileLaunchTests {
  /// A fake `tmux`: `-V` answers like tmux; anything else writes its arguments NUL-separated to
  /// `$MUXFINDER_FAKE_DIR/args` and `MUXFINDER_LAUNCHED` to `…/launched`, then exits with
  /// `MUXFINDER_FAKE_EXIT` (default 0). It exits 98 if `TMUX` or `TMUX_PANE` reached it.
  static let fakeTmuxScript = #"""
    #!/bin/sh
    if [ "$1" = -V ]; then echo "tmux 9.9-fake"; exit 0; fi
    if [ -n "${TMUX-}" ] || [ -n "${TMUX_PANE-}" ]; then echo "TMUX leaked" >&2; exit 98; fi
    printf '%s\0' "$@" > "$MUXFINDER_FAKE_DIR/args"
    printf '%s' "${MUXFINDER_LAUNCHED-unset}" > "$MUXFINDER_FAKE_DIR/launched"
    exit "${MUXFINDER_FAKE_EXIT:-0}"
    """#

  /// Writes the fake tmux as `tmux` in `directory` (0755) and returns its path.
  static func installFakeTmux(in directory: URL) throws -> String {
    let url = directory.appending(path: "tmux")
    try Data(fakeTmuxScript.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: url.path(percentEncoded: false))
    return url.path(percentEncoded: false)
  }

  /// The arguments the fake recorded in `directory`.
  static func recordedArguments(in directory: URL) throws -> [String] {
    let data = try Data(contentsOf: directory.appending(path: "args"))
    return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
      String(decoding: $0, as: UTF8.self)
    }
  }

  /// Session names that need tmux's escapes, quotes and Unicode.
  static let hostileNames = ["main", "work #1", "x;", "a##b;", "it's \"quoted\"", "日本 ü #;"]

  // MARK: - Plan

  /// A host list loaded as `saved`.
  static func saved(_ hosts: [HostConfig]) throws -> HostStoreLoadResult {
    .inMemory(try HostList(hosts))
  }

  /// The plan: This Mac with its override and session name; an SSH host with its destination
  /// and the default `main`; the discovery switch does not matter.
  @Test func plansFromTheHostList() throws {
    let local = HostConfig(
      displayName: "Local", mode: .local, tmuxPathOverride: "/opt/test/bin/tmux",
      persistentProfileEnabled: true, defaultSessionName: "work")
    let remote = HostConfig(
      displayName: "Remote", mode: .ssh, sshDestination: "remote.example.test", isEnabled: false,
      persistentProfileEnabled: true)
    let load = try Self.saved([local, remote])
    #expect(
      try ProfileLaunchPlan.make(hostID: local.id, from: load).get()
        == ProfileLaunchPlan(
          hostID: local.id, host: .local, tmuxPathOverride: "/opt/test/bin/tmux",
          sessionName: "work"))
    #expect(
      try ProfileLaunchPlan.make(hostID: remote.id, from: load).get()
        == ProfileLaunchPlan(
          hostID: remote.id, host: .ssh(destination: "remote.example.test"),
          tmuxPathOverride: nil, sessionName: "main"))
  } // End of func plansFromTheHostList()

  /// Every reason there is no plan, each its own problem.
  @Test func refusesUnusableHosts() throws {
    let off = HostConfig(displayName: "Off", mode: .local)
    let noDestination = HostConfig(
      displayName: "Draft", mode: .ssh, sshDestination: "", isEnabled: false,
      persistentProfileEnabled: true)
    let badOverride = HostConfig(
      displayName: "Override", mode: .ssh, sshDestination: "remote.example.test",
      tmuxPathOverride: "tmux", persistentProfileEnabled: true)
    let load = try Self.saved([off, noDestination, badOverride])
    #expect(
      ProfileLaunchPlan.make(hostID: UUID(), from: load) == .failure(.hostUnknown))
    #expect(ProfileLaunchPlan.make(hostID: off.id, from: load) == .failure(.notOptedIn))
    #expect(
      ProfileLaunchPlan.make(hostID: noDestination.id, from: load)
        == .failure(.invalidDestination(.sshDestinationEmpty)))
    #expect(
      ProfileLaunchPlan.make(hostID: badOverride.id, from: load)
        == .failure(.invalidTmuxPath(.executablePathNotAbsolute)))
    let missing = HostStoreLoadResult(
      hosts: .onboardingDefaults(), state: .notSavedYet,
      revision: HostFileRevision(entry: .missing))
    #expect(ProfileLaunchPlan.make(hostID: off.id, from: missing) == .failure(.hostListMissing))
    var invalid = missing
    invalid.state = .invalid(.notJSON)
    #expect(
      ProfileLaunchPlan.make(hostID: off.id, from: invalid)
        == .failure(.hostListUnusable(.notJSON)))
  } // End of func refusesUnusableHosts()

  /// Problems have distinct kinds and explanations, sentence case, no host data; the nesting
  /// guard exits 77, host problems 76, failed launches their own status.
  @Test func problemsExplainThemselves() {
    let problems: [ProfileLaunchProblem] = [
      .nested(variable: "TMUX"), .hostListMissing, .hostListUnusable(.notJSON),
      .hostListUnreadable(.directoryIsSymbolicLink), .hostUnknown, .notOptedIn,
      .invalidSessionName(.sessionNameEmpty), .invalidDestination(.sshDestinationEmpty),
      .invalidTmuxPath(.executablePathNotAbsolute),
      .launchFailed(.tmuxMissing, host: .local),
      .launchFailed(.sshFailed(.authFailed), host: .ssh(destination: "remote.example.test")),
    ]
    #expect(Set(problems.map(\.kind)).count == problems.count)
    #expect(Set(problems.map(\.explanation)).count == problems.count)
    for problem in problems {
      #expect(
        problem.explanation.first?.isUppercase == true || problem.explanation.hasPrefix("muxFinder")
          || problem.explanation.hasPrefix("ssh"))
      #expect(problem.explanation.hasSuffix("."))
      #expect(!problem.explanation.contains("remote.example.test"))
    }
    #expect(ProfileLaunchProblem.nested(variable: "TMUX").exitStatus == 77)
    #expect(ProfileLaunchProblem.hostUnknown.exitStatus == 76)
    #expect(ProfileLaunchProblem.launchFailed(.childExited(1), host: .local).exitStatus == 1)
    #expect(
      ProfileLaunch.explanation(for: .tmuxMissing, host: .ssh(destination: "x"))
        .contains("on the remote host"))
  } // End of func problemsExplainThemselves()

  // MARK: - Nesting guard

  /// `TMUX` and `MUXFINDER_LAUNCHED` trigger the guard when set and not empty, `TMUX` first.
  @Test func nestingVariables() {
    #expect(ProfileLaunch.nestingVariable(in: [:]) == nil)
    #expect(ProfileLaunch.nestingVariable(in: ["TMUX": ""]) == nil)
    #expect(ProfileLaunch.nestingVariable(in: ["MUXFINDER_LAUNCHED": ""]) == nil)
    #expect(ProfileLaunch.nestingVariable(in: ["TMUX": "/tmp/x,1,0"]) == "TMUX")
    #expect(ProfileLaunch.nestingVariable(in: ["MUXFINDER_LAUNCHED": "1"]) == "MUXFINDER_LAUNCHED")
    #expect(
      ProfileLaunch.nestingVariable(in: ["TMUX": "x", "MUXFINDER_LAUNCHED": "1"]) == "TMUX")
    #expect(ProfileLaunch.nestingVariable(in: ["TMUX_PANE": "%1"]) == nil)
  } // End of func nestingVariables()

  // MARK: - Local and remote commands

  /// Locally tmux gets `-u -CC new-session -A -s <name>`, the name escaped for tmux.
  @Test func localArguments() {
    #expect(
      ProfileLaunch.tmuxArguments(sessionName: "main")
        == ["-u", "-CC", "new-session", "-A", "-s", "main"])
    #expect(ProfileLaunch.tmuxArguments(sessionName: "a#b;").last == #"a##b\;"#)
    #expect(TmuxWord.escaped("#\u{301}") == "##\u{301}")
    #expect(TmuxWord.escaped(#"x\;"#) == #"x\\;"#)
    #expect(TmuxWord.escaped(";") == #"\;"#)
  }

  /// Remotely: D17's ssh options, `--`, the destination and one D3 string whose script is the
  /// static `remoteScript` and whose two arguments are single-quoted; nothing of the name or
  /// override is in the script.
  @Test func remoteArguments() throws {
    let arguments = try #require(
      ProfileLaunch.sshArguments(
        destination: "tester@remote.example.test", override: nil, sessionName: "it's #1;"))
    #expect(
      Array(arguments.prefix(5)) == [
        "-t", "-o", "ConnectTimeout=10", "--", "tester@remote.example.test",
      ])
    #expect(arguments.count == 6)
    #expect(
      arguments[5]
        == ShellQuoting.remoteCommand(
          script: ProfileLaunch.remoteScript, args: ["", "it's #1;"]))
    #expect(arguments[5].hasSuffix(#" muxfinder '' 'it'\''s #1;'"#))
    #expect(!ProfileLaunch.remoteScript.source.contains("it's"))
    #expect(ProfileLaunch.remoteScript.source.contains(#"exec "$t" -u -CC new-session -A -s "$w""#))
    #expect(
      ProfileLaunch.sshArguments(destination: "-oProxyCommand=x", override: nil, sessionName: "m")
        == nil)
    #expect(ProfileLaunch.sshArguments(destination: "", override: nil, sessionName: "m") == nil)
  } // End of func remoteArguments()

  /// The remote D3 string, parsed by a login shell (`/bin/sh` and `/bin/zsh` stand in for the
  /// remote one), runs the static script, which locates the override, escapes the name exactly
  /// as `TmuxWord.escaped` does and `exec`s tmux's control-mode `new-session -A` with `-u`;
  /// `TMUX` never reaches tmux.
  @Test(arguments: hostileNames)
  func remoteScriptRunsTmuxWithTheEscapedName(name: String) async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tmux = try Self.installFakeTmux(in: directory)
    for shell in ["/bin/sh", "/bin/zsh"] where FileManager.default.isExecutableFile(atPath: shell) {
      let result = try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: shell),
          arguments: ["-c", ProfileLaunch.remoteCommand(override: tmux, sessionName: name)],
          environment: [
            "PATH": ProcessEnvironment.systemSearchPath, "TMUX": "/tmp/x,1,0",
            "MUXFINDER_FAKE_DIR": directory.path(percentEncoded: false),
          ],
          timeout: .seconds(10)))
      #expect(
        result.termination == .exited(0), "\(String(decoding: result.standardError, as: UTF8.self))"
      )
      #expect(
        try Self.recordedArguments(in: directory)
          == ["-u", "-CC", "new-session", "-A", "-s", TmuxWord.escaped(name)])
    } // End of loop over the stand-in login shells
  } // End of func remoteScriptRunsTmuxWithTheEscapedName(name:)

  /// The remote script's own refusals: a missing override is 66, a bad argument count or a
  /// name starting with `-` is 68; nothing reaches tmux.
  @Test func remoteScriptRefusals() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tmux = try Self.installFakeTmux(in: directory)
    let cases: [([String], Int32)] = [
      (["/nonexistent/muxfinder-test/tmux", "main"], 66), ([tmux], 68), ([tmux, "-x"], 68),
      ([tmux, ""], 68),
    ]
    for (arguments, status) in cases {
      let result = try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: "/bin/sh"),
          arguments: ["-c", ProfileLaunch.remoteScript.source, "muxfinder"] + arguments,
          environment: [
            "PATH": ProcessEnvironment.systemSearchPath,
            "MUXFINDER_FAKE_DIR": directory.path(percentEncoded: false),
          ], timeout: .seconds(10)))
      #expect(result.termination == .exited(status))
    }
    #expect(!LaunchTestSupport.exists(directory.appending(path: "args")))
  } // End of func remoteScriptRefusals()

  /// The local check prints the override (or nothing usable without tmux) and refuses a wrong
  /// argument count.
  @Test func localCheckLocatesTmux() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tmux = try Self.installFakeTmux(in: directory)
    let environment = ["PATH": ProcessEnvironment.systemSearchPath, "TMUX": "x"]
    let found = try await TestSupport.fastRunner.run(
      ProfileLaunch.locateRequest(override: tmux, environment: environment, timeout: .seconds(10)))
    #expect(found.termination == .exited(0))
    #expect(LaunchGuard.tmuxPath(fromCheckOutput: found.standardOutput, override: tmux) == tmux)
    let missing = try await TestSupport.fastRunner.run(
      ProfileLaunch.locateRequest(
        override: "/nonexistent/muxfinder-test/tmux", environment: environment,
        timeout: .seconds(10)))
    #expect(missing.termination == .exited(66))
    var request = ProfileLaunch.locateRequest(
      override: tmux, environment: environment, timeout: .seconds(10))
    #expect(request.arguments.count == 4)
    #expect(request.timeout == .seconds(10))
    request.arguments.append("extra")
    #expect(try await TestSupport.fastRunner.run(request).termination == .exited(68))
  } // End of func localCheckLocatesTmux()

  // MARK: - Failures

  /// How the child ended: 0 is success; over ssh 66, 68 and 255 are the script's and ssh's;
  /// locally they are tmux's own statuses; a signal is `childSignaled`.
  @Test func mapsChildTerminations() {
    let ssh = LaunchHost.ssh(destination: "remote.example.test")
    let refused = Data("tester@remote.example.test: Permission denied (publickey).\n".utf8)
    #expect(ProfileLaunch.failure(for: .exited(0), host: .local) == nil)
    #expect(ProfileLaunch.failure(for: .exited(0), host: ssh) == nil)
    #expect(ProfileLaunch.failure(for: .exited(1), host: .local) == .childExited(1))
    #expect(ProfileLaunch.failure(for: .exited(66), host: ssh) == .tmuxMissing)
    #expect(ProfileLaunch.failure(for: .exited(66), host: .local) == .childExited(66))
    #expect(ProfileLaunch.failure(for: .exited(68), host: ssh) == .guardUsage)
    #expect(
      ProfileLaunch.failure(for: .exited(255), host: ssh, sshStandardError: refused)
        == .sshFailed(.authFailed))
    #expect(ProfileLaunch.failure(for: .exited(255), host: .local) == .childExited(255))
    #expect(ProfileLaunch.failure(for: .signaled(9), host: ssh) == .childSignaled(9))
  } // End of func mapsChildTerminations()
}
