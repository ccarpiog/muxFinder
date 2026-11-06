import Foundation
import os

/// An app inspector for tests and previews (PLAN.md D38, Phase I-12b3): it answers a snapshot
/// and a permission status set by the test (for every app, or per bundle identifier since Phase
/// I-12d1), records every read, and never asks LaunchServices, `NSRunningApplication` or the
/// Automation permission.
public final class FakeTerminalAppInspector: TerminalAppInspecting {
  /// Mutable state.
  private struct State {
    /// The snapshot answered for every bundle identifier.
    var snapshot: TerminalAppSnapshot
    /// The permission status answered for every bundle identifier.
    var status: Int32
    /// Snapshots answered for one bundle identifier (lowercased) instead of `snapshot`.
    var snapshots: [String: TerminalAppSnapshot] = [:]
    /// Statuses answered for one bundle identifier (lowercased) instead of `status`.
    var statuses: [String: Int32] = [:]
    /// The bundle identifiers whose snapshot was read, in order.
    var snapshotReads: [String] = []
    /// The bundle identifiers whose permission was read, in order.
    var permissionReads: [String] = []
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// An inspector answering `snapshot` and `status` (by default `granted`).
  public init(
    snapshot: TerminalAppSnapshot,
    status: Int32 = AutomationPermission.grantedStatus
  ) {
    state = OSAllocatedUnfairLock(initialState: State(snapshot: snapshot, status: status))
  }

  /// Changes the snapshot later reads answer.
  public func setSnapshot(_ snapshot: TerminalAppSnapshot) {
    state.withLock { $0.snapshot = snapshot }
  }

  /// Changes the permission status later reads answer.
  public func setStatus(_ status: Int32) {
    state.withLock { $0.status = status }
  }

  /// Makes later snapshot reads of `bundleIdentifier` (compared without regard to case) answer
  /// `snapshot`, whatever the others answer.
  public func setSnapshot(_ snapshot: TerminalAppSnapshot, for bundleIdentifier: String) {
    state.withLock { $0.snapshots[bundleIdentifier.lowercased()] = snapshot }
  }

  /// Makes later permission reads of `bundleIdentifier` (compared without regard to case)
  /// answer `status`, whatever the others answer.
  public func setStatus(_ status: Int32, for bundleIdentifier: String) {
    state.withLock { $0.statuses[bundleIdentifier.lowercased()] = status }
  }

  /// The snapshot, recording the read.
  public func snapshot(bundleIdentifier: String) -> TerminalAppSnapshot {
    state.withLock { state in
      state.snapshotReads.append(bundleIdentifier)
      return state.snapshots[bundleIdentifier.lowercased()] ?? state.snapshot
    }
  }

  /// The status, recording the read.
  public func automationStatus(bundleIdentifier: String) -> Int32 {
    state.withLock { state in
      state.permissionReads.append(bundleIdentifier)
      return state.statuses[bundleIdentifier.lowercased()] ?? state.status
    }
  }

  /// The bundle identifiers whose snapshot was read, in order.
  public var snapshotReads: [String] { state.withLock { $0.snapshotReads } }

  /// The bundle identifiers whose permission was read, in order.
  public var permissionReads: [String] { state.withLock { $0.permissionReads } }
} // End of class FakeTerminalAppInspector

/// A spawner for tests and previews: it starts nothing, records every request, and answers a
/// made-up process id or the failure set by the test.
public final class FakeTerminalProcessSpawner: TerminalProcessSpawning {
  /// Mutable state.
  private struct State {
    /// Every request, in order.
    var requests: [TerminalSpawnRequest] = []
    /// When set, every spawn fails with it (still recorded).
    var failure: ProcessRunnerError?
  }

  /// The first process id answered; later ones count up from it.
  public static let firstProcessID: Int32 = 90_001

  /// The state.
  private let state = OSAllocatedUnfairLock(initialState: State())

  /// A spawner that succeeds.
  public init() {}

  /// Makes every later spawn fail with `failure` (`nil`: succeed again).
  public func setFailure(_ failure: ProcessRunnerError?) {
    state.withLock { $0.failure = failure }
  }

  /// Records `request` and answers the next made-up process id, or the failure.
  public func spawn(_ request: TerminalSpawnRequest) throws(ProcessRunnerError) -> Int32 {
    let outcome = state.withLock { state -> Result<Int32, ProcessRunnerError> in
      state.requests.append(request)
      if let failure = state.failure { return .failure(failure) }
      return .success(Self.firstProcessID + Int32(state.requests.count - 1))
    }
    return try outcome.get()
  }

  /// Every request, in order.
  public var requests: [TerminalSpawnRequest] { state.withLock { $0.requests } }
} // End of class FakeTerminalProcessSpawner

/// An activator for tests and previews: it brings nothing forward, records every bundle
/// identifier asked for, and answers the activation set by the test.
@MainActor
public final class FakeTerminalAppActivator: TerminalAppActivating {
  /// The bundle identifiers asked for, in order.
  public private(set) var requests: [String] = []
  /// What every call answers.
  public var answer: TerminalAppActivation

  /// An activator answering `answer` (by default `activated`).
  public init(answer: TerminalAppActivation = .activated) {
    self.answer = answer
  }

  /// Records the request and answers `answer`.
  public func activate(bundleIdentifier: String) -> TerminalAppActivation {
    requests.append(bundleIdentifier)
    return answer
  }
} // End of class FakeTerminalAppActivator
