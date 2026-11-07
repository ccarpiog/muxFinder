import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The expansion bounds (PLAN.md D39, I-13b1): the archive check that reads the zip's
/// directory and local headers before `ditto` runs (a zip like the real one, `._` entries
/// included, passes; highly compressible or over-declared zips, malformed or inconsistent
/// structures, ZIP64, unsupported entries and unsafe names are refused with `ditto` never
/// started), and the watchdog that stops `ditto` when what it writes passes the bounds (a zip
/// whose directory understates its sizes, and a stand-in for `ditto` that writes past the
/// budget). Zips are built with `ditto -c -k` in private folders and patched; nothing is left
/// in the staging folder after a refusal.
@Suite("Update archive bounds")
struct UpdateArchiveTests {
  /// Shorthand.
  typealias Support = UpdateVerifyTestSupport

  /// The release version of the stub zips.
  static let expected = UpdateVersion("0.3.0")!

  /// The app in `source`.
  static func app(_ source: URL) -> URL {
    source.appending(path: "muxFinder.app", directoryHint: .isDirectory)
  }

  /// Bounds with every value generous except those given.
  static func limits(
    entries: Int = 20_000, bytes: Int = 1 << 30, entryBytes: Int = 1 << 30,
    ratio: Int = 1_000_000, depth: Int = 40
  ) -> UpdateArchiveLimits {
    UpdateArchiveLimits(
      maximumEntries: entries, maximumBytes: bytes, maximumEntryBytes: entryBytes,
      maximumRatio: ratio, ratioFloor: 1 << 20, maximumDepth: depth)
  }

  /// Writes `data` as a zip in a new private folder and returns its path and the folder.
  static func write(_ data: Data) throws -> (path: String, folder: URL) {
    let folder = try UpdateTestSupport.makePrivateFolder()
    let zip = folder.appending(path: "release.zip")
    try data.write(to: zip)
    return (zip.path(percentEncoded: false), folder)
  }

  /// Verifies `data` (a zip) in a new staging folder with a passing fake code checker,
  /// `runner` and `limits`; returns the report and the staging folder's names afterwards.
  static func verify(
    _ data: Data, runner: any ProcessRunner = PosixSpawnProcessRunner(),
    limits: UpdateArchiveLimits = .standard
  ) async throws -> (UpdateVerificationReport, [String]) {
    let (path, source) = try write(data)
    defer { try? FileManager.default.removeItem(at: source) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2", processRunner: runner,
      codeChecker: FakeUpdateCodeChecker(.passed), archiveLimits: limits
    ).verifyLocalZip(atPath: path, sha256: Support.sha256(data), expectedVersion: Self.expected)
    return (report, try Support.names(folder))
  } // End of static func verify(_:runner:limits:)

  /// The archive check of `data` alone.
  static func check(_ data: Data, limits: UpdateArchiveLimits = .standard) throws -> Result<
    UpdateArchiveCheck.Summary, UpdateArchiveProblem
  > {
    let (path, folder) = try write(data)
    defer { try? FileManager.default.removeItem(at: folder) }
    return UpdateArchiveCheck.check(zipAtPath: path, limits: limits)
  }

  /// The problem in `result`, or `nil` when it passed.
  static func problem(_ result: Result<UpdateArchiveCheck.Summary, UpdateArchiveProblem>)
    -> UpdateArchiveProblem?
  {
    if case .failure(let problem) = result { return problem }
    return nil
  }

  /// A zip of a stub app with extended attributes on a file and two folders (so `ditto -c -k`
  /// writes `._` entries, as in the real zip) and a link inside.
  static func realLikeZip() async throws -> (data: Data, url: URL, folder: URL) {
    try await Support.makeZip { source in
      let app = Self.app(source)
      try Support.makeApp(at: app)
      try Support.setAttribute("cc.carpio.muxfinder.test", on: app.appending(path: "Contents"))
      try Support.setAttribute(
        "cc.carpio.muxfinder.test", on: app.appending(path: "Contents/Info.plist"))
      try Support.setAttribute(
        "cc.carpio.muxfinder.test", on: app.appending(path: "Contents/MacOS"))
      try FileManager.default.createSymbolicLink(
        atPath: app.appending(path: "Contents/Current").path(percentEncoded: false),
        withDestinationPath: "MacOS")
    }
  } // End of static func realLikeZip()

  /// A zip like the real one, with `._` entries, passes the archive check and every step; the
  /// `._` entries become extended attributes and no `._` file is left.
  @Test func realLikeZipPasses() async throws {
    let zip = try await Self.realLikeZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let layout = try ZipLayout(zip.data)
    #expect(layout.names.contains("muxFinder.app/Contents/._Info.plist"))
    #expect(layout.names.contains("muxFinder.app/._Contents"))
    let summary = try #require(try? Self.check(zip.data).get())
    #expect(summary.entries == layout.entries.count)
    #expect(summary.declaredBytes == layout.entries.reduce(0) { $0 + $1.uncompressed })

    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed)
    ).verifyLocalZip(
      atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
      expectedVersion: Self.expected)
    #expect(report.steps.allSatisfy { $0.verdict == .passed })
    let app = folder.appending(path: "extracted/muxFinder.app", directoryHint: .isDirectory)
    #expect(
      try Support.names(app.appending(path: "Contents")) == [
        "Current", "Info.plist", "MacOS", "Resources",
      ])
    #expect(
      Support.hasAttribute(
        "cc.carpio.muxfinder.test", on: app.appending(path: "Contents/Info.plist")))
  } // End of func realLikeZipPasses()

  /// A highly compressible zip is refused before `ditto` runs: a 16 MiB run of zeros is over
  /// the standard ratio, and with other bounds over the total, the per-entry size or the
  /// entry count; an entry whose declared size was raised to 300 MiB is over the per-entry
  /// size. Nothing is left and `ditto` is never started.
  @Test func compressibleZipIsRefusedBeforeDitto() async throws {
    let zip = try await Support.makeZip { source in
      try Support.makeApp(at: Self.app(source))
      try Support.makeSparseFile(
        at: Self.app(source).appending(path: "Contents/Resources/zeros"), size: 16 << 20)
    }
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let cases: [(UpdateArchiveLimits, UpdateArchiveProblem)] = [
      (.standard, .ratioTooHigh),
      (Self.limits(bytes: 8 << 20), .tooLarge),
      (Self.limits(entryBytes: 4 << 20), .entryTooLarge),
      (Self.limits(entries: 3), .tooManyEntries),
    ]
    for (limits, problem) in cases {
      let runner = CountingProcessRunner()
      let (report, names) = try await Self.verify(zip.data, runner: runner, limits: limits)
      #expect(report.failure == .extraction(.archive(problem)), "\(problem)")
      #expect(report.verdict(of: .digest) == .passed, "\(problem)")
      #expect(report.verdict(of: .shape) == .notRun, "\(problem)")
      #expect(runner.runs == 0, "\(problem)")
      #expect(names.isEmpty, "\(problem)")
      #expect(report.cleanedUp, "\(problem)")
    } // End of loop over the bounds
    #expect(UpdateArchiveProblem.ratioTooHigh.reason == "the download would be too large unpacked")

    let small = try await Self.realLikeZip()
    defer { try? FileManager.default.removeItem(at: small.folder) }
    var layout = try ZipLayout(small.data)
    try layout.declare(size: 300 << 20, for: "muxFinder.app/Contents/Info.plist")
    let runner = CountingProcessRunner()
    let (raised, names) = try await Self.verify(layout.data, runner: runner)
    #expect(raised.failure == .extraction(.archive(.entryTooLarge)))
    #expect(runner.runs == 0)
    #expect(names.isEmpty)
  } // End of func compressibleZipIsRefusedBeforeDitto()

  /// A zip whose directory (and data descriptor) declare a small size for an entry that
  /// unpacks to 64 MiB passes the archive check, and the watchdog stops the extraction: the
  /// extraction fails with `expansionExceeded` and nothing is left.
  @Test func lyingDirectoryIsStoppedDuringExtraction() async throws {
    let zip = try await Support.makeZip { source in
      try Support.makeApp(at: Self.app(source))
      try Support.makeSparseFile(
        at: Self.app(source).appending(path: "Contents/Resources/zeros"), size: 64 << 20)
    }
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    var layout = try ZipLayout(zip.data)
    let entry = try layout.entry("muxFinder.app/Contents/Resources/zeros")
    try layout.declare(size: UInt32(entry.compressed * 2), for: entry.name)
    let limits = Self.limits(bytes: 4 << 20)
    let checked = try Self.check(layout.data, limits: limits)
    #expect(Self.problem(checked) == nil)
    #expect((try? checked.get().declaredBytes) ?? 0 < 4 << 20)

    let runner = CountingProcessRunner()
    let (report, names) = try await Self.verify(layout.data, runner: runner, limits: limits)
    #expect(report.failure == .extraction(.expansionExceeded))
    #expect(report.failure?.reason == "the download would be too large unpacked")
    #expect(report.verdict(of: .shape) == .notRun)
    #expect(runner.runs == 1)
    #expect(names.isEmpty)
    #expect(report.cleanedUp)
  } // End of func lyingDirectoryIsStoppedDuringExtraction()

  /// The watchdog stops a run that writes past the byte budget, and one that writes more
  /// entries than the bound, while it runs (the stand-in waits until it is cancelled); nothing
  /// is left.
  @Test func watchdogStopsARunWritingPastTheBounds() async throws {
    let zip = try await Support.makeZip { source in try Support.makeApp(at: Self.app(source)) }
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let entries = try #require(try? Self.check(zip.data).get()).entries
    let cases: [(WritingProcessRunner, UpdateArchiveLimits)] = [
      (WritingProcessRunner(files: 1, bytes: 2 << 20), Self.limits(bytes: 1 << 20)),
      (WritingProcessRunner(files: entries + 20, bytes: 1), Self.limits(entries: entries + 5)),
    ]
    for (runner, limits) in cases {
      let started = ContinuousClock.now
      let (report, names) = try await Self.verify(zip.data, runner: runner, limits: limits)
      #expect(report.failure == .extraction(.expansionExceeded))
      #expect(runner.wasCancelled)
      #expect(ContinuousClock.now - started < .seconds(10))
      #expect(names.isEmpty)
    } // End of loop over the runs
  } // End of func watchdogStopsARunWritingPastTheBounds()

  /// Malformed or inconsistent structures are refused before `ditto` runs.
  @Test func malformedArchivesAreRefused() async throws {
    let zip = try await Self.realLikeZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let original = try ZipLayout(zip.data)
    let first = try original.entry("muxFinder.app/Contents/Info.plist")
    try #require(ZipLayout.u16(original.bytes, first.record + 30) >= 4)
    let directoryOffset = Int(ZipLayout.u32(original.bytes, original.end + 16))
    var cases: [(String, Data, UpdateArchiveProblem)] = []

    cases.append(("truncated", zip.data.dropLast(), .malformed))
    var count = original
    count.set16(UInt16(original.entries.count + 1), at: original.end + 8)
    count.set16(UInt16(original.entries.count + 1), at: original.end + 10)
    cases.append(("entry count too high", count.data, .malformed))
    var offset = original
    offset.set32(UInt32(directoryOffset - 1), at: original.end + 16)
    cases.append(("directory offset off", offset.data, .malformed))
    var local = original
    try local.rename(
      first.name, to: first.name.replacingOccurrences(of: "Info", with: "Evil"), localOnly: true)
    cases.append(("local name differs", local.data, .malformed))
    var gap = original
    gap.bytes.insert(contentsOf: [0x50, 0x4B, 0x03, 0x04], at: directoryOffset)
    gap.set32(UInt32(directoryOffset + 4), at: gap.bytes.count - 22 + 16)
    cases.append(("bytes no entry lists", gap.data, .malformed))
    var size = original
    size.set32(UInt32(first.compressed + 1), at: first.record + 20)
    cases.append(("packed size differs", size.data, .malformed))
    var zip64 = original
    zip64.set16(0xFFFF, at: original.end + 10)
    cases.append(("ZIP64 end record", zip64.data, .zip64))
    var zip64Extra = original
    zip64Extra.set16(0x0001, at: first.record + 46 + first.name.utf8.count)
    cases.append(("ZIP64 extra field", zip64Extra.data, .zip64))
    var encrypted = original
    try encrypted.set(flags: first.flags | 0x0001, for: first.name)
    cases.append(("encrypted", encrypted.data, .unsupportedEntry))
    var method = original
    try method.set(method: 12, for: first.name)
    cases.append(("bzip2", method.data, .unsupportedEntry))
    var fifo = original
    fifo.set32(UInt32(S_IFIFO | 0o644) << 16, at: first.record + 38)
    cases.append(("a FIFO", fifo.data, .unsupportedEntry))
    var comment = original.bytes + Array("hello".utf8)
    comment[original.end + 20] = 4
    cases.append(("comment length wrong", Data(comment), .malformed))
    cases.append(
      ("empty", Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18)), .empty))

    for (name, data, problem) in cases {
      #expect(Self.problem(try Self.check(data)) == problem, "\(name)")
      let runner = CountingProcessRunner()
      let (report, names) = try await Self.verify(data, runner: runner)
      #expect(report.failure == .extraction(.archive(problem)), "\(name)")
      #expect(runner.runs == 0, "\(name)")
      #expect(names.isEmpty, "\(name)")
    } // End of loop over the malformed archives

    // A comment of the right length is fine.
    var commented = original.bytes + Array("hello".utf8)
    commented[original.end + 20] = 5
    #expect(Self.problem(try Self.check(Data(commented))) == nil)
  } // End of func malformedArchivesAreRefused()

  /// Unsafe names, duplicates and entries below a link are refused before `ditto` runs.
  @Test func unsafeNamesAreRefused() async throws {
    let zip = try await Support.makeZip { source in
      let app = Self.app(source)
      try Support.makeApp(at: app)
      try Data("a".utf8).write(to: app.appending(path: "Contents/Resources/a1.txt"))
      try Data("b".utf8).write(to: app.appending(path: "Contents/Resources/a2.txt"))
      try FileManager.default.createDirectory(
        at: app.appending(path: "Contents/M", directoryHint: .isDirectory),
        withIntermediateDirectories: false)
      try Data("x".utf8).write(to: app.appending(path: "Contents/M/x.txt"))
      try FileManager.default.createSymbolicLink(
        atPath: app.appending(path: "Contents/L").path(percentEncoded: false),
        withDestinationPath: "Resources")
    }
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let original = try ZipLayout(zip.data)
    #expect(Self.problem(try Self.check(zip.data)) == nil)
    let note = "muxFinder.app/Contents/Resources/note.txt"
    let renames: [(String, String, UpdateArchiveProblem)] = [
      (note, "muxFinder.app/Contents/Resources/../n.txt", .unsafeName),
      (note, "/uxFinder.app/Contents/Resources/note.txt", .unsafeName),
      (note, "muxFinder.app/Contents/Resources/./note.t", .unsafeName),
      (note, "muxFinder.app/Contents/Resources//note.tx", .unsafeName),
      (note, "muxFinder.app/Contents/Resources/note\\txt", .unsafeName),
      (note, "muxFinder.apq/Contents/Resources/note.txt", .outsideApp),
      (note, "__MACOSX/Abcd/Contents/Resources/note.txt", .outsideApp),
      (
        "muxFinder.app/Contents/Resources/a2.txt", "muxFinder.app/Contents/Resources/A1.txt",
        .duplicateName
      ),
      ("muxFinder.app/Contents/M/x.txt", "muxFinder.app/Contents/L/x.txt", .belowLink),
    ]
    for (old, new, problem) in renames {
      var layout = original
      try layout.rename(old, to: new)
      #expect(Self.problem(try Self.check(layout.data)) == problem, "\(new)")
      let runner = CountingProcessRunner()
      let (report, names) = try await Self.verify(layout.data, runner: runner)
      #expect(report.failure == .extraction(.archive(problem)), "\(new)")
      #expect(runner.runs == 0, "\(new)")
      #expect(names.isEmpty, "\(new)")
    } // End of loop over the renames
    #expect(UpdateArchiveProblem.belowLink.reason == "the download contains an unsafe file name")
  } // End of func unsafeNamesAreRefused()

  /// The name rules on their own: components and the top level.
  @Test func nameRules() throws {
    let limits = UpdateArchiveLimits.standard
    let components = { (name: String) -> [String]? in
      try? UpdateArchiveCheck.nameComponents(Array(name.utf8), limits: limits)
    }
    #expect(components("muxFinder.app/") == ["muxFinder.app"])
    #expect(
      components("muxFinder.app/Contents/Info.plist") == [
        "muxFinder.app", "Contents", "Info.plist",
      ])
    #expect(components("muxFinder.app/Contents/Resources/é.png")?.count == 4)
    for bad in [
      "", "/", "/muxFinder.app", "muxFinder.app//x", "muxFinder.app/./x", "muxFinder.app/../x",
      "..", "muxFinder.app/x\\y", "muxFinder.app/x\u{0}", String(repeating: "a/", count: 41) + "a",
      String(repeating: "a", count: 1025),
    ] {
      #expect(components(bad) == nil, "\(bad.prefix(40))")
    } // End of loop over unsafe names
    #expect((try? UpdateArchiveCheck.nameComponents([0x61, 0xFF], limits: limits)) == nil)
    let topLevel = { (components: [String]) in
      (try? UpdateArchiveCheck.checkTopLevel(components)) != nil
    }
    #expect(topLevel(["muxFinder.app"]))
    #expect(topLevel(["muxFinder.app", "Contents"]))
    #expect(topLevel(["._muxFinder.app"]))
    #expect(topLevel(["__MACOSX"]))
    #expect(topLevel(["__MACOSX", "muxFinder.app", "._Contents"]))
    #expect(topLevel(["__MACOSX", "._muxFinder.app"]))
    #expect(!topLevel(["._muxFinder.app", "x"]))
    #expect(!topLevel(["__MACOSX", "._muxFinder.app", "x"]))
    #expect(!topLevel(["__MACOSX", "Other.app"]))
    #expect(!topLevel(["MuxFinder.app"]))
    #expect(!topLevel(["Other.app", "Contents"]))
    #expect(UpdateArchiveLimits.standard.maximumEntries == 20_000)
    #expect(UpdateArchiveLimits.standard.maximumBytes == 256 << 20)
    #expect(UpdateArchiveLimits.standard.maximumEntryBytes == 128 << 20)
    #expect(UpdateArchiveLimits.standard.maximumRatio == 100)
    #expect(UpdateArchiveLimits.standard.ratioFloor == 1 << 20)
    #expect(UpdateExtractor.watchInterval == .milliseconds(50))
  } // End of func nameRules()
}
