import Darwin
import Foundation

/// The bounds on what the downloaded zip may unpack to (PLAN.md D39, I-13b1). The archive
/// check (`UpdateArchiveCheck`) holds the zip's declared entries to them before `ditto` runs,
/// and the extraction's watchdog (`UpdateExpansionWatch`) holds what `ditto` actually writes
/// to them while it runs, since a zip's directory can lie about its sizes.
public struct UpdateArchiveLimits: Sendable, Hashable {
  /// The most entries in the archive's directory, and the most entries written below the
  /// extraction folder while `ditto` runs (the 0.2.0 zip has 29; each file may have its `._`
  /// twin).
  public var maximumEntries: Int
  /// The most bytes the entries may declare unpacked in total, and the most bytes (regular
  /// files' and links' sizes plus extended attribute values) written below the extraction
  /// folder while `ditto` runs (the 0.2.0 zip declares about 19.2 MB).
  public var maximumBytes: Int
  /// The most bytes one entry may declare unpacked (the 0.2.0 zip's largest is about 12.6 MB).
  public var maximumEntryBytes: Int
  /// The highest compression ratio (declared unpacked size over packed size) of an entry
  /// declaring more than `ratioFloor` bytes (the 0.2.0 zip's highest is about 3.7).
  public var maximumRatio: Int
  /// Entries declaring at most this many bytes are not held to `maximumRatio`.
  public var ratioFloor: Int
  /// The most components in an entry's name, and the deepest level below the extraction
  /// folder while `ditto` runs.
  public var maximumDepth: Int

  /// Creates bounds.
  public init(
    maximumEntries: Int, maximumBytes: Int, maximumEntryBytes: Int, maximumRatio: Int,
    ratioFloor: Int, maximumDepth: Int
  ) {
    self.maximumEntries = maximumEntries
    self.maximumBytes = maximumBytes
    self.maximumEntryBytes = maximumEntryBytes
    self.maximumRatio = maximumRatio
    self.ratioFloor = ratioFloor
    self.maximumDepth = maximumDepth
  } // End of init(maximumEntries:maximumBytes:maximumEntryBytes:maximumRatio:ratioFloor:…)

  /// The bounds used: 20,000 entries, 256 MiB in total, 128 MiB per entry, a ratio of at most
  /// 100 for entries over 1 MiB, 40 levels.
  public static let standard = UpdateArchiveLimits(
    maximumEntries: 20_000, maximumBytes: 256 << 20, maximumEntryBytes: 128 << 20,
    maximumRatio: 100, ratioFloor: 1 << 20, maximumDepth: 40)
}

/// Why the archive check refused the zip before anything was unpacked (PLAN.md D39, I-13b1).
public enum UpdateArchiveProblem: Error, Sendable, Hashable {
  /// The zip could not be opened or read (this errno).
  case unreadable(errno: Int32)
  /// The zip's structure is not consistent: no end record, a directory that does not end
  /// where the end record begins, an entry record or local header out of place, a local
  /// header that disagrees with its directory record, sizes that cannot be, or bytes that
  /// belong to no listed entry (a reader that walks the local headers, as `ditto` does, would
  /// see something else than the directory lists).
  case malformed
  /// The zip uses ZIP64 records (never needed for a release zip of at most 50 MiB).
  case zip64
  /// The zip has no entries.
  case empty
  /// More entries than the bound.
  case tooManyEntries
  /// The entries declare more bytes in total than the bound, or the directory itself is too
  /// large.
  case tooLarge
  /// One entry declares more bytes than the bound.
  case entryTooLarge
  /// An entry's declared compression ratio is above the bound.
  case ratioTooHigh
  /// An entry is encrypted, uses a compression method other than stored or deflate, or is
  /// neither a regular file, a folder nor a symbolic link.
  case unsupportedEntry
  /// An entry's name is absolute, has an empty, `.` or `..` component, a backslash or NUL, is
  /// not UTF-8, or is too long or too deep.
  case unsafeName
  /// An entry lies outside `muxFinder.app` (and its AppleDouble companions).
  case outsideApp
  /// Two entries have the same name (compared without case and in one Unicode form).
  case duplicateName
  /// An entry lies below an entry that is a symbolic link.
  case belowLink

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .unreadable(let code): return "unreadable.\(code)"
    case .malformed: return "malformed"
    case .zip64: return "zip64"
    case .empty: return "empty"
    case .tooManyEntries: return "tooManyEntries"
    case .tooLarge: return "tooLarge"
    case .entryTooLarge: return "entryTooLarge"
    case .ratioTooHigh: return "ratioTooHigh"
    case .unsupportedEntry: return "unsupportedEntry"
    case .unsafeName: return "unsafeName"
    case .outsideApp: return "outsideApp"
    case .duplicateName: return "duplicateName"
    case .belowLink: return "belowLink"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .unreadable, .malformed, .zip64, .unsupportedEntry:
      return "the download isn't a valid archive"
    case .empty: return "the download doesn't contain muxFinder.app"
    case .tooManyEntries, .tooLarge, .entryTooLarge, .ratioTooHigh:
      return "the download would be too large unpacked"
    case .unsafeName, .duplicateName, .belowLink:
      return "the download contains an unsafe file name"
    case .outsideApp: return "the download contains more than muxFinder.app"
    }
  } // End of var reason
}

/// The archive check (PLAN.md D39, I-13b1): reads the zip's directory and local headers
/// itself, unpacking nothing, and refuses the zip before `ditto` runs when it is malformed,
/// uses ZIP64, declares too many entries or too many bytes (in total, for one entry, or at an
/// absurd compression ratio), holds an entry other than a stored or deflated regular file,
/// folder or symbolic link, or names an entry unsafely or outside `muxFinder.app`.
///
/// The end record is searched for in the last 65,557 bytes (its 22 bytes and the longest
/// comment), from the end, and must be the record whose comment ends exactly at the end of the
/// file; the directory must end exactly where it begins. Because `ditto` takes the names from
/// the local headers (checked on this Mac: a local header's name wins over its directory
/// record's, and an entry listed in no directory record is still unpacked), every local
/// header must agree with its directory record (flags, method, name, sizes; a data
/// descriptor's sizes too), and the listed entries must cover every byte before the directory
/// with no gap and no overlap. What the directory cannot promise, a deflate stream that
/// unpacks to more than declared, is the watchdog's (`UpdateExpansionWatch`).
public enum UpdateArchiveCheck {
  /// What the check counted.
  public struct Summary: Sendable, Hashable {
    /// Entries in the directory.
    public var entries = 0
    /// Bytes the entries declare unpacked.
    public var declaredBytes = 0
  }

  /// The largest directory read.
  public static let maximumDirectoryBytes = 16 << 20
  /// The longest entry name, in bytes.
  public static let maximumNameBytes = 1024
  /// The app's name, the only top-level entry allowed (with its AppleDouble companions).
  static let appName = UpdateBundleShape.appName

  /// The end record's signature, `PK\u{5}\u{6}`.
  static let endSignature: UInt32 = 0x0605_4B50
  /// A directory record's signature, `PK\u{1}\u{2}`.
  static let directorySignature: UInt32 = 0x0201_4B50
  /// A local header's signature, `PK\u{3}\u{4}`.
  static let localSignature: UInt32 = 0x0403_4B50
  /// A data descriptor's optional signature, `PK\u{7}\u{8}`.
  static let descriptorSignature: UInt32 = 0x0807_4B50
  /// The ZIP64 extended information extra field's identifier.
  static let zip64ExtraID: UInt16 = 0x0001

  /// One directory record.
  struct Entry {
    /// The name's bytes.
    var name: [UInt8]
    /// The general purpose flags.
    var flags: UInt16
    /// The compression method.
    var method: UInt16
    /// The CRC-32.
    var crc: UInt32
    /// The packed size.
    var compressed: Int
    /// The declared unpacked size.
    var uncompressed: Int
    /// The local header's offset.
    var localOffset: Int
    /// "Version made by" (its high byte is the host system; 3 is Unix).
    var madeBy: UInt16
    /// The external attributes (on a Unix host, the mode in the high 16 bits).
    var external: UInt32
  }

  /// Checks the zip at `path` (an absolute path; its last component is not followed if it is
  /// a link).
  public static func check(zipAtPath path: String, limits: UpdateArchiveLimits = .standard)
    -> Result<Summary, UpdateArchiveProblem>
  {
    let descriptor = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
    guard descriptor >= 0 else { return .failure(.unreadable(errno: errno)) }
    defer { Darwin.close(descriptor) }
    var info = stat()
    guard fstat(descriptor, &info) == 0 else { return .failure(.unreadable(errno: errno)) }
    guard info.st_mode & S_IFMT == S_IFREG else { return .failure(.malformed) }
    let reader = Reader(descriptor: descriptor, size: Int(info.st_size))
    do throws(UpdateArchiveProblem) {
      return .success(try check(reader, limits: limits))
    } catch {
      return .failure(error)
    }
  } // End of static func check(zipAtPath:limits:)

  /// The check over `reader`.
  static func check(_ reader: Reader, limits: UpdateArchiveLimits) throws(UpdateArchiveProblem)
    -> Summary
  {
    let end = try endRecord(reader)
    let entryCount = Int(end.u16(10))
    let directorySize = Int(end.u32(12))
    let directoryOffset = Int(end.u32(16))
    guard end.u16(4) != 0xFFFF, end.u16(6) != 0xFFFF, end.u16(8) != 0xFFFF,
      end.u16(10) != 0xFFFF, end.u32(12) != 0xFFFF_FFFF, end.u32(16) != 0xFFFF_FFFF
    else { throw .zip64 }
    guard end.u16(4) == 0, end.u16(6) == 0, end.u16(8) == end.u16(10) else { throw .malformed }
    guard entryCount > 0 else { throw .empty }
    guard entryCount <= limits.maximumEntries else { throw .tooManyEntries }
    guard directoryOffset + directorySize == end.offset else { throw .malformed }
    guard directorySize <= maximumDirectoryBytes else { throw .tooLarge }
    guard directorySize >= entryCount * 46 else { throw .malformed }
    let directory = try reader.bytes(at: directoryOffset, count: directorySize)
    let entries = try directoryEntries(directory, count: entryCount)
    try checkNames(entries, limits: limits)
    let declared = try checkSizes(entries, limits: limits)
    try checkLocalHeaders(entries, reader: reader, directoryOffset: directoryOffset)
    return Summary(entries: entryCount, declaredBytes: declared)
  } // End of static func check(_:limits:)

  /// The end record: the last one, searching from the end of the file, whose comment ends
  /// exactly at the end of the file.
  static func endRecord(_ reader: Reader) throws(UpdateArchiveProblem) -> Bytes {
    guard reader.size >= 22 else { throw .malformed }
    let tailCount = min(reader.size, 22 + 0xFFFF)
    let tailStart = reader.size - tailCount
    let tail = try reader.bytes(at: tailStart, count: tailCount)
    var index = tailCount - 22
    while index >= 0 {
      if tail.u32(index) == endSignature, Int(tail.u16(index + 20)) == tailCount - index - 22 {
        return Bytes(Array(tail.storage[index..<(index + 22)]), offset: tailStart + index)
      }
      index -= 1
    } // End of loop over the tail's offsets, from the end
    throw .malformed
  } // End of static func endRecord(_:)

  /// The `count` directory records in `directory`, which they must fill exactly.
  static func directoryEntries(_ directory: Bytes, count: Int) throws(UpdateArchiveProblem)
    -> [Entry]
  {
    var entries: [Entry] = []
    entries.reserveCapacity(count)
    var position = 0
    for _ in 0..<count {
      guard position + 46 <= directory.count, directory.u32(position) == directorySignature else {
        throw .malformed
      }
      let compressed = directory.u32(position + 20)
      let uncompressed = directory.u32(position + 24)
      let localOffset = directory.u32(position + 42)
      guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF,
        localOffset != 0xFFFF_FFFF, directory.u16(position + 34) != 0xFFFF
      else { throw .zip64 }
      guard directory.u16(position + 34) == 0 else { throw .malformed }
      let nameLength = Int(directory.u16(position + 28))
      let extraLength = Int(directory.u16(position + 30))
      let commentLength = Int(directory.u16(position + 32))
      let nameStart = position + 46
      let next = nameStart + nameLength + extraLength + commentLength
      guard next <= directory.count else { throw .malformed }
      try checkExtra(directory, from: nameStart + nameLength, count: extraLength)
      entries.append(
        Entry(
          name: Array(directory.storage[nameStart..<(nameStart + nameLength)]),
          flags: directory.u16(position + 8), method: directory.u16(position + 10),
          crc: directory.u32(position + 16), compressed: Int(compressed),
          uncompressed: Int(uncompressed), localOffset: Int(localOffset),
          madeBy: directory.u16(position + 4), external: directory.u32(position + 38)))
      position = next
    } // End of loop over the directory records
    guard position == directory.count else { throw .malformed }
    return entries
  } // End of static func directoryEntries(_:count:)

  /// Checks the extra field of `count` bytes at `start` in `bytes`: well-formed blocks, none a
  /// ZIP64 one.
  static func checkExtra(_ bytes: Bytes, from start: Int, count: Int)
    throws(UpdateArchiveProblem)
  {
    var position = start
    let end = start + count
    while position < end {
      guard position + 4 <= end else { throw .malformed }
      let identifier = bytes.u16(position)
      let size = Int(bytes.u16(position + 2))
      guard position + 4 + size <= end else { throw .malformed }
      if identifier == zip64ExtraID { throw .zip64 }
      position += 4 + size
    } // End of loop over the extra field's blocks
  } // End of static func checkExtra(_:from:count:)

  /// A file type in a Unix mode.
  enum Kind {
    /// Not recorded (another host system, or no type bits).
    case unknown
    /// A regular file.
    case file
    /// A folder.
    case folder
    /// A symbolic link.
    case link
    /// Anything else (a FIFO, a socket, a device).
    case other
  }

  /// The kind `entry` records.
  static func kind(of entry: Entry) -> Kind {
    guard entry.madeBy >> 8 == 3 else { return .unknown }
    switch mode_t(entry.external >> 16) & S_IFMT {
    case 0: return .unknown
    case S_IFREG: return .file
    case S_IFDIR: return .folder
    case S_IFLNK: return .link
    default: return .other
    }
  } // End of static func kind(of:)

  /// Checks every name: safe, inside `muxFinder.app`, no duplicate, nothing below a link.
  static func checkNames(_ entries: [Entry], limits: UpdateArchiveLimits)
    throws(UpdateArchiveProblem)
  {
    var seen = Set<String>()
    var links = Set<String>()
    var keys: [[String]] = []
    keys.reserveCapacity(entries.count)
    for entry in entries {
      let components = try nameComponents(entry.name, limits: limits)
      try checkTopLevel(components)
      let folded = components.map { $0.decomposedStringWithCanonicalMapping.lowercased() }
      let key = folded.joined(separator: "/")
      guard seen.insert(key).inserted else { throw .duplicateName }
      if kind(of: entry) == .link { links.insert(key) }
      keys.append(folded)
    } // End of loop over the entries' names
    guard !links.isEmpty else { return }
    for folded in keys where folded.count > 1 {
      for length in 1..<folded.count
      where links.contains(folded[0..<length].joined(separator: "/")) {
        throw .belowLink
      } // End of loop over the name's proper prefixes
    } // End of loop over the folded names
  } // End of static func checkNames(_:limits:)

  /// The components of the name `bytes` (a folder's trailing `/` dropped), or `unsafeName`.
  static func nameComponents(_ bytes: [UInt8], limits: UpdateArchiveLimits)
    throws(UpdateArchiveProblem) -> [String]
  {
    guard !bytes.isEmpty, bytes.count <= maximumNameBytes, !bytes.contains(0),
      !bytes.contains(0x5C), bytes.first != 0x2F,
      let text = String(bytes: bytes, encoding: .utf8)
    else { throw .unsafeName }
    let trimmed = text.hasSuffix("/") ? String(text.dropLast()) : text
    let components = trimmed.split(separator: "/", omittingEmptySubsequences: false).map(
      String.init)
    guard components.count <= limits.maximumDepth,
      !components.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    else { throw .unsafeName }
    return components
  } // End of static func nameComponents(_:limits:)

  /// Checks that `components` lie in `muxFinder.app`, or are its AppleDouble companion
  /// `._muxFinder.app`, or those two below `__MACOSX`.
  static func checkTopLevel(_ components: [String]) throws(UpdateArchiveProblem) {
    let companion = "._" + appName
    switch components[0] {
    case appName: return
    case companion where components.count == 1: return
    case "__MACOSX":
      if components.count == 1 || components[1] == appName { return }
      if components[1] == companion, components.count == 2 { return }
      throw .outsideApp
    default: throw .outsideApp
    }
  } // End of static func checkTopLevel(_:)

  /// Checks every entry's kind, method and sizes, and returns the declared total.
  static func checkSizes(_ entries: [Entry], limits: UpdateArchiveLimits)
    throws(UpdateArchiveProblem) -> Int
  {
    var total = 0
    for entry in entries {
      let kind = kind(of: entry)
      guard kind != .other, entry.flags & 0x0041 == 0, entry.method == 0 || entry.method == 8
      else { throw .unsupportedEntry }
      let isFolderName = entry.name.last == 0x2F
      guard isFolderName == (kind == .folder) || (isFolderName && kind == .unknown) else {
        throw .malformed
      }
      if isFolderName, entry.compressed != 0 || entry.uncompressed != 0 { throw .malformed }
      if entry.method == 0, entry.compressed != entry.uncompressed { throw .malformed }
      if entry.method == 8 {
        // A deflate stream is never empty, and never much longer than what it holds.
        guard entry.uncompressed == 0 || entry.compressed > 0,
          entry.compressed <= entry.uncompressed + entry.uncompressed / 1024 + 64
        else { throw .malformed }
      }
      guard entry.uncompressed <= limits.maximumEntryBytes else { throw .entryTooLarge }
      if entry.uncompressed > limits.ratioFloor,
        entry.uncompressed > entry.compressed * limits.maximumRatio
      {
        throw .ratioTooHigh
      }
      total += entry.uncompressed
      guard total <= limits.maximumBytes else { throw .tooLarge }
    } // End of loop over the entries' sizes
    return total
  } // End of static func checkSizes(_:limits:)

  /// Checks that every entry's local header agrees with its directory record and that the
  /// entries (headers, data and data descriptors) cover the bytes before the directory
  /// exactly, with no gap and no overlap.
  static func checkLocalHeaders(_ entries: [Entry], reader: Reader, directoryOffset: Int)
    throws(UpdateArchiveProblem)
  {
    var spans: [(start: Int, end: Int)] = []
    spans.reserveCapacity(entries.count)
    for entry in entries {
      let end = try localSpanEnd(entry, reader: reader, limit: directoryOffset)
      spans.append((entry.localOffset, end))
    } // End of loop over the entries' local headers
    spans.sort { $0.start < $1.start }
    var expected = 0
    for span in spans {
      guard span.start == expected else { throw .malformed }
      expected = span.end
    } // End of loop over the entries' spans, in file order
    guard expected == directoryOffset else { throw .malformed }
  } // End of static func checkLocalHeaders(_:reader:directoryOffset:)

  /// Checks `entry`'s local header (and data descriptor) and returns where its span ends,
  /// which must not pass `limit` (the directory's offset).
  static func localSpanEnd(_ entry: Entry, reader: Reader, limit: Int)
    throws(UpdateArchiveProblem) -> Int
  {
    guard entry.localOffset + 30 <= limit else { throw .malformed }
    let header = try reader.bytes(at: entry.localOffset, count: 30)
    let nameLength = Int(header.u16(26))
    let extraLength = Int(header.u16(28))
    guard header.u32(0) == localSignature, header.u16(6) == entry.flags,
      header.u16(8) == entry.method, nameLength == entry.name.count,
      entry.localOffset + 30 + nameLength + extraLength <= limit
    else { throw .malformed }
    let variable = try reader.bytes(
      at: entry.localOffset + 30, count: nameLength + extraLength)
    guard Array(variable.storage[0..<nameLength]) == entry.name else { throw .malformed }
    try checkExtra(variable, from: nameLength, count: extraLength)
    let recorded = (header.u32(14), Int(header.u32(18)), Int(header.u32(22)))
    let hasDescriptor = entry.flags & 0x0008 != 0
    if hasDescriptor {
      guard recorded.0 == 0 || recorded.0 == entry.crc,
        recorded.1 == 0 || recorded.1 == entry.compressed,
        recorded.2 == 0 || recorded.2 == entry.uncompressed
      else { throw .malformed }
    } else {
      guard recorded == (entry.crc, entry.compressed, entry.uncompressed) else {
        throw .malformed
      }
    }
    let dataEnd = entry.localOffset + 30 + nameLength + extraLength + entry.compressed
    guard dataEnd <= limit else { throw .malformed }
    guard hasDescriptor else { return dataEnd }
    let available = min(16, limit - dataEnd)
    guard available >= 12 else { throw .malformed }
    let descriptor = try reader.bytes(at: dataEnd, count: available)
    let matches = { (start: Int) in
      descriptor.u32(start) == entry.crc && Int(descriptor.u32(start + 4)) == entry.compressed
        && Int(descriptor.u32(start + 8)) == entry.uncompressed
    }
    if available == 16, descriptor.u32(0) == descriptorSignature, matches(4) {
      return dataEnd + 16
    }
    if matches(0) { return dataEnd + 12 }
    throw .malformed
  } // End of static func localSpanEnd(_:reader:limit:)

  /// Reads byte ranges of the open zip.
  struct Reader {
    /// The open zip.
    let descriptor: Int32
    /// Its size when it was opened.
    let size: Int

    /// The `count` bytes at `offset`, all of them within the file.
    func bytes(at offset: Int, count: Int) throws(UpdateArchiveProblem) -> Bytes {
      guard offset >= 0, count >= 0, offset + count <= size else { throw .malformed }
      var storage = [UInt8](repeating: 0, count: count)
      var done = 0
      while done < count {
        let result = storage.withUnsafeMutableBytes {
          pread(descriptor, $0.baseAddress! + done, count - done, off_t(offset + done))
        }
        if result > 0 {
          done += result
        } else if result == 0 {
          throw .malformed
        } else if errno != EINTR {
          throw .unreadable(errno: errno)
        }
      } // End of loop over reads
      return Bytes(storage, offset: offset)
    } // End of func bytes(at:count:)
  }

  /// Bytes read from the zip, with little-endian accessors.
  struct Bytes {
    /// The bytes.
    let storage: [UInt8]
    /// Where they begin in the zip.
    let offset: Int

    /// Wraps `storage` read at `offset`.
    init(_ storage: [UInt8], offset: Int) {
      self.storage = storage
      self.offset = offset
    }

    /// How many bytes there are.
    var count: Int { storage.count }

    /// The little-endian 16-bit value at `index`.
    func u16(_ index: Int) -> UInt16 {
      UInt16(storage[index]) | UInt16(storage[index + 1]) << 8
    }

    /// The little-endian 32-bit value at `index`.
    func u32(_ index: Int) -> UInt32 {
      UInt32(storage[index]) | UInt32(storage[index + 1]) << 8 | UInt32(storage[index + 2]) << 16
        | UInt32(storage[index + 3]) << 24
    }
  }
}
