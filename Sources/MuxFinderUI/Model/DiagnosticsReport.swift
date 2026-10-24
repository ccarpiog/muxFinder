import Foundation
import MuxFinderCore

/// The plain text "Copy diagnostics" puts on the pasteboard (PLAN.md D23).
///
/// It holds muxFinder's and macOS's versions, the launch-at-login status, how the host list
/// loaded, the last iTerm2 check, the session switcher shortcut's state by kind (PLAN.md D32;
/// never the combination), each host's display name, id, mode, on/off state and status, and
/// the operation log. Content rules:
///
/// - Hosts appear by display name and id only. SSH destinations, tmux paths, iTerm2 profile
///   names and node names are the user's data and are left out (the report says whether a tmux
///   path or a profile is set, never which).
/// - A host's status is its popover label and status kind; a failed probe's message is left out,
///   since it may quote ssh's or tmux's error output, which can name the destination.
/// - Sessions are counted, never named. Nothing holds terminal contents, window titles or
///   command lines (CLAUDE.md); log details carry none by `DiagnosticEvent`'s contract and are
///   flattened to one line by `DiagnosticsLog`, again here.
/// - Times are ISO 8601 in UTC.
public enum DiagnosticsReport {
  /// Everything the report is built from.
  public struct Input: Sendable {
    /// muxFinder's version.
    public var appVersion: String
    /// The macOS version.
    public var systemVersion: String
    /// When the report is made.
    public var generatedAt: Date
    /// The host list.
    public var hosts: HostList
    /// How the host list loaded.
    public var hostListStatus: HostListStatus?
    /// The refresh engine's last state.
    public var refreshState: RefreshState?
    /// The launch-at-login status.
    public var loginItem: LoginItemStatus?
    /// The operation log, oldest first.
    public var events: [DiagnosticEvent]
    /// The session switcher shortcut's state by kind (`GlobalShortcutModel.diagnosticsCode`).
    public var globalShortcut: String?

    /// Creates an input.
    public init(
      appVersion: String,
      systemVersion: String,
      generatedAt: Date,
      hosts: HostList,
      hostListStatus: HostListStatus?,
      refreshState: RefreshState?,
      loginItem: LoginItemStatus?,
      events: [DiagnosticEvent],
      globalShortcut: String? = nil
    ) {
      self.appVersion = appVersion
      self.systemVersion = systemVersion
      self.generatedAt = generatedAt
      self.hosts = hosts
      self.hostListStatus = hostListStatus
      self.refreshState = refreshState
      self.loginItem = loginItem
      self.events = events
      self.globalShortcut = globalShortcut
    } // End of init(appVersion:systemVersion:generatedAt:hosts:hostListStatus:…)
  }

  /// The line that closes the report, saying what was left out.
  public static let exclusionNote =
    "Not included: SSH destinations, tmux paths, iTerm2 profile names, session names, terminal "
    + "contents, window titles and commands."

  /// The report for `input`, ending with a line break.
  public static func text(_ input: Input) -> String {
    var lines = [
      "muxFinder diagnostics",
      "Generated: \(timestamp(input.generatedAt))",
      "muxFinder: \(clean(input.appVersion))",
      "macOS: \(clean(input.systemVersion))",
      "Launch at login: \(input.loginItem?.code ?? "unknown")",
      "Host list: \(hostListLine(input.hostListStatus, hosts: input.hosts))",
      "iTerm2 check: \(attachmentLine(input.refreshState?.attachmentCheck))",
      "Session switcher shortcut: \(clean(input.globalShortcut ?? "unknown"))",
      "",
      "Hosts (\(input.hosts.hosts.count)):",
    ]
    let snapshots = Dictionary(
      (input.refreshState?.hosts ?? []).map { ($0.host.id, $0) }, uniquingKeysWith: { $1 })
    for host in input.hosts.hosts {
      lines.append(hostLine(host))
      lines.append("  Status: " + statusLine(host, snapshot: snapshots[host.id]))
    }
    if input.hosts.hosts.isEmpty { lines.append("- none") }
    lines.append("")
    lines.append("Log (\(input.events.count) entries, oldest first):")
    for event in input.events {
      lines.append(eventLine(event, hosts: input.hosts))
    }
    if input.events.isEmpty { lines.append("- nothing recorded") }
    lines.append("")
    lines.append(exclusionNote)
    return lines.joined(separator: "\n") + "\n"
  } // End of static func text(_:)

  /// `date` in ISO 8601, UTC, whole seconds.
  public static func timestamp(_ date: Date) -> String {
    date.formatted(.iso8601)
  }

  /// `text` on one line, capped (control characters become spaces).
  static func clean(_ text: String) -> String {
    DiagnosticsLog.sanitizedDetail(text)
  }

  /// "saved", "not saved yet", "file unusable, left as it is (notJSON)", … with the counts.
  static func hostListLine(_ status: HostListStatus?, hosts: HostList) -> String {
    let counts = "\(hosts.hosts.count) hosts, \(hosts.enabledHosts.count) turned on"
    switch status {
    case .saved: return "saved; \(counts)"
    case .notSavedYet: return "not saved yet (examples shown); \(counts)"
    case .invalid(let problem): return "file unusable, left as it is (\(problem.code)); \(counts)"
    case .unreadable: return "settings folder unreadable"
    case nil: return "not loaded"
    }
  } // End of static func hostListLine(_:hosts:)

  /// The last iTerm2 attachment check, by kind and time.
  static func attachmentLine(_ check: AttachmentCheck?) -> String {
    switch check {
    case nil, .notChecked:
      return "not run"
    case .checked(let date, let counts):
      let unmapped = counts.unknown + counts.ambiguous + counts.nonUTF8 + counts.stale
      return "checked \(timestamp(date)); \(counts.mapped) mapped, \(unmapped) unmapped"
    case .iTermNotRunning(let date):
      return "iTerm2 not running \(timestamp(date))"
    case .failed(let date, let error):
      return "failed \(timestamp(date)) (\(error?.kind ?? "other error"))"
    }
  } // End of static func attachmentLine(_:)

  /// "- Saturno (<id>): SSH, turned on, tmux path automatic, iTerm2 profile default".
  static func hostLine(_ host: HostConfig) -> String {
    let mode = host.isThisMac ? "This Mac" : "SSH"
    let state = host.isEnabled ? "turned on" : "turned off"
    let tmux = host.tmuxPathOverride == nil ? "automatic" : "set"
    let profile = host.iTermProfileName == nil ? "default" : "set"
    return "- \(clean(host.displayName)) (\(host.id.uuidString)): \(mode), \(state), "
      + "tmux path \(tmux), iTerm2 profile \(profile)"
  }

  /// The host's status label and kind, times, session count and failures in a row; "turned
  /// off" or "not checked" without a snapshot.
  static func statusLine(_ host: HostConfig, snapshot: HostSnapshot?) -> String {
    guard let snapshot else { return host.isEnabled ? "not checked" : "turned off" }
    var parts = [HostStatusLabel(snapshot).text]
    if case .failed(let status) = snapshot.lastOutcome { parts[0] += " (\(status.kind))" }
    if let attempt = snapshot.lastAttempt { parts.append("last attempt \(timestamp(attempt))") }
    if let success = snapshot.lastSuccess { parts.append("last success \(timestamp(success))") }
    let count = snapshot.sessions.count
    parts.append(
      "\(count) \(count == 1 ? "session" : "sessions") (\(snapshot.freshness.rawValue))")
    parts.append("failures in a row: \(snapshot.consecutiveFailures)")
    return parts.joined(separator: "; ")
  } // End of static func statusLine(_:snapshot:)

  /// One log entry: time, category, outcome, host (by name when known), duration, detail.
  static func eventLine(_ event: DiagnosticEvent, hosts: HostList) -> String {
    var line = "\(timestamp(event.time)) \(event.category.rawValue) \(event.outcome.rawValue)"
    if let host = hostName(for: event.hostID, in: hosts) { line += " host \(host)" }
    if event.durationMs > 0 { line += " \(event.durationMs) ms" }
    return line + ": " + clean(event.detail)
  }

  /// The display name of the host whose id is `hostID`; the id itself when no host has it, or
  /// "unknown" when it is not a host id at all (never anything else the event carried).
  static func hostName(for hostID: String?, in hosts: HostList) -> String? {
    guard let hostID else { return nil }
    guard let id = UUID(uuidString: hostID) else { return "unknown" }
    return hosts.host(withID: id).map { clean($0.displayName) } ?? id.uuidString
  }
}
