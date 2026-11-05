import Foundation
import MuxFinderCore
import Testing

@testable import MuxFinderUI

/// New session's directory list filtered by the Directory field (PLAN.md D31, Phase I-7), as a
/// pure value: an empty field filters nothing; each section keeps its matching entries in order
/// (case and diacritics ignored, surrounding spaces trimmed); "No matching directories" apart
/// from "Nothing to pick yet"; an exact match still shown; the actions never filtered; and the
/// `~` rule, on This Mac only. Nothing runs.
@Suite("New session: the directory list's filter")
struct DirectoryFilterContentTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures
  /// This Mac's home folder in these tests (synthetic; never the real one).
  static let home = "/Users/me"

  /// A session numbered `id` on `host` that started in `folder`.
  static func session(_ id: Int, on host: HostConfig, in folder: String) -> HostSnapshot.Session {
    AttachFixtures.session("s\(id)", id: id, on: host, startedIn: folder)
  }

  /// Saturno's recent directories and the saved list, some of them under a projects folder.
  static let lists = DirectoryLists(
    saved: ["~/projects/site", "~/Documents/notes", "~/projects/api"],
    recent: [Fixtures.saturno.id: ["~/projects/experiments", "~/scratch"]])
  /// Saturno's sessions: one in a projects folder, one elsewhere.
  static let sessions = [
    session(1, on: Fixtures.saturno, in: "/srv/projects/web"),
    session(2, on: Fixtures.saturno, in: "/var/log"),
  ]

  /// The list for `host` with `field` typed.
  static func content(
    _ field: String,
    host: HostConfig = Fixtures.saturno,
    lists: DirectoryLists = lists,
    sessions: [HostSnapshot.Session] = sessions,
    canChange: Bool = true,
    home: String? = nil
  ) -> DirectoryPickerContent {
    DirectoryPickerContent(
      host: host, lists: lists, sessions: sessions, field: field,
      status: .usable(droppedEntryCount: 0), canChange: canChange, thisMacHome: home)
  } // End of static func content(_:host:lists:sessions:canChange:home:)

  /// An empty field, or one holding only spaces and line breaks, filters nothing: the list is
  /// as before the filter existed.
  @Test func anEmptyFieldFiltersNothing() {
    let all = [
      ["~/projects/experiments", "~/scratch"],
      ["~/projects/site", "~/Documents/notes", "~/projects/api"],
      ["/srv/projects/web", "/var/log"],
    ]
    for field in ["", "   ", " \n\t "] {
      let content = Self.content(field)
      #expect(content.query.isEmpty)
      #expect(content.sections.map(\.entries) == all)
      #expect(content.matchCount == 7 && content.unfilteredEntryCount == 7)
      #expect(!content.noMatches && !content.isEmpty)
      #expect(content.matchSummary == "7 directories")
    }
  } // End of func anEmptyFieldFiltersNothing()

  /// A query keeps, in each section, the entries that contain it, in their order; a section
  /// left empty is hidden; surrounding spaces are trimmed; the keyboard's items are the rows
  /// shown, then the actions.
  @Test func aQueryKeepsTheMatchingEntriesOfEachSection() {
    let content = Self.content("proj")
    #expect(content.query == "proj")
    #expect(content.sections.map(\.kind) == [.recent, .saved, .sessions])
    #expect(
      content.sections.map(\.entries) == [
        ["~/projects/experiments"], ["~/projects/site", "~/projects/api"], ["/srv/projects/web"],
      ])
    #expect(content.matchCount == 4 && content.unfilteredEntryCount == 7)
    #expect(content.matchSummary == "4 matching directories")
    #expect(
      content.items == [
        .entry(.recent, "~/projects/experiments"), .entry(.saved, "~/projects/site"),
        .entry(.saved, "~/projects/api"), .entry(.sessions, "/srv/projects/web"),
        .action(.saveDirectory), .action(.clearRecents),
      ])
    let scratch = Self.content("  scratch ")
    #expect(scratch.query == "scratch")
    #expect(scratch.sections.map(\.kind) == [.recent])
    #expect(scratch.sections.map(\.entries) == [["~/scratch"]])
    #expect(scratch.matchSummary == "1 matching directory")
  } // End of func aQueryKeepsTheMatchingEntriesOfEachSection()

  /// Matching ignores case and diacritics (composed or decomposed), as the popover's search.
  @Test func matchingIgnoresCaseAndDiacritics() {
    let lists = DirectoryLists(
      saved: ["~/Projects/Caf\u{E9}", "~/archive/cafe\u{301}", "~/work/CAFE", "~/other"],
      recent: [:])
    for query in ["caf\u{E9}", "CAFE", "Cafe\u{301}", "  cAfÉ  "] {
      let content = Self.content(query, lists: lists, sessions: [])
      #expect(content.sections.map(\.entries) == [Array(lists.saved.prefix(3))], "\(query)")
    }
  }

  /// With entries the filter hides all of, and an action on, the list says "No matching
  /// directories" (not "Nothing to pick yet") and the keyboard moves through the actions.
  @Test func noMatchesWithActionsOn() {
    let content = Self.content("~/zzz")
    #expect(content.sections.isEmpty)
    #expect(content.noMatches && !content.isEmpty)
    #expect(content.matchCount == 0)
    #expect(content.items == [.action(.saveDirectory), .action(.clearRecents)])
    #expect(content.item(movingFrom: nil, down: true) == .action(.saveDirectory))
    #expect(content.matchSummary == DirectoryPickerContent.noMatchesTitle)
    #expect(DirectoryPickerContent.noMatchesTitle == "No matching directories")
  }

  /// No match with every action off leaves no item; with no entry at all the list says
  /// "Nothing to pick yet" whatever the field holds, never "No matching directories".
  @Test func noMatchesWithNothingOnAndNothingAtAll() {
    let off = Self.content("~/zzz", canChange: false)
    #expect(off.noMatches)
    #expect(off.items.isEmpty)
    #expect(off.matchSummary == "No matching directories")
    let nothing = Self.content("~/zzz", lists: DirectoryLists(), sessions: [])
    #expect(nothing.isEmpty && !nothing.noMatches)
    #expect(nothing.items == [.action(.saveDirectory)])
    #expect(nothing.matchSummary == DirectoryPickerContent.nothingToPick)
    let nothingOff = Self.content("~/zzz", lists: DirectoryLists(), sessions: [], canChange: false)
    #expect(nothingOff.isEmpty && nothingOff.items.isEmpty)
  } // End of func noMatchesWithNothingOnAndNothingAtAll()

  /// An entry equal to the field byte for byte still shows (with "Save this directory" off, as
  /// it is saved); the rule holds even where the text search would not find it; another
  /// spelling of the same accented name shows too, as its own row.
  @Test func anExactMatchStillShows() {
    let site = Self.content("~/projects/site")
    #expect(site.sections.map(\.entries) == [["~/projects/site"]])
    #expect(site.saveIssue == .alreadySaved)
    #expect(DirectoryPickerContent.entry("~/a", matches: "zzz", field: "~/a", home: nil))
    #expect(!DirectoryPickerContent.entry("~/a", matches: "zzz", field: "~/b", home: nil))
    let composed = "~/projects/caf\u{E9}"
    let decomposed = "~/projects/cafe\u{301}"
    let accents = Self.content(
      composed, lists: DirectoryLists(saved: [composed, decomposed, "~/x"], recent: [:]),
      sessions: [])
    #expect(accents.items.count == 2, "both spellings; Save off (saved already), no recents")
    #expect(accents.items.contains(.entry(.saved, composed)))
    #expect(accents.items.contains(.entry(.saved, decomposed)))
  } // End of func anExactMatchStillShows()

  /// The actions are never filtered and keep their rules: Clear stays on for recents the filter
  /// hides, Save works from the typed text (on for a new one, off for a saved one, a line break
  /// or a full list).
  @Test func actionsAreNeverFiltered() {
    let hidden = Self.content("/var")
    #expect(hidden.sections.map(\.kind) == [.sessions])
    #expect(hidden.canClearRecents, "the host has recents, though none is shown")
    #expect(hidden.canSaveDirectory)
    #expect(hidden.items.suffix(2) == [.action(.saveDirectory), .action(.clearRecents)])
    #expect(Self.content("~/projects/api").saveIssue == .alreadySaved)
    #expect(Self.content("~/a\nb").saveIssue != nil)
    let full = DirectoryLists(
      saved: (1...50).map { "~/d\($0)" }, recent: [Fixtures.saturno.id: ["~/r"]])
    let fullContent = Self.content("~/new", lists: full, sessions: [])
    #expect(fullContent.saveIssue == .listFull)
    #expect(fullContent.noMatches && fullContent.items == [.action(.clearRecents)])
  } // End of func actionsAreNeverFiltered()

  /// On This Mac the field is matched as typed against each entry as stored, with a leading
  /// home folder written `~` and with a leading `~` or `~/` spelled out: `~/proj` finds a
  /// session folder `/Users/me/projects-old`, `/Users/me/pr` finds a saved `~/projects`; a
  /// `~user` form is never expanded, and a folder that only starts like the home folder is not
  /// in it.
  @Test func theTildeRuleOnThisMac() {
    let lists = DirectoryLists(
      saved: ["~/projects", "~bob/shared", "/Users/meadow/x"], recent: [:])
    let sessions = [
      Self.session(1, on: Fixtures.neptuno, in: "/Users/me/projects-old"),
      Self.session(2, on: Fixtures.neptuno, in: "/opt/tools"),
      Self.session(3, on: Fixtures.neptuno, in: "/Users/bob/x"),
    ]
    func entries(_ field: String) -> [[String]] {
      Self.content(
        field, host: Fixtures.neptuno, lists: lists, sessions: sessions, home: Self.home + "/"
      ).sections.map(\.entries)
    }
    #expect(entries("~/proj") == [["~/projects"], ["/Users/me/projects-old"]])
    #expect(entries("/Users/me/pr") == [["~/projects"], ["/Users/me/projects-old"]])
    #expect(entries("~bob") == [["~bob/shared"]], "matched as typed, never expanded")
    #expect(entries("/Users/bob/sh").isEmpty, "~bob is never spelled out")
    #expect(entries("~adow").isEmpty, "/Users/meadow is not in /Users/me")
    #expect(entries("~/").first == ["~/projects"])

    typealias Content = DirectoryPickerContent
    #expect(Content.spellings(of: "/Users/me/x", home: Self.home) == ["/Users/me/x", "~/x"])
    #expect(Content.spellings(of: "/Users/me", home: Self.home) == ["/Users/me", "~"])
    #expect(Content.spellings(of: "~/x", home: Self.home) == ["~/x", "/Users/me/x"])
    #expect(Content.spellings(of: "~", home: Self.home) == ["~", "/Users/me"])
    #expect(Content.spellings(of: "~bob/x", home: Self.home) == ["~bob/x"])
    #expect(Content.spellings(of: "/Users/meadow", home: Self.home) == ["/Users/meadow"])
    #expect(Content.spellings(of: "~/x", home: nil) == ["~/x"])
    #expect(Content.homeFolder("/Users/me//") == Self.home)
    #expect(Content.homeFolder("/") == nil && Content.homeFolder("") == nil)
    #expect(Content.homeFolder(nil) == nil)
  } // End of func theTildeRuleOnThisMac()

  /// On an SSH host, whose home folder is unknown, entries are matched only as stored, even
  /// with This Mac's home folder given; on This Mac with none given, the same.
  @Test func noTildeRuleOnSSHHosts() {
    let lists = DirectoryLists(saved: ["~/projects"], recent: [:])
    let saturno = [Self.session(1, on: Fixtures.saturno, in: "/Users/me/projects-old")]
    func entries(_ field: String, host: HostConfig, home: String?) -> [[String]] {
      Self.content(
        field, host: host, lists: lists,
        sessions: host.isThisMac
          ? [Self.session(2, on: host, in: "/Users/me/projects-old")] : saturno,
        home: home
      ).sections.map(\.entries)
    }
    #expect(entries("~/proj", host: Fixtures.saturno, home: Self.home) == [["~/projects"]])
    #expect(
      entries("/Users/me/pr", host: Fixtures.saturno, home: Self.home)
        == [["/Users/me/projects-old"]])
    #expect(entries("~/proj", host: Fixtures.neptuno, home: nil) == [["~/projects"]])
    #expect(
      entries("~/proj", host: Fixtures.neptuno, home: Self.home)
        == [["~/projects"], ["/Users/me/projects-old"]])
  } // End of func noTildeRuleOnSSHHosts()

  /// The Directory field's accessibility hint says that typing filters the list.
  @Test @MainActor func theFieldsHintMentionsTheFilter() {
    #expect(DirectoryFieldView.hint.hasPrefix("Typing filters the list"))
  }
}

/// Collects what the model asks VoiceOver to say.
@MainActor
final class AnnouncementRecorder {
  /// The announcements, oldest first.
  var said: [String] = []
}

/// The directory list's filter in the model (PLAN.md D31, Phase I-7): typing opens a list with
/// matches and highlights nothing; no match, or an empty field, closes a list the typing opened
/// but not one the button or ⌥↓ opened; Esc keeps the text; ↓ and ⌥↓ highlight the first match
/// and the arrows stay in the rows shown; Return with nothing highlighted creates from the
/// field; a pick fills the field and never reopens the list; a host change re-filters; a busy
/// draft or no host opens nothing; VoiceOver hears the match count.
@Suite("New session: the directory list's filter in the model")
@MainActor
struct DirectoryFilterModelTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures
  /// Shorthand.
  typealias Support = UITestSupport

  /// A fixture model showing New session for `host` with `directory` typed, over the gallery's
  /// lists and sessions (Saturno: recent `~/projects/experiments` and `~/scratch`; saved
  /// `~/projects/site`, `~/projects/api` and a long one; session folders
  /// `/Users/example/projects/api` and `…/site`), its list closed.
  static func model(host: HostConfig = Fixtures.saturno, directory: String = "") -> AppModel {
    var fixture = AttachFixtures.newSessionDirectories
    fixture.newSessionDraft = NewSessionDraft(hostID: host.id, name: "work", directory: directory)
    fixture.directoryPicker = DirectoryPickerState()
    return AppModel(fixture: fixture)
  }

  /// Typing that matches opens the list as the typing's, nothing highlighted; typing that
  /// matches nothing opens nothing.
  @Test func typingThatMatchesOpensTheListWithoutAHighlight() {
    let model = Self.model()
    model.newSessionDraft.directory = "zzz"
    #expect(!model.directoryPicker.isOpen)
    model.newSessionDraft.directory = "proj"
    #expect(model.directoryPicker.isOpen)
    #expect(model.directoryPicker.opening == .typing)
    #expect(model.highlightedDirectoryItem == nil)
    #expect(model.directoryPickerContent?.sections.map(\.kind) == [.recent, .saved, .sessions])
    #expect(model.directoryPickerContent?.matchCount == 5)
    model.newSessionDraft.directory = "proje"
    #expect(model.directoryPicker.opening == .typing)
  } // End of func typingThatMatchesOpensTheListWithoutAHighlight()

  /// No match closes a list the typing opened; one the button or ⌥↓ opened stays, saying "No
  /// matching directories" with the actions.
  @Test func noMatchClosesOnlyAListTheTypingOpened() {
    let model = Self.model()
    model.newSessionDraft.directory = "proj"
    model.newSessionDraft.directory = "proj-zzz"
    #expect(!model.directoryPicker.isOpen)

    model.toggleDirectoryList()
    #expect(model.directoryPicker.opening == .request)
    model.newSessionDraft.directory = "proj-zzzz"
    #expect(model.directoryPicker.opening == .request)
    #expect(model.directoryPickerContent?.noMatches == true)
    #expect(
      model.directoryPickerContent?.items == [.action(.saveDirectory), .action(.clearRecents)])

    model.toggleDirectoryList()
    #expect(model.handleNewSessionKey(.openList) == .handled)
    #expect(model.directoryPicker.opening == .request)
    model.newSessionDraft.directory = "proj-zz"
    #expect(model.directoryPicker.isOpen)
  } // End of func noMatchClosesOnlyAListTheTypingOpened()

  /// Clearing the field is no search: it closes a list the typing opened and opens nothing (not
  /// even with spaces left); a list the button opened stays and shows every entry again.
  @Test func clearingTheFieldClosesATypingOpenedListAndOpensNothing() {
    let model = Self.model()
    model.newSessionDraft.directory = "proj"
    #expect(model.directoryPicker.opening == .typing)
    model.newSessionDraft.directory = ""
    #expect(!model.directoryPicker.isOpen)
    model.newSessionDraft.directory = "   "
    #expect(!model.directoryPicker.isOpen)

    model.newSessionDraft.directory = ""
    model.toggleDirectoryList()
    model.newSessionDraft.directory = "proj"
    #expect(model.directoryPicker.opening == .request)
    model.newSessionDraft.directory = ""
    #expect(model.directoryPicker.opening == .request)
    #expect(model.directoryPickerContent?.matchCount == 7)
  } // End of func clearingTheFieldClosesATypingOpenedListAndOpensNothing()

  /// Esc closes the list and keeps the text (New session stays); the next edit may open it
  /// again.
  @Test func escKeepsTheTextAndCloses() {
    let model = Self.model()
    model.newSessionDraft.directory = "proj"
    #expect(model.handleNewSessionKey(.close) == .handled)
    #expect(!model.directoryPicker.isOpen)
    #expect(model.newSessionDraft.directory == "proj")
    #expect(model.isNewSessionShown)
    model.newSessionDraft.directory = "proje"
    #expect(model.directoryPicker.opening == .typing)
  } // End of func escKeepsTheTextAndCloses()

  /// ↓ highlights the first match; ↑/↓ visit only the rows shown (the matches, then the
  /// actions) and stop at the ends; ⌥↓ in a list the typing opened highlights the first match
  /// too.
  @Test func theArrowsStayInTheFilteredRows() {
    let model = Self.model()
    model.newSessionDraft.directory = "proj"
    #expect(model.handleNewSessionKey(.down) == .handled)
    #expect(model.highlightedDirectoryItem == .entry(.recent, "~/projects/experiments"))
    var visited = [model.highlightedDirectoryItem]
    for _ in 0..<10 {
      _ = model.handleNewSessionKey(.down)
      visited.append(model.highlightedDirectoryItem)
    }
    let items = model.directoryPickerContent?.items ?? []
    #expect(items.count == 5 + 2)
    #expect(Set(visited.compactMap { $0 }) == Set(items))
    #expect(!visited.contains(.entry(.recent, "~/scratch")))
    #expect(model.highlightedDirectoryItem == .action(.clearRecents))
    for _ in 0..<10 { _ = model.handleNewSessionKey(.up) }
    #expect(model.highlightedDirectoryItem == items.first)

    model.newSessionDraft.directory = "proje"
    #expect(model.highlightedDirectoryItem == nil)
    #expect(model.handleNewSessionKey(.openList) == .handled)
    #expect(model.highlightedDirectoryItem == .entry(.recent, "~/projects/experiments"))
    #expect(model.directoryPicker.opening == .typing)
  } // End of func theArrowsStayInTheFilteredRows()

  /// With the list the typing opened and nothing highlighted, Return closes it and creates from
  /// what the field holds.
  @Test func returnWithNoHighlightCreatesFromTheField() async {
    let harness = await DirectoryPickerModelTests.openSheet(
      InMemoryDirectoryStore(DirectoryLists(saved: ["~/s1", "~/s2"], recent: [:])))
    let model = harness.model
    harness.creator.script([.failure(.sessionExists(.hasSession))])
    model.newSessionDraft.name = "taken"
    model.newSessionDraft.directory = "~/s"
    #expect(model.directoryPicker.opening == .typing)
    #expect(model.highlightedDirectoryItem == nil)
    #expect(model.handleNewSessionKey(.open) == .handled)
    #expect(!model.directoryPicker.isOpen)
    #expect(model.newSessionDraft.state == .creating)
    #expect(await Support.waitUntil { model.newSessionDraft.state == .collision })
    #expect(harness.creator.requests.map(\.workingDirectory) == ["~/s"])
    await model.shutdown()
  } // End of func returnWithNoHighlightCreatesFromTheField()

  /// Picking a row (Return on the highlight, or a click) fills the field and closes the list;
  /// the fill is no edit, so the list does not reopen and nothing is announced.
  @Test func pickingFillsTheFieldAndDoesNotReopen() {
    let model = Self.model()
    let recorder = AnnouncementRecorder()
    model.announce = { recorder.said.append($0) }
    model.newSessionDraft.directory = "proj"
    _ = model.handleNewSessionKey(.down)
    let before = recorder.said
    #expect(model.handleNewSessionKey(.open) == .handled)
    #expect(model.newSessionDraft.directory == "~/projects/experiments")
    #expect(!model.directoryPicker.isOpen)
    #expect(recorder.said == before)

    model.newSessionDraft.directory = "api"
    #expect(model.directoryPicker.opening == .typing)
    let beforeClick = recorder.said
    model.pickDirectoryItem(.entry(.sessions, "/Users/example/projects/api"))
    #expect(model.newSessionDraft.directory == "/Users/example/projects/api")
    #expect(!model.directoryPicker.isOpen)
    #expect(recorder.said == beforeClick)
  } // End of func pickingFillsTheFieldAndDoesNotReopen()

  /// A host change re-filters with the new host's entries and keeps the field; it is no edit,
  /// so it neither opens nor closes the list.
  @Test func aHostChangeRefilters() {
    let model = Self.model()
    model.newSessionDraft.directory = "proj"
    #expect(model.directoryPickerContent?.sections.map(\.kind) == [.recent, .saved, .sessions])
    model.newSessionDraft.hostID = Fixtures.neptuno.id
    #expect(model.newSessionDraft.directory == "proj")
    let content = model.directoryPickerContent
    #expect(content?.hostName == "Neptuno")
    #expect(content?.sections.map(\.entries) == [["~/projects/site", "~/projects/api"]])
    #expect(model.directoryPicker.opening == .typing)

    model.newSessionDraft.directory = "notes"
    #expect(model.directoryPickerContent?.sections.map(\.entries) == [["~/notes"]])
    model.newSessionDraft.hostID = Fixtures.saturno.id
    #expect(model.directoryPickerContent?.noMatches == true)
    #expect(model.directoryPicker.isOpen, "a host change closes nothing")

    _ = model.handleNewSessionKey(.close)
    model.newSessionDraft.hostID = Fixtures.neptuno.id
    #expect(!model.directoryPicker.isOpen, "a host change opens nothing")
  } // End of func aHostChangeRefilters()

  /// Nothing opens while the draft is busy, with no host chosen, or with a host the engine does
  /// not list.
  @Test func aBusyDraftOrNoHostOpensNothing() {
    let busy = Self.model()
    busy.newSessionDraft.state = .creating
    busy.newSessionDraft.directory = "proj"
    #expect(!busy.directoryPicker.isOpen)
    busy.newSessionDraft.state = .findingExisting
    busy.newSessionDraft.directory = "proje"
    #expect(!busy.directoryPicker.isOpen)

    for hostID in [nil, UUID()] {
      let model = Self.model()
      model.newSessionDraft.hostID = hostID
      model.newSessionDraft.directory = "proj"
      #expect(model.directoryPickerContent == nil)
      #expect(!model.directoryPicker.isOpen)
    }
  } // End of func aBusyDraftOrNoHostOpensNothing()

  /// VoiceOver hears the match count when an edit opens the list or changes its rows, "No
  /// matching directories" when an edit closes a list the typing opened (or leaves a requested
  /// one with none), the whole count when the field is cleared in a requested list; nothing for
  /// an edit that keeps the rows, one that leaves the list closed, clearing a list the typing
  /// opened, or the button.
  @Test func theMatchCountIsAnnouncedWhenTheFilterChanges() {
    let model = Self.model()
    let recorder = AnnouncementRecorder()
    model.announce = { recorder.said.append($0) }
    model.newSessionDraft.directory = "zzz"
    #expect(recorder.said.isEmpty)
    model.newSessionDraft.directory = "proj"
    #expect(recorder.said == ["5 matching directories"])
    model.newSessionDraft.directory = "proje"
    #expect(recorder.said.count == 1, "the same rows: nothing said again")
    model.newSessionDraft.directory = "~/projects/s"
    model.newSessionDraft.directory = "~/projects/sz"
    model.newSessionDraft.directory = ""
    model.toggleDirectoryList()
    model.newSessionDraft.directory = "~/zzz"
    model.newSessionDraft.directory = ""
    #expect(
      recorder.said == [
        "5 matching directories", "1 matching directory", "No matching directories",
        "No matching directories", "7 directories",
      ])
  } // End of func theMatchCountIsAnnouncedWhenTheFilterChanges()

  /// The app's environment gives the real home folder and posts announcements; fixtures use the
  /// synthetic home and say nothing; the tests' and the placement diagnostic's environments
  /// have neither.
  @Test func theHomeFolderAndTheAnnouncerAreInjected() async {
    let production = AppEnvironment.production(rewritesProfilesAtLaunch: false)
    #expect(production.homeDirectory == NSHomeDirectory())
    #expect(production.announce != nil)
    let placement = AppEnvironment.placementDiagnostic()
    #expect(placement.homeDirectory == nil && placement.announce == nil)
    let fixture = Self.model()
    #expect(fixture.thisMacHome == PreviewFixtures.homeDirectory)
    #expect(fixture.announce == nil)
    let harness = await AttachHarness.make()
    #expect(harness.model.thisMacHome == nil && harness.model.announce == nil)
    await harness.model.shutdown()
  } // End of func theHomeFolderAndTheAnnouncerAreInjected()

  /// The gallery states: filtered by typing on This Mac (the `~` rule finding a session
  /// folder), no matching directory with the button's list, and both in the switcher's form;
  /// synthetic paths only.
  @Test func galleryFixturesCoverTheFilter() {
    let filtered = AppModel(fixture: AttachFixtures.newSessionFiltered)
    #expect(filtered.directoryPicker.opening == .typing)
    #expect(filtered.highlightedDirectoryItem == nil)
    #expect(
      filtered.directoryPickerContent?.sections.map(\.entries) == [
        ["~/projects/blog"], ["~/projects/site", "~/projects/api"],
        ["/Users/example/projects/site"],
      ])
    let noMatches = AppModel(fixture: AttachFixtures.newSessionNoMatches)
    #expect(noMatches.directoryPicker.opening == .request)
    #expect(noMatches.directoryPickerContent?.noMatches == true)
    #expect(noMatches.directoryPickerContent?.items.count == 2)
    let form = AppModel(fixture: SwitcherFixtures.formFiltered)
    #expect(form.directoryPicker.opening == .typing)
    #expect(form.directoryPickerContent?.sections.map(\.kind) == [.recent, .saved])
    let formNone = AppModel(fixture: SwitcherFixtures.formNoMatches)
    #expect(formNone.directoryPickerContent?.noMatches == true)
    let models = [filtered, noMatches, form, formNone]
    let paths = models.flatMap { $0.directoryPickerContent?.sections.flatMap(\.entries) ?? [] }
    #expect(paths.allSatisfy { $0.hasPrefix("~/") || $0.hasPrefix("/Users/example/") })
  } // End of func galleryFixturesCoverTheFilter()
}
