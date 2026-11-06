import Foundation
import MuxFinderCore
import Testing

@testable import MuxFinderUI

/// Settings › Directories' folder search setting (PLAN.md D32, D36, Phase I-10b): "Search
/// folders in" read when the window opens (`home` by default), saved at once through the
/// preferences store (in memory, or `PreferencesStore` on a private folder; never
/// `UserDefaults`), a failed save brought back, an unusable file shown and its choice off until
/// "Try again" finds it fixed; "Open Spotlight settings" recorded, never opened; the gallery's
/// states.
@Suite("Settings: folder search scope")
@MainActor
struct SettingsFolderSearchTests {
  /// Shorthand.
  typealias Support = SettingsTestSupport

  /// A Settings model over `preferences`, its window opened, and its seam recorder.
  static func model(
    preferences: (any PreferencesStoring)?
  ) async -> (SettingsModel, SeamRecorder) {
    let seams = SeamRecorder()
    var environment = Support.environment(
      store: FakeHostListStore(Support.loaded([])), seams: seams)
    environment.preferences = preferences
    let model = SettingsModel(environment: environment)
    await model.windowDidOpen()
    return (model, seams)
  } // End of static func model(preferences:)

  /// With nothing stored the scope is Home folder; choosing Whole disk saves it at once and a
  /// fresh read finds it; choosing the same again writes nothing.
  @Test func defaultsToHomeAndSavesAtOnce() async {
    let store = InMemoryPreferencesStore()
    let (model, _) = await Self.model(preferences: store)
    #expect(model.folderSearchScope == .home)
    #expect(model.canChangeFolderSearchScope)
    #expect(model.folderSearchScopeProblem == nil)
    #expect(await model.setFolderSearchScope(.disk))
    #expect(model.folderSearchScope == .disk)
    #expect(await store.preferences.folderSearchScope == .disk)
    #expect(await !model.setFolderSearchScope(.disk))
    #expect(await store.changeCount == 1)
    let (reopened, _) = await Self.model(preferences: store)
    #expect(reopened.folderSearchScope == .disk)
    #expect(FolderSearchScope.home.title == "Home folder")
    #expect(FolderSearchScope.disk.title == "Whole disk")
  } // End of func defaultsToHomeAndSavesAtOnce()

  /// The round trip through `PreferencesStore` on a private folder: the file holds
  /// `"folderSearchScope": "disk"`, which a new window reads.
  @Test func roundTripThroughAPrivateFolder() async throws {
    let folder = try ShortcutTestSupport.privatePreferencesFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let (model, _) = await Self.model(preferences: PreferencesStore(fileURL: folder.file))
    #expect(model.folderSearchScope == .home)
    #expect(await model.setFolderSearchScope(.disk))
    let object = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.file))
    #expect((object as? [String: Any])?["folderSearchScope"] as? String == "disk")
    let (reopened, _) = await Self.model(preferences: PreferencesStore(fileURL: folder.file))
    #expect(reopened.folderSearchScope == .disk)
  } // End of func roundTripThroughAPrivateFolder()

  /// Quitting right after a pick waits for its save (a slow disk): the picker shows the new
  /// scope at once, a second pick while the save runs is refused (the choice is off, so the
  /// scope shown is the one being saved), and `shutdown()` returns only once the store holds
  /// the pick.
  @Test func quittingWaitsForTheScopeSave() async {
    let store = GatedPreferencesStore()
    let (model, _) = await Self.model(preferences: store)
    #expect(model.folderSearchScope == .home)
    let save = model.chooseFolderSearchScope(.disk)
    #expect(save != nil)
    #expect(model.folderSearchScope == .disk && model.isSavingFolderSearchScope)
    #expect(!model.canChangeFolderSearchScope)
    #expect(await UITestSupport.waitUntil { await store.scopeSavesStarted == 1 })
    #expect(model.chooseFolderSearchScope(.home) == nil)
    #expect(await !model.setFolderSearchScope(.home))
    #expect(model.folderSearchScope == .disk)
    let quit = Task { () -> FolderSearchScope in
      await model.shutdown()
      return await store.preferences.folderSearchScope
    }
    try? await Task.sleep(for: .milliseconds(30))
    await store.release()
    #expect(await quit.value == .disk, "shutdown returned only once the store held the pick")
    #expect(await store.scopeSavesStarted == 1)
    #expect(!model.isSavingFolderSearchScope && model.folderSearchScope == .disk)
    #expect(await save?.value == true)
    #expect(model.chooseFolderSearchScope(.home) == nil, "nothing saves after quitting")
  } // End of func quittingWaitsForTheScopeSave()

  /// A save that fails brings the previous scope back and says why; the next one may succeed.
  @Test func aFailedSaveBringsThePreviousScopeBack() async {
    let store = InMemoryPreferencesStore()
    await store.setFailure(.busy)
    let (model, _) = await Self.model(preferences: store)
    #expect(await !model.setFolderSearchScope(.disk))
    #expect(model.folderSearchScope == .home)
    #expect(model.folderSearchScopeProblem?.hasPrefix("muxFinder couldn't save") == true)
    #expect(model.canChangeFolderSearchScope, "busy is no unusable file")
    await store.setFailure(nil)
    #expect(await model.setFolderSearchScope(.disk))
    #expect(model.folderSearchScopeProblem == nil)
  } // End of func aFailedSaveBringsThePreviousScopeBack()

  /// An unusable preferences file reads as Home folder, says so and turns the choice off; "Try
  /// again" once it is moved away turns it back on. An unreadable folder does the same.
  @Test func anUnusableFileTurnsTheChoiceOff() async throws {
    let folder = try ShortcutTestSupport.privatePreferencesFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    try ShortcutTestSupport.writePrivateFile("not json", to: folder.file)
    let (model, _) = await Self.model(preferences: PreferencesStore(fileURL: folder.file))
    #expect(model.folderSearchScope == .home)
    #expect(!model.isFolderSearchScopeFileUsable && !model.canChangeFolderSearchScope)
    #expect(model.folderSearchScopeProblem?.contains("Try again") == true)
    #expect(await !model.setFolderSearchScope(.disk))
    try FileManager.default.removeItem(at: folder.file)
    await model.loadFolderSearchScope()
    #expect(model.isFolderSearchScopeFileUsable && model.folderSearchScopeProblem == nil)
    #expect(await model.setFolderSearchScope(.disk))

    let (unreadable, _) = await Self.model(preferences: FailingPreferencesStore())
    #expect(unreadable.folderSearchScope == .home)
    #expect(!unreadable.canChangeFolderSearchScope)
    #expect(unreadable.folderSearchScopeProblem?.contains("settings folder") == true)
  } // End of func anUnusableFileTurnsTheChoiceOff()

  /// Without a store (every mode but normal, the tests of other parts) nothing is read and the
  /// choice is off; "Open Spotlight settings" goes through the URL seam.
  @Test func withoutAStoreAndTheSpotlightLink() async {
    let (model, seams) = await Self.model(preferences: nil)
    #expect(model.folderSearchScope == .home)
    #expect(!model.canChangeFolderSearchScope)
    #expect(await !model.setFolderSearchScope(.disk))
    model.openSpotlightSettings()
    #expect(seams.openedURLs == [FolderSearchSection.spotlightSettingsURL])
  }

  /// The gallery's Directories states: the folder search set to Whole disk, and an unusable
  /// preferences file with the choice off; fixtures change nothing.
  @Test func galleryFixtures() async {
    let disk = SettingsModel(fixture: SettingsFixtures.folderSearch)
    #expect(disk.selectedTab == .directories)
    #expect(disk.folderSearchScope == .disk && disk.canChangeFolderSearchScope)
    #expect(await !disk.setFolderSearchScope(.home))
    #expect(disk.folderSearchScope == .disk)
    let unusable = SettingsModel(fixture: SettingsFixtures.folderSearchUnusable)
    #expect(!unusable.canChangeFolderSearchScope)
    #expect(unusable.folderSearchScopeProblem?.contains("preferences file") == true)
    #expect(SettingsFixtures.all.contains { $0.id == SettingsFixtures.folderSearch.id })
    #expect(SettingsFixtures.all.contains { $0.id == SettingsFixtures.folderSearchUnusable.id })
  } // End of func galleryFixtures()
}
