import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// `checkForUpdatesAutomatically` in `preferences.json` (PLAN.md D32, D39), through
/// `PreferencesStore` on a private folder and `InMemoryPreferencesStore`: on by default, the
/// round trip, changes that write nothing, a value that is not a boolean, the unusable-file
/// rule and other keys kept.
@Suite("Update check preference")
struct UpdateCheckPreferenceTests {
  /// The fixtures and helpers of the preferences store tests.
  typealias Store = PreferencesStoreTests

  /// No file, no value, `null` and any value that is not a JSON boolean read as on.
  @Test func defaultsToOn() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #expect(try await fixture.store.load().preferences.checkForUpdatesAutomatically)
    for text in [
      "{\"schemaVersion\": 1}\n",
      "{\"schemaVersion\": 1, \"checkForUpdatesAutomatically\": null}\n",
      "{\"schemaVersion\": 1, \"checkForUpdatesAutomatically\": 0}\n",
      "{\"schemaVersion\": 1, \"checkForUpdatesAutomatically\": \"false\"}\n",
      "{\"schemaVersion\": 1, \"checkForUpdatesAutomatically\": {}}\n",
    ] {
      try Store.writeFile(text, in: fixture)
      let loaded = try await fixture.store.load()
      #expect(loaded.state == .saved, "\(text)")
      #expect(loaded.preferences.checkForUpdatesAutomatically, "\(text)")
    } // End of loop over files without a usable value
    try Store.writeFile(
      "{\"schemaVersion\": 1, \"checkForUpdatesAutomatically\": false}\n", in: fixture)
    #expect(try await !fixture.store.load().preferences.checkForUpdatesAutomatically)
    #expect(Preferences().checkForUpdatesAutomatically)
  } // End of func defaultsToOn()

  /// Turning it off writes `false` (0600, under the lock) that loads back; on again writes
  /// `true`; the other keys stay as they were.
  @Test func roundTrip() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    _ = try await fixture.store.setFolderSearchScope(.disk)
    let off = try await fixture.store.setCheckForUpdatesAutomatically(false)
    #expect(off.wrote && off.backup == nil)
    #expect(!off.preferences.checkForUpdatesAutomatically)
    #expect(off.preferences.folderSearchScope == .disk)
    #expect(try LaunchTestSupport.permissions(of: fixture.file) == 0o600)
    let object = try Store.object(at: fixture.file)
    #expect(JSONValue.boolean(object["checkForUpdatesAutomatically"]) == false)
    #expect(object["folderSearchScope"] as? String == "disk")
    let fresh = PreferencesStore(fileURL: fixture.file)
    #expect(try await !fresh.load().preferences.checkForUpdatesAutomatically)
    let on = try await fresh.setCheckForUpdatesAutomatically(true)
    #expect(on.wrote)
    #expect(
      JSONValue.boolean(try Store.object(at: fixture.file)["checkForUpdatesAutomatically"]) == true)
    _ = try await fixture.store.setTerminal("ghostty")
    let loaded = try await fixture.store.load().preferences
    #expect(
      loaded
        == Preferences(
          folderSearchScope: .disk, terminal: "ghostty", checkForUpdatesAutomatically: true))
  } // End of func roundTrip()

  /// On with no file creates nothing; on with no value, or the value the file holds, writes
  /// nothing.
  @Test func unchangedChoicesWriteNothing() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    #expect(!(try await fixture.store.setCheckForUpdatesAutomatically(true)).wrote)
    #expect(!LaunchTestSupport.exists(fixture.directory))
    try Store.writeFile("{\"schemaVersion\": 1}\n", in: fixture)
    let bare = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(!(try await fixture.store.setCheckForUpdatesAutomatically(true)).wrote)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == bare)
    _ = try await fixture.store.setCheckForUpdatesAutomatically(false)
    let after = try HostStoreTests.snapshot(of: fixture.directory)
    #expect(!(try await fixture.store.setCheckForUpdatesAutomatically(false)).wrote)
    #expect(try HostStoreTests.snapshot(of: fixture.directory) == after)
  } // End of func unchangedChoicesWriteNothing()

  /// A value that is not a boolean reads as on and is kept by other changes; saving the toggle
  /// replaces it, even with on.
  @Test func oddValueIsKeptUntilSaved() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Store.writeFile(
      "{\"schemaVersion\": 1, \"checkForUpdatesAutomatically\": \"no\"}\n", in: fixture)
    _ = try await fixture.store.setFolderSearchScope(.disk)
    #expect(try Store.object(at: fixture.file)["checkForUpdatesAutomatically"] as? String == "no")
    let on = try await fixture.store.setCheckForUpdatesAutomatically(true)
    #expect(on.wrote)
    #expect(
      JSONValue.boolean(try Store.object(at: fixture.file)["checkForUpdatesAutomatically"]) == true)
  } // End of func oddValueIsKeptUntilSaved()

  /// An unusable file refuses the change and stays as it is.
  @Test func unusableFileRefusesTheChange() async throws {
    let fixture = try Store.makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.base) }
    try Store.writeFile("not json", in: fixture)
    let before = try Data(contentsOf: fixture.file)
    await #expect(throws: PreferencesStoreError.fileNotUsable(.notJSON)) {
      try await fixture.store.setCheckForUpdatesAutomatically(false)
    }
    #expect(try Data(contentsOf: fixture.file) == before)
    #expect(try await fixture.store.load().preferences.checkForUpdatesAutomatically)
  } // End of func unusableFileRefusesTheChange()

  /// The in-memory store keeps the toggle and counts real changes.
  @Test func inMemory() async throws {
    let store = InMemoryPreferencesStore()
    #expect(await store.load().preferences.checkForUpdatesAutomatically)
    _ = try await store.setCheckForUpdatesAutomatically(true)
    #expect(await store.changeCount == 0)
    _ = try await store.setCheckForUpdatesAutomatically(false)
    #expect(await store.changeCount == 1)
    #expect(await !store.preferences.checkForUpdatesAutomatically)
    let setting: any UpdateCheckSettingStoring = PreferencesStore(
      fileURL: URL(fileURLWithPath: "/private/tmp/none/preferences.json"))
    #expect(setting is PreferencesStore)
  } // End of func inMemory()
}
