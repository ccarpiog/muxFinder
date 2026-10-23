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

  /// A synthetic GUID of muxFinder's generator.
  static let muxFinderGUID = "muxfinder-persistent-00000000-0000-4000-8000-000000000001"
  /// Another one.
  static let otherGUID = "muxfinder-persistent-00000000-0000-4000-8000-000000000002"
  /// The file iTerm2 names in its copy of a profile from muxFinder's file (a synthetic folder).
  static let muxFinderFile = "/nonexistent/DynamicProfiles/muxFinder.json"
  /// Another dynamic profile file in that folder.
  static let otherFile = "/nonexistent/DynamicProfiles/other.json"
  /// The rule `profiles hashes` uses for that folder: no written profile known, so the GUID
  /// format and the exact path alone.
  static let generalRule = ITerm2ProfileSnapshotter.MirrorRule(ownedFilePath: muxFinderFile)

  /// An exported domain whose `New Bookmarks` holds `entries`, as XML (what `defaults export`
  /// prints).
  static func export(bookmarks entries: [Any]) throws -> Data {
    try PropertyListSerialization.data(
      fromPropertyList: ["New Bookmarks": entries, "Default Bookmark Guid": "guid-1"],
      format: .xml, options: 0)
  }

  /// `New Bookmarks` entries for the general exclusion rule (`generalRule`, no written profile
  /// known), each with whether it is left out as iTerm2's copy of a muxFinder profile: only a
  /// well-formed generated `Guid` (the prefix and a lowercase UUID, nothing more) together with
  /// a `Dynamic Profile Filename` that is, standardized, exactly the owned file's path is.
  static func ruleCases() -> [(label: String, entry: Any, excluded: Bool)] {
    let file = ITerm2ProfileSnapshotter.dynamicProfileFilenameKey
    let guid = muxFinderGUID
    return [
      ("the user's profile", ["Name": "Default", "Guid": "guid-1", "Columns": 80], false),
      ("GUID only", ["Name": "Prefix only", "Guid": guid], false),
      (
        "copy of a muxFinder profile",
        ["Name": "Persistent work \u{2013} Test", "Guid": guid, file: muxFinderFile], true
      ),
      ("copy of another muxFinder profile", ["Guid": otherGUID, file: muxFinderFile], true),
      (
        "copy naming the file by a path that standardizes to it",
        ["Guid": guid, file: "/nonexistent//DynamicProfiles/./x/../muxFinder.json"], true
      ),
      ("file name only", ["Name": "File only", "Guid": "guid-3", file: muxFinderFile], false),
      ("another dynamic profile", ["Guid": "other-dynamic-1", file: otherFile], false),
      ("look-alike GUID", ["Guid": "muxfinder-persistent-custom", file: muxFinderFile], false),
      (
        "GUID with an uppercase UUID",
        ["Guid": "muxfinder-persistent-00000000-0000-4000-8000-00000000000A", file: muxFinderFile],
        false
      ),
      ("GUID with a suffix", ["Guid": guid + "0", file: muxFinderFile], false),
      ("GUID prefix in capitals", ["Guid": guid.uppercased(), file: muxFinderFile], false),
      (
        "GUID, another folder's muxFinder.json", ["Guid": guid, file: "/other/muxFinder.json"],
        false
      ),
      ("GUID, another file", ["Guid": guid, file: otherFile], false),
      ("GUID, a bare file name", ["Guid": guid, file: "muxFinder.json"], false),
      ("GUID, a relative path", ["Guid": guid, file: String(muxFinderFile.dropFirst())], false),
      ("GUID, look-alike file", ["Guid": guid, file: muxFinderFile + ".bak"], false),
      ("GUID, file in a folder", ["Guid": guid, file: muxFinderFile + "/x"], false),
      ("GUID, a trailing slash", ["Guid": guid, file: muxFinderFile + "/"], false),
      ("GUID, a trailing dot", ["Guid": guid, file: muxFinderFile + "/."], false),
      (
        "GUID, the folder's parent",
        ["Guid": guid, file: "/nonexistent/DynamicProfiles/../muxFinder.json"], false
      ),
      ("GUID not a string", ["Guid": 7, file: muxFinderFile], false),
      ("file name not a string", ["Guid": guid, file: ["muxFinder.json"]], false),
      ("not a dictionary", guid, false),
    ]
  } // End of func ruleCases()

  /// The number of `ruleCases()` left out.
  static let excludedRuleCases = 3

  /// Only what the general rule proves to be iTerm2's copies of muxFinder's own profiles is
  /// left out of the `New Bookmarks` hash and counted; every other entry (a muxFinder GUID or a
  /// `muxFinder.json` file name alone, another dynamic profile's copy, a look-alike GUID such
  /// as `muxfinder-persistent-custom`, another folder's or a relative `muxFinder.json`) is
  /// hashed in its order, so the fingerprint equals that of the export without the copies.
  /// Without a rule, or with an unusable owned path, nothing is left out.
  @Test func excludesOnlyMuxFinderMirrors() throws {
    let cases = Self.ruleCases()
    for (label, entry, excluded) in cases {
      #expect(Self.generalRule.matches(entry) == excluded, "\(label)")
    }
    let kept = cases.filter { !$0.excluded }.map(\.entry)
    let exported = try Self.export(bookmarks: cases.map(\.entry))
    let all = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(fromExport: exported, leavingOut: Self.generalRule))
    let without = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(
        fromExport: Self.export(bookmarks: kept), leavingOut: Self.generalRule))
    #expect(all.excludedMuxFinderEntries == Self.excludedRuleCases)
    #expect(all.count == cases.count - Self.excludedRuleCases)
    #expect(all.sha256 == without.sha256)
    #expect(without.excludedMuxFinderEntries == 0 && without.count == kept.count)
    // A kept look-alike is hashed: dropping it changes the fingerprint.
    let fewer = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(
        fromExport: Self.export(bookmarks: kept.dropLast()), leavingOut: Self.generalRule))
    #expect(fewer.sha256 != without.sha256)
    // No rule, or a rule whose owned path is not absolute: every entry is hashed.
    let unruled = try #require(try ITerm2ProfileSnapshotter.bookmarks(fromExport: exported))
    let relative = ITerm2ProfileSnapshotter.MirrorRule(
      ownedFilePath: "DynamicProfiles/muxFinder.json")
    #expect(relative.ownedFilePath == nil)
    let unusable = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(fromExport: exported, leavingOut: relative))
    for fingerprint in [unruled, unusable] {
      #expect(fingerprint.excludedMuxFinderEntries == 0 && fingerprint.count == cases.count)
    }
  } // End of func excludesOnlyMuxFinderMirrors()

  /// The profile the e2e harness writes for the host with id `…0001`, and its parsed form.
  static func writtenProfile() throws -> (
    profile: [String: Any], written: [ITerm2ProfileSnapshotter.WrittenProfile]
  ) {
    let host = HostConfig(
      id: try #require(UUID(uuidString: "00000000-0000-4000-8000-000000000001")),
      displayName: "Test", mode: .local, persistentProfileEnabled: true)
    let document = try PersistentProfiles.document(
      for: try HostList([host]), helperPath: PersistentProfilesTests.helper)
    let root = try #require(try JSONSerialization.jsonObject(with: document.data) as? [String: Any])
    let profile = try #require((root["Profiles"] as? [[String: Any]])?.first)
    let written = try #require(
      ITerm2ProfileSnapshotter.WrittenProfile.profiles(inDocument: document.data))
    return (profile, written)
  } // End of func writtenProfile()

  /// With the profiles the caller wrote (the e2e harness), only iTerm2's copy of one of them is
  /// left out: its exact GUID, the owned file's path, and every key it was written with holding
  /// an equal value after the round trip through `defaults export`; the keys iTerm2 fills in
  /// are not compared. A copy whose written key changed or went, whose boolean became an
  /// integer, another generated GUID, a look-alike GUID or another folder's file is hashed.
  @Test func writtenProfilesLeaveOutOnlyTheirUnchangedCopies() throws {
    let (profile, written) = try Self.writtenProfile()
    #expect(written.map(\.guid) == [Self.muxFinderGUID])
    #expect(
      Set(written[0].values.keys) == [
        "Guid", "Name", "Tags", "Custom Command", "Command", "Close Sessions On End",
      ])
    let rule = ITerm2ProfileSnapshotter.MirrorRule(
      ownedFilePath: Self.muxFinderFile, written: written)
    var copy = profile
    copy[ITerm2ProfileSnapshotter.dynamicProfileFilenameKey] = Self.muxFinderFile
    copy["Columns"] = 80
    copy["Rows"] = 25
    /// Whether `entry`, exported beside a user's profile, is left out.
    func leftOut(_ entry: [String: Any]) throws -> Bool {
      let user: [String: Any] = ["Name": "Default", "Guid": "guid-1"]
      let fingerprint = try #require(
        try ITerm2ProfileSnapshotter.bookmarks(
          fromExport: Self.export(bookmarks: [user, entry]), leavingOut: rule))
      #expect(fingerprint.count + fingerprint.excludedMuxFinderEntries == 2)
      return fingerprint.excludedMuxFinderEntries == 1
    }
    #expect(try leftOut(copy))
    #expect(rule.matches(copy))
    let changes: [(String, (inout [String: Any]) -> Void)] = [
      ("changed Command", { $0["Command"] = "/bin/zsh" }),
      ("changed Name", { $0["Name"] = "Default" }),
      ("Tags gone", { $0["Tags"] = nil }),
      ("Tags changed", { $0["Tags"] = ["muxFinder", "x"] }),
      ("boolean as an integer", { $0["Close Sessions On End"] = 1 }),
      ("another generated GUID", { $0["Guid"] = Self.otherGUID }),
      ("look-alike GUID", { $0["Guid"] = "muxfinder-persistent-custom" }),
      (
        "another folder's file",
        { $0[ITerm2ProfileSnapshotter.dynamicProfileFilenameKey] = "/other/muxFinder.json" }
      ),
      ("no file key", { $0[ITerm2ProfileSnapshotter.dynamicProfileFilenameKey] = nil }),
    ]
    for (label, change) in changes {
      var changed = copy
      change(&changed)
      #expect(try !leftOut(changed), "\(label)")
    }
    // A document that is not a profile list gives no written profiles.
    for bad in [
      #"{"Profiles": [{"Name": "x"}]}"#, #"{"Profiles": [{"Guid": "g", "x": null}]}"#, "[]",
    ] {
      #expect(ITerm2ProfileSnapshotter.WrittenProfile.profiles(inDocument: Data(bad.utf8)) == nil)
    }
  } // End of func writtenProfilesLeaveOutOnlyTheirUnchangedCopies()

  /// `profiles hashes` prints the snapshot as sorted JSON: `newBookmarks` holds `count` (the
  /// hashed entries), `sha256` and `excludedMuxFinderEntries`, and nothing of any entry (no
  /// GUID, name or file name), the copies left out included.
  @Test func jsonCountsTheExcludedCopies() throws {
    let cases = Self.ruleCases()
    let bookmarks = try #require(
      try ITerm2ProfileSnapshotter.bookmarks(
        fromExport: Self.export(bookmarks: cases.map(\.entry)), leavingOut: Self.generalRule))
    let snapshot = ITerm2ProfileSnapshot(
      dynamicProfilesDirectory: "/tmp/x", directoryExists: true, excludedFileName: "muxFinder.json",
      entries: [], newBookmarks: bookmarks)
    #expect(snapshot.excludedMuxFinderEntries == Self.excludedRuleCases)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    let data = try encoder.encode(snapshot)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    let fingerprint = try #require(root["newBookmarks"] as? [String: Any])
    #expect(Set(fingerprint.keys) == ["count", "sha256", "excludedMuxFinderEntries"])
    #expect(fingerprint["count"] as? Int == cases.count - Self.excludedRuleCases)
    #expect(fingerprint["excludedMuxFinderEntries"] as? Int == Self.excludedRuleCases)
    #expect(fingerprint["sha256"] as? String == bookmarks.sha256)
    let json = String(decoding: data, as: UTF8.self)
    for text in ["muxfinder-persistent", "MUXFINDER", "/nonexistent", "Persistent work", "guid-"] {
      #expect(!json.contains(text), "\(text)")
    }
    #expect(!json.contains("Default") && !json.contains("other-dynamic"))
  } // End of func jsonCountsTheExcludedCopies()

  /// Snapshots whose `New Bookmarks` hash the same entries match whatever number of copies
  /// each left out (they are not equal, which keeps that number visible); a change to a hashed
  /// entry, or `New Bookmarks` appearing, is named.
  @Test func comparisonIgnoresTheExcludedCopies() throws {
    let file = ITerm2ProfileSnapshotter.dynamicProfileFilenameKey
    let user: [Any] = [
      ["Name": "Default", "Guid": "guid-1"], ["Name": "Second", "Guid": "guid-2"],
    ]
    let copy: [String: Any] = [
      "Name": "Persistent work", "Guid": Self.muxFinderGUID, file: Self.muxFinderFile,
    ]
    /// The snapshot of an export holding `entries`.
    func snapshot(_ entries: [Any]?) throws -> ITerm2ProfileSnapshot {
      ITerm2ProfileSnapshot(
        dynamicProfilesDirectory: "/x", directoryExists: true, excludedFileName: "muxFinder.json",
        entries: [],
        newBookmarks: try entries.flatMap {
          try ITerm2ProfileSnapshotter.bookmarks(
            fromExport: Self.export(bookmarks: $0), leavingOut: Self.generalRule)
        })
    }
    let before = try snapshot(user)
    let installed = try snapshot([user[0], copy, user[1]])
    #expect(installed.excludedMuxFinderEntries == 1 && before.excludedMuxFinderEntries == 0)
    #expect(installed.hashesMatch(before) && before.hashesMatch(installed))
    #expect(installed.differences(from: before).isEmpty)
    #expect(installed != before)
    let renamed = try snapshot([["Name": "Renamed", "Guid": "guid-1"], copy, user[1]])
    #expect(!renamed.hashesMatch(before))
    #expect(renamed.differences(from: before) == ["New Bookmarks"])
    #expect(try snapshot(nil).differences(from: before) == ["New Bookmarks"])
  } // End of func comparisonIgnoresTheExcludedCopies()

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
    #expect(request.timeout == ITerm2ProfileSnapshotter.exportTimeout)
    // A caller with a budget bounds the export by what is left of it.
    _ = try await snapshotter.snapshot(.init(exportTimeout: .milliseconds(1500)))
    #expect(defaults.requests.withLock { $0.last?.timeout } == .milliseconds(1500))

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

  /// The snapshotter's owned file is `<its folder>/muxFinder.json`: a copy naming it is left
  /// out, one naming another folder's `muxFinder.json` is hashed; with the profiles written
  /// (the harness), only an unchanged copy of those is left out.
  @Test func snapshotLeavesOutCopiesOfItsOwnFileOnly() async throws {
    let fixture = try PersistentProfileInstallerTests.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let file = ITerm2ProfileSnapshotter.dynamicProfileFilenameKey
    let (profile, written) = try Self.writtenProfile()
    let snapshotter = ITerm2ProfileSnapshotter(
      directory: fixture.directory, runner: FakeDefaults(output: ""), environment: [:])
    let owned = fixture.directory.appending(path: "muxFinder.json").path(percentEncoded: false)
    #expect(snapshotter.ownedFilePath == owned)
    var copy = profile
    copy[file] = owned
    copy["Columns"] = 80
    var elsewhere = copy
    elsewhere[file] = "/elsewhere/DynamicProfiles/muxFinder.json"
    var changed = copy
    changed["Command"] = "/bin/zsh"
    let export = try Self.export(bookmarks: [
      ["Name": "Default", "Guid": "guid-1"], copy, elsewhere,
    ])
    let defaults = FakeDefaults(output: String(decoding: export, as: UTF8.self))
    var reading = snapshotter
    reading.runner = defaults
    let general = try await reading.snapshot()
    #expect(general.excludedMuxFinderEntries == 1 && general.newBookmarks?.count == 2)
    let exact = try await reading.snapshot(.init(written: written))
    #expect(exact.excludedMuxFinderEntries == 1 && exact.newBookmarks?.count == 2)
    let changedExport = try Self.export(bookmarks: [
      ["Name": "Default", "Guid": "guid-1"], changed,
    ])
    defaults.answer(with: String(decoding: changedExport, as: UTF8.self))
    #expect(try await reading.snapshot().excludedMuxFinderEntries == 1)
    let strict = try await reading.snapshot(.init(written: written))
    #expect(strict.excludedMuxFinderEntries == 0 && strict.newBookmarks?.count == 2)
  } // End of func snapshotLeavesOutCopiesOfItsOwnFileOnly()

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
