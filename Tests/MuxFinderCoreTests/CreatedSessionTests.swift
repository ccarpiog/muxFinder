import Foundation
import Testing

@testable import MuxFinderCore

/// `CreatedSession`: the record the e2e harness keeps of its own session, so a later step never
/// takes a session that reused the id (a restarted server) or the name for it.
@Suite("Created session")
struct CreatedSessionTests {
  /// Shorthand for the attribute arguments.
  typealias Fixture = CreatedSessionTests

  /// The server of the fixtures.
  static let server = ServerIdentity(
    socketPath: "/private/tmp/tmux-501/default", pid: 4242, startTime: 1_792_599_999)
  /// The record of the fixtures.
  static let record = CreatedSession(
    server: server, sessionID: TmuxSessionID("$3")!, createdAt: 1_792_600_001,
    name: "muxfinder-test-0a1b2c3d")

  /// One line of `CreatedSession.format` output.
  static func line(
    id: String = "$3",
    created: String = "1792600001",
    pid: String = "4242",
    start: String = "1792599999",
    socket: String = "/private/tmp/tmux-501/default",
    name: String = "muxfinder-test-0a1b2c3d"
  ) -> String {
    [id, created, pid, start, socket, name].joined(separator: "\t")
  } // End of func line(id:created:pid:start:socket:name:)

  /// The format is the static string the harness passes to tmux.
  @Test func format() {
    #expect(
      CreatedSession.format
        == "#{session_id}\t#{session_created}\t#{pid}\t#{start_time}\t#{socket_path}\t#{session_name}"
    )
  }

  /// A well-formed line parses, with or without a trailing line break.
  @Test func parsesALine() {
    #expect(CreatedSession.parse(Self.line()) == Self.record)
    #expect(CreatedSession.parse(Self.line() + "\n") == Self.record)
    #expect(CreatedSession.parse(Self.line() + "\r\n") == Self.record)
  }

  /// Malformed or ambiguous lines are refused: a tab in the socket path or name, missing or
  /// extra fields, non-canonical numbers, a relative socket path, an empty name, line breaks.
  @Test(arguments: [
    "", Fixture.line(id: "3"), Fixture.line(created: "01792600001"), Fixture.line(created: "-1"),
    Fixture.line(pid: "0"), Fixture.line(pid: "+4242"), Fixture.line(pid: "99999999999"),
    Fixture.line(start: " 1"), Fixture.line(socket: "relative"),
    Fixture.line(socket: "/tmp/odd\tpath"), Fixture.line(name: ""),
    Fixture.line(name: "muxfinder-test-0a1b2c3d\tx"), Fixture.line() + "\nextra",
    "$3\t1792600001\t4242\t1792599999\t/private/tmp/tmux-501/default",
  ])
  func refusesMalformedLines(_ line: String) {
    #expect(CreatedSession.parse(line) == nil)
  }

  /// Discovery's session matches only with the same server, id, creation time and name: a
  /// restarted server whose new session reuses the id, or the name, does not match.
  @Test func matchesDiscoveredSessions() {
    func discovered(
      server: ServerIdentity = Self.server,
      id: String = "$3",
      createdAt: Int64 = 1_792_600_001,
      name: String = "muxfinder-test-0a1b2c3d"
    ) -> DiscoveredSession {
      DiscoveredSession(
        key: SessionKey(hostID: UUID(), server: server, sessionID: TmuxSessionID(id)!),
        name: name, createdAt: createdAt, windowCount: 2, attachedClientCount: 0,
        lastActivityAt: 0, clients: [])
    } // End of func discovered(server:id:createdAt:name:)
    #expect(Self.record.matches(discovered()))
    let restarted = ServerIdentity(
      socketPath: "/private/tmp/tmux-501/default", pid: 5000, startTime: 1_792_700_000)
    #expect(!Self.record.matches(discovered(server: restarted)))
    #expect(
      !Self.record.matches(
        discovered(
          server: ServerIdentity(
            socketPath: "/private/tmp/tmux-501/default", pid: 4242, startTime: 1_792_700_000))))
    #expect(
      !Self.record.matches(
        discovered(
          server: ServerIdentity(
            socketPath: "/private/tmp/tmux-501/other", pid: 4242, startTime: 1_792_599_999))))
    #expect(!Self.record.matches(discovered(id: "$4")))
    #expect(!Self.record.matches(discovered(createdAt: 1_792_600_002)))
    #expect(!Self.record.matches(discovered(name: "user-session")))
  } // End of func matchesDiscoveredSessions()

  /// Recovery by name finds the one session with the exact name created since the attempt
  /// started, and nothing when the name differs, the session is older, or the line is
  /// malformed or ambiguous.
  @Test func findsTheSessionByItsExactName() {
    let lines = [
      Self.line(id: "$0", name: "user-session"),
      Self.line(id: "$1", name: "muxfinder-test-0a1b2c3d-other"),
      Self.line(id: "$2", name: "muxfinder-test-0a1b2c3"),
      "garbage",
      Self.line(),
    ]
    let name = "muxfinder-test-0a1b2c3d"
    #expect(
      CreatedSession.find(named: name, createdNoEarlierThan: 1_792_600_000, in: lines)
        == Self.record)
    #expect(CreatedSession.find(named: name, createdNoEarlierThan: 1_792_600_002, in: lines) == nil)
    #expect(
      CreatedSession.find(named: "muxfinder-test-ffffffff", createdNoEarlierThan: 0, in: lines)
        == nil)
    #expect(CreatedSession.find(named: name, createdNoEarlierThan: 0, in: []) == nil)
    let twice = lines + [Self.line(id: "$9")]
    #expect(CreatedSession.find(named: name, createdNoEarlierThan: 0, in: twice) == nil)
  } // End of func findsTheSessionByItsExactName()

  // MARK: - Killing only this session

  /// The conditional kill is one `if-shell -F` whose format compares every field of the
  /// record, with the kill (the id single-quoted for tmux's parser) and the marker as its two
  /// commands; nothing else.
  @Test func buildsTheConditionalKill() throws {
    let arguments = try #require(Self.record.killIfUnchangedArguments)
    #expect(
      arguments == [
        "if-shell", "-F", "-t", "$3",
        "#{&&:#{==:#{session_id},$3},#{&&:#{==:#{session_created},1792600001},"
          + "#{&&:#{==:#{pid},4242},#{&&:#{==:#{start_time},1792599999},"
          + "#{&&:#{==:#{socket_path},/private/tmp/tmux-501/default},"
          + "#{==:#{session_name},muxfinder-test-0a1b2c3d}}}}}}",
        "kill-session -t '$3'", "display-message -p muxfinder-not-this-session",
      ])
    var hashed = Self.record
    hashed.name = "muxfinder-test-a #ü, x} 日本;"
    #expect(
      hashed.killIfUnchangedArguments?[4].hasSuffix(
        "#{==:#{session_name},muxfinder-test-a ##ü#, x#} 日本;}}}}}}") == true)
  } // End of func buildsTheConditionalKill()

  /// A value that cannot be written as a format literal, or a negative number, gives no
  /// arguments at all (so nothing runs).
  @Test func refusesValuesItCannotEncode() {
    var record = Self.record
    for name in ["", "a{b", "a[b", "a]b", "#[fg=red]", "a\tb", "a\u{7F}b"] {
      record.name = name
      #expect(record.killIfUnchangedArguments == nil, "\(name)")
    } // End of loop over the names
    record = Self.record
    record.server.socketPath = "/tmp/{x}/default"
    #expect(record.killIfUnchangedArguments == nil)
    record = Self.record
    record.createdAt = -1
    #expect(record.killIfUnchangedArguments == nil)
    record = Self.record
    record.server.startTime = -1
    #expect(record.killIfUnchangedArguments == nil)
    record = Self.record
    record.server.pid = 0
    #expect(record.killIfUnchangedArguments == nil)
    #expect(CreatedSession.formatLiteral("a#b,c}d ü") == "a##b#,c#}d ü")
    // A `#` that a combining mark joins into one character is escaped too.
    #expect(
      CreatedSession.formatLiteral("a#\u{301}b").map { Array($0.unicodeScalars) }
        == Array("a##\u{301}b".unicodeScalars))
  } // End of func refusesValuesItCannotEncode()

  /// Exit 0 with no output is a kill; exit 0 with the marker line, or tmux's "no server" error,
  /// is another session or none; anything else is a failure.
  @Test func readsTheKillOutcome() {
    let marker = CreatedSession.notThisSessionMarker + "\n"
    let cases: [(Int32?, String, String, CreatedSession.KillOutcome)] = [
      (0, "", "", .killed),
      (0, marker, "", .notThisSession),
      (1, "", "no server running on /private/tmp/tmux-501/default\n", .notThisSession),
      (
        1, "", "error connecting to /tmp/tmux-501/default (No such file or directory)\n",
        .notThisSession
      ),
      (0, CreatedSession.notThisSessionMarker, "", .failed),
      (0, "something\n", "", .failed),
      (0, marker + marker, "", .failed),
      (1, "", "can't find session: $3\n", .failed),
      (1, "", "", .failed),
      (255, "", "Connection to saturno-m4 closed by remote host.\n", .failed),
      (nil, "", "", .failed),
    ]
    for (status, stdout, stderr, expected) in cases {
      #expect(
        CreatedSession.killOutcome(
          exitStatus: status, standardOutput: stdout, standardError: stderr)
          == expected)
    } // End of loop over the cases
  } // End of func readsTheKillOutcome()

  /// On a private server: a record differing from the session in any one field (another
  /// session's id, a missing id, the creation time, the server pid or start time, the socket,
  /// the name) kills nothing; the exact record kills only its session; a session that reused the
  /// id and the name on a restarted server is not killed by the old record; with no server the
  /// outcome is `notThisSession`. Only `muxfinder-test-*` sessions.
  @Test(.enabled(if: DiscoveryEndToEndTests.tmuxPath != nil), .timeLimit(.minutes(1)))
  func killsOnlyTheRecordedSessionOnAPrivateServer() async throws {
    let tmux = try #require(DiscoveryEndToEndTests.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    var root = directory.path(percentEncoded: false)
    if root.hasSuffix("/") { root.removeLast() }
    let server = PrivateServer(
      tmux: tmux,
      environment: [
        "PATH": ProcessEnvironment.systemSearchPath, "HOME": root, "TMUX_TMPDIR": root,
      ])
    do {
      // A restarted server whose new session has the old id and name.
      let first = try await server.create("muxfinder-test-restart")
      try await server.kill(first.sessionID)
      try await server.waitUntilGone()
      let second = try await server.create("muxfinder-test-restart")
      #expect(second.sessionID == first.sessionID && second.name == first.name)
      #expect(second.server.pid != first.server.pid)
      #expect(try await server.killIfUnchanged(first) == .notThisSession)
      #expect(try await server.ids() == [second.sessionID.rawValue])
      // One field off at a time.
      let other = try await server.create("muxfinder-test-other")
      let target = try await server.create("muxfinder-test-k ##ü, x} 日本 ;x")
      #expect(target.name == "muxfinder-test-k #ü, x} 日本 ;x")
      var variants = Array(repeating: target, count: 8)
      variants[0].sessionID = other.sessionID
      variants[1].sessionID = TmuxSessionID("$999")!
      variants[2].createdAt += 1
      variants[3].server.pid += 1
      variants[4].server.startTime += 1
      variants[5].server.socketPath += "x"
      variants[6].name += "x"
      variants[7].name = other.name
      let all = [second, other, target].map(\.sessionID.rawValue).sorted()
      for variant in variants {
        #expect(try await server.killIfUnchanged(variant) == .notThisSession)
        #expect(try await server.ids().sorted() == all)
      } // End of loop over the variants
      #expect(try await server.killIfUnchanged(target) == .killed)
      #expect(
        try await server.ids().sorted() == [second, other].map(\.sessionID.rawValue).sorted())
      #expect(try await server.killIfUnchanged(target) == .notThisSession)
      #expect(try await server.killIfUnchanged(other) == .killed)
      #expect(try await server.killIfUnchanged(second) == .killed)
      try await server.waitUntilGone()
      #expect(try await server.killIfUnchanged(second) == .notThisSession)
    } catch {
      await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: server.environment)
      throw error
    }
    await DiscoveryEndToEndTests.cleanUp([], tmux: tmux, environment: server.environment)
  } // End of func killsOnlyTheRecordedSessionOnAPrivateServer()

  /// A test-owned tmux server under a private `TMUX_TMPDIR`.
  struct PrivateServer {
    /// The tmux executable.
    let tmux: String
    /// The environment that selects the private server.
    let environment: [String: String]

    /// Runs `tmux -u <arguments>` and returns the raw result.
    func run(_ arguments: [String]) async throws -> ProcessResult {
      try await DiscoveryEndToEndTests.tmuxResult(
        tmux, ["-u"] + arguments, environment: environment, timeout: .seconds(10))
    }

    /// Creates the detached session `name` (tmux expands formats in it) running `sleep 60`.
    func create(_ name: String) async throws -> CreatedSession {
      let result = try await run([
        "new-session", "-d", "-P", "-F", CreatedSession.format, "-s", name, "sleep", "60",
      ])
      try #require(result.succeeded)
      return try #require(
        CreatedSession.parse(String(decoding: result.standardOutput, as: UTF8.self)))
    }

    /// Kills `id` unconditionally (only this test's own sessions).
    func kill(_ id: TmuxSessionID) async throws {
      try #require(try await run(["kill-session", "-t", id.rawValue]).succeeded)
    }

    /// The conditional kill of `record` and its outcome.
    func killIfUnchanged(_ record: CreatedSession) async throws -> CreatedSession.KillOutcome {
      let arguments = try #require(record.killIfUnchangedArguments)
      let result = try await run(arguments)
      return CreatedSession.killOutcome(
        exitStatus: result.exitCode,
        standardOutput: String(decoding: result.standardOutput, as: UTF8.self),
        standardError: String(decoding: result.standardError, as: UTF8.self))
    } // End of func killIfUnchanged(_:)

    /// The session ids the server lists (none without a server).
    func ids() async throws -> [String] {
      let result = try await run(["list-sessions", "-F", "#{session_id}"])
      guard result.succeeded else { return [] }
      return String(decoding: result.standardOutput, as: UTF8.self).split(separator: "\n")
        .map(String.init)
    }

    /// Waits (at most 3 s) until no server answers, after its last session was killed.
    func waitUntilGone() async throws {
      for _ in 0..<30 {
        let answered = try await run(["list-sessions"]).succeeded
        if !answered { return }
        try await Task.sleep(for: .milliseconds(100))
      }
      Issue.record("the private server did not exit")
    }
  } // End of struct PrivateServer
}
