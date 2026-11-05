import Foundation
import MuxFinderCore

/// How New session's directory lists last loaded (PLAN.md D31), as the picker and Settings'
/// Directories tab show it. Kinds and counts only, never a directory.
public enum DirectoryListStatus: Sendable, Hashable {
  /// Not loaded yet (or there is no store: a fixture, a test of another part).
  case notLoaded
  /// A usable file, or none yet; `droppedEntryCount` of its entries broke a rule and were left
  /// out.
  case usable(droppedEntryCount: Int)
  /// The file cannot be used: the lists are empty, the file is left as it is and every change
  /// is refused until it is fixed or moved away.
  case fileNotUsable(DirectoryFileProblem)
  /// muxFinder's folder could not be read (the store's explanation).
  case unreadable(String)

  /// The status a load came back with.
  public init(_ result: DirectoryStoreLoadResult) {
    switch result.state {
    case .saved, .notSavedYet: self = .usable(droppedEntryCount: result.droppedEntryCount)
    case .invalid(let problem): self = .fileNotUsable(problem)
    }
  }

  /// Whether a change can land: the file is usable, or was not loaded yet (the store then
  /// decides).
  public var acceptsChanges: Bool {
    switch self {
    case .notLoaded, .usable: return true
    case .fileNotUsable, .unreadable: return false
    }
  }

  /// What to tell the user: why the lists are empty and nothing can be saved, or how many
  /// entries were left out. `nil` when there is nothing to say.
  public var notice: String? {
    switch self {
    case .notLoaded, .usable(droppedEntryCount: 0):
      return nil
    case .usable(let count):
      return DirectoryStoreNotice.entriesDropped(count).message
    case .fileNotUsable(let problem):
      return DirectoryStoreNotice.fileNotUsed(problem).message
    case .unreadable(let message):
      return "muxFinder couldn't read its settings folder, so it shows no saved or recent "
        + "directories and saves none. " + message
    }
  } // End of var notice

  /// A stable name for the operation log ("usable", "fileNotUsable.notJSON", …).
  public var code: String {
    switch self {
    case .notLoaded: return "notLoaded"
    case .usable(droppedEntryCount: 0): return "usable"
    case .usable: return "usable.entriesDropped"
    case .fileNotUsable(let problem): return "fileNotUsable.\(problem.code)"
    case .unreadable: return "unreadable"
    }
  }
}

/// What New session's directory list shows for one host (PLAN.md D31): a pure value built from
/// the directory lists, the host's listed sessions and the Directory field, so its sections,
/// order, caps, filter and rules are unit-tested apart from the view.
///
/// - **Sections**, in this order, each only when it is not empty: "Recent" (the host's recent
///   directories, newest first), "Saved" (the list shared by every host, in the user's order)
///   and "Sessions on <host>" (the distinct start folders of the host's listed sessions, stale
///   ones included, sorted, at most `maximumSessionFolders`). A folder can show in more than one
///   section; within a section each shows once (exact string). With all three empty the list
///   says there is nothing to pick yet.
/// - **The filter** (Phase I-7): the Directory field is the list's search, combo-box style.
///   With its text (trimmed, `query`) empty nothing is filtered; otherwise each section keeps,
///   in its order, only the entries that match (`entry(_:matches:field:home:)`), and a section
///   left empty is hidden. When the filter hides every entry the list says "No matching
///   directories" (`noMatches`), not "Nothing to pick yet" (`isEmpty`, the host has no entry at
///   all).
/// - **Actions** below the sections, never filtered: "Save this directory" (off while the field
///   is empty, breaks `Validation.workingDirectory` or the entry rules, is saved already, the
///   saved list is full, or the store takes no change) and "Clear recent directories on
///   <host>" (off with no recent directory, shown or not, or while the store takes no change).
/// - **Items** are what the keyboard moves through: every entry shown, then the actions that
///   are on. An entry's identity is its section and its UTF-8 bytes, as the store's (`Item`),
///   so two spellings of one accented name are two rows the keys pass through in turn.
/// - Every entry is display data until picked: picking only fills the Directory field, which
///   the draft checks like typed text before any request (D3, D18).
public struct DirectoryPickerContent: Sendable, Hashable {
  /// The most session start folders listed.
  public static let maximumSessionFolders = 10
  /// "Save this directory".
  public static let saveTitle = "Save this directory"
  /// What the list (and the button) says with nothing to pick.
  public static let nothingToPick = "Nothing to pick yet"
  /// The explanation under `nothingToPick`.
  public static let nothingToPickExplanation =
    "Directories you create sessions in or save, and those this host's sessions started in, "
    + "appear here."
  /// What the list says when the filter hides every entry (and what VoiceOver hears then).
  public static let noMatchesTitle = "No matching directories"
  /// The explanation under `noMatchesTitle`.
  public static let noMatchesExplanation =
    "No directory in the list contains what you typed. Clear the field to see them all."

  /// One section of the list.
  public enum SectionKind: Sendable, Hashable, CaseIterable {
    /// The host's recent directories.
    case recent
    /// The shared saved directories.
    case saved
    /// The start folders of the host's sessions.
    case sessions
  }

  /// A titled group of directories.
  public struct Section: Sendable, Hashable, Identifiable {
    /// Which section.
    public var kind: SectionKind
    /// "Recent", "Saved", "Sessions on Saturno".
    public var title: String
    /// The directories, in the section's order.
    public var entries: [String]

    /// `Identifiable` conformance: the kind.
    public var id: SectionKind { kind }

    /// The section's rows, one per entry, in order.
    public var items: [Item] { entries.map { Item.entry(kind, $0) } }

    /// Equal sections have the same kind and title and the same entries byte for byte
    /// (`DirectoryLists.sameEntries(_:_:)`), as the store compares them. The synthesized hash
    /// stays consistent: entries equal byte for byte hash alike.
    public static func == (first: Section, second: Section) -> Bool {
      first.kind == second.kind && first.title == second.title
        && DirectoryLists.sameEntries(first.entries, second.entries)
    }
  } // End of struct Section

  /// A button below the sections.
  public enum Action: Sendable, Hashable {
    /// "Save this directory": adds the field's value to the saved list.
    case saveDirectory
    /// "Clear recent directories on <host>".
    case clearRecents
  }

  /// One row the keyboard can highlight and the user can pick. Its identity (equality, hashing,
  /// the view's row identity and the keyboard's position) is the section with the directory's
  /// UTF-8 bytes, so two spellings of an accented name, which the store keeps as two entries,
  /// are two rows (`String`'s `==` would take them for one).
  public enum Item: Sendable, Hashable {
    /// A directory of a section.
    case entry(SectionKind, String)
    /// An action.
    case action(Action)

    /// The directory of an entry row, `nil` for an action.
    public var directory: String? {
      if case .entry(_, let directory) = self { return directory }
      return nil
    }

    /// The same row: the same section and directory byte for byte, or the same action.
    public static func == (first: Item, second: Item) -> Bool {
      switch (first, second) {
      case (.entry(let firstKind, let firstDirectory), .entry(let secondKind, let secondDirectory)):
        return firstKind == secondKind && DirectoryLists.same(firstDirectory, secondDirectory)
      case (.action(let firstAction), .action(let secondAction)):
        return firstAction == secondAction
      default:
        return false
      }
    }

    /// Hashes what `==` compares: the section and the directory's UTF-8 bytes, or the action.
    public func hash(into hasher: inout Hasher) {
      switch self {
      case .entry(let kind, let directory):
        hasher.combine(0)
        hasher.combine(kind)
        hasher.combine(Array(directory.utf8))
      case .action(let action):
        hasher.combine(1)
        hasher.combine(action)
      }
    } // End of func hash(into:)
  } // End of enum Item

  /// Why "Save this directory" is off.
  public enum SaveIssue: Sendable, Hashable {
    /// The store takes no change (an unusable file, an unreadable folder, no store).
    case storeUnavailable
    /// The field is empty.
    case empty
    /// The field breaks a rule; the rule's message.
    case invalid(String)
    /// The field's value is saved already (exact string).
    case alreadySaved
    /// The saved list holds `DirectoryLists.maximumSavedCount` entries.
    case listFull

    /// The explanation, as the button's help.
    public var help: String {
      switch self {
      case .storeUnavailable: return "muxFinder can't change its directory list right now."
      case .empty: return "Type or pick a directory first."
      case .invalid(let message): return message
      case .alreadySaved: return "This directory is saved already."
      case .listFull: return DirectoryListError.tooManySaved.message
      }
    }
  } // End of enum SaveIssue

  /// The host's display name.
  public var hostName: String
  /// The sections shown: those with entries left after the filter, in order.
  public var sections: [Section]
  /// Why "Save this directory" is off, or `nil` when it is on.
  public var saveIssue: SaveIssue?
  /// Whether "Clear recent directories on <host>" is on.
  public var canClearRecents: Bool
  /// Why the lists are empty and nothing can be changed (an unusable file, an unreadable
  /// folder), shown at the top of the list.
  public var notice: String?
  /// The Directory field's text the entries are filtered by, trimmed of surrounding spaces and
  /// line breaks; empty when nothing is filtered.
  public var query: String
  /// How many entries the sections hold before the filter (a folder in two sections counts
  /// twice).
  public var unfilteredEntryCount: Int

  /// The list for `host`: its recent directories and the saved ones from `lists`, the start
  /// folders of `sessions` (the host's listed sessions), filtered by `field` (the Directory
  /// field as typed), which "Save this directory" would also add, with `status` the lists' load
  /// status and `canChange` whether a store takes changes at all. `thisMacHome` is This Mac's
  /// home folder for the filter's `~` rule; it is used only when `host` is This Mac (an SSH
  /// host's home folder is unknown), and `nil` turns the rule off.
  public init(
    host: HostConfig,
    lists: DirectoryLists,
    sessions: [HostSnapshot.Session],
    field: String,
    status: DirectoryListStatus = .notLoaded,
    canChange: Bool = true,
    thisMacHome: String? = nil
  ) {
    hostName = host.displayName
    let recent = lists.recent(for: host.id)
    let candidates: [(SectionKind, String, [String])] = [
      (.recent, "Recent", recent),
      (.saved, "Saved", lists.saved),
      (.sessions, "Sessions on \(host.displayName)", Self.sessionFolders(sessions)),
    ]
    let query = Self.query(field)
    let home = host.isThisMac ? Self.homeFolder(thisMacHome) : nil
    self.query = query
    unfilteredEntryCount = candidates.reduce(0) { $0 + $1.2.count }
    sections = candidates.compactMap { kind, title, entries in
      let shown =
        query.isEmpty
        ? entries
        : entries.filter { Self.entry($0, matches: query, field: field, home: home) }
      return shown.isEmpty ? nil : Section(kind: kind, title: title, entries: shown)
    }
    let acceptsChanges = canChange && status.acceptsChanges
    saveIssue = Self.saveIssue(field: field, lists: lists, acceptsChanges: acceptsChanges)
    canClearRecents = acceptsChanges && !recent.isEmpty
    notice = status.acceptsChanges ? nil : status.notice
  } // End of init(host:lists:sessions:field:status:canChange:thisMacHome:)

  /// Whether the host has nothing to pick at all (every section empty before the filter): the
  /// list says "Nothing to pick yet", whatever the field holds.
  public var isEmpty: Bool { unfilteredEntryCount == 0 }

  /// Whether the filter hides every entry the host has: the list says "No matching
  /// directories" above the actions.
  public var noMatches: Bool { !isEmpty && sections.isEmpty }

  /// How many entry rows the list shows (after the filter; actions not counted).
  public var matchCount: Int { sections.reduce(0) { $0 + $1.entries.count } }

  /// What VoiceOver hears when the filter changes (and the list's accessibility value): "3
  /// matching directories", "1 matching directory" or "No matching directories" while the
  /// field filters the list, "8 directories" or "1 directory" while it does not, and "Nothing
  /// to pick yet" when the host has no entry at all.
  public var matchSummary: String {
    if isEmpty { return Self.nothingToPick }
    let count = matchCount
    guard !query.isEmpty else { return count == 1 ? "1 directory" : "\(count) directories" }
    switch count {
    case 0: return Self.noMatchesTitle
    case 1: return "1 matching directory"
    default: return "\(count) matching directories"
    }
  } // End of var matchSummary

  /// "Clear recent directories on <host>".
  public var clearTitle: String { "Clear recent directories on \(hostName)" }

  /// Whether "Save this directory" is on.
  public var canSaveDirectory: Bool { saveIssue == nil }

  /// Whether `action` is on.
  public func isEnabled(_ action: Action) -> Bool {
    switch action {
    case .saveDirectory: return canSaveDirectory
    case .clearRecents: return canClearRecents
    }
  }

  /// The rows the keyboard moves through, in the list's order: every entry shown (after the
  /// filter), then the actions that are on.
  public var items: [Item] {
    let entries = sections.flatMap(\.items)
    let actions = [Action.saveDirectory, .clearRecents].filter(isEnabled).map(Item.action)
    return entries + actions
  }

  /// The item after (`down`) or before `current` in `items`, staying at the ends; with no
  /// current item (or one the list no longer has), ↓ gives the first and ↑ the last. `nil`
  /// when there are no items.
  public func item(movingFrom current: Item?, down: Bool) -> Item? {
    let items = self.items
    guard !items.isEmpty else { return nil }
    guard let current, let position = items.firstIndex(of: current) else {
      return down ? items.first : items.last
    }
    return items[down ? min(position + 1, items.count - 1) : max(position - 1, 0)]
  }

  /// The distinct start folders of `sessions` that pass the entry rules, sorted as Finder
  /// sorts names (byte order breaks ties), at most `maximumSessionFolders`. Sessions without
  /// a usable folder are skipped.
  public static func sessionFolders(_ sessions: [HostSnapshot.Session]) -> [String] {
    var seen = Set<[UInt8]>()
    var folders: [String] = []
    for session in sessions {
      guard let folder = session.discovered.startDirectory,
        (try? DirectoryLists.check(folder)) != nil,
        seen.insert(Array(folder.utf8)).inserted
      else { continue }
      folders.append(folder)
    } // End of loop over the host's sessions
    folders.sort { first, second in
      switch first.localizedStandardCompare(second) {
      case .orderedAscending: return true
      case .orderedDescending: return false
      case .orderedSame: return first.utf8.lexicographicallyPrecedes(second.utf8)
      }
    }
    return Array(folders.prefix(maximumSessionFolders))
  } // End of static func sessionFolders(_:)

  // MARK: - The filter (Phase I-7)

  /// The text `field` filters by: the field as typed, trimmed of surrounding spaces and line
  /// breaks (as the popover's search). Never expanded: a `~` in it is matched as typed.
  public static func query(_ field: String) -> String {
    field.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// `home` as the `~` rule uses it: without trailing slashes; `nil` for none, an empty one or
  /// the root folder (which would turn every absolute path into a `~` one).
  static func homeFolder(_ home: String?) -> String? {
    guard var home else { return nil }
    while home.hasSuffix("/") { home.removeLast() }
    return home.isEmpty ? nil : home
  }

  /// Whether `entry` shows while the field holds `field` (`query` its trimmed text, not empty):
  /// it equals the field byte for byte (picking it would change nothing, but hiding it would
  /// confuse), or one of its spellings (`spellings(of:home:)`) contains `query`, ignoring case
  /// and diacritics, as the popover's search matches (`PopoverContent.matches(_:query:)`).
  public static func entry(
    _ entry: String,
    matches query: String,
    field: String,
    home: String?
  ) -> Bool {
    if DirectoryLists.same(entry, field) { return true }
    return spellings(of: entry, home: home).contains { PopoverContent.matches($0, query: query) }
  }

  /// The spellings `entry` is matched in: as stored and, with This Mac's `home` folder known
  /// (`nil` for an SSH host, whose home is unknown), with a leading home folder written `~`
  /// (`<home>/x` as `~/x`, `<home>` as `~`) or with a leading `~` or `~/` spelled out as the
  /// home folder (`~/x` as `<home>/x`, `~` as `<home>`). The home folder is compared byte for
  /// byte and must end at a slash or the entry's end; `~user` forms are never expanded.
  static func spellings(of entry: String, home: String?) -> [String] {
    guard let home else { return [entry] }
    let bytes = Array(entry.utf8)
    let homeBytes = Array(home.utf8)
    let slash = UInt8(ascii: "/")
    if bytes == homeBytes { return [entry, "~"] }
    if bytes.starts(with: homeBytes + [slash]) {
      return [entry, "~" + String(decoding: bytes[homeBytes.count...], as: UTF8.self)]
    }
    if bytes == [UInt8(ascii: "~")] { return [entry, home] }
    if bytes.starts(with: [UInt8(ascii: "~"), slash]) {
      return [entry, home + String(decoding: bytes[1...], as: UTF8.self)]
    }
    return [entry]
  } // End of static func spellings(of:home:)

  /// Why "Save this directory" is off for `field`, or `nil`: the store takes no change, the
  /// field is empty, breaks a rule, is saved already, or the saved list is full.
  static func saveIssue(
    field: String,
    lists: DirectoryLists,
    acceptsChanges: Bool
  ) -> SaveIssue? {
    guard acceptsChanges else { return .storeUnavailable }
    guard !field.isEmpty else { return .empty }
    do throws(DirectoryListError) {
      _ = try DirectoryLists.check(field)
    } catch {
      return .invalid(error.message)
    }
    if lists.isSaved(field) { return .alreadySaved }
    if lists.saved.count >= DirectoryLists.maximumSavedCount { return .listFull }
    return nil
  } // End of static func saveIssue(field:lists:acceptsChanges:)
}

/// New session's directory list as the popover shows it: open or closed and how it was opened,
/// the row the keyboard highlights, and what the last save or clear could not do.
public struct DirectoryPickerState: Sendable, Hashable {
  /// How the open list was opened (PLAN.md D31, Phase I-7), which decides whether an edit of
  /// the Directory field may close it again.
  public enum Opening: Sendable, Hashable {
    /// The user asked for it: the pull-down button (or Space on it) or ⌥↓. It stays open
    /// whatever the field holds, showing "No matching directories" when the filter hides
    /// every entry, until Esc, the button, a pick, a creation or the window closing.
    case request
    /// An edit of the field that left an entry matching opened it: an edit that matches
    /// nothing, or leaves the field empty, closes it again.
    case typing
  }

  /// How the list was opened while it shows under the Directory field; `nil` while it is
  /// closed.
  public var opening: Opening?
  /// The highlighted row, if any: set by ↑/↓, ⌥↓ and the pointer, dropped when the Directory
  /// field's text changes, ignored when the list no longer has it.
  public var highlighted: DirectoryPickerContent.Item?
  /// Why the last "Save this directory" or "Clear recent directories" did nothing, shown in
  /// the list; never a directory.
  public var problem: String?

  /// Whether the list shows under the Directory field.
  public var isOpen: Bool { opening != nil }

  /// A state; closed by default. `isOpen` opens it as the button does (`Opening.request`).
  public init(
    isOpen: Bool = false,
    highlighted: DirectoryPickerContent.Item? = nil,
    problem: String? = nil
  ) {
    self.init(opening: isOpen ? .request : nil, highlighted: highlighted, problem: problem)
  }

  /// A state opened as `opening` says (`nil`: closed).
  public init(
    opening: Opening?,
    highlighted: DirectoryPickerContent.Item? = nil,
    problem: String? = nil
  ) {
    self.opening = opening
    self.highlighted = highlighted
    self.problem = problem
  }
}
