import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// Tests for `DirectoryLists` and `DirectoryStore` (PLAN.md D31). Every test uses its own
/// temporary folder, never the real Application Support folder; directories and host ids are
/// synthetic.
@Suite("Directory store")
struct DirectoryStoreTests {
  /// The fixed clock used to date backups: 2026-10-22 15:30:12 UTC.
  static let backupDate = Date(timeIntervalSince1970: 1_792_683_012)
  /// The backup name a write made at `backupDate` uses first.
  static let backupName = "directories.backup-20261022T153012Z.json"
  /// Two synthetic hosts.
  static let hostA = UUID(uuidString: "11111111-1111-4111-8111-111111111111")!
  /// The second synthetic host.
  static let hostB = UUID(uuidString: "22222222-2222-4222-8222-222222222222")!
  /// What a store's folder holds after a write: the file and the lock file, sorted.
  static let storeFiles = [DirectoryStore.fileName, DirectoryStore.lockFileName].sorted()

  /// A store at `<base>/muxFinder/directories.json` in a fresh private base directory.
  struct Fixture {
    /// The store.
    let store: DirectoryStore
    /// The private base directory (the caller removes it).
    let base: URL
    /// The store's folder (not created).
    let directory: URL
    /// The store's file.
    let file: URL
  }

  /// Creates a fixture; `beforePublishing` runs inside each write just before publication.
  static func makeFixture(beforePublishing: (@Sendable () -> Void)? = nil) throws -> Fixture {
    let base = try TestSupport.makeTemporaryDirectory()
    let directory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    let file = directory.appending(path: DirectoryStore.fileName)
    let store = DirectoryStore(
      fileURL: file, owner: geteuid(), now: { backupDate }, beforePublishing: beforePublishing)
    return Fixture(store: store, base: base, directory: directory, file: file)
  }

  /// Creates the fixture's folder (0700).
  static func createDirectory(_ fixture: Fixture) throws {
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
  }

  /// Writes `text` as the fixture's file, mode 0600, creating the folder.
  static func writeFile(_ text: String, in fixture: Fixture) throws {
    try writeFile(Data(text.utf8), in: fixture)
  }

  /// Writes `data` as the fixture's file, mode 0600, creating the folder.
  static func writeFile(_ data: Data, in fixture: Fixture) throws {
    if !LaunchTestSupport.exists(fixture.directory) { try createDirectory(fixture) }
    try HostStoreTests.writeFile(data, to: fixture.file)
  }

  /// A schema 1 document with `saved` and `recent` (JSON values written as given).
  static func document(saved: String = "[]", recent: String = "{}", extra: String = "") -> String {
    "{\(extra)\"schemaVersion\": 1, \"saved\": \(saved), \"recent\": \(recent)}\n"
  }

  /// The file's JSON object.
  static func object(at url: URL) throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  // MARK: - Loading

  /// No folder, or a folder without the file, gives empty lists as `notSavedYet`, and nothing
  /// is created.
  @Test func missingFileGivesEmptyLists() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let none = try await fixture.store.load()
    #expect(none == DirectoryStoreLoadResult(lists: DirectoryLists(), state: .notSavedYet))
    #expect(none.notice == nil)
    #expect(!LaunchTestSupport.exists(fixture.directory))
    try Self.createDirectory(fixture)
    #expect(try await fixture.store.load().state == .notSavedYet)
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
  }

  /// Files that cannot be used give empty lists and a notice naming the problem (never a
  /// directory), and stay exactly as they are; loading writes nothing.
  @Test func unusableFilesGiveEmptyListsAndStayAsTheyAre() async throws {
    let big = Data(repeating: 0x20, count: DirectoryStore.maximumFileSize + 1)
    let cases: [(String, Data, mode_t, DirectoryFileProblem)] = [
      ("not JSON", Data("{\"saved\": [".utf8), 0o600, .notJSON),
      ("an array", Data("[\"~/x\"]".utf8), 0o600, .malformed),
      ("no version", Data("{\"saved\": [\"~/x\"]}".utf8), 0o600, .malformed),
      ("string version", Data("{\"schemaVersion\": \"1\"}".utf8), 0o600, .malformed),
      ("saved not an array", Data(Self.document(saved: "\"~/x\"").utf8), 0o600, .malformed),
      ("recent not an object", Data(Self.document(recent: "[]").utf8), 0o600, .malformed),
      (
        "newer", Data("{\"schemaVersion\": 2, \"saved\": [\"~/x\"]}".utf8), 0o600,
        .newerSchemaVersion(2)
      ),
      ("zero", Data("{\"schemaVersion\": 0}".utf8), 0o600, .unsupportedSchemaVersion(0)),
      (
        "open permissions", Data(Self.document(saved: "[\"~/x\"]").utf8), 0o644,
        .unsafe(.permissionsTooOpen)
      ),
      ("too large", big, 0o600, .unsafe(.tooLarge)),
    ]
    for (label, data, mode, problem) in cases {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Self.createDirectory(fixture)
      try HostStoreTests.writeFile(data, to: fixture.file, mode: mode)
      let before = try HostStoreTests.snapshot(of: fixture.directory)
      let loaded = try await fixture.store.load()
      #expect(loaded.state == .invalid(problem), "\(label)")
      #expect(loaded.lists.isEmpty, "\(label)")
      #expect(loaded.notice == .fileNotUsed(problem), "\(label)")
      #expect(loaded.notice?.message.contains("~/x") == false, "\(label)")
      #expect(try HostStoreTests.snapshot(of: fixture.directory) == before, "\(label)")
    } // End of loop over unusable files
  } // End of func unusableFilesGiveEmptyListsAndStayAsTheyAre()

  /// A symbolic link at the name is never followed, a folder there is not a file, and a file
  /// with an ACL is not trusted; each stays as it is.
  @Test func unsafeEntriesAreNotTrusted() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let target = fixture.base.appending(path: "target.json")
    try HostStoreTests.writeFile(Data(Self.document(saved: "[\"~/x\"]").utf8), to: target)
    try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
    #expect(try await fixture.store.load().state == .invalid(.unsafe(.symbolicLink)))
    try FileManager.default.removeItem(at: fixture.file)

    try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
    #expect(try await fixture.store.load().state == .invalid(.unsafe(.notARegularFile)))
    try FileManager.default.removeItem(at: fixture.file)

    try Self.writeFile(Self.document(saved: "[\"~/x\"]"), in: fixture)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: fixture.file)
    let before = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(try await fixture.store.load().state == .invalid(.unsafe(.extendedACL)))
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == before)
  } // End of func unsafeEntriesAreNotTrusted()

  /// A folder that is a symbolic link or not a folder is refused by loads and changes alike,
  /// and nothing is written through it.
  @Test func refusesUnusableFolders() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let target = fixture.base.appending(path: "target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: target)
    await #expect(throws: DirectoryStoreError.directoryIsSymbolicLink) {
      try await fixture.store.load()
    }
    await #expect(throws: DirectoryStoreError.directoryIsSymbolicLink) {
      try await fixture.store.apply(.addSaved("~/x"), knownHosts: nil)
    }
    #expect(try LaunchTestSupport.names(in: target).isEmpty)
    try FileManager.default.removeItem(at: fixture.directory)
    try Data("x".utf8).write(to: fixture.directory)
    await #expect(throws: DirectoryStoreError.directoryNotADirectory) {
      try await fixture.store.apply(.addSaved("~/x"), knownHosts: nil)
    }
  } // End of func refusesUnusableFolders()

  /// Unknown keys (top level and anywhere else) are ignored.
  @Test func ignoresUnknownKeys() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.writeFile(
      Self.document(
        saved: "[\"~/projects/site\"]", recent: "{\"\(Self.hostA.uuidString)\": [\"~/a\"]}",
        extra: "\"pinned\": {\"x\": 1}, \"futureField\": [true], "),
      in: fixture)
    let loaded = try await fixture.store.load()
    #expect(loaded.state == .saved)
    #expect(loaded.notice == nil)
    #expect(loaded.lists.saved == ["~/projects/site"])
    #expect(loaded.lists.recent(for: Self.hostA) == ["~/a"])
  } // End of func ignoresUnknownKeys()

  /// Entries that break a rule are left out and counted: not a string, empty, NUL, a line
  /// break, too long, a host key that is not a UUID (with its entries), a host value that is
  /// not an array. A duplicate loses nothing and is not counted. Loading writes nothing.
  @Test func dropsAndCountsInvalidEntries() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let long = "\"/" + String(repeating: "x", count: DirectoryLists.maximumEntryLength) + "\""
    let saved =
      "[\"~/ok\", \"\", \"a\\nb\", 42, \"x\\u0000y\", \"r\\rs\", \(long), \"~/ok\", null, "
      + "\"tab\\there\"]"
    let recent =
      "{\"\(Self.hostA.uuidString)\": [\"~/a\", 7, \"b\\nc\"], \"not-a-uuid\": [\"~/x\", \"~/y\"], "
      + "\"\(Self.hostB.uuidString)\": \"not an array\"}"
    try Self.writeFile(Self.document(saved: saved, recent: recent), in: fixture)
    let before = try HostStoreTests.snapshot(of: fixture.directory)
    let loaded = try await fixture.store.load()
    #expect(loaded.state == .saved)
    #expect(loaded.lists.saved == ["~/ok", "tab\there"])
    #expect(loaded.lists.recent == [Self.hostA: ["~/a"]])
    #expect(loaded.droppedEntryCount == 12)
    #expect(loaded.notice == .entriesDropped(12))
    #expect(loaded.notice?.message.hasPrefix("12 saved or recent directories") == true)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == before)
  } // End of func dropsAndCountsInvalidEntries()

  /// At most 50 saved entries and 8 recent ones per host are loaded (the first ones, so the
  /// newest recents); the rest are counted as dropped.
  @Test func enforcesTheCapsOnLoad() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let saved = (1...51).map { "\"~/s\($0)\"" }.joined(separator: ", ")
    let recent = (1...9).map { "\"~/r\($0)\"" }.joined(separator: ", ")
    try Self.writeFile(
      Self.document(saved: "[\(saved)]", recent: "{\"\(Self.hostA.uuidString)\": [\(recent)]}"),
      in: fixture)
    let loaded = try await fixture.store.load()
    #expect(loaded.lists.saved == (1...50).map { "~/s\($0)" })
    #expect(loaded.lists.recent(for: Self.hostA) == (1...8).map { "~/r\($0)" })
    #expect(loaded.droppedEntryCount == 2)
  } // End of func enforcesTheCapsOnLoad()

  /// Duplicates collapse by exact string, keeping the first place: `~/x` and `/Users/…/x` stay
  /// two entries, and so do the composed and decomposed spellings of one accented name.
  @Test func collapsesDuplicatesByExactString() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.writeFile(
      Self.document(
        saved: "[\"~/x\", \"/Users/example/x\", \"~/x\", \"caf\\u00e9\", \"cafe\\u0301\", "
          + "\"/Users/example/x\"]"),
      in: fixture)
    let loaded = try await fixture.store.load()
    #expect(loaded.lists.saved.count == 4)
    #expect(
      loaded.lists.saved.map { Array($0.utf8) } == [
        Array("~/x".utf8), Array("/Users/example/x".utf8), Array("caf\u{E9}".utf8),
        Array("cafe\u{301}".utf8),
      ])
    #expect(loaded.droppedEntryCount == 0)
  } // End of func collapsesDuplicatesByExactString()

  // MARK: - Changes

  /// Changes round-trip through the file; the file is a schema 1 object with sorted keys, host
  /// ids as keys, a final newline; the folder is 0700 and the file 0600, neither with an ACL,
  /// even under a parent with an inheritable ACL; only `directories.json` and the lock file
  /// (0600, empty, no ACL) are in the folder.
  @Test func writesPrivatelyAndRoundTrips() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneInheritedACL, on: fixture.base)
    let store = fixture.store
    _ = try await store.apply(.addSaved("~/projects/site"), knownHosts: nil)
    _ = try await store.apply(
      .recordRecent("/Users/example/a b", hostID: Self.hostA), knownHosts: nil)
    let result = try await store.apply(
      .recordRecent("~/ünïcödé 日本 #1;", hostID: Self.hostA), knownHosts: nil)
    #expect(result.wrote)
    #expect(result.backup == nil && result.displacedFileError == nil)
    #expect(result.lists.recent(for: Self.hostA) == ["~/ünïcödé 日本 #1;", "/Users/example/a b"])

    let loaded = try await DirectoryStore(fileURL: fixture.file).load()
    #expect(loaded == DirectoryStoreLoadResult(lists: result.lists, state: .saved))
    let object = try Self.object(at: fixture.file)
    #expect(Set(object.keys) == ["schemaVersion", "saved", "recent"])
    #expect(object["schemaVersion"] as? Int == 1)
    #expect((object["recent"] as? [String: Any])?.keys.sorted() == [Self.hostA.uuidString])
    let text = try String(contentsOf: fixture.file, encoding: .utf8)
    #expect(text.hasSuffix("}\n"))
    #expect(text.contains("\"~/projects/site\""))
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o700)
    #expect(try LaunchTestSupport.aclEntryCount(of: fixture.directory) == 0)
    #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
    #expect(try LaunchTestSupport.aclEntryCount(of: fixture.file) == 0)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == Self.storeFiles)
    let lock = fixture.directory.appending(path: DirectoryStore.lockFileName)
    #expect(try LaunchTestSupport.permissions(of: lock) == 0o600)
    #expect(try LaunchTestSupport.aclEntryCount(of: lock) == 0)
    #expect(try Data(contentsOf: lock).isEmpty)
  } // End of func writesPrivatelyAndRoundTrips()

  /// A recent directory goes first; recording it again moves it to the front; more than 8 drop
  /// the oldest; each host has its own list.
  @Test func recordsRecentsNewestFirstWithTheCap() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let store = fixture.store
    for number in 1...10 {
      _ = try await store.apply(.recordRecent("~/r\(number)", hostID: Self.hostA), knownHosts: nil)
    }
    _ = try await store.apply(.recordRecent("~/r5", hostID: Self.hostA), knownHosts: nil)
    _ = try await store.apply(.recordRecent("~/other", hostID: Self.hostB), knownHosts: nil)
    let lists = try await store.load().lists
    #expect(
      lists.recent(for: Self.hostA) == [
        "~/r5", "~/r10", "~/r9", "~/r8", "~/r7", "~/r6", "~/r4", "~/r3",
      ])
    #expect(lists.recent(for: Self.hostB) == ["~/other"])
    let cleared = try await store.apply(.clearRecents(hostID: Self.hostA), knownHosts: nil)
    #expect(cleared.lists.recent == [Self.hostB: ["~/other"]])
  } // End of func recordsRecentsNewestFirstWithTheCap()

  /// The saved list: add at the end, add an existing entry (nothing changes, nothing is
  /// written), remove, move, replace (duplicates collapse), and the cap.
  @Test func changesTheSavedList() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let store = fixture.store
    for entry in ["~/a", "~/b", "~/c"] {
      _ = try await store.apply(.addSaved(entry), knownHosts: nil)
    }
    let again = try await store.apply(.addSaved("~/b"), knownHosts: nil)
    #expect(again.lists.saved == ["~/a", "~/b", "~/c"])
    #expect(!again.wrote)
    #expect(
      try await store.apply(.moveSaved(from: 2, to: 0), knownHosts: nil).lists.saved == [
        "~/c", "~/a", "~/b",
      ])
    #expect(
      try await store.apply(.removeSaved("~/a"), knownHosts: nil).lists.saved == ["~/c", "~/b"])
    let replaced = try await store.apply(
      .replaceSaved(["~/z", "/Users/example/y", "~/z"]), knownHosts: nil)
    #expect(replaced.lists.saved == ["~/z", "/Users/example/y"])
    let full = (1...50).map { "~/s\($0)" }
    _ = try await store.apply(.replaceSaved(full), knownHosts: nil)
    await #expect(throws: DirectoryStoreError.invalidChange(.tooManySaved)) {
      try await store.apply(.addSaved("~/one more"), knownHosts: nil)
    }
    await #expect(throws: DirectoryStoreError.invalidChange(.tooManySaved)) {
      try await store.apply(.replaceSaved(full + ["~/one more"]), knownHosts: nil)
    }
    await #expect(throws: DirectoryStoreError.invalidChange(.positionOutOfRange)) {
      try await store.apply(.moveSaved(from: 0, to: 50), knownHosts: nil)
    }
    #expect(try await store.load().lists.saved == full)
  } // End of func changesTheSavedList()

  /// A refused change (an entry that breaks a rule) writes nothing, not even the folder.
  @Test func aRefusedChangeWritesNothing() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let refused: [(DirectoryListChange, DirectoryListError)] = [
      (.recordRecent("", hostID: Self.hostA), .entryEmpty),
      (
        .recordRecent("a\nb", hostID: Self.hostA), .entryInvalid(.workingDirectoryContainsLineBreak)
      ),
      (.addSaved("x\u{0}"), .entryInvalid(.workingDirectoryContainsNullCharacter)),
      (
        .addSaved("/" + String(repeating: "x", count: DirectoryLists.maximumEntryLength)),
        .entryTooLong
      ),
      (.replaceSaved(["~/ok", "a\rb"]), .entryInvalid(.workingDirectoryContainsLineBreak)),
    ]
    for (change, error) in refused {
      await #expect(throws: DirectoryStoreError.invalidChange(error)) {
        try await fixture.store.apply(change, knownHosts: nil)
      }
    }
    #expect(!LaunchTestSupport.exists(fixture.directory))
    try Self.writeFile(Self.document(saved: "[\"~/kept\"]"), in: fixture)
    let before = try HostStoreTests.snapshot(of: fixture.directory)
    await #expect(throws: DirectoryStoreError.self) {
      try await fixture.store.apply(.replaceSaved(["~/new", ""]), knownHosts: nil)
    }
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == before)
  } // End of func aRefusedChangeWritesNothing()

  /// A change that changes nothing writes nothing: no file is created for empty lists, and a
  /// file that already holds the result is not rewritten.
  @Test func aChangeThatChangesNothingWritesNothing() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let cleared = try await fixture.store.apply(.clearRecents(hostID: Self.hostA), knownHosts: [])
    #expect(!cleared.wrote)
    #expect(!LaunchTestSupport.exists(fixture.directory))
    _ = try await fixture.store.apply(.addSaved("~/a"), knownHosts: nil)
    let before = try HostStoreTests.snapshot(of: fixture.directory)
    let removed = try await fixture.store.apply(.removeSaved("~/absent"), knownHosts: nil)
    #expect(!removed.wrote)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == before)
  } // End of func aChangeThatChangesNothingWritesNothing()

  /// The recent directories of hosts not in the host list are forgotten at the next write;
  /// without a host list (`nil`) none are.
  @Test func prunesRemovedHostsAtTheNextWrite() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let removed = UUID()
    try Self.writeFile(
      Self.document(
        recent: "{\"\(Self.hostA.uuidString)\": [\"~/a\"], \"\(Self.hostB.uuidString)\": "
          + "[\"~/b\"], \"\(removed.uuidString)\": [\"~/gone\"]}"),
      in: fixture)
    let kept = try await fixture.store.apply(.addSaved("~/s"), knownHosts: nil)
    #expect(kept.lists.recent.count == 3)
    let pruned = try await fixture.store.apply(
      .recordRecent("~/a2", hostID: Self.hostA), knownHosts: [Self.hostA, Self.hostB])
    #expect(pruned.lists.recent == [Self.hostA: ["~/a2", "~/a"], Self.hostB: ["~/b"]])
    #expect(
      try await fixture.store.load().lists.recent.keys.sorted { $0.uuidString < $1.uuidString } == [
        Self.hostA, Self.hostB,
      ])
  } // End of func prunesRemovedHostsAtTheNextWrite()

  /// A change reads the file first, so what another program wrote since is kept.
  @Test func keepsWhatAnotherProgramWrote() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try await fixture.store.apply(.addSaved("~/mine"), knownHosts: nil)
    try Self.writeFile(Self.document(saved: "[\"~/mine\", \"~/theirs\"]"), in: fixture)
    let result = try await fixture.store.apply(
      .recordRecent("~/r", hostID: Self.hostA), knownHosts: nil)
    #expect(result.lists.saved == ["~/mine", "~/theirs"])
    #expect(result.backup == nil)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == Self.storeFiles)
  }

  /// A usable file with entries left out is replaced at the next change and kept as a backup
  /// with its bytes (0600); the store's own file is not.
  @Test func keepsAFileWithEntriesLeftOutAsABackup() async throws {
    let original = Self.document(saved: "[\"~/ok\", \"a\\nb\"]")
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.writeFile(original, in: fixture)
    let result = try await fixture.store.apply(
      .recordRecent("~/r", hostID: Self.hostA), knownHosts: nil)
    #expect(result.lists.saved == ["~/ok"])
    #expect(result.backup?.lastPathComponent == Self.backupName)
    let backup = fixture.directory.appending(path: Self.backupName)
    #expect(try String(contentsOf: backup, encoding: .utf8) == original)
    #expect(try LaunchTestSupport.permissions(of: backup) == 0o600)
    _ = try await fixture.store.apply(.recordRecent("~/r2", hostID: Self.hostA), knownHosts: nil)
    #expect(
      try LaunchTestSupport.names(in: fixture.directory)
        == (Self.storeFiles + [Self.backupName]).sorted())
  } // End of func keepsAFileWithEntriesLeftOutAsABackup()

  /// Everything about the store's file that a write could change: its bytes, kind and mode,
  /// inode (a publication is a new file) and modification time to the nanosecond.
  struct FileState: Equatable {
    /// The bytes (`nil` for a symbolic link, which is never read).
    var contents: Data?
    /// `st_mode`, kind and permission bits.
    var mode: mode_t
    /// `st_ino`.
    var inode: ino_t
    /// `st_mtimespec`, seconds and nanoseconds.
    var modified: [Int]
  }

  /// The state of the entry at `url`, without following a link.
  static func fileState(_ url: URL) throws -> FileState {
    var info = stat()
    try #require(lstat(url.path(percentEncoded: false), &info) == 0)
    let isFile = info.st_mode & S_IFMT == S_IFREG
    return FileState(
      contents: isFile ? try Data(contentsOf: url) : nil, mode: info.st_mode,
      inode: info.st_ino,
      modified: [Int(info.st_mtimespec.tv_sec), Int(info.st_mtimespec.tv_nsec)])
  }

  /// Every kind of change: recording and clearing a recent, adding, removing, moving,
  /// replacing and merging saved entries, and pruning removed hosts.
  static let everyChange: [(DirectoryListChange, Set<UUID>?)] = [
    (.recordRecent("~/r", hostID: hostA), nil),
    (.recordRecent("~/r", hostID: hostA), [hostA]),
    (.clearRecents(hostID: hostA), nil),
    (.clearRecents(hostID: hostB), []),
    (.addSaved("~/s"), nil),
    (.removeSaved("~/x"), nil),
    (.moveSaved(from: 0, to: 0), nil),
    (.replaceSaved(["~/s"]), nil),
    (.replaceSaved([]), [hostB]),
    (.mergeSaved(base: ["~/x"], edited: ["~/s"]), nil),
  ]

  /// A file that cannot be used (unsafe permissions on valid lists, a newer schema after a
  /// downgrade, invalid JSON, malformed, an ACL, a symbolic link) refuses every change with
  /// `fileNotUsable` and its problem: its bytes, mode, inode and modification time stay as
  /// they are, and nothing is written in the folder (no backup, no temporary file, no lock
  /// file; the folder's own mode, 0750 here, is not tightened).
  @Test func refusesEveryChangeWhileTheFileIsUnusable() async throws {
    let valid = Self.document(
      saved: "[\"~/x\"]", recent: "{\"\(Self.hostA.uuidString)\": [\"~/a\"]}")
    let cases: [(String, String, mode_t, DirectoryFileProblem)] = [
      ("unsafe permissions", valid, 0o644, .unsafe(.permissionsTooOpen)),
      (
        "newer schema", "{\"schemaVersion\": 2, \"saved\": [\"~/x\"]}\n", 0o600,
        .newerSchemaVersion(2)
      ),
      ("invalid JSON", "{\"saved\": [\"~/x\"", 0o600, .notJSON),
      ("malformed", Self.document(recent: "[]"), 0o600, .malformed),
      ("extended ACL", valid, 0o600, .unsafe(.extendedACL)),
      ("symbolic link", valid, 0o600, .unsafe(.symbolicLink)),
    ]
    for (label, text, mode, problem) in cases {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Self.createDirectory(fixture)
      try #require(chmod(fixture.directory.path(percentEncoded: false), 0o750) == 0)
      if problem == .unsafe(.symbolicLink) {
        let target = fixture.base.appending(path: "target.json")
        try HostStoreTests.writeFile(Data(text.utf8), to: target, mode: mode)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
      } else {
        try HostStoreTests.writeFile(Data(text.utf8), to: fixture.file, mode: mode)
      }
      if problem == .unsafe(.extendedACL) {
        try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: fixture.file)
      }
      let before = try Self.fileState(fixture.file)
      let folder = try HostStoreTests.snapshot(of: fixture.directory)
      for (change, knownHosts) in Self.everyChange {
        await #expect(throws: DirectoryStoreError.fileNotUsable(problem), "\(label) \(change)") {
          try await fixture.store.apply(change, knownHosts: knownHosts)
        }
      } // End of loop over changes
      #expect(try Self.fileState(fixture.file) == before, "\(label)")
      #expect(try HostStoreTests.snapshot(of: fixture.directory) == folder, "\(label)")
      #expect(try LaunchTestSupport.names(in: fixture.directory) == [DirectoryStore.fileName])
      #expect(try await fixture.store.load().state == .invalid(problem), "\(label)")
    } // End of loop over unusable files
  } // End of func refusesEveryChangeWhileTheFileIsUnusable()

  /// The refusal's code names the problem, never a directory, so the model logs it as it is;
  /// its message says the file was left as it is.
  @Test func theRefusalNamesOnlyTheProblem() {
    let error = DirectoryStoreError.fileNotUsable(.unsafe(.permissionsTooOpen))
    #expect(error.code == "fileNotUsable.unsafe.permissionsTooOpen")
    #expect(
      DirectoryStoreError.fileNotUsable(.newerSchemaVersion(2)).code
        == "fileNotUsable.newerSchemaVersion")
    #expect(error.errorDescription?.contains("left it as it is") == true)
    #expect(DirectoryStoreError.busy.code == "busy")
    #expect(DirectoryStoreError.lockUnavailable.code == "lockUnavailable")
  } // End of func theRefusalNamesOnlyTheProblem()

  /// Two stores on one file (two muxFinder processes, say) never lose each other's changes:
  /// while the first holds the lock with its lists written but not yet published, the second
  /// store's change is started and given time to finish. It waits for the lock instead, then
  /// reads what the first published and adds its own, so the file ends with both and nothing
  /// is displaced into a backup. (Without the lock it would publish first and the first store's
  /// swap would push its change out into a backup.)
  @Test func twoStoresNeverLoseEachOthersChanges() async throws {
    let base = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appending(path: "muxFinder", directoryHint: .isDirectory)
      .appending(path: DirectoryStore.fileName)
    let second = DirectoryStore(
      fileURL: file, owner: geteuid(), now: { Self.backupDate }, lockWait: .seconds(30))
    let armed = OSAllocatedUnfairLock(initialState: false)
    let started = OSAllocatedUnfairLock<Task<DirectoryStoreChangeResult, any Error>?>(
      initialState: nil)
    let first = DirectoryStore(
      fileURL: file, owner: geteuid(), now: { Self.backupDate },
      beforePublishing: {
        let fires = armed.withLock { value -> Bool in
          let was = value
          value = false
          return was
        }
        guard fires else { return }
        let finished = DispatchSemaphore(value: 0)
        let task = Task {
          defer { finished.signal() }
          return try await second.apply(
            .recordRecent("~/theirs", hostID: Self.hostB), knownHosts: nil)
        }
        started.withLock { $0 = task }
        _ = finished.wait(timeout: .now() + .milliseconds(700))
      })
    _ = try await first.apply(.addSaved("~/seed"), knownHosts: nil)
    armed.withLock { $0 = true }
    let mine = try await first.apply(.recordRecent("~/mine", hostID: Self.hostA), knownHosts: nil)
    #expect(mine.backup == nil)
    let theirs = try #require(started.withLock { $0 })
    let result = try await theirs.value
    #expect(result.backup == nil)
    let lists = try await DirectoryStore(fileURL: file).load().lists
    #expect(lists.saved == ["~/seed"])
    #expect(lists.recent == [Self.hostA: ["~/mine"], Self.hostB: ["~/theirs"]])
    #expect(
      try LaunchTestSupport.names(in: file.deletingLastPathComponent()) == Self.storeFiles)
  } // End of func twoStoresNeverLoseEachOthersChanges()

  /// While another holder keeps `directories.lock`, a change waits, then gives up (`busy`)
  /// writing nothing; once it is released the change works. A lock file that is a symbolic
  /// link is refused (`lockUnavailable`), its target untouched.
  @Test func aHeldLockMakesAChangeWaitThenGiveUp() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let store = DirectoryStore(
      fileURL: fixture.file, owner: geteuid(), now: { Self.backupDate },
      lockWait: .milliseconds(50))
    _ = try await store.apply(.addSaved("~/a"), knownHosts: nil)
    let before = try Self.fileState(fixture.file)
    let folder = open(fixture.directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    try #require(folder >= 0)
    defer { close(folder) }
    let holder = try PrivateStorage.acquireLock(
      named: DirectoryStore.lockFileName, in: folder, owner: geteuid(), wait: .zero)
    await #expect(throws: DirectoryStoreError.busy) {
      try await store.apply(.addSaved("~/b"), knownHosts: nil)
    }
    #expect(try Self.fileState(fixture.file) == before)
    close(holder)
    #expect(try await store.apply(.addSaved("~/b"), knownHosts: nil).wrote)

    let lock = fixture.directory.appending(path: DirectoryStore.lockFileName)
    try FileManager.default.removeItem(at: lock)
    let target = fixture.base.appending(path: "target")
    try Data("the user's".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
    await #expect(throws: DirectoryStoreError.lockUnavailable) {
      try await store.apply(.addSaved("~/c"), knownHosts: nil)
    }
    #expect(try Data(contentsOf: target) == Data("the user's".utf8))
    #expect(try await store.load().lists.saved == ["~/a", "~/b"])
  } // End of func aHeldLockMakesAChangeWaitThenGiveUp()

  /// A file another program puts at the name between the read and the publication is never
  /// lost: the swap displaces it and it is kept as a backup.
  @Test func keepsAFileChangedDuringAWrite() async throws {
    let theirs = Data(Self.document(saved: "[\"~/theirs\"]").utf8)
    let target = OSAllocatedUnfairLock<URL?>(initialState: nil)
    let fixture = try Self.makeFixture(beforePublishing: {
      if let file = target.withLock({ $0 }) { try? theirs.write(to: file) }
    })
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try await fixture.store.apply(.addSaved("~/mine"), knownHosts: nil)
    target.withLock { $0 = fixture.file }
    let result = try await fixture.store.apply(.addSaved("~/second"), knownHosts: nil)
    #expect(result.backup?.lastPathComponent == Self.backupName)
    let backup = fixture.directory.appending(path: Self.backupName)
    #expect(try Data(contentsOf: backup) == theirs)
    #expect(try await fixture.store.load().lists.saved == ["~/mine", "~/second"])
  } // End of func keepsAFileChangedDuringAWrite()

  /// A symbolic link or a folder at the name refuses the change (`fileNotUsable`) and is left
  /// as it is; one that takes the name after the change looked (only a program outside
  /// muxFinder can do that) is refused by the write itself (`existingFileNotRegular`).
  @Test func refusesToReplaceANonRegularFile() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let target = fixture.base.appending(path: "target.json")
    try Data("{}".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
    await #expect(throws: DirectoryStoreError.fileNotUsable(.unsafe(.symbolicLink))) {
      try await fixture.store.apply(.addSaved("~/x"), knownHosts: nil)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "{}")
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [DirectoryStore.fileName])
    let folder = open(fixture.directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    try #require(folder >= 0)
    defer { close(folder) }
    await #expect(throws: DirectoryStoreError.existingFileNotRegular) {
      try await fixture.store.prepareReplacement(in: folder)
    }
    try FileManager.default.removeItem(at: fixture.file)
    try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
    await #expect(throws: DirectoryStoreError.fileNotUsable(.unsafe(.notARegularFile))) {
      try await fixture.store.apply(.addSaved("~/x"), knownHosts: nil)
    }
    await #expect(throws: DirectoryStoreError.existingFileNotRegular) {
      try await fixture.store.prepareReplacement(in: folder)
    }
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [DirectoryStore.fileName])
  } // End of func refusesToReplaceANonRegularFile()

  /// Lists that would encode over the size cap are refused before anything is written.
  @Test func refusesListsOverTheSizeCap() throws {
    let entry = "/" + String(repeating: "x", count: DirectoryLists.maximumEntryLength - 1)
    var recent: [UUID: [String]] = [:]
    for _ in 0..<40 {
      recent[UUID()] = (0..<8).map { "\(entry.prefix(entry.count - 1))\($0)" }
    }
    let lists = DirectoryLists(saved: [], recent: recent)
    #expect(lists.recent.count == 40)
    #expect(throws: DirectoryStoreError.listsTooLarge) { try DirectoryStore.encode(lists) }
  }

  // MARK: - Location and separation

  /// The default store is `~/Library/Application Support/muxFinder/directories.json`, in the
  /// host list's folder, computed without creating anything.
  @Test func defaultLocation() {
    let path = DirectoryStore().fileURL.path(percentEncoded: false)
    #expect(path.hasSuffix("/Library/Application Support/muxFinder/directories.json"))
    #expect(
      PrivateStorage.path(of: DirectoryStore().directoryURL)
        == PrivateStorage.path(of: HostStore().directoryURL))
    let root = TestSupport.temporaryURL()
    let store = DirectoryStore(paths: AppPaths(applicationSupportDirectory: root))
    #expect(store.fileURL == root.appending(path: "directories.json"))
    #expect(!LaunchTestSupport.exists(root))
  }

  /// The directory list stays apart from the host list: changes never read, replace or back up
  /// `hosts.json` or its backups, whatever they hold.
  @Test func neverTouchesTheHostList() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let hosts = fixture.directory.appending(path: HostStore.fileName)
    let hostsBackup = fixture.directory.appending(path: "hosts.backup-20261022T153012Z.json")
    try HostStoreTests.writeFile(Data("not even json".utf8), to: hosts)
    try HostStoreTests.writeFile(Data("{}".utf8), to: hostsBackup)
    try Self.writeFile(Self.document(saved: "[\"~/kept\", \"a\\nb\"]"), in: fixture)
    _ = try await fixture.store.apply(.recordRecent("~/r", hostID: Self.hostA), knownHosts: [])
    _ = try await fixture.store.apply(.addSaved("~/s"), knownHosts: [Self.hostA])
    #expect(try String(contentsOf: hosts, encoding: .utf8) == "not even json")
    #expect(try String(contentsOf: hostsBackup, encoding: .utf8) == "{}")
    #expect(
      try LaunchTestSupport.names(in: fixture.directory)
        == (Self.storeFiles + [
          Self.backupName, "hosts.backup-20261022T153012Z.json", HostStore.fileName,
        ]).sorted())
  } // End of func neverTouchesTheHostList()

  // MARK: - In memory

  /// The in-memory store applies the same rules and keeps nothing on disk.
  @Test func inMemoryStoreAppliesTheSameRules() async throws {
    let store = InMemoryDirectoryStore(
      DirectoryLists(saved: ["~/s"], recent: [Self.hostA: ["~/a"]]))
    #expect(await store.load().lists.saved == ["~/s"])
    let result = try await store.apply(
      .recordRecent("~/b", hostID: Self.hostB), knownHosts: [Self.hostB])
    #expect(result.lists.recent == [Self.hostB: ["~/b"]])
    #expect(!result.wrote)
    await #expect(throws: DirectoryStoreError.invalidChange(.entryEmpty)) {
      try await store.apply(.recordRecent("", hostID: Self.hostB), knownHosts: nil)
    }
    #expect(await store.changeCount == 1)
    #expect(await store.lists == result.lists)
  } // End of func inMemoryStoreAppliesTheSameRules()
}

/// The value rules of `DirectoryLists` (PLAN.md D31).
@Suite("Directory lists")
struct DirectoryListsTests {
  /// An entry must not be empty, pass `Validation.workingDirectory(_:)` and fit 4,096 bytes;
  /// tabs and other characters that rule allows stay allowed.
  @Test func checksEntries() {
    #expect(throws: DirectoryListError.entryEmpty) { try DirectoryLists.check("") }
    #expect(throws: DirectoryListError.entryInvalid(.workingDirectoryContainsLineBreak)) {
      try DirectoryLists.check("a\nb")
    }
    #expect(throws: DirectoryListError.entryInvalid(.workingDirectoryContainsNullCharacter)) {
      try DirectoryLists.check("a\u{0}b")
    }
    let longest = "/" + String(repeating: "é", count: 2047) + "x"
    #expect(longest.utf8.count == 4096)
    #expect(throws: Never.self) { try DirectoryLists.check(longest) }
    #expect(throws: DirectoryListError.entryTooLong) { try DirectoryLists.check(longest + "x") }
    for allowed in ["~", "~/x", "relative", "-x", "tab\there", " spaced "] {
      #expect(throws: Never.self) { try DirectoryLists.check(allowed) }
    }
  } // End of func checksEntries()

  /// The checking initializer keeps order, collapses duplicates without counting them, drops and
  /// counts rule breakers and entries past the caps, and leaves out hosts with nothing left.
  @Test func checkingInitializer() {
    var dropped = 0
    let lists = DirectoryLists(
      saved: ["~/a", "", "~/a", "~/b"],
      recent: [UUID(): ["", "a\nb"], UUID(): (1...9).map { "~/r\($0)" }],
      droppedCount: &dropped)
    #expect(lists.saved == ["~/a", "~/b"])
    #expect(lists.recent.count == 1)
    #expect(lists.recent.values.first == (1...8).map { "~/r\($0)" })
    #expect(dropped == 4)
  }

  /// Settings' merge (PLAN.md D31): the edits from `base` to `edited` land on the saved list as
  /// it is now. With nothing changed since `base` the result is `edited` (duplicates collapsed);
  /// otherwise the edits' removals, order and additions hold, what was removed since stays
  /// removed and what was added since follows at the end, entries compared byte for byte; a
  /// result over the cap, or an entry that breaks a rule, changes nothing (recents included).
  @Test func mergeSavedAppliesTheEditsToTheListAsItIsNow() throws {
    var lists = DirectoryLists(saved: ["~/a", "~/b", "~/c"], recent: [:])
    try lists.mergeSaved(base: ["~/a", "~/b", "~/c"], edited: ["~/c", "~/a", "~/new", "~/c"])
    #expect(lists.saved == ["~/c", "~/a", "~/new"])

    // Since the base, ~/a was removed and ~/x added elsewhere; the edits removed ~/b, moved
    // ~/c up and added ~/d.
    lists = DirectoryLists(saved: ["~/b", "~/c", "~/x"], recent: [:])
    try lists.mergeSaved(base: ["~/a", "~/b", "~/c"], edited: ["~/c", "~/a", "~/d"])
    #expect(lists.saved == ["~/c", "~/d", "~/x"])

    let composed = "~/caf\u{E9}"
    let decomposed = "~/cafe\u{301}"
    lists = DirectoryLists(saved: [composed, decomposed], recent: [:])
    try lists.mergeSaved(base: [composed], edited: [])
    #expect(DirectoryLists.sameEntries(lists.saved, [decomposed]), "added since, by its bytes")

    let host = UUID()
    let full = (1...50).map { "~/s\($0)" }
    var capped = DirectoryLists(saved: full, recent: [host: ["~/r"]])
    #expect(throws: DirectoryListError.tooManySaved) {
      try capped.mergeSaved(
        base: Array(full.prefix(49)), edited: Array(full.prefix(49)) + ["~/mine"])
    }
    #expect(throws: DirectoryListError.entryInvalid(.workingDirectoryContainsLineBreak)) {
      try capped.mergeSaved(base: full, edited: ["a\nb"])
    }
    #expect(capped.saved == full)
    #expect(capped.recent(for: host) == ["~/r"])
    #expect(DirectoryListChange.mergeSaved(base: [], edited: []).kind == "mergeSaved")
  } // End of func mergeSavedAppliesTheEditsToTheListAsItIsNow()

  /// Lists are equal byte for byte, as their duplicates rule compares entries: two spellings of
  /// one accented name make two different lists, saved or recent, and two set members.
  @Test func equalityIsByteForByte() {
    let composed = "~/caf\u{E9}"
    let decomposed = "~/cafe\u{301}"
    let host = UUID()
    let savedComposed = DirectoryLists(saved: [composed], recent: [:])
    #expect(savedComposed == DirectoryLists(saved: [composed], recent: [:]))
    #expect(savedComposed != DirectoryLists(saved: [decomposed], recent: [:]))
    #expect(
      DirectoryLists(saved: [], recent: [host: [composed]])
        != DirectoryLists(saved: [], recent: [host: [decomposed]]))
    #expect(
      DirectoryLists(saved: [], recent: [host: [composed]])
        != DirectoryLists(saved: [], recent: [UUID(): [composed]]))
    #expect(
      DirectoryLists(saved: ["~/a"], recent: [host: ["~/r"]])
        == DirectoryLists(saved: ["~/a"], recent: [host: ["~/r"]]))
    #expect(Set([savedComposed, DirectoryLists(saved: [decomposed], recent: [:])]).count == 2)
  } // End of func equalityIsByteForByte()

  /// Messages name the rule, never the entry.
  @Test func messagesNameNoDirectory() {
    let errors: [DirectoryListError] = [
      .entryEmpty, .entryInvalid(.workingDirectoryContainsLineBreak), .entryTooLong,
      .tooManySaved, .positionOutOfRange,
    ]
    #expect(Set(errors.map(\.message)).count == errors.count)
    #expect(Set(errors.map(\.code)).count == errors.count)
    #expect(DirectoryStoreError.invalidChange(.entryTooLong).code == "invalidChange.entryTooLong")
    #expect(
      DirectoryStoreError.systemCallFailed(name: "renameatx_np", errno: EIO).code
        == "systemCallFailed.renameatx_np.\(EIO)")
  } // End of func messagesNameNoDirectory()
}
