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
/// order, caps and rules are unit-tested apart from the view.
///
/// - **Sections**, in this order, each only when it is not empty: "Recent" (the host's recent
///   directories, newest first), "Saved" (the list shared by every host, in the user's order)
///   and "Sessions on <host>" (the distinct start folders of the host's listed sessions, stale
///   ones included, sorted, at most `maximumSessionFolders`). A folder can show in more than one
///   section; within a section each shows once (exact string). With all three empty the list
///   says there is nothing to pick yet.
/// - **Actions** below the sections: "Save this directory" (off while the field is empty,
///   breaks `Validation.workingDirectory` or the entry rules, is saved already, the saved list
///   is full, or the store takes no change) and "Clear recent directories on <host>" (off with
///   no recent directory or while the store takes no change).
/// - **Items** are what the keyboard moves through: every entry, then the actions that are on.
///   An entry's identity is its section and its UTF-8 bytes, as the store's (`Item`), so two
///   spellings of one accented name are two rows the keys pass through in turn.
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
  /// The sections that are not empty, in order.
  public var sections: [Section]
  /// Why "Save this directory" is off, or `nil` when it is on.
  public var saveIssue: SaveIssue?
  /// Whether "Clear recent directories on <host>" is on.
  public var canClearRecents: Bool
  /// Why the lists are empty and nothing can be changed (an unusable file, an unreadable
  /// folder), shown at the top of the list.
  public var notice: String?

  /// The list for `host`: its recent directories and the saved ones from `lists`, the start
  /// folders of `sessions` (the host's listed sessions), "Save this directory" for `field` (the
  /// Directory field as typed), with `status` the lists' load status and `canChange` whether
  /// a store takes changes at all.
  public init(
    host: HostConfig,
    lists: DirectoryLists,
    sessions: [HostSnapshot.Session],
    field: String,
    status: DirectoryListStatus = .notLoaded,
    canChange: Bool = true
  ) {
    hostName = host.displayName
    let recent = lists.recent(for: host.id)
    let candidates: [(SectionKind, String, [String])] = [
      (.recent, "Recent", recent),
      (.saved, "Saved", lists.saved),
      (.sessions, "Sessions on \(host.displayName)", Self.sessionFolders(sessions)),
    ]
    sections = candidates.compactMap { kind, title, entries in
      entries.isEmpty ? nil : Section(kind: kind, title: title, entries: entries)
    }
    let acceptsChanges = canChange && status.acceptsChanges
    saveIssue = Self.saveIssue(field: field, lists: lists, acceptsChanges: acceptsChanges)
    canClearRecents = acceptsChanges && !recent.isEmpty
    notice = status.acceptsChanges ? nil : status.notice
  } // End of init(host:lists:sessions:field:status:canChange:)

  /// Whether every section is empty: the list says there is nothing to pick yet.
  public var isEmpty: Bool { sections.isEmpty }

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

  /// The rows the keyboard moves through, in the list's order: every entry, then the actions
  /// that are on.
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

/// New session's directory list as the popover shows it: open or closed, the row the keyboard
/// highlights, and what the last save or clear could not do.
public struct DirectoryPickerState: Sendable, Hashable {
  /// Whether the list shows under the Directory field.
  public var isOpen: Bool
  /// The highlighted row, if any: set by ↑/↓, ⌥↓ and the pointer, dropped when the Directory
  /// field's text changes, ignored when the list no longer has it.
  public var highlighted: DirectoryPickerContent.Item?
  /// Why the last "Save this directory" or "Clear recent directories" did nothing, shown in
  /// the list; never a directory.
  public var problem: String?

  /// A state; closed by default.
  public init(
    isOpen: Bool = false,
    highlighted: DirectoryPickerContent.Item? = nil,
    problem: String? = nil
  ) {
    self.isOpen = isOpen
    self.highlighted = highlighted
    self.problem = problem
  }
}
