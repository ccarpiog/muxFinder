import Foundation
import Testing

@testable import MuxFinderCore

/// One `path` record value and what the parser must make of it.
struct PathExample: Sendable, CustomTestStringConvertible {
  /// What it is, for the test log.
  let label: String
  /// The path's bytes as tmux would print them.
  let bytes: [UInt8]

  /// The label.
  var testDescription: String { label }

  /// An example whose bytes are `text`'s UTF-8.
  init(_ label: String, _ text: String) {
    self.label = label
    bytes = Array(text.utf8)
  }

  /// An example with raw `bytes`.
  init(_ label: String, bytes: [UInt8]) {
    self.label = label
    self.bytes = bytes
  }
}

/// The session start folders in discovery (PLAN.md D31): the probe's `path` record, its framing
/// against hostile paths, and the parser's rules for keeping or dropping a path. Paths are
/// synthetic; the real capture comes from a private tmux 3.8 server.
@Suite("Probe report: session start folders")
struct ProbeSessionPathTests {
  /// Shorthand.
  typealias B = ReportBuilder

  /// A default report whose one session has a `path` record with `bytes` as its path.
  static func report(withPath bytes: [UInt8], id: String = "$0") throws -> Data {
    let marker = Array("@@PATH@@".utf8)
    var data = [UInt8](
      B.report(sessions: [B.session(id: id), B.path("@@PATH@@", id: id)]))
    let index = try #require(LineReader.firstIndex(of: marker, in: data, from: 0))
    data.replaceSubrange(index..<(index + marker.count), with: bytes)
    return Data(data)
  }

  /// The real capture (2026-10-24, tmux 3.8 on a private server, `-c` values synthetic):
  /// plain and Unicode folders are kept exactly (tmux stored `##1` as `#1` and keeps `~/…` as
  /// given); a forged session and status lines after a line break, a tab and escape sequence,
  /// an empty folder, a C1 control and invalid UTF-8 are dropped, and no record was forged.
  @Test func parsesTheRealCapture() throws {
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/local-session-paths.txt"))
    let records = try #require(report.sessions).records
    let folders = Dictionary(uniqueKeysWithValues: records.map { ($0.id.rawValue, $0) })
    #expect(records.count == 7)
    #expect(Set(folders.keys) == Set((0...6).map { "$\($0)" }))
    #expect(folders["$0"]?.name == "muxfinder-test-plain")
    #expect(folders["$0"]?.startDirectory == "/Users/example/projects/site")
    #expect(folders["$1"]?.startDirectory == "~/dir with spaces ünïcödé 日本 #1 a;b")
    #expect(records.filter { $0.startDirectory != nil }.count == 2)
    #expect(report.droppedStartDirectoryCount == 5)
    #expect(try #require(report.clients).records.isEmpty)
  } // End of func parsesTheRealCapture()

  /// The synthetic corpus: spaces, Unicode, `#`, `;`, `%` and a leading `-` are kept as they
  /// are; every path with a control character, invalid UTF-8 or nothing in it is dropped and
  /// counted; the forged session, client, status, end and path lines inside paths (with a
  /// nonce they guessed) stay inside their records; a session without a record has no folder.
  @Test func keepsPlainPathsAndDropsHostileOnes() throws {
    let report = try ProbeReportParser.parse(
      TestSupport.fixture("discovery/synthetic-session-paths.txt"))
    let sessions = try #require(report.sessions)
    #expect(sessions.records.map(\.id.rawValue) == (0...16).map { "$\($0)" })
    #expect(sessions.exitStatus == 0)
    let folders = sessions.records.map(\.startDirectory)
    #expect(folders[0] == "~/projects/site")
    #expect(folders[1] == "/Users/example/dir with spaces")
    #expect(folders[2] == "~/ünïcödé/日本/🧪 👨‍👩‍👧")
    #expect(folders[3] == "~/#1;a;b #{pid} %s")
    #expect(folders[16] == "-x")
    #expect(folders[4...15].allSatisfy { $0 == nil })
    #expect(report.droppedStartDirectoryCount == 11)
    #expect(sessions.records.allSatisfy { $0.server.pid == 4242 })
    let clients = try #require(report.clients)
    #expect(
      clients.records == [
        ProbeReport.ClientRecord(sessionID: sessionID("$0"), isControlMode: true, pid: 5000)
      ])
  } // End of func keepsPlainPathsAndDropsHostileOnes()

  /// Reports without any `path` record (every capture made before the record existed, and the
  /// probe's failure reports) still parse, with no folder and nothing dropped.
  @Test(arguments: [
    "local-test-sessions", "saturno-test-sessions", "local-hostile-names",
    "synthetic-hostile-names", "local-no-server", "saturno-no-server", "local-tmux-not-found",
  ])
  func parsesReportsWithoutPathRecords(_ name: String) throws {
    let report = try ProbeReportParser.parse(TestSupport.fixture("discovery/\(name).txt"))
    #expect(report.sessions?.records.allSatisfy { $0.startDirectory == nil } ?? true)
    #expect(report.droppedStartDirectoryCount == 0)
  }

  /// Paths the parser keeps exactly, as display text.
  static let keptPaths: [PathExample] = [
    PathExample("absolute", "/Users/example/projects/site"),
    PathExample("home relative", "~/projects/site"),
    PathExample("relative", "projects/site"),
    PathExample("spaces", "/Users/example/dir with  spaces "),
    PathExample("unicode", "/Users/example/ünïcödé/日本語/中文 한국어/🧪🚀"),
    PathExample("decomposed accent", "/Users/example/cafe\u{301}"),
    PathExample("hash", "~/#1 #{pid} ##"),
    PathExample("semicolons", "~/a;b;"),
    PathExample("shell text", #"~/$(touch x) `id` 'sq' "dq" \ * ? [a]"#),
    PathExample("leading hyphen", "-x"),
    PathExample("another run's nonce", "/x ffffffffffffffff"),
    PathExample("longest", "/" + String(repeating: "x", count: 4095)),
  ]

  /// A plain path comes back exactly, and nothing is dropped.
  @Test(arguments: keptPaths)
  func keepsAPath(_ example: PathExample) throws {
    let report = try ProbeReportParser.parse(Self.report(withPath: example.bytes))
    let record = try #require(report.sessions?.records.first)
    #expect(record.startDirectory.map { Array($0.utf8) } == example.bytes)
    #expect(report.droppedStartDirectoryCount == 0)
  }

  /// Paths the parser drops: every control character (C0 with tab, line feed and carriage
  /// return, DEL, C1), invalid UTF-8, nothing, and one byte over the limit.
  static let droppedPaths: [PathExample] = [
    PathExample("tab", "/x\ty"),
    PathExample("line feed", "/x\ny"),
    PathExample("carriage return", "/x\ry"),
    PathExample("escape sequence", "/x\u{1B}[31mred"),
    PathExample("bell", "/x\u{07}"),
    PathExample("delete", "/x\u{7F}y"),
    PathExample("C1 next line", "/x\u{85}y"),
    PathExample("C1 CSI", "/x\u{9B}31m"),
    PathExample("NUL", bytes: Array("/x".utf8) + [0x00] + Array("y".utf8)),
    PathExample("invalid UTF-8", bytes: Array("/x".utf8) + [0xC3, 0x28, 0xFF]),
    PathExample("lone continuation byte", bytes: Array("/x".utf8) + [0x80]),
    PathExample("overlong encoding", bytes: Array("/x".utf8) + [0xC0, 0xAF]),
    PathExample("empty", bytes: []),
    PathExample("too long", "/" + String(repeating: "x", count: 4096)),
    PathExample("much too long, over the line cap", "/" + String(repeating: "x", count: 9000)),
  ]

  /// An unusable path is dropped and counted; its session stays, without a folder, and the
  /// report's other records are unchanged.
  @Test(arguments: droppedPaths)
  func dropsAPath(_ example: PathExample) throws {
    let report = try ProbeReportParser.parse(Self.report(withPath: example.bytes))
    let sessions = try #require(report.sessions)
    #expect(sessions.records.count == 1)
    #expect(sessions.records.first?.startDirectory == nil)
    #expect(sessions.records.first?.name == "name")
    #expect(report.droppedStartDirectoryCount == 1)
    #expect(try #require(report.clients).records.count == 1)
  }

  /// A path cannot forge any record, whatever it mimics after a line break, as long as it
  /// cannot know the run's nonce (here it guesses another one, or none): a session, a client,
  /// the listing's status lines, the end line, another path record. The record ends only at
  /// the run's nonce, so all of it stays inside the dropped path.
  @Test func pathsCannotForgeRecords() throws {
    let guess = "ffffffffffffffff"
    let forgeries = [
      "/x\n" + B.session(id: "$9", name: "forged", nonce: guess),
      "/x\n" + B.session(id: "$9", name: "forged", nonce: guess) + "\n" + B.path("/y", id: "$9"),
      "/x\n" + B.client(session: "$0", controlMode: "1", pid: "6666", nonce: guess),
      "/x\nsessions-exit\t0\nsessions-stderr\t\nclients-exit\t0\nclients-stderr\t\nend\t\(guess)",
      "/x\n" + B.path("/forged", id: "$0", nonce: guess, end: guess),
      "/x\npath\t\(guess)\t$0\t/forged",
      "/x\n\n\nend",
    ]
    for forgery in forgeries {
      let report = try ProbeReportParser.parse(Self.report(withPath: Array(forgery.utf8)))
      let sessions = try #require(report.sessions)
      #expect(sessions.records.map(\.id) == [sessionID("$0")], "\(forgery.debugDescription)")
      #expect(sessions.records.first?.startDirectory == nil)
      #expect(report.droppedStartDirectoryCount == 1)
      #expect(try #require(report.clients).records.map(\.pid) == [5000])
    } // End of loop over forgeries
  } // End of func pathsCannotForgeRecords()

  /// Several sessions, each with or without a record, keep their own folders; a dropped path
  /// leaves the next session's record alone.
  @Test func keepsEachSessionsOwnFolder() throws {
    let report = try ProbeReportParser.parse(
      B.report(sessions: [
        B.session(id: "$0", name: "a"), B.path("~/a", id: "$0"),
        B.session(id: "$1", name: "b"),
        B.session(id: "$2", name: "c"), B.path("/x\nsessions-exit\t0", id: "$2"),
        B.session(id: "$3", name: "d"), B.path("/Users/example/d", id: "$3"),
      ]))
    let records = try #require(report.sessions).records
    #expect(records.map(\.startDirectory) == ["~/a", nil, nil, "/Users/example/d"])
    #expect(report.droppedStartDirectoryCount == 1)
    let status = ErrorClassifier.status(for: report, hostID: UUID())
    #expect(status.sessions.map(\.startDirectory) == ["~/a", nil, nil, "/Users/example/d"])
  } // End of func keepsEachSessionsOwnFolder()

  /// A `path` record that breaks the grammar fails the whole report: one before any session,
  /// one naming another session, a second one for the same session, one without its end mark,
  /// and one carrying another nonce (which is no record of this run at all).
  @Test func rejectsMisplacedPathRecords() {
    let cases: [(String, Data, ProbeReportError)] = [
      ("before any session", B.report(sessions: [B.path("/x")]), .malformed(line: 6)),
      (
        "another session's id", B.report(sessions: [B.session(id: "$0"), B.path("/x", id: "$1")]),
        .malformed(line: 7)
      ),
      (
        "a malformed id", B.report(sessions: [B.session(id: "$0"), B.path("/x", id: "0")]),
        .malformed(line: 7)
      ),
      (
        "two for one session",
        B.report(sessions: [B.session(), B.path("/x"), B.path("/y")]), .malformed(line: 8)
      ),
      (
        "another nonce",
        B.report(sessions: [B.session(), B.path("/x", nonce: "fedcba9876543210")]),
        .malformed(line: 7)
      ),
      (
        "no end mark",
        B.report(sessions: [B.session(), B.path("/x", end: "fedcba9876543210")]), .incomplete
      ),
    ]
    for (label, data, error) in cases {
      #expect(throws: error, "\(label)") { try ProbeReportParser.parse(data) }
    }
  } // End of func rejectsMisplacedPathRecords()

  /// A line break inside a path counts as a line, so errors after it name the right line.
  @Test func countsTheLinesInsideAPathRecord() {
    let data = B.report(
      sessions: [B.session(), B.path("/x\ny\nz")], sessionsExit: "x")
    #expect(throws: ProbeReportError.malformed(line: 10)) { try ProbeReportParser.parse(data) }
  }

  /// Every proper prefix of the synthetic corpus is rejected, none crashes.
  @Test func rejectsEveryTruncation() throws {
    let data = try TestSupport.fixture("discovery/synthetic-session-paths.txt")
    for length in 0..<data.count {
      #expect(throws: ProbeReportError.self) { try ProbeReportParser.parse(data.prefix(length)) }
    }
  }

  /// Replacing any single byte of the synthetic corpus with a separator, a NUL or an invalid
  /// byte never crashes the parser, and never makes a session out of path bytes.
  @Test func survivesSingleByteCorruption() throws {
    let data = [UInt8](try TestSupport.fixture("discovery/synthetic-session-paths.txt"))
    for index in data.indices {
      for replacement: UInt8 in [0x09, 0x0A, 0x00, 0xFF] where data[index] != replacement {
        var corrupted = data
        corrupted[index] = replacement
        if let report = try? ProbeReportParser.parse(Data(corrupted)) {
          #expect((report.sessions?.records.count ?? 0) <= 17)
          #expect(report.sessions?.records.contains { $0.id.rawValue == "$99" } != true)
        }
      }
    } // End of loop over byte positions
  } // End of func survivesSingleByteCorruption()

  /// The real probe script through the fake tmux: the record is framed with the nonce on both
  /// sides, so `$0`'s folder comes through and `$7`'s, which hides a status line after a line
  /// break, is dropped without breaking the report.
  @Test func probeScriptFramesThePathRecord() async throws {
    try await ProbeScriptTests.withFakeTmux { tmux in
      let result = try await ProbeScriptTests.discover(tmuxPath: tmux, mode: "sessions")
      let sessions = result.status.sessions
      #expect(sessions.map(\.key.sessionID.rawValue) == ["$0", "$7"], "\(result.status)")
      #expect(sessions.map(\.startDirectory) == ["/Users/example/projects/site", nil])
      #expect(result.report?.droppedStartDirectoryCount == 1)
      #expect(sessions.last?.clients.isEmpty == true)
    }
  } // End of func probeScriptFramesThePathRecord()

  /// The D3 command string (what ssh hands the remote login shell) frames the record the same
  /// way through sh, zsh and bash: the line break in the format survives each of them.
  @Test(arguments: [["/bin/sh"], ["/bin/zsh", "-f"], ["/bin/bash"]])
  func remoteCommandStringFramesThePathRecord(loginShell: [String]) async throws {
    try await ProbeScriptTests.withFakeTmux(directoryName: "it's here") { tmux in
      let command = ShellQuoting.remoteCommand(script: ProbeScript.script, args: [tmux])
      let result = try await TestSupport.fastRunner.run(
        ProcessRequest(
          executableURL: URL(fileURLWithPath: loginShell[0]),
          arguments: Array(loginShell.dropFirst()) + ["-c", command],
          environment: [
            "PATH": ProcessEnvironment.systemSearchPath, "MUXFINDER_FAKE_MODE": "sessions",
          ],
          timeout: .seconds(10)))
      let classification = ErrorClassifier.classify(result, transport: .ssh, hostID: UUID())
      #expect(
        classification.status.sessions.map(\.startDirectory) == [
          "/Users/example/projects/site", nil,
        ], "\(classification.status)")
      #expect(classification.report?.droppedStartDirectoryCount == 1)
    }
  } // End of func remoteCommandStringFramesThePathRecord(loginShell:)

  /// The script's session format puts the record right after the session line, with the nonce
  /// before the id and again after the path (the end mark the parser looks for), and has tmux
  /// print a path over the parser's limit as nothing, the limit written as the parser's own.
  @Test func scriptFormatsTheRecordAfterTheSessionLine() {
    let source = ProbeScript.script.source
    let limit = ProbeReportParser.maximumStartDirectoryLength
    #expect(source.contains(#"f="$f${nl}path$tab$n$tab#{session_id}$tab""#))
    #expect(
      source.contains(
        #"f="$f#{?#{e|>|:#{n:session_path},"# + "\(limit)" + #"},,#{session_path}}$tab$n""#))
    #expect(!source.contains("$tab#{session_path}$tab"))
    #expect(source.contains("#{session_name}\"\n"))
  } // End of func scriptFormatsTheRecordAfterTheSessionLine()

  /// The runner/classifier boundary at the parser's limits: the real probe script through the
  /// real runner with discovery's own request, the fake tmux printing 1,000 sessions on
  /// 4,096-byte lines, each but the last in the longest folder kept, and 1,000 clients (about
  /// 8 MiB, eight times the runner's default cap). Nothing is cut, every session and folder
  /// comes through, and the last session's empty record (what tmux prints for a folder over
  /// 4,096 bytes) is dropped and counted, never a folder.
  @Test(.timeLimit(.minutes(1)))
  func discoversAReportAtTheParsersLimits() async throws {
    try await ProbeScriptTests.withFakeTmux { tmux in
      let probe = DiscoveryProbe(
        runner: TestSupport.fastRunner,
        baseEnvironment: [
          "PATH": ProcessEnvironment.systemSearchPath, "MUXFINDER_FAKE_MODE": "many-paths",
        ],
        timeout: .seconds(30))
      let host = HostConfig(displayName: "This Mac", mode: .local, tmuxPathOverride: tmux)
      let request = try probe.request(for: host)
      #expect(request.outputLimit == ProbeReportParser.maximumReportSize)
      #expect(request.errorOutputLimit == ProcessRequest.defaultOutputLimit)
      let run = try await TestSupport.fastRunner.run(request)
      #expect(!run.standardOutputTruncated)
      #expect(run.standardOutput.count > 7 * ProcessRequest.defaultOutputLimit)
      #expect(run.standardOutput.count <= ProbeReportParser.maximumReportSize)
      let classification = ErrorClassifier.classify(run, transport: .local, hostID: host.id)
      let sessions = classification.status.sessions
      #expect(classification.status.kind == "ok", "\(classification.status)")
      #expect(sessions.count == ProbeReportParser.maximumSessionCount)
      let folder = "/" + String(repeating: "x", count: 4095)
      #expect(sessions.dropLast().allSatisfy { $0.startDirectory == folder })
      #expect(sessions.last?.startDirectory == nil)
      #expect(classification.report?.droppedStartDirectoryCount == 1)
      #expect(sessions.allSatisfy { $0.clients.count == 1 && $0.name.utf8.count > 3900 })
    }
  } // End of func discoversAReportAtTheParsersLimits()

  /// The output budget holds the largest report the parser accepts: the host, tmux and version
  /// lines at the 4,096-byte line cap, 1,000 sessions with the longest ids on lines at the cap,
  /// each with a path record holding the longest folder kept, and 1,000 clients. Through a
  /// runner that keeps stdout up to the request's cap, as the real one does, discovery lists
  /// every session with its folder.
  @Test func theOutputBudgetHoldsTheLargestAcceptedReport() async throws {
    let filler = { (count: Int) in String(repeating: "n", count: count) }
    let ids = (0..<ProbeReportParser.maximumSessionCount).map {
      "$" + String(100_000_000_000_000_000 + $0)
    }
    #expect(ids.allSatisfy { $0.utf8.count == 1 + TmuxSessionID.maximumDigits })
    var sessions: [String] = []
    for id in ids {
      let line = B.session(id: id, name: "")
      sessions.append(B.session(id: id, name: filler(4096 - line.utf8.count)))
      sessions.append(B.path("/" + filler(4095), id: id))
    } // End of loop over sessions
    let clients = ids.prefix(ProbeReportParser.maximumClientCount).map {
      B.client(session: $0, controlMode: "1", pid: "2147483647")
    }
    var lines = B.lines(sessions: sessions, clients: clients)
    lines[2] = "host\t" + filler(4096 - 5)
    lines[3] = "tmux\t/" + filler(4096 - 6)
    lines[4] = "version\t" + filler(4096 - 8)
    #expect(
      lines.filter { !$0.hasPrefix("path\t") }.allSatisfy {
        $0.utf8.count <= ProbeReportParser.maximumLineLength
      })
    let data = B.data(lines)
    #expect(data.count > 7 * ProcessRequest.defaultOutputLimit)
    #expect(data.count <= ProbeReportParser.maximumReportSize)
    let probe = DiscoveryProbe(runner: CappingRunner(output: data), baseEnvironment: [:])
    let result = try await probe.discover(HostConfig(displayName: "This Mac", mode: .local))
    #expect(result.status.kind == "ok", "\(result.status.kind)")
    #expect(result.status.sessions.count == ProbeReportParser.maximumSessionCount)
    #expect(result.status.sessions.allSatisfy { $0.startDirectory?.utf8.count == 4096 })
    #expect(result.report?.droppedStartDirectoryCount == 0)
    let over = DiscoveryProbe(
      runner: CappingRunner(
        output: Data(repeating: 0x0A, count: ProbeReportParser.maximumReportSize + 1)),
      baseEnvironment: [:])
    #expect(
      try await over.discover(HostConfig(displayName: "This Mac", mode: .local)).status
        == .probeError("The discovery report is too large."))
  } // End of func theOutputBudgetHoldsTheLargestAcceptedReport()
}

/// A runner that answers every request with canned stdout, kept up to the request's
/// `outputLimit` the way `PosixSpawnProcessRunner` keeps it (the rest cut, and the cut flagged).
struct CappingRunner: ProcessRunner {
  /// Everything the probe "printed".
  let output: Data

  /// The canned run, exit status 0.
  func run(_ request: ProcessRequest) async throws -> ProcessResult {
    ProcessResult(
      processID: 1, termination: .exited(0),
      standardOutput: output.prefix(request.outputLimit),
      standardOutputTruncated: output.count > request.outputLimit)
  }
}

/// The start folders in the refresh engine's snapshots (PLAN.md D20, D31).
@Suite("Refresh snapshots: session start folders")
struct StartFolderSnapshotTests {
  /// Shorthand.
  typealias Support = RefreshTestSupport

  /// A live snapshot carries each session's folder; after a failure the stale snapshot keeps
  /// the last success's sessions with their folders; the next success replaces them.
  @Test func aStaleSnapshotKeepsItsLastFolders() async {
    let host = Support.sshHost("host-a")
    let prober = ScriptedProber()
    var first = Support.session(on: host, id: "$1", name: "first")
    first.startDirectory = "~/projects/site"
    let second = Support.session(on: host, id: "$2", name: "second")
    prober.setAnswer(.ok([first, second]), for: host.id)
    let coordinator = Support.coordinator([host], prober: prober, clock: GatedAttachClock())
    let live = await coordinator.refreshOnce().snapshot(of: host.id)
    #expect(live?.isLive == true)
    #expect(live?.sessions.map(\.discovered.startDirectory) == ["~/projects/site", nil])

    prober.setAnswer(.unreachable(.timeout), for: host.id)
    let stale = await coordinator.refreshOnce().snapshot(of: host.id)
    #expect(stale?.freshness == .stale)
    #expect(stale?.sessions.map(\.discovered.startDirectory) == ["~/projects/site", nil])

    var moved = first
    moved.startDirectory = "/Users/example/elsewhere"
    prober.setAnswer(.ok([moved]), for: host.id)
    let again = await coordinator.refreshOnce().snapshot(of: host.id)
    #expect(again?.sessions.map(\.discovered.startDirectory) == ["/Users/example/elsewhere"])
    await coordinator.stop()
  } // End of func aStaleSnapshotKeepsItsLastFolders()
}

/// The start folders against a real tmux, kept hermetic like `DiscoveryEndToEndTests`: a private
/// `TMUX_TMPDIR`, `-f /dev/null`, only `muxfinder-test-*` sessions running `sleep 60`, never the
/// user's server; the `-c` values are synthetic and never created as folders (tmux stores a
/// `-c` value as given). Skipped when no tmux is installed.
@Suite("Discovery end to end: session start folders (private tmux server)")
struct SessionPathEndToEndTests {
  /// Shorthand.
  typealias E2E = DiscoveryEndToEndTests

  /// Sessions with plain and hostile start folders: discovery keeps the plain ones exactly,
  /// drops the hostile ones (a forged session and status lines after a line break, a tab and an
  /// escape sequence, an empty one) and lists exactly the sessions created.
  @Test(.enabled(if: E2E.tmuxPath != nil), .timeLimit(.minutes(1)))
  func reportsStartFoldersOnAPrivateServer() async throws {
    let tmux = try #require(E2E.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = E2E.tmuxEnvironment(directory)
    let probe = DiscoveryProbe(runner: TestSupport.fastRunner, baseEnvironment: environment)
    let host = HostConfig(displayName: "This Mac", mode: .local)
    let forged =
      "/x\nsession\tffffffffffffffff\t$99\t1\t1\t0\t1\t1\t1\t/x\tforged\nsessions-exit\t0"
    // (name suffix, value given to -c, folder discovery must report)
    let cases: [(String, String, String?)] = [
      ("plain", "/Users/example/projects/site", "/Users/example/projects/site"),
      ("home", "~/projects/site", "~/projects/site"),
      ("unicode", "/Users/example/ünïcödé 日本 ##1 a;b", "/Users/example/ünïcödé 日本 #1 a;b"),
      ("forged", forged, nil),
      ("escape", "/Users/example/tab\there\u{1B}[31m", nil),
      ("empty", "", nil),
    ]
    var created: [(id: String, expected: String?)] = []
    do {
      for (suffix, value, expected) in cases {
        let id = try await E2E.runTmux(
          tmux,
          [
            "-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{session_id}",
            "-s", E2E.sessionPrefix + "path-" + suffix, "-c", value, "sleep", "60",
          ],
          environment: environment)
        created.append((id.trimmingCharacters(in: .whitespacesAndNewlines), expected))
      } // End of loop over test sessions
      let result = try await probe.discover(host)
      let found = Dictionary(
        uniqueKeysWithValues: result.status.sessions.map { ($0.key.sessionID.rawValue, $0) })
      #expect(found.count == created.count, "\(result.status)")
      for (id, expected) in created {
        #expect(found[id]?.startDirectory == expected, "\(id)")
      }
      #expect(found["$99"] == nil)
      #expect(result.report?.droppedStartDirectoryCount == 3)
    } catch {
      await E2E.cleanUp(created.map(\.id), tmux: tmux, environment: environment)
      throw error
    }
    await E2E.cleanUp(created.map(\.id), tmux: tmux, environment: environment)
  } // End of func reportsStartFoldersOnAPrivateServer()

  /// tmux bounds the path itself: a folder of exactly 4,096 bytes comes through whole, and one
  /// over it (4,097 ASCII bytes; 8,001 bytes of two-byte characters, fewer than 4,096
  /// characters) is printed as nothing, so its record is empty in the raw report, no part of it
  /// reaches the output, and discovery drops and counts it instead of keeping a cut folder.
  @Test(.enabled(if: E2E.tmuxPath != nil), .timeLimit(.minutes(1)))
  func printsNothingForAFolderOverTheLimit() async throws {
    let tmux = try #require(E2E.tmuxPath)
    let directory = try TestSupport.makeShortTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = E2E.tmuxEnvironment(directory)
    let longest = "/" + String(repeating: "x", count: 4095)
    let cases: [(String, String)] = [
      ("longest", longest),
      ("over", "/" + String(repeating: "y", count: 4096)),
      ("wide", "/" + String(repeating: "é", count: 4000)),
    ]
    #expect(cases.map(\.1.utf8.count) == [4096, 4097, 8001])
    var created: [String] = []
    do {
      for (suffix, value) in cases {
        let id = try await E2E.runTmux(
          tmux,
          [
            "-f", "/dev/null", "new-session", "-d", "-P", "-F", "#{session_id}",
            "-s", E2E.sessionPrefix + "path-" + suffix, "-c", value, "sleep", "60",
          ],
          environment: environment)
        created.append(id.trimmingCharacters(in: .whitespacesAndNewlines))
      } // End of loop over test sessions
      let probe = DiscoveryProbe(runner: TestSupport.fastRunner, baseEnvironment: environment)
      let host = HostConfig(displayName: "This Mac", mode: .local)
      let run = try await TestSupport.fastRunner.run(try probe.request(for: host))
      let raw = String(decoding: run.standardOutput, as: UTF8.self)
      let nonce = try #require(
        raw.split(separator: "\n").first { $0.hasPrefix("nonce\t") }?.dropFirst(6))
      // Booleans, so a failure names the record instead of printing the whole report.
      let record = { (id: String, path: String) in
        raw.contains("path\t\(nonce)\t\(id)\t\(path)\t\(nonce)\n")
      }
      let kept = record(created[0], longest)
      let emptied = [record(created[1], ""), record(created[2], "")]
      let leaked = raw.contains("yy") || raw.contains("é")
      #expect(kept, "the 4,096-byte folder's record")
      #expect(emptied == [true, true], "the empty records of the folders over the limit")
      #expect(!leaked, "part of a folder over the limit in the report")
      let classification = ErrorClassifier.classify(run, transport: .local, hostID: host.id)
      let sessions = classification.status.sessions
      #expect(
        Set(sessions.map(\.key.sessionID.rawValue)) == Set(created),
        "\(classification.status.kind)")
      let folders = Dictionary(
        uniqueKeysWithValues: sessions.compactMap { session in
          session.startDirectory.map { (session.key.sessionID.rawValue, $0) }
        })
      #expect(folders == [created[0]: longest])
      #expect(classification.report?.droppedStartDirectoryCount == 2)
    } catch {
      await E2E.cleanUp(created, tmux: tmux, environment: environment)
      throw error
    }
    await E2E.cleanUp(created, tmux: tmux, environment: environment)
  } // End of func printsNothingForAFolderOverTheLimit()
}
