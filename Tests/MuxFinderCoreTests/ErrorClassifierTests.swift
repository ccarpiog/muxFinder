import Foundation
import Testing

@testable import MuxFinderCore

/// One ssh stderr capture and the status it must classify as.
struct SSHStderrCase: Sendable, CustomTestStringConvertible {
  /// Where the text comes from, for the test log.
  let label: String
  /// The stderr text.
  let stderr: String
  /// The expected status.
  let status: HostStatus

  /// The label.
  var testDescription: String { label }
}

/// Tests for `ErrorClassifier`: ssh stderr patterns, run failures and report classification.
@Suite("Error classifier")
struct ErrorClassifierTests {
  /// The host id used for classified sessions.
  static let hostID = UUID(uuidString: "6B0F3C1E-2D4A-4E8B-9C7D-1A2B3C4D5E6F")!

  /// ssh stderr captured on Neptuno on 2026-10-21 with OpenSSH_10.5p1 (`/usr/bin/ssh -o
  /// BatchMode=yes -o ConnectTimeout=5 … -n -T <destination> true`, every run exit 255), plus
  /// the standard OpenSSH wording for cases that could not be produced here (marked
  /// "synthesized"). The changed-key capture has its fingerprint and file path redacted.
  static let sshCases: [SSHStderrCase] = [
    SSHStderrCase(
      label: "something.invalid (captured)",
      stderr:
        "ssh: Could not resolve hostname something.invalid: nodename nor servname provided, or "
        + "not known\n",
      status: .unreachable(.dnsFailure)
    ),
    SSHStderrCase(
      label: "192.0.2.1 after ConnectTimeout=5 (captured)",
      stderr: "ssh: connect to host 192.0.2.1 port 22: Operation timed out\n",
      status: .unreachable(.timeout)
    ),
    SSHStderrCase(
      label: "nonexistent-muxfinder@saturno-m4 (captured)",
      stderr:
        "nonexistent-muxfinder@saturno-m4: Permission denied (publickey,password,"
        + "keyboard-interactive).\n",
      status: .authFailed
    ),
    SSHStderrCase(
      label: "closed local port, ssh://127.0.0.1:1 (captured)",
      stderr: "ssh: connect to host 127.0.0.1 port 1: Connection refused\n",
      status: .unreachable(.refused)
    ),
    SSHStderrCase(
      label: "strict harness, empty known-hosts file (captured)",
      stderr:
        "No ED25519 host key is known for saturno-m4 and you have requested strict checking.\n"
        + "Host key verification failed.\n",
      status: .hostKeyProblem(.unknown)
    ),
    SSHStderrCase(
      label: "strict harness, wrong key in known-hosts file (captured, redacted)",
      stderr: """
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
        @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
        IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
        Someone could be eavesdropping on you right now (man-in-the-middle attack)!
        It is also possible that a host key has just been changed.
        The fingerprint for the ED25519 key sent by the remote host is
        SHA256:<redacted>.
        Please contact your system administrator.
        Add correct host key in /tmp/<redacted>/known_hosts to get rid of this message.
        Offending ED25519 key in /tmp/<redacted>/known_hosts:1
        Host key for saturno-m4 has changed and you have requested strict checking.
        Host key verification failed.

        """,
      status: .hostKeyProblem(.changed)
    ),
    SSHStderrCase(
      label: "BatchMode with an unknown key, default StrictHostKeyChecking (synthesized)",
      stderr: "Host key verification failed.\n",
      status: .hostKeyProblem(.unknown)
    ),
    SSHStderrCase(
      label: "no route (synthesized)",
      stderr: "ssh: connect to host 10.9.9.9 port 22: No route to host\n",
      status: .unreachable(.noRoute)
    ),
    SSHStderrCase(
      label: "network unreachable (synthesized)",
      stderr: "ssh: connect to host 10.9.9.9 port 22: Network is unreachable\n",
      status: .unreachable(.noRoute)
    ),
    SSHStderrCase(
      label: "Linux connect timeout (synthesized)",
      stderr: "ssh: connect to host 10.9.9.9 port 22: Connection timed out\n",
      status: .unreachable(.timeout)
    ),
    SSHStderrCase(
      label: "server alive timeout (synthesized)",
      stderr: "Timeout, server saturno-m4 not responding.\n",
      status: .unreachable(.timeout)
    ),
    SSHStderrCase(
      label: "too many keys offered (synthesized)",
      stderr: "Received disconnect from 10.9.9.9 port 22:2: Too many authentication failures\n",
      status: .authFailed
    ),
    SSHStderrCase(
      label: "unclassified error",
      stderr: "kex_exchange_identification: Connection closed by remote host\nsecond line\n",
      status: .probeError(
        "ssh failed: kex_exchange_identification: Connection closed by remote host")
    ),
    SSHStderrCase(
      label: "empty stderr",
      stderr: "",
      status: .probeError("ssh failed with exit status 255.")
    ),
  ]

  /// Each captured ssh error maps to its status, through the whole `classify` path.
  @Test(arguments: sshCases)
  func classifiesSSHErrors(_ example: SSHStderrCase) {
    let result = ProcessResult(
      processID: 1,
      termination: .exited(255),
      standardError: Data(example.stderr.utf8)
    )
    let classification = ErrorClassifier.classify(result, transport: .ssh, hostID: Self.hostID)
    #expect(classification.status == example.status)
    #expect(classification.report == nil)
  }

  /// The changed-key warning also says "Host key verification failed"; changed wins in either
  /// order.
  @Test func changedHostKeyWinsOverVerificationFailure() {
    let reversed =
      "Host key verification failed.\nWARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!\n"
    #expect(
      ErrorClassifier.sshFailureStatus(stderr: Data(reversed.utf8)) == .hostKeyProblem(.changed))
  }

  /// Quoted stderr is reduced to one line of printable ASCII.
  @Test func sanitizesQuotedStderr() {
    let stderr = Data("\n  ssh: \u{1B}[31mbad\tthing ü\nsecond\n".utf8)
    #expect(
      ErrorClassifier.sshFailureStatus(stderr: stderr)
        == .probeError("ssh failed: ssh: ?[31mbad?thing ?"))
    let long = Data(String(repeating: "x", count: 1000).utf8)
    #expect(ErrorClassifier.firstLine(of: long).count == ErrorClassifier.maximumQuotedLength)
  }

  /// A runner timeout is `unreachable(.timeout)` for any transport and exit status.
  @Test func runnerTimeoutIsUnreachable() {
    for transport in [DiscoveryTransport.local, .ssh] {
      let result = ProcessResult(processID: 1, termination: .signaled(15), timedOut: true)
      let status = ErrorClassifier.classify(result, transport: transport, hostID: Self.hostID)
        .status
      #expect(status == .unreachable(.timeout))
    }
  }

  /// Exit 255 is only an ssh error for SSH runs; other failures are probe errors.
  @Test func classifiesRunFailures() {
    let permissionDenied = Data("Permission denied\n".utf8)
    let local255 = ProcessResult(
      processID: 1, termination: .exited(255), standardError: permissionDenied)
    #expect(
      ErrorClassifier.classify(local255, transport: .local, hostID: Self.hostID).status
        == .probeError("The discovery probe failed with exit status 255: Permission denied")
    )
    let remote127 = ProcessResult(
      processID: 1,
      termination: .exited(127),
      standardError: Data("zsh:1: no such file or directory: /bin/sh\n".utf8)
    )
    #expect(
      ErrorClassifier.classify(remote127, transport: .ssh, hostID: Self.hostID).status
        == .probeError(
          "The discovery probe failed with exit status 127: zsh:1: no such file or directory: /bin/sh"
        )
    )
    let signaled = ProcessResult(processID: 1, termination: .signaled(9))
    #expect(
      ErrorClassifier.classify(signaled, transport: .local, hostID: Self.hostID).status
        == .probeError("The discovery probe was stopped by signal 9.")
    )
    let truncated = ProcessResult(
      processID: 1,
      termination: .exited(0),
      standardOutput: ReportBuilder.report(),
      standardOutputTruncated: true
    )
    #expect(
      ErrorClassifier.classify(truncated, transport: .ssh, hostID: Self.hostID).status
        == .probeError("The discovery report is too large.")
    )
    let garbage = ProcessResult(
      processID: 1, termination: .exited(0), standardOutput: Data("hi\n".utf8))
    #expect(
      ErrorClassifier.classify(garbage, transport: .ssh, hostID: Self.hostID).status
        == .probeError(ProbeReportError.missingHeader.message)
    )
  } // End of func classifiesRunFailures()

  /// The real captures classify as expected.
  @Test func classifiesTheRealCaptures() throws {
    let expectations: [(String, String)] = [
      ("local-no-server", "noServer"),
      ("saturno-no-server", "noServer"),
      ("local-tmux-not-found", "tmuxNotFound"),
      ("local-test-sessions", "ok"),
      ("saturno-test-sessions", "ok"),
      ("local-hostile-names", "ok"),
    ]
    for (name, kind) in expectations {
      let result = ProcessResult(
        processID: 1,
        termination: .exited(0),
        standardOutput: try TestSupport.fixture("discovery/\(name).txt")
      )
      let status = ErrorClassifier.classify(result, transport: .ssh, hostID: Self.hostID).status
      #expect(status.kind == kind, "\(name)")
    }
  } // End of func classifiesTheRealCaptures()

  /// Sessions get keys for the host and their clients; clients of unknown sessions are dropped.
  @Test func buildsSessionsWithKeysAndClients() throws {
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/synthetic-hostile-names.txt")
    )
    let sessions = ErrorClassifier.status(for: report, hostID: Self.hostID).sessions
    #expect(sessions.count == 10)
    let server = ServerIdentity(
      socketPath: "/private/tmp/tmux-501/default",
      pid: 4242,
      startTime: 1_792_599_999
    )
    #expect(
      sessions[0].key == SessionKey(hostID: Self.hostID, server: server, sessionID: sessionID("$0"))
    )
    #expect(
      sessions[0].clients == [
        ClientSummary(pid: 5000, isControlMode: false),
        ClientSummary(pid: 5001, isControlMode: true),
      ]
    )
    #expect(sessions[5].clients == [ClientSummary(pid: 5002, isControlMode: true)])
    #expect(sessions.map(\.clients.count).reduce(0, +) == 3)
    #expect(Set(sessions.map(\.key)).count == 10)
  } // End of func buildsSessionsWithKeysAndClients()

  /// The same session on two hosts gets two different keys.
  @Test func keysDifferPerHost() throws {
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/local-test-sessions.txt"))
    let other = UUID()
    let first = ErrorClassifier.status(for: report, hostID: Self.hostID).sessions
    let second = ErrorClassifier.status(for: report, hostID: other).sessions
    #expect(first.map(\.name) == second.map(\.name))
    #expect(Set(first.map(\.key)).isDisjoint(with: second.map(\.key)))
  }

  /// tmux error lines that mean "no server", and some that do not.
  @Test func recognizesNoServerMessages() {
    #expect(ErrorClassifier.isNoServerMessage("no server running on /private/tmp/tmux-501/default"))
    #expect(
      ErrorClassifier.isNoServerMessage(
        "error connecting to /private/tmp/tmux-501/default (No such file or directory)"
      )
    )
    #expect(
      !ErrorClassifier.isNoServerMessage(
        "error connecting to /private/tmp/tmux-501/default (Permission denied)")
    )
    #expect(!ErrorClassifier.isNoServerMessage("protocol version mismatch (client 8, server 7)"))
    #expect(!ErrorClassifier.isNoServerMessage(""))
  } // End of func recognizesNoServerMessages()

  /// Listing failures become `noServer` or a probe error that quotes tmux.
  @Test func classifiesListingFailures() throws {
    func status(_ data: Data) throws -> HostStatus {
      ErrorClassifier.status(for: try ProbeReportParser.parse(data), hostID: Self.hostID)
    }
    #expect(
      try status(
        ReportBuilder.report(
          sessions: [],
          sessionsExit: "1",
          sessionsStderr: "no server running on /private/tmp/tmux-501/default",
          clients: nil
        )
      ) == .noServer
    )
    #expect(
      try status(
        ReportBuilder.report(
          sessions: [],
          sessionsExit: "1",
          sessionsStderr: "protocol version mismatch (client 8, server 7)",
          clients: nil
        )
      )
        == .probeError(
          "tmux could not list sessions: protocol version mismatch (client 8, server 7)")
    )
    #expect(
      try status(ReportBuilder.report(sessions: [], sessionsExit: "1", clients: nil))
        == .probeError("tmux could not list sessions (exit status 1).")
    )
    var lines = ReportBuilder.lines(clients: [])
    let index = try #require(lines.firstIndex(of: "clients-exit\t0"))
    lines[index] = "clients-exit\t1"
    lines[index + 1] = "clients-stderr\tno server running on /private/tmp/tmux-501/default"
    #expect(try status(ReportBuilder.data(lines)) == .noServer)
    lines[index + 1] = "clients-stderr\tlost server"
    #expect(
      try status(ReportBuilder.data(lines))
        == .probeError("tmux could not list clients: lost server"))
    #expect(try status(ReportBuilder.report(sessions: [], clients: [])) == .ok([]))
  } // End of func classifiesListingFailures()
}
