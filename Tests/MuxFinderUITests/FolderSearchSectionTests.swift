import Foundation
import MuxFinderCore
import Testing

@testable import MuxFinderUI

/// New session's "Folders on <host>" section as a pure value (PLAN.md D31, D36, Phase I-10b):
/// when it shows (the `/` and 2-character rules), its states (searching, found, none, every
/// unavailable reason, a failure, a refusal), the `~` rule, de-duplication against the other
/// sections, unusable paths dropped and counted, the SSH-only protected-folders note, and its
/// place in the list's items. Synthetic paths only; nothing runs.
@Suite("New session: the folders section")
struct FolderSearchSectionTests {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures
  /// The hosts' home folder in these tests (synthetic).
  static let home = "/Users/me"

  /// A header with home `home`, Spotlight on, and the protected folders `readability`.
  static func header(
    home: String? = home, readability: FolderSearchHeader.Readability = .readable
  ) -> FolderSearchHeader {
    FolderSearchHeader(
      homeDirectory: home, hasSpotlight: true, homeIndexing: .on, diskIndexing: .on,
      desktop: readability, documents: readability, downloads: readability)
  }

  /// The channel's state for `text` on `host` at `phase`.
  static func state(
    _ text: String, on host: HostConfig = Fixtures.saturno, phase: FolderSearchState.Phase,
    header: FolderSearchHeader? = header(), scope: FolderSearchScope = .home
  ) -> FolderSearchState {
    var state = FolderSearchState.initial
    state.host = FolderSearchHost(host)
    state.text = text
    state.scope = scope
    state.phase = phase
    state.header = header
    return state
  } // End of static func state(_:on:phase:header:scope:)

  /// An answer holding `paths`.
  static func found(
    _ paths: [String], isLimited: Bool = false, dropped: Int = 0
  ) -> FolderSearchState.Phase {
    .answered(FolderSearchAnswer(paths: paths, isLimited: isLimited, droppedCount: dropped))
  }

  /// The section for `field` on `host` with `state` and `previous`, earlier sections showing
  /// `shown`.
  static func section(
    _ field: String, host: HostConfig = Fixtures.saturno, state: FolderSearchState?,
    previous: FolderSearchPreviousAnswer? = nil, shown: [String] = []
  ) -> FolderSearchSection? {
    FolderSearchSection(
      host: host, field: field, snapshot: FolderSearchSnapshot(state: state, previous: previous),
      shown: shown)
  }

  /// Text with a `/` (a path being typed), fewer than 2 characters (as `Character`s) or only
  /// spaces shows no section; anything else does, spaces kept.
  @Test func whichTextIsSearched() {
    for text in ["", "a", "é", "e\u{301}", "  ", " \n", "/", "a/b", "~/pro", "pro/", "ab/"] {
      #expect(!FolderSearchSection.isSearchable(text), "\(text)")
      #expect(Self.section(text, state: nil) == nil, "\(text)")
    }
    for text in ["ab", "a b", " ab ", "日本", "~pro", "proj"] {
      #expect(FolderSearchSection.isSearchable(text), "\(text)")
      #expect(Self.section(text, state: nil)?.status == .searching, "\(text)")
    }
  } // End of func whichTextIsSearched()

  /// The `~` rule: the home folder itself is `~`, a path under it `~/…` (whole components,
  /// byte for byte), anything else as it is; no home, an empty one or the root turns it off; a
  /// trailing slash on the home is ignored.
  @Test func theTildeRule() {
    let display = FolderSearchSection.displayPath
    #expect(display("/Users/me", "/Users/me") == "~")
    #expect(display("/Users/me/projects/site", "/Users/me") == "~/projects/site")
    #expect(display("/Users/me/projects", "/Users/me/") == "~/projects")
    #expect(display("/Users/me2/projects", "/Users/me") == "/Users/me2/projects")
    #expect(display("/Volumes/Archive/x", "/Users/me") == "/Volumes/Archive/x")
    #expect(display("/Users/me/x", nil) == "/Users/me/x")
    #expect(display("/Users/me/x", "") == "/Users/me/x")
    #expect(display("/Users/me/x", "/") == "/Users/me/x")
  }

  /// No state for the text, a state for another text or host, or the channel still searching:
  /// "Searching…" with no rows (the summary says it), nothing else.
  @Test func searching() throws {
    let cases: [FolderSearchState?] = [
      nil, Self.state("pr", phase: Self.found(["/Users/me/projects"])),
      Self.state("proj", on: Fixtures.neptuno, phase: Self.found(["/Users/me/projects"])),
      Self.state("proj", phase: .searching), Self.state("proj", phase: .idle),
    ]
    for state in cases {
      let section = try #require(Self.section("proj", state: state))
      #expect(section.status == .searching)
      #expect(!section.status.isSettled)
      #expect(section.entries.isEmpty)
      #expect(section.statusLine == "Searching…")
      #expect(section.summary == "Searching…")
      #expect(section.title == "Folders on Saturno")
      #expect(section.droppedNote == nil && section.limitedNote == nil)
    } // End of loop over searching states
  } // End of func searching()

  /// While a newer text is searched, the previous answer's folders on this host whose names
  /// (not paths) still contain the text stay listed (case and diacritics ignored); another
  /// host's answer leaves nothing.
  @Test func searchingKeepsThePreviousFoldersThatStillMatch() throws {
    let previous = FolderSearchPreviousAnswer(
      host: FolderSearchHost(Fixtures.saturno), text: "pr", scope: .home,
      paths: ["/Users/me/Projects", "/Users/me/proj-x/pr", "/Volumes/Old/PRÓJ", "/Users/me/prize"],
      header: Self.header())
    let section = try #require(
      Self.section("proj", state: Self.state("proj", phase: .searching), previous: previous))
    #expect(section.status == .searching)
    #expect(section.entries == ["~/Projects", "/Volumes/Old/PRÓJ"])
    var elsewhere = previous
    elsewhere.host = .local
    let other = try #require(Self.section("proj", state: nil, previous: elsewhere))
    #expect(other.entries.isEmpty)
  } // End of func searchingKeepsThePreviousFoldersThatStillMatch()

  /// A previous answer for another scope leaves nothing while the newer text is searched: Whole
  /// disk "pr" found `/Volumes/Archive/projects`, and once the scope is Home folder, "pro"
  /// must not offer it (nor its home folder rows); the same scope keeps them all.
  @Test func searchingDropsThePreviousFoldersOfAnotherScope() throws {
    let previous = FolderSearchPreviousAnswer(
      host: FolderSearchHost(Fixtures.saturno), text: "pr", scope: .disk,
      paths: ["/Volumes/Archive/projects", "/Users/me/projects"], header: Self.header())
    let home = try #require(
      Self.section(
        "pro", state: Self.state("pro", phase: .searching, scope: .home), previous: previous))
    #expect(home.status == .searching)
    #expect(home.scope == .home)
    #expect(home.entries.isEmpty)
    let disk = try #require(
      Self.section(
        "pro", state: Self.state("pro", phase: .searching, scope: .disk), previous: previous))
    #expect(disk.entries == ["/Volumes/Archive/projects", "~/projects"])
  } // End of func searchingDropsThePreviousFoldersOfAnotherScope()

  /// An answer for the field's exact text lists its folders in Spotlight's order, `~/…` under
  /// the header's home; "1 folder found", "3 folders found"; a limited answer says so.
  @Test func found() throws {
    let paths = ["/Users/me/projects", "/Volumes/Archive/old projects", "/Users/me"]
    let section = try #require(
      Self.section("pro", state: Self.state("pro", phase: Self.found(paths, isLimited: true))))
    #expect(section.status == .found && section.status.isSettled)
    #expect(section.entries == ["~/projects", "/Volumes/Archive/old projects", "~"])
    #expect(section.statusLine == nil)
    #expect(section.summary == "3 folders found")
    #expect(section.limitedNote?.hasPrefix("Showing the first 50 folders found.") == true)
    let one = try #require(
      Self.section("pro", state: Self.state("pro", phase: Self.found(["/srv/pro"]))))
    #expect(one.summary == "1 folder found")
    #expect(one.limitedNote == nil)
    let noHome = try #require(
      Self.section(
        "pro", state: Self.state("pro", phase: Self.found(paths), header: Self.header(home: nil))))
    #expect(noHome.entries == paths)
  } // End of func found()

  /// A folder an earlier section shows (as `~/x` or as `<home>/x`) is left out and shows only
  /// there; a duplicate in the answer shows once; when every folder found is shown above, the
  /// section says "No other folders found"; with none at all, "No folders found".
  @Test func deduplicatesAgainstTheOtherSections() throws {
    let paths = [
      "/Users/me/projects/site", "/Users/me/projects/api", "/srv/www", "/srv/www",
      "/Users/me/notes",
    ]
    let shown = ["~/projects/site", "/Users/me/projects/api", "/srv/www/"]
    let section = try #require(
      Self.section("st", state: Self.state("st", phase: Self.found(paths)), shown: shown))
    #expect(section.entries == ["/srv/www", "~/notes"])
    let all = try #require(
      Self.section(
        "st", state: Self.state("st", phase: Self.found(Array(paths.prefix(2)))), shown: shown))
    #expect(all.status == .noneElse)
    #expect(all.statusLine == "No other folders found")
    #expect(all.entries.isEmpty)
    let none = try #require(Self.section("st", state: Self.state("st", phase: Self.found([]))))
    #expect(none.status == .noneFound)
    #expect(none.statusLine == "No folders found")
    #expect(none.summary == "No folders found")
  } // End of func deduplicatesAgainstTheOtherSections()

  /// A path a typed Directory could not hold (a line feed, a tab, a C1 control, longer than
  /// 4,096 bytes) is dropped and only counted, with the parser's own drops; a section with
  /// only dropped folders says "No folders found" and how many can't be offered.
  @Test func dropsUnusablePaths() throws {
    let long = "/Users/me/" + String(repeating: "x", count: 4_100)
    let paths = [
      "/Users/me/line\nfeed", "/Users/me/tab\tbed", "/Users/me/c1\u{85}x", long,
      "/Users/me/fine",
    ]
    let section = try #require(
      Self.section("in", state: Self.state("in", phase: Self.found(paths, dropped: 2))))
    #expect(section.entries == ["~/fine"])
    #expect(section.droppedCount == 6)
    #expect(section.droppedNote?.hasPrefix("6 folders found can't be offered") == true)
    let only = try #require(
      Self.section("in", state: Self.state("in", phase: Self.found(Array(paths.prefix(1))))))
    #expect(only.status == .noneFound)
    #expect(only.droppedNote?.hasPrefix("1 folder found can't be offered") == true)
    #expect(FolderSearchSection.isUsable("~/fine") && FolderSearchSection.isUsable("/srv"))
    #expect(!FolderSearchSection.isUsable("") && !FolderSearchSection.isUsable("~/a\u{7F}b"))
  } // End of func dropsUnusablePaths()

  /// Each reason a host cannot search has its title and reason (the indexing one by scope);
  /// nothing is listed and the protected-folders note is not shown.
  @Test func unavailable() throws {
    let unreadable = Self.header(readability: .unreadable)
    func section(
      _ reason: FolderSearchUnavailable, scope: FolderSearchScope = .home
    ) throws -> FolderSearchSection {
      try #require(
        Self.section(
          "site",
          state: Self.state(
            "site", phase: .unavailable(reason), header: unreadable, scope: scope)))
    }
    let noSpotlight = try section(.noSpotlight)
    #expect(noSpotlight.status == .unavailable(.noSpotlight))
    #expect(noSpotlight.statusLine == "Folder search isn't available on Saturno")
    #expect(noSpotlight.summary == "Folder search isn't available on Saturno")
    #expect(noSpotlight.unavailableReason?.contains("Spotlight (mdfind) isn't there") == true)
    #expect(noSpotlight.protectedFoldersNote == nil)
    #expect(noSpotlight.entries.isEmpty)
    #expect(
      try section(.indexingOff).unavailableReason
        == "Spotlight indexing is turned off for the disk that holds its home folder.")
    #expect(
      try section(.indexingOff, scope: .disk).unavailableReason
        == "Spotlight indexing is turned off for its startup disk.")
    #expect(try section(.noHomeFolder).unavailableReason?.contains("Choose Whole disk") == true)
    #expect(Self.section("site", state: nil)?.unavailableReason == nil)
  } // End of func unavailable()

  /// A failure (SSH, a timeout) shows the core's message, a refused text its reason; neither
  /// lists folders.
  @Test func failedAndRefused() throws {
    let failure = FolderSearchFailure.connection(.unreachable(.timeout))
    let failed = try #require(
      Self.section("site", state: Self.state("site", phase: .failed(failure), header: nil)))
    #expect(failed.status == .failed(failure))
    #expect(failed.statusLine == failure.message)
    #expect(failed.summary == "The host can't be reached, so folders weren't searched.")
    let long = String(repeating: "é", count: 200)
    let refused = try #require(
      Self.section(long, state: Self.state(long, phase: .refused(.tooLong))))
    #expect(refused.statusLine == FolderSearchTextIssue.tooLong.message)
    #expect(refused.entries.isEmpty)
  } // End of func failedAndRefused()

  /// Only an SSH host gets the protected-folders note, naming the folders its header found
  /// unreadable ("Desktop, Documents and Downloads on Saturno can't be searched over SSH.");
  /// This Mac never does, whatever its header says, and `notChecked` is no problem.
  @Test func protectedFoldersNoteOnlyForSSH() throws {
    let answered = Self.found(["/Users/me/site"])
    let all = try #require(
      Self.section(
        "site",
        state: Self.state("site", phase: answered, header: Self.header(readability: .unreadable))))
    #expect(
      all.protectedFoldersNote
        == "Desktop, Documents and Downloads on Saturno can't be searched over SSH.")
    var one = Self.header()
    one.documents = .unreadable
    let documents = try #require(
      Self.section("site", state: Self.state("site", phase: answered, header: one)))
    #expect(documents.protectedFoldersNote == "Documents on Saturno can't be searched over SSH.")
    var two = Self.header()
    two.desktop = .unreadable
    two.downloads = .unreadable
    let pair = try #require(
      Self.section("site", state: Self.state("site", phase: .searching, header: two)))
    #expect(
      pair.protectedFoldersNote == "Desktop and Downloads on Saturno can't be searched over SSH.")
    let thisMac = try #require(
      Self.section(
        "site", host: Fixtures.neptuno,
        state: Self.state(
          "site", on: Fixtures.neptuno, phase: answered,
          header: Self.header(readability: .unreadable))))
    #expect(thisMac.protectedFoldersNote == nil)
    #expect(thisMac.isThisMac)
    let unchecked = try #require(
      Self.section(
        "site",
        state: Self.state("site", phase: answered, header: Self.header(readability: .notChecked))))
    #expect(unchecked.protectedFoldersNote == nil)
  } // End of func protectedFoldersNoteOnlyForSSH()

  /// In the list: the section comes last, its folders after the other sections' entries in the
  /// keyboard's items, then "Missing a folder?", then the actions; it counts as something to
  /// show whatever its status, and the list's summary speaks for it. Without folder search the
  /// list is as before.
  @Test func theSectionInTheList() throws {
    let lists = DirectoryLists(saved: ["~/projects/site"], recent: [:])
    let snapshot = FolderSearchSnapshot(
      state: Self.state(
        "site", phase: Self.found(["/Users/me/projects/site", "/Users/me/website"])))
    let content = DirectoryPickerContent(
      host: Fixtures.saturno, lists: lists, sessions: [], field: "site",
      status: .usable(droppedEntryCount: 0), folderSearch: snapshot)
    #expect(content.sections.map(\.kind) == [.saved])
    #expect(content.folders?.entries == ["~/website"])
    #expect(
      content.items == [
        .entry(.saved, "~/projects/site"), .entry(.folders, "~/website"),
        .action(.folderSearchHelp), .action(.saveDirectory),
      ])
    #expect(content.isEnabled(.folderSearchHelp))
    #expect(content.hasSomethingToShow)
    #expect(content.listSummary == "1 matching directory. 1 folder found")

    let nothingLocal = DirectoryPickerContent(
      host: Fixtures.saturno, lists: DirectoryLists(), sessions: [], field: "zz",
      status: .usable(droppedEntryCount: 0), folderSearch: FolderSearchSnapshot())
    #expect(nothingLocal.isEmpty && nothingLocal.matchCount == 0)
    #expect(nothingLocal.hasSomethingToShow, "the section shows while it searches")
    #expect(nothingLocal.folders?.status == .searching)
    #expect(nothingLocal.listSummary == "Searching…")
    #expect(nothingLocal.items == [.action(.folderSearchHelp), .action(.saveDirectory)])

    let noFolderSearch = DirectoryPickerContent(
      host: Fixtures.saturno, lists: DirectoryLists(), sessions: [], field: "zz",
      status: .usable(droppedEntryCount: 0))
    #expect(noFolderSearch.folders == nil && !noFolderSearch.hasSomethingToShow)
    #expect(!noFolderSearch.isEnabled(.folderSearchHelp))
    #expect(noFolderSearch.listSummary == DirectoryPickerContent.nothingToPick)
    let slash = DirectoryPickerContent(
      host: Fixtures.saturno, lists: lists, sessions: [], field: "~/projects",
      status: .usable(droppedEntryCount: 0), folderSearch: snapshot)
    #expect(slash.folders == nil, "a path being typed is not searched")
  } // End of func theSectionInTheList()

  /// The texts the explanation and its links use, and the This Mac Spotlight pane's URL (never
  /// opened by a test).
  @Test func theExplanation() {
    let text = FolderSearchSection.missingFolderExplanation.joined(separator: " ")
    for part in [
      "start with a dot", "Spotlight's privacy settings", "node_modules", "Whole disk",
      "Allow full disk access for remote users", "apostrophe", "first 50",
    ] {
      #expect(text.contains(part), "\(part)")
    }
    #expect(FolderSearchSection.helpTitle == "Missing a folder?")
    #expect(FolderSearchSection.openSettingsTitle == "Open muxFinder Settings")
    #expect(FolderSearchSection.openSpotlightSettingsTitle == "Open Spotlight settings")
    #expect(FolderSearchSection.spotlightSettingsURL.scheme == "x-apple.systempreferences")
  } // End of func theExplanation()

  /// The gallery's folder search states: every status, synthetic paths only (under the
  /// fixtures' home folder or `/Volumes/Archive`), no environment, unique ids, in the New
  /// session gallery.
  @Test @MainActor func galleryFixturesCoverEveryState() {
    let fixtures = FolderSearchFixtures.all
    let models = fixtures.map { AppModel(fixture: $0) }
    let sections = models.compactMap { $0.directoryPickerContent?.folders }
    #expect(sections.count == fixtures.count)
    let statuses = Set(sections.map(\.status))
    #expect(statuses.contains(.searching) && statuses.contains(.found))
    #expect(statuses.contains(.noneFound))
    for reason in [FolderSearchUnavailable.noSpotlight, .indexingOff, .noHomeFolder] {
      #expect(statuses.contains(.unavailable(reason)), "\(reason)")
    }
    #expect(statuses.contains { if case .failed = $0 { true } else { false } })
    #expect(sections.filter { $0.protectedFoldersNote != nil }.count == 1)
    #expect(models.filter(\.isFolderSearchHelpShown).count == 1)
    #expect(models.allSatisfy { $0.environment == nil && $0.directoryPicker.isOpen })
    let paths = sections.flatMap(\.entries)
    #expect(!paths.isEmpty)
    #expect(paths.allSatisfy { $0.hasPrefix("~/") || $0.hasPrefix("/Volumes/Archive/") })
    #expect(Set(fixtures.map(\.id)).count == fixtures.count)
    let gallery = Set(NewSessionGallery.fixtures.map(\.id))
    #expect(fixtures.allSatisfy { gallery.contains($0.id) })
    #expect(gallery.count == NewSessionGallery.fixtures.count)
  } // End of func galleryFixturesCoverEveryState()
}
