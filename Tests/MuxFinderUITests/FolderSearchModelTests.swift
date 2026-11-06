import Foundation
import MuxFinderCore
import Testing

@testable import MuxFinderUI

/// New session's folder search in the app model (PLAN.md D36, Phase I-10b), over
/// `FakeFolderSearchTransport` and a gated clock (no process, no Spotlight, no ssh): the channel
/// opens on the first searchable text and closes with the window, a host change, a quiet minute
/// and quitting; `/` and short texts send nothing; answers become the section; unusable paths
/// are dropped; a pick fills the field and never reopens the list; the scope is read for each
/// query; VoiceOver hears "Searching…" once and the count when it changes; the explanation's
/// links. Synthetic paths only.
@Suite("New session: folder search in the model")
@MainActor
struct FolderSearchModelTests {
  /// Shorthand.
  typealias Harness = FolderSearchHarness

  /// One character, a path, or spaces open nothing and send nothing (the list stays closed,
  /// there being no other entry); the second character opens This Mac's channel at once and
  /// the list with the folders section, searching.
  @Test func opensOnTheFirstSearchableText() async throws {
    let rig = await Harness.make()
    #expect(rig.model.isNewSessionShown)
    for text in ["p", "/p", "~/pr", "  "] {
      await rig.type(text)
      #expect(rig.model.directoryPickerContent?.folders == nil, "\(text)")
      #expect(!rig.model.directoryPicker.isOpen, "\(text)")
    }
    try await Task.sleep(for: .milliseconds(20))
    #expect(rig.transport.openedHosts.isEmpty)
    await rig.type("pr")
    #expect(rig.model.directoryPicker.opening == .typing)
    #expect(rig.folders?.status == .searching)
    #expect(rig.folders?.title == "Folders on Neptuno")
    let connection = await rig.opened(1)
    #expect(connection != nil)
    #expect(rig.transport.openedHosts == [.local])
    await rig.model.shutdown()
  } // End of func opensOnTheFirstSearchableText()

  /// The query goes after the header and the debounce; the answer becomes the section
  /// (`~/…` under the header's home, a path with a line feed dropped and counted); typing on
  /// shows "Searching…" at once, the latest text alone is sent.
  @Test func answersBecomeTheSection() async throws {
    let rig = await Harness.make()
    let connection = try #require(await rig.searched("pr"))
    #expect(connection.sentLines == ["1 home pr\n"])
    #expect(
      await rig.answer(
        connection, ["/Users/me/projects", "/Users/me/bad\nname", "/Volumes/Archive/pr"]))
    let found = try #require(rig.folders)
    #expect(found.status == .found)
    #expect(found.entries == ["~/projects", "/Volumes/Archive/pr"])
    #expect(found.droppedCount == 1)
    #expect(
      rig.model.directoryPickerContent?.items.prefix(3) == [
        .entry(.folders, "~/projects"), .entry(.folders, "/Volumes/Archive/pr"),
        .action(.folderSearchHelp),
      ])

    await rig.type("pro")
    #expect(rig.folders?.status == .searching)
    #expect(rig.folders?.entries == ["~/projects"], "the previous folder that still matches")
    await rig.type("proj")
    await rig.passDebounce()
    #expect(await rig.lines(connection, 2) == ["1 home pr\n", "2 home proj\n"])
    #expect(await rig.answer(connection, []))
    #expect(rig.folders?.status == .noneFound)
    #expect(rig.transport.connections.count == 1)
    await rig.model.shutdown()
  } // End of func answersBecomeTheSection()

  /// A path (`/`) or fewer than 2 characters typed before the debounce passed cancels the
  /// waiting query: nothing is sent, and the section is hidden.
  @Test func slashesAndShortTextSendNothing() async throws {
    let rig = await Harness.make()
    await rig.type("pr")
    let connection = try #require(await rig.opened(1))
    connection.emit(.header(Harness.header))
    #expect(await rig.debounceWaits(), "the query would go if the clock moved now")
    await rig.type("pr/")
    #expect(rig.folders == nil)
    rig.clock.advance(by: .milliseconds(150))
    await rig.type("p")
    rig.clock.advance(by: .milliseconds(150))
    try await Task.sleep(for: .milliseconds(30))
    #expect(connection.sentLines.isEmpty)
    #expect(!rig.model.directoryPicker.isOpen, "the typing's list closes with nothing to show")
    await rig.model.shutdown()
  } // End of func slashesAndShortTextSendNothing()

  /// Picking a folder found fills the field with it as shown (`~/…`) and closes the list,
  /// which does not reopen; nothing is announced and no query follows. The draft takes it as
  /// typed text.
  @Test func pickingAFolderFillsTheField() async throws {
    let rig = await Harness.make()
    let connection = try #require(await rig.searched("pr"))
    #expect(await rig.answer(connection, ["/Users/me/projects"]))
    let said = rig.said.said.count
    rig.model.pickDirectoryItem(.entry(.folders, "~/projects"))
    #expect(rig.model.newSessionDraft.directory == "~/projects")
    #expect(rig.model.newSessionDraft.directoryIssue == nil)
    #expect(!rig.model.directoryPicker.isOpen)
    #expect(rig.said.said.count == said)
    rig.clock.advance(by: .milliseconds(150))
    await rig.model.folderSearchRequestsHandled()
    try await Task.sleep(for: .milliseconds(20))
    #expect(connection.sentLines.count == 1)
    #expect(!rig.model.directoryPicker.isOpen)
    rig.model.pickDirectoryItem(.entry(.folders, "~/not-listed"))
    #expect(rig.model.newSessionDraft.directory == "~/projects")
    await rig.model.shutdown()
  } // End of func pickingAFolderFillsTheField()

  /// The keys reach the folders and "Missing a folder?", whose Return shows and hides the
  /// explanation with the list staying open; Return on a folder picks it.
  @Test func keysReachTheFoldersAndTheHelp() async throws {
    let rig = await Harness.make()
    let connection = try #require(await rig.searched("pr"))
    #expect(await rig.answer(connection, ["/Users/me/projects", "/srv/pr"]))
    #expect(rig.model.handleNewSessionKey(.down) == .handled)
    #expect(rig.model.highlightedDirectoryItem == .entry(.folders, "~/projects"))
    _ = rig.model.handleNewSessionKey(.down)
    _ = rig.model.handleNewSessionKey(.down)
    #expect(rig.model.highlightedDirectoryItem == .action(.folderSearchHelp))
    _ = rig.model.handleNewSessionKey(.open)
    #expect(rig.model.isFolderSearchHelpShown)
    #expect(rig.model.directoryPicker.isOpen)
    _ = rig.model.handleNewSessionKey(.open)
    #expect(!rig.model.isFolderSearchHelpShown)
    _ = rig.model.handleNewSessionKey(.up)
    _ = rig.model.handleNewSessionKey(.open)
    #expect(rig.model.newSessionDraft.directory == "/srv/pr")
    #expect(!rig.model.directoryPicker.isOpen)
    await rig.model.shutdown()
  } // End of func keysReachTheFoldersAndTheHelp()

  /// Closing the window (Cancel, Esc, ⌘W, the close button) closes the channel and forgets
  /// what it found and the explanation; the next window's first searchable text opens a new
  /// one.
  @Test func closingTheWindowClosesTheChannel() async throws {
    let rig = await Harness.make()
    let connection = try #require(await rig.searched("pr"))
    #expect(await rig.answer(connection, ["/Users/me/projects"]))
    rig.model.toggleFolderSearchHelp()
    rig.model.closeNewSession()
    #expect(await UITestSupport.waitUntil { connection.isClosed })
    #expect(rig.model.folderSearchState == nil && rig.model.folderSearchPrevious == nil)
    #expect(!rig.model.isFolderSearchHelpShown)
    await rig.model.folderSearchRequestsHandled()
    #expect(await UITestSupport.waitUntil { rig.model.folderSearchClosings.isEmpty })

    rig.model.newSession()
    #expect(rig.folders == nil)
    await rig.type("pr")
    #expect(rig.folders?.status == .searching, "nothing kept from the closed window")
    #expect(await rig.opened(2) != nil)
    await rig.model.shutdown()
  } // End of func closingTheWindowClosesTheChannel()

  /// A host change closes the old host's channel and searches the field's text on the new one
  /// at once (a channel for its destination), the section titled for it.
  @Test func aHostChangeClosesAndSearchesTheNewHost() async throws {
    let rig = await Harness.make()
    let first = try #require(await rig.searched("pr"))
    #expect(await rig.answer(first, ["/Users/me/projects"]))
    rig.model.newSessionDraft.hostID = rig.saturno.id
    #expect(await UITestSupport.waitUntil { first.isClosed })
    #expect(rig.folders?.title == "Folders on Saturno")
    #expect(rig.folders?.status == .searching)
    #expect(rig.folders?.entries.isEmpty == true, "nothing carried from another host")
    let second = try #require(await rig.opened(2))
    #expect(second.host == .ssh(destination: "saturno.example"))
    #expect(rig.transport.openedHosts == [.local, .ssh(destination: "saturno.example")])
    #expect(rig.model.newSessionDraft.directory == "pr")
    await rig.model.shutdown()
  } // End of func aHostChangeClosesAndSearchesTheNewHost()

  /// A quiet minute without a query closes the channel's process (the answer stays shown);
  /// the next text opens a new one.
  @Test func aQuietMinuteClosesTheProcess() async throws {
    let rig = await Harness.make()
    let connection = try #require(await rig.searched("pr"))
    #expect(await rig.answer(connection, ["/Users/me/projects"]))
    #expect(await rig.sleeps(1), "only the quiet minute waits")
    rig.clock.advance(by: .seconds(59))
    try await Task.sleep(for: .milliseconds(20))
    #expect(!connection.isClosed)
    rig.clock.advance(by: .seconds(1))
    #expect(await UITestSupport.waitUntil { connection.isClosed })
    #expect(rig.folders?.status == .found)
    await rig.type("pro")
    #expect(await rig.opened(2) != nil)
    await rig.model.shutdown()
  } // End of func aQuietMinuteClosesTheProcess()

  /// Quitting closes the channel and waits for it.
  @Test func quittingClosesTheChannel() async throws {
    let rig = await Harness.make()
    let connection = try #require(await rig.searched("pr"))
    await rig.model.shutdown()
    #expect(connection.isClosed)
    await rig.type("pro")
    try await Task.sleep(for: .milliseconds(20))
    #expect(rig.transport.connections.count == 1, "nothing opens after quitting")
  } // End of func quittingClosesTheChannel()

  /// The scope is read from the preferences for each query: `disk` as stored, `home` again
  /// once changed, `home` when the store holds none or cannot be read.
  @Test func theScopeIsReadForEachQuery() async throws {
    let store = InMemoryPreferencesStore(Preferences(folderSearchScope: .disk))
    let rig = await Harness.make(preferences: store)
    let connection = try #require(await rig.searched("pr"))
    #expect(connection.sentLines == ["1 disk pr\n"])
    #expect(await rig.answer(connection, []))
    _ = try await store.setFolderSearchScope(.home)
    await rig.type("pro")
    await rig.passDebounce()
    #expect(await rig.lines(connection, 2) == ["1 disk pr\n", "2 home pro\n"])
    await rig.model.shutdown()

    let fresh = await Harness.make(preferences: InMemoryPreferencesStore())
    #expect(try #require(await fresh.searched("pr")).sentLines == ["1 home pr\n"])
    await fresh.model.shutdown()
    let failing = FailingPreferencesStore()
    let unreadable = await Harness.make(preferences: failing)
    #expect(try #require(await unreadable.searched("pr")).sentLines == ["1 home pr\n"])
    #expect(await failing.loads == 1)
    await unreadable.model.shutdown()
  } // End of func theScopeIsReadForEachQuery()

  /// A scope changed between two texts drops the previous answer's folders while the new text
  /// is searched (Whole disk "pr" found `/Volumes/Archive/projects`; Home folder "pro" must
  /// not offer it), then the new answer shows; the same scope keeps them
  /// (`answersBecomeTheSection`).
  @Test func aScopeChangeDropsThePreviousFolders() async throws {
    let store = InMemoryPreferencesStore(Preferences(folderSearchScope: .disk))
    let rig = await Harness.make(preferences: store)
    let connection = try #require(await rig.searched("pr"))
    #expect(connection.sentLines == ["1 disk pr\n"])
    #expect(await rig.answer(connection, ["/Volumes/Archive/projects", "/Users/me/projects"]))
    #expect(rig.folders?.entries == ["/Volumes/Archive/projects", "~/projects"])
    _ = try await store.setFolderSearchScope(.home)
    await rig.type("pro")
    #expect(await UITestSupport.waitUntil { rig.model.folderSearchState?.text == "pro" })
    #expect(rig.model.folderSearchState?.scope == .home)
    #expect(rig.folders?.status == .searching)
    #expect(rig.folders?.entries.isEmpty == true, "nothing found in another scope")
    await rig.passDebounce()
    #expect(await rig.lines(connection, 2) == ["1 disk pr\n", "2 home pro\n"])
    #expect(await rig.answer(connection, ["/Users/me/projects"]))
    #expect(rig.folders?.entries == ["~/projects"])
    await rig.model.shutdown()
  } // End of func aScopeChangeDropsThePreviousFolders()

  /// A scope chosen in Settings (through `PreferencesStore` on a private folder) is what the
  /// next query asks; with no file the default is `home`.
  @Test func aScopeSavedInSettingsAppliesToTheNextQuery() async throws {
    let folder = try ShortcutTestSupport.privatePreferencesFolder()
    defer { try? FileManager.default.removeItem(at: folder.base) }
    let store = PreferencesStore(fileURL: folder.file)
    var environment = SettingsTestSupport.environment(
      store: FakeHostListStore(SettingsTestSupport.loaded([])))
    environment.preferences = store
    let settings = SettingsModel(environment: environment)
    await settings.windowDidOpen()
    #expect(settings.folderSearchScope == .home)
    let rig = await Harness.make(preferences: store)
    let connection = try #require(await rig.searched("pr"))
    #expect(connection.sentLines == ["1 home pr\n"])
    #expect(await rig.answer(connection, []))
    #expect(await settings.setFolderSearchScope(.disk))
    await rig.type("pro")
    await rig.passDebounce()
    #expect(await rig.lines(connection, 2) == ["1 home pr\n", "2 disk pro\n"])
    let saved = try await PreferencesStore(fileURL: folder.file).load()
    #expect(saved.preferences.folderSearchScope == .disk)
    await rig.model.shutdown()
  } // End of func aScopeSavedInSettingsAppliesToTheNextQuery()

  /// An unreachable host shows "Searching…" until the channel reports its second failure, then
  /// the problem, with no retry for the same text; the form is never held up (its fields and
  /// Create stay as they were).
  @Test func aFailureShowsInTheSection() async throws {
    let rig = await Harness.make()
    rig.model.newSessionDraft.hostID = rig.saturno.id
    rig.transport.failNextOpens(2, with: .connection(.unreachable(.timeout)))
    rig.model.newSessionDraft.directory = "site"
    #expect(rig.folders?.status == .searching)
    await rig.model.folderSearchRequestsHandled()
    #expect(
      await UITestSupport.waitUntil {
        if case .failed = rig.folders?.status { return true }
        return false
      })
    #expect(rig.folders?.statusLine == "The host can't be reached, so folders weren't searched.")
    #expect(rig.transport.openedHosts.count == 2)
    #expect(rig.model.newSessionDraft.directoryIssue == nil)
    #expect(!rig.model.newSessionDraft.isBusy)
    #expect(rig.model.directoryPicker.isOpen)
    await rig.model.shutdown()
  } // End of func aFailureShowsInTheSection()

  /// VoiceOver hears "Searching…" once when a search starts (with the directory count of the
  /// same edit when it changed), never again while it searches, then the folder count when the
  /// answer arrives, and "Searching…" again only for the next search.
  @Test func announcements() async throws {
    let lists = DirectoryLists(saved: ["~/projects/site"], recent: [:])
    let rig = await Harness.make(directories: InMemoryDirectoryStore(lists))
    await rig.model.directoryRecordingsHandled()
    let connection = try #require(await rig.searched("pr"))
    #expect(rig.said.said == ["1 matching directory. Searching…"])
    #expect(await rig.answer(connection, ["/Users/me/projects", "/srv/pr"]))
    #expect(rig.said.said.last == "2 folders found")
    await rig.type("pro")
    await rig.type("proj")
    await rig.type("proje")
    #expect(Array(rig.said.said.dropFirst(2)) == ["Searching…"], "once, not per keystroke")
    await rig.passDebounce()
    _ = await rig.lines(connection, 2)
    #expect(await rig.answer(connection, ["/Users/me/projects"]))
    #expect(Array(rig.said.said.dropFirst(2)) == ["Searching…", "1 folder found"])
    await rig.type("zzz")
    await rig.passDebounce()
    _ = await rig.lines(connection, 3)
    #expect(await rig.answer(connection, []))
    #expect(
      Array(rig.said.said.dropFirst(4)) == ["Searching…", "No folders found"],
      "the directories' count is left to the folders section once only it shows")
    await rig.model.shutdown()
  } // End of func announcements()

  /// "Open muxFinder Settings" shows Settings on its Directories tab; "Open Spotlight
  /// settings" asks the environment to open This Mac's Spotlight pane (recorded, never
  /// opened); a fixture does neither.
  @Test func theExplanationsLinks() async {
    let rig = await Harness.make()
    rig.model.openFolderSearchSettings()
    #expect(rig.model.settings.selectedTab == .directories)
    #expect(rig.seams.presented.count == 1)
    rig.model.openSpotlightSettings()
    #expect(rig.seams.openedURLs == [FolderSearchSection.spotlightSettingsURL])
    await rig.model.shutdown()
    let fixture = AppModel(fixture: FolderSearchFixtures.help)
    fixture.openFolderSearchSettings()
    fixture.openSpotlightSettings()
    #expect(fixture.settings.selectedTab != .directories)
  } // End of func theExplanationsLinks()

  /// Without `AppEnvironment.folderSearch` (the tests of other parts, the self-tests, every
  /// diagnostic) there is no folders section and the list behaves as before; the app's
  /// environment has folder search only in normal mode.
  @Test func onlyNormalModeHasFolderSearch() async {
    let harness = await AttachHarness.make(hosts: [UITestSupport.localHost()])
    harness.model.newSession()
    harness.model.newSessionDraft.directory = "proj"
    #expect(harness.model.directoryPickerContent?.folders == nil)
    #expect(!harness.model.directoryPicker.isOpen)
    await harness.model.shutdown()
    #expect(AppEnvironment.production(rewritesProfilesAtLaunch: false).folderSearch == nil)
    let menuBarItem = AppEnvironment.production(rewritesProfilesAtLaunch: false)
    #expect(menuBarItem.settings?.preferences == nil)
    let normal = AppEnvironment.production(
      rewritesProfilesAtLaunch: false, usesGlobalShortcut: true)
    #expect(normal.folderSearch?.transport is ProcessFolderSearchTransport)
    #expect(normal.folderSearch?.preferences is PreferencesStore)
    #expect(normal.settings?.preferences is PreferencesStore)
    #expect(AppEnvironment.placementDiagnostic().folderSearch == nil)
  } // End of func onlyNormalModeHasFolderSearch()
}
