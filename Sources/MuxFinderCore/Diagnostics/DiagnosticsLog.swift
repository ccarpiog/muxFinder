import Foundation
import os

/// The area of the app an event comes from. Also used as the `os.Logger` category.
public struct DiagnosticCategory: RawRepresentable, Hashable, Sendable {
  /// The category name.
  public let rawValue: String

  /// Creates a category with the given name.
  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  /// Running external processes.
  public static let process = DiagnosticCategory(rawValue: "process")
  /// Connections to iTerm2's API.
  public static let iTerm2 = DiagnosticCategory(rawValue: "iterm2")
  /// The launch helper (`muxfinder-launch`) and its request and result files.
  public static let launch = DiagnosticCategory(rawValue: "launch")
  /// Attaching and detaching tmux sessions in iTerm2 (`AttachCoordinator`).
  public static let attach = DiagnosticCategory(rawValue: "attach")
  /// The host list and the Settings window: loads, saves, connection tests, launch at login.
  public static let settings = DiagnosticCategory(rawValue: "settings")
  /// Application lifecycle and anything without a more specific category.
  public static let general = DiagnosticCategory(rawValue: "general")
}

/// How an operation ended.
public enum DiagnosticOutcome: String, Sendable, Equatable {
  /// The operation succeeded.
  case success
  /// The operation failed.
  case failure
  /// The operation hit its time limit.
  case timedOut
  /// The operation was cancelled.
  case cancelled
  /// Informational record, not the end of an operation.
  case info
}

/// One diagnostics record.
///
/// `detail` describes what happened in plain words ("exit status 255", "permission denied").
/// It must never contain command lines with user data, terminal output or window titles.
/// `DiagnosticsLog` additionally flattens control characters and caps the length, so stray
/// multi-line output cannot slip in whole.
public struct DiagnosticEvent: Sendable, Equatable {
  /// When the event was recorded.
  public let time: Date
  /// Where the event comes from.
  public let category: DiagnosticCategory
  /// The configured host involved, if any.
  public let hostID: String?
  /// How the operation ended.
  public let outcome: DiagnosticOutcome
  /// How long the operation took, in milliseconds (0 when not applicable).
  public let durationMs: Int
  /// Plain description, already sanitized.
  public let detail: String

  /// Creates an event. `detail` is stored as given; `DiagnosticsLog` sanitizes before creating
  /// events.
  public init(
    time: Date,
    category: DiagnosticCategory,
    hostID: String?,
    outcome: DiagnosticOutcome,
    durationMs: Int,
    detail: String
  ) {
    self.time = time
    self.category = category
    self.hostID = hostID
    self.outcome = outcome
    self.durationMs = durationMs
    self.detail = detail
  } // End of init(time:category:hostID:outcome:durationMs:detail:)
}

/// In-memory ring buffer of recent operations, mirrored to the unified log under subsystem
/// `cc.carpio.muxfinder`. It backs the diagnostics view.
public actor DiagnosticsLog {
  /// The unified-logging subsystem.
  public static let subsystem = "cc.carpio.muxfinder"
  /// Default number of events kept.
  public static let defaultCapacity = 500
  /// Longest detail kept, in characters.
  public static let maximumDetailLength = 300

  /// Maximum number of events kept; the oldest are dropped first.
  public let capacity: Int
  /// Whether events are also written to `os.Logger`.
  private let writesToSystemLog: Bool
  /// Source of event timestamps.
  private let now: @Sendable () -> Date
  /// Storage; once full, `nextIndex` points at the oldest event.
  private var storage: [DiagnosticEvent] = []
  /// Where the next event goes once `storage` is full.
  private var nextIndex = 0

  /// Creates a log. Tests pass `writesToSystemLog: false` and a fixed clock.
  public init(
    capacity: Int = DiagnosticsLog.defaultCapacity,
    writesToSystemLog: Bool = true,
    now: @escaping @Sendable () -> Date = { Date() }
  ) {
    self.capacity = max(1, capacity)
    self.writesToSystemLog = writesToSystemLog
    self.now = now
  }

  /// Records an event and returns it as stored (with the detail sanitized).
  @discardableResult
  public func record(
    _ category: DiagnosticCategory,
    outcome: DiagnosticOutcome,
    hostID: String? = nil,
    durationMs: Int = 0,
    detail: String
  ) -> DiagnosticEvent {
    let event = DiagnosticEvent(
      time: now(),
      category: category,
      hostID: hostID,
      outcome: outcome,
      durationMs: max(0, durationMs),
      detail: Self.sanitizedDetail(detail)
    )
    if storage.count < capacity {
      storage.append(event)
    } else {
      storage[nextIndex] = event
      nextIndex = (nextIndex + 1) % capacity
    }
    if writesToSystemLog { Self.writeToSystemLog(event) }
    return event
  } // End of func record(_:outcome:hostID:durationMs:detail:)

  /// The kept events, oldest first.
  public func events() -> [DiagnosticEvent] {
    Array(storage[nextIndex...] + storage[..<nextIndex])
  }

  /// Removes every event.
  public func removeAll() {
    storage.removeAll()
    nextIndex = 0
  }

  /// Replaces control characters (line breaks, tabs, escape sequences) with spaces and caps the
  /// length, so a detail stays a single short line.
  public static func sanitizedDetail(_ detail: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in detail.unicodeScalars {
      scalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
    }
    let flattened = String(scalars)
    guard flattened.count > maximumDetailLength else { return flattened }
    return String(flattened.prefix(maximumDetailLength - 1)) + "…"
  }

  /// Mirrors `event` to the unified log. Host ids and details are marked private.
  private static func writeToSystemLog(_ event: DiagnosticEvent) {
    let logger = Logger(subsystem: subsystem, category: event.category.rawValue)
    let level: OSLogType
    switch event.outcome {
    case .failure, .timedOut: level = .error
    case .cancelled: level = .default
    case .success, .info: level = .info
    }
    logger.log(
      level: level,
      """
      \(event.outcome.rawValue, privacy: .public) \
      host=\(event.hostID ?? "-", privacy: .private) \
      durationMs=\(event.durationMs, privacy: .public) \
      \(event.detail, privacy: .private)
      """
    )
  } // End of func writeToSystemLog(_:)
}
