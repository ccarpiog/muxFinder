import Foundation
import MuxFinderCore

/// The New session window's folder search states for `--preview-gallery new-session` (PLAN.md
/// D36, Phase I-10b): searching, folders found (one left out as Saved shows it, a long path
/// shortened in the middle), none found, each reason the host cannot search (no Spotlight,
/// indexing off, no home folder), an SSH failure, Desktop, Documents and Downloads hidden over
/// SSH, and "Missing a folder?" open on This Mac. Synthetic paths only, under the fixtures'
/// home folder `/Users/example` or an invented `/Volumes/Archive`; no real folder name. Building
/// them runs nothing.
public enum FolderSearchFixtures {
  /// Shorthand.
  typealias Fixtures = PreviewFixtures

  /// A host without Spotlight (a Linux box), for the "no Spotlight" state.
  public static let buildBox = HostConfig(
    id: Fixtures.fixtureID(20), displayName: "Build box", mode: .ssh,
    sshDestination: "build-box.example")

  /// A header from a host whose home folder is the fixtures' (`nil` home: none), Spotlight
  /// and indexing as given, the protected folders `readability` (This Mac's are never
  /// checked).
  static func header(
    home: String? = Fixtures.homeDirectory,
    spotlight: Bool = true,
    homeIndexing: FolderSearchHeader.IndexState = .on,
    readability: FolderSearchHeader.Readability = .readable
  ) -> FolderSearchHeader {
    FolderSearchHeader(
      homeDirectory: home, hasSpotlight: spotlight, homeIndexing: homeIndexing,
      diskIndexing: .on, desktop: readability, documents: readability, downloads: readability)
  }

  /// The channel's state for `text` on `host` at `phase`, with `header`.
  static func state(
    _ text: String, on host: HostConfig, phase: FolderSearchState.Phase,
    header: FolderSearchHeader?
  ) -> FolderSearchState {
    var state = FolderSearchState.initial
    state.host = FolderSearchHost(host)
    state.text = text
    state.scope = .home
    state.phase = phase
    state.header = header
    return state
  } // End of static func state(_:on:phase:header:)

  /// The phase of an answer holding `paths`.
  static func found(_ paths: [String], isLimited: Bool = false) -> FolderSearchState.Phase {
    .answered(FolderSearchAnswer(paths: paths, isLimited: isLimited))
  }

  /// A New session fixture with `directory` typed for `host`, the list opened by the typing,
  /// over the directory list fixtures' lists and Saturno's folder sessions, its folders section
  /// at `phase`.
  static func fixture(
    id: String,
    title: String,
    host: HostConfig,
    directory: String,
    phase: FolderSearchState.Phase,
    header: FolderSearchHeader?,
    highlighted: DirectoryPickerContent.Item? = nil,
    helpShown: Bool = false
  ) -> PreviewFixture {
    var snapshots = [
      Fixtures.snapshot(
        Fixtures.saturno, outcome: .sessionsListed, sessions: AttachFixtures.saturnoFolderSessions,
        lastSuccessAgo: 5),
      Fixtures.snapshot(
        Fixtures.neptuno, outcome: .sessionsListed, sessions: AttachFixtures.neptuno,
        lastSuccessAgo: 5),
    ]
    if host.id == buildBox.id {
      snapshots.append(Fixtures.snapshot(buildBox, outcome: .noServer, lastSuccessAgo: 5))
    }
    return PreviewFixture(
      id: id, title: title, state: Fixtures.state(snapshots), showsNewSession: true,
      newSessionDraft: NewSessionDraft(hostID: host.id, name: "site-preview", directory: directory),
      directoryLists: AttachFixtures.directoryLists,
      directoryStatus: .usable(droppedEntryCount: 0),
      directoryPicker: DirectoryPickerState(opening: .typing, highlighted: highlighted),
      folderSearch: FolderSearchSnapshot(
        state: state(directory, on: host, phase: phase, header: header)),
      folderSearchHelpShown: helpShown)
  } // End of static func fixture(id:title:host:directory:phase:header:highlighted:helpShown:)

  /// This Mac with "pho" typed: nothing in the lists matches, so the list shows only the
  /// folders section, searching.
  public static let searching = fixture(
    id: "new-session-folders-searching", title: "New session: searching folders",
    host: Fixtures.neptuno, directory: "pho", phase: .searching,
    header: header(readability: .notChecked))

  /// This Mac with "dra" typed: Saved's drafts folder, then the folders found (that one left
  /// out, shown once in Saved; a long path shortened in the middle; one outside the home
  /// folder), one highlighted.
  public static let results = fixture(
    id: "new-session-folders-found", title: "New session: folders found",
    host: Fixtures.neptuno, directory: "dra",
    phase: found([
      "/Users/example/Documents/client work/2026/quarterly reports/drafts",
      "/Users/example/Documents/client work/2026/quarterly reports/drafts/final",
      "/Users/example/Writing/drafts",
      "/Users/example/Projects/alpha/design/landing page redesign for the spring campaign/"
        + "second round/drawings and sketches",
      "/Volumes/Archive/drawings",
    ]),
    header: header(readability: .notChecked),
    highlighted: .entry(.folders, "~/Writing/drafts"))

  /// Saturno with "zebra" typed: nothing in the lists, no folder found.
  public static let noneFound = fixture(
    id: "new-session-folders-none", title: "New session: no folders found",
    host: Fixtures.saturno, directory: "zebra", phase: found([]), header: header())

  /// A host without Spotlight: the section says so and nothing was searched.
  public static let noSpotlight = fixture(
    id: "new-session-folders-no-spotlight", title: "New session: no Spotlight on the host",
    host: buildBox, directory: "site", phase: .unavailable(.noSpotlight),
    header: header(spotlight: false, homeIndexing: .unknown))

  /// Saturno with Spotlight indexing off for its home folder's disk.
  public static let indexingOff = fixture(
    id: "new-session-folders-indexing-off", title: "New session: Spotlight indexing off",
    host: Fixtures.saturno, directory: "site", phase: .unavailable(.indexingOff),
    header: header(homeIndexing: .off))

  /// Saturno whose home folder is unknown, so Home folder cannot be searched.
  public static let noHomeFolder = fixture(
    id: "new-session-folders-no-home", title: "New session: host's home folder unknown",
    host: Fixtures.saturno, directory: "site", phase: .unavailable(.noHomeFolder),
    header: header(home: nil, readability: .missing))

  /// Saturno unreachable over SSH: the problem shows in the section; the form still works.
  public static let failed = fixture(
    id: "new-session-folders-failed", title: "New session: folder search failed over SSH",
    host: Fixtures.saturno, directory: "site",
    phase: .failed(.connection(.unreachable(.timeout))), header: nil)

  /// Saturno with "site" typed, whose header found Desktop, Documents and Downloads unreadable
  /// over SSH: the folders found (the session's folder left out, shown in Sessions) and the
  /// note.
  public static let protectedFolders = fixture(
    id: "new-session-folders-protected", title: "New session: protected folders over SSH",
    host: Fixtures.saturno, directory: "site",
    phase: found([
      "/Users/example/projects/site", "/Users/example/Sites", "/Users/example/projects/site-v1",
      "/Users/example/Code/website",
    ]),
    header: header(readability: .unreadable))

  /// This Mac with no folder found and "Missing a folder?" open: the explanation with "Open
  /// muxFinder Settings" and "Open Spotlight settings".
  public static let help = fixture(
    id: "new-session-folders-help", title: "New session: missing a folder?",
    host: Fixtures.neptuno, directory: "receipts", phase: found([]),
    header: header(readability: .notChecked), highlighted: .action(.folderSearchHelp),
    helpShown: true)

  /// Every folder search state, in the gallery's order.
  public static let all = [
    searching, results, noneFound, noSpotlight, indexingOff, noHomeFolder, failed,
    protectedFolders, help,
  ]
}
