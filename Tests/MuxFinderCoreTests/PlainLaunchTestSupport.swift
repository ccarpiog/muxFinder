import Darwin
import Foundation
import os

@testable import MuxFinderCore

/// A `LaunchChildRunner` over `FakeLaunchChildRunner` that also records which standard input
/// each attach call asked for (the plain modes ask for `terminalReadWrite`, PLAN.md D38; every
/// other mode's call is `inherited`), and runs `afterSpawn` right after the child is reported
/// to `onSpawn`, while it still "runs" (so a test can look at what exists by then).
final class StandardInputRecordingRunner: LaunchChildRunner {
  /// The fake that plays the canned outcomes.
  let base: FakeLaunchChildRunner
  /// Runs right after `onSpawn`, before the call returns.
  let afterSpawn: (@Sendable () -> Void)?
  /// The standard input of each attach call, in order.
  private let recorded = OSAllocatedUnfairLock<[LaunchChildStandardInput]>(initialState: [])

  /// Wraps `base`.
  init(_ base: FakeLaunchChildRunner, afterSpawn: (@Sendable () -> Void)? = nil) {
    self.base = base
    self.afterSpawn = afterSpawn
  }

  /// The standard input of each attach call so far.
  var standardInputs: [LaunchChildStandardInput] { recorded.withLock { $0 } }

  /// The base's check.
  func runCheck(
    _ request: ProcessRequest
  ) async throws(ProcessRunnerError) -> LaunchCheckOutcome {
    try await base.runCheck(request)
  }

  /// An attach call that does not choose its standard input: recorded as `inherited`.
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    relaysStandardError: Bool,
    onSpawn: (@Sendable (Int32) -> Void)?
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    try await run(
      executable: executable, arguments: arguments, environment: environment,
      relaysStandardError: relaysStandardError, standardInput: .inherited, onSpawn: onSpawn)
  }

  /// Records `standardInput` and plays the base's attach.
  func run(
    executable: String,
    arguments: [String],
    environment: [String: String],
    relaysStandardError: Bool,
    standardInput: LaunchChildStandardInput,
    onSpawn: (@Sendable (Int32) -> Void)?
  ) async throws(ProcessRunnerError) -> LaunchChildOutcome {
    recorded.withLock { $0.append(standardInput) }
    let after = afterSpawn
    return try await base.run(
      executable: executable, arguments: arguments, environment: environment,
      relaysStandardError: relaysStandardError,
      onSpawn: { processID in
        onSpawn?(processID)
        after?()
      })
  } // End of func run(executable:arguments:environment:relaysStandardError:standardInput:…)
} // End of class StandardInputRecordingRunner

/// Helpers for the plain-mode tests.
enum PlainLaunchTestSupport {
  /// The terminal definition id the plain requests are for.
  static let definitionID = "terminal"
  /// The terminal path the fixed facts report.
  static let terminalPath = "/dev/ttys042"
  /// The start time the fixed facts report for every process.
  static let startTime = ProcessStartTime(seconds: 1_792_600_002, microseconds: 123_456)
  /// Facts with `terminalPath` and `startTime` for every process.
  static let facts = PlainLaunchFacts(terminalPath: { terminalPath }, startTime: { _ in startTime })

  /// A plain request for `$3` (`LaunchTestSupport.request`), for `definitionID`, a move here
  /// when `moving`, with `keepsMinimumLifetime` as given.
  static func request(
    id: LaunchToken = LaunchToken(),
    createdAt: Date = LaunchTestSupport.requestTime,
    host: LaunchHost = .local,
    tmuxPathOverride: String? = nil,
    moving: Bool = false,
    keepsMinimumLifetime: Bool? = nil
  ) -> LaunchRequest {
    var request = LaunchTestSupport.request(
      id: id, createdAt: createdAt, host: host, tmuxPathOverride: tmuxPathOverride)
    request.terminal = .plain(definitionID: definitionID)
    request.detachOtherClients = moving ? true : nil
    request.keepsMinimumLifetime = keepsMinimumLifetime
    return request
  } // End of func request(id:createdAt:host:tmuxPathOverride:moving:keepsMinimumLifetime:)

  /// The guard's four values of `LaunchTestSupport.request`, as a plain attach binds them.
  static let fourFields = BoundSessionIdentity(
    sessionID: TmuxSessionID("$3")!, serverPID: 4242, serverStartTime: 1_792_599_999,
    createdAt: 1_792_600_001)

  /// Writes `text` as the request file for `id`, as a raw file (0600), bypassing the encoder.
  static func writeRawRequest(_ text: String, id: LaunchToken, in store: LaunchStore) throws {
    let url = store.directory.appending(path: LaunchStore.requestFileName(for: id))
    try Data(text.utf8).write(to: url)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o600], ofItemAtPath: url.path(percentEncoded: false))
  }

  /// `request`'s JSON with its `terminal` field removed, as a muxFinder before Phase I-12b2
  /// wrote it.
  static func jsonWithoutTerminal(_ request: LaunchRequest) throws -> String {
    let data = try LaunchCoding.encoder().encode(request)
    let text = String(decoding: data, as: UTF8.self)
    let field = #","terminal":"\#(request.terminal.rawValue)""#
    precondition(text.contains(field))
    return text.replacingOccurrences(of: field, with: "")
  }
} // End of enum PlainLaunchTestSupport
