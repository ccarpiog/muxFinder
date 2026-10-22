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
}
