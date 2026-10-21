import Foundation
import Testing

@testable import MuxFinderCore

/// Runs the real static probe script through local shells against a fake `tmux` (see
/// `fakeTmuxScript`), so its control flow, quoting, sanitizing and environment handling are
/// tested without tmux or SSH.
@Suite("Probe script")
struct ProbeScriptTests {
  /// Runs discovery for a local host whose tmux override is `tmuxPath`, with the fake in
  /// `mode`, and returns the result.
  static func discover(
    tmuxPath: String,
    mode: String,
    timeout: Duration = .seconds(10)
  ) async throws -> DiscoveryResult {
    let probe = DiscoveryProbe(
      runner: TestSupport.fastRunner,
      baseEnvironment: [
        "PATH": ProcessEnvironment.systemSearchPath,
        "MUXFINDER_FAKE_MODE": mode,
        "TMUX": "/private/tmp/tmux-501/other,1,0",
        "TMUX_PANE": "%3",
      ],
      timeout: timeout
    )
    let host = HostConfig(displayName: "This Mac", mode: .local, tmuxPathOverride: tmuxPath)
    return try await probe.discover(host)
  } // End of func discover(tmuxPath:mode:timeout:)

  /// Runs `body` with a fresh directory holding the fake tmux, then removes the directory.
  static func withFakeTmux(
    directoryName: String = "bin",
    _ body: (String) async throws -> Void
  ) async throws {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    try await body(try installFakeTmux(in: directory, directoryName: directoryName))
  }

  /// Sessions, a hostile name with a tab, and a control client come through intact; `-u` is
  /// passed; `TMUX` never reaches tmux.
  @Test func reportsSessionsAndClients() async throws {
    try await Self.withFakeTmux { tmux in
      let result = try await Self.discover(tmuxPath: tmux, mode: "sessions")
      let sessions = result.status.sessions
      #expect(result.status.kind == "ok", "\(result.status)")
      #expect(sessions.map(\.key.sessionID.rawValue) == ["$0", "$7"])
      #expect(sessions.map(\.name) == ["plain", #"a;rm -rf ~ $(touch x) "q" 'q'"# + "\tend"])
      #expect(sessions.first?.windowCount == 2)
      #expect(sessions.first?.clients == [ClientSummary(pid: 5151, isControlMode: true)])
      #expect(result.report?.tmuxPath == tmux)
      #expect(result.report?.tmuxVersion == "tmux 9.9-fake")
      #expect(result.report?.nodeName.isEmpty == false)
    }
  } // End of func reportsSessionsAndClients()

  /// An override path with spaces, quotes and `$()` is passed as data.
  @Test func acceptsAnOverridePathWithMetacharacters() async throws {
    try await Self.withFakeTmux(directoryName: #"fake dir 'q' "d" $(touch x) ;"#) { tmux in
      let result = try await Self.discover(tmuxPath: tmux, mode: "sessions")
      #expect(result.status.kind == "ok", "\(result.status)")
      #expect(result.report?.tmuxPath == tmux)
    }
  }

  /// A missing or non-tmux override is "tmux not found", with no fallback to another tmux.
  @Test func reportsTmuxNotFound() async throws {
    let missing = try await Self.discover(tmuxPath: "/nonexistent/muxfinder/tmux", mode: "sessions")
    #expect(missing.status == .tmuxNotFound)
    #expect(missing.report?.tmuxPath == nil)
    try await Self.withFakeTmux { tmux in
      let notTmux = try await Self.discover(tmuxPath: tmux, mode: "not-tmux")
      #expect(notTmux.status == .tmuxNotFound)
    }
    let directory = try await Self.discover(tmuxPath: "/usr/bin", mode: "sessions")
    #expect(directory.status == .tmuxNotFound)
  } // End of func reportsTmuxNotFound()

  /// "no server running" is `noServer`.
  @Test func reportsNoServer() async throws {
    try await Self.withFakeTmux { tmux in
      let result = try await Self.discover(tmuxPath: tmux, mode: "no-server")
      #expect(result.status == .noServer)
      #expect(result.report?.clients == nil)
    }
  }

  /// Only the first stderr line is quoted, reduced to printable ASCII and 200 bytes.
  @Test func sanitizesTmuxErrors() async throws {
    try await Self.withFakeTmux { tmux in
      let noisy = try await Self.discover(tmuxPath: tmux, mode: "noisy")
      #expect(noisy.report?.sessions?.firstErrorLine == "bad ?[31mthing??? here")
      #expect(noisy.status == .probeError("tmux could not list sessions: bad ?[31mthing??? here"))
      let long = try await Self.discover(tmuxPath: tmux, mode: "long-stderr")
      #expect(long.report?.sessions?.firstErrorLine == String(repeating: "x", count: 200))
      #expect(long.status.kind == "probeError")
    }
  }

  /// A tmux that floods stderr (8 MiB on one line) and exits 3 is reported with exit status 3
  /// (it was drained, not killed by SIGPIPE) and a sanitized first line of 200 bytes.
  @Test func boundsAFloodOfTmuxErrors() async throws {
    try await Self.withFakeTmux { tmux in
      let result = try await Self.discover(tmuxPath: tmux, mode: "flood-stderr")
      let listing = try #require(result.report?.sessions, "\(result.status)")
      let expected = "flood ?[1m" + String(repeating: "x", count: 190)
      #expect(listing.exitStatus == 3)
      #expect(listing.firstErrorLine == expected)
      #expect(result.status == .probeError("tmux could not list sessions: \(expected)"))
    }
  }

  /// The probe shell never holds tmux's stderr: with 8 MiB of it, the peak resident size of the
  /// shell and every process it waited for, as `/usr/bin/time -l` reports it, stays below
  /// 8 MiB. Capturing the whole stderr before cutting it peaked above 100 MiB.
  @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: "/usr/bin/time")))
  func neverBuffersTmuxErrorsInTheShell() async throws {
    try await Self.withFakeTmux { tmux in
      let result = try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: "/usr/bin/time"),
          arguments: [
            "-l", DiscoveryProbe.shellURL.path, "-c", ProbeScript.script.source,
            ShellQuoting.scriptName, tmux,
          ],
          environment: [
            "PATH": ProcessEnvironment.systemSearchPath,
            "MUXFINDER_FAKE_MODE": "flood-stderr",
          ],
          timeout: .seconds(20)
        )
      )
      #expect(result.succeeded)
      let report = try ProbeReportParser.parse(result.standardOutput)
      #expect(report.sessions?.exitStatus == 3)
      let peak = try #require(Self.maximumResidentSize(in: result.standardError))
      #expect(peak < 8 << 20, "peak resident size: \(peak) bytes")
    }
  } // End of func neverBuffersTmuxErrorsInTheShell()

  /// A `-V` that prints one endless line is cut to 200 bytes instead of hanging the probe.
  @Test func boundsAnEndlessVersionLine() async throws {
    try await Self.withFakeTmux { tmux in
      let result = try await Self.discover(tmuxPath: tmux, mode: "endless-version")
      #expect(result.status.kind == "ok", "\(result.status)")
      #expect(result.report?.tmuxVersion == "tmux 9.9-" + String(repeating: "x", count: 191))
    }
  }

  /// The "maximum resident set size" in bytes from `/usr/bin/time -l` output, if present.
  static func maximumResidentSize(in standardError: Data) -> Int? {
    let lines = String(decoding: standardError, as: UTF8.self).split(separator: "\n")
    guard let line = lines.first(where: { $0.hasSuffix("maximum resident set size") }) else {
      return nil
    }
    return line.split(separator: " ").first.flatMap { Int($0) }
  }

  /// A failing `list-clients` is a probe error that quotes tmux.
  @Test func reportsClientListingFailures() async throws {
    try await Self.withFakeTmux { tmux in
      let result = try await Self.discover(tmuxPath: tmux, mode: "clients-fail")
      #expect(result.status == .probeError("tmux could not list clients: lost server"))
    }
  }

  /// A hanging tmux is stopped by the timeout and reported as `unreachable(.timeout)`.
  @Test func stopsAHangingProbe() async throws {
    try await Self.withFakeTmux { tmux in
      let clock = ContinuousClock()
      let start = clock.now
      let result = try await Self.discover(tmuxPath: tmux, mode: "hang", timeout: .seconds(1))
      #expect(result.status == .unreachable(.timeout))
      #expect(clock.now - start < .seconds(10))
    }
  }

  /// The D3 command string (what ssh hands the remote login shell) produces the same report
  /// through sh, zsh and bash, with `TMUX` set in the outer shell.
  @Test(arguments: [["/bin/sh"], ["/bin/zsh", "-f"], ["/bin/bash"]])
  func runsThroughTheRemoteCommandString(loginShell: [String]) async throws {
    try await Self.withFakeTmux(directoryName: "it's here") { tmux in
      let command = ShellQuoting.remoteCommand(script: ProbeScript.script, args: [tmux])
      let result = try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: loginShell[0]),
          arguments: Array(loginShell.dropFirst()) + ["-c", command],
          environment: [
            "PATH": ProcessEnvironment.systemSearchPath,
            "MUXFINDER_FAKE_MODE": "sessions",
            "TMUX": "/private/tmp/tmux-501/other,1,0",
            "TMUX_PANE": "%3",
          ],
          timeout: .seconds(10)
        )
      )
      #expect(result.standardError.isEmpty)
      let classification = ErrorClassifier.classify(result, transport: .ssh, hostID: UUID())
      #expect(classification.status.sessions.map(\.key.sessionID.rawValue) == ["$0", "$7"])
    }
  } // End of func runsThroughTheRemoteCommandString(loginShell:)

  /// Two runs use different nonces.
  @Test func usesAFreshNoncePerRun() async throws {
    var nonces = Set<String>()
    for _ in 0..<2 {
      let result = try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: DiscoveryProbe.shellURL,
          arguments: ["-c", ProbeScript.script.source, "muxfinder", "/nonexistent/tmux"],
          environment: TestSupport.environment,
          timeout: .seconds(10)
        )
      )
      let lines = String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
      let nonce = try #require(lines.first { $0.hasPrefix("nonce\t") })
      #expect(nonce.count == "nonce\t".count + 16)
      nonces.insert(String(nonce))
    } // End of loop over runs
    #expect(nonces.count == 2)
  } // End of func usesAFreshNoncePerRun()
}
