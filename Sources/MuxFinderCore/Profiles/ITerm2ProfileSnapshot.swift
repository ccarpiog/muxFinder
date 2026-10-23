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
/// and the `New Bookmarks` array (iTerm2's own profiles) of `com.googlecode.iterm2`. It holds
/// names, kinds, counts and SHA-256 digests only, never contents: profile names are the user's.
/// Two snapshots compare equal exactly when nothing it covers changed.
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

  /// The `New Bookmarks` array's fingerprint.
  public struct Bookmarks: Sendable, Hashable, Codable {
    /// How many profiles it holds.
    public var count: Int
    /// The lowercase hexadecimal SHA-256 of its canonical form (`CanonicalPropertyList`).
    public var sha256: String
  }

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

  /// The names of entries that differ between this snapshot and `other` (added, removed or
  /// changed), sorted, plus `New Bookmarks` when it differs: what a failed comparison reports.
  public func differences(from other: ITerm2ProfileSnapshot) -> [String] {
    let mine = Dictionary(uniqueKeysWithValues: entries.map { ($0.name, $0) })
    let theirs = Dictionary(uniqueKeysWithValues: other.entries.map { ($0.name, $0) })
    var names = Set(mine.keys).union(theirs.keys).filter { mine[$0] != theirs[$0] }.sorted()
    if newBookmarks != other.newBookmarks { names.append("New Bookmarks") }
    if directoryExists != other.directoryExists { names.append("DynamicProfiles folder") }
    return names
  } // End of func differences(from:)
}

/// Takes `ITerm2ProfileSnapshot`s, reading only: it lists the `DynamicProfiles` folder and reads
/// its regular files (never following a link, never descending into a folder, never opening
/// anything else), and runs `/usr/bin/defaults export com.googlecode.iterm2 -` (argv, never
/// `defaults write`), parsing its property list and digesting a canonical form of `New
/// Bookmarks` alone.
public struct ITerm2ProfileSnapshotter: Sendable {
  /// `defaults`.
  public static let defaultsURL = URL(fileURLWithPath: "/usr/bin/defaults")
  /// Its arguments: export iTerm2's domain to standard output.
  public static let defaultsArguments = ["export", "com.googlecode.iterm2", "-"]
  /// The key of iTerm2's own profiles in its domain.
  public static let bookmarksKey = "New Bookmarks"
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

  /// Takes a snapshot.
  public func snapshot() async throws -> ITerm2ProfileSnapshot {
    let (exists, entries) = try entries()
    let bookmarks = try await newBookmarks()
    return ITerm2ProfileSnapshot(
      dynamicProfilesDirectory: PrivateStorage.path(of: directory), directoryExists: exists,
      excludedFileName: PersistentProfiles.fileName, entries: entries, newBookmarks: bookmarks)
  }

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

  /// `New Bookmarks` from `defaults export com.googlecode.iterm2 -`, or `nil` when the domain
  /// has none.
  func newBookmarks() async throws -> ITerm2ProfileSnapshot.Bookmarks? {
    let request = ProcessRequest(
      executableURL: Self.defaultsURL, arguments: Self.defaultsArguments, environment: environment,
      timeout: Self.exportTimeout, outputLimit: Self.exportLimit)
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
    return try Self.bookmarks(fromExport: result.standardOutput)
  } // End of func newBookmarks()

  /// The fingerprint of `New Bookmarks` in an exported property list (`nil` when absent).
  public static func bookmarks(
    fromExport data: Data
  ) throws(ITerm2ProfileSnapshotError) -> ITerm2ProfileSnapshot.Bookmarks? {
    guard
      let root = try? PropertyListSerialization.propertyList(from: data, format: nil),
      let domain = root as? [String: Any]
    else { throw .defaultsOutputUnreadable }
    guard let value = domain[bookmarksKey] else { return nil }
    guard let array = value as? [Any], let canonical = CanonicalPropertyList.encode(array) else {
      throw .bookmarksUnreadable
    }
    return .init(count: array.count, sha256: digest(canonical))
  } // End of static func bookmarks(fromExport:)

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
