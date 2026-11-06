import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The plain launch's early report (PLAN.md D14, D38) in the launch store: written atomically
/// 0600, peeked (never taken), removed with its result, by the sweep or explicitly; anything
/// malformed, oversized or unsafe a typed failure, never a report. Also the kernel start time
/// it carries and the terminal path rule.
@Suite("Plain launch report")
struct PlainLaunchReportTests {
  /// A well-formed report for `id`.
  static func report(
    id: LaunchToken = LaunchToken(),
    terminalPath: String? = PlainLaunchTestSupport.terminalPath
  ) -> PlainLaunchReport {
    PlainLaunchReport(
      id: id, helperPID: 4321, terminalPath: terminalPath, attachChildPID: 777,
      attachChildStartTime: PlainLaunchTestSupport.startTime)
  }

  /// The report file's URL in `store`.
  static func url(of id: LaunchToken, in store: LaunchStore) -> URL {
    store.directory.appending(path: LaunchStore.reportFileName(for: id))
  }

  /// Writes `text` as `id`'s report file with `mode`.
  static func writeRaw(_ text: String, id: LaunchToken, in store: LaunchStore, mode: Int = 0o600)
    throws
  {
    let url = Self.url(of: id, in: store)
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: mode], ofItemAtPath: url.path(percentEncoded: false))
  }

  /// Written and peeked: the same report, 0600, a regular file, the name `<id>.report.json`,
  /// no temporary file left; peeking twice leaves it; `removeReport` removes it once.
  @Test func writesAndPeeks() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let report = Self.report()
    #expect(LaunchStore.reportFileName(for: report.id) == "\(report.id.rawValue).report.json")
    try store.writeReport(report)
    #expect(try LaunchTestSupport.permissions(of: Self.url(of: report.id, in: store)) == 0o600)
    #expect(try LaunchTestSupport.names(in: store.directory) == ["\(report.id).report.json"])
    #expect(try store.peekReport(report.id) == report)
    #expect(try store.peekReport(report.id) == report)
    #expect(try store.removeReport(report.id))
    #expect(try !store.removeReport(report.id))
    #expect(try store.peekReport(report.id) == nil)
    let none = Self.report(terminalPath: nil)
    try store.writeReport(none)
    #expect(try store.peekReport(none.id)?.terminalPath == nil)
  } // End of func writesAndPeeks()

  /// The write is atomic: a temporary file renamed into place, so a symbolic link planted at
  /// the name is replaced (its target untouched) and an earlier report is replaced whole.
  @Test func writesAtomically() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let target = root.appending(path: "target")
    try Data("keep".utf8).write(to: target)
    let report = Self.report()
    try FileManager.default.createSymbolicLink(
      at: Self.url(of: report.id, in: store), withDestinationURL: target)
    try store.writeReport(report)
    #expect(try Data(contentsOf: target) == Data("keep".utf8))
    #expect(
      try LaunchTestSupport.status(of: Self.url(of: report.id, in: store)).st_mode & S_IFMT
        == S_IFREG)
    var second = report
    second.attachChildPID = 778
    try store.writeReport(second)
    #expect(try store.peekReport(report.id) == second)
    #expect(try LaunchTestSupport.names(in: store.directory) == ["\(report.id).report.json"])
  } // End of func writesAtomically()

  /// The write refuses a report that is not well formed, and never creates the directory.
  @Test func refusesToWriteUnusableReports() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    var bad = Self.report()
    bad.helperPID = 0
    #expect(throws: LaunchStoreError.fileMalformed) { try store.writeReport(bad) }
    bad = Self.report(terminalPath: "ttys004")
    #expect(throws: LaunchStoreError.fileMalformed) { try store.writeReport(bad) }
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)
    let missing = LaunchStore(directory: root.appending(path: "absent"))
    #expect(throws: LaunchStoreError.directoryMissing) { try missing.writeReport(Self.report()) }
    #expect(!LaunchTestSupport.exists(root.appending(path: "absent")))
    #expect(try missing.peekReport(LaunchToken()) == nil)
    #expect(try !missing.removeReport(LaunchToken()))
  } // End of func refusesToWriteUnusableReports()

  /// A report that does not decode, is for another id, or holds unusable values is
  /// `fileMalformed`; one over 16 KiB `fileUnsafe(.tooLarge)`; one readable by others
  /// `fileUnsafe(.permissionsTooOpen)`; a symbolic link `fileUnsafe(.symbolicLink)`. A peek
  /// never deletes any of them.
  @Test func malformedOrUnsafeReportsAreTypedFailures() throws {
    let (store, root) = try LaunchTestSupport.makeStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = LaunchToken()
    let good = String(
      decoding: try LaunchCoding.encoder().encode(Self.report(id: id)), as: UTF8.self)
    let other = String(
      decoding: try LaunchCoding.encoder().encode(Self.report()), as: UTF8.self)
    let malformed = [
      "", "{", "[]", "null", other,
      good.replacingOccurrences(of: #""schemaVersion":1"#, with: #""schemaVersion":2"#),
      good.replacingOccurrences(of: #""helperPID":4321"#, with: #""helperPID":-1"#),
      good.replacingOccurrences(of: #""attachChildPID":777"#, with: #""attachChildPID":0"#),
      good.replacingOccurrences(of: "/dev/ttys042", with: "/tmp/ttys042"),
      good.replacingOccurrences(of: "/dev/ttys042", with: "/dev/tty s042"),
      good.replacingOccurrences(of: #""microseconds":123456"#, with: #""microseconds":1000000"#),
      good.replacingOccurrences(of: #""seconds":1792600002"#, with: #""seconds":-5"#),
      good.replacingOccurrences(of: #""attachChildPID":777,"#, with: ""),
      good.replacingOccurrences(of: #""helperPID":4321"#, with: #""helperPID":"4321""#),
    ]
    for text in malformed {
      #expect(text != good)
      try Self.writeRaw(text, id: id, in: store)
      #expect(throws: LaunchStoreError.fileMalformed, "\(text)") { try store.peekReport(id) }
      #expect(LaunchTestSupport.exists(Self.url(of: id, in: store)))
    } // End of loop over the malformed reports
    try Self.writeRaw(good + String(repeating: " ", count: 16 * 1024), id: id, in: store)
    #expect(throws: LaunchStoreError.fileUnsafe(.tooLarge)) { try store.peekReport(id) }
    try Self.writeRaw(good, id: id, in: store, mode: 0o640)
    #expect(throws: LaunchStoreError.fileUnsafe(.permissionsTooOpen)) {
      try store.peekReport(id)
    }
    try FileManager.default.removeItem(at: Self.url(of: id, in: store))
    try FileManager.default.createSymbolicLink(
      at: Self.url(of: id, in: store), withDestinationURL: root.appending(path: "nowhere"))
    #expect(throws: LaunchStoreError.fileUnsafe(.symbolicLink)) { try store.peekReport(id) }
    #expect(LaunchTestSupport.exists(Self.url(of: id, in: store)))
    try FileManager.default.removeItem(at: Self.url(of: id, in: store))
    try Self.writeRaw(good, id: id, in: store)
    #expect(try store.peekReport(id) == Self.report(id: id))
  } // End of func malformedOrUnsafeReportsAreTypedFailures()

  /// The report goes with its result when `takeResult` takes that (not before: a look with no
  /// result leaves it), and the sweep removes an old one like any launch file.
  @Test func removedWithItsResultAndByTheSweep() throws {
    let start = LaunchTestSupport.requestTime
    let (store, root) = try LaunchTestSupport.makeStore(now: start)
    defer { try? FileManager.default.removeItem(at: root) }
    let report = Self.report()
    try store.writeReport(report)
    #expect(try store.takeResult(report.id) == nil)
    #expect(try store.peekResult(report.id) == nil)
    #expect(try store.peekReport(report.id) == report)
    try store.writeResult(
      LaunchResult(
        id: report.id, helperPID: 4321, startedAt: start, childStartedAt: start, endedAt: start,
        childTermination: .exited(0), failure: nil))
    #expect(try store.peekResult(report.id)?.succeeded == true)
    #expect(try store.peekReport(report.id) == report)
    #expect(try store.takeResult(report.id)?.succeeded == true)
    #expect(try store.peekReport(report.id) == nil)
    #expect(try LaunchTestSupport.names(in: store.directory).isEmpty)

    #expect(LaunchStore.isManagedFileName("\(report.id).report.json"))
    let old = Self.report()
    let fresh = Self.report()
    try store.writeReport(old)
    try store.writeReport(fresh)
    let past = Date(timeIntervalSinceNow: -3600)
    try FileManager.default.setAttributes(
      [.modificationDate: past],
      ofItemAtPath: Self.url(of: old.id, in: store).path(percentEncoded: false))
    let sweeper = LaunchStore(directory: store.directory, now: { Date() })
    #expect(try sweeper.sweep() == 1)
    #expect(try store.peekReport(old.id) == nil)
    #expect(try store.peekReport(fresh.id) == fresh)
  } // End of func removedWithItsResultAndByTheSweep()

  /// The kernel start time of a live process (this one, a child) is read and plausible, and a
  /// reaped child's or an impossible pid's is none; terminal paths follow the `/dev/` rule.
  @Test func startTimesAndTerminalPaths() async throws {
    let own = try #require(ProcessStartTime.of(getpid()))
    #expect(own.isValid && Double(own.seconds) <= Date().timeIntervalSince1970 + 1)
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/bin/sleep")
    child.arguments = ["5"]
    let before = Date().timeIntervalSince1970
    try child.run()
    let started = try #require(ProcessStartTime.of(child.processIdentifier))
    let seconds = Double(started.seconds) + Double(started.microseconds) / 1_000_000
    #expect(seconds >= before - 1 && seconds <= Date().timeIntervalSince1970 + 1)
    #expect(ProcessStartTime.of(child.processIdentifier) == started)
    child.terminate()
    child.waitUntilExit()
    #expect(ProcessStartTime.of(child.processIdentifier) == nil)
    #expect(ProcessStartTime.of(0) == nil && ProcessStartTime.of(-1) == nil)

    for good in ["/dev/ttys004", "/dev/pts/3", "/dev/console"] {
      #expect(PlainLaunchReport.isValidTerminalPath(good), "\(good)")
    }
    for bad in [
      "", "/dev/", "ttys004", "/tmp/ttys004", "/dev/tty s4", "/dev/ttys\u{7}", "/dev/tty日",
    ] {
      #expect(!PlainLaunchReport.isValidTerminalPath(bad), "\(bad)")
    }
    #expect(
      !PlainLaunchReport.isValidTerminalPath(
        "/dev/" + String(repeating: "x", count: PlainLaunchReport.maximumTerminalPathLength)))
    var master: Int32 = -1
    var slave: Int32 = -1
    #expect(openpty(&master, &slave, nil, nil, nil) == 0)
    defer {
      close(master)
      close(slave)
    }
    let path = try #require(PlainLaunchFacts.terminalPath(of: slave))
    #expect(path.hasPrefix("/dev/ttys"))
    var name = [CChar](repeating: 0, count: 128)
    #expect(ttyname_r(slave, &name, name.count) == 0)
    #expect(
      path == String(decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    )
  } // End of func startTimesAndTerminalPaths()
} // End of struct PlainLaunchReportTests
