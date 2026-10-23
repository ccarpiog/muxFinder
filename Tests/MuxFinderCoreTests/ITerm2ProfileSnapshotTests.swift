import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The read-only hash snapshot of iTerm2's other profiles (PLAN.md D26): the `DynamicProfiles`
/// entries other than `muxFinder.json` and `New Bookmarks` from `defaults export`, over a
/// private folder and a fake `defaults` (no real `defaults` and no real iTerm2 folder).
@Suite("iTerm2 profile snapshot")
struct ITerm2ProfileSnapshotTests {
  /// A `ProcessRunner` that records its requests and answers with canned output.
  final class FakeDefaults: ProcessRunner {
    /// The canned answer.
    let answer: OSAllocatedUnfairLock<ProcessResult>
    /// The requests so far.
    let requests = OSAllocatedUnfairLock<[ProcessRequest]>(initialState: [])

    /// Answers every run with `output` and exit status `status`.
    init(output: String, status: Int32 = 0) {
      answer = OSAllocatedUnfairLock(
        initialState: ProcessResult(
          processID: 55, termination: .exited(status), standardOutput: Data(output.utf8)))
    }

    /// Changes the answer's output.
    func answer(with output: String) {
      answer.withLock { $0.standardOutput = Data(output.utf8) }
    }

    /// Records `request` and returns the canned answer.
    func run(_ request: ProcessRequest) async throws -> ProcessResult {
      requests.withLock { $0.append(request) }
      return answer.withLock { $0 }
    }
  } // End of class FakeDefaults

  /// An exported domain whose `New Bookmarks` holds two synthetic profiles, keys written in
  /// `order` (`forward` or reversed), with every property list type.
  static func export(reversed: Bool = false, name: String = "Default") -> String {
    let first = [
      "<key>Name</key><string>\(name)</string>",
      "<key>Guid</key><string>guid-1</string>",
      "<key>Columns</key><integer>80</integer>",
      "<key>Transparency</key><real>0.25</real>",
      "<key>Blink</key><true/>",
      "<key>Tags</key><array><string>a</string><string>b</string></array>",
      "<key>Data</key><data>AAEC</data>",
      "<key>Date</key><date>2026-10-23T00:00:00Z</date>",
    ]
    let keys = reversed ? first.reversed() : first
    let other =
      reversed
      ? "<dict><key>Name</key><string>Second</string><key>Guid</key><string>guid-2</string></dict>"
      : "<dict><key>Guid</key><string>guid-2</string><key>Name</key><string>Second</string></dict>"
    let domain = [
      "<key>New Bookmarks</key><array><dict>\(keys.joined())</dict>\(other)</array>",
      "<key>Default Bookmark Guid</key><string>guid-1</string>",
    ]
    return """
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0"><dict>\((reversed ? domain.reversed() : domain).joined())</dict></plist>
      """
  } // End of func export(reversed:name:)

  /// The snapshot lists every other entry with its kind and digest (file bytes, link text),
  /// never `muxFinder.json`; runs exactly `/usr/bin/defaults export com.googlecode.iterm2 -`;
  /// counts `New Bookmarks`; and is unchanged by installing and removing muxFinder's file.
  @Test func snapshotsTheFolderAndBookmarks() async throws {
    let fixture = try PersistentProfileInstallerTests.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let defaults = FakeDefaults(output: Self.export())
    let snapshotter = ITerm2ProfileSnapshotter(
      directory: fixture.directory, runner: defaults, environment: ["PATH": "/usr/bin:/bin"])
    let before = try await snapshotter.snapshot()
    #expect(before.directoryExists)
    #expect(before.excludedFileName == "muxFinder.json")
    #expect(
      before.entries.map(\.name) == [
        ".hidden", "dangling.json", "folder", "linked.json", "mine.json", "other.plist",
      ])
    #expect(
      before.entries.map(\.kind) == [
        .file, .symbolicLink, .directory, .symbolicLink, .file, .file,
      ])
    #expect(before.entries[0].sha256 == ITerm2ProfileSnapshotter.digest(Data("hidden".utf8)))
    #expect(
      before.entries[1].sha256
        == ITerm2ProfileSnapshotter.digest(Data("/nonexistent/muxfinder-test".utf8)))
    #expect(before.entries[2].sha256 == nil)
    #expect(before.newBookmarks?.count == 2)
    let request = try #require(defaults.requests.withLock { $0.first })
    #expect(request.executableURL.path(percentEncoded: false) == "/usr/bin/defaults")
    #expect(request.arguments == ["export", "com.googlecode.iterm2", "-"])
    #expect(request.timeout != nil)

    try fixture.installer.install(try PersistentProfileInstallerTests.document())
    let installed = try await snapshotter.snapshot()
    #expect(installed == before)
    try fixture.installer.remove()
    #expect(try await snapshotter.snapshot() == before)

    // A changed sibling or bookmark shows up, by name only.
    try Data("changed".utf8).write(to: fixture.directory.appending(path: "mine.json"))
    defaults.answer(with: Self.export(name: "Renamed"))
    let changed = try await snapshotter.snapshot()
    #expect(changed != before)
    #expect(changed.differences(from: before) == ["mine.json", "New Bookmarks"])
  } // End of func snapshotsTheFolderAndBookmarks()

  /// The bookmarks digest does not depend on the order `defaults` printed keys in, and the
  /// snapshot's JSON holds no profile name or GUID.
  @Test func bookmarksDigestIsCanonical() throws {
    let forward = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(fromExport: Data(Self.export().utf8)))
    let reversed = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(fromExport: Data(Self.export(reversed: true).utf8)))
    #expect(forward == reversed)
    let renamed = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(fromExport: Data(Self.export(name: "Other").utf8)))
    #expect(renamed.sha256 != forward.sha256)
    let snapshot = ITerm2ProfileSnapshot(
      dynamicProfilesDirectory: "/tmp/x", directoryExists: true, excludedFileName: "muxFinder.json",
      entries: [], newBookmarks: forward)
    let json = String(decoding: try JSONEncoder().encode(snapshot), as: UTF8.self)
    #expect(!json.contains("Default") && !json.contains("guid-1") && !json.contains("Second"))
  } // End of func bookmarksDigestIsCanonical()

  /// Booleans, integers and reals of equal value are told apart; a domain without `New
  /// Bookmarks` gives none; output that is not a property list, or a `New Bookmarks` that is
  /// not an array, is an error.
  @Test func canonicalFormAndBadOutput() throws {
    #expect(CanonicalPropertyList.encode([true]) != CanonicalPropertyList.encode([1]))
    #expect(CanonicalPropertyList.encode([1]) != CanonicalPropertyList.encode([1.0]))
    #expect(
      CanonicalPropertyList.encode(["a": "b", "c": "d"])
        == CanonicalPropertyList.encode(["c": "d", "a": "b"]))
    #expect(
      CanonicalPropertyList.encode(["ab", "c"]) != CanonicalPropertyList.encode(["a", "bc"]))
    #expect(CanonicalPropertyList.encode([NSNull()]) == nil)
    let empty = #"<plist version="1.0"><dict><key>X</key><integer>1</integer></dict></plist>"#
    #expect(try ITerm2ProfileSnapshotter.bookmarks(fromExport: Data(empty.utf8)) == nil)
    #expect(throws: ITerm2ProfileSnapshotError.defaultsOutputUnreadable) {
      try ITerm2ProfileSnapshotter.bookmarks(fromExport: Data("not a plist".utf8))
    }
    let notArray =
      #"<plist version="1.0"><dict><key>New Bookmarks</key><string>x</string></dict></plist>"#
    #expect(throws: ITerm2ProfileSnapshotError.bookmarksUnreadable) {
      try ITerm2ProfileSnapshotter.bookmarks(fromExport: Data(notArray.utf8))
    }
  } // End of func canonicalFormAndBadOutput()

  /// A failing `defaults` is an error, and a missing folder is reported as missing.
  @Test func defaultsFailureAndMissingFolder() async throws {
    let base = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let missing = base.appending(path: "DynamicProfiles")
    let failing = ITerm2ProfileSnapshotter(
      directory: missing, runner: FakeDefaults(output: "", status: 1), environment: [:])
    await #expect(throws: ITerm2ProfileSnapshotError.defaultsFailed(status: 1)) {
      try await failing.snapshot()
    }
    let snapshot = try await ITerm2ProfileSnapshotter(
      directory: missing, runner: FakeDefaults(output: Self.export()), environment: [:]
    ).snapshot()
    #expect(!snapshot.directoryExists)
    #expect(snapshot.entries.isEmpty)
    #expect(!LaunchTestSupport.exists(missing))
  } // End of func defaultsFailureAndMissingFolder()
}
