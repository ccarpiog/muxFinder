import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Tests for `HostStore`. Every test uses its own temporary directory, never the real
/// Application Support folder; host names and destinations are synthetic.
@Suite("Host store")
struct HostStoreTests {
  /// The fixed clock used to date backups: 2026-10-22 15:30:12 UTC.
  static let backupDate = Date(timeIntervalSince1970: 1_792_683_012)
  /// `backupDate` as it appears in backup names.
  static let backupStamp = "20261022T153012Z"

  /// A store at `<base>/muxFinder/hosts.json` in a fresh private base directory.
  struct Fixture {
    /// The store.
    let store: HostStore
    /// The private base directory (the caller removes it).
    let base: URL
    /// The store's folder (not created).
    let directory: URL
    /// The store's file.
    let file: URL
  }

  /// Creates a fixture. `owner` simulates another user's folder.
  static func makeFixture(owner: uid_t = geteuid()) throws -> Fixture {
    let base = try TestSupport.makeTemporaryDirectory()
    let directory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    let file = directory.appending(path: HostStore.fileName)
    let store = HostStore(fileURL: file, owner: owner, now: { backupDate })
    return Fixture(store: store, base: base, directory: directory, file: file)
  }

  /// Creates the fixture's folder with `mode`.
  static func createDirectory(_ fixture: Fixture, mode: Int = 0o700) throws {
    try FileManager.default.createDirectory(
      at: fixture.directory,
      withIntermediateDirectories: false,
      attributes: [.posixPermissions: mode]
    )
  }

  /// Writes `data` as the fixture's file with `mode` (exactly, whatever the umask).
  static func writeFile(_ data: Data, to url: URL, mode: mode_t = 0o600) throws {
    try data.write(to: url)
    try #require(chmod(url.path(percentEncoded: false), mode) == 0)
  }

  /// A valid list: This Mac, a configured SSH host with an override and a profile, and a
  /// disabled draft.
  static func sampleList() throws -> HostList {
    try HostList([
      HostConfig(displayName: "Local test", mode: .local),
      HostConfig(
        displayName: "Remote test",
        mode: .ssh,
        sshDestination: "tester@remote.example.test",
        tmuxPathOverride: "/opt/test/bin/tmux",
        iTermProfileName: "Test profile ü 日本"
      ),
      HostConfig(displayName: "Draft", mode: .ssh, sshDestination: "", isEnabled: false),
    ])
  } // End of func sampleList()

  /// Everything about a folder that a write could change: each entry's kind, mode, ACL entry
  /// count and bytes (regular files), and the folder's own mode and ACL entry count.
  struct Snapshot: Equatable {
    /// Per entry name: "kind mode acl-count".
    var entries: [String: String] = [:]
    /// Per regular file name: its bytes.
    var contents: [String: Data] = [:]
    /// The folder's mode and ACL entry count.
    var directory = ""
  }

  /// Takes a snapshot of `directory`.
  static func snapshot(of directory: URL) throws -> Snapshot {
    var snapshot = Snapshot()
    var info = stat()
    try #require(lstat(directory.path(percentEncoded: false), &info) == 0)
    snapshot.directory =
      "\(info.st_mode & 0o7777) \(try LaunchTestSupport.aclEntryCount(of: directory))"
    for name in try LaunchTestSupport.names(in: directory) {
      let url = directory.appending(path: name)
      try #require(lstat(url.path(percentEncoded: false), &info) == 0)
      let kind = info.st_mode & S_IFMT
      let acl = kind == S_IFLNK ? 0 : try LaunchTestSupport.aclEntryCount(of: url)
      snapshot.entries[name] = "\(kind) \(info.st_mode & 0o7777) \(acl)"
      if kind == S_IFREG { snapshot.contents[name] = try Data(contentsOf: url) }
    } // End of loop over entries
    return snapshot
  } // End of func snapshot(of:)

  /// The backup name a save made at `backupDate` uses on its `attempt`.
  static func backupName(attempt: Int = 1) -> String {
    "hosts.backup-\(backupStamp)" + (attempt > 1 ? "-\(attempt)" : "") + ".json"
  }

  // MARK: - Round trip and layout

  /// A saved list loads back as `saved`, identical; the file is a schema 1 object; saving a
  /// changed list over a valid file makes no backup.
  @Test func roundTrip() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    var list = try Self.sampleList()
    #expect(try await fixture.store.save(list) == nil)
    let loaded = try await fixture.store.load()
    #expect(loaded.state == .saved)
    #expect(loaded.hosts == list)

    let object = try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.file)) as? [String: Any]
    )
    #expect(Set(object.keys) == ["schemaVersion", "hosts"])
    #expect(object["schemaVersion"] as? Int == 1)
    let hosts = try #require(object["hosts"] as? [[String: Any]])
    #expect(hosts.count == 3)
    #expect(
      Set(hosts[1].keys) == [
        "id", "displayName", "mode", "sshDestination", "tmuxPathOverride", "iTermProfileName",
        "isEnabled",
      ]
    )
    #expect(hosts[0]["mode"] as? String == "local")
    #expect(Set(hosts[2].keys) == ["id", "displayName", "mode", "sshDestination", "isEnabled"])

    try list.remove(id: list.hosts[2].id)
    #expect(try await fixture.store.save(list) == nil)
    #expect(try await fixture.store.load() == HostStoreLoadResult.saved(list))
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [HostStore.fileName])
  } // End of func roundTrip()

  /// The default store is `~/Library/Application Support/muxFinder/hosts.json`, computed
  /// without creating anything; one made from `AppPaths` uses that root.
  @Test func defaultLocation() throws {
    let path = HostStore().fileURL.path(percentEncoded: false)
    #expect(path.hasSuffix("/Library/Application Support/muxFinder/hosts.json"))
    let root = TestSupport.temporaryURL()
    let store = HostStore(paths: AppPaths(applicationSupportDirectory: root))
    #expect(store.fileURL == root.appending(path: "hosts.json"))
    #expect(PrivateStorage.path(of: store.directoryURL) == PrivateStorage.path(of: root))
    #expect(!LaunchTestSupport.exists(root))
  }

  /// The folder a save creates under a parent with an inheritable ACL inherits it (the
  /// premise), but the save removes it: folder 0700 and file 0600, neither with an ACL. A
  /// folder that exists with a looser mode and an ACL (allow or deny-only) is tightened and
  /// stripped by the next save.
  @Test func writesPrivatelyAndStripsACLs() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneInheritedACL, on: fixture.base)
    let premise = fixture.base.appending(path: "premise")
    try FileManager.default.createDirectory(at: premise, withIntermediateDirectories: false)
    #expect(try LaunchTestSupport.aclEntryCount(of: premise) == 1)

    try await fixture.store.save(Self.sampleList())
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o700)
    #expect(try LaunchTestSupport.aclEntryCount(of: fixture.directory) == 0)
    #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
    #expect(try LaunchTestSupport.aclEntryCount(of: fixture.file) == 0)

    for text in [LaunchTestSupport.everyoneReadACL, LaunchTestSupport.everyoneDenyDeleteACL] {
      try #require(chmod(fixture.directory.path(percentEncoded: false), 0o755) == 0)
      try LaunchTestSupport.setACL(text, on: fixture.directory)
      #expect(try LaunchTestSupport.aclEntryCount(of: fixture.directory) == 1)
      try await fixture.store.save(Self.sampleList())
      #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o700)
      #expect(try LaunchTestSupport.aclEntryCount(of: fixture.directory) == 0)
      #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
      #expect(try LaunchTestSupport.aclEntryCount(of: fixture.file) == 0)
    }
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [HostStore.fileName])
  } // End of func writesPrivatelyAndStripsACLs()

  /// A folder whose ACL cannot be removed (it is immutable) is refused, and nothing is written.
  /// Loading does not touch the ACL, so it still reads the folder.
  @Test func refusesAFolderWhoseACLStays() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let path = fixture.directory.path(percentEncoded: false)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: fixture.directory)
    try #require(chflags(path, UInt32(UF_IMMUTABLE)) == 0)
    defer { chflags(path, 0) }
    await #expect(throws: HostStoreError.directoryHasExtendedACL) {
      try await fixture.store.save(Self.sampleList())
    }
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
    #expect(try LaunchTestSupport.aclEntryCount(of: fixture.directory) == 1)
    #expect(try await fixture.store.load().state == .notSavedYet)
  } // End of func refusesAFolderWhoseACLStays()

  /// A folder that is a symbolic link, a file, or another user's is refused by both load and
  /// save, and nothing is written through it.
  @Test func refusesUnusableFolders() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let target = fixture.base.appending(path: "target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: target)
    await #expect(throws: HostStoreError.directoryIsSymbolicLink) {
      try await fixture.store.load()
    }
    await #expect(throws: HostStoreError.directoryIsSymbolicLink) {
      try await fixture.store.save(Self.sampleList())
    }
    #expect(try LaunchTestSupport.names(in: target).isEmpty)

    try FileManager.default.removeItem(at: fixture.directory)
    try Data("x".utf8).write(to: fixture.directory)
    await #expect(throws: HostStoreError.directoryNotADirectory) {
      try await fixture.store.load()
    }
    await #expect(throws: HostStoreError.directoryNotADirectory) {
      try await fixture.store.save(Self.sampleList())
    }
    #expect(try Data(contentsOf: fixture.directory) == Data("x".utf8))

    try FileManager.default.removeItem(at: fixture.directory)
    try Self.createDirectory(fixture)
    let foreign = HostStore(fileURL: fixture.file, owner: geteuid() + 1, now: { Self.backupDate })
    await #expect(throws: HostStoreError.directoryNotOwnedByUser) { try await foreign.load() }
    await #expect(throws: HostStoreError.directoryNotOwnedByUser) {
      try await foreign.save(Self.sampleList())
    }
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
  } // End of func refusesUnusableFolders()

  // MARK: - Loading writes nothing

  /// No folder, or a folder without the file: the onboarding defaults, `notSavedYet`, and
  /// nothing written (no folder created; an existing folder keeps its loose mode, its ACL and
  /// its contents).
  @Test func missingFileGivesTheDefaultsAndWritesNothing() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let first = try await fixture.store.load()
    #expect(first.state == .notSavedYet)
    #expect(first.hosts.hosts.map(\.displayName) == ["Saturno", "Neptuno", "Sirio"])
    #expect(!LaunchTestSupport.exists(fixture.directory))
    #expect(try LaunchTestSupport.names(in: fixture.base).isEmpty)

    try Self.createDirectory(fixture, mode: 0o755)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneInheritedACL, on: fixture.directory)
    try Data("other".utf8).write(to: fixture.directory.appending(path: "unrelated"))
    let before = try Self.snapshot(of: fixture.directory)
    let second = try await fixture.store.load()
    #expect(second.state == .notSavedYet)
    #expect(second.hosts.hosts.map(\.displayName) == ["Saturno", "Neptuno", "Sirio"])
    #expect(try Self.snapshot(of: fixture.directory) == before)
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o755)
  } // End of func missingFileGivesTheDefaultsAndWritesNothing()

  /// One file that cannot be used, the problem a load reports for it, and why.
  struct InvalidCase {
    /// What the case covers.
    let label: String
    /// The file's bytes.
    let bytes: Data
    /// The expected problem.
    let problem: HostFileProblem
  }

  /// The invalid files: not JSON, not a host list, other schema versions, broken invariants.
  static func invalidCases() -> [InvalidCase] {
    let id = "8F1C2B9E-3A55-4E0B-9C7D-1E2F3A4B5C6D"
    /// A schema 1 file with these host objects.
    func file(_ hosts: String) -> Data {
      Data(#"{"schemaVersion": 1, "hosts": [\#(hosts)]}"#.utf8)
    }
    let local =
      #"{"id": "%@", "displayName": "L", "mode": "local", "sshDestination": "", "#
      + #""isEnabled": true}"#
    let localA = local.replacingOccurrences(of: "%@", with: id)
    let localB = local.replacingOccurrences(of: "%@", with: UUID().uuidString)
    let sshTwin =
      #"{"id": "\#(id)", "displayName": "S", "mode": "ssh", "sshDestination": "s.example.test", "#
      + #""isEnabled": true}"#
    let incomplete =
      #"{"id": "\#(id)", "displayName": "S", "mode": "ssh", "sshDestination": "", "#
      + #""isEnabled": true}"#
    let uuid = UUID(uuidString: id)!
    return [
      InvalidCase(
        label: "truncated", bytes: Data(#"{"schemaVersion": 1, "hosts": ["#.utf8), problem: .notJSON
      ),
      InvalidCase(label: "empty", bytes: Data(), problem: .notJSON),
      InvalidCase(label: "binary", bytes: Data([0xFF, 0xFE, 0x00, 0x7B]), problem: .notJSON),
      InvalidCase(label: "array", bytes: Data("[]".utf8), problem: .malformed),
      InvalidCase(label: "number", bytes: Data("1".utf8), problem: .malformed),
      InvalidCase(label: "no version", bytes: Data(#"{"hosts": []}"#.utf8), problem: .malformed),
      InvalidCase(
        label: "string version",
        bytes: Data(#"{"schemaVersion": "1", "hosts": []}"#.utf8),
        problem: .malformed
      ),
      InvalidCase(
        label: "no hosts",
        bytes: Data(#"{"schemaVersion": 1}"#.utf8),
        problem: .malformed
      ),
      InvalidCase(label: "bad host", bytes: file(#"{"id": "x"}"#), problem: .malformed),
      InvalidCase(
        label: "bad mode",
        bytes: file(localA.replacingOccurrences(of: "\"local\"", with: "\"telnet\"")),
        problem: .malformed
      ),
      InvalidCase(
        label: "newer",
        bytes: Data(#"{"schemaVersion": 2, "hosts": [], "future": true}"#.utf8),
        problem: .newerSchemaVersion(2)
      ),
      InvalidCase(
        label: "zero",
        bytes: Data(#"{"schemaVersion": 0, "hosts": []}"#.utf8),
        problem: .unsupportedSchemaVersion(0)
      ),
      InvalidCase(
        label: "two This Mac",
        bytes: file(localA + ", " + localB),
        problem: .invariantBroken(.moreThanOneThisMac)
      ),
      InvalidCase(
        label: "duplicate ids",
        bytes: file(localA + ", " + sshTwin),
        problem: .invariantBroken(.duplicateID(uuid))
      ),
      InvalidCase(
        label: "enabled without destination",
        bytes: file(incomplete),
        problem: .invariantBroken(
          .sshDestinationRequired(hostID: uuid, reason: .sshDestinationEmpty)
        )
      ),
    ]
  } // End of func invalidCases()

  /// Each invalid file is reported with its problem and the defaults, with nothing written by
  /// the load; the next save first copies its bytes to a 0600 backup without an ACL, then
  /// replaces it, and the save after that makes no other backup.
  @Test func reportsInvalidFilesAndBacksThemUpOnSave() async throws {
    for invalid in Self.invalidCases() {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Self.createDirectory(fixture)
      try Self.writeFile(invalid.bytes, to: fixture.file)
      let before = try Self.snapshot(of: fixture.directory)

      let loaded = try await fixture.store.load()
      #expect(loaded.state == .invalid(invalid.problem), "\(invalid.label)")
      #expect(
        loaded.hosts.hosts.map(\.displayName) == ["Saturno", "Neptuno", "Sirio"],
        "\(invalid.label)"
      )
      #expect(try Self.snapshot(of: fixture.directory) == before, "\(invalid.label)")

      let list = try Self.sampleList()
      let backup = try await fixture.store.save(list)
      #expect(backup?.lastPathComponent == Self.backupName(), "\(invalid.label)")
      let backupFile = fixture.directory.appending(path: Self.backupName())
      #expect(try Data(contentsOf: backupFile) == invalid.bytes, "\(invalid.label)")
      #expect(try LaunchTestSupport.permissions(of: backupFile) == 0o600)
      #expect(try LaunchTestSupport.aclEntryCount(of: backupFile) == 0)
      #expect(try await fixture.store.load() == HostStoreLoadResult.saved(list))

      #expect(try await fixture.store.save(list) == nil, "\(invalid.label)")
      #expect(
        try LaunchTestSupport.names(in: fixture.directory) == [
          Self.backupName(), HostStore.fileName,
        ],
        "\(invalid.label)"
      )
    } // End of loop over invalid cases
  } // End of func reportsInvalidFilesAndBacksThemUpOnSave()

  /// A valid list in a file others may read or change (group or other bits, or an ACL, allow or
  /// deny-only) or one that is too large is reported unsafe and left as it is by the load; the
  /// save backs it up byte for byte and replaces it with a private file (a deny-delete ACL
  /// does not block the replacement).
  @Test func reportsUnsafeFilesAndBacksThemUp() async throws {
    let valid = try HostStore.encode(Self.sampleList())
    let cases: [(String, Data, mode_t, String?, HostFileProblem.UnsafeReason)] = [
      ("group readable", valid, 0o640, nil, .permissionsTooOpen),
      ("world writable", valid, 0o606, nil, .permissionsTooOpen),
      ("allow ACL", valid, 0o600, LaunchTestSupport.everyoneReadACL, .extendedACL),
      ("deny-only ACL", valid, 0o600, LaunchTestSupport.everyoneDenyDeleteACL, .extendedACL),
      ("open and ACL", valid, 0o644, LaunchTestSupport.everyoneDenyDeleteACL, .permissionsTooOpen),
      (
        "too large", Data(repeating: 0x20, count: HostStore.maximumFileSize + 1), 0o600, nil,
        .tooLarge
      ),
    ]
    for (label, bytes, mode, acl, reason) in cases {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Self.createDirectory(fixture)
      try Self.writeFile(bytes, to: fixture.file, mode: mode)
      if let acl { try LaunchTestSupport.setACL(acl, on: fixture.file) }
      let before = try Self.snapshot(of: fixture.directory)

      let loaded = try await fixture.store.load()
      #expect(loaded.state == .invalid(.unsafe(reason)), "\(label)")
      #expect(try Self.snapshot(of: fixture.directory) == before, "\(label)")

      let list = try Self.sampleList()
      #expect(try await fixture.store.save(list)?.lastPathComponent == Self.backupName())
      let backupFile = fixture.directory.appending(path: Self.backupName())
      #expect(try Data(contentsOf: backupFile) == bytes, "\(label)")
      #expect(try LaunchTestSupport.permissions(of: backupFile) == 0o600, "\(label)")
      #expect(try LaunchTestSupport.aclEntryCount(of: backupFile) == 0, "\(label)")
      #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600, "\(label)")
      #expect(try LaunchTestSupport.aclEntryCount(of: fixture.file) == 0, "\(label)")
      #expect(try await fixture.store.load().state == .saved, "\(label)")
    } // End of loop over unsafe cases
  } // End of func reportsUnsafeFilesAndBacksThemUp()

  /// A symbolic link, a folder or a FIFO at the file's name is reported unsafe without being
  /// followed, read or blocked on; a save refuses to replace it and writes nothing.
  @Test func leavesNonRegularFilesAlone() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let target = fixture.base.appending(path: "elsewhere.json")
    try Self.writeFile(try HostStore.encode(Self.sampleList()), to: target)
    let targetBytes = try Data(contentsOf: target)
    try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)

    let kinds: [(String, HostFileProblem.UnsafeReason)] = [
      ("link", .symbolicLink), ("folder", .notARegularFile), ("fifo", .notARegularFile),
    ]
    for (kind, reason) in kinds {
      if kind == "folder" {
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createDirectory(
          at: fixture.file, withIntermediateDirectories: false)
      } else if kind == "fifo" {
        try FileManager.default.removeItem(at: fixture.file)
        try #require(mkfifo(fixture.file.path(percentEncoded: false), 0o600) == 0)
      }
      let before = try Self.snapshot(of: fixture.directory)
      #expect(try await fixture.store.load().state == .invalid(.unsafe(reason)), "\(kind)")
      await #expect(throws: HostStoreError.existingFileNotRegular, "\(kind)") {
        try await fixture.store.save(Self.sampleList())
      }
      #expect(try Self.snapshot(of: fixture.directory) == before, "\(kind)")
    } // End of loop over kinds
    #expect(try Data(contentsOf: target) == targetBytes)
  } // End of func leavesNonRegularFilesAlone()

  /// A file owned by another user is not trusted (checked on the open descriptor's status;
  /// tests cannot create another user's file).
  @Test func distrustsAnotherUsersFile() throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    try Self.writeFile(Data("{}".utf8), to: fixture.file)
    let descriptor = open(fixture.file.path(percentEncoded: false), O_RDONLY)
    try #require(descriptor >= 0)
    defer { close(descriptor) }
    var info = stat()
    try #require(fstat(descriptor, &info) == 0)
    #expect(try HostStore.trustProblem(of: descriptor, info: info, owner: geteuid()) == nil)
    #expect(
      try HostStore.trustProblem(of: descriptor, info: info, owner: geteuid() + 1)
        == .notOwnedByUser
    )
  } // End of func distrustsAnotherUsersFile()

  /// Two saves in the same second that each replace an unusable file keep both files: the
  /// second backup gets the next free suffix and the first is left as it was.
  @Test func backupsNeverReplaceEachOther() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let first = Data("first, not JSON".utf8)
    let second = Data(#"{"schemaVersion": 7}"#.utf8)
    try Self.writeFile(first, to: fixture.file)
    try await fixture.store.save(Self.sampleList())
    try Self.writeFile(second, to: fixture.file)
    let backup = try await fixture.store.save(Self.sampleList())
    #expect(backup?.lastPathComponent == Self.backupName(attempt: 2))
    #expect(
      try Data(contentsOf: fixture.directory.appending(path: Self.backupName())) == first
    )
    #expect(
      try Data(contentsOf: fixture.directory.appending(path: Self.backupName(attempt: 2)))
        == second
    )
    #expect(try LaunchTestSupport.names(in: fixture.directory).count == 3)
  } // End of func backupsNeverReplaceEachOther()

  // MARK: - Files changed while a save runs

  /// A store at the fixture's file whose saves run `hook` after looking at the file and writing
  /// their temporary file, just before publishing it.
  static func makeStore(
    _ fixture: Fixture,
    beforePublishing hook: @escaping @Sendable () -> Void
  ) -> HostStore {
    HostStore(
      fileURL: fixture.file,
      owner: geteuid(),
      now: { backupDate },
      beforePublishing: hook
    )
  }

  /// Replaces the file at `url` the way most editors save: a new 0600 file beside it, renamed
  /// over the name.
  static func renameOver(_ url: URL, with data: Data) throws {
    let draft = url.deletingLastPathComponent().appending(path: "editor-draft")
    try writeFile(data, to: draft)
    try #require(rename(draft.path(percentEncoded: false), url.path(percentEncoded: false)) == 0)
  }

  /// Rewrites the bytes of the existing file at `url` in place (same file, same mode).
  static func editInPlace(_ url: URL, with data: Data) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.truncate(atOffset: 0)
    try handle.write(contentsOf: data)
  }

  /// A one-host list that differs from `sampleList()`.
  static func otherList(_ name: String) throws -> HostList {
    try HostList([HostConfig(displayName: name, mode: .ssh, sshDestination: "other.test")])
  }

  /// A file another program changes after the save looked at it and before the save publishes
  /// (a hook in the save path, no timing): an invalid file or a valid list with other bytes
  /// renamed over it, and a valid list written in place, are each kept byte for byte in a 0600
  /// backup without ACL, with the new list in place. Renaming over the name without looking at
  /// what it displaces loses each of them.
  @Test func keepsAFileChangedWhileSaving() async throws {
    let other = try HostStore.encode(Self.otherList("Edited elsewhere"))
    let cases: [(String, Data, Bool)] = [
      ("invalid, renamed over", Data("edited elsewhere, not JSON".utf8), false),
      ("valid, renamed over", other, false),
      ("valid, edited in place", other, true),
    ]
    for (label, bytes, inPlace) in cases {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try await fixture.store.save(Self.sampleList())
      let file = fixture.file
      let store = Self.makeStore(fixture) {
        if inPlace {
          try? Self.editInPlace(file, with: bytes)
        } else {
          try? Self.renameOver(file, with: bytes)
        }
      }
      #expect(try await store.load().state == .saved, "\(label)")

      let list = try Self.otherList("Saved by the store")
      let backup = try await store.save(list)
      #expect(backup?.lastPathComponent == Self.backupName(), "\(label)")
      let backupFile = fixture.directory.appending(path: Self.backupName())
      #expect(try Data(contentsOf: backupFile) == bytes, "\(label)")
      #expect(try LaunchTestSupport.permissions(of: backupFile) == 0o600, "\(label)")
      #expect(try LaunchTestSupport.aclEntryCount(of: backupFile) == 0, "\(label)")
      #expect(
        try await store.load() == HostStoreLoadResult.saved(list), "\(label)"
      )
      #expect(
        try LaunchTestSupport.names(in: fixture.directory) == [
          Self.backupName(), HostStore.fileName,
        ],
        "\(label)"
      )
    } // End of loop over changes
  } // End of func keepsAFileChangedWhileSaving()

  /// A file that appears after the save found none and before it publishes is never
  /// overwritten: the exclusive rename refuses, the save swaps instead and keeps the file.
  @Test func keepsAFileThatAppearsWhileSaving() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let bytes = try HostStore.encode(Self.otherList("Created elsewhere"))
    let file = fixture.file
    let store = Self.makeStore(fixture) { try? Self.renameOver(file, with: bytes) }
    #expect(try await store.load().state == .notSavedYet)

    let list = try Self.sampleList()
    #expect(try await store.save(list)?.lastPathComponent == Self.backupName())
    #expect(try Data(contentsOf: fixture.directory.appending(path: Self.backupName())) == bytes)
    #expect(try await store.load() == HostStoreLoadResult.saved(list))
    #expect(
      try LaunchTestSupport.names(in: fixture.directory) == [Self.backupName(), HostStore.fileName]
    )
  } // End of func keepsAFileThatAppearsWhileSaving()

  /// A save deletes the file it displaces only when it holds the bytes this store last wrote or
  /// loaded: saving twice, or saving after loading the file, leaves no backup, while a store
  /// that has loaded or written nothing keeps even a valid file it displaces.
  @Test func deletesOnlyTheFileItKnows() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let first = try Self.sampleList()
    let second = try Self.otherList("Second")
    #expect(try await fixture.store.save(first) == nil)
    #expect(try await fixture.store.save(second) == nil)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [HostStore.fileName])

    let loader = HostStore(fileURL: fixture.file, owner: geteuid(), now: { Self.backupDate })
    #expect(try await loader.load().state == .saved)
    #expect(try await loader.save(first) == nil)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [HostStore.fileName])

    let saved = try Data(contentsOf: fixture.file)
    let unaware = HostStore(fileURL: fixture.file, owner: geteuid(), now: { Self.backupDate })
    #expect(try await unaware.save(second)?.lastPathComponent == Self.backupName())
    #expect(try Data(contentsOf: fixture.directory.appending(path: Self.backupName())) == saved)
    #expect(try await unaware.load() == HostStoreLoadResult.saved(second))
  } // End of func deletesOnlyTheFileItKnows()

  /// A file removed after the save looked at it is simply replaced: the swap finds no file, the
  /// exclusive rename publishes the list, and nothing is backed up.
  @Test func publishesWhenTheFileVanishesWhileSaving() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try await fixture.store.save(Self.sampleList())
    let path = fixture.file.path(percentEncoded: false)
    let store = Self.makeStore(fixture) { unlink(path) }
    #expect(try await store.load().state == .saved)

    let list = try Self.otherList("After removal")
    #expect(try await store.save(list) == nil)
    #expect(try await store.load() == HostStoreLoadResult.saved(list))
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [HostStore.fileName])
  } // End of func publishesWhenTheFileVanishesWhileSaving()

  /// A symbolic link or a folder that takes the file's place after the save looked at it is
  /// displaced by the swap and kept under the backup name as it was: the link not followed
  /// (its target unchanged), the folder with its contents.
  @Test func keepsALinkOrFolderThatAppearsWhileSaving() async throws {
    for kind in ["link", "folder"] {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try await fixture.store.save(Self.sampleList())
      let target = fixture.base.appending(path: "elsewhere.json")
      try Self.writeFile(Data("target".utf8), to: target)
      let path = fixture.file.path(percentEncoded: false)
      let targetPath = target.path(percentEncoded: false)
      let store = Self.makeStore(fixture) {
        unlink(path)
        if kind == "link" {
          symlink(targetPath, path)
        } else {
          mkdir(path, 0o700)
          try? Data("inside".utf8).write(to: URL(filePath: path).appending(path: "inside"))
        }
      }
      #expect(try await store.load().state == .saved, "\(kind)")

      let list = try Self.otherList("Over a \(kind)")
      #expect(try await store.save(list)?.lastPathComponent == Self.backupName(), "\(kind)")
      let backup = fixture.directory.appending(path: Self.backupName())
      if kind == "link" {
        #expect(
          try FileManager.default.destinationOfSymbolicLink(
            atPath: backup.path(percentEncoded: false)
          ) == targetPath
        )
      } else {
        #expect(try Data(contentsOf: backup.appending(path: "inside")) == Data("inside".utf8))
      }
      #expect(try Data(contentsOf: target) == Data("target".utf8), "\(kind)")
      #expect(
        try await store.load() == HostStoreLoadResult.saved(list), "\(kind)"
      )
    } // End of loop over kinds
  } // End of func keepsALinkOrFolderThatAppearsWhileSaving()

  /// When no backup name is free, the displaced file is never deleted: the save reports
  /// `displacedFileNotKept` with the hidden temporary name that still holds its bytes, the new
  /// list is in place, and every existing backup is unchanged.
  @Test func keepsTheDisplacedFileWhenNoBackupNameIsFree() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.createDirectory(fixture)
    let bytes = Data("hand-edited, not JSON".utf8)
    try Self.writeFile(bytes, to: fixture.file)
    let attempts = 1...HostStore.maximumBackupAttempts
    for attempt in attempts {
      let backup = fixture.directory.appending(path: Self.backupName(attempt: attempt))
      try Self.writeFile(Data("backup \(attempt)".utf8), to: backup)
    }

    let list = try Self.sampleList()
    do throws(HostStoreError) {
      try await fixture.store.save(list)
      Issue.record("The save should report the displaced file it could not keep.")
    } catch {
      guard case .displacedFileNotKept(let temporaryName, let code) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      #expect(code == EEXIST)
      #expect(temporaryName.hasPrefix(".hosts.json.") && temporaryName.hasSuffix(".tmp"))
      #expect(try Data(contentsOf: fixture.directory.appending(path: temporaryName)) == bytes)
      #expect(error.localizedDescription.contains(temporaryName))
    }
    #expect(try await fixture.store.load() == HostStoreLoadResult.saved(list))
    for attempt in attempts {
      let backup = fixture.directory.appending(path: Self.backupName(attempt: attempt))
      #expect(try Data(contentsOf: backup) == Data("backup \(attempt)".utf8))
    }
    #expect(try LaunchTestSupport.names(in: fixture.directory).count == attempts.count + 2)
  } // End of func keepsTheDisplacedFileWhenNoBackupNameIsFree()

  // MARK: - Checked saves

  /// `save(_:expecting:)` refuses a file that is no longer the revision it expects, writing
  /// nothing (not even the folder): a valid file replaced by one that is not JSON, by a newer
  /// format or by another valid list, edited in place, or turned into a link, and a missing
  /// file that appeared (PLAN.md D19, D23). The error carries what is there now.
  @Test func checkedSaveRefusesAChangedFile() async throws {
    let other = try HostStore.encode(Self.otherList("Elsewhere"))
    let changes: [(String, Bool, Data?)] = [
      ("not JSON, renamed over", true, Data("not JSON".utf8)),
      ("newer format, renamed over", true, Data(#"{"schemaVersion": 2, "hosts": []}"#.utf8)),
      ("another list, renamed over", true, other),
      ("another list, edited in place", false, other),
      ("a link", true, nil),
    ]
    for (label, renamed, bytes) in changes {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try await fixture.store.save(Self.sampleList())
      let loaded = try await fixture.store.load()
      if let bytes {
        try renamed
          ? Self.renameOver(fixture.file, with: bytes) : Self.editInPlace(fixture.file, with: bytes)
      } else {
        let path = fixture.file.path(percentEncoded: false)
        try #require(unlink(path) == 0 && symlink("/dev/null", path) == 0)
      }
      let before = try Self.snapshot(of: fixture.directory)
      let current = try await fixture.store.load().revision
      #expect(current != loaded.revision, "\(label)")
      await #expect(throws: HostStoreError.fileChanged(current: current), "\(label)") {
        try await fixture.store.save(Self.otherList("Saved here"), expecting: loaded.revision)
      }
      #expect(try Self.snapshot(of: fixture.directory) == before, "\(label)")
    } // End of loop over changes

    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let missing = try await fixture.store.load()
    #expect(missing.state == .notSavedYet)
    try Self.createDirectory(fixture)
    try Self.writeFile(other, to: fixture.file)
    let before = try Self.snapshot(of: fixture.directory)
    await #expect(throws: HostStoreError.self) {
      try await fixture.store.save(Self.sampleList(), expecting: missing.revision)
    }
    #expect(try Self.snapshot(of: fixture.directory) == before)
  } // End of func checkedSaveRefusesAChangedFile()

  /// A checked save of an unchanged file goes through and returns the revision it wrote, which
  /// the next save and a later load both match; the backup rule is unchanged: a valid file the
  /// store knows is not kept, an unusable one is, and a refused save's `current` revision lets
  /// a save replace exactly that file, keeping it as a backup.
  @Test func checkedSavesChainAndKeepTheBackupRule() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let missing = try await fixture.store.load()
    let first = try await fixture.store.save(Self.sampleList(), expecting: missing.revision)
    #expect(first.backup == nil && first.displacedFileError == nil)
    #expect(try await fixture.store.load().revision == first.revision)
    let second = try await fixture.store.save(Self.otherList("Two"), expecting: first.revision)
    #expect(second.backup == nil)
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [HostStore.fileName])

    let unusable = Data("hand-edited, not JSON".utf8)
    try Self.renameOver(fixture.file, with: unusable)
    let three = try Self.otherList("Three")
    var current: HostFileRevision?
    do throws(HostStoreError) {
      _ = try await fixture.store.save(three, expecting: second.revision)
      Issue.record("The save should refuse the changed file.")
    } catch {
      guard case .fileChanged(let found) = error else {
        Issue.record("Unexpected error: \(error)")
        return
      }
      current = found
    }
    let expected = try #require(current)
    let third = try await fixture.store.save(three, expecting: expected)
    #expect(third.backup?.lastPathComponent == Self.backupName())
    #expect(try Data(contentsOf: fixture.directory.appending(path: Self.backupName())) == unusable)
    #expect(try await fixture.store.load() == HostStoreLoadResult.saved(three))
  } // End of func checkedSavesChainAndKeepTheBackupRule()

  /// A list that breaks an invariant, or that would be too large to load, is refused before
  /// anything is written (not even the folder).
  @Test func refusesInvalidOrOversizedLists() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let twoLocal = HostList(unchecked: [
      HostConfig(displayName: "One", mode: .local),
      HostConfig(displayName: "Two", mode: .local),
    ])
    await #expect(throws: HostStoreError.invalidList(.moreThanOneThisMac)) {
      try await fixture.store.save(twoLocal)
    }
    let incomplete = HostConfig(displayName: "Remote", mode: .ssh, isEnabled: true)
    await #expect(
      throws: HostStoreError.invalidList(
        .sshDestinationRequired(hostID: incomplete.id, reason: .sshDestinationEmpty)
      )
    ) { try await fixture.store.save(HostList(unchecked: [incomplete])) }
    let huge = try HostList([
      HostConfig(
        displayName: String(repeating: "x", count: HostStore.maximumFileSize),
        mode: .local
      )
    ])
    await #expect(throws: HostStoreError.listTooLarge) { try await fixture.store.save(huge) }
    #expect(!LaunchTestSupport.exists(fixture.directory))
  } // End of func refusesInvalidOrOversizedLists()

  /// A save into a folder whose parent is missing is refused (`directoryMissing`); the folder
  /// itself is created, but not its parents.
  @Test func needsTheParentFolder() async throws {
    let base = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appending(path: "missing/muxFinder/hosts.json")
    let store = HostStore(fileURL: file)
    await #expect(throws: HostStoreError.directoryMissing) {
      try await store.save(Self.sampleList())
    }
    #expect(try LaunchTestSupport.names(in: base).isEmpty)
    #expect(try await store.load().state == .notSavedYet)
  } // End of func needsTheParentFolder()

  /// Concurrent saves of one store never interleave: every save succeeds, the file holds one of
  /// the lists, and no temporary file or backup is left.
  @Test func concurrentSavesStayConsistent() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let lists = try (0..<16).map { index in
      try HostList([
        HostConfig(displayName: "Host \(index)", mode: .ssh, sshDestination: "h\(index).test")
      ])
    }
    try await withThrowingTaskGroup(of: Void.self) { group in
      for list in lists {
        group.addTask { _ = try await fixture.store.save(list) }
      }
      try await group.waitForAll()
    }
    let loaded = try await fixture.store.load()
    #expect(loaded.state == .saved)
    #expect(lists.contains(loaded.hosts))
    #expect(try LaunchTestSupport.names(in: fixture.directory) == [HostStore.fileName])
  } // End of func concurrentSavesStayConsistent()

  /// Backup names keep the extension last and count from the second attempt; timestamps are
  /// UTC.
  @Test func namesBackups() {
    #expect(
      HostStore.backupName(for: "hosts.json", timestamp: "20261022T153012Z", attempt: 1)
        == "hosts.backup-20261022T153012Z.json"
    )
    #expect(
      HostStore.backupName(for: "hosts.json", timestamp: "20261022T153012Z", attempt: 3)
        == "hosts.backup-20261022T153012Z-3.json"
    )
    #expect(
      HostStore.backupName(for: "plain", timestamp: "T", attempt: 1) == "plain.backup-T"
    )
    #expect(HostStore.timestamp(Date(timeIntervalSince1970: 0)) == "19700101T000000Z")
    #expect(HostStore.timestamp(Self.backupDate) == Self.backupStamp)
  } // End of func namesBackups()

  /// Problem codes are stable and messages are English sentences that hold no file contents.
  @Test func describesProblems() {
    let problems: [HostFileProblem] = [
      .unsafe(.symbolicLink), .unsafe(.notARegularFile), .unsafe(.notOwnedByUser),
      .unsafe(.permissionsTooOpen), .unsafe(.extendedACL), .unsafe(.tooLarge), .notJSON,
      .malformed, .newerSchemaVersion(2), .unsupportedSchemaVersion(0),
      .invariantBroken(.moreThanOneThisMac),
    ]
    #expect(Set(problems.map(\.code)).count == problems.count)
    #expect(problems[4].code == "unsafe.extendedACL")
    for problem in problems {
      #expect(problem.message.first?.isUppercase == true)
      #expect(problem.message.hasSuffix("."))
      #expect(problem.description == problem.message)
    }
    let errors: [HostStoreError] = [
      .directoryMissing, .directoryIsSymbolicLink, .directoryNotADirectory,
      .directoryNotOwnedByUser, .directoryHasExtendedACL, .existingFileNotRegular,
      .existingFileTooLarge, .invalidList(.moreThanOneThisMac), .encodingFailed, .listTooLarge,
      .displacedFileNotKept(temporaryName: ".hosts.json.1.tmp", errno: EEXIST),
      .systemCallFailed(name: "openat", errno: EACCES),
    ]
    for error in errors {
      #expect(error.localizedDescription.hasSuffix("."))
    }
  } // End of func describesProblems()
}

extension HostStoreLoadResult {
  /// What loading a file a store wrote for `hosts` gives: `saved`, whose revision is the bytes
  /// the store wrote.
  static func saved(_ hosts: HostList) throws -> HostStoreLoadResult {
    HostStoreLoadResult(
      hosts: hosts, state: .saved,
      revision: HostFileRevision(entry: .contents(try HostStore.encode(hosts), nil)))
  }
}
