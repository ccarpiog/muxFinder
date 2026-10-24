import Foundation

/// How the discovery probe reached the host.
public enum DiscoveryTransport: String, Sendable, Hashable, Codable {
  /// `/bin/sh` on this Mac.
  case local
  /// `/usr/bin/ssh` to a remote host.
  case ssh
}

/// Turns a finished probe run into a `HostStatus`.
///
/// Order of checks: a runner timeout is `unreachable(.timeout)`; for SSH, exit status 255 is an
/// ssh error and its stderr decides the case; any other failure of the run is a `probeError`;
/// otherwise the report is parsed strictly and classified by its content.
public enum ErrorClassifier {
  /// The exit status ssh uses for its own errors (as opposed to the remote command's status).
  public static let sshErrorExitStatus: Int32 = 255

  /// Longest stderr excerpt quoted in a `probeError` message, in characters.
  public static let maximumQuotedLength = 200

  /// The result of classifying one run.
  public struct Classification: Sendable, Hashable {
    /// The host's status.
    public var status: HostStatus
    /// The parsed report, when the probe produced a valid one.
    public var report: ProbeReport?

    /// Creates a classification.
    public init(status: HostStatus, report: ProbeReport?) {
      self.status = status
      self.report = report
    }
  }

  /// ssh stderr patterns, checked in this order against the lowercased stderr. A changed host
  /// key comes first: OpenSSH prints "REMOTE HOST IDENTIFICATION HAS CHANGED" *and* "Host key
  /// verification failed" in that case.
  static let sshPatterns: [(needle: String, status: HostStatus)] = [
    ("remote host identification has changed", .hostKeyProblem(.changed)),
    ("host key verification failed", .hostKeyProblem(.unknown)),
    ("permission denied", .authFailed),
    ("too many authentication failures", .authFailed),
    ("could not resolve hostname", .unreachable(.dnsFailure)),
    ("operation timed out", .unreachable(.timeout)),
    ("connection timed out", .unreachable(.timeout)),
    ("timeout, server", .unreachable(.timeout)),
    ("connection refused", .unreachable(.refused)),
    ("no route to host", .unreachable(.noRoute)),
    ("network is unreachable", .unreachable(.noRoute)),
    ("host is down", .unreachable(.noRoute)),
  ]

  /// Classifies the run of a discovery probe for the host `hostID`.
  public static func classify(
    _ result: ProcessResult,
    transport: DiscoveryTransport,
    hostID: UUID
  ) -> Classification {
    if result.timedOut {
      return Classification(status: .unreachable(.timeout), report: nil)
    }
    if transport == .ssh, result.exitCode == sshErrorExitStatus {
      return Classification(status: sshFailureStatus(stderr: result.standardError), report: nil)
    }
    if let signal = result.signal {
      return Classification(
        status: .probeError("The discovery probe was stopped by signal \(signal)."),
        report: nil
      )
    }
    if let code = result.exitCode, code != 0 {
      var message = "The discovery probe failed with exit status \(code)"
      let excerpt = firstLine(of: result.standardError)
      message += excerpt.isEmpty ? "." : ": \(excerpt)"
      return Classification(status: .probeError(message), report: nil)
    }
    if result.standardOutputTruncated {
      return Classification(status: .probeError("The discovery report is too large."), report: nil)
    }
    do throws(ProbeReportError) {
      let report = try ProbeReportParser.parse(result.standardOutput)
      return Classification(status: status(for: report, hostID: hostID), report: report)
    } catch {
      return Classification(status: .probeError(error.message), report: nil)
    }
  } // End of func classify(_:transport:hostID:)

  /// The status for an ssh run that exited with 255, from its stderr.
  public static func sshFailureStatus(stderr: Data) -> HostStatus {
    let text = String(decoding: stderr, as: UTF8.self).lowercased()
    for pattern in sshPatterns where text.contains(pattern.needle) {
      return pattern.status
    }
    let excerpt = firstLine(of: stderr)
    return .probeError(
      excerpt.isEmpty ? "ssh failed with exit status 255." : "ssh failed: \(excerpt)")
  }

  /// Whether a tmux error line means "the default server is not running": `no server running
  /// on …` (stale or missing server) or `error connecting to … (No such file or directory)`
  /// (no socket).
  public static func isNoServerMessage(_ line: String) -> Bool {
    let lowered = line.lowercased()
    if lowered.contains("no server running on") { return true }
    return lowered.contains("error connecting to")
      && lowered.contains("(no such file or directory)")
  }

  /// The status a valid report describes. Sessions get keys for `hostID`; clients are attached
  /// to their sessions, and clients of sessions that appeared after `list-sessions` ran are
  /// ignored.
  public static func status(for report: ProbeReport, hostID: UUID) -> HostStatus {
    guard report.tmuxPath != nil, let sessions = report.sessions else { return .tmuxNotFound }
    guard sessions.exitStatus == 0 else {
      if isNoServerMessage(sessions.firstErrorLine) { return .noServer }
      return .probeError(listingFailure("sessions", sessions.exitStatus, sessions.firstErrorLine))
    }
    guard let clients = report.clients else {
      return .probeError(ProbeReportError.incomplete.message)
    }
    guard clients.exitStatus == 0 else {
      if isNoServerMessage(clients.firstErrorLine) { return .noServer }
      return .probeError(listingFailure("clients", clients.exitStatus, clients.firstErrorLine))
    }
    var clientsBySession: [TmuxSessionID: [ClientSummary]] = [:]
    for client in clients.records {
      clientsBySession[client.sessionID, default: []].append(
        ClientSummary(pid: client.pid, isControlMode: client.isControlMode)
      )
    }
    let discovered = sessions.records.map { record in
      DiscoveredSession(
        key: SessionKey(hostID: hostID, server: record.server, sessionID: record.id),
        name: record.name,
        createdAt: record.createdAt,
        windowCount: record.windowCount,
        attachedClientCount: record.attachedClientCount,
        lastActivityAt: record.lastActivityAt,
        clients: clientsBySession[record.id] ?? [],
        startDirectory: record.startDirectory
      )
    }
    return .ok(discovered)
  } // End of func status(for:hostID:)

  /// The message for a failed `list-sessions` / `list-clients`.
  static func listingFailure(_ what: String, _ exitStatus: Int32, _ errorLine: String) -> String {
    let excerpt = sanitized(errorLine)
    if excerpt.isEmpty { return "tmux could not list \(what) (exit status \(exitStatus))." }
    return "tmux could not list \(what): \(excerpt)"
  }

  /// The first non-empty line of `data`, reduced to printable ASCII and capped at
  /// `maximumQuotedLength` characters. Used to quote stderr in messages.
  public static func firstLine(of data: Data) -> String {
    let text = String(decoding: data, as: UTF8.self)
    let line = text.split(whereSeparator: \.isNewline).first { !$0.allSatisfy(\.isWhitespace) }
    return sanitized(line.map(String.init) ?? "")
  }

  /// `text` with every character outside printable ASCII replaced by `?`, trimmed, and capped
  /// at `maximumQuotedLength` characters.
  static func sanitized(_ text: String) -> String {
    var scalars = String.UnicodeScalarView()
    for scalar in text.unicodeScalars.prefix(maximumQuotedLength) {
      scalars.append((0x20...0x7E).contains(scalar.value) ? scalar : "?")
    }
    return String(scalars).trimmingCharacters(in: .whitespaces)
  }
}
