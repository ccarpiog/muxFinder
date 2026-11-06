import Foundation
import Testing

@testable import MuxFinderCore

/// Discovery's client record gains the client's terminal and creation time (PLAN.md D38, Phase
/// I-12c2): the static script asks tmux for them in a `tty` record of their own after the
/// client's line, framed by the run's nonce (review fix); the parser keeps a usable terminal path (absolute, printable ASCII without whitespace, at
/// most 255 bytes) and a canonical creation time, and an unusable or hostile value is unknown,
/// never a failed report. A client line without the record still parses. Synthetic reports,
/// plus the real script through the fake tmux.
@Suite("Discovery client fields")
struct ProbeClientFieldsTests {
  /// Shorthand.
  typealias B = ReportBuilder

  /// A client line followed by its `tty` record holding `created` and `tty`.
  static func client(
    tty: String = "/dev/ttys003",
    created: String = "1792600123",
    session: String = "$0",
    controlMode: String = "0",
    pid: String = "5000"
  ) -> String {
    B.client(session: session, controlMode: controlMode, pid: pid) + "\n"
      + B.tty(tty, created: created, pid: pid)
  }

  /// The one client record of a report with `line` as its client line.
  static func record(_ line: String) throws -> ProbeReport.ClientRecord {
    let report = try ProbeReportParser.parse(B.report(clients: [line]))
    let clients = try #require(report.clients)
    try #require(clients.records.count == 1)
    return clients.records[0]
  }

  /// The script asks tmux for both fields, read-only and static, in a record of their own
  /// after the client's line: the client's pid, the creation time, then the terminal before
  /// the nonce, printed as nothing when over the parser's limit (written as the parser's own).
  @Test func theScriptAsksForTheTerminalAndCreationTime() throws {
    let source = ProbeScript.script.source
    let lines = source.split(separator: "\n").map {
      $0.trimmingCharacters(in: .whitespaces)
    }
    let limit = ProbeReportParser.maximumTerminalPathLength
    let first = "f=\"client$tab$n$tab#{session_id}$tab#{client_control_mode}$tab#{client_pid}\""
    let index = try #require(lines.firstIndex(of: first))
    #expect(
      lines[index + 1] == "f=\"$f${nl}tty$tab$n$tab#{client_pid}$tab#{client_created}$tab\"")
    #expect(
      lines[index + 2]
        == "f=\"$f#{?#{e|>|:#{n:client_tty},\(limit)},,#{client_tty}}$tab$n\"")
    #expect(lines[index + 3] == "muxfinder_tmux list-clients -F \"$f\"")
    #expect(!source.contains("$tab#{client_tty}$tab"))
  } // End of func theScriptAsksForTheTerminalAndCreationTime()

  /// Present: both kept, with the five fields as before.
  @Test func keepsBothFieldsWhenPresent() throws {
    let record = try Self.record(Self.client(controlMode: "1", pid: "7001"))
    #expect(record.sessionID == TmuxSessionID("$0"))
    #expect(record.isControlMode && record.pid == 7001)
    #expect(record.terminalPath == "/dev/ttys003")
    #expect(record.createdAt == 1_792_600_123)
  }

  /// Absent: a client line with no `tty` record (an older probe, a fake) parses with both
  /// unknown; a six-field line stays malformed, and so does a seven-field one (both fields on
  /// the client's line, as before the review fix).
  @Test func absentFieldsAreUnknown() throws {
    let record = try Self.record(B.client())
    #expect(record.terminalPath == nil && record.createdAt == nil)
    #expect(record.pid == 5000)
    for extra in ["\t1792600123", "\t/dev/ttys003\t1792600123"] {
      #expect(throws: ProbeReportError.malformed(line: 9)) {
        try ProbeReportParser.parse(B.report(clients: [B.client() + extra]))
      }
    }
  } // End of func absentFieldsAreUnknown()

  /// A `tty` record that breaks the grammar fails the whole report, as a misplaced `path`
  /// record does: one before any client, one naming another client's pid or a malformed one,
  /// one with no creation time field, a second one for the same client, one carrying another
  /// nonce (no record of this run), and one without its end mark. None of these can come from
  /// a terminal's bytes, which follow the pid and the creation time and cannot predict the
  /// nonce.
  @Test func rejectsMisplacedTerminalRecords() {
    let client = B.client()
    let short = ["tty", B.nonce, "5000", "/dev/ttys003", B.nonce].joined(separator: "\t")
    let cases: [(String, Data, ProbeReportError)] = [
      ("before any client", B.report(clients: [B.tty("/dev/ttys003")]), .malformed(line: 9)),
      (
        "another client's pid", B.report(clients: [client, B.tty("/dev/ttys003", pid: "5001")]),
        .malformed(line: 10)
      ),
      (
        "a malformed pid", B.report(clients: [client, B.tty("/dev/ttys003", pid: "05000")]),
        .malformed(line: 10)
      ),
      ("no creation time field", B.report(clients: [client, short]), .malformed(line: 10)),
      (
        "two for one client",
        B.report(clients: [client, B.tty("/dev/ttys003"), B.tty("/dev/ttys004")]),
        .malformed(line: 11)
      ),
      (
        "another nonce",
        B.report(clients: [client, B.tty("/dev/ttys003", nonce: "fedcba9876543210")]),
        .malformed(line: 10)
      ),
      (
        "no end mark",
        B.report(clients: [client, B.tty("/dev/ttys003", end: "fedcba9876543210")]), .incomplete
      ),
    ]
    for (label, data, error) in cases {
      #expect(throws: error, "\(label)") { try ProbeReportParser.parse(data) }
    }
  } // End of func rejectsMisplacedTerminalRecords()

  /// A line break inside a terminal counts as a line, so errors after it name the right line.
  @Test func countsTheLinesInsideATerminalRecord() {
    var lines = B.lines(clients: [Self.client(tty: "/x\ny\nz")])
    let exit = lines.firstIndex(of: "clients-exit\t0")
    lines[exit ?? 0] = "clients-exit\tx"
    #expect(exit != nil)
    #expect(throws: ProbeReportError.malformed(line: 13)) {
      try ProbeReportParser.parse(B.data(lines))
    }
  }

  /// Unusable values are dropped one by one, the client and the report kept: an empty terminal
  /// (a client with none), a relative path, a space, a tab inside (the creation time, on the
  /// client's own line, unchanged), a control or non-ASCII byte, a path over 255 bytes; a
  /// creation time that is empty, signed, padded, has a leading zero or is not a number.
  @Test(
    arguments: [
      ("", "1792600123", nil, 1_792_600_123),
      ("dev/ttys003", "1792600123", nil, 1_792_600_123),
      ("/dev/tty s003", "1792600123", nil, 1_792_600_123),
      ("/dev/tty\ts003", "1792600123", nil, 1_792_600_123),
      ("/dev/tty\u{1B}s003", "1792600123", nil, 1_792_600_123),
      ("/dev/ttyé", "1792600123", nil, 1_792_600_123),
      ("/" + String(repeating: "a", count: 255), "1792600123", nil, 1_792_600_123),
      (
        "/" + String(repeating: "a", count: 254), "1792600123",
        "/" + String(repeating: "a", count: 254), 1_792_600_123
      ),
      ("/dev/ttys003", "", "/dev/ttys003", nil),
      ("/dev/ttys003", "-1", "/dev/ttys003", nil),
      ("/dev/ttys003", " 1792600123", "/dev/ttys003", nil),
      ("/dev/ttys003", "01792600123", "/dev/ttys003", nil),
      ("/dev/ttys003", "soon", "/dev/ttys003", nil),
    ] as [(String, String, String?, Int64?)])
  func unusableValuesAreUnknown(
    tty: String,
    created: String,
    expectedPath: String?,
    expectedCreated: Int64?
  ) throws {
    let record = try Self.record(Self.client(tty: tty, created: created))
    #expect(record.terminalPath == expectedPath)
    #expect(record.createdAt == expectedCreated)
    #expect(record.pid == 5000 && record.sessionID == TmuxSessionID("$0"))
  } // End of func unusableValuesAreUnknown(tty:created:expectedPath:expectedCreated:)

  /// Terminals no real tty has, as a hostile or broken client could report them (Phase I-12c2
  /// review fix): line breaks (alone, at the end, with a carriage return, after a guessed
  /// nonce), a tab with a number after it (a would-be creation time), the run's own nonce after
  /// a tab but with no line feed (no end mark), the nonce before a line feed but with no tab,
  /// and forged client, status and end lines carrying a guessed nonce.
  static let hostileTerminals: [String] = [
    "/dev/tty\ns003",
    "/dev/tty\ts003",
    "/dev/tty\t1792600999",
    "/dev/tty\r\ns003",
    "/dev/tty\n",
    "\n\n",
    "/dev/tty\t" + B.nonce,
    "/dev/" + B.nonce + "\n",
    "/dev/tty\tffffffffffffffff\nclient\tffffffffffffffff\t$0\t1\t6666\t1792600000",
    "/dev/tty\nclients-exit\t1\nclients-stderr\tlost server\nend\tffffffffffffffff",
  ]

  /// A hostile terminal costs only its own client's terminal path, through discovery's own
  /// path (the runner's output classified as `DiscoveryProbe.discover(_:)` does): the host is
  /// `ok`, both sessions are listed, that client keeps its pid, control mode and creation time,
  /// and the clients before and after it keep every field.
  @Test(arguments: hostileTerminals)
  func aHostileTerminalOnlyLosesItsPath(tty: String) async throws {
    let data = B.report(
      sessions: [B.session(id: "$0", name: "a"), B.session(id: "$1", name: "b")],
      clients: [
        Self.client(tty: "/dev/ttys001", created: "1792600001", pid: "5001"),
        Self.client(tty: tty, created: "1792600002", controlMode: "1", pid: "5002"),
        Self.client(tty: "/dev/ttys003", created: "1792600003", session: "$1", pid: "5003"),
      ])
    let probe = DiscoveryProbe(runner: FakeProcessRunner(stdout: data), baseEnvironment: [:])
    let result = try await probe.discover(HostConfig(displayName: "This Mac", mode: .local))
    guard case .ok(let sessions) = result.status else {
      Issue.record("not ok: \(result.status)")
      return
    }
    #expect(sessions.map(\.key.sessionID.rawValue) == ["$0", "$1"])
    #expect(sessions.map(\.name) == ["a", "b"])
    #expect(
      sessions.first?.clients == [
        ClientSummary(
          pid: 5001, isControlMode: false, terminalPath: "/dev/ttys001", createdAt: 1_792_600_001),
        ClientSummary(pid: 5002, isControlMode: true, terminalPath: nil, createdAt: 1_792_600_002),
      ])
    #expect(
      sessions.last?.clients == [
        ClientSummary(
          pid: 5003, isControlMode: false, terminalPath: "/dev/ttys003", createdAt: 1_792_600_003)
      ])
  } // End of func aHostileTerminalOnlyLosesItsPath(tty:)

  /// The real probe script through the fake tmux: the `tty` record is framed with the nonce on
  /// both sides, so the first client's terminal comes through and the second's, which hides a
  /// status line after a line break, is only unknown; both keep their creation times, and the
  /// sessions are listed as ever.
  @Test func theProbeScriptFramesTheTerminalRecord() async throws {
    try await ProbeScriptTests.withFakeTmux { tmux in
      let result = try await ProbeScriptTests.discover(tmuxPath: tmux, mode: "hostile-tty")
      let sessions = result.status.sessions
      #expect(sessions.map(\.key.sessionID.rawValue) == ["$0", "$7"], "\(result.status)")
      let expected = [
        ClientSummary(
          pid: 5151, isControlMode: false, terminalPath: "/dev/ttys001", createdAt: 1_700_000_200),
        ClientSummary(pid: 5152, isControlMode: true, terminalPath: nil, createdAt: 1_700_000_201),
      ]
      #expect(sessions.first?.clients == expected)
      #expect(sessions.last?.clients.isEmpty == true)
    }
  } // End of func theProbeScriptFramesTheTerminalRecord()

  /// The classified status hands both to each session's client summary, and its JSON (as
  /// `discover` prints it) shows them; an unknown one is left out.
  @Test func theSessionsClientsCarryBoth() throws {
    let report = try ProbeReportParser.parse(
      B.report(clients: [Self.client(controlMode: "1"), B.client(pid: "5001")]))
    let host = HostConfig(displayName: "This Mac", mode: .local)
    guard case .ok(let sessions) = ErrorClassifier.status(for: report, hostID: host.id) else {
      Issue.record("not ok")
      return
    }
    let clients = try #require(sessions.first?.clients)
    #expect(
      clients == [
        ClientSummary(
          pid: 5000, isControlMode: true, terminalPath: "/dev/ttys003", createdAt: 1_792_600_123),
        ClientSummary(pid: 5001, isControlMode: false),
      ])
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    let json = String(decoding: try encoder.encode(clients), as: UTF8.self)
    #expect(
      json
        == #"[{"createdAt":1792600123,"isControlMode":true,"pid":5000,"#
        + #""terminalPath":"/dev/ttys003"},{"isControlMode":false,"pid":5001}]"#)
    let decoded = try JSONDecoder().decode([ClientSummary].self, from: Data(json.utf8))
    #expect(decoded == clients)
  } // End of func theSessionsClientsCarryBoth()
} // End of struct ProbeClientFieldsTests
