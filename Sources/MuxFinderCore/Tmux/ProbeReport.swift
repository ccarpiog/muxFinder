import Foundation

/// A parsed discovery report (format 1, see `ProbeScript`).
///
/// It holds what the probe saw, before classification: `ErrorClassifier` turns it into a
/// `HostStatus`.
public struct ProbeReport: Sendable, Hashable {
  /// One `session` line.
  public struct SessionRecord: Sendable, Hashable {
    /// `#{session_id}`.
    public var id: TmuxSessionID
    /// `#{session_created}`, seconds since 1970.
    public var createdAt: Int64
    /// `#{session_windows}`.
    public var windowCount: Int
    /// `#{session_attached}`.
    public var attachedClientCount: Int
    /// `#{session_activity}`, seconds since 1970.
    public var lastActivityAt: Int64
    /// `#{pid}`, `#{start_time}` and `#{socket_path}` of the server.
    public var server: ServerIdentity
    /// `#{session_name}`: everything after the fixed fields, tabs included. Display text only.
    public var name: String

    /// Creates a session record.
    public init(
      id: TmuxSessionID,
      createdAt: Int64,
      windowCount: Int,
      attachedClientCount: Int,
      lastActivityAt: Int64,
      server: ServerIdentity,
      name: String
    ) {
      self.id = id
      self.createdAt = createdAt
      self.windowCount = windowCount
      self.attachedClientCount = attachedClientCount
      self.lastActivityAt = lastActivityAt
      self.server = server
      self.name = name
    } // End of init(id:createdAt:windowCount:attachedClientCount:lastActivityAt:server:name:)
  }

  /// One `client` line.
  public struct ClientRecord: Sendable, Hashable {
    /// `#{session_id}` of the session the client is attached to.
    public var sessionID: TmuxSessionID
    /// `#{client_control_mode}`.
    public var isControlMode: Bool
    /// `#{client_pid}`.
    public var pid: Int32

    /// Creates a client record.
    public init(sessionID: TmuxSessionID, isControlMode: Bool, pid: Int32) {
      self.sessionID = sessionID
      self.isControlMode = isControlMode
      self.pid = pid
    }
  }

  /// The outcome of one listing command (`list-sessions` or `list-clients`).
  public struct Listing<Record: Sendable & Hashable>: Sendable, Hashable {
    /// The command's records, in tmux's order.
    public var records: [Record]
    /// The command's exit status.
    public var exitStatus: Int32
    /// The first line of its stderr, printable ASCII only (empty when there was none).
    public var firstErrorLine: String

    /// Creates a listing.
    public init(records: [Record], exitStatus: Int32, firstErrorLine: String) {
      self.records = records
      self.exitStatus = exitStatus
      self.firstErrorLine = firstErrorLine
    }
  }

  /// `uname -n` of the host, for example `Saturno-M4.local`.
  public var nodeName: String
  /// The tmux executable the probe used, or `nil` when none was found.
  public var tmuxPath: String?
  /// First line of `tmux -V`, for example `tmux 3.8`; `nil` when tmux was not found.
  public var tmuxVersion: String?
  /// The `list-sessions` outcome; `nil` when tmux was not found.
  public var sessions: Listing<SessionRecord>?
  /// The `list-clients` outcome; `nil` when it did not run (tmux not found, or `list-sessions`
  /// failed).
  public var clients: Listing<ClientRecord>?

  /// Creates a report.
  public init(
    nodeName: String,
    tmuxPath: String? = nil,
    tmuxVersion: String? = nil,
    sessions: Listing<SessionRecord>? = nil,
    clients: Listing<ClientRecord>? = nil
  ) {
    self.nodeName = nodeName
    self.tmuxPath = tmuxPath
    self.tmuxVersion = tmuxVersion
    self.sessions = sessions
    self.clients = clients
  } // End of init(nodeName:tmuxPath:tmuxVersion:sessions:clients:)
}

/// Why a discovery report was rejected. `message` is English, sentence case, and safe to show:
/// it never quotes report content.
public enum ProbeReportError: Error, Sendable, Hashable, CustomStringConvertible {
  /// The probe printed nothing.
  case empty
  /// The first line is not a probe header (something printed before the report, or the output
  /// is not a report at all).
  case missingHeader
  /// The header names a format version this build does not understand.
  case unsupportedVersion
  /// The report stops before its `end` line, or its last line is not terminated.
  case incomplete
  /// A line is longer than `ProbeReportParser.maximumLineLength` bytes.
  case lineTooLong(line: Int)
  /// A line does not have the expected shape.
  case malformed(line: Int)
  /// The nonce line does not hold 16 lowercase hex digits.
  case invalidNonce
  /// More than `ProbeReportParser.maximumSessionCount` session lines.
  case tooManySessions
  /// More than `ProbeReportParser.maximumClientCount` client lines.
  case tooManyClients
  /// The same session id appears twice.
  case duplicateSession(line: Int)
  /// Session lines name different tmux servers.
  case inconsistentServer(line: Int)
  /// Something follows the `end` line.
  case trailingOutput(line: Int)

  /// The user-facing explanation.
  public var message: String {
    switch self {
    case .empty:
      return "The host sent no discovery report."
    case .missingHeader:
      return
        "Unexpected output before the discovery report. A shell startup file on the host may "
        + "be printing text."
    case .unsupportedVersion:
      return "The discovery report uses an unsupported format version."
    case .incomplete:
      return "The discovery report is incomplete."
    case .lineTooLong(let line):
      return "The discovery report has a line longer than 4 KiB (line \(line))."
    case .malformed(let line):
      return "The discovery report is malformed (line \(line))."
    case .invalidNonce:
      return "The discovery probe could not create its random token."
    case .tooManySessions:
      return "The host has more than 1,000 tmux sessions."
    case .tooManyClients:
      return "The host has more than 1,000 tmux clients."
    case .duplicateSession(let line):
      return "The discovery report lists a session twice (line \(line))."
    case .inconsistentServer(let line):
      return "The discovery report mixes sessions from different tmux servers (line \(line))."
    case .trailingOutput(let line):
      return "Unexpected output after the discovery report (line \(line))."
    }
  } // End of var message

  /// Same as `message`.
  public var description: String { message }
}

/// The strict parser for discovery reports.
///
/// It works on bytes and accepts exactly the grammar `ProbeScript` writes. Fixed fields must be
/// canonical: ids match `^\$[0-9]+$`, integers are plain decimal digits without sign, spaces or
/// leading zeros, and the per-run nonce must match on every record. The session name is the
/// remainder of its line and is never interpreted. Anything unexpected, oversized or
/// inconsistent throws `ProbeReportError`; nothing traps.
public enum ProbeReportParser {
  /// The header line of format 1.
  public static let header = "MUXFINDER-PROBE \(ProbeScript.formatVersion)"
  /// The longest accepted line, in bytes, without its newline.
  public static let maximumLineLength = 4096
  /// The most session lines accepted.
  public static let maximumSessionCount = 1000
  /// The most client lines accepted.
  public static let maximumClientCount = 1000
  /// Number of tab-separated fields before the name on a session line (tag and nonce
  /// included).
  static let sessionFixedFieldCount = 10
  /// Number of tab-separated fields on a client line.
  static let clientFieldCount = 5

  /// Parses `data`, the probe's complete standard output.
  public static func parse(_ data: Data) throws(ProbeReportError) -> ProbeReport {
    let bytes = [UInt8](data)
    guard !bytes.isEmpty else { throw .empty }
    var lines = LineReader(bytes: bytes)
    guard let first = try lines.next() else { throw .empty }
    guard first.elementsEqual(header.utf8) else {
      if first.starts(with: "MUXFINDER-PROBE ".utf8) { throw .unsupportedVersion }
      throw .missingHeader
    }
    let nonce = try lines.value(of: "nonce")
    guard nonce.count == 16, nonce.allSatisfy(isLowercaseHexDigit) else { throw .invalidNonce }
    var report = ProbeReport(nodeName: try text(lines.value(of: "host")))
    if try lines.peek()?.elementsEqual("tmux-not-found".utf8) == true {
      _ = try lines.next()
    } else {
      let path = try text(lines.value(of: "tmux"))
      guard path.hasPrefix("/") else { throw .malformed(line: lines.lineNumber) }
      report.tmuxPath = path
      report.tmuxVersion = try text(lines.value(of: "version"))
      let sessions = try parseSessions(&lines, nonce: nonce)
      report.sessions = sessions
      if sessions.exitStatus == 0 {
        report.clients = try parseClients(&lines, nonce: nonce)
      }
    }
    let end = try lines.value(of: "end")
    guard end.elementsEqual(nonce) else { throw .malformed(line: lines.lineNumber) }
    if try lines.next() != nil { throw .trailingOutput(line: lines.lineNumber) }
    return report
  } // End of func parse(_:)

  /// Parses the session lines and the `sessions-exit` / `sessions-stderr` pair after them.
  static func parseSessions(
    _ lines: inout LineReader,
    nonce: ArraySlice<UInt8>
  ) throws(ProbeReportError) -> ProbeReport.Listing<ProbeReport.SessionRecord> {
    var records: [ProbeReport.SessionRecord] = []
    var seen = Set<TmuxSessionID>()
    while let line = try lines.peek(), line.starts(with: "session\t".utf8) {
      _ = try lines.next()
      let lineNumber = lines.lineNumber
      guard records.count < maximumSessionCount else { throw .tooManySessions }
      let record = try sessionRecord(line, nonce: nonce, line: lineNumber)
      guard seen.insert(record.id).inserted else { throw .duplicateSession(line: lineNumber) }
      if let server = records.first?.server, server != record.server {
        throw .inconsistentServer(line: lineNumber)
      }
      records.append(record)
    } // End of loop over session lines
    let exitStatus = try lines.exitStatus(of: "sessions-exit")
    let errorLine = try text(lines.value(of: "sessions-stderr"))
    return ProbeReport.Listing(records: records, exitStatus: exitStatus, firstErrorLine: errorLine)
  } // End of func parseSessions(_:nonce:)

  /// Parses the client lines and the `clients-exit` / `clients-stderr` pair after them.
  static func parseClients(
    _ lines: inout LineReader,
    nonce: ArraySlice<UInt8>
  ) throws(ProbeReportError) -> ProbeReport.Listing<ProbeReport.ClientRecord> {
    var records: [ProbeReport.ClientRecord] = []
    while let line = try lines.peek(), line.starts(with: "client\t".utf8) {
      _ = try lines.next()
      guard records.count < maximumClientCount else { throw .tooManyClients }
      records.append(try clientRecord(line, nonce: nonce, line: lines.lineNumber))
    }
    let exitStatus = try lines.exitStatus(of: "clients-exit")
    let errorLine = try text(lines.value(of: "clients-stderr"))
    return ProbeReport.Listing(records: records, exitStatus: exitStatus, firstErrorLine: errorLine)
  } // End of func parseClients(_:nonce:)

  /// Parses one `session` line. The name is everything after the tenth tab.
  static func sessionRecord(
    _ line: ArraySlice<UInt8>,
    nonce: ArraySlice<UInt8>,
    line lineNumber: Int
  ) throws(ProbeReportError) -> ProbeReport.SessionRecord {
    let fields = line.split(
      separator: tab,
      maxSplits: sessionFixedFieldCount,
      omittingEmptySubsequences: false
    )
    guard fields.count == sessionFixedFieldCount + 1, fields[1].elementsEqual(nonce),
      let id = sessionID(fields[2]),
      let createdAt = decimal(fields[3]),
      let windowCount = decimal(fields[4]).flatMap({ Int(exactly: $0) }),
      let attachedCount = decimal(fields[5]).flatMap({ Int(exactly: $0) }),
      let lastActivityAt = decimal(fields[6]),
      let pid = processID(fields[7]),
      let startTime = decimal(fields[8]),
      let socketPath = socketPath(fields[9])
    else { throw .malformed(line: lineNumber) }
    return ProbeReport.SessionRecord(
      id: id,
      createdAt: createdAt,
      windowCount: windowCount,
      attachedClientCount: attachedCount,
      lastActivityAt: lastActivityAt,
      server: ServerIdentity(socketPath: socketPath, pid: pid, startTime: startTime),
      name: String(decoding: fields[10], as: UTF8.self)
    )
  } // End of func sessionRecord(_:nonce:line:)

  /// Parses one `client` line: exactly five fields, no remainder.
  static func clientRecord(
    _ line: ArraySlice<UInt8>,
    nonce: ArraySlice<UInt8>,
    line lineNumber: Int
  ) throws(ProbeReportError) -> ProbeReport.ClientRecord {
    let fields = line.split(separator: tab, omittingEmptySubsequences: false)
    guard fields.count == clientFieldCount, fields[1].elementsEqual(nonce),
      let id = sessionID(fields[2]),
      let controlMode = decimal(fields[3]), controlMode <= 1,
      let pid = processID(fields[4])
    else { throw .malformed(line: lineNumber) }
    return ProbeReport.ClientRecord(sessionID: id, isControlMode: controlMode == 1, pid: pid)
  } // End of func clientRecord(_:nonce:line:)

  /// The tab byte.
  static let tab = UInt8(ascii: "\t")

  /// Decodes a free-text field. Invalid UTF-8 becomes U+FFFD; nothing is interpreted.
  static func text(_ bytes: ArraySlice<UInt8>) -> String {
    String(decoding: bytes, as: UTF8.self)
  }

  /// Parses a canonical non-negative decimal: 1 to 18 ASCII digits, no sign, no spaces, and no
  /// leading zero unless the number is 0. Returns `nil` for anything else.
  static func decimal(_ bytes: ArraySlice<UInt8>) -> Int64? {
    guard !bytes.isEmpty, bytes.count <= 18 else { return nil }
    guard bytes.count == 1 || bytes.first != UInt8(ascii: "0") else { return nil }
    var value: Int64 = 0
    for byte in bytes {
      guard byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") else { return nil }
      value = value * 10 + Int64(byte - UInt8(ascii: "0"))
    }
    return value
  } // End of func decimal(_:)

  /// Parses a process id: a canonical decimal from 1 to `Int32.max`.
  static func processID(_ bytes: ArraySlice<UInt8>) -> Int32? {
    guard let value = decimal(bytes), value >= 1 else { return nil }
    return Int32(exactly: value)
  }

  /// Parses a session id field (`^\$[0-9]+$`).
  static func sessionID(_ bytes: ArraySlice<UInt8>) -> TmuxSessionID? {
    guard TmuxSessionID.isValid(bytes) else { return nil }
    return TmuxSessionID(String(decoding: bytes, as: UTF8.self))
  }

  /// Parses a socket path: absolute and free of control characters.
  static func socketPath(_ bytes: ArraySlice<UInt8>) -> String? {
    guard bytes.first == UInt8(ascii: "/"), !bytes.contains(where: { $0 < 0x20 || $0 == 0x7F })
    else { return nil }
    return String(decoding: bytes, as: UTF8.self)
  }

  /// Whether `byte` is `0`–`9` or `a`–`f`.
  static func isLowercaseHexDigit(_ byte: UInt8) -> Bool {
    (byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9"))
      || (byte >= UInt8(ascii: "a") && byte <= UInt8(ascii: "f"))
  }
}

/// Splits report bytes into newline-terminated lines, lazily, enforcing the line-length cap.
struct LineReader {
  /// The whole report.
  let bytes: [UInt8]
  /// Where the next line starts.
  private var position = 0
  /// The line `peek()` already split off, if any, and where the line after it starts.
  private var peeked: (line: ArraySlice<UInt8>, next: Int)?
  /// 1-based number of the line most recently returned by `next()`.
  private(set) var lineNumber = 0

  /// Creates a reader over `bytes`.
  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  /// Returns the next line without consuming it, or `nil` at the end.
  mutating func peek() throws(ProbeReportError) -> ArraySlice<UInt8>? {
    if let peeked { return peeked.line }
    guard position < bytes.count else { return nil }
    guard let newline = bytes[position...].firstIndex(of: UInt8(ascii: "\n")) else {
      throw .incomplete
    }
    let line = bytes[position..<newline]
    guard line.count <= ProbeReportParser.maximumLineLength else {
      throw .lineTooLong(line: lineNumber + 1)
    }
    peeked = (line, newline + 1)
    return line
  } // End of func peek()

  /// Returns and consumes the next line, or `nil` at the end.
  mutating func next() throws(ProbeReportError) -> ArraySlice<UInt8>? {
    guard let line = try peek(), let peeked else { return nil }
    position = peeked.next
    self.peeked = nil
    lineNumber += 1
    return line
  }

  /// Returns and consumes the next line; the report is incomplete if there is none.
  mutating func require() throws(ProbeReportError) -> ArraySlice<UInt8> {
    guard let line = try next() else { throw .incomplete }
    return line
  }

  /// Consumes a `<key>\t<value>` line and returns the value: the rest of the line after the
  /// first tab. Throws `.malformed` when the line has another key.
  mutating func value(of key: String) throws(ProbeReportError) -> ArraySlice<UInt8> {
    let line = try require()
    let prefix = Array(key.utf8) + [ProbeReportParser.tab]
    guard line.starts(with: prefix) else { throw .malformed(line: lineNumber) }
    return line.dropFirst(prefix.count)
  }

  /// Consumes a `<key>\t<status>` line whose status is a canonical decimal from 0 to 255.
  mutating func exitStatus(of key: String) throws(ProbeReportError) -> Int32 {
    let field = try value(of: key)
    guard let status = ProbeReportParser.decimal(field), status <= 255 else {
      throw .malformed(line: lineNumber)
    }
    return Int32(status)
  }
}
