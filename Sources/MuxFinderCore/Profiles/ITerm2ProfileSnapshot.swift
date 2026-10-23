import CryptoKit
import Darwin
import Foundation

/// Why a profile hash snapshot could not be taken. Messages hold no file or profile contents.
public enum ITerm2ProfileSnapshotError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The `DynamicProfiles` folder could not be read (it is a link, not a folder, another
  /// user's, or a system call failed).
  case directoryUnusable(String)
  /// An entry of the folder could not be read; its name.
  case entryUnreadable(name: String, errno: Int32)
  /// `defaults export` could not be run.
  case defaultsNotRun(String)
  /// `defaults export` failed (its exit status, or -1 for a signal or a timeout).
  case defaultsFailed(status: Int32)
  /// `defaults export` printed more than `ITerm2ProfileSnapshotter.exportLimit` bytes.
  case defaultsOutputTooLarge
  /// `defaults export` printed something that is not a property list with a dictionary root.
  case defaultsOutputUnreadable
  /// `New Bookmarks` is not an array, or holds a value the canonical form does not know.
  case bookmarksUnreadable

  /// A short developer-facing description.
  public var description: String {
    switch self {
    case .directoryUnusable(let reason): return "The DynamicProfiles folder is unusable: \(reason)"
    case .entryUnreadable(let name, let code):
      return "\(name) could not be read: \(String(cString: strerror(code)))."
    case .defaultsNotRun(let reason): return "defaults export could not run: \(reason)"
    case .defaultsFailed(let status): return "defaults export failed (status \(status))."
    case .defaultsOutputTooLarge: return "defaults export printed too much."
    case .defaultsOutputUnreadable: return "defaults export printed no readable property list."
    case .bookmarksUnreadable: return "New Bookmarks is not an array of property list values."
    }
  } // End of var description
}

/// A read-only fingerprint of the iTerm2 settings Phase 11's acceptance says muxFinder must not
/// change (PLAN.md D26): every entry of the `DynamicProfiles` folder except `muxFinder.json`,
/// and the `New Bookmarks` array (iTerm2's own profiles) of `com.googlecode.iterm2` without
/// the copies iTerm2 itself writes there of muxFinder's loaded dynamic profiles, as far as
/// `ITerm2ProfileSnapshotter.MirrorRule` proves them to be such copies; those are only
/// counted. It holds names, kinds, counts and SHA-256 digests only, never contents: profile
/// names are the user's.
/// `differences(from:)` is empty exactly when nothing it hashes changed; `==` also compares
/// how many mirrored entries were left out.
public struct ITerm2ProfileSnapshot: Sendable, Hashable, Codable {
  /// One entry of the `DynamicProfiles` folder.
  public struct Entry: Sendable, Hashable, Codable {
    /// What the entry is.
    public enum Kind: String, Sendable, Hashable, Codable {
      /// A regular file; `sha256` digests its bytes.
      case file
      /// A symbolic link (never followed); `sha256` digests the link's text.
      case symbolicLink
      /// A folder (not descended into).
      case directory
      /// Anything else (a FIFO, a socket …), never opened.
      case other
    }

    /// The entry's name in the folder.
    public var name: String
    /// What it is.
    public var kind: Kind
    /// The lowercase hexadecimal SHA-256 of a file's bytes or a link's text; `nil` otherwise.
    public var sha256: String?
  }

  /// The `New Bookmarks` array's fingerprint: its entries in order, without iTerm2's mirrors of
  /// muxFinder's own dynamic profiles, which are counted in `excludedMuxFinderEntries` only.
  public struct Bookmarks: Sendable, Hashable, Codable {
    /// How many profiles were hashed: every entry but the excluded ones.
    public var count: Int
    /// The lowercase hexadecimal SHA-256 of the canonical form (`CanonicalPropertyList`) of the
    /// hashed entries, as an array in their order.
    public var sha256: String
    /// How many entries were left out as iTerm2's mirrors of muxFinder's own profiles
    /// (`ITerm2ProfileSnapshotter.MirrorRule`: a generated `Guid`, the owned file's exact path
    /// and, when the caller knows what it wrote, every written key unchanged).
    public var excludedMuxFinderEntries: Int

    /// Creates a fingerprint.
    public init(count: Int, sha256: String, excludedMuxFinderEntries: Int = 0) {
      self.count = count
      self.sha256 = sha256
      self.excludedMuxFinderEntries = excludedMuxFinderEntries
    }

    /// Whether `other` hashed the same entries (equal `count` and `sha256`), whatever either
    /// left out.
    public func hashesSameEntries(as other: Bookmarks) -> Bool {
      count == other.count && sha256 == other.sha256
    }
  } // End of struct Bookmarks

  /// The folder's path.
  public var dynamicProfilesDirectory: String
  /// Whether the folder exists.
  public var directoryExists: Bool
  /// The one name left out: muxFinder's own file.
  public var excludedFileName: String
  /// Every other entry, sorted by name.
  public var entries: [Entry]
  /// `New Bookmarks`, or `nil` when the domain has none.
  public var newBookmarks: Bookmarks?

  /// How many entries the folder holds besides muxFinder's file.
  public var entryCount: Int { entries.count }

  /// How many of iTerm2's mirrors of muxFinder's own profiles `New Bookmarks` held (left out
  /// of its hash); 0 without `New Bookmarks`.
  public var excludedMuxFinderEntries: Int { newBookmarks?.excludedMuxFinderEntries ?? 0 }

  /// The names of entries that differ between this snapshot and `other` (added, removed or
  /// changed), sorted, plus `New Bookmarks` when its hashed entries differ (not when only the
  /// number of muxFinder mirrors left out does): what a failed comparison reports.
  public func differences(from other: ITerm2ProfileSnapshot) -> [String] {
    let mine = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    let theirs = Dictionary(uniqueKeysWithValues: other.entries.map { ($0.name, $0) })
    var names = Set(mine.keys).union(theirs.keys).filter { mine[$0] != theirs[$0] }.sorted()
    switch (newBookmarks, other.newBookmarks) {
    case (nil, nil): break
    case (let mine?, let theirs?) where mine.hashesSameEntries(as: theirs): break
    default: names.append("New Bookmarks")
    }
    if directoryExists != other.directoryExists { names.append("DynamicProfiles folder") }
    return names
  } // End of func differences(from:)

  /// Whether nothing this snapshot hashes differs from `other` (`differences(from:)` is
  /// empty): what the `e2e-profile` run compares.
  public func hashesMatch(_ other: ITerm2ProfileSnapshot) -> Bool {
    differences(from: other).isEmpty
  }
} // End of struct ITerm2ProfileSnapshot

/// Takes `ITerm2ProfileSnapshot`s, reading only: it lists the `DynamicProfiles` folder and reads
/// its regular files (never following a link, never descending into a folder, never opening
/// anything else), and runs `/usr/bin/defaults export com.googlecode.iterm2 -` (argv, never
/// `defaults write`), parsing its property list and digesting a canonical form of `New
/// Bookmarks` alone, without iTerm2's mirrors of muxFinder's own profiles.
///
/// iTerm2 (3.7.6) writes every dynamic profile it has loaded into its saved `New Bookmarks`,
/// with a `Dynamic Profile Filename` key naming the file, and drops it after the file goes
/// (PLAN.md D26). Such a copy of a profile from muxFinder's own `muxFinder.json` is iTerm2's
/// doing, not a change to the user's profiles, so it is counted and left out of the hash, but
/// only when `MirrorRule` proves it is one; everything else (other dynamic profiles' copies,
/// look-alikes, a copy whose written keys changed) is hashed.
public struct ITerm2ProfileSnapshotter: Sendable {
  /// A profile muxFinder wrote into `muxFinder.json`: its GUID and the canonical form
  /// (`CanonicalPropertyList`) of every key's value as the file holds it, which iTerm2's copy
  /// must hold unchanged to be left out.
  public struct WrittenProfile: Sendable, Hashable {
    /// The profile's `Guid`.
    public let guid: String
    /// Every key the file gives the profile, with the canonical form of its value.
    public let values: [String: Data]

    /// The profiles of the `muxFinder.json` bytes `document` (`{"Profiles": […]}`, each a
    /// dictionary with a string `Guid`), or `nil` when the bytes are not that or hold a value a
    /// property list cannot (a JSON `null`).
    public static func profiles(inDocument document: Data) -> [WrittenProfile]? {
      guard let root = try? JSONSerialization.jsonObject(with: document) as? [String: Any],
        let list = root["Profiles"] as? [Any]
      else { return nil }
      var profiles: [WrittenProfile] = []
      for item in list {
        guard let profile = item as? [String: Any],
          let guid = profile[ITerm2ProfileSnapshotter.guidKey] as? String
        else { return nil }
        var values: [String: Data] = [:]
        for (key, value) in profile {
          guard let canonical = CanonicalPropertyList.encode(value) else { return nil }
          values[key] = canonical
        }
        profiles.append(WrittenProfile(guid: guid, values: values))
      } // End of loop over the document's profiles
      return profiles
    } // End of static func profiles(inDocument:)
  } // End of struct WrittenProfile

  /// What proves a `New Bookmarks` entry is iTerm2's copy of one of muxFinder's own profiles,
  /// so that it is left out of the hash (PLAN.md D26). All of these must hold:
  /// - it is a dictionary whose `Guid` is a well-formed generated GUID
  ///   (`PersistentProfiles.guidPrefix` and a lowercase UUID) and, when the caller knows what
  ///   it wrote (`written`), exactly one of the written profiles' GUIDs;
  /// - its `Dynamic Profile Filename` is an absolute path whose last component is
  ///   `muxFinder.json` and which, standardized (`.` and repeated `/` dropped, `..` applied),
  ///   is exactly the owned file's standardized path, `<DynamicProfiles>/muxFinder.json`;
  /// - when `written` is known, every key that profile was written with is present with an
  ///   equal value (the same canonical form; iTerm2 adds keys of its own, which are not
  ///   compared).
  ///
  /// The `e2e-profile` harness knows what it wrote; `profiles hashes`, which knows no install,
  /// uses the GUID format and the exact path alone.
  public struct MirrorRule: Sendable, Hashable {
    /// The owned file's standardized path, or `nil` when the path given was not usable (then
    /// nothing is left out).
    public let ownedFilePath: String?
    /// The written profiles by GUID, or `nil` when the caller knows none.
    public let written: [String: WrittenProfile]?

    /// A rule for the owned file at `ownedFilePath` and, when known, the profiles written
    /// into it.
    public init(ownedFilePath: String, written: [WrittenProfile]? = nil) {
      self.ownedFilePath = MirrorRule.standardizedFilePath(ownedFilePath)
      self.written = written.map {
        Dictionary($0.map { ($0.guid, $0) }, uniquingKeysWith: { first, _ in first })
      }
    }

    /// Whether `entry` is proven to be iTerm2's copy of one of muxFinder's own profiles.
    public func matches(_ entry: Any) -> Bool {
      guard let ownedFilePath, let profile = entry as? [String: Any],
        let guid = profile[ITerm2ProfileSnapshotter.guidKey] as? String,
        let hostID = PersistentProfiles.hostID(fromGUID: guid),
        PersistentProfiles.guid(forHostID: hostID) == guid,
        let filename = profile[ITerm2ProfileSnapshotter.dynamicProfileFilenameKey] as? String,
        Self.standardizedFilePath(filename) == ownedFilePath
      else { return false }
      guard let written else { return true }
      guard let mine = written[guid] else { return false }
      return mine.values.allSatisfy { key, canonical in
        profile[key].flatMap { CanonicalPropertyList.encode($0) } == canonical
      }
    } // End of func matches(_:)

    /// `path` standardized: `.` and empty components dropped, `..` applied (never above the
    /// root); `nil` unless it is absolute and its last component is `muxFinder.json` (so a
    /// trailing `/`, `.` or `..` never names the file).
    static func standardizedFilePath(_ path: String) -> String? {
      guard path.hasPrefix("/"),
        path.split(separator: "/", omittingEmptySubsequences: false).last
          == Substring(PersistentProfiles.fileName)
      else { return nil }
      var components: [Substring] = []
      for component in path.split(separator: "/") {
        switch component {
        case ".": continue
        case "..": _ = components.popLast()
        default: components.append(component)
        }
      } // End of loop over the path's components
      return "/" + components.joined(separator: "/")
    } // End of static func standardizedFilePath(_:)
  } // End of struct MirrorRule

  /// What one snapshot is told: the profiles the caller wrote, and how long `defaults export`
  /// may take.
  public struct Options: Sendable, Hashable {
    /// The profiles the caller wrote into `muxFinder.json`: only iTerm2's unchanged copies of
    /// these are left out. `nil` when it knows none (`profiles hashes`; the harness before it
    /// installs): then any entry with a well-formed generated GUID naming the owned file is.
    public var written: [WrittenProfile]?
    /// The deadline of `defaults export` (`exportTimeout` by default; a caller with a budget
    /// passes what is left of it).
    public var exportTimeout: Duration

    /// Options for a snapshot.
    public init(
      written: [WrittenProfile]? = nil,
      exportTimeout: Duration = ITerm2ProfileSnapshotter.exportTimeout
    ) {
      self.written = written
      self.exportTimeout = exportTimeout
    }
  } // End of struct Options

  /// `defaults`.
  public static let defaultsURL = URL(fileURLWithPath: "/usr/bin/defaults")
  /// Its arguments: export iTerm2's domain to standard output.
  public static let defaultsArguments = ["export", "com.googlecode.iterm2", "-"]
  /// The key of iTerm2's own profiles in its domain.
  public static let bookmarksKey = "New Bookmarks"
  /// A profile's GUID key.
  public static let guidKey = "Guid"
  /// The key iTerm2 adds to its saved copy of a loaded dynamic profile: the file it came from.
  public static let dynamicProfileFilenameKey = "Dynamic Profile Filename"
  /// The most `defaults export` output read.
  public static let exportLimit = 64 * 1024 * 1024
  /// The deadline of `defaults export`.
  public static let exportTimeout: Duration = .seconds(20)
  /// The largest folder entry read, in bytes; a larger file is digested as unreadable.
  public static let entryLimit = 64 * 1024 * 1024

  /// The `DynamicProfiles` folder.
  public var directory: URL
  /// Runs `defaults`.
  public var runner: any ProcessRunner
  /// The environment `defaults` runs with.
  public var environment: [String: String]
  /// The user id that must own the folder.
  let owner: uid_t

  /// A snapshotter of `directory` (iTerm2's own folder by default) running `defaults` through
  /// `runner`.
  public init(
    directory: URL = PersistentProfileInstaller.standardDirectory,
    runner: any ProcessRunner = PosixSpawnProcessRunner(),
    environment: [String: String] = [
      "PATH": ProcessEnvironment.systemSearchPath, "HOME": NSHomeDirectory(),
    ]
  ) {
    self.directory = directory
    self.runner = runner
    self.environment = environment
    self.owner = geteuid()
  } // End of init(directory:runner:environment:)

  /// The path of muxFinder's own file in the folder, `<directory>/muxFinder.json`: the only
  /// `Dynamic Profile Filename` a copy left out of the hash may name.
  public var ownedFilePath: String {
    PrivateStorage.path(of: directory) + "/" + PersistentProfiles.fileName
  }

  /// Takes a snapshot, leaving out of `New Bookmarks` what `MirrorRule` proves to be iTerm2's
  /// copies of `options.written` (or, without them, of any generated profile) from
  /// `ownedFilePath`, with `defaults export` bounded by `options.exportTimeout`.
  public func snapshot(_ options: Options = Options()) async throws -> ITerm2ProfileSnapshot {
    let (exists, entries) = try entries()
    let rule = MirrorRule(ownedFilePath: ownedFilePath, written: options.written)
    let bookmarks = try await newBookmarks(rule: rule, timeout: options.exportTimeout)
    return ITerm2ProfileSnapshot(
      dynamicProfilesDirectory: PrivateStorage.path(of: directory), directoryExists: exists,
      excludedFileName: PersistentProfiles.fileName, entries: entries, newBookmarks: bookmarks)
  } // End of func snapshot(_:)

  /// The folder's entries other than muxFinder's file, sorted by name, and whether it exists.
  func entries() throws(ITerm2ProfileSnapshotError) -> (Bool, [ITerm2ProfileSnapshot.Entry]) {
    let folder: Int32
    do throws(PrivateStorageError) {
      folder = try PrivateStorage.openDirectory(
        atPath: PrivateStorage.path(of: directory), owner: owner, access: .inspect)
    } catch .directoryMissing {
      return (false, [])
    } catch {
      throw .directoryUnusable("\(error)")
    }
    defer { Darwin.close(folder) }
    let names: [String]
    do throws(PrivateStorageError) {
      names = try PrivateStorage.entryNames(in: folder)
    } catch {
      throw .directoryUnusable("\(error)")
    }
    var entries: [ITerm2ProfileSnapshot.Entry] = []
    for name in names.sorted() where name != PersistentProfiles.fileName {
      entries.append(try Self.entry(named: name, in: folder))
    }
    return (true, entries)
  } // End of func entries()

  /// One entry, looked at without following a link: a regular file's bytes or a link's text are
  /// digested; folders and other kinds only get their kind.
  static func entry(
    named name: String,
    in folder: Int32
  ) throws(ITerm2ProfileSnapshotError) -> ITerm2ProfileSnapshot.Entry {
    var info = stat()
    guard fstatat(folder, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
      throw .entryUnreadable(name: name, errno: errno)
    }
    switch info.st_mode & S_IFMT {
    case S_IFLNK:
      var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
      let count = readlinkat(folder, name, &buffer, buffer.count)
      guard count >= 0 else { throw .entryUnreadable(name: name, errno: errno) }
      let text = Data(buffer.prefix(count).map { UInt8(bitPattern: $0) })
      return .init(name: name, kind: .symbolicLink, sha256: digest(text))
    case S_IFDIR:
      return .init(name: name, kind: .directory, sha256: nil)
    case S_IFREG:
      return .init(name: name, kind: .file, sha256: digest(try contents(of: name, in: folder)))
    default:
      return .init(name: name, kind: .other, sha256: nil)
    }
  } // End of func entry(named:in:)

  /// The bytes of the regular file `name`, opened without following a link or blocking.
  static func contents(of name: String, in folder: Int32) throws(ITerm2ProfileSnapshotError) -> Data
  {
    let descriptor = openat(folder, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { throw .entryUnreadable(name: name, errno: errno) }
    defer { Darwin.close(descriptor) }
    do throws(PrivateStorageError) {
      return try PrivateStorage.readAll(from: descriptor, limit: entryLimit)
    } catch .fileTooLarge {
      throw .entryUnreadable(name: name, errno: EFBIG)
    } catch {
      throw .entryUnreadable(name: name, errno: PrivateStorage.posixCode(of: error))
    }
  } // End of func contents(of:in:)

  /// `New Bookmarks` from `defaults export com.googlecode.iterm2 -` run with `timeout`, without
  /// the entries `rule` matches, or `nil` when the domain has none.
  func newBookmarks(
    rule: MirrorRule,
    timeout: Duration
  ) async throws -> ITerm2ProfileSnapshot.Bookmarks? {
    let request = ProcessRequest(
      executableURL: Self.defaultsURL, arguments: Self.defaultsArguments, environment: environment,
      timeout: timeout, outputLimit: Self.exportLimit)
    let result: ProcessResult
    do {
      result = try await runner.run(request)
    } catch let error as ProcessRunnerError {
      throw ITerm2ProfileSnapshotError.defaultsNotRun(error.description)
    }
    guard !result.timedOut, case .exited(0) = result.termination else {
      throw ITerm2ProfileSnapshotError.defaultsFailed(status: result.exitCode ?? -1)
    }
    guard !result.standardOutputTruncated else {
      throw ITerm2ProfileSnapshotError.defaultsOutputTooLarge
    }
    return try Self.bookmarks(fromExport: result.standardOutput, leavingOut: rule)
  } // End of func newBookmarks(rule:timeout:)

  /// The fingerprint of `New Bookmarks` in an exported property list (`nil` when absent): the
  /// canonical form of its entries in order without those `rule` matches, which are counted
  /// (no rule: every entry is hashed).
  public static func bookmarks(
    fromExport data: Data,
    leavingOut rule: MirrorRule? = nil
  ) throws(ITerm2ProfileSnapshotError) -> ITerm2ProfileSnapshot.Bookmarks? {
    guard
      let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let domain = root as? [String: Any]
    else { throw .defaultsOutputUnreadable }
    guard let value = domain[bookmarksKey] else { return nil }
    guard let array = value as? [Any] else { throw .bookmarksUnreadable }
    let hashed = array.filter { rule?.matches($0) != true }
    guard let canonical = CanonicalPropertyList.encode(hashed) else { throw .bookmarksUnreadable }
    return .init(
      count: hashed.count, sha256: digest(canonical),
      excludedMuxFinderEntries: array.count - hashed.count)
  } // End of static func bookmarks(fromExport:leavingOut:)

  /// The lowercase hexadecimal SHA-256 of `data`.
  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}

/// A canonical byte form of a property list value, so the same value always digests the same
/// whatever the order `defaults` printed a dictionary's keys in: every value is a type tag and
/// its length-prefixed content; dictionaries list their keys sorted by UTF-8 bytes.
///
/// Tags: `d` dictionary, `a` array, `s` string, `D` data, `t` date (the bit pattern of its
/// seconds since 2001), `b` boolean, `i` integer, `u` unsigned integer above `Int64.max`, `r`
/// real (the bit pattern of its `Double`). A value of another type makes the form `nil`.
public enum CanonicalPropertyList {
  /// The canonical form of `value`, or `nil` when it holds a type a property list does not.
  public static func encode(_ value: Any) -> Data? {
    var output = Data()
    return append(value, to: &output) ? output : nil
  }

  /// Appends `value`'s canonical form to `output`; returns whether every part was known.
  static func append(_ value: Any, to output: inout Data) -> Bool {
    if let dictionary = value as? [String: Any] {
      tag("d", length: dictionary.count, to: &output)
      for key in dictionary.keys.sorted(by: { Array($0.utf8).lexicographicallyPrecedes($1.utf8) }) {
        appendString(key, to: &output)
        guard let item = dictionary[key], append(item, to: &output) else { return false }
      }
      return true
    }
    if let array = value as? [Any] {
      tag("a", length: array.count, to: &output)
      return array.allSatisfy { append($0, to: &output) }
    }
    if let string = value as? String {
      appendString(string, to: &output)
      return true
    }
    if let data = value as? Data {
      tag("D", length: data.count, to: &output)
      output.append(data)
      return true
    }
    if let date = value as? Date {
      tag("t", length: 8, to: &output)
      appendBits(date.timeIntervalSinceReferenceDate.bitPattern, to: &output)
      return true
    }
    if let number = value as? NSNumber {
      return appendNumber(number, to: &output)
    }
    return false
  } // End of static func append(_:to:)

  /// Appends a number: a boolean, an integer, or a real.
  static func appendNumber(_ number: NSNumber, to output: inout Data) -> Bool {
    if CFGetTypeID(number) == CFBooleanGetTypeID() {
      tag("b", length: 1, to: &output)
      output.append(number.boolValue ? 1 : 0)
    } else if CFNumberIsFloatType(number) {
      tag("r", length: 8, to: &output)
      appendBits(number.doubleValue.bitPattern, to: &output)
    } else if number.int64Value < 0 || number.uint64Value <= UInt64(Int64.max) {
      tag("i", length: 8, to: &output)
      appendBits(UInt64(bitPattern: number.int64Value), to: &output)
    } else {
      tag("u", length: 8, to: &output)
      appendBits(number.uint64Value, to: &output)
    }
    return true
  } // End of static func appendNumber(_:to:)

  /// Appends a string: `s`, its UTF-8 length, its UTF-8 bytes.
  static func appendString(_ string: String, to output: inout Data) {
    let bytes = Array(string.utf8)
    tag("s", length: bytes.count, to: &output)
    output.append(contentsOf: bytes)
  }

  /// Appends a one-byte tag and a length as eight big-endian bytes.
  static func tag(_ tag: Character, length: Int, to output: inout Data) {
    output.append(contentsOf: Array(String(tag).utf8))
    appendBits(UInt64(length), to: &output)
  }

  /// Appends `bits` as eight big-endian bytes.
  static func appendBits(_ bits: UInt64, to output: inout Data) {
    withUnsafeBytes(of: bits.bigEndian) { output.append(contentsOf: $0) }
  }
}
