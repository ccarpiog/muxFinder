import Foundation
import Testing

@testable import MuxFinderCore

/// Runs the real static guard (the check child) through `/bin/sh` against a fake `tmux`
/// (`fakeLaunchTmuxScript`), so every branch of the D4 check is covered without tmux. Real tmux
/// is covered by `LaunchGuardRealTmuxTests`; the attach child by `LaunchHelperBinaryTests`.
@Suite("Launch guard")
struct LaunchGuardTests {
  /// The environment for guard runs: `TMUX`/`TMUX_PANE` set (the guard must drop them) plus
  /// the fake's variables.
  static func environment(_ fake: [String: String], directory: URL) -> [String: String] {
    var environment = [
      "PATH": ProcessEnvironment.systemSearchPath,
      "TMUX": "/private/tmp/muxfinder-test-nonexistent/default,1,0",
      "TMUX_PANE": "%1",
      "MUXFINDER_FAKE_DIR": directory.path(percentEncoded: false),
    ]
    environment.merge(fake) { _, new in new }
    return environment
  } // End of func environment(_:directory:)

  /// Runs the guard for `request`, the way the helper does, and returns the result.
  static func runGuard(
    _ request: LaunchRequest,
    environment: [String: String]
  ) async throws -> ProcessResult {
    try await TestSupport.fastRunner.run(
      LaunchGuard.checkRequest(for: request, environment: environment)
    )
  } // End of func runGuard(_:environment:)

  /// Runs `body` with a fresh directory holding the fake tmux, then removes the directory.
  static func withFakeTmux(_ body: (String, URL) async throws -> Void) async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(try LaunchTestSupport.installFakeTmux(in: directory), directory)
  }

  /// The check's argv and request: the static script, `muxfinder`, then data only; stdin
  /// `/dev/null`, the 10 s default deadline and a small output cap. The attach argv is
  /// separate and needs no shell.
  @Test func buildsArgvFromTheRequest() {
    let request = LaunchTestSupport.request(tmuxPathOverride: "/opt/x/tmux")
    #expect(
      LaunchGuard.arguments(for: request) == [
        "-c", LaunchGuard.script.source, "muxfinder", "/opt/x/tmux", "$3", "4242",
        "1792599999", "1792600001",
      ]
    )
    #expect(LaunchGuard.arguments(for: LaunchTestSupport.request())[3] == "")
    let check = LaunchGuard.checkRequest(for: request, environment: ["PATH": "/usr/bin"])
    #expect(check.executableURL.path(percentEncoded: false) == "/bin/sh")
    #expect(check.arguments == LaunchGuard.arguments(for: request))
    #expect(check.environment == ["PATH": "/usr/bin"])
    #expect(check.standardInput == .nullDevice)
    #expect(check.timeout == .seconds(10) && LaunchGuard.defaultTimeout == .seconds(10))
    #expect(check.outputLimit == LaunchGuard.outputLimit)
    #expect(
      LaunchGuard.attachArguments(for: request) == ["-u", "-CC", "attach-session", "-t", "$3"])
    #expect(LaunchGuard.script.source.hasPrefix(TmuxLocator.script.source))
    #expect(LaunchGuard.body.source.contains("f='\(LaunchGuard.identityFormat)'"))
    #expect(LaunchGuard.body.source.hasSuffix(#"printf '%s\n' "$t""# + "\n"))
    #expect(!LaunchGuard.script.source.contains("exec \"$t\""))
    #expect(!LaunchGuard.script.source.contains("attach-session"))
  } // End of func buildsArgvFromTheRequest()

  /// A matching identity passes: the check exits 0 and prints exactly the tmux path it used,
  /// with nothing on stderr; it never attaches. `TMUX` never reaches tmux.
  @Test func passesAMatchingSession() async throws {
    try await Self.withFakeTmux { tmux, directory in
      let request = LaunchTestSupport.request(tmuxPathOverride: tmux)
      let environment = Self.environment(
        ["MUXFINDER_FAKE_IDENTITY": LaunchTestSupport.identity(of: request)],
        directory: directory
      )
      let check = try await Self.runGuard(request, environment: environment)
      #expect(
        check.termination == .exited(0), "\(String(decoding: check.standardError, as: UTF8.self))")
      #expect(String(decoding: check.standardOutput, as: UTF8.self) == tmux + "\n")
      #expect(check.standardError.isEmpty)
      #expect(LaunchGuard.tmuxPath(fromCheckOutput: check.standardOutput, request: request) == tmux)
      #expect(!TestSupport.fileExists("attach", in: directory))
    }
  } // End of func passesAMatchingSession()

  /// Only one line holding an absolute path to a regular executable file is accepted, and with
  /// an override only the override itself.
  @Test func validatesThePrintedTmuxPath() throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tmux = try LaunchTestSupport.installFakeTmux(in: directory)
    let plain = directory.appending(path: "plain")
    try Data("x".utf8).write(to: plain)
    let link = directory.appending(path: "link")
    try FileManager.default.createSymbolicLink(
      at: link, withDestinationURL: URL(fileURLWithPath: tmux))
    let none = LaunchTestSupport.request()
    /// What `tmuxPath(fromCheckOutput:request:)` makes of `output`.
    func path(_ output: String, _ request: LaunchRequest = none) -> String? {
      LaunchGuard.tmuxPath(fromCheckOutput: Data(output.utf8), request: request)
    }
    #expect(path(tmux + "\n") == tmux)
    #expect(path(link.path(percentEncoded: false) + "\n") == link.path(percentEncoded: false))
    #expect(path(tmux + "\n", LaunchTestSupport.request(tmuxPathOverride: tmux)) == tmux)
    #expect(path("/bin/sh\n", LaunchTestSupport.request(tmuxPathOverride: tmux)) == nil)
    let refused = [
      tmux, tmux + "\n\n", tmux + "\nextra\n", "relative/tmux\n", "\n", "",
      "/nonexistent/muxfinder-test/tmux\n", directory.path(percentEncoded: false) + "\n",
      plain.path(percentEncoded: false) + "\n", "/bin/sh\r\n", "/bin/s\u{0}h\n",
    ]
    for output in refused {
      #expect(path(output) == nil, "\(output.debugDescription)")
    }
    #expect(
      LaunchGuard.tmuxPath(fromCheckOutput: Data([0x2F, 0xFF, 0x0A]), request: none) == nil)
  } // End of func validatesThePrintedTmuxPath()

  /// Same id, other values: changed (65). Empty or other session id: gone (64).
  @Test(arguments: [
    ("$3:4242:1792599999:1792600002", LaunchExitStatus.sessionChanged),
    ("$3:4243:1792599999:1792600001", LaunchExitStatus.sessionChanged),
    ("$3:4242:1792599998:1792600001", LaunchExitStatus.sessionChanged),
    ("$3:4242:1792599999:", LaunchExitStatus.sessionChanged),
    (":4242:1792599999:", LaunchExitStatus.sessionGone),
    (":", LaunchExitStatus.sessionGone),
    ("$7:4242:1792599999:1792600001", LaunchExitStatus.sessionGone),
    ("$33:4242:1792599999:1792600001", LaunchExitStatus.sessionGone),
    ("", LaunchExitStatus.tmuxCheckFailed),
    ("garbage", LaunchExitStatus.tmuxCheckFailed),
  ])
  func classifiesIdentityAnswers(answer: String, expected: Int32) async throws {
    try await Self.withFakeTmux { tmux, directory in
      let request = LaunchTestSupport.request(tmuxPathOverride: tmux)
      let result = try await Self.runGuard(
        request,
        environment: Self.environment(["MUXFINDER_FAKE_IDENTITY": answer], directory: directory)
      )
      #expect(result.termination == .exited(expected))
      #expect(result.standardOutput.isEmpty)
      #expect(!TestSupport.fileExists("attach", in: directory))
    }
  } // End of func classifiesIdentityAnswers(answer:expected:)

  /// tmux failures: no server and no socket are gone (64); anything else is check failed (67)
  /// with tmux's first line, sanitized, on stderr.
  @Test(arguments: [
    ("no server running on /private/tmp/tmux-501/default", LaunchExitStatus.sessionGone),
    (
      "error connecting to /private/tmp/tmux-501/default (No such file or directory)",
      LaunchExitStatus.sessionGone
    ),
    ("can't find session: $3", LaunchExitStatus.sessionGone),
    (
      "error connecting to /private/tmp/tmux-501/default (Permission denied)",
      LaunchExitStatus.tmuxCheckFailed
    ),
    ("protocol version mismatch (client 8, server 7)", LaunchExitStatus.tmuxCheckFailed),
  ])
  func classifiesTmuxErrors(message: String, expected: Int32) async throws {
    try await Self.withFakeTmux { tmux, directory in
      let request = LaunchTestSupport.request(tmuxPathOverride: tmux)
      let result = try await Self.runGuard(
        request,
        environment: Self.environment(
          ["MUXFINDER_FAKE_DISPLAY_FAIL": message],
          directory: directory
        )
      )
      #expect(result.termination == .exited(expected))
      let stderr = String(decoding: result.standardError, as: UTF8.self)
      #expect(stderr == (expected == LaunchExitStatus.tmuxCheckFailed ? "tmux: \(message)\n" : ""))
      #expect(!TestSupport.fileExists("attach", in: directory))
    }
  } // End of func classifiesTmuxErrors(message:expected:)

  /// tmux's error line is reduced to printable ASCII and 200 bytes.
  @Test func sanitizesTmuxErrors() async throws {
    try await Self.withFakeTmux { tmux, directory in
      let message = "bad \u{1B}[31mthing ü " + String(repeating: "x", count: 300)
      let result = try await Self.runGuard(
        LaunchTestSupport.request(tmuxPathOverride: tmux),
        environment: Self.environment(
          ["MUXFINDER_FAKE_DISPLAY_FAIL": message], directory: directory)
      )
      #expect(result.termination == .exited(LaunchExitStatus.tmuxCheckFailed))
      let stderr = String(decoding: result.standardError, as: UTF8.self)
      #expect(stderr.hasPrefix("tmux: bad ?[31mthing ?? xxx"))
      #expect(stderr.utf8.count == "tmux: ".utf8.count + 200 + 1)
    }
  } // End of func sanitizesTmuxErrors()

  /// A missing override, or one that is not tmux, is tmux missing (66), with no fallback.
  @Test func reportsTmuxMissing() async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    for override in ["/nonexistent/muxfinder/tmux", "/bin/echo", "/usr/bin"] {
      let result = try await Self.runGuard(
        LaunchTestSupport.request(tmuxPathOverride: override),
        environment: Self.environment([:], directory: directory)
      )
      #expect(result.termination == .exited(LaunchExitStatus.tmuxMissing), "\(override)")
    }
  } // End of func reportsTmuxMissing()

  /// Wrong argument counts or shapes exit 68 before tmux is looked for.
  @Test(arguments: [
    [] as [String],
    ["", "$3", "1", "2"],
    ["", "$3", "1", "2", "3", "4"],
    ["attach", "", "$3", "1", "2", "3"],
    ["", "3", "1", "2", "3"],
    ["", "$", "1", "2", "3"],
    ["", "$3x", "1", "2", "3"],
    ["", "@3", "1", "2", "3"],
    ["", "$3", "", "2", "3"],
    ["", "$3", "1", "-2", "3"],
    ["", "$3", "1", "2", "3; id"],
  ])
  func refusesBadArguments(arguments: [String]) async throws {
    let result = try await TestSupport.fastRunner.run(
      ProcessRequest(
        executableURL: URL(fileURLWithPath: LaunchGuard.shellPath),
        arguments: ["-c", LaunchGuard.script.source, ShellQuoting.scriptName] + arguments,
        environment: TestSupport.environment,
        timeout: .seconds(10)
      )
    )
    #expect(result.termination == .exited(LaunchExitStatus.guardUsage))
  } // End of func refusesBadArguments(arguments:)
}

/// The guard against a real tmux, kept hermetic like `DiscoveryEndToEndTests`: a private
/// `TMUX_TMPDIR` under `/tmp`, `-f /dev/null`, only `muxfinder-test-*` sessions running
/// `sleep 60`, cleaned up by id; never the user's server, never an attach. Skipped when no
/// tmux is installed.
@Suite("Launch guard (private tmux server)")
struct LaunchGuardRealTmuxTests {
  /// The first installed tmux among the locator's candidates, if any.
  static let tmuxPath = DiscoveryEndToEndTests.tmuxPath

  /// The guard's environment for the private server under `directory`, with a bogus `TMUX`.
  static func environment(_ directory: URL) -> [String: String] {
    var environment = DiscoveryEndToEndTests.tmuxEnvironment(directory)
    environment["TMUX"] = "/private/tmp/muxfinder-test-nonexistent/default,1,0"
    environment["TMUX_PANE"] = "%1"
    return environment
  }

  /// The exit status of the guard for `request`.
  static func check(_ request: LaunchRequest, directory: URL) async throws -> Int32? {
    try await LaunchGuardTests.runGuard(request, environment: environment(directory)).exitCode
  }

  /// The tmux path the guard accepted for `request`, or `nil` if it failed.
  static func acceptedPath(_ request: LaunchRequest, directory: URL) async throws -> String? {
    let result = try await LaunchGuardTests.runGuard(request, environment: environment(directory))
    guard result.termination == .exited(0) else { return nil }
    return LaunchGuard.tmuxPath(fromCheckOutput: result.standardOutput, request: request)
  }

  /// No server (no socket, then a stale socket after the server exits) is gone; a matching
  /// session passes the check and yields the located tmux (or the override); a wrong id is
  /// gone; wrong `session_created`, pid or server start time is changed.
  @Test(.enabled(if: tmuxPath != nil), .timeLimit(.minutes(1)))
  func checksSessionsOnAPrivateServer() async throws {
    let tmux = try #require(Self.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let none = LaunchTestSupport.request(sessionID: "$0")
    #expect(try await Self.check(none, directory: directory) == LaunchExitStatus.sessionGone)

    let tmuxEnvironment = DiscoveryEndToEndTests.tmuxEnvironment(directory)
    let probe = DiscoveryProbe(runner: TestSupport.fastRunner, baseEnvironment: tmuxEnvironment)
    try await DiscoveryEndToEndTests.withTestSessions(
      ["muxfinder-test-guard"],
      tmux: tmux,
      environment: tmuxEnvironment
    ) { created in
      let discovered = try await probe.discover(HostConfig(displayName: "This Mac", mode: .local))
      let session = try #require(discovered.status.sessions.first, "\(discovered.status)")
      #expect(session.key.sessionID.rawValue == created.first?.id)
      let request = LaunchRequest(
        createdAt: Date(),
        host: .local,
        tmuxPathOverride: nil,
        session: session
      )
      #expect(try await Self.acceptedPath(request, directory: directory) == tmux)
      var overridden = request
      overridden.tmuxPathOverride = tmux
      #expect(try await Self.acceptedPath(overridden, directory: directory) == tmux)

      var gone = request
      gone.sessionID = TmuxSessionID("$\(Int(session.key.sessionID.rawValue.dropFirst())! + 50)")!
      var newer = request
      newer.expectedSessionCreated += 1
      var pid = request
      pid.expectedServerPID += 1
      var start = request
      start.expectedServerStartTime -= 1
      #expect(try await Self.check(gone, directory: directory) == LaunchExitStatus.sessionGone)
      for changed in [newer, pid, start] {
        #expect(
          try await Self.check(changed, directory: directory) == LaunchExitStatus.sessionChanged)
      }
    }
    // The server exited with its last session; its socket file stays ("no server running").
    #expect(try await Self.check(none, directory: directory) == LaunchExitStatus.sessionGone)
  } // End of func checksSessionsOnAPrivateServer()
}
