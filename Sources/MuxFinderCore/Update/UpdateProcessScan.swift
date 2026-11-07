import Darwin
import Foundation

/// Why a scan of the running processes cannot vouch for every process (PLAN.md D39, I-13b2):
/// the leftover cleanup then keeps every run folder it was judging.
public enum UpdateProcessScanProblem: Sendable, Hashable {
  /// The pid list could not be read: `proc_listpids` failed with this errno, or answered no
  /// pid at all (errno 0; this process runs, so a complete list is never empty).
  case listFailed(errno: Int32)
  /// The pid list filled every buffer it was given, up to the last attempt: it may be
  /// truncated.
  case listTruncated
  /// A process that still runs has an executable whose path could not be read
  /// (`proc_pidpath` failed with this errno).
  case pathUnreadable(errno: Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .listFailed(let code): return "listFailed.\(code)"
    case .listTruncated: return "listTruncated"
    case .pathUnreadable(let code): return "pathUnreadable.\(code)"
    }
  }
}

/// What one scan of the running processes found (PLAN.md D39, I-13b2).
public enum UpdateProcessScan: Sendable, Hashable {
  /// Every listed process was accounted for: the executable paths of those that run from a
  /// file that has a path, as the kernel reports them (`proc_pidpath`).
  case complete([String])
  /// The scan cannot vouch for every process.
  case incomplete(UpdateProcessScanProblem)
}

/// Scans the running processes' executables (PLAN.md D39, I-13b2); a seam for the leftover
/// cleanup.
public protocol UpdateProcessListing: Sendable {
  /// Scans now, saying whether the scan is complete.
  func scan() -> UpdateProcessScan
}

/// One kernel call's answer: a value, or the errno it failed with.
enum UpdateProcessCall<Value: Sendable & Hashable>: Sendable, Hashable {
  /// The call succeeded.
  case value(Value)
  /// The call failed with this errno.
  case failed(errno: Int32)
}

/// A process's state as `sysctl` (`CTL_KERN`, `KERN_PROC`, `KERN_PROC_PID`) reports it.
enum UpdateProcessState: Sendable, Hashable {
  /// No process has the pid.
  case gone
  /// It ended and is not reaped yet: it has no address space and no executable.
  case zombie
  /// It is ending (`P_WEXIT`): it runs no more code of its own and the kernel releases its
  /// executable on the way (`proc_pidpath` then answers `ESRCH`).
  case exiting
  /// It runs.
  case alive
  /// `sysctl` failed or answered something unusable.
  case unreadable
}

/// The kernel calls a process scan makes (a seam, so tests can fail each one); the app uses
/// `SystemUpdateProcessTable`.
protocol UpdateProcessTableReading: Sendable {
  /// `proc_listpids(PROC_ALL_PIDS, 0, NULL, 0)`: the kernel's estimate of the number of pids.
  func estimatedProcessCount() -> UpdateProcessCall<Int>
  /// `proc_listpids(PROC_ALL_PIDS, …)` into a buffer of `capacity` pids: the pids written.
  func processIDs(capacity: Int) -> UpdateProcessCall<[pid_t]>
  /// `proc_pidpath`: the path of the executable `pid` runs.
  func executablePath(of pid: pid_t) -> UpdateProcessCall<String>
  /// `kill(pid, 0)`: 0, or the errno (`EPERM`: it exists, another user's; `ESRCH`: it ended).
  func signalCheck(_ pid: pid_t) -> Int32
  /// The process's state.
  func state(of pid: pid_t) -> UpdateProcessState
}

/// The real kernel calls.
struct SystemUpdateProcessTable: UpdateProcessTableReading {
  /// See `UpdateProcessTableReading`.
  func estimatedProcessCount() -> UpdateProcessCall<Int> {
    let bytes = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
    let code = errno
    guard bytes > 0 else { return .failed(errno: bytes < 0 ? code : 0) }
    return .value(Int(bytes) / MemoryLayout<pid_t>.stride)
  }

  /// See `UpdateProcessTableReading`.
  func processIDs(capacity: Int) -> UpdateProcessCall<[pid_t]> {
    let stride = MemoryLayout<pid_t>.stride
    guard capacity > 0, capacity <= Int(Int32.max) / stride else { return .failed(errno: EINVAL) }
    var pids = [pid_t](repeating: 0, count: capacity)
    let (bytes, code) = pids.withUnsafeMutableBytes { buffer -> (Int32, Int32) in
      let written = proc_listpids(
        UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(buffer.count))
      return (written, written < 0 ? errno : 0)
    }
    guard bytes >= 0 else { return .failed(errno: code) }
    return .value(Array(pids.prefix(min(Int(bytes) / stride, capacity))))
  } // End of func processIDs(capacity:)

  /// See `UpdateProcessTableReading`.
  func executablePath(of pid: pid_t) -> UpdateProcessCall<String> {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let (length, code) = buffer.withUnsafeMutableBufferPointer { pointer -> (Int32, Int32) in
      let written = proc_pidpath(pid, pointer.baseAddress, UInt32(pointer.count))
      return (written, written > 0 ? 0 : errno)
    }
    guard length > 0 else { return .failed(errno: code) }
    let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    return .value(String(decoding: bytes, as: UTF8.self))
  }

  /// See `UpdateProcessTableReading`.
  func signalCheck(_ pid: pid_t) -> Int32 {
    kill(pid, 0) == 0 ? 0 : errno
  }

  /// See `UpdateProcessTableReading`.
  func state(of pid: pid_t) -> UpdateProcessState {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return .unreadable }
    if size == 0 { return .gone }
    guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
      return .unreadable
    }
    if Int32(info.kp_proc.p_stat) == SZOMB { return .zombie }
    return info.kp_proc.p_flag & P_WEXIT != 0 ? .exiting : .alive
  } // End of func state(of:)
}

/// The real process scan (PLAN.md D39, I-13b2): every pid (`proc_listpids`, sized by the
/// kernel's estimate plus 64 and doubled while a list fills its whole buffer, at most four
/// attempts; still full, or failed, or empty, the scan is incomplete), then each pid's
/// executable (`proc_pidpath`). A pid whose path cannot be read is passed over only when it
/// cannot be running from any folder: it ended (`kill(pid, 0)` answers `ESRCH`, or `sysctl`
/// no longer lists it), it is a zombie (no address space or executable; `kill(pid, 0)` still
/// answers 0 for it) or exiting (`P_WEXIT`: it runs no more code, its executable released),
/// or it runs and `proc_pidpath` answered `ENOENT` (the kernel could not resolve the
/// executable's path: the file was deleted, so it lies in no folder; a moved folder is
/// followed, not `ENOENT`). Any other such pid that still exists (`kill` 0 or `EPERM`) makes
/// the scan incomplete.
public struct SystemUpdateProcessListing: UpdateProcessListing {
  /// How many times the pid list is read before it counts as truncated.
  static let maximumListAttempts = 4
  /// Room added to the kernel's estimate for processes started meanwhile.
  static let extraCapacity = 64

  /// The kernel calls.
  let table: any UpdateProcessTableReading

  /// A listing over the real kernel.
  public init() {
    self.init(table: SystemUpdateProcessTable())
  }

  /// A listing over `table` (tests inject one).
  init(table: any UpdateProcessTableReading) {
    self.table = table
  }

  /// See `UpdateProcessListing`.
  public func scan() -> UpdateProcessScan {
    var capacity: Int
    switch table.estimatedProcessCount() {
    case .failed(let code): return .incomplete(.listFailed(errno: code))
    case .value(let count): capacity = max(count, 0) + Self.extraCapacity
    }
    for _ in 0..<Self.maximumListAttempts {
      switch table.processIDs(capacity: capacity) {
      case .failed(let code):
        return .incomplete(.listFailed(errno: code))
      case .value(let pids) where pids.count >= capacity:
        capacity *= 2
      case .value(let pids):
        guard !pids.isEmpty else { return .incomplete(.listFailed(errno: 0)) }
        return executables(of: pids)
      }
    } // End of loop over the pid list's attempts
    return .incomplete(.listTruncated)
  } // End of func scan()

  /// The executables of `pids` (pid 0, the kernel, left out), or the first problem.
  func executables(of pids: [pid_t]) -> UpdateProcessScan {
    var paths: [String] = []
    for pid in pids where pid > 0 {
      switch table.executablePath(of: pid) {
      case .value(let path):
        paths.append(path)
      case .failed(let code):
        if let problem = unresolved(pid, pathErrno: code) { return .incomplete(problem) }
      }
    } // End of loop over the listed pids
    return .complete(paths)
  } // End of func executables(of:)

  /// For a pid whose executable path failed with `pathErrno`: `nil` when it cannot be running
  /// from any folder (see the type), else the problem that makes the scan incomplete.
  func unresolved(_ pid: pid_t, pathErrno: Int32) -> UpdateProcessScanProblem? {
    if table.signalCheck(pid) == ESRCH { return nil }
    switch table.state(of: pid) {
    case .gone, .zombie, .exiting: return nil
    case .alive where pathErrno == ENOENT: return nil
    case .alive, .unreadable: return .pathUnreadable(errno: pathErrno)
    }
  }
}
