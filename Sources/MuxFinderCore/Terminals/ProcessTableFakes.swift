import Foundation
import os

/// A process table for tests and previews (PLAN.md D38, Phase I-12c2): the processes and
/// terminal devices the test sets, nothing read from the system. Records every pid looked up,
/// in order, so a test can check how often (and whether) the table was read.
public final class FakeProcessTable: ProcessTableReading, Sendable {
  /// Mutable state.
  private struct State {
    /// What a lookup of each pid answers; a pid not here is `gone`.
    var processes: [Int32: ProcessTableLookup]
    /// The device of each terminal path; a path not here is no character device.
    var terminals: [String: Int32]
    /// Every pid looked up, in order.
    var lookups: [Int32] = []
  }

  /// The state.
  private let state: OSAllocatedUnfairLock<State>

  /// A table holding `processes` (each found) and the terminal devices `terminals`.
  public init(_ processes: [ProcessTableEntry] = [], terminals: [String: Int32] = [:]) {
    var table: [Int32: ProcessTableLookup] = [:]
    for entry in processes { table[entry.pid] = .found(entry) }
    state = OSAllocatedUnfairLock(initialState: State(processes: table, terminals: terminals))
  }

  /// Makes a lookup of `pid` answer `lookup` from now on.
  public func set(_ pid: Int32, _ lookup: ProcessTableLookup) {
    state.withLock { $0.processes[pid] = lookup }
  }

  /// Adds (or replaces) `entry`.
  public func add(_ entry: ProcessTableEntry) {
    set(entry.pid, .found(entry))
  }

  /// Every pid looked up so far, in order.
  public var lookups: [Int32] { state.withLock { $0.lookups } }

  /// Records the lookup and answers what was set (`gone` for an unknown pid).
  public func process(_ pid: Int32) -> ProcessTableLookup {
    state.withLock { state in
      state.lookups.append(pid)
      return state.processes[pid] ?? .gone
    }
  }

  /// The device set for `path`, if any.
  public func terminalDevice(atPath path: String) -> Int32? {
    state.withLock { $0.terminals[path] }
  }
} // End of class FakeProcessTable
