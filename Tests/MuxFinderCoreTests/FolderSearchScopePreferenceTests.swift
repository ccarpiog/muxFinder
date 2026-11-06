import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The folder search scope in `preferences.json` (PLAN.md D32, D36), through `PreferencesStore`
/// on a private folder and `InMemoryPreferencesStore`: the default, the round trip, changes that
/// write nothing, an unknown value, the unusable-file rule and other keys kept.
@Suite("Folder search scope preference")
struct FolderSearchScopePreferenceTests {
  /// The fixtures and helpers of the preferences store tests.
  typealias Store = PreferencesStoreTests

  /// No file, no value, `null` and a value that is not a string all read as `home`.
  @Test func defaultsToHome() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #expect(try await fixture.store.load().preferences.folderSearchScope == .home)
    for text in [
      "{\"schemaVersion\": 1}\n", "{\"schemaVersion\": 1, \"folderSearchScope\": null}\n",
      "{\"schemaVersion\": 1, \"folderSearchScope\": 5}\n",
      "{\"schemaVersion\": 1, \"folderSearchScope\": \"HOME\"}\n",
    ] {
      try Store.writeFile(text, in: fixture)
      let loaded = try await fixture.store.load()
      #expect(loaded.state == .saved, "\(text)")
      #expect(loaded.preferences.folderSearchScope == .home, "\(text)")
      #expect(!loaded.droppedShortcut)
    } // End of loop over files without a usable scope
    #expect(Preferences().folderSearchScope == .home)
    #expect(FolderSearchScope.standard == .home)
  } // End of func defaultsToHome()

  /// Choosing the whole disk writes `"folderSearchScope": "disk"` (0600, under the lock) that
  /// loads back; choosing home again writes `home`; the shortcut stays as it was.
  @Test func roundTrip() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try await fixture.store.setGlobalShortcut(PreferencesStoreTests.controlOptionSpace)
    let disk = try await fixture.store.setFolderSearchScope(.disk)
    #expect(disk.wrote && disk.backup == nil)
    #expect(disk.preferences.folderSearchScope == .disk)
    #expect(disk.preferences.globalShortcut == PreferencesStoreTests.controlOptionSpace)
    #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
    let object = try Store.object(at: fixture.file)
    #expect(object["folderSearchScope"] as? String == "disk")
    #expect(object["schemaVersion"] as? Int == 1)
    #expect(object["globalShortcut"] != nil)
    let fresh = PreferencesStore(fileURL: fixture.file)
    #expect(try await fresh.load().preferences.folderSearchScope == .disk)
    let home = try await fresh.setFolderSearchScope(.home)
    #expect(home.wrote)
    #expect(try Store.object(at: fixture.file)["folderSearchScope"] as? String == "home")
    let loaded = try await fixture.store.load()
    #expect(
      loaded.preferences == Preferences(globalShortcut: PreferencesStoreTests.controlOptionSpace))
    _ = try await fixture.store.setGlobalShortcut(nil)
    #expect(try Store.object(at: fixture.file)["folderSearchScope"] as? String == "home")
  } // End of func roundTrip()

  /// Home with no file creates nothing; home with no value, or the value the file holds,
  /// writes nothing.
  @Test func unchangedChoicesWriteNothing() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #expect(!(try await fixture.store.setFolderSearchScope(.home)).wrote)
    #expect(!LaunchTestSupport.exists(fixture.directory))
    try Store.writeFile("{\"schemaVersion\": 1}\n", in: fixture)
    let bare = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(!(try await fixture.store.setFolderSearchScope(.home)).wrote)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == bare)
    _ = try await fixture.store.setFolderSearchScope(.disk)
    let after = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(!(try await fixture.store.setFolderSearchScope(.disk)).wrote)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == after)
  } // End of func unchangedChoicesWriteNothing()

  /// An unknown value reads as home and is never rewritten by another change (a shortcut
  /// write keeps it as it is, with no backup); choosing a scope replaces it, again with no
  /// backup, since the file was fully usable.
  @Test func leavesAnUnknownValueUntilASave() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Store.writeFile(
      "{\"schemaVersion\": 1, \"folderSearchScope\": \"everywhere\", \"other\": [1]}\n",
      in: fixture)
    #expect(try await fixture.store.load().preferences.folderSearchScope == .home)
    let shortcut = try await fixture.store.setGlobalShortcut(
      PreferencesStoreTests.controlOptionSpace)
    #expect(shortcut.wrote && shortcut.backup == nil)
    #expect(shortcut.preferences.folderSearchScope == .home)
    #expect(try Store.object(at: fixture.file)["folderSearchScope"] as? String == "everywhere")
    let scope = try await fixture.store.setFolderSearchScope(.home)
    #expect(scope.wrote && scope.backup == nil)
    let object = try Store.object(at: fixture.file)
    #expect(object["folderSearchScope"] as? String == "home")
    #expect(object["other"] as? [Int] == [1])
    #expect(object["globalShortcut"] != nil)
    #expect(
      try LaunchTestSupport.names(in: fixture.directory)
        == [PreferencesStore.fileName, PreferencesStore.lockFileName].sorted())
  } // End of func leavesAnUnknownValueUntilASave()

  /// A file that cannot be used refuses the change and stays exactly as it is.
  @Test func unusableFilesRefuseTheChange() async throws {
    for (text, problem) in [
      (
        "{\"schemaVersion\": 2, \"folderSearchScope\": \"disk\"}",
        PreferencesFileProblem.newerSchemaVersion(2)
      ),
      ("not json", .notJSON),
    ] {
      let fixture = try Store.makeFixture()
      defer { try? FileManager.default.removeItem(at: fixture.base) }
      try Store.writeFile(text, in: fixture)
      let before = try HostStoreTests.snapshot(of: fixture.directory)
      #expect(try await fixture.store.load().preferences.folderSearchScope == .home)
      await #expect(throws: PreferencesStoreError.fileNotUsable(problem)) {
        try await fixture.store.setFolderSearchScope(.disk)
      }
      await #expect(throws: PreferencesStoreError.fileNotUsable(problem)) {
        try await fixture.store.setFolderSearchScope(.home)
      }
      #expect(try HostStoreTests.snapshot(of: fixture.directory) == before)
    } // End of loop over unusable files
  } // End of func unusableFilesRefuseTheChange()

  /// The in-memory store keeps the scope, counts real changes and fails when told.
  @Test func inMemoryStore() async throws {
    let store = InMemoryPreferencesStore()
    #expect(await store.load().preferences.folderSearchScope == .home)
    #expect(try await store.setFolderSearchScope(.disk).preferences.folderSearchScope == .disk)
    _ = try await store.setFolderSearchScope(.disk)
    #expect(await store.changeCount == 1)
    #expect(await store.load().preferences == Preferences(folderSearchScope: .disk))
    await store.setFailure(.busy)
    await #expect(throws: PreferencesStoreError.busy) {
      try await store.setFolderSearchScope(.home)
    }
    #expect(await store.preferences.folderSearchScope == .disk)
  } // End of func inMemoryStore()
}
