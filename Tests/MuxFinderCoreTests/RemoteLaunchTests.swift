import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The remote launch (PLAN.md D3, D17): the ssh argv and the D3 command string, built from a
/// request only (hostile values stay data), the remote script run through sh, zsh and bash
/// against the fake tmux (the D4 guard on the remote side), the request's host kind, and the
/// mapping of ssh's exit statuses and standard error to failures.
@Suite("Remote launch")
struct RemoteLaunchTests {
  /// An SSH request for `$3` on the fixture server.
  static func request(
    destination: String = "fixture-remote",
    tmuxPathOverride: String? = nil
  ) -> LaunchRequest {
    LaunchTestSupport.request(
      host: .ssh(destination: destination), tmuxPathOverride: tmuxPathOverride)
  }

  /// The argv: `-t`, the connect timeout, `--`, the destination, then exactly one D3 string:
  /// the static remote script and the guard's five values, each single-quoted. No `BatchMode`,
  /// so a person can authenticate in the tab; nothing weakens host-key checking.
  @Test func buildsTheSSHArgv() throws {
    let request = Self.request(tmuxPathOverride: "/opt/x/tmux")
    let arguments = try #require(RemoteLaunch.sshArguments(for: request))
    #expect(RemoteLaunch.sshPath == "/usr/bin/ssh")
    #expect(
      arguments == [
        "-t", "-o", "ConnectTimeout=10", "--", "fixture-remote", RemoteLaunch.command(for: request),
      ])
    #expect(
      RemoteLaunch.command(for: request)
        == ShellQuoting.remoteCommand(
          script: RemoteLaunch.script,
          args: ["/opt/x/tmux", "$3", "4242", "1792599999", "1792600001"]))
    #expect(
      RemoteLaunch.command(for: Self.request()).hasSuffix(
        " muxfinder '' '$3' "
          + "'4242' '1792599999' '1792600001'"))
    let joined = arguments.joined(separator: " ")
    for weakening in ["BatchMode", "StrictHostKeyChecking", "UserKnownHostsFile", "-T"] {
      #expect(!arguments.dropLast().contains { $0.contains(weakening) }, "\(weakening)")
    }
    #expect(joined.contains("ConnectTimeout=10"))
    // The remote script: locator, the guard's check, then the attach, all static.
    #expect(RemoteLaunch.script.source.hasPrefix(TmuxLocator.script.source))
    #expect(RemoteLaunch.script.source.contains(LaunchGuard.check.source))
    #expect(
      RemoteLaunch.script.source.hasSuffix(#"exec "$t" -u -CC attach-session -t "$id""# + "\n"))
    #expect(!RemoteLaunch.script.source.contains(LaunchGuard.printPath.source))
    // A local request, or a destination that is not valid, gets no ssh argv at all.
    #expect(RemoteLaunch.sshArguments(for: LaunchTestSupport.request()) == nil)
    for destination in ["", "-oProxyCommand=x", "fixture remote", "fixture\nremote", "a\tb"] {
      #expect(RemoteLaunch.sshArguments(for: Self.request(destination: destination)) == nil)
    }
  } // End of func buildsTheSSHArgv()

  /// Hostile values stay data: a destination with shell metacharacters (but no whitespace, so
  /// it is valid) is one argv element after `--`, never part of the command string; an override
  /// path from the adversarial corpus is single-quoted in it; and a session's name, however
  /// hostile, never reaches the command (only its `$N` id does).
  @Test func keepsHostileValuesAsData() throws {
    let hostile = "user@fixture;touch$(echo)`x`'q'"
    let request = Self.request(destination: hostile)
    let arguments = try #require(RemoteLaunch.sshArguments(for: request))
    #expect(arguments[4] == hostile)
    #expect(arguments[3] == "--")
    #expect(!arguments[5].contains(hostile))
    for override in TestSupport.adversarialArguments where override.hasPrefix("/") {
      let command = RemoteLaunch.command(for: Self.request(tmuxPathOverride: override))
      #expect(command.contains(ShellQuoting.posixSingleQuote(override)))
    }
    let name = "a;rm -rf ~ $(touch /tmp/mfx-x) `id` 'q' \"d\" \t-x 🧪"
    var session = AttachTestSupport.session()
    session.name = name
    let fromSession = LaunchRequest(
      createdAt: LaunchTestSupport.requestTime, host: .ssh(destination: "fixture-remote"),
      tmuxPathOverride: nil, session: session)
    let command = RemoteLaunch.command(for: fromSession)
    #expect(!command.contains("rm -rf") && !command.contains("touch") && !command.contains("🧪"))
    #expect(
      command.hasSuffix(" muxfinder '' '$3' '4242' '1792599999' '1792600001'"))
  } // End of func keepsHostileValuesAsData()

  /// The D3 string through each login shell a remote host may have, with `TMUX` set outside
  /// and the fake tmux (in a directory whose name holds quotes, a substitution and spaces) as
  /// the override: a match `exec`s `tmux -u -CC attach-session -t $3` (the fake records it);
  /// a changed session exits 65, a gone one 64, a missing tmux 66 and a tmux error 67 with its
  /// sanitized line, each without attaching. ssh hands these statuses back unchanged.
  @Test(arguments: [["/bin/sh"], ["/bin/zsh", "-f"], ["/bin/bash"]])
  func runsTheGuardOnTheRemoteSide(loginShell: [String]) async throws {
    let root = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appending(path: "it's $(here) \"x\"")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    let tmux = try LaunchTestSupport.installFakeTmux(in: directory)
    let request = Self.request(tmuxPathOverride: tmux)
    /// Runs the request's D3 string through the login shell with the fake's `variables`.
    func run(_ request: LaunchRequest, _ variables: [String: String]) async throws
      -> ProcessResult
    {
      var environment = [
        "PATH": ProcessEnvironment.systemSearchPath, "TMUX": "/private/tmp/tmux-501/other,1,0",
        "TMUX_PANE": "%3", "MUXFINDER_FAKE_DIR": root.path(percentEncoded: false),
      ]
      environment.merge(variables) { _, new in new }
      return try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: loginShell[0]),
          arguments: Array(loginShell.dropFirst()) + ["-c", RemoteLaunch.command(for: request)],
          environment: environment, timeout: .seconds(10)))
    } // End of func run(_:_:)
    let identity = LaunchTestSupport.identity(of: request)
    let changed = try await run(request, ["MUXFINDER_FAKE_IDENTITY": "$3:4242:1792599999:7"])
    #expect(changed.termination == .exited(LaunchExitStatus.sessionChanged))
    let gone = try await run(request, ["MUXFINDER_FAKE_IDENTITY": ":4242:1792599999:"])
    #expect(gone.termination == .exited(LaunchExitStatus.sessionGone))
    let missing = try await run(
      Self.request(tmuxPathOverride: "/nonexistent/muxfinder-test/tmux"),
      ["MUXFINDER_FAKE_IDENTITY": identity])
    #expect(missing.termination == .exited(LaunchExitStatus.tmuxMissing))
    let failing = try await run(request, ["MUXFINDER_FAKE_DISPLAY_FAIL": "permission denied"])
    #expect(failing.termination == .exited(LaunchExitStatus.tmuxCheckFailed))
    #expect(String(decoding: failing.standardError, as: UTF8.self) == "tmux: permission denied\n")
    #expect(!TestSupport.fileExists("attach", in: root))
    let matched = try await run(request, ["MUXFINDER_FAKE_IDENTITY": identity])
    #expect(
      matched.termination == .exited(0),
      "\(String(decoding: matched.standardError, as: UTF8.self))")
    let attached = try String(contentsOf: root.appending(path: "attach"), encoding: .utf8)
    #expect(attached.hasPrefix("$3 "))
  } // End of func runsTheGuardOnTheRemoteSide(loginShell:)

  /// The host kind round-trips as `{"kind":"ssh","destination":…}`; a missing destination or
  /// an unknown kind is refused.
  @Test func encodesTheHostKind() throws {
    let host = LaunchHost.ssh(destination: "user@fixture-remote")
    let data = try LaunchCoding.encoder().encode(host)
    #expect(
      String(decoding: data, as: UTF8.self)
        == #"{"destination":"user@fixture-remote","kind":"ssh"}"#)
    #expect(try LaunchCoding.decoder().decode(LaunchHost.self, from: data) == host)
    #expect(host.isRemote && !LaunchHost.local.isRemote)
    for refused in [#"{"kind":"ssh"}"#, #"{"kind":"mosh","destination":"x"}"#] {
      #expect(throws: (any Error).self) {
        try LaunchCoding.decoder().decode(LaunchHost.self, from: Data(refused.utf8))
      }
    }
  } // End of func encodesTheHostKind()

  /// A request whose destination is not valid is not well formed, so the helper refuses it
  /// when it takes it (`fileMalformed`) and never runs ssh with it.
  @Test func refusesARequestWithAnInvalidDestination() throws {
    #expect(Self.request().isWellFormed)
    #expect(Self.request(destination: "user@fixture;x").isWellFormed)
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    for destination in ["", "-oProxyCommand=x", "fixture remote", "fixture\u{7}"] {
      let request = Self.request(destination: destination)
      #expect(!request.isWellFormed)
      try store.writeRequest(request)
      #expect(throws: LaunchStoreError.fileMalformed) { try store.takeRequest(request.id) }
    }
  } // End of func refusesARequestWithAnInvalidDestination()

  /// ssh's statuses: 255 is ssh's own error, classified from its standard error (as discovery
  /// does); the guard's 64–68 come back from the remote host; tmux's 0 is a success; a local
  /// launch keeps 255 as an ordinary status.
  @Test func mapsSSHExitStatuses() {
    let host = LaunchHost.ssh(destination: "fixture-remote")
    /// The failure for `status` with `standardError`.
    func failure(_ status: Int32, _ standardError: String = "") -> LaunchFailure? {
      LaunchFailure.from(.exited(status), host: host, sshStandardError: Data(standardError.utf8))
    }
    #expect(failure(0) == nil)
    #expect(failure(64) == .sessionGone)
    #expect(failure(65) == .sessionChanged)
    #expect(failure(66) == .tmuxMissing)
    #expect(failure(67) == .tmuxCheckFailed)
    #expect(failure(68) == .guardUsage)
    #expect(failure(1) == .childExited(1))
    #expect(
      failure(255, "fixture@fixture-remote: Permission denied (publickey,password).\r\n")
        == .sshFailed(.authFailed))
    #expect(
      failure(255, "ssh: connect to host fixture-remote port 22: Operation timed out\r\n")
        == .sshFailed(.unreachable))
    #expect(
      failure(255, "ssh: Could not resolve hostname fixture-remote: nodename nor servname\r\n")
        == .sshFailed(.unreachable))
    #expect(
      failure(255, "ssh: connect to host 192.0.2.1 port 22: Connection refused\r\n")
        == .sshFailed(.unreachable))
    #expect(
      failure(
        255,
        "@@@\r\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\r\n"
          + "Host key verification failed.\r\n") == .sshFailed(.hostKeyProblem))
    #expect(failure(255, "Host key verification failed.\r\n") == .sshFailed(.hostKeyProblem))
    #expect(failure(255, "Killed by signal 1.\r\n") == .sshFailed(.other))
    #expect(failure(255) == .sshFailed(.other))
    #expect(
      LaunchFailure.from(.signaled(SIGHUP), host: host, sshStandardError: Data())
        == .childSignaled(SIGHUP))
    #expect(
      LaunchFailure.from(.exited(255), host: .local, sshStandardError: Data("denied".utf8))
        == .childExited(255))
    #expect(LaunchFailure.sshFailed(.authFailed).exitStatus == 255)
  } // End of func mapsSSHExitStatuses()

  /// Every failure has an English explanation for a remote launch; the ssh classes each have
  /// their own, and the ones that name this Mac or tmux alone are reworded.
  @Test func explainsRemoteFailures() {
    let host = LaunchHost.ssh(destination: "fixture-remote")
    let failures: [LaunchFailure] =
      [
        .sessionGone, .sessionChanged, .tmuxMissing, .tmuxCheckFailed, .guardUsage, .usage,
        .requestMissing, .requestExpired, .requestUnreadable, .launchDirectoryUnusable,
        .spawnFailed(errno: ENOENT), .checkTimedOut, .interrupted(SIGHUP),
        .childSignaled(SIGTERM), .childExited(1),
      ] + SSHFailureClass.allCases.map(LaunchFailure.sshFailed)
    for failure in failures {
      let text = failure.explanation(for: host)
      #expect(text.count > 10 && text.hasSuffix("."), "\(failure)")
      #expect(!text.contains("fixture-remote"))
    }
    let classes = Set(SSHFailureClass.allCases.map { LaunchFailure.sshFailed($0).explanation })
    #expect(classes.count == SSHFailureClass.allCases.count)
    #expect(LaunchFailure.tmuxMissing.explanation(for: host).contains("remote host"))
    #expect(LaunchFailure.tmuxMissing.explanation(for: .local).contains("this Mac"))
    #expect(LaunchFailure.spawnFailed(errno: ENOENT).explanation(for: host).contains("ssh"))
  } // End of func explainsRemoteFailures()
}

/// `LaunchHelper` with an SSH request, in this process with the fake child runner and
/// terminal: one ssh child with the D17 argv and a relayed standard error, no local check,
/// and every failure (ssh failing fast on authentication or an unreachable host, a guard
/// refusal on the remote host) ending through the result, the explanation, the wait for
/// Return and the hold until the helper is 10 s old, so the tab never ends inside iTerm2's
/// short-lived-session window.
@Suite("Launch helper (remote)")
struct RemoteLaunchHelperTests {
  /// Shorthand.
  typealias Base = LaunchHelperTests

  /// An SSH request for `$3`.
  static func request(_ destination: String = "fixture-remote") -> LaunchRequest {
    LaunchTestSupport.request(host: .ssh(destination: destination))
  }

  /// ssh attaches and later exits 0 (a detach): no local check ran; the one child is
  /// `/usr/bin/ssh` with the D17 argv, a relayed standard error and the cleaned environment;
  /// the result says success, nothing is printed, and the tab is held for the whole minimum
  /// lifetime (the clock stands still). Diagnostics never name the destination.
  @Test func runsSSHForARemoteRequest() async throws {
    let fixture = try Base.fixture(
      interactive: true,
      environment: [
        "PATH": "/usr/bin:/bin", "TMUX": "/tmp/x,1,0", "TMUX_PANE": "%1", "LANG": "en_US.UTF-8",
        "MUXFINDER_LAUNCH_NO_WAIT": "0",
      ])
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.request()
    let (status, _) = try await Base.attach(fixture, request: request)
    #expect(status == 0)
    #expect(fixture.runner.checks.isEmpty)
    let call = try #require(fixture.runner.calls.first)
    #expect(fixture.runner.calls.count == 1)
    #expect(call.executable == "/usr/bin/ssh")
    #expect(call.arguments == RemoteLaunch.sshArguments(for: request))
    #expect(
      Array(call.arguments.prefix(5)) == ["-t", "-o", "ConnectTimeout=10", "--", "fixture-remote"])
    #expect(call.relaysStandardError)
    #expect(call.environment["TMUX"] == nil && call.environment["TMUX_PANE"] == nil)
    #expect(call.environment["MUXFINDER_LAUNCH_NO_WAIT"] == nil)
    #expect(call.environment["LANG"] == "en_US.UTF-8")
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.succeeded && result.childTermination == .exited(0))
    #expect(fixture.terminal.text.isEmpty)
    #expect(fixture.terminal.pauses == [.hold(.seconds(10))])
    let events = await fixture.log.events()
    #expect(!events.contains { $0.detail.contains("fixture-remote") || $0.detail.contains("$3") })
  } // End of func runsSSHForARemoteRequest()

  /// Every way a remote launch fails fast ends the same way: the result (with the failure
  /// ssh's exit status and standard error give) is written first, the explanation is printed,
  /// the helper waits for Return and then holds until it is 10 s old.
  @Test(arguments: [
    (
      ProcessResult.Termination.exited(255),
      "fixture@fixture-remote: Permission denied (publickey,password,keyboard-interactive).\r\n",
      LaunchFailure.sshFailed(.authFailed)
    ),
    (
      .exited(255), "ssh: connect to host fixture-remote port 22: Operation timed out\r\n",
      .sshFailed(.unreachable)
    ),
    (
      .exited(255), "ssh: Could not resolve hostname fixture-remote: nodename nor servname\r\n",
      .sshFailed(.unreachable)
    ),
    (
      .exited(255),
      "No ED25519 host key is known for fixture-remote.\r\nHost key verification failed.\r\n",
      .sshFailed(.hostKeyProblem)
    ),
    (
      .exited(255), "kex_exchange_identification: Connection closed by remote host\r\n",
      .sshFailed(.other)
    ),
    (.exited(64), "Connection to fixture-remote closed.\r\n", .sessionGone),
    (.exited(65), "", .sessionChanged),
    (.exited(66), "", .tmuxMissing),
    (.exited(67), "", .tmuxCheckFailed),
    (.exited(1), "", .childExited(1)),
    (.signaled(SIGKILL), "", .childSignaled(SIGKILL)),
  ])
  func remoteFailuresEndThroughTheHold(
    termination: ProcessResult.Termination,
    standardError: String,
    expected: LaunchFailure
  ) async throws {
    let fixture = try Base.fixture(
      .termination(termination, forwarded: [], standardError: standardError), interactive: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let request = Self.request()
    let resultPath = fixture.store.directory.appending(path: request.id.rawValue + ".result.json")
      .path(percentEncoded: false)
    let resultWrittenBeforeHold = OSAllocatedUnfairLock(initialState: false)
    fixture.terminal.onHold {
      let exists = FileManager.default.fileExists(atPath: resultPath)
      resultWrittenBeforeHold.withLock { $0 = exists }
    }
    let (status, _) = try await Base.attach(fixture, request: request)
    #expect(status == expected.exitStatus)
    #expect(fixture.runner.checks.isEmpty)
    #expect(fixture.terminal.text.contains("muxFinder: \(expected.explanation(for: request.host))"))
    #expect(fixture.terminal.text.contains("Press Return to close."))
    #expect(fixture.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
    #expect(resultWrittenBeforeHold.withLock { $0 })
    let result = try #require(try fixture.store.takeResult(request.id))
    #expect(result.failure == expected)
    #expect(result.childTermination == termination)
  } // End of func remoteFailuresEndThroughTheHold(termination:standardError:expected:)

  /// Closing the tab while ssh runs (SIGHUP passed on) records the failure but neither waits
  /// nor holds: nobody can see the tab. A terminal that is not interactive never waits either.
  @Test func neverHoldsAClosedOrUnseenTab() async throws {
    let closed = try Base.fixture(
      .termination(.exited(255), forwarded: [SIGHUP], standardError: "Killed by signal 1.\r\n"),
      interactive: true)
    defer { try? FileManager.default.removeItem(at: closed.root) }
    let (status, request) = try await Base.attach(closed, request: Self.request())
    #expect(status == 255)
    #expect(closed.terminal.pauses.isEmpty)
    #expect(try closed.store.takeResult(request.id)?.failure == .sshFailed(.other))

    let unseen = try Base.fixture(
      .termination(.exited(255), forwarded: [], standardError: "Permission denied.\r\n"))
    defer { try? FileManager.default.removeItem(at: unseen.root) }
    let (unseenStatus, _) = try await Base.attach(unseen, request: Self.request())
    #expect(unseenStatus == 255)
    #expect(unseen.terminal.pauses.isEmpty)
  } // End of func neverHoldsAClosedOrUnseenTab()

  /// ssh that cannot be started is `spawnFailed` (74), explained as such, and held; a request
  /// whose destination is not valid is refused when taken (72) and ssh never runs.
  @Test func refusesWhatCannotRun() async throws {
    let unstartable = try Base.fixture(.error(.spawnFailed(errno: ENOENT)), interactive: true)
    defer { try? FileManager.default.removeItem(at: unstartable.root) }
    let (status, request) = try await Base.attach(unstartable, request: Self.request())
    #expect(status == LaunchExitStatus.spawnFailed)
    #expect(unstartable.terminal.text.contains("could not start ssh"))
    #expect(unstartable.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
    #expect(try unstartable.store.takeResult(request.id)?.failure == .spawnFailed(errno: ENOENT))

    let invalid = try Base.fixture(interactive: true)
    defer { try? FileManager.default.removeItem(at: invalid.root) }
    let (invalidStatus, _) = try await Base.attach(
      invalid, request: Self.request("-oProxyCommand=x"))
    #expect(invalidStatus == LaunchExitStatus.requestUnreadable)
    #expect(invalid.runner.calls.isEmpty && invalid.runner.checks.isEmpty)
    #expect(invalid.terminal.pauses == [.waitForReturn, .hold(.seconds(10))])
  } // End of func refusesWhatCannotRun()
}

/// `TerminalChildRunner`'s standard error relay (the ssh child, PLAN.md D17): what the child
/// writes there reaches the destination (the tab) as it comes and its first 16 KiB are
/// captured for classification; without the relay nothing is captured; and a descendant that
/// keeps the pipe open after the child exited delays the result by at most the drain time.
@Suite("Terminal child runner (standard error relay)")
struct StandardErrorRelayTests {
  /// Runs `script` through `/bin/sh` with standard error relayed (or not) into a file, and
  /// returns the outcome with what the file received.
  static func run(
    _ script: String,
    relays: Bool = true
  ) async throws -> (outcome: LaunchChildOutcome, relayed: Data) {
    let directory = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sink = directory.appending(path: "tab")
    let descriptor = open(sink.path(percentEncoded: false), O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    let runner = TerminalChildRunner(standardErrorDestination: descriptor)
    let outcome = try await runner.run(
      executable: "/bin/sh", arguments: ["-c", script, "muxfinder-test"],
      environment: TestSupport.environment, relaysStandardError: relays)
    return (outcome, try Data(contentsOf: sink))
  } // End of func run(_:relays:)

  /// ssh's error lines are relayed and captured, and classify the failure.
  @Test(.timeLimit(.minutes(1)))
  func relaysAndCapturesStandardError() async throws {
    let (outcome, relayed) = try await Self.run(
      #"printf 'first\n' >&2; printf 'Permission denied (publickey).\r\n' >&2; exit 255"#)
    let expected = Data("first\nPermission denied (publickey).\r\n".utf8)
    #expect(outcome.termination == .exited(255))
    #expect(outcome.capturedStandardError == expected)
    #expect(relayed == expected)
    #expect(SSHFailureClass(standardError: outcome.capturedStandardError) == .authFailed)
  }

  /// Only the first 16 KiB are captured; everything is relayed.
  @Test(.timeLimit(.minutes(1)))
  func capsTheCaptureButRelaysEverything() async throws {
    let (outcome, relayed) = try await Self.run(
      #"head -c 20000 /dev/zero | tr '\0' x >&2; exit 0"#)
    #expect(outcome.termination == .exited(0))
    #expect(outcome.capturedStandardError.count == TerminalChildRunner.capturedStandardErrorLimit)
    #expect(TerminalChildRunner.capturedStandardErrorLimit == 16 * 1024)
    #expect(relayed.count == 20000)
  }

  /// Without the relay the child's standard error is the runner's own (inherited), and nothing
  /// is captured.
  @Test(.timeLimit(.minutes(1)))
  func capturesNothingWithoutTheRelay() async throws {
    let (outcome, relayed) = try await Self.run("exit 3", relays: false)
    #expect(outcome.termination == .exited(3))
    #expect(outcome.capturedStandardError.isEmpty)
    #expect(relayed.isEmpty)
  }

  /// A background descendant that inherited the pipe keeps it open after the child exited; the
  /// runner stops relaying after the drain time instead of waiting for it.
  @Test(.timeLimit(.minutes(1)))
  func stopsRelayingSoonAfterTheChildExits() async throws {
    let start = ContinuousClock.now
    let (outcome, relayed) = try await Self.run(#"sleep 3 & printf 'x\n' >&2; exit 0"#)
    #expect(outcome.termination == .exited(0))
    #expect(ContinuousClock.now - start < .milliseconds(2500))
    #expect(outcome.capturedStandardError == Data("x\n".utf8))
    #expect(relayed == Data("x\n".utf8))
  }
}
