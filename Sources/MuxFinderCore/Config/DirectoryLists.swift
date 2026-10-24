import Foundation

/// Why a change to the directory lists was refused (PLAN.md D31). Nothing was changed.
/// `message` is English, sentence case, and never quotes the directory.
public enum DirectoryListError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The directory is empty (the home folder, which is never kept).
  case entryEmpty
  /// The directory breaks `Validation.workingDirectory(_:)`.
  case entryInvalid(ValidationError)
  /// The directory is longer than `DirectoryLists.maximumEntryLength` bytes.
  case entryTooLong
  /// The saved list holds `DirectoryLists.maximumSavedCount` entries already.
  case tooManySaved
  /// A move names a position outside the saved list.
  case positionOutOfRange

  /// A stable, machine-readable name (the operation log records it, never the directory).
  public var code: String {
    switch self {
    case .entryEmpty: return "entryEmpty"
    case .entryInvalid: return "entryInvalid"
    case .entryTooLong: return "entryTooLong"
    case .tooManySaved: return "tooManySaved"
    case .positionOutOfRange: return "positionOutOfRange"
    }
  }

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .entryEmpty:
      return "Enter a directory."
    case .entryInvalid(let error):
      return error.message
    case .entryTooLong:
      return "Directories can be at most \(DirectoryLists.maximumEntryLength) bytes long."
    case .tooManySaved:
      return "muxFinder keeps at most \(DirectoryLists.maximumSavedCount) saved directories."
    case .positionOutOfRange:
      return "That position isn't in the list of saved directories."
    }
  } // End of var message

  /// The same as `message`.
  public var description: String { message }
}

/// One change to the directory lists, as `DirectoryStoring.apply(_:knownHosts:)` takes it.
public enum DirectoryListChange: Sendable, Hashable {
  /// Adds a directory at the end of the saved list (nothing changes when it is saved already).
  case addSaved(String)
  /// Removes a directory from the saved list (nothing changes when it is not there).
  case removeSaved(String)
  /// Moves the saved entry at `from` so it ends at position `to`.
  case moveSaved(from: Int, to: Int)
  /// Replaces the saved list: checked entry by entry, duplicates collapsed.
  case replaceSaved([String])
  /// Settings' Save: applies the edits that turned `base` (the saved list the edits started
  /// from) into `edited` to the saved list as it is when the change runs
  /// (`DirectoryLists.mergeSaved(base:edited:)`), so what changed elsewhere since is kept.
  case mergeSaved(base: [String], edited: [String])
  /// Records a directory New session created a session in, newest first, for one host.
  case recordRecent(String, hostID: UUID)
  /// Forgets every recent directory of one host.
  case clearRecents(hostID: UUID)

  /// A stable, machine-readable name (never the directory).
  public var kind: String {
    switch self {
    case .addSaved: return "addSaved"
    case .removeSaved: return "removeSaved"
    case .moveSaved: return "moveSaved"
    case .replaceSaved: return "replaceSaved"
    case .mergeSaved: return "mergeSaved"
    case .recordRecent: return "recordRecent"
    case .clearRecents: return "clearRecents"
    }
  }
}

/// The directories New session offers (PLAN.md D31): one saved list shared by every host, and
/// the recent directories of each host, newest first.
///
/// - Every entry is a directory as the user typed it or as New session checked it: it passes
///   `Validation.workingDirectory(_:)`, is not empty (the home folder is never kept) and is at
///   most `maximumEntryLength` bytes. `~/…` paths are kept as they are and resolve on each host
///   (PLAN.md D18); muxFinder cannot know a remote home folder, so `~/x` and `/Users/…/x` are two
///   entries.
/// - Duplicates collapse by exact string, compared byte for byte (UTF-8), so two spellings of
///   the same accented name stay two entries, as they can be two folders on a host. Two lists
///   are equal (`==`) by the same rule.
/// - At most `maximumSavedCount` saved entries (adding more is refused) and
///   `maximumRecentCount` recent ones per host (recording one more drops the oldest).
/// - Directories are user data: they never go into logs or diagnostics (kinds and counts only).
public struct DirectoryLists: Sendable, Hashable {
  /// The most saved directories kept.
  public static let maximumSavedCount = 50
  /// The most recent directories kept per host.
  public static let maximumRecentCount = 8
  /// The longest directory kept, in bytes of UTF-8 (Linux's `PATH_MAX`; macOS's is 1,024).
  public static let maximumEntryLength = 4096

  /// The saved directories, in the user's order.
  public private(set) var saved: [String]
  /// The recent directories per host (`HostConfig.id`), newest first. A host without recent
  /// directories has no key.
  public private(set) var recent: [UUID: [String]]

  /// Empty lists.
  public init() {
    saved = []
    recent = [:]
  }

  /// Lists made of `saved` and `recent`, each entry checked: entries that break a rule,
  /// duplicates and entries past the caps are left out, and `droppedCount` counts the ones left
  /// out for breaking a rule or a cap (a duplicate loses nothing, so it is not counted). Order is
  /// kept.
  public init(saved: [String], recent: [UUID: [String]]) {
    var dropped = 0
    self.init(saved: saved, recent: recent, droppedCount: &dropped)
  }

  /// The checking initializer; adds what it left out to `droppedCount`.
  init(saved: [String], recent: [UUID: [String]], droppedCount: inout Int) {
    self.saved = Self.cleaned(saved, cap: Self.maximumSavedCount, droppedCount: &droppedCount)
    var kept: [UUID: [String]] = [:]
    for (hostID, entries) in recent {
      let cleaned = Self.cleaned(
        entries, cap: Self.maximumRecentCount, droppedCount: &droppedCount)
      if !cleaned.isEmpty { kept[hostID] = cleaned }
    }
    self.recent = kept
  } // End of init(saved:recent:droppedCount:)

  /// Whether both lists are empty.
  public var isEmpty: Bool { saved.isEmpty && recent.isEmpty }

  /// The recent directories of `hostID`, newest first.
  public func recent(for hostID: UUID) -> [String] {
    recent[hostID] ?? []
  }

  /// Whether `entry` is saved (exact string).
  public func isSaved(_ entry: String) -> Bool {
    saved.contains { Self.same($0, entry) }
  }

  // MARK: - Checks

  /// Checks one entry and returns it unchanged: not empty, `Validation.workingDirectory(_:)`,
  /// at most `maximumEntryLength` bytes.
  public static func check(_ entry: String) throws(DirectoryListError) -> String {
    guard !entry.isEmpty else { throw .entryEmpty }
    do throws(ValidationError) {
      _ = try Validation.workingDirectory(entry)
    } catch {
      throw .entryInvalid(error)
    }
    guard entry.utf8.count <= maximumEntryLength else { throw .entryTooLong }
    return entry
  } // End of static func check(_:)

  /// Whether `first` and `second` are the same entry: the same bytes (no Unicode
  /// normalization, unlike `String`'s `==`).
  public static func same(_ first: String, _ second: String) -> Bool {
    first.utf8.elementsEqual(second.utf8)
  }

  /// Whether `first` and `second` hold the same entries in the same order, each compared byte
  /// for byte (`same(_:_:)`).
  public static func sameEntries(_ first: [String], _ second: [String]) -> Bool {
    first.count == second.count && zip(first, second).allSatisfy { same($0, $1) }
  }

  /// Whether both lists hold the same entries byte for byte: the same saved list in the same
  /// order and, for every host, the same recent directories. (`String`'s own `==` would take
  /// two spellings of an accented name for one, and `@Observable` models skip telling their
  /// views about a value equal to the one they hold.) The synthesized hash stays consistent:
  /// entries equal byte for byte hash alike.
  public static func == (first: DirectoryLists, second: DirectoryLists) -> Bool {
    guard sameEntries(first.saved, second.saved), first.recent.count == second.recent.count
    else { return false }
    return first.recent.allSatisfy { hostID, entries in
      second.recent[hostID].map { sameEntries(entries, $0) } ?? false
    }
  }

  /// `entries` checked, in order, without duplicates, at most `cap` long; adds the entries
  /// left out for a rule or the cap to `droppedCount`.
  static func cleaned(_ entries: [String], cap: Int, droppedCount: inout Int) -> [String] {
    var kept: [String] = []
    var seen = Set<[UInt8]>()
    for entry in entries {
      guard (try? check(entry)) != nil else {
        droppedCount += 1
        continue
      }
      guard seen.insert(Array(entry.utf8)).inserted else { continue }
      guard kept.count < cap else {
        droppedCount += 1
        continue
      }
      kept.append(entry)
    } // End of loop over entries
    return kept
  } // End of static func cleaned(_:cap:droppedCount:)

  // MARK: - Changes

  /// Applies `change`, or throws without changing anything.
  public mutating func apply(_ change: DirectoryListChange) throws(DirectoryListError) {
    switch change {
    case .addSaved(let entry): try addSaved(entry)
    case .removeSaved(let entry): removeSaved(entry)
    case .moveSaved(let from, let to): try moveSaved(from: from, to: to)
    case .replaceSaved(let entries): try replaceSaved(entries)
    case .mergeSaved(let base, let edited): try mergeSaved(base: base, edited: edited)
    case .recordRecent(let entry, let hostID): try recordRecent(entry, for: hostID)
    case .clearRecents(let hostID): clearRecents(for: hostID)
    }
  }

  /// Adds `entry` at the end of the saved list; an entry saved already stays where it is.
  public mutating func addSaved(_ entry: String) throws(DirectoryListError) {
    let checked = try Self.check(entry)
    guard !isSaved(checked) else { return }
    guard saved.count < Self.maximumSavedCount else { throw .tooManySaved }
    saved.append(checked)
  }

  /// Removes `entry` from the saved list, if it is there.
  public mutating func removeSaved(_ entry: String) {
    saved.removeAll { Self.same($0, entry) }
  }

  /// Moves the saved entry at `source` so it ends at position `destination` (both within the
  /// list).
  public mutating func moveSaved(from source: Int, to destination: Int) throws(DirectoryListError) {
    guard saved.indices.contains(source), saved.indices.contains(destination) else {
      throw .positionOutOfRange
    }
    let entry = saved.remove(at: source)
    saved.insert(entry, at: destination)
  }

  /// Replaces the saved list with `entries`: every entry is checked first (the first that
  /// breaks a rule is thrown and nothing changes), duplicates collapse to their first place,
  /// and more than `maximumSavedCount` distinct entries are refused.
  public mutating func replaceSaved(_ entries: [String]) throws(DirectoryListError) {
    var kept: [String] = []
    var seen = Set<[UInt8]>()
    for entry in entries {
      let checked = try Self.check(entry)
      guard seen.insert(Array(checked.utf8)).inserted else { continue }
      kept.append(checked)
    } // End of loop over the new saved entries
    guard kept.count <= Self.maximumSavedCount else { throw .tooManySaved }
    saved = kept
  } // End of mutating func replaceSaved(_:)

  /// Settings' Save (PLAN.md D31): applies the edits that turned `base` (the saved list the
  /// edits started from) into `edited` to the saved list as it is now, a three-way merge with
  /// entries compared byte for byte. The result is `edited` (its order, its additions, without
  /// what it removed) less the entries removed from the saved list since `base`, followed by the
  /// entries added to it since `base` that `edited` lacks, in their current order. With the
  /// saved list still `base`, that is `edited` itself. Then `replaceSaved(_:)` checks it: an
  /// entry that breaks a rule, or more than `maximumSavedCount` entries, changes nothing.
  public mutating func mergeSaved(base: [String], edited: [String]) throws(DirectoryListError) {
    let baseEntries = Set(base.map { Array($0.utf8) })
    let editedEntries = Set(edited.map { Array($0.utf8) })
    let currentEntries = Set(saved.map { Array($0.utf8) })
    let kept = edited.filter { entry in
      let bytes = Array(entry.utf8)
      return !baseEntries.contains(bytes) || currentEntries.contains(bytes)
    }
    let addedElsewhere = saved.filter { entry in
      let bytes = Array(entry.utf8)
      return !baseEntries.contains(bytes) && !editedEntries.contains(bytes)
    }
    try replaceSaved(kept + addedElsewhere)
  } // End of mutating func mergeSaved(base:edited:)

  /// Records `entry` as `hostID`'s newest recent directory: an earlier copy of it moves to the
  /// front, and the oldest entry goes once there are more than `maximumRecentCount`.
  public mutating func recordRecent(_ entry: String, for hostID: UUID) throws(DirectoryListError) {
    let checked = try Self.check(entry)
    var entries = recent[hostID] ?? []
    entries.removeAll { Self.same($0, checked) }
    entries.insert(checked, at: 0)
    if entries.count > Self.maximumRecentCount {
      entries.removeLast(entries.count - Self.maximumRecentCount)
    }
    recent[hostID] = entries
  } // End of mutating func recordRecent(_:for:)

  /// Forgets `hostID`'s recent directories.
  public mutating func clearRecents(for hostID: UUID) {
    recent[hostID] = nil
  }

  /// Forgets the recent directories of every host not in `hostIDs` (hosts removed from the host
  /// list).
  public mutating func pruneRecents(keeping hostIDs: Set<UUID>) {
    recent = recent.filter { hostIDs.contains($0.key) }
  }
}
