import Foundation
import MuxFinderCore
import Testing

@testable import MuxFinderUI

/// Settings' Directories tab (PLAN.md D31, D23's Save and Revert): the saved list loads with
/// the window, "Add" is checked inline, entries are removed and reordered on a working copy,
/// "Save" merges the edits into the saved list as the store holds it (recents untouched, what
/// changed elsewhere kept) and "Revert" brings it back; an unusable file shows its notice and
/// offers no edit; failures are logged by code.
@Suite("Settings: directories")
@MainActor
struct SettingsDirectoriesTests {
  /// Shorthand.
  typealias Support = SettingsTestSupport

  /// A Settings model over `store` (and fakes for the rest), its window opened.
  static func openModel(
    _ store: any DirectoryStoring,
    diagnostics: DiagnosticsLog = DiagnosticsLog(writesToSystemLog: false)
  ) async -> SettingsModel {
    var environment = Support.environment(
      store: FakeHostListStore(Support.loaded([Support.sshHost("Saturno")])),
      diagnostics: diagnostics)
    environment.directories = store
    let model = SettingsModel(environment: environment)
    await model.windowDidOpen()
    return model
  } // End of func openModel(_:diagnostics:)

  /// A private folder holding a `directories.json` with `contents` and `mode` (removed by the
  /// caller).
  static func privateFile(_ contents: String, mode: mode_t) throws -> (base: URL, file: URL) {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "mfx-settings-dirs-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: base, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    let file = base.appending(path: DirectoryStore.fileName)
    try Data(contents.utf8).write(to: file)
    guard chmod(file.path(percentEncoded: false), mode) == 0 else {
      throw CocoaError(.fileWriteNoPermission)
    }
    return (base, file)
  } // End of static func privateFile(_:mode:)

  /// Opening the window loads the saved list into the working copy: editable, nothing to save.
  @Test func openingLoadsTheSavedList() async {
    let host = UUID()
    let store = InMemoryDirectoryStore(
      DirectoryLists(saved: ["~/b", "~/a"], recent: [host: ["~/r"]]))
    let model = await Self.openModel(store)
    #expect(model.directoryStatus == .usable(droppedEntryCount: 0))
    #expect(model.savedDirectories == ["~/b", "~/a"])
    #expect(model.directoryDraft == ["~/b", "~/a"])
    #expect(model.areDirectoriesEditable)
    #expect(!model.isDirectoryListDirty && !model.canSaveDirectories)
    #expect(model.directoryNotice == nil)
    #expect(SettingsModel.Tab.directories.title == "Directories")
  } // End of func openingLoadsTheSavedList()

  /// "Add" is checked inline: nothing while the field is empty; a rule the directory breaks,
  /// a directory in the list already (exact string) and a full list are refused with their
  /// message; a good one is appended as typed and the field empties.
  @Test func addIsCheckedInline() async {
    let model = await Self.openModel(
      InMemoryDirectoryStore(DirectoryLists(saved: ["~/caf\u{E9}"], recent: [:])))
    #expect(model.newDirectoryIssue == nil && !model.canAddDirectory)
    model.newDirectory = "~/a\nb"
    #expect(model.newDirectoryIssue == ValidationError.workingDirectoryContainsLineBreak.message)
    model.addDirectory()
    #expect(model.directoryDraft == ["~/caf\u{E9}"])
    model.newDirectory = "~/caf\u{E9}"
    #expect(model.newDirectoryIssue == "This directory is in the list already.")
    #expect(!model.canAddDirectory)
    model.newDirectory = "~/cafe\u{301}"
    #expect(model.newDirectoryIssue == nil, "another spelling is another entry")
    model.newDirectory = " ~/projects/site ü #1; "
    #expect(model.canAddDirectory)
    model.addDirectory()
    #expect(model.directoryDraft == ["~/caf\u{E9}", " ~/projects/site ü #1; "])
    #expect(model.newDirectory.isEmpty)
    #expect(model.isDirectoryListDirty && model.canSaveDirectories)

    let full = await Self.openModel(
      InMemoryDirectoryStore(DirectoryLists(saved: (1...50).map { "~/d\($0)" }, recent: [:])))
    full.newDirectory = "~/one-more"
    #expect(full.newDirectoryIssue == DirectoryListError.tooManySaved.message)
    full.addDirectory()
    #expect(full.directoryDraft.count == 50)
  } // End of func addIsCheckedInline()

  /// Entries move up and down (never past an end) and are removed, on the working copy only.
  @Test func removeAndReorder() async {
    let store = InMemoryDirectoryStore(DirectoryLists(saved: ["~/a", "~/b", "~/c"], recent: [:]))
    let model = await Self.openModel(store)
    model.moveDirectory(at: 0, by: 1)
    #expect(model.directoryDraft == ["~/b", "~/a", "~/c"])
    model.moveDirectory(at: 2, by: -1)
    #expect(model.directoryDraft == ["~/b", "~/c", "~/a"])
    model.moveDirectory(at: 0, by: -1)
    model.moveDirectory(at: 2, by: 1)
    model.moveDirectory(at: 7, by: 1)
    #expect(model.directoryDraft == ["~/b", "~/c", "~/a"])
    model.removeDirectory(at: 1)
    model.removeDirectory(at: 9)
    #expect(model.directoryDraft == ["~/b", "~/a"])
    #expect(model.savedDirectories == ["~/a", "~/b", "~/c"])
    #expect(await store.lists.saved == ["~/a", "~/b", "~/c"])
    #expect(await store.changeCount == 0)
  } // End of func removeAndReorder()

  /// "Save" writes the edits in one change (nothing changed elsewhere, so the saved list becomes
  /// the working copy), leaves the recents alone, tells the app, says "Saved." and logs the
  /// count only; "Revert" brings back the list as last saved.
  @Test func saveAndRevert() async {
    let host = UUID()
    let store = InMemoryDirectoryStore(
      DirectoryLists(saved: ["~/a", "~/b"], recent: [host: ["~/r"]]))
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let model = await Self.openModel(store, diagnostics: diagnostics)
    var told: [DirectoryLists] = []
    model.onDirectoriesSaved = { told.append($0) }
    model.removeDirectory(at: 0)
    model.newDirectory = "/Users/example/secret project"
    model.addDirectory()
    #expect(await model.saveDirectories())
    #expect(await store.lists.saved == ["~/b", "/Users/example/secret project"])
    #expect(await store.lists.recent(for: host) == ["~/r"])
    #expect(await store.changeCount == 1)
    #expect(model.savedDirectories == ["~/b", "/Users/example/secret project"])
    #expect(!model.isDirectoryListDirty)
    #expect(model.directorySaveNotice == "Saved.")
    #expect(told.map(\.saved) == [["~/b", "/Users/example/secret project"]])
    let details = await diagnostics.events().map(\.detail)
    #expect(details.contains("saved directories: 2"))
    #expect(details.allSatisfy { !$0.contains("secret") })

    model.moveDirectory(at: 0, by: 1)
    model.newDirectory = "~/half typed"
    #expect(model.isDirectoryListDirty)
    model.revertDirectories()
    #expect(model.directoryDraft == ["~/b", "/Users/example/secret project"])
    #expect(model.newDirectory.isEmpty && !model.isDirectoryListDirty)
    #expect(!(await model.saveDirectories()), "nothing to save")
    #expect(await store.changeCount == 1)
  } // End of func saveAndRevert()

  /// A save the store refuses keeps the working copy, says why and logs the code only.
  @Test func aRefusedSaveKeepsTheEdits() async {
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let model = await Self.openModel(FailingDirectoryStore(), diagnostics: diagnostics)
    model.newDirectory = "/Users/example/secret project"
    model.addDirectory()
    #expect(!(await model.saveDirectories()))
    #expect(model.directorySaveError?.hasPrefix("muxFinder couldn't save the directories.") == true)
    #expect(model.directoryDraft == ["/Users/example/secret project"])
    #expect(model.isDirectoryListDirty && model.areDirectoriesEditable)
    let details = await diagnostics.events().map(\.detail)
    #expect(details.contains("saved directories not saved: systemCallFailed.renameatx_np.\(EIO)"))
    #expect(details.allSatisfy { !$0.contains("secret") })
  } // End of func aRefusedSaveKeepsTheEdits()

  /// An unusable file (valid lists, but readable by others) shows its notice with "Try again"
  /// and offers no edit: nothing is added or saved and the file keeps its bytes and mode. Once
  /// fixed, "Try again" loads it.
  @Test func anUnusableFileShowsItsNoticeAndOffersNoEdit() async throws {
    let contents = #"{"recent": {}, "saved": ["~/kept"], "schemaVersion": 1}"#
    let (base, file) = try Self.privateFile(contents, mode: 0o644)
    defer { try? FileManager.default.removeItem(at: base) }
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let model = await Self.openModel(DirectoryStore(fileURL: file), diagnostics: diagnostics)
    #expect(model.directoryStatus == .fileNotUsable(.unsafe(.permissionsTooOpen)))
    #expect(
      model.directoryNotice
        == DirectoryStoreNotice.fileNotUsed(.unsafe(.permissionsTooOpen)).message)
    #expect(model.offersDirectoryReload)
    #expect(!model.areDirectoriesEditable)
    #expect(model.directoryDraft.isEmpty)
    model.newDirectory = "~/new"
    #expect(!model.canAddDirectory)
    model.addDirectory()
    #expect(model.directoryDraft.isEmpty)
    #expect(!(await model.saveDirectories()))
    #expect(try Data(contentsOf: file) == Data(contents.utf8))
    let attributes = try FileManager.default.attributesOfItem(
      atPath: file.path(percentEncoded: false))
    #expect(attributes[.posixPermissions] as? Int == 0o644)
    #expect(
      await diagnostics.events().map(\.detail).contains(
        "directory list loaded: fileNotUsable.unsafe.permissionsTooOpen, 0 saved"))

    try #require(chmod(file.path(percentEncoded: false), 0o600) == 0)
    await model.loadDirectories()
    #expect(model.areDirectoriesEditable && !model.offersDirectoryReload)
    #expect(model.directoryDraft == ["~/kept"])
  } // End of func anUnusableFileShowsItsNoticeAndOffersNoEdit()

  /// A usable file with an entry left out is editable; its notice counts the entry and says the
  /// file is kept as a backup at the save, which then writes the list as shown.
  @Test func entriesLeftOutAreCountedAndTheFileIsBackedUp() async throws {
    let contents = #"{"recent": {}, "saved": ["~/kept", "~/a\nb"], "schemaVersion": 1}"#
    let (base, file) = try Self.privateFile(contents, mode: 0o600)
    defer { try? FileManager.default.removeItem(at: base) }
    let model = await Self.openModel(DirectoryStore(fileURL: file))
    #expect(model.directoryStatus == .usable(droppedEntryCount: 1))
    #expect(model.directoryNotice?.contains("left out") == true)
    #expect(model.directoryNotice?.contains("kept as a backup") == true)
    #expect(model.areDirectoriesEditable)
    model.newDirectory = "~/added"
    model.addDirectory()
    #expect(await model.saveDirectories())
    #expect(model.directoryNotice == nil)
    let names = try FileManager.default.contentsOfDirectory(
      atPath: base.path(percentEncoded: false))
    #expect(names.contains { $0.hasPrefix("directories.backup-") })
    let loaded = try await DirectoryStore(fileURL: file).load()
    #expect(loaded.lists.saved == ["~/kept", "~/added"])
  } // End of func entriesLeftOutAreCountedAndTheFileIsBackedUp()

  /// A change from New session's list: the saved list shown follows it while there are no
  /// unsaved edits; with edits only the list "Revert" brings back does.
  @Test func changesElsewhereFollowWithoutEdits() async {
    let model = await Self.openModel(
      InMemoryDirectoryStore(DirectoryLists(saved: ["~/a"], recent: [:])))
    model.directoriesChangedElsewhere(DirectoryLists(saved: ["~/a", "~/b"], recent: [:]))
    #expect(model.directoryDraft == ["~/a", "~/b"])
    #expect(!model.isDirectoryListDirty)
    model.removeDirectory(at: 0)
    model.directoriesChangedElsewhere(DirectoryLists(saved: ["~/a", "~/b", "~/c"], recent: [:]))
    #expect(model.directoryDraft == ["~/b"])
    #expect(model.savedDirectories == ["~/a", "~/b", "~/c"])
    model.revertDirectories()
    #expect(model.directoryDraft == ["~/a", "~/b", "~/c"])
  } // End of func changesElsewhereFollowWithoutEdits()

  /// Save merges (PLAN.md D31): with ~/a removed in the tab but not saved, New session saves
  /// ~/c, clears This Mac's recent directories and records a new one; Save then keeps ~/c and
  /// the new recent (neither lost nor reverted) and removes only ~/a, and the tab and New
  /// session's list both show what the store holds.
  @Test func saveKeepsWhatNewSessionChangedMeanwhile() async {
    let local = UITestSupport.localHost()
    let store = InMemoryDirectoryStore(
      DirectoryLists(saved: ["~/a", "~/b"], recent: [local.id: ["~/r1"]]))
    var settingsEnvironment = Support.environment(
      store: FakeHostListStore(UITestSupport.loaded([local])))
    settingsEnvironment.directories = store
    let harness = await AttachHarness.make(
      hosts: [local], settings: settingsEnvironment, directories: store)
    let model = harness.model
    let settings = model.settings
    await settings.windowDidOpen()
    settings.removeDirectory(at: 0)
    #expect(settings.directoryDraft == ["~/b"])

    model.newSession()
    await model.directoryRecordingsHandled()
    model.newSessionDraft.directory = "~/c"
    model.saveFieldDirectory()
    model.clearRecentDirectories()
    model.recordRecentDirectory("~/r2", for: local.id)
    await model.directoryRecordingsHandled()
    #expect(await store.lists.saved == ["~/a", "~/b", "~/c"])
    #expect(await store.lists.recent(for: local.id) == ["~/r2"])
    #expect(settings.savedDirectories == ["~/a", "~/b", "~/c"])
    #expect(settings.directoryDraft == ["~/b"], "unsaved edits stay")

    #expect(await settings.saveDirectories())
    #expect(await store.lists.saved == ["~/b", "~/c"])
    #expect(await store.lists.recent(for: local.id) == ["~/r2"])
    #expect(settings.savedDirectories == ["~/b", "~/c"])
    #expect(settings.directoryDraft == ["~/b", "~/c"])
    #expect(!settings.isDirectoryListDirty)
    #expect(model.directoryLists.saved == ["~/b", "~/c"])
    #expect(model.directoryLists.recent(for: local.id) == ["~/r2"])
    await model.shutdown()
  } // End of func saveKeepsWhatNewSessionChangedMeanwhile()

  /// Save merges under the store's lock with what another muxFinder (another store on the same
  /// file) changed since the tab loaded: its addition stays, its removal stays removed, and the
  /// tab's own removal and order hold.
  @Test func saveMergesAnotherMuxFindersChange() async throws {
    let contents = #"{"recent": {}, "saved": ["~/a", "~/b", "~/c"], "schemaVersion": 1}"#
    let (base, file) = try Self.privateFile(contents, mode: 0o600)
    defer { try? FileManager.default.removeItem(at: base) }
    let model = await Self.openModel(DirectoryStore(fileURL: file))
    model.removeDirectory(at: 0)
    model.moveDirectory(at: 1, by: -1)
    #expect(model.directoryDraft == ["~/c", "~/b"])
    let other = DirectoryStore(fileURL: file)
    _ = try await other.apply(.addSaved("~/d"), knownHosts: nil)
    _ = try await other.apply(.removeSaved("~/b"), knownHosts: nil)
    #expect(await model.saveDirectories())
    #expect(try await DirectoryStore(fileURL: file).load().lists.saved == ["~/c", "~/d"])
    #expect(model.directoryDraft == ["~/c", "~/d"])
    #expect(model.savedDirectories == ["~/c", "~/d"])
    #expect(!model.isDirectoryListDirty)
  } // End of func saveMergesAnotherMuxFindersChange()

  /// The app gives the Directories tab and New session's list the same store instance (the
  /// real `directories.json`; building the environment reads nothing).
  @Test func theAppSharesOneStore() {
    let production = AppEnvironment.production(rewritesProfilesAtLaunch: false)
    let popover = production.directories as? DirectoryStore
    let settings = production.settings?.directories as? DirectoryStore
    #expect(popover != nil && settings != nil)
    #expect(popover === settings)
    #expect(settings?.fileURL.lastPathComponent == DirectoryStore.fileName)
  }

  /// The Directories fixtures show unsaved edits with an inline issue and an unusable file;
  /// their models have no environment, so nothing is loaded or saved; synthetic paths only.
  @Test func fixturesNeverTouchAStore() async {
    let edits = SettingsModel(fixture: SettingsFixtures.directories)
    #expect(edits.selectedTab == .directories)
    #expect(edits.isDirectoryListDirty)
    #expect(edits.newDirectoryIssue == "This directory is in the list already.")
    #expect(!(await edits.saveDirectories()))
    await edits.loadDirectories()
    #expect(edits.directoryDraft == SettingsFixtures.directories.directoryDraft)
    let unusable = SettingsModel(fixture: SettingsFixtures.directoriesUnusable)
    #expect(unusable.directoryNotice != nil && !unusable.areDirectoriesEditable)
    let paths = SettingsFixtures.all.flatMap { $0.savedDirectories + ($0.directoryDraft ?? []) }
    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0.hasPrefix("~/") || $0.hasPrefix("/Volumes/Archive/") })
  } // End of func fixturesNeverTouchAStore()
}
