import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for how `DiscoveryProbe` builds its process requests and maps runner outcomes. All
/// runs use a fake runner; nothing is spawned.
@Suite("Discovery probe requests")
struct DiscoveryProbeTests {
  /// An environment as a shell inside tmux would have it.
  static let tmuxShellEnvironment = [
    "PATH": "/usr/bin:/bin",
    "HOME": "/Users/test",
    "TMUX": "/private/tmp/tmux-501/other,123,0",
    "TMUX_PANE": "%7",
    "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
  ]

  /// A probe with a fake runner that succeeds with the real local capture.
  static func probe(
    _ runner: FakeProcessRunner,
    policy: DiscoveryProbe.HostKeyPolicy = .userConfiguration
  ) -> DiscoveryProbe {
    DiscoveryProbe(runner: runner, baseEnvironment: tmuxShellEnvironment, hostKeyPolicy: policy)
  }

  /// Local discovery runs `/bin/sh -c <script> muxfinder [override]` without `TMUX` and
  /// `TMUX_PANE`, bounded by the 12 s timeout.
  @Test func buildsTheLocalRequest() throws {
    let probe = Self.probe(FakeProcessRunner(stdout: Data()))
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let request = try probe.request(for: host)
    #expect(request.executableURL.path == "/bin/sh")
    #expect(request.arguments == ["-c", ProbeScript.script.source, "muxfinder"])
    #expect(request.environment["TMUX"] == nil)
    #expect(request.environment["TMUX_PANE"] == nil)
    #expect(request.environment["HOME"] == "/Users/test")
    #expect(request.environment["PATH"]?.hasPrefix("/opt/homebrew/bin:") == true)
    #expect(request.timeout == .seconds(12))
    #expect(request.standardInput == .nullDevice)

    var withOverride = host
    withOverride.tmuxPathOverride = "/Users/test/my tools/tmux"
    let overridden = try probe.request(for: withOverride)
    #expect(overridden.arguments.last == "/Users/test/my tools/tmux")
    #expect(overridden.arguments.count == 4)
  } // End of func buildsTheLocalRequest()

  /// SSH discovery is argv only: the D6 options, `-n -T --`, the destination, and one D3
  /// command string built by `ShellQuoting.remoteCommand`.
  @Test func buildsTheSSHRequest() throws {
    let probe = Self.probe(FakeProcessRunner(stdout: Data()))
    let host = HostConfig(
      displayName: "Saturno",
      mode: .ssh,
      sshDestination: "me@saturno-m4",
      tmuxPathOverride: "/opt/it's/tmux"
    )
    let request = try probe.request(for: host)
    #expect(request.executableURL.path == "/usr/bin/ssh")
    let expectedCommand = ShellQuoting.remoteCommand(
      script: ProbeScript.script,
      args: ["/opt/it's/tmux"]
    )
    #expect(
      request.arguments == [
        "-o", "BatchMode=yes", "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
        "-o", "ServerAliveCountMax=1", "-n", "-T", "--", "me@saturno-m4", expectedCommand,
      ]
    )
    #expect(expectedCommand.hasSuffix(#" muxfinder '/opt/it'\''s/tmux'"#))
    #expect(!request.arguments.contains { $0.contains("StrictHostKeyChecking") })
    #expect(!request.arguments.contains { $0.hasPrefix("Control") })
    #expect(request.environment["SSH_AUTH_SOCK"] == "/private/tmp/agent.sock")
    #expect(request.timeout == .seconds(12))
  } // End of func buildsTheSSHRequest()

  /// The strict test-harness policy only adds stricter options, including no connection
  /// sharing, so a master connection from the user's configuration cannot bypass the check.
  @Test func buildsTheStrictHarnessRequest() throws {
    let probe = Self.probe(
      FakeProcessRunner(stdout: Data()),
      policy: .strict(knownHostsFile: "/tmp/mfx-1/known_hosts")
    )
    let host = HostConfig(displayName: "Saturno", mode: .ssh, sshDestination: "saturno-m4")
    let arguments = try probe.request(for: host).arguments
    #expect(Array(arguments[0..<8]) == DiscoveryProbe.sshOptions)
    #expect(
      Array(arguments[8..<18]) == [
        "-o", "StrictHostKeyChecking=yes", "-o", "UserKnownHostsFile=/tmp/mfx-1/known_hosts",
        "-o", "GlobalKnownHostsFile=/dev/null", "-o", "ControlMaster=no",
        "-o", "ControlPath=none",
      ]
    )
    #expect(Array(arguments[18...].prefix(4)) == ["-n", "-T", "--", "saturno-m4"])
    for file in ["relative/known_hosts", "/tmp/with space", "/tmp/%h", "/tmp/~x"] {
      let bad = Self.probe(FakeProcessRunner(stdout: Data()), policy: .strict(knownHostsFile: file))
      #expect(throws: DiscoveryConfigurationError.invalidKnownHostsFile) {
        try bad.request(for: host)
      }
    }
  } // End of func buildsTheStrictHarnessRequest()

  /// Invalid configuration becomes a probe error before any process runs.
  @Test func rejectsInvalidConfigurationWithoutRunning() async throws {
    let cases: [(HostConfig, String)] = [
      (
        HostConfig(displayName: "x", mode: .ssh, sshDestination: "-oProxyCommand=touch /tmp/x"),
        ValidationError.sshDestinationContainsWhitespace.message
      ),
      (
        HostConfig(displayName: "x", mode: .ssh, sshDestination: "-oProxyCommand=x"),
        ValidationError.sshDestinationStartsWithHyphen.message
      ),
      (
        HostConfig(displayName: "x", mode: .ssh, sshDestination: ""),
        ValidationError.sshDestinationEmpty.message
      ),
      (
        HostConfig(displayName: "x", mode: .local, tmuxPathOverride: "tmux"),
        ValidationError.executablePathNotAbsolute.message
      ),
      (
        HostConfig(displayName: "x", mode: .ssh, sshDestination: "h", tmuxPathOverride: "/a\nb"),
        ValidationError.executablePathContainsControlCharacter.message
      ),
    ]
    for (host, message) in cases {
      let runner = FakeProcessRunner(stdout: Data())
      let result = try await Self.probe(runner).discover(host)
      #expect(result.status == .probeError(message))
      #expect(result.hostID == host.id)
      #expect(runner.requests.isEmpty)
    }
  } // End of func rejectsInvalidConfigurationWithoutRunning()

  /// A successful run is parsed and keyed to the host.
  @Test func discoversThroughTheRunner() async throws {
    let runner = FakeProcessRunner(
      stdout: try TestSupport.fixture("discovery/local-test-sessions.txt"))
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let result = try await Self.probe(runner).discover(host)
    #expect(result.status.kind == "ok")
    #expect(result.status.sessions.count == 2)
    #expect(result.status.sessions.allSatisfy { $0.key.hostID == host.id })
    #expect(result.report?.nodeName == "Neptuno-M4.local")
    #expect(runner.requests.count == 1)
  } // End of func discoversThroughTheRunner()

  /// A spawn failure is a probe error; cancellation propagates.
  @Test func mapsRunnerErrors() async throws {
    let host = HostConfig(displayName: "Saturno", mode: .ssh, sshDestination: "saturno-m4")
    let failing = FakeProcessRunner(.error(ProcessRunnerError.spawnFailed(errno: ENOENT)))
    let result = try await Self.probe(failing).discover(host)
    #expect(result.status.kind == "probeError")
    let cancelled = FakeProcessRunner(.error(CancellationError()))
    await #expect(throws: CancellationError.self) { try await Self.probe(cancelled).discover(host) }
  }

  /// The locator script checks the documented candidates, in order.
  @Test func locatorScriptMatchesTheCandidateList() {
    let loop = "for c in " + TmuxLocator.candidatePaths.joined(separator: " ") + "; do"
    #expect(TmuxLocator.script.source.contains(loop))
    #expect(ProbeScript.script.source.hasPrefix(TmuxLocator.script.source))
    #expect(ProbeScript.script.source.contains("MUXFINDER-PROBE \(ProbeScript.formatVersion)"))
  }

  /// `TmuxSessionID` accepts only `$` plus digits.
  @Test func validatesSessionIDs() {
    #expect(TmuxSessionID("$0")?.rawValue == "$0")
    #expect(TmuxSessionID("$123")?.description == "$123")
    for bad in ["", "$", "0", "$a", "$1 ", " $1", "$-1", "%1", "@1", "$1;x", "=name", "$１"] {
      #expect(TmuxSessionID(bad) == nil, "\(bad)")
    }
  }

  /// Models round-trip through JSON; a bad session id is rejected on decode.
  @Test func modelsRoundTripThroughJSON() throws {
    let host = HostConfig(
      displayName: "Saturno",
      mode: .ssh,
      sshDestination: "saturno-m4",
      tmuxPathOverride: "/opt/homebrew/bin/tmux",
      iTermProfileName: "Work",
      isEnabled: false
    )
    #expect(try JSONDecoder().decode(HostConfig.self, from: JSONEncoder().encode(host)) == host)
    #expect(!host.isThisMac)
    #expect(HostConfig(displayName: "This Mac", mode: .local).isThisMac)
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/local-test-sessions.txt"))
    let sessions = ErrorClassifier.status(for: report, hostID: host.id).sessions
    let decoded = try JSONDecoder().decode(
      [DiscoveredSession].self,
      from: JSONEncoder().encode(sessions)
    )
    #expect(decoded == sessions)
    #expect(throws: DecodingError.self) {
      try JSONDecoder().decode([TmuxSessionID].self, from: Data(#"["$1","x"]"#.utf8))
    }
  } // End of func modelsRoundTripThroughJSON()
}
