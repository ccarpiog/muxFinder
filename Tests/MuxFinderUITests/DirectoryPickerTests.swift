import AppKit
import Foundation
import MuxFinderCore
import Observation
import Testing

@testable import MuxFinderUI

/// New session's directory list content (PLAN.md D31): the sections per host and their order,
/// the session folders' cap, distinctness and order, hidden empty sections, nothing to pick,
/// the "Save this directory" and "Clear recent directories" rules, and the keyboard's items.
/// Pure values: nothing runs.
@Suite("New session: directory list content")
struct DirectoryPickerContentTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// A session numbered `id` on `host` that started in `folder`.
  static func session(_ id: Int, on host: HostConfig, in folder: String?) -> HostSnapshot.Session {
    AttachFixtures.session("s\(id)", id: id, on: host, startedIn: folder)
  }

  /// Saturno and Neptuno each see their own recent directories, the same saved list, and their
  /// own sessions' folders, in the order Recent, Saved, "Sessions on <host>".
  @Test func sectionsPerHostInOrder() {
    let lists = DirectoryLists(
      saved: ["~/b", "~/a"],
      recent: [Fixtures.saturno.id: ["~/new", "~/old"], Fixtures.neptuno.id: ["~/mine"]])
    let saturno = DirectoryPickerContent(
      host: Fixtures.saturno, lists: lists,
      sessions: [Self.session(1, on: Fixtures.saturno, in: "/srv/app")], field: "")
    #expect(saturno.sections.map(\.kind) == [.recent, .saved, .sessions])
    #expect(saturno.sections.map(\.title) == ["Recent", "Saved", "Sessions on Saturno"])
    #expect(
      saturno.sections.map(\.entries) == [["~/new", "~/old"], ["~/b", "~/a"], ["/srv/app"]])
    #expect(saturno.clearTitle == "Clear recent directories on Saturno")
    let neptuno = DirectoryPickerContent(
      host: Fixtures.neptuno, lists: lists, sessions: [], field: "")
    #expect(neptuno.sections.map(\.kind) == [.recent, .saved])
    #expect(neptuno.sections.map(\.entries) == [["~/mine"], ["~/b", "~/a"]])
    #expect(neptuno.hostName == "Neptuno")
  } // End of func sectionsPerHostInOrder()

  /// Session folders: distinct by exact string (two spellings of an accented name stay two),
  /// sorted as Finder sorts names, at most 10; sessions without a folder, or with one that
  /// breaks the entry rules, are skipped.
  @Test func sessionFoldersAreDistinctSortedAndCapped() {
    let names = (1...14).map { "/Users/example/p\($0)" }
    var sessions = names.reversed().enumerated().map { offset, folder in
      Self.session(offset + 1, on: Fixtures.saturno, in: folder)
    }
    sessions.append(Self.session(40, on: Fixtures.saturno, in: names[0]))
    sessions.append(Self.session(41, on: Fixtures.saturno, in: nil))
    sessions.append(Self.session(42, on: Fixtures.saturno, in: "/Users/example/a\nb"))
    sessions.append(Self.session(43, on: Fixtures.saturno, in: ""))
    let folders = DirectoryPickerContent.sessionFolders(sessions)
    #expect(folders.count == DirectoryPickerContent.maximumSessionFolders)
    #expect(folders == Array(names.prefix(10)))

    let composed = "/Users/example/caf\u{E9}"
    let decomposed = "/Users/example/cafe\u{301}"
    let accents = DirectoryPickerContent.sessionFolders([
      Self.session(1, on: Fixtures.saturno, in: decomposed),
      Self.session(2, on: Fixtures.saturno, in: composed),
      Self.session(3, on: Fixtures.saturno, in: composed),
    ])
    #expect(accents.count == 2)
    #expect(accents.contains { DirectoryLists.same($0, composed) })
    #expect(accents.contains { DirectoryLists.same($0, decomposed) })
  } // End of func sessionFoldersAreDistinctSortedAndCapped()

  /// Each section shows only when it is not empty.
  @Test func emptySectionsAreHidden() {
    let savedOnly = DirectoryPickerContent(
      host: Fixtures.saturno, lists: DirectoryLists(saved: ["~/a"], recent: [:]),
      sessions: [Self.session(1, on: Fixtures.saturno, in: nil)], field: "")
    #expect(savedOnly.sections.map(\.kind) == [.saved])
    let foldersOnly = DirectoryPickerContent(
      host: Fixtures.saturno,
      lists: DirectoryLists(saved: [], recent: [Fixtures.neptuno.id: ["~/x"]]),
      sessions: [Self.session(1, on: Fixtures.saturno, in: "/srv")], field: "")
    #expect(foldersOnly.sections.map(\.kind) == [.sessions])
    #expect(!foldersOnly.canClearRecents)
  } // End of func emptySectionsAreHidden()

  /// With all three empty the list has nothing to pick, says so, and still offers "Save this
  /// directory" for a typed directory.
  @Test func nothingToPick() {
    let empty = DirectoryPickerContent(
      host: Fixtures.neptuno, lists: DirectoryLists(), sessions: [], field: "")
    #expect(empty.isEmpty)
    #expect(empty.sections.isEmpty)
    #expect(empty.items.isEmpty)
    #expect(DirectoryPickerContent.nothingToPick == "Nothing to pick yet")
    let typed = DirectoryPickerContent(
      host: Fixtures.neptuno, lists: DirectoryLists(), sessions: [], field: "~/projects/new")
    #expect(typed.isEmpty)
    #expect(typed.items == [.action(.saveDirectory)])
  } // End of func nothingToPick()

  /// "Save this directory" is off for an empty field, one that breaks a rule, one saved
  /// already (exact string), a full saved list, and while the store takes no change.
  @Test func saveDirectoryRule() {
    let saved = DirectoryLists(saved: ["~/projects/caf\u{E9}"], recent: [:])
    func issue(
      _ field: String, lists: DirectoryLists = saved, status: DirectoryListStatus = .notLoaded,
      canChange: Bool = true
    ) -> DirectoryPickerContent.SaveIssue? {
      DirectoryPickerContent(
        host: Fixtures.saturno, lists: lists, sessions: [], field: field, status: status,
        canChange: canChange
      ).saveIssue
    }
    #expect(issue("") == .empty)
    #expect(issue("~/a\nb") == .invalid(ValidationError.workingDirectoryContainsLineBreak.message))
    #expect(issue("~/projects/caf\u{E9}") == .alreadySaved)
    #expect(issue("~/projects/cafe\u{301}") == nil, "another spelling is another entry")
    #expect(issue("~/new") == nil)
    let full = DirectoryLists(saved: (1...50).map { "~/d\($0)" }, recent: [:])
    #expect(issue("~/new", lists: full) == .listFull)
    #expect(issue("~/new", status: .fileNotUsable(.notJSON)) == .storeUnavailable)
    #expect(issue("~/new", status: .unreadable("No.")) == .storeUnavailable)
    #expect(issue("~/new", canChange: false) == .storeUnavailable)
    #expect(issue("~/new", status: .usable(droppedEntryCount: 3)) == nil)
    #expect(
      DirectoryPickerContent.SaveIssue.alreadySaved.help == "This directory is saved already.")
  } // End of func saveDirectoryRule()

  /// "Clear recent directories on <host>" is on only with recent directories and a store that
  /// takes changes; an unusable file's notice shows at the top of the list.
  @Test func clearRuleAndNotice() {
    let lists = DirectoryLists(saved: [], recent: [Fixtures.saturno.id: ["~/a"]])
    let usable = DirectoryPickerContent(
      host: Fixtures.saturno, lists: lists, sessions: [], field: "",
      status: .usable(droppedEntryCount: 2))
    #expect(usable.canClearRecents)
    #expect(usable.notice == nil, "entries left out are Settings' notice, not the list's")
    let unusable = DirectoryPickerContent(
      host: Fixtures.saturno, lists: lists, sessions: [], field: "~/b",
      status: .fileNotUsable(.unsafe(.permissionsTooOpen)))
    #expect(!unusable.canClearRecents)
    #expect(unusable.saveIssue == .storeUnavailable)
    #expect(
      unusable.notice
        == DirectoryStoreNotice.fileNotUsed(.unsafe(.permissionsTooOpen)).message)
    #expect(unusable.items == [.entry(.recent, "~/a")])
  } // End of func clearRuleAndNotice()

  /// The keyboard's items: every entry in the list's order, then the actions that are on;
  /// moving stays at the ends, and starts at the first (↓) or last (↑) row.
  @Test func itemsAndMoving() {
    let content = DirectoryPickerContent(
      host: Fixtures.saturno,
      lists: DirectoryLists(saved: ["~/s"], recent: [Fixtures.saturno.id: ["~/r"]]),
      sessions: [Self.session(1, on: Fixtures.saturno, in: "/srv")], field: "~/typed")
    let items = content.items
    #expect(
      items == [
        .entry(.recent, "~/r"), .entry(.saved, "~/s"), .entry(.sessions, "/srv"),
        .action(.saveDirectory), .action(.clearRecents),
      ])
    #expect(content.item(movingFrom: nil, down: true) == items.first)
    #expect(content.item(movingFrom: nil, down: false) == items.last)
    #expect(content.item(movingFrom: items[0], down: true) == items[1])
    #expect(content.item(movingFrom: items[0], down: false) == items[0])
    #expect(content.item(movingFrom: items[4], down: true) == items[4])
    #expect(content.item(movingFrom: .entry(.saved, "~/gone"), down: true) == items.first)
    let none = DirectoryPickerContent(
      host: Fixtures.saturno, lists: DirectoryLists(), sessions: [], field: "")
    #expect(none.item(movingFrom: nil, down: true) == nil)
  } // End of func itemsAndMoving()

  /// Two spellings of one accented name (composed and decomposed), which the store keeps as two
  /// entries, are two rows: distinct items that hash apart, the keys go from the second
  /// spelling on to the next entry (not back to the first), each row carries its own bytes,
  /// and sections (so the whole content) compare byte for byte too.
  @Test func twoSpellingsAreTwoRows() {
    let composed = "~/projects/caf\u{E9}"
    let decomposed = "~/projects/cafe\u{301}"
    let lists = DirectoryLists(saved: [composed, decomposed, "~/projects/next"], recent: [:])
    #expect(lists.saved.count == 3)
    let content = DirectoryPickerContent(
      host: Fixtures.saturno, lists: lists, sessions: [], field: "")
    let items = content.items
    #expect(items.count == 3)
    #expect(items[0] != items[1])
    #expect(Set(items).count == 3)
    #expect(content.item(movingFrom: items[0], down: true) == items[1])
    #expect(content.item(movingFrom: items[1], down: true) == items[2])
    #expect(content.item(movingFrom: items[1], down: false) == items[0])
    #expect(items[1].directory.map { DirectoryLists.same($0, decomposed) } == true)
    #expect(items[0].directory.map { DirectoryLists.same($0, composed) } == true)
    #expect(DirectoryPickerContent.Item.entry(.saved, composed) != .entry(.recent, composed))
    #expect(DirectoryPickerContent.Item.action(.saveDirectory).directory == nil)
    let swapped = DirectoryPickerContent(
      host: Fixtures.saturno,
      lists: DirectoryLists(saved: [decomposed, composed, "~/projects/next"], recent: [:]),
      sessions: [], field: "")
    #expect(swapped.sections != content.sections)
    #expect(swapped != content)
  } // End of func twoSpellingsAreTwoRows()

  /// The New session gallery states: the list open with all three sections, nothing to pick,
  /// "Save this directory" off for a saved directory, and an unusable file; synthetic paths.
  @Test @MainActor func galleryFixturesCoverTheList() {
    let fixtures = [
      AttachFixtures.newSessionDirectories, AttachFixtures.newSessionNothingToPick,
      AttachFixtures.newSessionSavedAlready, AttachFixtures.newSessionUnusableFile,
    ]
    let contents = fixtures.compactMap { AppModel(fixture: $0).directoryPickerContent }
    #expect(contents.count == 4)
    #expect(fixtures.allSatisfy { $0.directoryPicker.isOpen && $0.panel == .newSession })
    #expect(contents[0].sections.map(\.kind) == [.recent, .saved, .sessions])
    #expect(contents[1].isEmpty && contents[1].canSaveDirectory)
    #expect(contents[2].saveIssue == .alreadySaved)
    #expect(contents[3].notice != nil && contents[3].saveIssue == .storeUnavailable)
    let paths = contents.flatMap { $0.sections.flatMap(\.entries) }
    #expect(paths.allSatisfy { $0.hasPrefix("~/") || $0.hasPrefix("/Users/example/") })
  } // End of func galleryFixturesCoverTheList()
}

/// New session's directory list in the model (PLAN.md D31): picking fills and checks the
/// draft, a host change keeps the field, the keys (⌥↓ opens, ↑/↓ inside, Return picks or
/// creates, Esc closes the list before the panel, every other key as before), and "Save this
/// directory" and "Clear recent directories" through the store, with their failures surfaced
/// and logged by code only.
@Suite("New session: directory list in the model")
@MainActor
struct DirectoryPickerModelTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures
  /// Shorthand.
  typealias Support = UITestSupport

  /// A fixture model showing New session for `host` with `directory` typed, over the gallery's
  /// lists and sessions, its list closed.
  static func fixtureModel(
    host: HostConfig = Fixtures.saturno, directory: String = ""
  ) -> AppModel {
    var fixture = AttachFixtures.newSessionDirectories
    fixture.newSessionDraft = NewSessionDraft(hostID: host.id, name: "work", directory: directory)
    fixture.directoryPicker = DirectoryPickerState()
    return AppModel(fixture: fixture)
  }

  /// A started model over This Mac and Saturno with `store`, New session open and the lists
  /// loaded.
  static func openSheet(
    _ store: any DirectoryStoring,
    diagnostics: DiagnosticsLog? = nil
  ) async -> AttachHarness {
    let harness = await AttachHarness.make(
      hosts: [Support.localHost(), Support.sshHost("Saturno")], directories: store,
      diagnostics: diagnostics)
    harness.model.newSession()
    await harness.model.directoryRecordingsHandled()
    return harness
  }

  /// Picking an entry fills the Directory field with it as typed text would be, checked by the
  /// draft and carried into the request unchanged; the list closes. A row the list does not
  /// show, or a busy sheet, picks nothing.
  @Test func pickingFillsAndChecksTheDraft() {
    let model = Self.fixtureModel()
    model.toggleDirectoryList()
    #expect(model.directoryPicker.isOpen)
    let long = AttachFixtures.directoryLists.saved[2]
    model.pickDirectoryItem(.entry(.saved, long))
    #expect(model.newSessionDraft.directory == long)
    #expect(model.newSessionDraft.directoryIssue == nil)
    #expect(
      model.newSessionDraft.request(hosts: model.newSessionHosts)?.workingDirectory == long)
    #expect(!model.directoryPicker.isOpen)

    model.openDirectoryList(highlightingFirst: false)
    model.pickDirectoryItem(.entry(.sessions, "/Users/example/projects/site"))
    #expect(model.newSessionDraft.directory == "/Users/example/projects/site")
    model.pickDirectoryItem(.entry(.saved, "~/not-listed"))
    #expect(model.newSessionDraft.directory == "/Users/example/projects/site")

    model.newSessionDraft.state = .collision
    model.pickDirectoryItem(.entry(.recent, "~/scratch"))
    #expect(model.newSessionDraft.directory == "~/scratch")
    #expect(model.newSessionDraft.state == .editing, "editing after a collision")

    model.newSessionDraft.state = .creating
    model.openDirectoryList(highlightingFirst: true)
    #expect(!model.directoryPicker.isOpen, "a busy sheet opens no list")
    model.pickDirectoryItem(.entry(.recent, "~/projects/experiments"))
    #expect(model.newSessionDraft.directory == "~/scratch")
  } // End of func pickingFillsAndChecksTheDraft()

  /// Changing the host updates the list (its recents and session folders) and keeps what is
  /// in the field; a highlight the new host's list does not have is dropped.
  @Test func hostChangeKeepsTheField() {
    let model = Self.fixtureModel(directory: "~/typed by hand")
    _ = model.handle(.openList)
    #expect(model.highlightedDirectoryItem == .entry(.recent, "~/projects/experiments"))
    #expect(model.directoryPickerContent?.sections.map(\.kind) == [.recent, .saved, .sessions])
    model.newSessionDraft.hostID = Fixtures.neptuno.id
    let content = model.directoryPickerContent
    #expect(content?.hostName == "Neptuno")
    #expect(content?.sections.map(\.kind) == [.recent, .saved])
    #expect(content?.sections.first?.entries == ["~/notes"])
    #expect(model.newSessionDraft.directory == "~/typed by hand")
    #expect(model.directoryPicker.isOpen)
    #expect(model.highlightedDirectoryItem == nil)
    _ = model.handle(.down)
    #expect(model.highlightedDirectoryItem == .entry(.recent, "~/notes"))
  } // End of func hostChangeKeepsTheField()

  /// ⌥↓ opens the list on its first row; ↑/↓ move inside it and stop at the ends; Return picks
  /// the highlighted row; Esc closes the list first and the panel second; ⌘F, ⌘N, ⌘R and ⌘,
  /// keep their panel behavior while it is open.
  @Test func keysInsideTheList() {
    let model = Self.fixtureModel()
    #expect(model.handle(.openList) == .handled)
    let items = model.directoryPickerContent?.items ?? []
    #expect(items.count == 2 + 3 + 2 + 1, "2 recent, 3 saved, 2 folders, Clear")
    #expect(model.highlightedDirectoryItem == items.first)
    #expect(model.handle(.down) == .handled)
    #expect(model.highlightedDirectoryItem == items[1])
    #expect(model.handle(.openList) == .handled)
    #expect(model.highlightedDirectoryItem == items[2])
    _ = model.handle(.up)
    _ = model.handle(.up)
    _ = model.handle(.up)
    #expect(model.highlightedDirectoryItem == items[0])
    for _ in 0..<20 { _ = model.handle(.down) }
    #expect(model.highlightedDirectoryItem == .action(.clearRecents))
    #expect(model.selection == nil, "the session rows' selection never moves")

    #expect(model.handle(.find) == .handled)
    #expect(model.searchFocusRequests == 0)
    #expect(model.handle(.newSession) == .handled)
    #expect(model.handle(.settings) == .handled)
    #expect(model.handle(.refresh) == .handled)
    #expect(model.directoryPicker.isOpen)

    _ = model.handle(.up)
    let folder = model.highlightedDirectoryItem
    #expect(folder == .entry(.sessions, "/Users/example/projects/site"))
    #expect(model.handle(.open) == .handled)
    #expect(model.newSessionDraft.directory == "/Users/example/projects/site")
    #expect(!model.directoryPicker.isOpen)
    #expect(model.panel == .newSession)

    _ = model.handle(.openList)
    #expect(model.handle(.close) == .handled)
    #expect(!model.directoryPicker.isOpen)
    #expect(model.panel == .newSession)
    #expect(model.handle(.close) == .handled)
    #expect(model.panel == nil)
  } // End of func keysInsideTheList()

  /// Without New session, ⌥↓ is left to the focused view (the search field), in the host list
  /// and in Move here alike; the other keys do what they did.
  @Test func openListElsewhereIsIgnored() {
    var fixture = PreviewFixtures.overview
    fixture.selection = nil
    let model = AppModel(fixture: fixture)
    #expect(model.handle(.openList) == .ignored)
    #expect(model.selection == nil)
    #expect(model.handle(.down) == .handled)
    #expect(model.selection != nil)
    #expect(model.handle(.close) == .closePopover)
    let moveHere = AppModel(fixture: AttachFixtures.moveHere)
    #expect(moveHere.handle(.openList) == .ignored)
    #expect(!moveHere.directoryPicker.isOpen)
    #expect(moveHere.handle(.close) == .handled)
    #expect(moveHere.panel == nil)
  } // End of func openListElsewhereIsIgnored()

  /// ⌥↓ (also with the arrows' own flags) is the list's key; ⌥↑, ⇧⌥↓, ⌃↓ and ⌘↓ stay unmapped.
  @Test func openListKeyMapping() {
    typealias Key = PopoverKey
    #expect(
      Key(keyCode: 125, modifierFlags: .option, charactersIgnoringModifiers: nil) == .openList)
    #expect(
      Key(
        keyCode: 125, modifierFlags: [.option, .numericPad, .function],
        charactersIgnoringModifiers: nil) == .openList)
    #expect(Key(keyCode: 126, modifierFlags: .option, charactersIgnoringModifiers: nil) == nil)
    #expect(
      Key(keyCode: 125, modifierFlags: [.option, .shift], charactersIgnoringModifiers: nil) == nil)
    #expect(Key(keyCode: 125, modifierFlags: .control, charactersIgnoringModifiers: nil) == nil)
    #expect(Key(keyCode: 125, modifierFlags: .command, charactersIgnoringModifiers: nil) == nil)
    #expect(Key(keyCode: 36, modifierFlags: .option, charactersIgnoringModifiers: "\r") == nil)
  } // End of func openListKeyMapping()

  /// Return in the field still creates: with the list closed, and with it open but nothing
  /// highlighted (the list closes first). Esc then closes the panel, not a list.
  @Test func returnStillCreates() async {
    let harness = await Self.openSheet(InMemoryDirectoryStore())
    let model = harness.model
    harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.newSessionDraft.name = "taken"
    model.toggleDirectoryList()
    #expect(model.directoryPicker.isOpen && model.highlightedDirectoryItem == nil)
    #expect(model.handle(.open) == .handled)
    #expect(!model.directoryPicker.isOpen)
    #expect(model.newSessionDraft.state == .creating)
    #expect(await Support.waitUntil { model.newSessionDraft.state == .collision })

    harness.creator.script([.failure(.sessionExists(.hasSession))])
    let before = model.finishedActions.count
    #expect(model.handle(.open) == .handled)
    #expect(model.newSessionDraft.state == .creating)
    #expect(await Support.waitUntil { model.finishedActions.count > before })
    #expect(model.handle(.close) == .handled)
    #expect(model.panel == nil)
    await model.shutdown()
  } // End of func returnStillCreates()

  /// Editing the field ends the list's navigation: with a row highlighted (⌥↓), typing drops
  /// the highlight (the list stays open) and Return creates from what was typed instead of
  /// picking that row; a row highlighted with ↓ after the edit, and not edited past, is what
  /// Return picks.
  @Test func editingTheFieldDropsTheHighlight() async {
    let harness = await Self.openSheet(
      InMemoryDirectoryStore(DirectoryLists(saved: ["~/s1", "~/s2"], recent: [:])))
    let model = harness.model
    harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.newSessionDraft.name = "taken"
    #expect(model.handle(.openList) == .handled)
    #expect(model.highlightedDirectoryItem == .entry(.saved, "~/s1"))
    model.newSessionDraft.directory = "~/typed"
    #expect(model.directoryPicker.isOpen)
    #expect(model.highlightedDirectoryItem == nil)
    #expect(model.handle(.open) == .handled)
    #expect(!model.directoryPicker.isOpen)
    #expect(model.newSessionDraft.directory == "~/typed")
    #expect(model.newSessionDraft.state == .creating)
    #expect(await Support.waitUntil { model.newSessionDraft.state == .collision })
    #expect(harness.creator.requests.map(\.workingDirectory) == ["~/typed"])

    _ = model.handle(.openList)
    model.newSessionDraft.directory = "~/typed again"
    #expect(model.highlightedDirectoryItem == nil)
    _ = model.handle(.down)
    #expect(model.highlightedDirectoryItem == .entry(.saved, "~/s1"))
    #expect(model.handle(.open) == .handled)
    #expect(model.newSessionDraft.directory == "~/s1")
    #expect(!model.directoryPicker.isOpen)
    #expect(harness.creator.requests.count == 1, "picking a row creates nothing")
    await model.shutdown()
  } // End of func editingTheFieldDropsTheHighlight()

  /// The keys pass through both spellings of one accented name on to the next entry, and
  /// Return on the decomposed one fills the field with exactly its bytes.
  @Test func keysMoveThroughBothSpellings() {
    let composed = "~/projects/caf\u{E9}"
    let decomposed = "~/projects/cafe\u{301}"
    var fixture = AttachFixtures.newSessionDirectories
    fixture.newSessionDraft = NewSessionDraft(hostID: Fixtures.neptuno.id, name: "work")
    fixture.directoryLists = DirectoryLists(
      saved: [composed, decomposed, "~/projects/next"], recent: [:])
    fixture.directoryPicker = DirectoryPickerState()
    let model = AppModel(fixture: fixture)
    #expect(model.directoryPickerContent?.items.count == 3)
    _ = model.handle(.openList)
    #expect(model.highlightedDirectoryItem == .entry(.saved, composed))
    _ = model.handle(.down)
    #expect(model.highlightedDirectoryItem == .entry(.saved, decomposed))
    _ = model.handle(.down)
    #expect(model.highlightedDirectoryItem == .entry(.saved, "~/projects/next"))
    _ = model.handle(.up)
    #expect(model.handle(.open) == .handled)
    #expect(DirectoryLists.same(model.newSessionDraft.directory, decomposed))
    #expect(!model.directoryPicker.isOpen)
  } // End of func keysMoveThroughBothSpellings()

  /// Lists that differ only in an entry's spelling are a change: the model tells its views
  /// (an `@Observable` model skips values equal to the one it holds), so the rows shown carry
  /// the bytes the store holds.
  @Test func aRespelledEntryReachesTheView() {
    let composed = "~/projects/caf\u{E9}"
    let decomposed = "~/projects/cafe\u{301}"
    var fixture = AttachFixtures.newSessionDirectories
    fixture.directoryLists = DirectoryLists(saved: [composed], recent: [:])
    let model = AppModel(fixture: fixture)
    let told = Counter()
    withObservationTracking {
      _ = model.directoryLists
    } onChange: {
      told.increment()
    }
    model.directoriesChanged(
      DirectoryLists(saved: [decomposed], recent: [:]), tellingSettings: false)
    #expect(told.value == 1)
    let items = model.directoryPickerContent?.items ?? []
    #expect(items.contains(.entry(.saved, decomposed)))
    #expect(!items.contains(.entry(.saved, composed)))
  } // End of func aRespelledEntryReachesTheView()

  /// Opening New session reads the lists afresh; "Save this directory" adds the field's value
  /// to the store's saved list (then it is saved already), the list staying open; "Clear recent
  /// directories" forgets only that host's recents.
  @Test func saveAndClearGoThroughTheStore() async {
    let local = Support.localHost()
    let other = UUID()
    let lists = DirectoryLists(
      saved: ["~/kept"], recent: [local.id: ["~/r1", "~/r2"], other: ["~/elsewhere"]])
    let store = InMemoryDirectoryStore(lists)
    let harness = await AttachHarness.make(hosts: [local], directories: store)
    let model = harness.model
    model.newSession()
    await model.directoryRecordingsHandled()
    #expect(model.directoryLists == lists)
    #expect(model.directoryStatus == .usable(droppedEntryCount: 0))

    model.newSessionDraft.directory = "~/projects/new ü #1;"
    _ = model.handle(.openList)
    #expect(model.directoryPickerContent?.canSaveDirectory == true)
    model.pickDirectoryItem(.action(.saveDirectory))
    await model.directoryRecordingsHandled()
    #expect(await store.lists.saved == ["~/kept", "~/projects/new ü #1;"])
    #expect(model.directoryLists.saved == ["~/kept", "~/projects/new ü #1;"])
    #expect(model.directoryPickerContent?.saveIssue == .alreadySaved)
    #expect(model.directoryPicker.isOpen)

    model.pickDirectoryItem(.action(.clearRecents))
    await model.directoryRecordingsHandled()
    #expect(await store.lists.recent(for: local.id).isEmpty)
    #expect(await store.lists.saved.count == 2)
    #expect(model.directoryPickerContent?.sections.map(\.kind) == [.saved])
    #expect(model.directoryPickerContent?.canClearRecents == false)
    #expect(await store.lists.recent(for: other).isEmpty, "a host not in the list is pruned")
    await model.shutdown()
  } // End of func saveAndClearGoThroughTheStore()

  /// A save the store refuses changes nothing else: the list says why, the field and lists stay,
  /// and the operation log has the kind and the code, never the directory.
  @Test func aRefusedSaveIsSurfacedAndLoggedByCode() async {
    let store = FailingDirectoryStore()
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let harness = await Self.openSheet(store, diagnostics: diagnostics)
    let model = harness.model
    model.newSessionDraft.directory = "/Users/example/secret project"
    model.toggleDirectoryList()
    model.saveFieldDirectory()
    await model.directoryRecordingsHandled()
    #expect(await store.attempts == 1)
    #expect(
      model.directoryPicker.problem?.hasPrefix("muxFinder couldn't save this directory.") == true)
    #expect(model.newSessionDraft.directory == "/Users/example/secret project")
    #expect(model.directoryLists.isEmpty)
    #expect(model.panel == .newSession)
    let events = await diagnostics.events().filter { $0.detail.hasPrefix("directory list") }
    #expect(
      events.map(\.detail) == [
        "directory list: addSaved not done: systemCallFailed.renameatx_np.\(EIO)"
      ])
    #expect(await diagnostics.events().allSatisfy { !$0.detail.contains("secret") })
    await model.shutdown()
  } // End of func aRefusedSaveIsSurfacedAndLoggedByCode()

  /// An unusable directory list file (valid lists with group and other permissions, in a
  /// private folder): the list shows its notice, offers neither action, and the file keeps its
  /// bytes and mode.
  @Test func anUnusableFileOffersNoChange() async throws {
    let base = FileManager.default.temporaryDirectory
      .appending(path: "mfx-picker-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: base) }
    let file = base.appending(path: DirectoryStore.fileName)
    let original = Data(#"{"recent": {}, "saved": ["~/kept"], "schemaVersion": 1}"#.utf8)
    try original.write(to: file)
    try #require(chmod(file.path(percentEncoded: false), 0o644) == 0)
    let diagnostics = DiagnosticsLog(writesToSystemLog: false)
    let harness = await Self.openSheet(DirectoryStore(fileURL: file), diagnostics: diagnostics)
    let model = harness.model
    #expect(model.directoryStatus == .fileNotUsable(.unsafe(.permissionsTooOpen)))
    model.newSessionDraft.directory = "~/new"
    let content = try #require(model.directoryPickerContent)
    #expect(content.notice != nil)
    #expect(content.saveIssue == .storeUnavailable)
    #expect(!content.canClearRecents)
    #expect(content.isEmpty)
    model.saveFieldDirectory()
    model.clearRecentDirectories()
    await model.directoryRecordingsHandled()
    #expect(try Data(contentsOf: file) == original)
    let attributes = try FileManager.default.attributesOfItem(
      atPath: file.path(percentEncoded: false))
    #expect(attributes[.posixPermissions] as? Int == 0o644)
    let events = await diagnostics.events().map(\.detail)
    #expect(events.contains("directory list not usable: fileNotUsable.unsafe.permissionsTooOpen"))
    await model.shutdown()
  } // End of func anUnusableFileOffersNoChange()

  /// A save in Settings reaches New session's list, and a save from New session's list reaches
  /// Settings' Directories tab (which has no unsaved edits), through the one store.
  @Test func settingsAndThePickerShareTheStore() async {
    let store = InMemoryDirectoryStore(DirectoryLists(saved: ["~/a"], recent: [:]))
    var settingsEnvironment = SettingsTestSupport.environment(
      store: FakeHostListStore(Support.loaded([Support.localHost()])))
    settingsEnvironment.directories = store
    let harness = await AttachHarness.make(settings: settingsEnvironment, directories: store)
    let model = harness.model
    await model.settings.windowDidOpen()
    #expect(model.settings.savedDirectories == ["~/a"])
    model.settings.newDirectory = "~/b"
    model.settings.addDirectory()
    #expect(await model.settings.saveDirectories())
    #expect(model.directoryLists.saved == ["~/a", "~/b"])

    model.newSession()
    await model.directoryRecordingsHandled()
    model.newSessionDraft.directory = "~/c"
    model.saveFieldDirectory()
    await model.directoryRecordingsHandled()
    #expect(model.settings.savedDirectories == ["~/a", "~/b", "~/c"])
    #expect(model.settings.directoryDraft == ["~/a", "~/b", "~/c"])
    await model.shutdown()
  } // End of func settingsAndThePickerShareTheStore()
}
