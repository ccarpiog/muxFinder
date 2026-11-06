import Foundation

/// What the folder-search script's header says about its host (PLAN.md D36).
public struct FolderSearchHeader: Sendable, Hashable {
  /// Spotlight's indexing state for a volume, from `mdutil -s`.
  public enum IndexState: String, Sendable, Hashable {
    /// "Indexing enabled."
    case on
    /// Indexing (or Spotlight itself) is disabled.
    case off
    /// `mdutil` is missing, the volume is unknown, or the state could not be read.
    case unknown
  }

  /// Whether a protected folder (Desktop, Documents, Downloads) could be listed.
  public enum Readability: String, Sendable, Hashable {
    /// Listing it worked.
    case readable = "yes"
    /// It exists but could not be listed (macOS privacy protection over SSH, or permissions).
    case unreadable = "no"
    /// It does not exist (or the home folder is unknown).
    case missing
    /// It was not looked at: the script ran with `FolderSearchScript.uncheckedArgument`, as on
    /// This Mac (PLAN.md Phase I-10b).
    case notChecked = "unchecked"
  }

  /// The host's home folder, or `nil` when `$HOME` was not an absolute path.
  public var homeDirectory: String?
  /// Whether `mdfind` exists on the host.
  public var hasSpotlight: Bool
  /// The indexing state of the volume that holds the home folder.
  public var homeIndexing: IndexState
  /// The indexing state of `/`.
  public var diskIndexing: IndexState
  /// `~/Desktop`.
  public var desktop: Readability
  /// `~/Documents`.
  public var documents: Readability
  /// `~/Downloads`.
  public var downloads: Readability

  /// Creates a header.
  public init(
    homeDirectory: String?, hasSpotlight: Bool, homeIndexing: IndexState,
    diskIndexing: IndexState, desktop: Readability, documents: Readability,
    downloads: Readability
  ) {
    self.homeDirectory = homeDirectory
    self.hasSpotlight = hasSpotlight
    self.homeIndexing = homeIndexing
    self.diskIndexing = diskIndexing
    self.desktop = desktop
    self.documents = documents
    self.downloads = downloads
  } // End of init(homeDirectory:hasSpotlight:homeIndexing:diskIndexing:desktop:…)

  /// The indexing state of the volume `scope` searches.
  public func indexing(for scope: FolderSearchScope) -> IndexState {
    scope == .home ? homeIndexing : diskIndexing
  }

  /// Whether Desktop, Documents or Downloads exists but could not be read, so Spotlight's
  /// results from them may be missing (`notChecked` is not unreadable).
  public var hasUnreadableProtectedFolder: Bool {
    !unreadableProtectedFolders.isEmpty
  }

  /// The names of the protected folders that exist but could not be read, in the header's
  /// order ("Desktop", "Documents", "Downloads").
  public var unreadableProtectedFolders: [String] {
    zip(FolderSearchOutputParser.protectedFolders, [desktop, documents, downloads])
      .filter { $0.1 == .unreadable }
      .map { $0.0 }
  }

  /// Why `scope` cannot be searched on this host, or `nil` when it can (an `unknown` indexing
  /// state is searched: only `off` is known to find nothing).
  public func unavailability(for scope: FolderSearchScope) -> FolderSearchUnavailable? {
    if !hasSpotlight { return .noSpotlight }
    if scope == .home, homeDirectory == nil { return .noHomeFolder }
    if indexing(for: scope) == .off { return .indexingOff }
    return nil
  }
}

/// Why a host cannot answer folder searches (PLAN.md D36), known from the header or an answer.
public enum FolderSearchUnavailable: String, Sendable, Hashable {
  /// The host has no `mdfind` (not a Mac, for example).
  case noSpotlight
  /// Spotlight indexing is off for the volume the scope searches.
  case indexingOff
  /// The host's home folder is unknown, so the home scope cannot be searched.
  case noHomeFolder
}

/// One answer as the script wrote it: the paths before its end record, and the end record.
public struct FolderSearchReply: Sendable, Hashable {
  /// How the answer ended.
  public enum Status: Sendable, Hashable {
    /// Every kept folder is in the answer.
    case ok
    /// More than `FolderSearchScript.resultLimit` folders were kept; the answer holds the first.
    case limited
    /// The script refused the query or the search failed, with the script's code.
    case error(String)
  }

  /// The query id the end record names.
  public var id: UInt64
  /// How the answer ended.
  public var status: Status
  /// The paths, in the order written (an error answer holds none).
  public var paths: [String]
  /// How many path records were left out (longer than `FolderSearchOutputParser
  /// .maximumRecordLength`, or not valid UTF-8).
  public var droppedCount: Int

  /// Creates a reply.
  public init(id: UInt64, status: Status, paths: [String], droppedCount: Int = 0) {
    self.id = id
    self.status = status
    self.paths = paths
    self.droppedCount = droppedCount
  }
}

/// Output that is not what the script writes (PLAN.md D36). The parser stops at the first one.
public enum FolderSearchProtocolError: Error, Sendable, Hashable {
  /// No header began within `FolderSearchOutputParser.maximumPreambleLength` bytes.
  case noHeader
  /// A header record is missing, out of order, malformed or too long.
  case badHeader
  /// A record after the header is neither a path nor an end record.
  case unexpectedRecord
  /// An answer holds more than `FolderSearchScript.resultLimit` path records.
  case tooManyPaths
  /// An end record's count does not match the path records before it.
  case countMismatch
  /// The output ended in the middle of a record, the header or an answer.
  case truncated
  /// More parsed events waited to be read than a connection buffers
  /// (`ProcessFolderSearchTransport.eventLimit`): the host wrote far more answers than it was
  /// asked for, or nobody reads them. Reported by the transport, never by the parser.
  case eventOverflow

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .noHeader: return "noHeader"
    case .badHeader: return "badHeader"
    case .unexpectedRecord: return "unexpectedRecord"
    case .tooManyPaths: return "tooManyPaths"
    case .countMismatch: return "countMismatch"
    case .truncated: return "truncated"
    case .eventOverflow: return "eventOverflow"
    }
  } // End of var code
}

/// What the parser found in a chunk of output.
public enum FolderSearchOutputEvent: Sendable, Hashable {
  /// The header, once.
  case header(FolderSearchHeader)
  /// One complete answer.
  case reply(FolderSearchReply)
}

/// The incremental parser of the folder-search script's output (PLAN.md D36).
///
/// Records end with NUL. Before the header, up to `maximumPreambleLength` bytes that a login
/// shell's startup files may print are skipped: the first record that ends with the header's
/// first record, `muxfinder-folders 1`, starts the header, which must then hold its records in
/// order. After it, a record starting with `/` is a path of the current answer and `end …`
/// ends that answer; anything else is `unexpectedRecord`. Every buffer is bounded: one record
/// at most `maximumRecordLength` bytes (a longer path is read to its end, left out and
/// counted; a longer header record is `badHeader`), one answer at most
/// `FolderSearchScript.resultLimit` path records. The parser never interprets ids: the channel
/// drops answers to ids it does not wait for. After an error every later call throws it again.
public struct FolderSearchOutputParser: Sendable {
  /// The longest record kept, in bytes.
  public static let maximumRecordLength = 16 * 1024
  /// The most bytes skipped before the header.
  public static let maximumPreambleLength = 64 * 1024
  /// The header's first record.
  static let magic = Array("muxfinder-folders \(FolderSearchScript.formatVersion)".utf8)
  /// The protected folders, in the header's order.
  static let protectedFolders = ["Desktop", "Documents", "Downloads"]

  /// Where the parser is.
  enum Stage: Sendable {
    /// Looking for the header's first record.
    case preamble
    /// Reading the header record at this index (0 is `home`, 7 is `ready`).
    case header(Int)
    /// Reading answers.
    case answers
  }

  /// Where the parser is.
  var stage: Stage = .preamble
  /// The current record's bytes (in the preamble only its last `magic.count`).
  var record: [UInt8] = []
  /// Whether the current record grew past `maximumRecordLength`.
  var recordOversized = false
  /// Bytes seen before the header.
  var preambleLength = 0
  /// The header fields read so far.
  var fields = HeaderFields()
  /// The current answer's paths.
  var paths: [String] = []
  /// The current answer's path records left out.
  var dropped = 0
  /// The error the parser stopped at, if any.
  var failure: FolderSearchProtocolError?

  /// The header fields as they are read.
  struct HeaderFields: Sendable {
    /// `home`.
    var home: String?
    /// `mdfind`.
    var hasSpotlight = false
    /// `index home`.
    var homeIndexing = FolderSearchHeader.IndexState.unknown
    /// `index disk`.
    var diskIndexing = FolderSearchHeader.IndexState.unknown
    /// `readable …`, in order.
    var readability: [FolderSearchHeader.Readability] = []
  }

  /// A parser at the start of the output.
  public init() {}

  /// Parses `bytes`, the next chunk of output, and returns what it completed.
  public mutating func consume(
    _ bytes: some Sequence<UInt8>
  ) throws(FolderSearchProtocolError) -> [FolderSearchOutputEvent] {
    if let failure { throw failure }
    var events: [FolderSearchOutputEvent] = []
    do throws(FolderSearchProtocolError) {
      for byte in bytes {
        if byte == 0 {
          if let event = try endRecord() { events.append(event) }
        } else {
          try append(byte)
        }
      } // End of loop over the chunk's bytes
    } catch {
      failure = error
      throw error
    }
    return events
  } // End of func consume(_:)

  /// Checks the end of output: anything but a clean end after a whole answer (or the header)
  /// is `truncated`; before the header it is `noHeader`.
  public mutating func finish() throws(FolderSearchProtocolError) {
    if let failure { throw failure }
    let error: FolderSearchProtocolError?
    switch stage {
    case .preamble: error = .noHeader
    case .header: error = .truncated
    case .answers:
      let clean = record.isEmpty && !recordOversized && paths.isEmpty && dropped == 0
      error = clean ? nil : .truncated
    }
    if let error {
      failure = error
      throw error
    }
  } // End of func finish()

  /// Adds one byte that is not NUL to the current record.
  mutating func append(_ byte: UInt8) throws(FolderSearchProtocolError) {
    if case .preamble = stage {
      preambleLength += 1
      guard preambleLength <= Self.maximumPreambleLength else { throw .noHeader }
      record.append(byte)
      if record.count > Self.magic.count { record.removeFirst(record.count - Self.magic.count) }
      return
    }
    guard !recordOversized else { return }
    if record.count == Self.maximumRecordLength {
      if case .header = stage { throw .badHeader }
      recordOversized = true
      record.removeAll(keepingCapacity: true)
      return
    }
    record.append(byte)
  } // End of func append(_:)

  /// Handles the end of the current record.
  mutating func endRecord() throws(FolderSearchProtocolError) -> FolderSearchOutputEvent? {
    defer {
      record.removeAll(keepingCapacity: true)
      recordOversized = false
    }
    switch stage {
    case .preamble:
      preambleLength += 1
      guard preambleLength <= Self.maximumPreambleLength else { throw .noHeader }
      if record == Self.magic { stage = .header(0) }
      return nil
    case .header(let index):
      return try headerRecord(at: index)
    case .answers:
      return try answerRecord()
    }
  } // End of func endRecord()

  /// Reads header record `index` from `record`.
  mutating func headerRecord(at index: Int) throws(FolderSearchProtocolError)
    -> FolderSearchOutputEvent?
  {
    guard let text = Self.validUTF8(record) else { throw .badHeader }
    switch index {
    case 0:
      guard text.hasPrefix("home ") else { throw .badHeader }
      let home = String(text.dropFirst("home ".count))
      guard home.isEmpty || home.hasPrefix("/") else { throw .badHeader }
      fields.home = home.isEmpty ? nil : home
    case 1:
      switch text {
      case "mdfind yes": fields.hasSpotlight = true
      case "mdfind no": fields.hasSpotlight = false
      default: throw .badHeader
      }
    case 2:
      fields.homeIndexing = try Self.indexState(text, prefix: "index home ")
    case 3:
      fields.diskIndexing = try Self.indexState(text, prefix: "index disk ")
    case 4...6:
      let prefix = "readable \(Self.protectedFolders[index - 4]) "
      let value = String(text.dropFirst(prefix.count))
      guard text.hasPrefix(prefix),
        let readability = FolderSearchHeader.Readability(rawValue: value)
      else { throw .badHeader }
      fields.readability.append(readability)
    default:
      guard text == "ready", fields.readability.count == 3 else { throw .badHeader }
      stage = .answers
      return .header(
        FolderSearchHeader(
          homeDirectory: fields.home, hasSpotlight: fields.hasSpotlight,
          homeIndexing: fields.homeIndexing, diskIndexing: fields.diskIndexing,
          desktop: fields.readability[0], documents: fields.readability[1],
          downloads: fields.readability[2]))
    }
    stage = .header(index + 1)
    return nil
  } // End of func headerRecord(at:)

  /// The indexing state in `text`, which must start with `prefix`.
  static func indexState(
    _ text: String, prefix: String
  ) throws(FolderSearchProtocolError) -> FolderSearchHeader.IndexState {
    guard text.hasPrefix(prefix),
      let state = FolderSearchHeader.IndexState(rawValue: String(text.dropFirst(prefix.count)))
    else { throw .badHeader }
    return state
  }

  /// Reads a record after the header: a path, or the end of an answer.
  mutating func answerRecord() throws(FolderSearchProtocolError) -> FolderSearchOutputEvent? {
    if recordOversized || record.first == UInt8(ascii: "/") {
      guard paths.count + dropped < FolderSearchScript.resultLimit else { throw .tooManyPaths }
      if !recordOversized, let path = Self.validUTF8(record) {
        paths.append(path)
      } else {
        dropped += 1
      }
      return nil
    }
    guard let end = Self.endRecord(record) else { throw .unexpectedRecord }
    let reply: FolderSearchReply
    switch end.status {
    case .error:
      // An error answer holds no paths, whatever came before its end.
      reply = FolderSearchReply(id: end.id, status: end.status, paths: [])
    case .ok, .limited:
      let count = paths.count + dropped
      let expected = end.status == .limited ? FolderSearchScript.resultLimit : count
      guard end.count == count, count == expected else { throw .countMismatch }
      reply = FolderSearchReply(id: end.id, status: end.status, paths: paths, droppedCount: dropped)
    }
    paths = []
    dropped = 0
    return .reply(reply)
  } // End of func answerRecord()

  /// An end record's fields.
  struct EndRecord: Sendable, Hashable {
    /// The query id.
    var id: UInt64
    /// How the answer ended.
    var status: FolderSearchReply.Status
    /// The count of an `ok` or `limited` record; 0 for `error`.
    var count: Int
  }

  /// The fields of an end record, `end <id> ok|limited <count>` or `end <id> error <code>`
  /// (a code of 1 to 32 lowercase ASCII letters); `nil` when `bytes` is not one.
  static func endRecord(_ bytes: [UInt8]) -> EndRecord? {
    let parts = bytes.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
    guard parts.count == 4, parts[0].elementsEqual("end".utf8),
      let id = number(parts[1], maximumDigits: FolderSearchScript.maximumIDDigits)
    else { return nil }
    switch String(decoding: parts[2], as: UTF8.self) {
    case "ok":
      guard let count = number(parts[3], maximumDigits: 3) else { return nil }
      return EndRecord(id: id, status: .ok, count: Int(count))
    case "limited":
      guard let count = number(parts[3], maximumDigits: 3) else { return nil }
      return EndRecord(id: id, status: .limited, count: Int(count))
    case "error":
      let code = parts[3]
      guard (1...32).contains(code.count),
        code.allSatisfy({ (UInt8(ascii: "a")...UInt8(ascii: "z")).contains($0) })
      else { return nil }
      return EndRecord(id: id, status: .error(String(decoding: code, as: UTF8.self)), count: 0)
    default:
      return nil
    }
  } // End of static func endRecord(_:)

  /// `bytes` as a string when they are valid UTF-8, else `nil` (decoding replaces invalid
  /// sequences, so the result is kept only when it encodes back to the same bytes).
  static func validUTF8(_ bytes: [UInt8]) -> String? {
    let text = String(decoding: bytes, as: UTF8.self)
    return text.utf8.elementsEqual(bytes) ? text : nil
  }

  /// The decimal number `digits` holds (1 to `maximumDigits` ASCII digits), else `nil`.
  static func number(_ digits: ArraySlice<UInt8>, maximumDigits: Int) -> UInt64? {
    guard (1...maximumDigits).contains(digits.count) else { return nil }
    var value: UInt64 = 0
    for digit in digits {
      guard (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(digit) else { return nil }
      value = value * 10 + UInt64(digit - UInt8(ascii: "0"))
    } // End of loop over the digits
    return value
  }
}
