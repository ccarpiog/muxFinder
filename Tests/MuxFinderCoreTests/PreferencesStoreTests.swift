import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// `PreferencesStore` and `InMemoryPreferencesStore` (PLAN.md D32). Every test uses its own
/// temporary folder, never the real Application Support folder, and never `UserDefaults` or
/// `~/Library/Preferences`.
@Suite("Preferences store")
struct PreferencesStoreTests {
  /// The fixed clock used to date backups: 2026-10-22 15:30:12 UTC.
  static let backupDate = Date(timeIntervalSince1970: 1_792_683_012)
  /// The backup name a write made at `backupDate` uses first.
  static let backupName = "preferences.backup-20261022T153012Z.json"
  /// ⌃⌥Space.
  static let controlOptionSpace = GlobalShortcut(
    keyCode: GlobalShortcut.KeyCode.space, modifiers: [.control, .option])
  /// ⌘⇧F19.
  static let commandShiftF19 = GlobalShortcut(
    keyCode: GlobalShortcut.KeyCode.f19, modifiers: [.command, .shift])

  /// A store at `<base>/muxFinder/preferences.json` in a fresh private base directory.
  struct Fixture {
    /// The store.
    let store: PreferencesStore
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
    let file = directory.appending(path: PreferencesStore.fileName)
    let store = PreferencesStore(
      fileURL: file, owner: geteuid(), now: { backupDate }, beforePublishing: beforePublishing)
    return Fixture(store: store, base: base, directory: directory, file: file)
  }

  /// Writes `text` as the fixture's file with `mode`, creating the folder (0700).
  static func writeFile(_ text: String, in fixture: Fixture, mode: mode_t = 0o600) throws {
    if !LaunchTestSupport.exists(fixture.directory) {
      try FileManager.default.createDirectory(
        at: fixture.directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    }
    try HostStoreTests.writeFile(Data(text.utf8), to: fixture.file, mode: mode)
  }

  /// The file's JSON object.
  static func object(at url: URL) throws -> [String: Any] {
    try #require(
      try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
  }

  // MARK: - Loading

  /// No folder, or a folder without the file: no shortcut, `notSavedYet`, nothing created.
  @Test func missingFileGivesNoShortcut() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let loaded = try await fixture.store.load()
    #expect(loaded == PreferencesLoadResult(preferences: Preferences(), state: .notSavedYet))
    #expect(!LaunchTestSupport.exists(fixture.directory))
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o755])
    #expect(try await fixture.store.load().state == .notSavedYet)
    #expect(try LaunchTestSupport.names(in: fixture.directory).isEmpty)
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o755)
  } // End of func missingFileGivesNoShortcut()

  /// Recording writes a private file (0600, folder 0700) that loads back; clearing removes the
  /// entry; the file holds the schema version, the key code and the modifier names.
  @Test func roundTrip() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let recorded = try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)
    #expect(recorded.wrote && recorded.backup == nil)
    #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
    #expect(try LaunchTestSupport.permissions(of: fixture.directory) == 0o700)
    #expect(
      try LaunchTestSupport.names(in: fixture.directory)
        == [PreferencesStore.fileName, PreferencesStore.lockFileName].sorted())
    let object = try Self.object(at: fixture.file)
    #expect(object["schemaVersion"] as? Int == 1)
    let entry = try #require(object["globalShortcut"] as? [String: Any])
    #expect(entry["keyCode"] as? Int == 49)
    #expect(entry["modifiers"] as? [String] == ["control", "option"])
    let text = try String(contentsOf: fixture.file, encoding: .utf8)
    #expect(text.hasSuffix("}\n"))
    let fresh = PreferencesStore(fileURL: fixture.file)
    let loaded = try await fresh.load()
    #expect(loaded.state == .saved && !loaded.droppedShortcut)
    #expect(loaded.preferences.globalShortcut == Self.controlOptionSpace)

    let changed = try await fresh.setGlobalShortcut(Self.commandShiftF19)
    #expect(changed.wrote && changed.backup == nil)
    #expect(try await fixture.store.load().preferences.globalShortcut == Self.commandShiftF19)
    let cleared = try await fresh.setGlobalShortcut(nil)
    #expect(cleared.wrote && cleared.preferences.globalShortcut == nil)
    #expect(try Self.object(at: fixture.file)["globalShortcut"] == nil)
    #expect(
      try await fixture.store.load()
        == PreferencesLoadResult(preferences: Preferences(), state: .saved))
  } // End of func roundTrip()

  /// A change that changes nothing writes nothing: the same shortcut again, or a clear with
  /// no file (no folder or lock file created) or no shortcut in the file.
  @Test func unchangedChangesWriteNothing() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let none = try await fixture.store.setGlobalShortcut(nil)
    #expect(!none.wrote)
    #expect(!LaunchTestSupport.exists(fixture.directory))
    _ = try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)
    let before = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(!(try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)).wrote)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == before)
    try Self.writeFile("{\"schemaVersion\": 1, \"globalShortcut\": null}\n", in: fixture)
    let nullBefore = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(!(try await fixture.store.setGlobalShortcut(nil)).wrote)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == nullBefore)
  } // End of func unchangedChangesWriteNothing()

  /// Files that cannot be used give no shortcut and stay exactly as they are; every change is
  /// refused (`fileNotUsable`) and writes nothing, not even the lock file.
  @Test func unusableFilesAreLeftAsTheyAre() async throws {
    let valid =
      "{\"schemaVersion\": 1, \"globalShortcut\": {\"keyCode\": 49, \"modifiers\": "
      + "[\"control\"]}}\n"
    let big = String(repeating: " ", count: PreferencesStore.maximumFileSize + 1)
    let cases: [(String, String, mode_t, PreferencesFileProblem)] = [
      ("not JSON", "{\"schemaVersion\": 1,", 0o600, .notJSON),
      ("an array", "[1]", 0o600, .malformed),
      ("no version", "{\"globalShortcut\": null}", 0o600, .malformed),
      ("string version", "{\"schemaVersion\": \"1\"}", 0o600, .malformed),
      ("newer", "{\"schemaVersion\": 2}", 0o600, .newerSchemaVersion(2)),
      ("zero", "{\"schemaVersion\": 0}", 0o600, .unsupportedSchemaVersion(0)),
      ("open permissions", valid, 0o644, .unsafe(.permissionsTooOpen)),
      ("too large", big, 0o600, .unsafe(.tooLarge)),
    ]
    for (label, text, mode, problem) in cases {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Self.writeFile(text, in: fixture, mode: mode)
      let before = try HostStoreTests.snapshot(of: fixture.directory)
      let loaded = try await fixture.store.load()
      #expect(loaded.state == .invalid(problem), "\(label)")
      #expect(loaded.preferences.globalShortcut == nil, "\(label)")
      await #expect(throws: PreferencesStoreError.fileNotUsable(problem), "\(label)") {
        try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)
      }
      await #expect(throws: PreferencesStoreError.fileNotUsable(problem), "\(label)") {
        try await fixture.store.setGlobalShortcut(nil)
      }
      #expect(try HostStoreTests.snapshot(of: fixture.directory) == before, "\(label)")
    } // End of loop over unusable files
  } // End of func unusableFilesAreLeftAsTheyAre()

  /// A symbolic link is never followed, a folder at the name is not a file, a file with an
  /// ACL is not trusted; each stays as it is and refuses changes.
  @Test func unsafeEntriesAreNotTrusted() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try FileManager.default.createDirectory(
      at: fixture.directory, withIntermediateDirectories: false,
      attributes: [.posixPermissions: 0o700])
    let target = fixture.base.appending(path: "target.json")
    try HostStoreTests.writeFile(Data("{\"schemaVersion\": 1}".utf8), to: target)
    try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
    #expect(try await fixture.store.load().state == .invalid(.unsafe(.symbolicLink)))
    await #expect(throws: PreferencesStoreError.fileNotUsable(.unsafe(.symbolicLink))) {
      try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)
    }
    #expect(try String(contentsOf: target, encoding: .utf8) == "{\"schemaVersion\": 1}")
    try FileManager.default.removeItem(at: fixture.file)

    try FileManager.default.createDirectory(at: fixture.file, withIntermediateDirectories: false)
    #expect(try await fixture.store.load().state == .invalid(.unsafe(.notARegularFile)))
    try FileManager.default.removeItem(at: fixture.file)

    try Self.writeFile("{\"schemaVersion\": 1}\n", in: fixture)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: fixture.file)
    let before = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(try await fixture.store.load().state == .invalid(.unsafe(.extendedACL)))
    await #expect(throws: PreferencesStoreError.fileNotUsable(.unsafe(.extendedACL))) {
      try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)
    }
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == before)
  } // End of func unsafeEntriesAreNotTrusted()

  /// A folder that is a symbolic link is refused by loads and changes, and nothing is written
  /// through it.
  @Test func refusesAFolderThatIsALink() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    let target = fixture.base.appending(path: "target", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: target)
    await #expect(throws: PreferencesStoreError.directoryIsSymbolicLink) {
      try await fixture.store.load()
    }
    await #expect(throws: PreferencesStoreError.directoryIsSymbolicLink) {
      try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)
    }
    #expect(try LaunchTestSupport.names(in: target).isEmpty)
  } // End of func refusesAFolderThatIsALink()

  /// A shortcut value that is not usable is left out (`droppedShortcut`, no shortcut), the
  /// file stays usable, and a recording replaces it while keeping the file as a backup.
  @Test func unusableShortcutValuesAreDropped() async throws {
    let values = [
      "\"⌃⌥Space\"", "{\"keyCode\": 49}", "{\"keyCode\": 49.5, \"modifiers\": [\"control\"]}",
      "{\"keyCode\": 200, \"modifiers\": [\"control\"]}",
      "{\"keyCode\": -1, \"modifiers\": [\"control\"]}",
      "{\"keyCode\": 49, \"modifiers\": [\"hyper\"]}",
      "{\"keyCode\": 49, \"modifiers\": \"control\"}",
      "{\"keyCode\": 40, \"modifiers\": []}", "{\"keyCode\": 49, \"modifiers\": [\"command\"]}",
      "{\"keyCode\": true, \"modifiers\": [\"control\"]}",
    ]
    for value in values {
      let fixture = try Self.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Self.writeFile("{\"schemaVersion\": 1, \"globalShortcut\": \(value)}\n", in: fixture)
      let loaded = try await fixture.store.load()
      #expect(loaded.state == .saved, "\(value)")
      #expect(loaded.droppedShortcut, "\(value)")
      #expect(loaded.preferences.globalShortcut == nil, "\(value)")
      let recorded = try await fixture.store.setGlobalShortcut(Self.controlOptionSpace)
      #expect(recorded.wrote, "\(value)")
      #expect(recorded.backup?.lastPathComponent == Self.backupName, "\(value)")
      #expect(try await fixture.store.load().preferences.globalShortcut == Self.controlOptionSpace)
    } // End of loop over unusable values
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.writeFile("{\"schemaVersion\": 1, \"globalShortcut\": \"x\"}\n", in: fixture)
    let cleared = try await fixture.store.setGlobalShortcut(nil)
    #expect(cleared.wrote)
    #expect(try Self.object(at: fixture.file)["globalShortcut"] == nil)
  } // End of func unusableShortcutValuesAreDropped()

  /// Keys muxFinder does not know are ignored when read and kept when written; the file's
  /// order and spacing become the store's (sorted keys, pretty-printed).
  @Test func keepsUnknownKeys() async throws {
    let fixture = try Self.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Self.writeFile(
      "{\"futureSetting\": {\"nested\": [1, \"two\", null, true]}, \"schemaVersion\": 1, "
        + "\"zeta\": \"z/w\"}\n", in: fixture)
    let loaded = try await fixture.store.load()
    #expect(loaded.state == .saved && loaded.preferences.globalShortcut == nil)
    let recorded = try await fixture.store.setGlobalShortcut(Self.commandShiftF19)
    #expect(recorded.wrote && recorded.backup == nil)
    var object = try Self.object(at: fixture.file)
    let future = try #require(object["futureSetting"] as? [String: Any])
    let nested = try #require(future["nested"] as? [Any])
    #expect(nested.count == 4 && nested[1] as? String == "two" && nested[2] is NSNull)
    #expect(object["zeta"] as? String == "z/w")
    #expect(try String(contentsOf: fixture.file, encoding: .utf8).contains("\"z/w\""))
    _ = try await fixture.store.setGlobalShortcut(nil)
    object = try Self.object(at: fixture.file)
    #expect(object["futureSetting"] != nil && object["zeta"] as? String == "z/w")
    #expect(object["globalShortcut"] == nil && object["schemaVersion"] as? Int == 1)
  } // End of func keepsUnknownKeys()

  /// A file another program wrote between the store's read and its publication is kept as a
  /// backup (0600), never lost; a file the store wrote itself is replaced without one.
  @Test func keepsAFileChangedDuringAWriteAsABackup() async throws {
    let base = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    let file = directory.appending(path: PreferencesStore.fileName)
    let outside = "{\"schemaVersion\": 1, \"other\": 1}\n"
    let writes = OSAllocatedUnfairLock(initialState: 0)
    let store = PreferencesStore(
      fileURL: file, owner: geteuid(), now: { Self.backupDate },
      beforePublishing: {
        let write = writes.withLock { count -> Int in
          count += 1
          return count
        }
        if write == 2 { try? HostStoreTests.writeFile(Data(outside.utf8), to: file) }
      })
    let first = try await store.setGlobalShortcut(Self.controlOptionSpace)
    #expect(first.wrote && first.backup == nil)
    let second = try await store.setGlobalShortcut(Self.commandShiftF19)
    #expect(second.backup?.lastPathComponent == Self.backupName)
    let backup = directory.appending(path: Self.backupName)
    #expect(try String(contentsOf: backup, encoding: .utf8) == outside)
    #expect(try LaunchTestSupport.permissions(of: backup) == 0o600)
    #expect(
      try await PreferencesStore(fileURL: file).load().preferences.globalShortcut
        == Self.commandShiftF19)
  } // End of func keepsAFileChangedDuringAWriteAsABackup()

  /// Another muxFinder holding the lock makes a change wait, then `busy`; nothing is written.
  @Test func busyLockRefusesTheChange() async throws {
    let base = try TestSupport.makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: base) }
    let directory = base.appending(path: "muxFinder", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = directory.appending(path: PreferencesStore.fileName)
    let store = PreferencesStore(
      fileURL: file, owner: geteuid(), now: { Self.backupDate }, lockWait: .milliseconds(50))
    let folder = open(directory.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    #expect(folder >= 0)
    defer { close(folder) }
    let held = try PrivateStorage.acquireLock(
      named: PreferencesStore.lockFileName, in: folder, owner: geteuid(), wait: .zero)
    defer { close(held) }
    await #expect(throws: PreferencesStoreError.busy) {
      try await store.setGlobalShortcut(Self.controlOptionSpace)
    }
    #expect(!LaunchTestSupport.exists(file))
  } // End of func busyLockRefusesTheChange()

  /// The production store is `preferences.json` in muxFinder's folder; building it reads and
  /// creates nothing.
  @Test func productionPath() {
    let root = URL(fileURLWithPath: "/private/tmp/mfx-not-created", isDirectory: true)
    let store = PreferencesStore(paths: AppPaths(applicationSupportDirectory: root))
    #expect(
      store.fileURL.path(percentEncoded: false) == "/private/tmp/mfx-not-created/preferences.json")
    #expect(!LaunchTestSupport.exists(root))
    #expect(PreferencesStore().fileURL.lastPathComponent == "preferences.json")
    #expect(PreferencesStore().directoryURL.lastPathComponent == AppPaths.directoryName)
  }

  /// The in-memory store keeps the shortcut, counts real changes and can be made to fail.
  @Test func inMemoryStore() async throws {
    let store = InMemoryPreferencesStore()
    #expect(await store.load() == PreferencesLoadResult(preferences: Preferences(), state: .saved))
    _ = try await store.setGlobalShortcut(Self.controlOptionSpace)
    _ = try await store.setGlobalShortcut(Self.controlOptionSpace)
    #expect(await store.changeCount == 1)
    #expect(await store.load().preferences.globalShortcut == Self.controlOptionSpace)
    await store.setFailure(.busy)
    await #expect(throws: PreferencesStoreError.busy) { try await store.setGlobalShortcut(nil) }
    #expect(await store.preferences.globalShortcut == Self.controlOptionSpace)
  }

  /// Codes and messages hold no file contents.
  @Test func errorCodesAndMessages() {
    #expect(PreferencesStoreError.fileNotUsable(.notJSON).code == "fileNotUsable.notJSON")
    #expect(
      PreferencesStoreError.fileNotUsable(.unsafe(.permissionsTooOpen)).code
        == "fileNotUsable.unsafe.permissionsTooOpen")
    #expect(PreferencesFileProblem.newerSchemaVersion(3).message.contains("format 3"))
    #expect(PreferencesStoreError.busy.errorDescription?.contains("Another muxFinder") == true)
  }
}
