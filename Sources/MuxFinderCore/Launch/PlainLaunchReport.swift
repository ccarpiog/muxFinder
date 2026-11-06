import Darwin
import Foundation

/// When a process started, as the kernel reports it (`proc_pidinfo` with `PROC_PIDTBSDINFO`:
/// `pbi_start_tvsec` and `pbi_start_tvusec`). A process id is reused once its process is
/// reaped, so a pid together with its start time names one process (PLAN.md D38).
public struct ProcessStartTime: Sendable, Hashable, Codable {
  /// Whole seconds since 1970.
  public var seconds: Int64
  /// Microseconds within that second (0–999 999).
  public var microseconds: Int32

  /// Creates a start time from the kernel's two values.
  public init(seconds: Int64, microseconds: Int32) {
    self.seconds = seconds
    self.microseconds = microseconds
  }

  /// Whether both values are in range: seconds not negative, microseconds below one million.
  public var isValid: Bool { seconds >= 0 && (0..<1_000_000).contains(microseconds) }

  /// The start time of the process `processID`, or `nil` when it does not exist or cannot be
  /// read. Read-only; it signals nothing.
  public static func of(_ processID: Int32) -> ProcessStartTime? {
    guard processID > 0 else { return nil }
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    let time = ProcessStartTime(
      seconds: Int64(truncatingIfNeeded: info.pbi_start_tvsec),
      microseconds: Int32(truncatingIfNeeded: info.pbi_start_tvusec))
    return time.isValid ? time : nil
  } // End of static func of(_:)
} // End of struct ProcessStartTime

/// What `muxfinder-launch attach-plain` reports early, as `<launch id>.report.json` next to the
/// request (PLAN.md D14, D38; requirement 5 of `autoclaude/processed/110-other-terminal-apps.md`):
/// written once its attach child has started and before it waits on it, so the coordinator
/// (I-12c) can tell the launch's tmux client from every other one on This Mac: the client whose
/// `client_tty` is `terminalPath`, while `attachChildPID` with `attachChildStartTime` is still
/// that process (a terminal's path is reused as soon as its process exits).
///
/// It holds ids, numbers and the terminal's device path only, never terminal content. `attach`
/// writes none: an iTerm2 attach is confirmed by its tmux connection (D15).
public struct PlainLaunchReport: Sendable, Hashable, Codable {
  /// The schema version this build writes and reads.
  public static let currentSchemaVersion = 1
  /// The longest terminal path accepted.
  public static let maximumTerminalPathLength = Int(MAXPATHLEN)

  /// The schema version.
  public var schemaVersion: Int
  /// The launch id of the request this report belongs to.
  public var id: LaunchToken
  /// The helper's process id.
  public var helperPID: Int32
  /// The helper's terminal, from its standard input with `ttyname` (such as `/dev/ttys004`);
  /// `nil` when standard input is not a terminal, which the coordinator treats as "cannot
  /// confirm here".
  public var terminalPath: String?
  /// The attach child's process id: the local tmux client, or `/usr/bin/ssh` for an SSH host.
  public var attachChildPID: Int32
  /// The attach child's start time, as the kernel reports it.
  public var attachChildStartTime: ProcessStartTime

  /// Creates a report of the current schema.
  public init(
    id: LaunchToken,
    helperPID: Int32,
    terminalPath: String?,
    attachChildPID: Int32,
    attachChildStartTime: ProcessStartTime
  ) {
    schemaVersion = Self.currentSchemaVersion
    self.id = id
    self.helperPID = helperPID
    self.terminalPath = terminalPath
    self.attachChildPID = attachChildPID
    self.attachChildStartTime = attachChildStartTime
  } // End of init(id:helperPID:terminalPath:attachChildPID:attachChildStartTime:)

  /// Whether every field is usable: the current schema, positive process ids, a valid start
  /// time and, when present, a terminal path `isValidTerminalPath(_:)` accepts.
  public var isWellFormed: Bool {
    guard schemaVersion == Self.currentSchemaVersion, helperPID > 0, attachChildPID > 0,
      attachChildStartTime.isValid
    else { return false }
    if let terminalPath { return Self.isValidTerminalPath(terminalPath) }
    return true
  }

  /// Whether `path` reads as a terminal device's path: `/dev/` and a name, at most
  /// `maximumTerminalPathLength` bytes, printable ASCII without spaces.
  public static func isValidTerminalPath(_ path: String) -> Bool {
    let bytes = path.utf8
    return path.hasPrefix("/dev/") && bytes.count > 5 && bytes.count <= maximumTerminalPathLength
      && bytes.allSatisfy { (0x21...0x7E).contains($0) }
  }
} // End of struct PlainLaunchReport

/// Where `attach-plain` reads the facts of its early report (PLAN.md D38): its terminal's path
/// and its attach child's start time. Tests pass fixed values; production reads the process's
/// standard input and the kernel.
public struct PlainLaunchFacts: Sendable {
  /// The helper's terminal path, or `nil` when its standard input is not a terminal.
  public var terminalPath: @Sendable () -> String?
  /// The start time of a process (the attach child, unreaped while it runs), or `nil`.
  public var startTime: @Sendable (Int32) -> ProcessStartTime?

  /// Creates facts from two readers.
  public init(
    terminalPath: @escaping @Sendable () -> String?,
    startTime: @escaping @Sendable (Int32) -> ProcessStartTime?
  ) {
    self.terminalPath = terminalPath
    self.startTime = startTime
  }

  /// The process's own: `terminalPath(of:)` of standard input and `ProcessStartTime.of(_:)`.
  public static let standard = PlainLaunchFacts(
    terminalPath: { terminalPath(of: STDIN_FILENO) },
    startTime: { ProcessStartTime.of($0) })

  /// The path of the terminal `descriptor` refers to (`ttyname_r`), or `nil` when it is not a
  /// terminal or the path is not one `PlainLaunchReport.isValidTerminalPath(_:)` accepts.
  public static func terminalPath(of descriptor: Int32) -> String? {
    guard isatty(descriptor) == 1 else { return nil }
    var name = [CChar](repeating: 0, count: Int(MAXPATHLEN))
    guard ttyname_r(descriptor, &name, name.count) == 0 else { return nil }
    let path = String(
      decoding: name.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    return PlainLaunchReport.isValidTerminalPath(path) ? path : nil
  } // End of static func terminalPath(of:)
} // End of struct PlainLaunchFacts
