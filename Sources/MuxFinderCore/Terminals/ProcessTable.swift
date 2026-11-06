import AppKit
import Darwin
import Foundation

/// One process as the process table shows it (PLAN.md D38, Phase I-12c2): what tracing a local
/// tmux client to its terminal app needs, read by pid and nothing else.
public struct ProcessTableEntry: Sendable, Hashable {
  /// The process id.
  public var pid: Int32
  /// Its parent's process id (0 for the kernel's own, 1 once reparented to launchd).
  public var parentPID: Int32
  /// When it started, by the kernel's clock.
  public var startTime: ProcessStartTime
  /// The device number of its controlling terminal; `nil` when it has none.
  public var controllingTerminal: Int32?
  /// Its executable's path, when readable.
  public var executablePath: String?
  /// The bundle identifier of the app it is, when it is an app registered with the window
  /// server (`NSRunningApplication`); `nil` for every other process.
  public var bundleIdentifier: String?

  /// An entry of these values.
  public init(
    pid: Int32,
    parentPID: Int32,
    startTime: ProcessStartTime,
    controllingTerminal: Int32? = nil,
    executablePath: String? = nil,
    bundleIdentifier: String? = nil
  ) {
    self.pid = pid
    self.parentPID = parentPID
    self.startTime = startTime
    self.controllingTerminal = controllingTerminal
    self.executablePath = executablePath
    self.bundleIdentifier = bundleIdentifier
  } // End of init(pid:parentPID:startTime:controllingTerminal:executablePath:bundleIdentifier:)
} // End of struct ProcessTableEntry

/// What a lookup of one pid found.
public enum ProcessTableLookup: Sendable, Hashable {
  /// The process runs.
  case found(ProcessTableEntry)
  /// No process has the pid (it ended, or it changed while it was read).
  case gone
  /// The table could not be read for the pid.
  case unreadable
}

/// The process table, read-only, by pid (PLAN.md D38, Phase I-12c2). Nothing is signalled,
/// launched or sent an Apple event. A seam: the app and the probe use `SystemProcessTable`,
/// tests a `FakeProcessTable`.
public protocol ProcessTableReading: Sendable {
  /// The process `pid`, if it runs.
  func process(_ pid: Int32) -> ProcessTableLookup
  /// The device number of the terminal at `path` (`stat`'s `st_rdev`), when `path` names a
  /// character device; `nil` otherwise.
  func terminalDevice(atPath path: String) -> Int32?
}

/// The real process table: `sysctl` with `KERN_PROC_PID` (parent, kernel start time,
/// controlling terminal), `proc_pidpath` (executable path) and
/// `NSRunningApplication(processIdentifier:)` (bundle identifier of a registered app), then
/// `sysctl` again, so a pid reused while it was read is `gone`, never another process's
/// entry. It only reads: no signal, no launch, no Apple event.
public struct SystemProcessTable: ProcessTableReading {
  /// A table reader.
  public init() {}

  /// The kernel's part of one entry.
  struct KernelEntry: Hashable {
    /// The parent's pid.
    var parentPID: Int32
    /// The start time.
    var startTime: ProcessStartTime
    /// The controlling terminal's device, `nil` for none.
    var controllingTerminal: Int32?
  }

  /// What `kernelEntry(_:)` found.
  enum KernelLookup: Hashable {
    /// The process runs.
    case found(KernelEntry)
    /// No process has the pid.
    case gone
    /// `sysctl` failed, or answered something unusable.
    case unreadable
  }

  /// Reads `pid` from the kernel, its executable path and its bundle identifier, then the
  /// kernel again: an entry that changed meanwhile (the pid reused) is `gone`.
  public func process(_ pid: Int32) -> ProcessTableLookup {
    guard pid > 0 else { return .gone }
    let first: KernelEntry
    switch Self.kernelEntry(pid) {
    case .gone: return .gone
    case .unreadable: return .unreadable
    case .found(let entry): first = entry
    }
    let path = Self.executablePath(pid)
    let bundleIdentifier = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    guard Self.kernelEntry(pid) == .found(first) else { return .gone }
    return .found(
      ProcessTableEntry(
        pid: pid, parentPID: first.parentPID, startTime: first.startTime,
        controllingTerminal: first.controllingTerminal, executablePath: path,
        bundleIdentifier: bundleIdentifier))
  } // End of func process(_:)

  /// `stat`'s `st_rdev` for a character device at `path`.
  public func terminalDevice(atPath path: String) -> Int32? {
    var info = stat()
    guard stat(path, &info) == 0, info.st_mode & S_IFMT == S_IFCHR else { return nil }
    return info.st_rdev
  }

  /// `sysctl` `CTL_KERN`, `KERN_PROC`, `KERN_PROC_PID`: the parent, the start time and the
  /// controlling terminal (`NODEV` is none). A pid no process has answers no data.
  static func kernelEntry(_ pid: Int32) -> KernelLookup {
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return .unreadable }
    if size == 0 { return .gone }
    guard size == MemoryLayout<kinfo_proc>.stride, info.kp_proc.p_pid == pid else {
      return .unreadable
    }
    let started = info.kp_proc.p_un.__p_starttime
    let startTime = ProcessStartTime(
      seconds: Int64(started.tv_sec), microseconds: Int32(truncatingIfNeeded: started.tv_usec))
    guard startTime.isValid, info.kp_eproc.e_ppid >= 0 else { return .unreadable }
    let device = info.kp_eproc.e_tdev
    return .found(
      KernelEntry(
        parentPID: info.kp_eproc.e_ppid, startTime: startTime,
        controllingTerminal: device == Self.noDevice ? nil : device))
  } // End of static func kernelEntry(_:)

  /// `NODEV`: no device.
  static let noDevice: Int32 = -1

  /// `proc_pidpath`, or `nil` when it fails.
  static func executablePath(_ pid: Int32) -> String? {
    var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
    let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
    guard length > 0 else { return nil }
    let bytes = buffer.prefix(Int(length)).map { UInt8(bitPattern: $0) }
    return String(decoding: bytes, as: UTF8.self)
  }
} // End of struct SystemProcessTable
