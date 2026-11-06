import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// A fake tmux for the plain launch tests: `-V`, the guard's `display-message` (answering
/// `MUXFINDER_FAKE_IDENTITY`), the bound plain attach (`if-shell`) that records its arguments
/// one per line and its parent's argument list (as `ps` shows it) and appends its pid to
/// `attached` once ready, and `list-clients`, which prints the `clients` file. Every file lives
/// in `MUXFINDER_FAKE_DIR`.
let fakePlainTmuxScript = #"""
  #!/bin/sh
  if [ "$1" = -V ]; then echo "tmux 9.9-fake"; exit 0; fi
  if [ "$1" != -u ]; then echo "missing -u" >&2; exit 99; fi
  d=$MUXFINDER_FAKE_DIR
  case "$2" in
    display-message)
      printf '%s\n' "${MUXFINDER_FAKE_IDENTITY-}"
      exit 0 ;;
    if-shell)
      shift 2
      printf '%s\n' "$@" > "$d/args-$$"
      ps -ww -o args= -p "$PPID" > "$d/parent-$$"
      printf '%s\n' "$$" >> "$d/attached"
      if [ "${MUXFINDER_FAKE_ATTACH-}" = wait ]; then
        trap 'exit 43' TERM HUP
        i=0
        while [ $i -lt 600 ]; do sleep 0.05; i=$((i + 1)); done
        exit 45
      fi
      exit "${MUXFINDER_FAKE_EXIT:-0}" ;;
    list-clients)
      cat "$d/clients"
      exit 0 ;;
  esac
  echo "unexpected call" >&2
  exit 97
  """#

/// Plain attaches (PLAN.md D38): the local attach argv, the remote script with its token (run
/// through sh and zsh as the login shell, against a fake tmux: the guard still checks, the
/// shell holding the token stays the client's parent), and the identification of a launch's
/// client, locally by `client_tty` and remotely by the token, with a match, none and two
/// candidates (which confirm nothing).
@Suite("Plain launch")
struct PlainLaunchTests {
  /// The session the tests use.
  static let session = TmuxSessionID("$3")!
  /// The guard's five values for the fake server (the identity `fakeIdentity` matches).
  static let check = ["", "$3", "4242", "1792599999", "1792600001"]
  /// The identity line the fake prints for a matching session.
  static let fakeIdentity = "$3:4242:1792599999:1792600001"

  /// A folder with the fake tmux, and its path.
  struct Fake {
    /// The folder (removed by the caller).
    let folder: URL
    /// The fake tmux.
    let tmux: String

    /// The folder's path.
    var path: String { folder.path(percentEncoded: false) }
  }

  /// Creates a folder holding the fake tmux.
  static func makeFake() throws -> Fake {
    let folder = try TestSupport.makeTemporaryDirectory()
    let tmux = folder.appending(path: "tmux")
    try Data(fakePlainTmuxScript.utf8).write(to: tmux)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: tmux.path(percentEncoded: false))
    return Fake(folder: folder, tmux: tmux.path(percentEncoded: false))
  }

  /// The plain remote command for `token`, its override the fake.
  static func command(
    _ fake: Fake,
    token: LaunchToken,
    detachingOthers: Bool = false
  ) -> String {
    PlainLaunch.remoteCommand(
      checkArguments: [fake.tmux] + check.dropFirst(), token: token,
      detachingOthers: detachingOthers)
  }

  /// `loginShell -c <command>` as OpenSSH runs it, with the fake's environment.
  static func request(
    _ loginShell: [String],
    command: String,
    fake: Fake,
    extra: [String: String] = [:],
    timeout: Duration = .seconds(10)
  ) -> ProcessRequest {
    var environment = TestSupport.environment
    environment["MUXFINDER_FAKE_DIR"] = fake.path
    environment["MUXFINDER_FAKE_IDENTITY"] = fakeIdentity
    environment.merge(extra) { $1 }
    return ProcessRequest(
      executableURL: URL(fileURLWithPath: loginShell[0]),
      arguments: Array(loginShell.dropFirst()) + ["-c", command],
      environment: environment, timeout: timeout)
  } // End of static func request(_:command:fake:extra:timeout:)

  /// The pids the fake's attaches recorded so far.
  static func attachedPIDs(_ fake: Fake) -> [pid_t] {
    TestSupport.processIDs(inFile: "attached", in: fake.folder)
  }

  /// The text of the fake's file `name`, or `nil`.
  static func file(_ name: String, in fake: Fake) -> String? {
    try? String(contentsOf: fake.folder.appending(path: name), encoding: .utf8)
  }

  // MARK: - Shapes

  /// The guard's four values of the fake server as a bound identity.
  static let identity = BoundSessionIdentity(
    sessionID: session, serverPID: 4242, serverStartTime: 1_792_599_999,
    createdAt: 1_792_600_001)

  /// What the fake records for the remote script's bound attach: the arguments after `-u
  /// if-shell`, one per line, which must be the local builder's for the same four values.
  static func boundAttachRecord(detachingOthers: Bool) throws -> String {
    let arguments = try #require(
      PlainLaunch.localAttachArguments(session: identity, detachingOthers: detachingOthers))
    #expect(Array(arguments.prefix(2)) == ["-u", "if-shell"])
    return arguments.dropFirst(2).joined(separator: "\n") + "\n"
  } // End of static func boundAttachRecord(detachingOthers:)

  /// The remote scripts are the locator, the token step, the guard's check and a bound plain
  /// attach that is not `exec`, never a bare `attach-session`; the command carries the five
  /// check values and then the token.
  @Test func buildsTheRemoteScripts() {
    let token = LaunchToken()
    for script in [PlainLaunch.remoteScript, PlainLaunch.remoteMoveHereScript] {
      #expect(script.source.hasPrefix(TmuxLocator.script.source))
      #expect(script.source.contains(PlainLaunch.tokenStep.source))
      #expect(script.source.contains(LaunchGuard.check.source))
      #expect(!script.source.contains("-CC"))
      #expect(!script.source.contains(#"exec "$t""#))
      #expect(!script.source.contains(#""$t" -u attach-session"#))
      #expect(script.source.contains(#""$t" -u if-shell -F -t "$id" "$c" "attach-session "#))
    }
    #expect(PlainLaunch.remoteScript.source.hasSuffix(PlainLaunch.attachTail.source))
    #expect(PlainLaunch.remoteMoveHereScript.source.hasSuffix(PlainLaunch.moveHereTail.source))
    #expect(
      PlainLaunch.remoteCommand(checkArguments: Self.check, token: token, detachingOthers: false)
        == ShellQuoting.remoteCommand(
          script: PlainLaunch.remoteScript, args: Self.check + [token.rawValue]))
    #expect(
      PlainLaunch.remoteCommand(checkArguments: Self.check, token: token, detachingOthers: true)
        .hasSuffix(" muxfinder '' '$3' '4242' '1792599999' '1792600001' '\(token.rawValue)'"))
  } // End of func buildsTheRemoteScripts()

  // MARK: - The remote script against the fake

  /// Through sh and zsh as the login shell: the guard checks, the bound plain attach (exactly
  /// the local builder's arguments for the guard's four values) runs as a child of the shell
  /// whose arguments end with the token, and its status comes back.
  @Test(arguments: [["/bin/sh"], ["/bin/zsh", "-f"]])
  func attachesAsAChildOfTheTokenShell(loginShell: [String]) async throws {
    let fake = try Self.makeFake()
    defer { try? FileManager.default.removeItem(at: fake.folder) }
    let token = LaunchToken()
    let result = try await TestSupport.fastRunner.run(
      Self.request(
        loginShell, command: Self.command(fake, token: token), fake: fake,
        extra: ["MUXFINDER_FAKE_EXIT": "7"]))
    #expect(result.termination == .exited(7))
    let pid = try #require(Self.attachedPIDs(fake).first)
    #expect(
      Self.file("args-\(pid)", in: fake) == (try Self.boundAttachRecord(detachingOthers: false)))
    let parent = try #require(Self.file("parent-\(pid)", in: fake))
    #expect(parent.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix(" " + token.rawValue))
    #expect(parent.contains("muxfinder_locate_tmux"))
  } // End of func attachesAsAChildOfTheTokenShell(loginShell:)

  /// A move here attaches with `-d`, bound the same way; the bound attach's 65 (the session
  /// changed after the guard's check) comes back as the script's status.
  @Test func moveHereDetachesOthers() async throws {
    let fake = try Self.makeFake()
    defer { try? FileManager.default.removeItem(at: fake.folder) }
    let result = try await TestSupport.fastRunner.run(
      Self.request(
        ["/bin/sh"], command: Self.command(fake, token: LaunchToken(), detachingOthers: true),
        fake: fake))
    #expect(result.termination == .exited(0))
    let pid = try #require(Self.attachedPIDs(fake).first)
    #expect(
      Self.file("args-\(pid)", in: fake) == (try Self.boundAttachRecord(detachingOthers: true)))
    let changed = try await TestSupport.fastRunner.run(
      Self.request(
        ["/bin/sh"], command: Self.command(fake, token: LaunchToken()), fake: fake,
        extra: ["MUXFINDER_FAKE_EXIT": "65"]))
    #expect(changed.termination == .exited(65))
  } // End of func moveHereDetachesOthers()

  /// A token that is missing, not canonical or extra exits 68 before tmux is asked anything;
  /// a session that is gone exits 64 from the guard; neither attaches.
  @Test func refusesBadTokensAndKeepsTheGuard() async throws {
    let fake = try Self.makeFake()
    defer { try? FileManager.default.removeItem(at: fake.folder) }
    let checkValues = [fake.tmux] + Self.check.dropFirst()
    let badArguments: [[String]] = [
      checkValues,
      checkValues + ["0F8FAD5B-D9CB-469F-A165-70867728950E"],
      checkValues + ["0f8fad5b-d9cb-469f-a165-70867728950"],
      checkValues + ["0f8fad5b-d9cb-469f-a165-70867728950e0"],
      checkValues + ["0f8fad5b d9cb-469f-a165-70867728950e"],
      checkValues + ["0f8fad5b-d9cb-469f-a165-70867728950e", "extra"],
    ]
    for arguments in badArguments {
      let command = ShellQuoting.remoteCommand(script: PlainLaunch.remoteScript, args: arguments)
      let result = try await TestSupport.fastRunner.run(
        Self.request(["/bin/sh"], command: command, fake: fake))
      #expect(result.termination == .exited(68), "\(arguments.count) arguments")
    }
    let gone = try await TestSupport.fastRunner.run(
      Self.request(
        ["/bin/sh"], command: Self.command(fake, token: LaunchToken()), fake: fake,
        extra: ["MUXFINDER_FAKE_IDENTITY": ":4242:1792599999:"]))
    #expect(gone.termination == .exited(64))
    #expect(Self.attachedPIDs(fake).isEmpty)
  } // End of func refusesBadTokensAndKeepsTheGuard()

  // MARK: - The remote reading against the fake

  /// Runs the remote reading for `token` against the fake.
  static func readRemote(_ fake: Fake, token: LaunchToken) async throws
    -> PlainClientIdentification.Reading?
  {
    let command = ShellQuoting.remoteCommand(
      script: PlainClientIdentification.remoteScript,
      args: PlainClientIdentification.remoteArguments(
        tmuxPathOverride: fake.tmux, sessionID: session, token: token))
    let result = try await TestSupport.fastRunner.run(
      request(["/bin/sh"], command: command, fake: fake))
    #expect(result.termination == .exited(0))
    return PlainClientIdentification.remote(
      output: String(decoding: result.standardOutput, as: UTF8.self))
  } // End of static func readRemote(_:token:)

  /// Starts a plain launch for `token` whose fake attach waits, and returns its task and the
  /// fake attach's pid once it is ready.
  static func startWaitingLaunch(
    _ fake: Fake,
    token: LaunchToken
  ) async throws -> (task: Task<ProcessResult, any Error>, pid: pid_t) {
    let before = Set(attachedPIDs(fake))
    let request = request(
      ["/bin/sh"], command: command(fake, token: token), fake: fake,
      extra: ["MUXFINDER_FAKE_ATTACH": "wait"], timeout: .seconds(60))
    let task = Task { try await TestSupport.fastRunner.run(request) }
    var found: pid_t?
    _ = await TestSupport.eventually(within: .seconds(10)) {
      found = attachedPIDs(fake).first { !before.contains($0) }
      return found != nil
    }
    guard let found else {
      task.cancel()
      throw CancellationError()
    }
    return (task, found)
  } // End of static func startWaitingLaunch(_:token:)

  /// The reading finds the launch's client by the token in its parent's arguments, none for
  /// another token, and two candidates (confirming neither) when a second launch carries the
  /// same token; clients of other sessions are left out.
  @Test func readsTheLaunchClientByItsToken() async throws {
    let fake = try Self.makeFake()
    defer { try? FileManager.default.removeItem(at: fake.folder) }
    let token = LaunchToken()
    let first = try await Self.startWaitingLaunch(fake, token: token)
    defer { first.task.cancel() }
    let clients = [
      "$3 \(first.pid) 1792600100 /dev/ttys901",
      "$3 \(getpid()) 1792600101 /dev/ttys902",
      "$4 \(first.pid) 1792600102 /dev/ttys903",
      "$3 1 1792600103 client-1",
    ]
    try Data((clients.joined(separator: "\n") + "\n").utf8)
      .write(to: fake.folder.appending(path: "clients"))
    let found = try #require(try await Self.readRemote(fake, token: token))
    #expect(found.clients.count == 3)
    let expected = try #require(
      OtherClient(processID: String(first.pid), created: "1792600100", name: "/dev/ttys901"))
    #expect(found.outcome == .confirmed(expected))
    let other = try #require(try await Self.readRemote(fake, token: LaunchToken()))
    #expect(other.outcome == .none)
    #expect(other.clients.count == 3)
    let second = try await Self.startWaitingLaunch(fake, token: token)
    defer { second.task.cancel() }
    try Data(
      ((clients + ["$3 \(second.pid) 1792600104 /dev/ttys904"]).joined(separator: "\n") + "\n")
        .utf8
    ).write(to: fake.folder.appending(path: "clients"))
    let twice = try #require(try await Self.readRemote(fake, token: token))
    guard case .ambiguous(let candidates) = twice.outcome else {
      Issue.record("two launches with one token were not ambiguous: \(twice.outcome)")
      return
    }
    #expect(candidates.map(\.name) == ["/dev/ttys901", "/dev/ttys904"])
  } // End of func readsTheLaunchClientByItsToken()

  /// The reading refuses unusable arguments with 68 and asks tmux nothing.
  @Test func remoteReadingRefusesBadArguments() async throws {
    let fake = try Self.makeFake()
    defer { try? FileManager.default.removeItem(at: fake.folder) }
    let token = LaunchToken().rawValue
    for arguments in [
      [fake.tmux, "$3"], [fake.tmux, "3", token], [fake.tmux, "$3x", token],
      [fake.tmux, "$3", token.uppercased()], [fake.tmux, "$3", token + "0"],
    ] {
      let command = ShellQuoting.remoteCommand(
        script: PlainClientIdentification.remoteScript, args: arguments)
      let result = try await TestSupport.fastRunner.run(
        Self.request(["/bin/sh"], command: command, fake: fake))
      #expect(result.termination == .exited(68), "\(arguments)")
    }
  } // End of func remoteReadingRefusesBadArguments()

  // MARK: - Reading the answers

  /// Locally: the session's clients whose `client_tty` is the terminal; other sessions are
  /// left out; one match confirms, none is none, two are ambiguous.
  @Test func readsTheLocalListing() throws {
    let listing =
      [
        "$3\t101\t1792600100\t/dev/ttys004\t/dev/ttys004",
        "$3\t102\t1792600101\t/dev/ttys006\t/dev/ttys006",
        "$4\t103\t1792600102\t/dev/ttys004\t/dev/ttys004",
        "$3\t104\t1792600103\t\tclient-104",
      ].joined(separator: "\n") + "\n"
    let one = try #require(
      PlainClientIdentification.local(
        listing: listing, sessionID: Self.session, terminal: "/dev/ttys004"))
    #expect(one.clients.map(\.processID) == [101, 102, 104])
    #expect(
      one.outcome
        == .confirmed(OtherClient(processID: "101", created: "1792600100", name: "/dev/ttys004")!))
    let none = try #require(
      PlainClientIdentification.local(
        listing: listing, sessionID: Self.session, terminal: "/dev/ttys009"))
    #expect(none.outcome == .none)
    let shared = listing + "$3\t105\t1792600104\t/dev/ttys004\t/dev/ttys004\n"
    let two = try #require(
      PlainClientIdentification.local(
        listing: shared, sessionID: Self.session, terminal: "/dev/ttys004"))
    guard case .ambiguous(let candidates) = two.outcome else {
      Issue.record("two clients on one terminal were not ambiguous")
      return
    }
    #expect(candidates.map(\.processID) == [101, 105])
    let empty = try #require(
      PlainClientIdentification.local(listing: "", sessionID: Self.session, terminal: "/dev/x"))
    #expect(empty.clients.isEmpty && empty.outcome == .none)
  } // End of func readsTheLocalListing()

  /// Locally, a malformed line, a bad value of the session's client, a carriage return or an
  /// empty terminal makes the listing unreadable; a bad line of another session does too.
  @Test func refusesUnreadableLocalListings() {
    let bad = [
      "$3\t101\t1792600100\t/dev/ttys004",
      "$3\t0\t1792600100\t/dev/ttys004\t/dev/ttys004",
      "$3\t101\t-1\t/dev/ttys004\t/dev/ttys004",
      "$3\t101\t1792600100\t/dev/ttys004\t/dev/tty s004",
      "$3\t101\t1792600100\t/dev/ttys004\t/dev/ttys004\r",
      "$4\t101",
    ]
    for listing in bad {
      #expect(
        PlainClientIdentification.local(
          listing: listing + "\n", sessionID: Self.session, terminal: "/dev/ttys004") == nil,
        "\(listing)")
    }
    #expect(
      PlainClientIdentification.local(
        listing: "", sessionID: Self.session, terminal: "") == nil)
  } // End of func refusesUnreadableLocalListings()

  /// Remotely: `match` and `other` lines and a closing count; one match confirms, none is
  /// none, two are ambiguous.
  @Test func readsTheRemoteAnswer() throws {
    let one = try #require(
      PlainClientIdentification.remote(
        output: "match 101 1792600100 /dev/ttys003\nother 102 1792600101 /dev/ttys006\nend 2\n"))
    #expect(one.clients.count == 2)
    #expect(
      one.outcome
        == .confirmed(OtherClient(processID: "101", created: "1792600100", name: "/dev/ttys003")!))
    let none = try #require(
      PlainClientIdentification.remote(output: "other 102 1792600101 /dev/ttys006\nend 1\n"))
    #expect(none.outcome == .none)
    let empty = try #require(PlainClientIdentification.remote(output: "end 0\n"))
    #expect(empty.clients.isEmpty && empty.outcome == .none)
    let two = try #require(
      PlainClientIdentification.remote(
        output: "match 101 1792600100 /dev/ttys003\nmatch 103 1792600102 /dev/ttys007\nend 2\n"))
    guard case .ambiguous(let candidates) = two.outcome else {
      Issue.record("two matches were not ambiguous")
      return
    }
    #expect(candidates.count == 2)
  } // End of func readsTheRemoteAnswer()

  /// Remotely, a cut-off answer, a wrong count, an unknown marker or a bad value is unreadable.
  @Test(arguments: [
    "", "match 101 1792600100 /dev/ttys003\n", "match 101 1792600100 /dev/ttys003\nend 2\n",
    "end 1\n", "end 01\n", "end\n", "maybe 101 1792600100 /dev/ttys003\nend 1\n",
    "match 101 1792600100\nend 1\n", "match x 1792600100 /dev/ttys003\nend 1\n",
    "match 101 1792600100 /dev/ttys003 extra\nend 1\n", "end 0\nend 0\n", "end 0\r\n",
  ])
  func refusesUnreadableRemoteAnswers(output: String) {
    #expect(PlainClientIdentification.remote(output: output) == nil)
  }
} // End of struct PlainLaunchTests
