import Foundation
import MuxFinderCore

/// The latest answer New session's folder search gave on a host (PLAN.md D31, D36, Phase
/// I-10b), kept in memory while a newer text is searched, so its folders whose names still
/// contain the text stay listed under "Searching…" instead of the section emptying at each
/// keystroke (only while the newer search is on the same host in the same scope). Never
/// written to disk.
public struct FolderSearchPreviousAnswer: Sendable, Hashable {
  /// The host that answered.
  public var host: FolderSearchHost
  /// The text the answer was for, as typed.
  public var text: String
  /// The scope the answer was for: its folders stay listed only while a search in the same
  /// scope runs (a Whole disk folder is no Home folder result).
  public var scope: FolderSearchScope
  /// The folders found, as the core returned them (absolute paths).
  public var paths: [String]
  /// The host's header when it answered (its home folder for the `~` rule).
  public var header: FolderSearchHeader?

  /// An answer from its parts.
  public init(
    host: FolderSearchHost, text: String, scope: FolderSearchScope, paths: [String],
    header: FolderSearchHeader?
  ) {
    self.host = host
    self.text = text
    self.scope = scope
    self.paths = paths
    self.header = header
  }
}

/// What New session's model knows of its folder search, for the directory list's content: the
/// window's channel's latest state and its latest answer. `nil` in place of a snapshot means
/// folder search does not exist here (the tests of other parts, the self-tests, the
/// diagnostics, fixtures without folder search).
public struct FolderSearchSnapshot: Sendable, Hashable {
  /// The latest state the window's channel published, if any.
  public var state: FolderSearchState?
  /// The latest answer, if any.
  public var previous: FolderSearchPreviousAnswer?

  /// A snapshot from its parts.
  public init(state: FolderSearchState? = nil, previous: FolderSearchPreviousAnswer? = nil) {
    self.state = state
    self.previous = previous
  }
}

/// The "Folders on <host>" section of New session's directory list (PLAN.md D31, D36, Phase
/// I-10b), as a pure value built from the Directory field, the host, the folder search's
/// snapshot and the entries the earlier sections show, so its states and rules are unit-tested
/// apart from the view and the channel.
///
/// - **When it shows:** only while the field's text can be searched (`isSearchable(_:)`: at
///   least 2 characters, not only spaces, and no `/`, since a path being typed is no folder
///   name); otherwise there is no section and no query.
/// - **Status:** "Searching…" until the channel's state is for the field's exact text on this
///   host (so a keystroke shows it at once, before the channel heard of the text), then the
///   folders found, "No folders found" ("No other folders found" when every folder found is in
///   an earlier section), "Folder search isn't available on <host>" with its reason (no
///   Spotlight, indexing off, no home folder; no query was sent), the channel's failure (an SSH
///   problem, a timeout), or why the text cannot be searched.
/// - **Rows:** each path the core returned, written `~/…` under the host's home folder (from
///   the script's header; the home folder itself `~`) and absolute elsewhere, which is also
///   what a pick puts in the field. A path that would not pass the checks a typed Directory
///   gets (`DirectoryLists.check`: not empty, `Validation.workingDirectory`, at most 4,096
///   bytes) or holds a control character is dropped and only counted (`droppedCount`, with the
///   parser's own), never logged. A folder an earlier section shows (compared after the `~`
///   rule, byte for byte) is left out: it shows once, in its first section. While searching,
///   the previous answer's folders on this host whose names still contain the text stay
///   listed, only when that answer was for the scope of the latest request the channel knows
///   (a scope changed in Settings drops them).
/// - **Notes:** "Showing the first 50…" for a limited answer, the dropped count, and, for an SSH
///   host only, which of Desktop, Documents and Downloads the header found unreadable over SSH
///   (This Mac runs no readability check).
public struct FolderSearchSection: Sendable, Hashable {
  /// Where the section's search stands.
  public enum Status: Sendable, Hashable {
    /// Waiting for typing to pause, the channel to open, or the answer.
    case searching
    /// Folders were found and are listed.
    case found
    /// The answer holds no folder (or none that can be offered).
    case noneFound
    /// Every folder found is listed in an earlier section already.
    case noneElse
    /// The host cannot search; no query was sent.
    case unavailable(FolderSearchUnavailable)
    /// The search failed (the second failure in a row); it stands until the text or the host
    /// changes.
    case failed(FolderSearchFailure)
    /// The text cannot be searched (a control character, too long).
    case refused(FolderSearchTextIssue)

    /// Whether the search is over for the text (anything but `searching`).
    public var isSettled: Bool { self != .searching }
  }

  /// "Searching…".
  public static let searchingTitle = "Searching…"
  /// "No folders found".
  public static let noneFoundTitle = "No folders found"
  /// "No other folders found".
  public static let noneElseTitle = "No other folders found"
  /// "Missing a folder?", the section's help row and Settings' heading.
  public static let helpTitle = "Missing a folder?"
  /// The help row's link to Settings › Directories.
  public static let openSettingsTitle = "Open muxFinder Settings"
  /// The help row's link to This Mac's Spotlight settings.
  public static let openSpotlightSettingsTitle = "Open Spotlight settings"
  /// This Mac's Spotlight pane in System Settings (opened only by the user's click).
  public static let spotlightSettingsURL = URL(
    string: "x-apple.systempreferences:com.apple.Spotlight-Settings.extension")!
  /// What "Missing a folder?" says, one paragraph each (PLAN.md D36's noise rule, Spotlight's
  /// limits, the scope and SSH's privacy protection); shown in the section and in Settings ›
  /// Directories.
  public static let missingFolderExplanation = [
    "Results come from Spotlight on the host, which matches folder names, not paths. Only the "
      + "first \(FolderSearchScript.resultLimit) folders found are listed.",
    "Folders whose names start with a dot, and anything excluded in Spotlight's privacy "
      + "settings, never appear.",
    "muxFinder leaves out Library folders, node_modules, DerivedData, Pods and __pycache__, "
      + "folders inside apps and other packages, and, with Whole disk, system folders such as "
      + "/System and /usr.",
    "Home folder searches only the host's home folder; choose Whole disk in Settings › "
      + "Directories to search everything Spotlight indexes.",
    "Over SSH, macOS may hide Desktop, Documents and Downloads unless the other Mac allows it "
      + "(System Settings › General › Sharing › Remote Login › Allow full disk access for remote "
      + "users, set on that Mac).",
    "An apostrophe inside a word, as in rock'n'roll, may find nothing: type the part before or "
      + "after it.",
  ]

  /// The host's display name.
  public var hostName: String
  /// Whether the host is This Mac (which offers "Open Spotlight settings").
  public var isThisMac: Bool
  /// Where the search stands.
  public var status: Status
  /// The scope the search ran in (as far as the channel says).
  public var scope: FolderSearchScope
  /// The folders listed, in Spotlight's order, as the field would take them (`~/…` under the
  /// host's home folder).
  public var entries: [String]
  /// Whether more folders matched than the answer holds.
  public var isLimited: Bool
  /// How many folders found cannot be offered (the parser's and the section's checks).
  public var droppedCount: Int
  /// The protected folders an SSH host's header found unreadable ("Desktop", "Documents",
  /// "Downloads"); always empty for This Mac.
  public var unreadableFolders: [String]

  /// The section for `field` on `host` from `snapshot`, leaving out folders in `shown` (the
  /// entries the earlier sections show); `nil` when the field's text cannot be searched.
  public init?(
    host: HostConfig,
    field: String,
    snapshot: FolderSearchSnapshot,
    shown: [String]
  ) {
    guard Self.isSearchable(field) else { return nil }
    let searchHost = FolderSearchHost(host)
    let state = snapshot.state.flatMap { $0.host == searchHost ? $0 : nil }
    let current = state.flatMap { DirectoryLists.same($0.text, field) ? $0 : nil }
    hostName = host.displayName
    isThisMac = host.isThisMac
    scope = current?.scope ?? state?.scope ?? .standard
    entries = []
    isLimited = false
    droppedCount = 0
    let header = state?.header
    unreadableFolders = host.isThisMac ? [] : header?.unreadableProtectedFolders ?? []
    switch current?.phase {
    case .answered(let answer)?:
      let rows = Self.rows(answer.paths, home: header?.homeDirectory, shown: shown)
      entries = rows.entries
      droppedCount = answer.droppedCount + rows.dropped
      isLimited = answer.isLimited
      if !entries.isEmpty {
        status = .found
      } else {
        status = rows.duplicates > 0 ? .noneElse : .noneFound
      }
    case .unavailable(let reason)?:
      status = .unavailable(reason)
      unreadableFolders = []
    case .failed(let failure)?:
      status = .failed(failure)
      unreadableFolders = []
    case .refused(let issue)?:
      status = .refused(issue)
      unreadableFolders = []
    case .searching?, .idle?, nil:
      status = .searching
      let requestScope = current?.scope ?? state?.scope
      if let previous = snapshot.previous, previous.host == searchHost,
        previous.scope == requestScope
      {
        let still = previous.paths.filter { Self.name(of: $0, contains: field) }
        entries = Self.rows(still, home: previous.header?.homeDirectory, shown: shown).entries
      }
    }
  } // End of init?(host:field:snapshot:shown:)

  // MARK: - Texts

  /// "Folders on <host>".
  public var title: String { "Folders on \(hostName)" }

  /// "Folder search isn't available on <host>".
  public var unavailableTitle: String { "Folder search isn't available on \(hostName)" }

  /// The status line shown above the rows (or in their place), `nil` while folders are listed
  /// and the search is over.
  public var statusLine: String? {
    switch status {
    case .searching: return Self.searchingTitle
    case .found: return nil
    case .noneFound: return Self.noneFoundTitle
    case .noneElse: return Self.noneElseTitle
    case .unavailable: return unavailableTitle
    case .failed(let failure): return failure.message
    case .refused(let issue): return issue.message
    }
  } // End of var statusLine

  /// Why the host cannot search, under `unavailableTitle`; `nil` for any other status.
  public var unavailableReason: String? {
    guard case .unavailable(let reason) = status else { return nil }
    switch reason {
    case .noSpotlight:
      return "Spotlight (mdfind) isn't there, as on Linux, so its folders can't be searched."
    case .indexingOff:
      let place = scope == .home ? "the disk that holds its home folder" : "its startup disk"
      return "Spotlight indexing is turned off for \(place)."
    case .noHomeFolder:
      return "Its home folder is unknown, so Home folder can't be searched. Choose Whole disk in "
        + "Settings › Directories."
    }
  } // End of var unavailableReason

  /// What VoiceOver hears of the section (and its accessibility value): "Searching…", "3
  /// folders found", "1 folder found", "No folders found", "No other folders found", the
  /// unavailable title, the failure or the refusal.
  public var summary: String {
    switch status {
    case .found:
      return entries.count == 1 ? "1 folder found" : "\(entries.count) folders found"
    default:
      return statusLine ?? ""
    }
  }

  /// "Showing the first 50 folders found…", while the answer was limited.
  public var limitedNote: String? {
    guard isLimited, status == .found else { return nil }
    return "Showing the first \(FolderSearchScript.resultLimit) folders found. Type more of the "
      + "name to narrow them down."
  }

  /// How many folders found cannot be offered, if any.
  public var droppedNote: String? {
    guard droppedCount > 0, status.isSettled else { return nil }
    let subject = droppedCount == 1 ? "1 folder found" : "\(droppedCount) folders found"
    return "\(subject) can't be offered: a line break or another control character in the "
      + "name, or a path that is too long."
  }

  /// "Desktop, Documents and Downloads on <host> can't be searched over SSH." for the folders
  /// an SSH host's header found unreadable; `nil` otherwise (always for This Mac).
  public var protectedFoldersNote: String? {
    guard !unreadableFolders.isEmpty else { return nil }
    return "\(Self.list(unreadableFolders)) on \(hostName) can't be searched over SSH."
  }

  // MARK: - Rules

  /// Whether `field` (the Directory field as typed) is searched: at least
  /// `FolderSearchText.minimumCharacters` characters, not only spaces and line breaks, and no
  /// `/` (a path, not a name).
  public static func isSearchable(_ field: String) -> Bool {
    field.count >= FolderSearchText.minimumCharacters && !field.contains("/")
      && !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// `path` as the list shows it and a pick fills it: `~/…` under `home` (compared byte for
  /// byte by whole components), `~` for the home folder itself, unchanged elsewhere or with no
  /// home known (`DirectoryPickerContent.homeFolder(_:)`'s rule: no root, no trailing slash).
  public static func displayPath(_ path: String, home: String?) -> String {
    guard let home = DirectoryPickerContent.homeFolder(home) else { return path }
    let bytes = Array(path.utf8)
    let homeBytes = Array(home.utf8)
    if bytes == homeBytes { return "~" }
    guard bytes.starts(with: homeBytes + [UInt8(ascii: "/")]) else { return path }
    return "~" + String(decoding: bytes[homeBytes.count...], as: UTF8.self)
  }

  /// Whether `entry` may be offered: it passes `DirectoryLists.check` (a typed Directory's
  /// checks, PLAN.md D31) and holds no control character (C0, DEL, C1), as session start
  /// folders must not.
  public static func isUsable(_ entry: String) -> Bool {
    guard (try? DirectoryLists.check(entry)) != nil else { return false }
    return !entry.unicodeScalars.contains { $0.properties.generalCategory == .control }
  }

  /// Whether the last component of `path` contains `text` as Spotlight's `cd` match does
  /// (ignoring case and diacritics).
  static func name(of path: String, contains text: String) -> Bool {
    let name = path.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init)
    return name.map { PopoverContent.matches($0, query: text) } ?? false
  }

  /// The rows for `paths` on a host whose home folder is `home`: usable, written by
  /// `displayPath(_:home:)`, each once, none that `shown` holds after the same rule; with how
  /// many were dropped as unusable and how many were left out as shown already.
  static func rows(
    _ paths: [String], home: String?, shown: [String]
  ) -> (entries: [String], dropped: Int, duplicates: Int) {
    var seen = Set(shown.map { Array(displayPath($0, home: home).utf8) })
    var entries: [String] = []
    var dropped = 0
    var duplicates = 0
    for path in paths {
      let entry = displayPath(path, home: home)
      guard isUsable(entry), isUsable(path) else {
        dropped += 1
        continue
      }
      guard seen.insert(Array(entry.utf8)).inserted else {
        duplicates += 1
        continue
      }
      entries.append(entry)
    } // End of loop over the paths found
    return (entries, dropped, duplicates)
  } // End of static func rows(_:home:shown:)

  /// "A", "A and B", "A, B and C".
  static func list(_ names: [String]) -> String {
    guard names.count > 1 else { return names.first ?? "" }
    return names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1]
  }
}
