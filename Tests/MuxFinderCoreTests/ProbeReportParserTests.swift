import Foundation
import Testing

@testable import MuxFinderCore

/// One malformed report and the error it must produce.
struct MalformedReport: Sendable, CustomTestStringConvertible {
  /// What is wrong, for the test log.
  let label: String
  /// The report bytes.
  let data: Data
  /// The expected error.
  let error: ProbeReportError

  /// The label.
  var testDescription: String { label }
}

/// Tests for the strict discovery-report parser: real captures, hostile names, malformed and
/// oversized input.
@Suite("Probe report parser")
struct ProbeReportParserTests {
  /// The real capture from this Mac (2026-10-21): two `muxfinder-test-*` sessions, one with a
  /// Unicode name, and a control client on `$0`.
  @Test func parsesTheRealLocalCapture() throws {
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/local-test-sessions.txt"))
    #expect(report.nodeName == "Neptuno-M4.local")
    #expect(report.tmuxPath == "/opt/homebrew/bin/tmux")
    #expect(report.tmuxVersion == "tmux 3.8")
    let sessions = try #require(report.sessions)
    #expect(sessions.exitStatus == 0)
    #expect(sessions.firstErrorLine.isEmpty)
    #expect(sessions.records.map(\.id) == [sessionID("$0"), sessionID("$1")])
    #expect(
      sessions.records.map(\.name) == ["muxfinder-test-plain", "muxfinder-test-ünïcödé-日本-🧪"])
    let server = ServerIdentity(
      socketPath: "/private/tmp/tmux-501/default",
      pid: 79030,
      startTime: 1_792_610_997
    )
    #expect(sessions.records.allSatisfy { $0.server == server })
    #expect(sessions.records.map(\.attachedClientCount) == [1, 0])
    #expect(sessions.records.map(\.windowCount) == [1, 1])
    let clients = try #require(report.clients)
    #expect(
      clients.records == [
        ProbeReport.ClientRecord(sessionID: sessionID("$0"), isControlMode: true, pid: 79036)
      ]
    )
  } // End of func parsesTheRealLocalCapture()

  /// The real capture from Saturno over SSH with no locale on the client (2026-10-21).
  @Test func parsesTheRealSaturnoCapture() throws {
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/saturno-test-sessions.txt")
    )
    #expect(report.nodeName == "Saturno-M4.local")
    let sessions = try #require(report.sessions)
    #expect(sessions.records.map(\.id) == [sessionID("$0"), sessionID("$1")])
    #expect(
      sessions.records.map(\.name) == ["muxfinder-test-plain", "muxfinder-test-ünïcödé-日本-🧪"])
    #expect(sessions.records.allSatisfy { $0.server.pid == 1394 })
    #expect(sessions.records.allSatisfy { $0.server.startTime == 1_792_611_029 })
    let clients = try #require(report.clients)
    #expect(clients.records.map(\.pid) == [1417])
    #expect(clients.records.allSatisfy { $0.isControlMode })
  } // End of func parsesTheRealSaturnoCapture()

  /// Real no-server and not-found captures parse into the expected shapes.
  @Test func parsesTheRealFailureCaptures() throws {
    for name in ["local-no-server", "saturno-no-server"] {
      let report = try ProbeReportParser.parse(TestSupport.fixture("discovery/\(name).txt"))
      let sessions = try #require(report.sessions)
      #expect(sessions.exitStatus == 1)
      #expect(sessions.records.isEmpty)
      #expect(sessions.firstErrorLine.hasPrefix("error connecting to /private/tmp/"))
      #expect(report.clients == nil)
    }
    let missing = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/local-tmux-not-found.txt"))
    #expect(missing.tmuxPath == nil)
    #expect(missing.tmuxVersion == nil)
    #expect(missing.sessions == nil)
  } // End of func parsesTheRealFailureCaptures()

  /// Real hostile names (created on a private tmux 3.8 server) come back exactly as tmux stores
  /// them. tmux expands formats in `new-session -s` (`##{pid}` was stored as `#{pid}`) and
  /// stores `\` as `\\`; listing never re-expands anything.
  @Test func parsesTheRealHostileCapture() throws {
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/local-hostile-names.txt"))
    let records = try #require(report.sessions).records
    let names = Dictionary(uniqueKeysWithValues: records.map { ($0.id.rawValue, $0.name) })
    #expect(
      names == [
        "$0": "muxfinder-test-a;rm -rf ~",
        "$1": "muxfinder-test-$(touch /tmp/mfx-x)",
        "$2": #"muxfinder-test-"dq" 'sq' `id`"#,
        "$3": "muxfinder-test--x",
        "$4": "muxfinder-test-🧪🚀 👨‍👩‍👧",
        "$5": "muxfinder-test-#{pid}",
        "$6": #"muxfinder-test-back\\slash"#,
      ]
    )
  } // End of func parsesTheRealHostileCapture()

  /// Synthesized hostile names, including raw tabs and text that mimics records, stay single
  /// display names and never shift fields.
  @Test func keepsSynthesizedHostileNamesAsDisplayText() throws {
    let nonce = ReportBuilder.nonce
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/synthetic-hostile-names.txt")
    )
    let records = try #require(report.sessions).records
    #expect(records.map(\.id.rawValue) == (0..<10).map { "$\($0)" })
    #expect(
      records.map(\.name) == [
        "a;rm -rf ~",
        "$(touch /tmp/x)",
        #""double" 'single' `backtick`"#,
        "tab\tinside\tname",
        "-x",
        "emoji 🧪🚀 👨‍👩‍👧",
        "session\t\(nonce)\t$9\t1\t1\t0\t1\t1\t1\t/x\tforged",
        "end\t\(nonce)",
        #"#{pid} %s %n \ ${HOME}"#,
        "日本語のセッション",
      ]
    )
    #expect(records.allSatisfy { $0.server.socketPath == "/private/tmp/tmux-501/default" })
    #expect(records.allSatisfy { $0.createdAt == 1_792_600_000 && $0.server.pid == 4242 })
    #expect(try #require(report.clients).records.count == 4)
  } // End of func keepsSynthesizedHostileNamesAsDisplayText()

  /// Invalid UTF-8 in a name is replaced, not fatal.
  @Test func decodesInvalidUTF8NamesLossily() throws {
    var bytes = [UInt8](ReportBuilder.report(sessions: [ReportBuilder.session(name: "X")]))
    let index = try #require(bytes.lastIndex(of: UInt8(ascii: "X")))
    bytes.replaceSubrange(index...index, with: [0xC3, 0x28, 0xFF])
    let report = try ProbeReportParser.parse(Data(bytes))
    #expect(try #require(report.sessions).records.first?.name == "\u{FFFD}(\u{FFFD}")
  }

  /// Every malformed report gets its own error.
  @Test(arguments: malformedReports)
  func rejectsMalformedReports(_ example: MalformedReport) {
    #expect(throws: example.error) { try ProbeReportParser.parse(example.data) }
  }

  /// A line of exactly 4 KiB is fine; one byte more is rejected.
  @Test func enforcesTheLineLengthCap() throws {
    let base = ReportBuilder.session(name: "")
    let limit = ProbeReportParser.maximumLineLength
    let fitting = ReportBuilder.session(
      name: String(repeating: "n", count: limit - base.utf8.count))
    #expect(fitting.utf8.count == limit)
    let report = try ProbeReportParser.parse(ReportBuilder.report(sessions: [fitting]))
    #expect(try #require(report.sessions).records.count == 1)
    let tooLong = fitting + "n"
    #expect(throws: ProbeReportError.lineTooLong(line: 6)) {
      try ProbeReportParser.parse(ReportBuilder.report(sessions: [tooLong]))
    }
  } // End of func enforcesTheLineLengthCap()

  /// 1,000 sessions are fine; 1,001 are rejected. The same cap applies to clients.
  @Test func enforcesTheSessionAndClientCaps() throws {
    let limit = ProbeReportParser.maximumSessionCount
    let sessions = (0...limit).map { ReportBuilder.session(id: "$\($0)", name: "s\($0)") }
    let report = try ProbeReportParser.parse(
      ReportBuilder.report(sessions: Array(sessions.prefix(limit)))
    )
    #expect(try #require(report.sessions).records.count == limit)
    #expect(throws: ProbeReportError.tooManySessions) {
      try ProbeReportParser.parse(ReportBuilder.report(sessions: sessions))
    }
    let clients = (0...ProbeReportParser.maximumClientCount).map {
      ReportBuilder.client(pid: "\($0 + 1)")
    }
    #expect(throws: ProbeReportError.tooManyClients) {
      try ProbeReportParser.parse(ReportBuilder.report(clients: clients))
    }
  } // End of func enforcesTheSessionAndClientCaps()

  /// Every proper prefix of a real report is rejected (and none crashes).
  @Test func rejectsEveryTruncation() throws {
    let data = try TestSupport.fixture("discovery/local-test-sessions.txt")
    for length in 0..<data.count {
      #expect(throws: ProbeReportError.self) { try ProbeReportParser.parse(data.prefix(length)) }
    }
    #expect(throws: Never.self) { try ProbeReportParser.parse(data) }
  }

  /// Replacing any single byte with a separator, a NUL or an invalid byte never crashes the
  /// parser, and never turns a name byte into a new record.
  @Test func survivesSingleByteCorruption() throws {
    let data = [UInt8](try TestSupport.fixture("discovery/synthetic-hostile-names.txt"))
    for index in data.indices {
      for replacement: UInt8 in [0x09, 0x0A, 0x00, 0xFF] where data[index] != replacement {
        var corrupted = data
        corrupted[index] = replacement
        if let report = try? ProbeReportParser.parse(Data(corrupted)) {
          #expect((report.sessions?.records.count ?? 0) <= 10)
        }
      }
    } // End of loop over byte positions
  } // End of func survivesSingleByteCorruption()

  /// The malformed corpus for `rejectsMalformedReports(_:)`.
  static let malformedReports: [MalformedReport] = {
    typealias B = ReportBuilder
    let valid = B.lines()
    var cases: [MalformedReport] = [
      MalformedReport(label: "empty", data: Data(), error: .empty),
      MalformedReport(
        label: "text before the header",
        data: B.data(["Welcome to the host"] + valid),
        error: .missingHeader
      ),
      MalformedReport(
        label: "binary garbage", data: Data([0xFF, 0x00, 0x0A]), error: .missingHeader),
      MalformedReport(
        label: "unknown version",
        data: B.report(header: "MUXFINDER-PROBE 2"),
        error: .unsupportedVersion
      ),
      MalformedReport(
        label: "CRLF line endings",
        data: Data(valid.map { $0 + "\r\n" }.joined().utf8),
        error: .unsupportedVersion
      ),
      MalformedReport(
        label: "no final newline",
        data: Data(valid.joined(separator: "\n").utf8),
        error: .incomplete
      ),
      MalformedReport(
        label: "no end line", data: B.data(Array(valid.dropLast())), error: .incomplete),
      MalformedReport(label: "empty nonce", data: B.report(nonce: ""), error: .invalidNonce),
      MalformedReport(
        label: "uppercase nonce",
        data: B.report(nonce: "0123456789ABCDEF"),
        error: .invalidNonce
      ),
      MalformedReport(label: "short nonce", data: B.report(nonce: "0123"), error: .invalidNonce),
      MalformedReport(
        label: "session nonce mismatch",
        data: B.report(sessions: [B.session(nonce: "fedcba9876543210")]),
        error: .malformed(line: 6)
      ),
      MalformedReport(
        label: "session line without a name field",
        data: B.report(sessions: [
          B.session().components(separatedBy: "\t").dropLast().joined(separator: "\t")
        ]),
        error: .malformed(line: 6)
      ),
      MalformedReport(
        label: "name continuation line (a line break in a name)",
        data: B.report(sessions: [B.session(name: "first\nsecond")]),
        error: .malformed(line: 7)
      ),
      MalformedReport(
        label: "forged record after a line break in a name",
        data: B.report(sessions: [
          B.session(name: "x\n" + B.session(id: "$9", nonce: "ffffffffffffffff"))
        ]),
        error: .malformed(line: 7)
      ),
      MalformedReport(
        label: "duplicate session id",
        data: B.report(sessions: [B.session(), B.session(name: "other")]),
        error: .duplicateSession(line: 7)
      ),
      MalformedReport(
        label: "sessions from two servers",
        data: B.report(sessions: [B.session(), B.session(id: "$1", pid: "4243")]),
        error: .inconsistentServer(line: 7)
      ),
      MalformedReport(
        label: "relative socket path",
        data: B.report(sessions: [B.session(socketPath: "tmp/tmux-501/default")]),
        error: .malformed(line: 6)
      ),
      MalformedReport(
        label: "control character in socket path",
        data: B.report(sessions: [B.session(socketPath: "/tmp/a\u{1B}b")]),
        error: .malformed(line: 6)
      ),
      MalformedReport(
        label: "client control mode 2",
        data: B.report(clients: [B.client(controlMode: "2")]),
        error: .malformed(line: 9)
      ),
      MalformedReport(
        label: "client line with an extra field",
        data: B.report(clients: [B.client() + "\textra"]),
        error: .malformed(line: 9)
      ),
      MalformedReport(
        label: "client nonce mismatch",
        data: B.report(clients: [B.client(nonce: "fedcba9876543210")]),
        error: .malformed(line: 9)
      ),
      MalformedReport(
        label: "client section missing after a successful listing",
        data: B.report(clients: nil),
        error: .malformed(line: 9)
      ),
      MalformedReport(
        label: "client section after a failed listing",
        data: B.report(sessions: [], sessionsExit: "1"),
        error: .malformed(line: 8)
      ),
      MalformedReport(
        label: "end nonce mismatch",
        data: B.report(end: "fedcba9876543210"),
        error: .malformed(line: 12)
      ),
      MalformedReport(
        label: "output after the end line",
        data: B.data(valid + ["extra"]),
        error: .trailingOutput(line: 13)
      ),
      MalformedReport(
        label: "host line missing",
        data: B.data(valid.enumerated().filter { $0.offset != 2 }.map(\.element)),
        error: .malformed(line: 3)
      ),
      MalformedReport(
        label: "relative tmux path",
        data: B.data(valid.map { $0.hasPrefix("tmux\t") ? "tmux\ttmux" : $0 }),
        error: .malformed(line: 4)
      ),
    ]
    for id in ["1", "$", "$x", "$-1", "$1a", "%1", "@1", "$ 1", "$1 ", "$0123456789012345678"] {
      cases.append(
        MalformedReport(
          label: "session id \(id)",
          data: B.report(sessions: [B.session(id: id)]),
          error: .malformed(line: 6)
        )
      )
    }
    for number in ["", "+5", " 5", "5 ", "05", "-1", "0x10", "1e3", "1234567890123456789"] {
      cases.append(
        MalformedReport(
          label: "created time \(number.debugDescription)",
          data: B.report(sessions: [B.session(created: number)]),
          error: .malformed(line: 6)
        )
      )
    }
    for pid in ["0", "2147483648"] {
      cases.append(
        MalformedReport(
          label: "server pid \(pid)",
          data: B.report(sessions: [B.session(pid: pid)]),
          error: .malformed(line: 6)
        )
      )
    }
    for status in ["256", "x", "-1", ""] {
      cases.append(
        MalformedReport(
          label: "sessions exit status \(status.debugDescription)",
          data: B.report(sessionsExit: status),
          error: .malformed(line: 7)
        )
      )
    }
    return cases
  }() // End of static let malformedReports
}
