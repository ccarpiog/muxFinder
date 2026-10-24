import Darwin
import Foundation
import MuxFinderCore
import os

/// The launch store of `e2e-bury`: the real store, except that while `suppressesDisinter` is
/// on, every request it writes asks the helper to write no `Disinter`
/// (`LaunchRequest.testSuppressDisinter`, honored only in test mode, which the run's setup
/// turns on), for spike step (b).
final class BuryRequestStore: LaunchRequestStore {
  /// The real store.
  let base: LaunchStore
  /// Whether requests written now suppress `Disinter`.
  private let suppresses = OSAllocatedUnfairLock(initialState: false)

  /// Wraps `base`; requests are written unchanged until `setSuppressesDisinter(true)`.
  init(base: LaunchStore) {
    self.base = base
  }

  /// Turns the switch on or off for the requests written from now on.
  func setSuppressesDisinter(_ on: Bool) {
    suppresses.withLock { $0 = on }
  }

  /// Writes `request` through the real store, with `testSuppressDisinter` while the switch is
  /// on.
  func writeRequest(_ request: LaunchRequest) throws(LaunchStoreError) {
    var written = request
    if suppresses.withLock({ $0 }) { written.testSuppressDisinter = true }
    try base.writeRequest(written)
  }

  /// The real store's `discardRequest(_:)`.
  @discardableResult
  func discardRequest(_ id: LaunchToken) throws(LaunchStoreError) -> Bool {
    try base.discardRequest(id)
  }

  /// The real store's `takeResult(_:)`.
  func takeResult(_ id: LaunchToken) throws(LaunchStoreError) -> LaunchResult? {
    try base.takeResult(id)
  }

  /// The real store's `sweep()`.
  @discardableResult
  func sweep() throws(LaunchStoreError) -> Int {
    try base.sweep()
  }
} // End of class BuryRequestStore

/// Where iTerm2 lists a launch tab's session at one moment.
enum GatewayPlace: String, Sendable {
  /// In a tab of a window.
  case inTab = "in a tab"
  /// In `buried_sessions`.
  case buried
  /// Not listed at all.
  case absent = "gone"

  /// Where `sessions` lists `gateway`.
  init(of gateway: String, in sessions: ITerm2API.ListSessionsResponse) {
    if sessions.placement(ofSession: gateway) != nil {
      self = .inTab
    } else if sessions.buriedSessions.contains(where: { $0.uniqueIdentifier == gateway }) {
      self = .buried
    } else {
      self = .absent
    }
  } // End of init(of:in:)
} // End of enum GatewayPlace

/// One look at a launch tab's session: when the `ListSessions` request went out, when its
/// answer came back (wall clock, like the helper's digest), and where the session was.
struct GatewaySample: Sendable {
  /// When the request was sent.
  let sentAt: Date
  /// When the answer arrived.
  let receivedAt: Date
  /// Where iTerm2 listed the session.
  let place: GatewayPlace
}

/// Looks at one launch tab's session every `interval` from a task of its own until stopped or
/// `limit` passes, so a step can tell when it moved (spike (c): did the helper's status report
/// answer come only after the restore?).
struct GatewaySampler {
  /// The sampling task; its value is every sample, oldest first.
  private let task: Task<[GatewaySample], Never>

  /// Starts sampling `gateway` through `client`.
  init(
    _ gateway: String,
    client: ITerm2APIClient,
    every interval: Duration = .milliseconds(100),
    limit: Duration = .seconds(40)
  ) {
    task = Task {
      var samples: [GatewaySample] = []
      let deadline = ContinuousClock.now + limit
      while !Task.isCancelled, ContinuousClock.now < deadline {
        let sentAt = Date()
        if let sessions = try? await client.listSessions() {
          samples.append(
            GatewaySample(
              sentAt: sentAt, receivedAt: Date(), place: GatewayPlace(of: gateway, in: sessions)))
        }
        do {
          try await Task.sleep(for: interval)
        } catch {
          break
        }
      } // End of loop over the samples
      return samples
    }
  } // End of init(_:client:every:limit:)

  /// Stops sampling and returns the samples.
  func stop() async -> [GatewaySample] {
    task.cancel()
    return await task.value
  }
} // End of struct GatewaySampler

/// What `e2e-bury` reads about a process of the helper's before signaling it: through
/// `libproc`, never by name, so only the exact process the helper recorded is ever touched.
enum ProcessCheck {
  /// The parent of `processID`, or `nil` when it does not exist (or cannot be read).
  static func parent(of processID: pid_t) -> pid_t? {
    var info = proc_bsdinfo()
    let size = Int32(MemoryLayout<proc_bsdinfo>.size)
    guard proc_pidinfo(processID, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
    return pid_t(info.pbi_ppid)
  }

  /// The executable `processID` runs, as the kernel reports it (symbolic links resolved), or
  /// `nil`.
  static func executablePath(of processID: pid_t) -> String? {
    var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
    guard proc_pidpath(processID, &buffer, UInt32(buffer.count)) > 0 else { return nil }
    return String(decoding: buffer.prefix { $0 != 0 }, as: UTF8.self)
  }

  /// Whether a process `processID` exists (one of the user's, as every process here is).
  static func isAlive(_ processID: pid_t) -> Bool {
    guard processID > 1 else { return false }
    return kill(processID, 0) == 0 || errno == EPERM
  }

  /// `path` with every symbolic link resolved, as `executablePath(of:)` reports it.
  static func resolved(_ path: String) -> String {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path(percentEncoded: false)
  }
} // End of enum ProcessCheck

/// Whether ssh shares connections for a destination (`ControlMaster`, `ControlPath`), read from
/// `ssh -G` (OpenSSH's evaluated configuration; no connection is made). Spike step (e) kills
/// the helper's local ssh child only when it cannot be, or use, a shared master connection, so
/// that nothing but this run's own connection ends. The values themselves are never printed.
enum SSHConnectionSharing {
  /// What `ssh -G` showed.
  enum Verdict: Sendable, Equatable {
    /// `controlmaster` is `false` and no `controlpath` is set: every ssh is a connection of its
    /// own.
    case off
    /// Connection sharing may apply.
    case on
    /// `ssh -G` failed or printed neither key.
    case unknown
  }

  /// Runs `/usr/bin/ssh -G -- <destination>` (5 s deadline) and reads the two keys.
  static func check(destination: String) async -> Verdict {
    let request = ProcessRequest(
      executableURL: DiscoveryProbe.sshURL, arguments: ["-G", "--", destination],
      environment: DiscoveryProbe.localEnvironment(base: ProcessInfo.processInfo.environment),
      timeout: .seconds(5))
    guard let result = try? await PosixSpawnProcessRunner().run(request), result.exitCode == 0,
      !result.timedOut
    else { return .unknown }
    return verdict(fromConfiguration: String(decoding: result.standardOutput, as: UTF8.self))
  } // End of static func check(destination:)

  /// The verdict for `ssh -G` output: one `key value` line per option, keys in lowercase.
  static func verdict(fromConfiguration text: String) -> Verdict {
    var master: String?
    var path: String?
    for line in text.split(separator: "\n") {
      let parts = line.split(separator: " ", maxSplits: 1).map { String($0) }
      guard parts.count == 2 else { continue }
      switch parts[0].lowercased() {
      case "controlmaster": master = parts[1].lowercased()
      case "controlpath": path = parts[1]
      default: continue
      }
    } // End of loop over the configuration lines
    guard let master else { return .unknown }
    let pathUnset = path == nil || path?.lowercased() == "none"
    return ["false", "no"].contains(master) && pathUnset ? .off : .on
  } // End of static func verdict(fromConfiguration:)
} // End of enum SSHConnectionSharing

/// Whole milliseconds from `start` to `end` (negative when `end` is earlier).
func milliseconds(from start: Date, to end: Date) -> Int {
  Int((end.timeIntervalSince(start) * 1000).rounded())
}
