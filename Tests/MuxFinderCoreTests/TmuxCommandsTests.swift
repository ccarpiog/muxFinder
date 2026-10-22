import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `TmuxCommands`: the creation request (local argv, the remote D3 string), validation before
/// any process runs, the classification of every outcome, and the static script itself, run by
/// `/bin/sh` against a fake tmux that records its argv (and once against a real tmux on a
/// private server). Nothing touches ssh, iTerm2 or the user's tmux server.
@Suite("tmux commands: new session")
struct TmuxCommandsTests {
  /// A valid local request.
  static let local = NewSessionRequest(
    host: HostConfig(displayName: "This Mac", mode: .local), name: "  muxfinder-test-a  ",
    workingDirectory: "~/dir", command: ["sleep", "60"])

  /// A remote host.
  static let remoteHost = HostConfig(
    displayName: "Remote", mode: .ssh, sshDestination: "saturno-m4",
    tmuxPathOverride: "/opt/homebrew/bin/tmux")

  /// A name with everything a shell or tmux could misread that validation still accepts.
  static let hostileName =
    "muxfinder-test-a;rm -rf ~ $(touch injected) `id` \"dq\" 'sq' #{pid} ##x ü 日本 🧪"
  /// A directory below the home directory with the same kind of characters.
  static let hostileDirectory = "dir 'q' $(touch injected) `id` #{pid} ü 日本"

  // MARK: - Requests

  /// Locally: `/bin/sh -c <script> muxfinder <override> <trimmed name> <directory> <command…>`,
  /// the environment without `TMUX`/`TMUX_PANE`, the 12 s deadline and the output cap.
  @Test func buildsTheLocalArgv() throws {
    let commands = TmuxCommands(
      runner: FakeProcessRunner(stdout: Data()),
      baseEnvironment: ["PATH": "/usr/bin:/bin", "TMUX": "/tmp/x,1,0", "TMUX_PANE": "%1"])
    let request = try commands.processRequest(for: Self.local)
    #expect(request.executableURL.path == "/bin/sh")
    #expect(
      request.arguments == [
        "-c", TmuxCommands.script.source, "muxfinder", "", "muxfinder-test-a", "~/dir", "sleep",
        "60",
      ])
    #expect(request.environment["TMUX"] == nil && request.environment["TMUX_PANE"] == nil)
    #expect(request.environment["PATH"]?.contains("/opt/homebrew/bin") == true)
    #expect(request.timeout == .seconds(12))
    #expect(request.outputLimit == TmuxCommands.outputLimit)
    #expect(request.standardInput == .nullDevice)
  } // End of func buildsTheLocalArgv()

  /// Over SSH: discovery's noninteractive options (BatchMode), `-n -T --`, the destination, and
  /// one D3 string whose every argument is POSIX single-quoted; the script is static.
  @Test func buildsTheRemoteD3String() throws {
    let commands = TmuxCommands(runner: FakeProcessRunner(stdout: Data()), baseEnvironment: [:])
    let request = try commands.processRequest(
      for: NewSessionRequest(
        host: Self.remoteHost, name: Self.hostileName, workingDirectory: "~/it's here"))
    #expect(request.executableURL.path == "/usr/bin/ssh")
    let command = ShellQuoting.remoteCommand(
      script: TmuxCommands.script,
      args: ["/opt/homebrew/bin/tmux", Self.hostileName, "~/it's here"])
    #expect(
      request.arguments == DiscoveryProbe.sshOptions + ["-n", "-T", "--", "saturno-m4", command])
    #expect(request.arguments.contains("BatchMode=yes"))
    #expect(command.hasPrefix("/bin/sh -c '"))
    #expect(
      command.hasSuffix(
        #" muxfinder '/opt/homebrew/bin/tmux' "#
          + ShellQuoting.posixSingleQuote(Self.hostileName) + #" '~/it'\''s here'"#))
    // The script itself holds no runtime data.
    #expect(!TmuxCommands.script.source.contains("muxfinder-test"))
    #expect(!TmuxCommands.script.source.contains("saturno"))
  } // End of func buildsTheRemoteD3String()

  /// The script's `-F` format is `CreatedSession.format`, built with real tabs.
  @Test func scriptFormatMatchesCreatedSession() {
    let source = TmuxCommands.script.source
    let built =
      "#{session_id}$tab#{session_created}$tab#{pid}$tab#{start_time}$tab#{socket_path}"
      + "$tab#{session_name}"
    #expect(
      built.replacingOccurrences(of: "$tab", with: "\t") == CreatedSession.format)
    #expect(
      source.contains(
        ##"f="#{session_id}$tab#{session_created}$tab#{pid}$tab#{start_time}$tab#{socket_path}""##
      ))
    #expect(source.contains(##"f="$f$tab#{session_name}""##))
    #expect(source.contains(#"exec "$t" -u new-session -d -P -F "$f" -s "$n" -c "$c" "$@""#))
    #expect(source.contains(#"muxfinder_tmux_word "=$2""#))
    #expect(source.contains(#""$t" -u has-session -t "$w""#))
    #expect(!source.contains(" -A"))
  } // End of func scriptFormatMatchesCreatedSession()

  // MARK: - Validation before any process

  /// Invalid names, directories, destinations and overrides are refused with zero processes run.
  @Test(arguments: [
    (
      NewSessionRequest(host: HostConfig(displayName: "L", mode: .local), name: "   "),
      SessionCreationError.invalidName(.sessionNameEmpty)
    ),
    (
      NewSessionRequest(host: HostConfig(displayName: "L", mode: .local), name: "a.b"),
      .invalidName(.sessionNameContainsColonOrPeriod)
    ),
    (
      NewSessionRequest(host: HostConfig(displayName: "L", mode: .local), name: "a:b"),
      .invalidName(.sessionNameContainsColonOrPeriod)
    ),
    (
      NewSessionRequest(host: HostConfig(displayName: "L", mode: .local), name: #"a\b"#),
      .invalidName(.sessionNameContainsBackslash)
    ),
    (
      NewSessionRequest(host: HostConfig(displayName: "L", mode: .local), name: "-a"),
      .invalidName(.sessionNameStartsWithHyphen)
    ),
    (
      NewSessionRequest(host: HostConfig(displayName: "L", mode: .local), name: "a\tb"),
      .invalidName(.sessionNameContainsControlCharacter)
    ),
    (
      NewSessionRequest(
        host: HostConfig(displayName: "L", mode: .local), name: String(repeating: "a", count: 101)),
      .invalidName(.sessionNameTooLong(maximumLength: 100))
    ),
    (
      NewSessionRequest(
        host: HostConfig(displayName: "L", mode: .local), name: "ok", workingDirectory: "a\nb"),
      .invalidDirectory(.workingDirectoryContainsLineBreak)
    ),
    (
      NewSessionRequest(
        host: HostConfig(displayName: "R", mode: .ssh, sshDestination: "-oProxyCommand=x"),
        name: "ok"),
      .invalidDestination(.sshDestinationStartsWithHyphen)
    ),
    (
      NewSessionRequest(
        host: HostConfig(displayName: "R", mode: .ssh, sshDestination: ""), name: "ok"),
      .invalidDestination(.sshDestinationEmpty)
    ),
    (
      NewSessionRequest(
        host: HostConfig(displayName: "L", mode: .local, tmuxPathOverride: "tmux"), name: "ok"),
      .invalidTmuxPath(.executablePathNotAbsolute)
    ),
  ])
  func refusesInvalidInputWithoutRunningAnything(
    request: NewSessionRequest,
    expected: SessionCreationError
  ) async {
    let runner = FakeProcessRunner(stdout: Data())
    let commands = TmuxCommands(runner: runner, baseEnvironment: [:])
    await #expect(throws: expected) { try await commands.createSession(request) }
    #expect(runner.requests.isEmpty)
    #expect(!expected.mayHaveCreated)
  } // End of func refusesInvalidInputWithoutRunningAnything(request:expected:)

  // MARK: - Classification

  /// A valid record line, as tmux prints it for the `-F` format.
  static let record =
    "$5\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\tmuxfinder-test-ü #x\n"

  /// A run that exited `status` with the given output.
  static func run(
    _ status: Int32,
    stdout: String = "",
    stderr: String = "",
    truncated: Bool = false
  ) -> ProcessResult {
    ProcessResult(
      processID: 1, termination: .exited(status), standardOutput: Data(stdout.utf8),
      standardError: Data(stderr.utf8), standardOutputTruncated: truncated)
  }

  /// Exit 0 with one record line is the created session, turned into an attach target whose key
  /// and creation time are the record's.
  @Test func parsesTheCreatedSession() throws {
    let created = try TmuxCommands.classify(Self.run(0, stdout: Self.record), transport: .local)
      .get()
    #expect(created.sessionID == TmuxSessionID("$5"))
    #expect(created.createdAt == 1_792_600_001)
    #expect(
      created.server
        == ServerIdentity(
          socketPath: "/private/tmp/tmux-501/default", pid: 4242, startTime: 1_792_599_999))
    #expect(created.name == "muxfinder-test-ü #x")
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let target = created.attachTarget(on: host)
    #expect(
      target.key
        == SessionKey(hostID: host.id, server: created.server, sessionID: created.sessionID))
    #expect(target.session.createdAt == created.createdAt)
    #expect(target.session.attachedClientCount == 0)
  } // End of func parsesTheCreatedSession()

  /// Exit 0 with anything but exactly one valid record line is `unexpectedOutput` (the session
  /// may exist).
  @Test(arguments: [
    "",
    "\n",
    "$5\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\tname",
    "$5\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\tname\n"
      + "$6\t1\t1\t1\t/x\ty\n",
    "5\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\tname\n",
    "$5\t01792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\tname\n",
    "$5\t1792600001\t0\t1792599999\t/private/tmp/tmux-501/default\tname\n",
    "$5\t1792600001\t4242\t1792599999\trelative/socket\tname\n",
    "$5\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\t\n",
    "$5\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\tname\textra\n",
    "$5 1792600001 4242 1792599999 /private/tmp/tmux-501/default name\n",
  ])
  func refusesMalformedOutput(stdout: String) {
    let outcome = TmuxCommands.classify(Self.run(0, stdout: stdout), transport: .local)
    #expect(outcome == .failure(.unexpectedOutput))
    #expect(SessionCreationError.unexpectedOutput.mayHaveCreated)
  }

  /// Output cut by the cap, or not valid UTF-8, is `unexpectedOutput` too.
  @Test func refusesTruncatedOrInvalidOutput() {
    let truncated = Self.run(0, stdout: Self.record, truncated: true)
    #expect(TmuxCommands.classify(truncated, transport: .local) == .failure(.unexpectedOutput))
    var invalid = Self.run(0)
    invalid.standardOutput = Data("$5\t1\t1\t1\t/x\t".utf8) + Data([0xFF, 0x0A])
    #expect(TmuxCommands.classify(invalid, transport: .local) == .failure(.unexpectedOutput))
  }

  /// Every other outcome: the script's codes, tmux's duplicate-session error (a collision) and
  /// other errors, ssh's 255 (classified, remote only), a timeout and a signal.
  @Test func classifiesFailures() {
    let cases: [(ProcessResult, DiscoveryTransport, SessionCreationError)] = [
      (Self.run(80), .local, .sessionExists(.hasSession)),
      (
        Self.run(1, stderr: "duplicate session: muxfinder-test-a\n"), .local,
        .sessionExists(.duplicateSession)
      ),
      (Self.run(1, stderr: "duplicate session: x\n"), .ssh, .sessionExists(.duplicateSession)),
      (
        Self.run(1, stderr: "create window failed: fork failed\nmore\n"), .local,
        .tmuxFailed("create window failed: fork failed")
      ),
      (Self.run(1), .local, .tmuxFailed("")),
      (Self.run(81), .ssh, .directoryMissing),
      (Self.run(66), .ssh, .tmuxMissing),
      (Self.run(68), .local, .scriptFailed(.exited(68))),
      (Self.run(127), .local, .scriptFailed(.exited(127))),
      (Self.run(255, stderr: "x"), .local, .scriptFailed(.exited(255))),
      (
        Self.run(255, stderr: "saturno-m4: Permission denied (publickey,password).\n"), .ssh,
        .sshFailed(.authFailed)
      ),
      (
        Self.run(255, stderr: "Host key verification failed.\n"), .ssh,
        .sshFailed(.hostKeyProblem)
      ),
      (
        Self.run(255, stderr: "ssh: Could not resolve hostname x: nodename\n"), .ssh,
        .sshFailed(.unreachable)
      ),
      (Self.run(255, stderr: "something else\n"), .ssh, .connectionLost),
      (
        ProcessResult(processID: 1, termination: .signaled(9)), .local,
        .scriptFailed(.signaled(9))
      ),
      (ProcessResult(processID: 1, termination: .signaled(15), timedOut: true), .ssh, .timedOut),
    ]
    for (result, transport, expected) in cases {
      #expect(TmuxCommands.classify(result, transport: transport) == .failure(expected))
    } // End of loop over the cases
  } // End of func classifiesFailures()

  /// ssh's standard error for each failure that comes before the remote command can run (the
  /// connection never came up, or the login or host key was refused), with its class: nothing
  /// was created, and the auth and host-key failures say "Set up SSH in iTerm2 first".
  static let beforeRemoteCommand: [(stderr: String, failureClass: SSHFailureClass)] = [
    ("saturno-m4: Permission denied (publickey,password).\r\n", .authFailed),
    (
      "Received disconnect from 100.64.0.2 port 22:2: Too many authentication failures\r\n"
        + "Disconnected from 100.64.0.2 port 22\r\n", .authFailed
    ),
    ("Host key verification failed.\r\n", .hostKeyProblem),
    (
      "@@@@@@@@\r\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\n"
        + "Host key verification failed.\r\n", .hostKeyProblem
    ),
    (
      "ssh: Could not resolve hostname saturno-m4: nodename nor servname provided\r\n",
      .unreachable
    ),
    ("ssh: connect to host saturno-m4 port 22: Connection refused\r\n", .unreachable),
    ("ssh: connect to host saturno-m4 port 22: Operation timed out\r\n", .unreachable),
    ("ssh: connect to host saturno-m4 port 22: Connection timed out\r\n", .unreachable),
    ("ssh: connect to host saturno-m4 port 22: No route to host\r\n", .unreachable),
    ("ssh: connect to host saturno-m4 port 22: Network is unreachable\r\n", .unreachable),
    ("ssh: connect to host saturno-m4 port 22: Host is down\r\n", .unreachable),
  ]

  /// ssh's standard error when the connection was up (or may have been) when ssh failed: the
  /// script may have created the session before the exit status was lost.
  static let afterConnection = [
    "Timeout, server saturno-m4 not responding.\r\n",
    "Read from remote host saturno-m4: Operation timed out\r\n",
    "Read from remote host saturno-m4: No route to host\r\n",
    "Read from remote host saturno-m4: Connection reset by peer\r\n",
    "client_loop: send disconnect: Broken pipe\r\n",
    "client_loop: send disconnect: Network is unreachable\r\n",
    "packet_write_wait: Connection to 100.64.0.2 port 22: Broken pipe\r\n",
    "ssh_dispatch_run_fatal: Connection to 100.64.0.2 port 22: Operation timed out\r\n",
    "Connection to saturno-m4 closed by remote host.\r\n",
    "Killed by signal 1.\r\n",
    "tmux: permission denied\r\nConnection to saturno-m4 closed by remote host.\r\n",
    "kex_exchange_identification: read: Connection reset by peer\r\n",
    "something else\n",
    "",
  ]

  /// Over ssh, exit 255 with a failure before the remote command is `sshFailed` with its
  /// class: nothing was created, no refresh.
  @Test func sshFailureBeforeTheRemoteCommandCreatedNothing() {
    for (stderr, failureClass) in Self.beforeRemoteCommand {
      let outcome = TmuxCommands.classify(Self.run(255, stderr: stderr), transport: .ssh)
      #expect(outcome == .failure(.sshFailed(failureClass)), "\(stderr)")
      #expect(outcome.failure?.mayHaveCreated == false)
      #expect(outcome.failure?.triggersRefresh == false)
    } // End of loop over the failures before the remote command
  } // End of func sshFailureBeforeTheRemoteCommandCreatedNothing()

  /// Over ssh, any other exit 255 (a connection lost after it was up, an unclassified message,
  /// none at all) may have come after the session was created: `mayHaveCreated`,
  /// refresh-triggering, and no message claims nothing was created. A signal, or an exit status
  /// above 128 (a shell's or ssh's report of a child killed by a signal), is the same.
  @Test func connectionLossOrASignalMayHaveCreated() {
    var failures = Self.afterConnection.map { stderr in
      TmuxCommands.classify(Self.run(255, stderr: stderr), transport: .ssh).failure
    }
    failures += [
      TmuxCommands.classify(ProcessResult(processID: 1, termination: .signaled(9)), transport: .ssh)
        .failure,
      TmuxCommands.classify(
        ProcessResult(processID: 1, termination: .signaled(1)), transport: .local
      ).failure,
      TmuxCommands.classify(Self.run(137), transport: .ssh).failure,
      TmuxCommands.classify(Self.run(129), transport: .local).failure,
    ]
    for failure in failures {
      #expect(failure?.mayHaveCreated == true, "\(String(describing: failure))")
      #expect(failure?.triggersRefresh == true)
      #expect(failure?.message.contains("may have been created") == true)
      #expect(failure?.message.lowercased().contains("no session was created") == false)
    } // End of loop over the failures
    for stderr in Self.afterConnection {
      #expect(
        TmuxCommands.classify(Self.run(255, stderr: stderr), transport: .ssh)
          == .failure(.connectionLost), "\(stderr)")
    } // End of loop over the lost connections
    #expect(SessionCreationError.connectionLost.kind == "connectionLost")
    #expect(SessionCreationError.sshFailed(.other).mayHaveCreated)
    // Statuses that come before tmux could create anything stay definite.
    #expect(!SessionCreationError.scriptFailed(.exited(68)).mayHaveCreated)
    #expect(!SessionCreationError.scriptFailed(.exited(127)).mayHaveCreated)
    #expect(!SessionCreationError.scriptFailed(.exited(128)).mayHaveCreated)
  } // End of func connectionLossOrASignalMayHaveCreated()

  /// A remote authentication failure is explained as "set up SSH in iTerm2 first", a host-key
  /// problem too; messages are sentence case and carry no user data.
  @Test func explainsSSHFailures() {
    let auth = SessionCreationError.sshFailed(.authFailed)
    #expect(auth.message.contains("Set up SSH in iTerm2 first"))
    #expect(auth.kind == "sshFailed" && auth.detail == "authFailed")
    #expect(
      SessionCreationError.sshFailed(.hostKeyProblem).message.contains("Set up SSH in iTerm2"))
    #expect(!SessionCreationError.sessionExists(.hasSession).message.contains("muxfinder-test"))
    #expect(SessionCreationError.sessionExists(.duplicateSession).triggersRefresh)
    #expect(SessionCreationError.timedOut.triggersRefresh)
    #expect(SessionCreationError.connectionLost.triggersRefresh)
    #expect(!SessionCreationError.directoryMissing.triggersRefresh)
    #expect(!auth.triggersRefresh)
  } // End of func explainsSSHFailures()

  /// A runner error is `couldNotRun`; a cancelled run is `cancelled` (may have created).
  @Test func reportsRunnerErrorsAndCancellation() async {
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let request = NewSessionRequest(host: host, name: "muxfinder-test-a")
    let failing = TmuxCommands(
      runner: FakeProcessRunner(.error(ProcessRunnerError.spawnFailed(errno: ENOENT))),
      baseEnvironment: [:])
    await #expect(throws: SessionCreationError.couldNotRun(.spawnFailed(errno: ENOENT))) {
      try await failing.createSession(request)
    }
    let cancelled = TmuxCommands(
      runner: FakeProcessRunner(.error(CancellationError())), baseEnvironment: [:])
    await #expect(throws: SessionCreationError.cancelled) {
      try await cancelled.createSession(request)
    }
  } // End of func reportsRunnerErrorsAndCancellation()

  // MARK: - The script, against a fake tmux

  /// A fake `tmux` for the creation script. `-V` answers like tmux; every other call writes
  /// its argv, NUL-separated, to `$MUXFINDER_FAKE_LOG/call-<n>`. `has-session` exits
  /// `$MUXFINDER_FAKE_HAS` (default 1, not found); `new-session` prints a record
  /// (`MUXFINDER_FAKE_NEW` unset), tmux's duplicate-session error (`duplicate`) or another
  /// error (`fail`).
  static let fakeTmux = #"""
    #!/bin/sh
    if [ "$1" = -V ]; then echo "tmux 9.9-fake"; exit 0; fi
    log=$MUXFINDER_FAKE_LOG
    n=$(ls "$log" | wc -l | tr -d ' ')
    printf '%s\0' "$@" > "$log/call-$n"
    case $2 in
      has-session) exit "${MUXFINDER_FAKE_HAS:-1}" ;;
      new-session)
        case ${MUXFINDER_FAKE_NEW-} in
          duplicate) echo "duplicate session: muxfinder-test-x" >&2; exit 1 ;;
          fail) echo "create window failed: fork failed" >&2; exit 1 ;;
          *) printf '$5\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default\tcreated\n' ;;
        esac ;;
      *) exit 97 ;;
    esac
    """#

  /// A private home directory, a fake tmux and a call log for one test.
  struct Sandbox {
    /// The root (removed by `remove()`).
    let root: URL
    /// The home directory the script sees.
    let home: String
    /// The fake tmux.
    let tmux: String
    /// The call log directory.
    let log: String

    /// Creates the sandbox.
    init() throws {
      root = try TestSupport.makeTemporaryDirectory()
      home = root.appending(path: "home").path(percentEncoded: false)
      log = root.appending(path: "log").path(percentEncoded: false)
      try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false)
      try FileManager.default.createDirectory(atPath: log, withIntermediateDirectories: false)
      tmux = root.appending(path: "tmux").path(percentEncoded: false)
      try Data(TmuxCommandsTests.fakeTmux.utf8).write(to: URL(fileURLWithPath: tmux))
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmux)
    } // End of init()

    /// The environment for the script: the home directory, the log and the fake's modes.
    func environment(has: Int32 = 1, new: String? = nil) -> [String: String] {
      var environment = [
        "PATH": ProcessEnvironment.systemSearchPath, "HOME": home, "MUXFINDER_FAKE_LOG": log,
        "MUXFINDER_FAKE_HAS": "\(has)",
      ]
      environment["MUXFINDER_FAKE_NEW"] = new
      return environment
    }

    /// The fake's calls so far, oldest first, each as its argv.
    func calls() throws -> [[String]] {
      let names = try FileManager.default.contentsOfDirectory(atPath: log)
      let ordered = names.sorted { Int($0.dropFirst(5)) ?? 0 < Int($1.dropFirst(5)) ?? 0 }
      return try ordered.map { name in
        let data = try Data(contentsOf: URL(fileURLWithPath: log).appending(path: name))
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map {
          String(decoding: $0, as: UTF8.self)
        }
      }
    } // End of func calls()

    /// Creates `path` (relative to the home directory) with `mkdir`, byte for byte.
    func makeDirectory(_ path: String) throws {
      let full = home + "/" + path
      guard mkdir(full, 0o700) == 0 else { throw POSIXError(.EIO) }
    }

    /// Removes the sandbox.
    func remove() {
      try? FileManager.default.removeItem(at: root)
    }
  } // End of struct Sandbox

  /// A local host whose tmux is the sandbox's fake.
  static func host(_ sandbox: Sandbox) -> HostConfig {
    HostConfig(displayName: "This Mac", mode: .local, tmuxPathOverride: sandbox.tmux)
  }

  /// The created session is the fake's record; the script asked `has-session -t '=<name>'`
  /// first, then `new-session -d -P -F <format> -s <name> -c <directory> <command…>`, with the
  /// hostile name and `~/` directory byte for byte, every `#` doubled, and nothing injected.
  @Test func createsThroughTheScript() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory(Self.hostileDirectory)
    let commands = TmuxCommands(
      runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment())
    let created = try await commands.createSession(
      NewSessionRequest(
        host: Self.host(sandbox), name: Self.hostileName,
        workingDirectory: "~/" + Self.hostileDirectory, command: ["sleep", "60"]))
    #expect(created.sessionID == TmuxSessionID("$5"))
    #expect(created.name == "created")
    let doubled = { (text: String) in text.replacingOccurrences(of: "#", with: "##") }
    let calls = try sandbox.calls()
    #expect(calls.count == 2)
    #expect(calls.first == ["-u", "has-session", "-t", "=" + Self.hostileName])
    #expect(
      calls.last == [
        "-u", "new-session", "-d", "-P", "-F", CreatedSession.format, "-s",
        doubled(Self.hostileName), "-c", doubled(sandbox.home + "/" + Self.hostileDirectory),
        "sleep", "60",
      ])
    let injected = try FileManager.default.contentsOfDirectory(atPath: sandbox.home)
    #expect(injected == [Self.hostileDirectory])
  } // End of func createsThroughTheScript()

  /// The same arguments as the D3 string, parsed by a shell as the remote login shell parses
  /// it, reach the script byte for byte.
  @Test func remoteStringReachesTheScriptExactly() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory(Self.hostileDirectory)
    let request = NewSessionRequest(
      host: Self.host(sandbox), name: Self.hostileName,
      workingDirectory: "~/" + Self.hostileDirectory)
    let command = TmuxCommands.remoteCommand(
      arguments: try TmuxCommands.scriptArguments(for: request))
    let result = try await TestSupport.fastRunner.run(
      ProcessRequest(
        executableURL: TestSupport.shell, arguments: ["-c", command],
        environment: sandbox.environment(), timeout: .seconds(10)))
    #expect(try TmuxCommands.classify(result, transport: .ssh).get().name == "created")
    let calls = try sandbox.calls()
    #expect(calls.first == ["-u", "has-session", "-t", "=" + Self.hostileName])
    #expect(
      calls.last?.suffix(4) == [
        "-s", Self.hostileName.replacingOccurrences(of: "#", with: "##"), "-c",
        (sandbox.home + "/" + Self.hostileDirectory).replacingOccurrences(of: "#", with: "##"),
      ])
    #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.home).count == 1)
  } // End of func remoteStringReachesTheScriptExactly()

  /// Arguments ending in `;` (tmux's command separator, even as a whole argv element) reach
  /// tmux with that `;` written `\;`, which tmux reads back as a literal `;`: the `has-session`
  /// target, the name and the directory (after the `#` doubling, so `#;` is `##\;`) and every
  /// command word; a trailing `\;` becomes `\\;`. The same argv locally (argv) and remotely (the
  /// D3 string, which carries the values unchanged: the host's script escapes them).
  @Test(arguments: [false, true])
  func escapesTrailingSemicolonsForTmux(remote: Bool) async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory("work")
    try sandbox.makeDirectory("work #;")
    try sandbox.makeDirectory(#"w\;"#)
    let requests = [
      NewSessionRequest(
        host: Self.host(sandbox), name: "muxfinder-test-semi #1;", workingDirectory: "~/work #;",
        command: ["sleep", "60", ";", "x;"]),
      NewSessionRequest(host: Self.host(sandbox), name: ";", workingDirectory: #"~/w\;"#),
    ]
    for request in requests {
      let arguments = try TmuxCommands.scriptArguments(for: request)
      #expect(
        Array(arguments.dropFirst()) == [request.name, request.workingDirectory!] + request.command)
      if remote {
        let command = TmuxCommands.remoteCommand(arguments: arguments)
        #expect(command.contains(" " + ShellQuoting.posixSingleQuote(request.name) + " "))
        let result = try await TestSupport.fastRunner.run(
          ProcessRequest(
            executableURL: TestSupport.shell, arguments: ["-c", command],
            environment: sandbox.environment(), timeout: .seconds(10)))
        #expect(try TmuxCommands.classify(result, transport: .ssh).get().name == "created")
      } else {
        let commands = TmuxCommands(
          runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment())
        #expect(try await commands.createSession(request).name == "created")
      }
    } // End of loop over the requests
    let new = ["-u", "new-session", "-d", "-P", "-F", CreatedSession.format]
    #expect(
      try sandbox.calls() == [
        ["-u", "has-session", "-t", #"=muxfinder-test-semi #1\;"#],
        new + [
          "-s", #"muxfinder-test-semi ##1\;"#, "-c", sandbox.home + #"/work ##\;"#, "sleep", "60",
          #"\;"#, #"x\;"#,
        ],
        ["-u", "has-session", "-t", #"=\;"#],
        new + ["-s", #"\;"#, "-c", sandbox.home + #"/w\\;"#],
      ])
    #expect(try FileManager.default.contentsOfDirectory(atPath: sandbox.home).count == 3)
  } // End of func escapesTrailingSemicolonsForTmux(remote:)

  /// `~`, an empty or missing directory and a relative path all resolve from `$HOME` on the
  /// host.
  @Test(arguments: [
    (String?.none, ""), ("", ""), ("~", ""), ("~/sub dir", "/sub dir"), ("sub dir", "/sub dir"),
  ])
  func resolvesTheHomeDirectory(directory: String?, suffix: String) async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    try sandbox.makeDirectory("sub dir")
    let commands = TmuxCommands(
      runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment())
    _ = try await commands.createSession(
      NewSessionRequest(
        host: Self.host(sandbox), name: "muxfinder-test-a", workingDirectory: directory))
    let new = try #require(try sandbox.calls().last)
    #expect(Array(new.suffix(2)) == ["-c", sandbox.home + suffix])
  } // End of func resolvesTheHomeDirectory(directory:suffix:)

  /// A missing directory (a Unicode name, an absolute path, a file) exits 81: no `new-session`.
  @Test(arguments: ["~/missing ünïcödé 日本", "/nonexistent/muxfinder-test ü", "~/file"])
  func refusesAMissingDirectory(directory: String) async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    FileManager.default.createFile(atPath: sandbox.home + "/file", contents: Data())
    let commands = TmuxCommands(
      runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment())
    await #expect(throws: SessionCreationError.directoryMissing) {
      try await commands.createSession(
        NewSessionRequest(
          host: Self.host(sandbox), name: "muxfinder-test-a", workingDirectory: directory))
    }
    #expect(try sandbox.calls().map { $0[1] } == ["has-session"])
  } // End of func refusesAMissingDirectory(directory:)

  /// `has-session` finding the name is a collision before anything is created; tmux's
  /// duplicate-session error from `new-session` is one too; another tmux error is reported.
  @Test func reportsCollisionsAndTmuxErrors() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let request = NewSessionRequest(host: Self.host(sandbox), name: "muxfinder-test-a")
    let exists = TmuxCommands(
      runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment(has: 0))
    await #expect(throws: SessionCreationError.sessionExists(.hasSession)) {
      try await exists.createSession(request)
    }
    #expect(try sandbox.calls().map { $0[1] } == ["has-session"])
    let duplicate = TmuxCommands(
      runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment(new: "duplicate"))
    await #expect(throws: SessionCreationError.sessionExists(.duplicateSession)) {
      try await duplicate.createSession(request)
    }
    let failing = TmuxCommands(
      runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment(new: "fail"))
    await #expect(throws: SessionCreationError.tmuxFailed("create window failed: fork failed")) {
      try await failing.createSession(request)
    }
  } // End of func reportsCollisionsAndTmuxErrors()

  /// An override that is not tmux is `tmuxMissing`, with nothing run through it.
  @Test func reportsAMissingTmux() async throws {
    let sandbox = try Sandbox()
    defer { sandbox.remove() }
    let host = HostConfig(
      displayName: "This Mac", mode: .local,
      tmuxPathOverride: sandbox.root.appending(path: "none").path(percentEncoded: false))
    let commands = TmuxCommands(
      runner: TestSupport.fastRunner, baseEnvironment: sandbox.environment())
    await #expect(throws: SessionCreationError.tmuxMissing) {
      try await commands.createSession(NewSessionRequest(host: host, name: "muxfinder-test-a"))
    }
    #expect(try sandbox.calls().isEmpty)
  } // End of func reportsAMissingTmux()

  // MARK: - The script, against a real tmux on a private server

  /// A wrapper "tmux" that answers `has-session` with "not found" and runs the real tmux
  /// (`$MUXFINDER_REAL_TMUX`) otherwise, so `new-session`'s own duplicate check is exercised.
  static let blindWrapper = #"""
    #!/bin/sh
    if [ "$2" = has-session ]; then exit 1; fi
    exec "$MUXFINDER_REAL_TMUX" "$@"
    """#

  /// With a real tmux on a private server (its own `TMUX_TMPDIR` and home): a name with `#`,
  /// Unicode and spaces is stored exactly, the pane starts in a directory with `#`, spaces and
  /// Unicode reached through `~/`, the same name again is a `has-session` collision (and,
  /// with the check blinded, tmux's duplicate-session error), and a missing directory creates
  /// nothing. Only `muxfinder-test-*` sessions, killed afterwards.
  @Test(.enabled(if: DiscoveryEndToEndTests.tmuxPath != nil), .timeLimit(.minutes(1)))
  func createsOnAPrivateServer() async throws {
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var root = directory.path(percentEncoded: false)
    if root.hasSuffix("/") { root.removeLast() }
    let home = root + "/home"
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false)
    let work = "work #1 {x} ü 日本"
    guard mkdir(home + "/" + work, 0o700) == 0 else { throw POSIXError(.EIO) }
    let wrapper = root + "/blind-tmux"
    try Data(Self.blindWrapper.utf8).write(to: URL(fileURLWithPath: wrapper))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper)
    let environment = [
      "PATH": ProcessEnvironment.systemSearchPath, "HOME": home, "TMUX_TMPDIR": root,
      "MUXFINDER_REAL_TMUX": tmux,
    ]
    let commands = TmuxCommands(runner: TestSupport.fastRunner, baseEnvironment: environment)
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let name = "muxfinder-test-#{pid} ##x ü 日本"
    let request = NewSessionRequest(
      host: host, name: name, workingDirectory: "~/" + work, command: ["sleep", "60"])
    do {
      let created = try await commands.createSession(request)
      #expect(created.name == name)
      #expect(created.server.socketPath.hasPrefix("/private" + root))
      let path = try await DiscoveryEndToEndTests.runTmux(
        tmux,
        ["-u", "display-message", "-p", "-t", created.sessionID.rawValue, "#{pane_current_path}"],
        environment: environment)
      #expect(path == "/private" + home + "/" + work + "\n")
      await #expect(throws: SessionCreationError.sessionExists(.hasSession)) {
        try await commands.createSession(request)
      }
      var blind = request
      blind.host.tmuxPathOverride = wrapper
      await #expect(throws: SessionCreationError.sessionExists(.duplicateSession)) {
        try await commands.createSession(blind)
      }
      var missing = request
      missing.name = "muxfinder-test-missing"
      missing.workingDirectory = "~/missing ünïcödé"
      await #expect(throws: SessionCreationError.directoryMissing) {
        try await commands.createSession(missing)
      }
      let listed = try await DiscoveryEndToEndTests.runTmux(
        tmux, ["list-sessions", "-F", "#{session_id}"], environment: environment)
      #expect(listed == created.sessionID.rawValue + "\n")
    } catch {
      await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: environment)
      throw error
    }
    await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: environment)
  } // End of func createsOnAPrivateServer()

  /// With a real tmux on a private server: a name and a directory ending in `;` are kept
  /// literally (the pane starts in `~/work;`, not in its sibling `~/work`), `has-session` looks
  /// for the exact name (a session named without the `;` is neither a collision nor touched),
  /// the same name again is a `has-session` collision, and no extra tmux command runs (the
  /// server holds the two sessions, one pane each, and nothing else). Only `muxfinder-test-*`
  /// sessions, killed afterwards.
  @Test(.enabled(if: DiscoveryEndToEndTests.tmuxPath != nil), .timeLimit(.minutes(1)))
  func keepsTrailingSemicolonsOnAPrivateServer() async throws {
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var root = directory.path(percentEncoded: false)
    if root.hasSuffix("/") { root.removeLast() }
    let home = root + "/home"
    try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: false)
    for folder in ["work", "work;"] where mkdir(home + "/" + folder, 0o700) != 0 {
      throw POSIXError(.EIO)
    }
    let environment = [
      "PATH": ProcessEnvironment.systemSearchPath, "HOME": home, "TMUX_TMPDIR": root,
    ]
    let commands = TmuxCommands(runner: TestSupport.fastRunner, baseEnvironment: environment)
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let request = NewSessionRequest(
      host: host, name: "muxfinder-test-semi;", workingDirectory: "~/work;",
      command: ["sleep", "60"])
    do {
      let plain = try await commands.createSession(
        NewSessionRequest(
          host: host, name: "muxfinder-test-semi", workingDirectory: "~/work",
          command: ["sleep", "60"]))
      let created = try await commands.createSession(request)
      #expect(created.name == "muxfinder-test-semi;")
      let format = "#{session_id}\t#{session_name}\t#{session_windows}\t#{pane_current_path}"
      let expected: Set = [
        "\(plain.sessionID)\tmuxfinder-test-semi\t1\t/private\(home)/work",
        "\(created.sessionID)\tmuxfinder-test-semi;\t1\t/private\(home)/work;",
      ]
      let panes = try await DiscoveryEndToEndTests.runTmux(
        tmux, ["-u", "list-panes", "-a", "-F", format], environment: environment)
      #expect(panes.split(separator: "\n").count == 2)
      #expect(Set(panes.split(separator: "\n").map(String.init)) == expected)
      await #expect(throws: SessionCreationError.sessionExists(.hasSession)) {
        try await commands.createSession(request)
      }
      let after = try await DiscoveryEndToEndTests.runTmux(
        tmux, ["-u", "list-panes", "-a", "-F", format], environment: environment)
      #expect(after == panes)
    } catch {
      await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: environment)
      throw error
    }
    await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: environment)
  } // End of func keepsTrailingSemicolonsOnAPrivateServer()
}

extension Result where Success == CreatedSession, Failure == SessionCreationError {
  /// The creation failure, or `nil` for a created session.
  fileprivate var failure: SessionCreationError? {
    if case .failure(let error) = self { return error }
    return nil
  }
}
