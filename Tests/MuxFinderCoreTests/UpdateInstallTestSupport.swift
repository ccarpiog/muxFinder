import Darwin
import Foundation
import os

@testable import MuxFinderCore

/// Shared fixtures of the install pipeline's tests (PLAN.md D39, Phase I-13b2). Everything
/// runs in private folders under `/private/tmp` (`UpdateTestSupport.makePrivateFolder()`):
/// stub bundles stand in for the installed app, the update folder is injected, the relauncher's
/// opener is a harmless stand-in script (never `/usr/bin/open`), the waited pid is a `sleep`
/// child of the test, and signatures are ad hoc only.
enum UpdateInstallTestSupport {
  /// The stand-in opener: appends its first argument as a line to `<its own path>.opened`.
  /// Static text, no runtime value in it.
  static let standInOpenerScript = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> \"$0.opened\"\n"

  /// A stub "installed" app at `<folder>/Applications/muxFinder.app` (version `short`, build
  /// `build`), like I-13b1's stubs: `Contents/Info.plist`, `Contents/MacOS/muxFinder` (a copy
  /// of `/usr/bin/true`) and one resource.
  static func makeInstalledApp(
    in folder: URL, short: String = "0.2.0", build: String = "2"
  ) throws -> URL {
    let applications = folder.appending(path: "Applications", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: applications, withIntermediateDirectories: true)
    let app = applications.appending(path: "muxFinder.app", directoryHint: .isDirectory)
    try UpdateVerifyTestSupport.makeApp(
      at: app, info: UpdateVerifyTestSupport.infoPlist(short: short, build: build))
    return app
  } // End of static func makeInstalledApp(in:short:build:)

  /// The absolute path of `url` without a trailing slash.
  static func path(_ url: URL) -> String {
    PrivateStorage.path(of: url)
  }

  /// The stub app's main executable path.
  static func executablePath(of app: URL) -> String {
    path(app) + "/Contents/MacOS/muxFinder"
  }

  /// Writes the stand-in opener into `folder` (0700) and returns its path.
  static func makeStandInOpener(in folder: URL) throws -> String {
    let opener = folder.appending(path: "stand-in-opener")
    try Data(standInOpenerScript.utf8).write(to: opener)
    guard chmod(path(opener), 0o700) == 0 else { throw POSIXError(.EIO) }
    return path(opener)
  }

  /// The lines the stand-in opener at `opener` has written (empty when it never ran).
  static func openedLines(_ opener: String) -> [String] {
    guard let text = try? String(contentsOfFile: opener + ".opened", encoding: .utf8) else {
      return []
    }
    return text.split(separator: "\n").map(String.init)
  }

  /// Starts `/bin/sleep <seconds>` as a child of the test (Foundation reaps it).
  static func startSleep(_ seconds: Int = 60) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sleep")
    process.arguments = [String(seconds)]
    try process.run()
    return process
  }

  /// Ends `process` (SIGTERM) and waits until it has been reaped.
  static func stop(_ process: Process) {
    if process.isRunning { process.terminate() }
    process.waitUntilExit()
  }

  /// Waits (real time, at most `limit`) for the child `pid` to exit and reaps it; its exit
  /// status, or `nil` when it was still running (then it is killed and reaped).
  static func waitForExit(_ pid: Int32, within limit: Duration = .seconds(10)) async -> Int32? {
    let deadline = ContinuousClock.now + limit
    var status: Int32 = 0
    while ContinuousClock.now < deadline {
      let reaped = waitpid(pid, &status, WNOHANG)
      if reaped == pid {
        return (status & 0x7f) == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)
      }
      if reaped < 0 { return nil }
      try? await Task.sleep(for: .milliseconds(50))
    } // End of loop waiting for the child
    kill(pid, SIGKILL)
    _ = waitpid(pid, &status, 0)
    return nil
  } // End of static func waitForExit(_:within:)

  /// Whether the child `pid` is still running (not reaped here).
  static func isRunning(_ pid: Int32) -> Bool {
    var info = siginfo_t()
    return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == 0
  }

  /// `/bin/sleep` copied into `folder` as `name` and signed ad hoc (a copy of a platform binary
  /// run from elsewhere is killed; an ad hoc copy runs), then started with `seconds`.
  static func startCopiedSleep(in folder: URL, name: String, seconds: Int = 60) async throws
    -> Process
  {
    let copy = folder.appending(path: name)
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/sleep"), to: copy)
    try await UpdateVerifyTestSupport.run("/usr/bin/codesign", ["-s", "-", "--force", path(copy)])
    let process = Process()
    process.executableURL = copy
    process.arguments = [String(seconds)]
    try process.run()
    return process
  } // End of static func startCopiedSleep(in:name:seconds:)

  /// The eligible install of the stub app at `app`, signed (as the tests pretend) by
  /// `UpdateVerifyTestSupport.team`.
  static func eligibleInstall(_ app: URL, build: String = "2") throws -> UpdateEligibleInstall {
    UpdateEligibleInstall(
      team: UpdateVerifyTestSupport.team, bundlePath: path(app),
      identity: try UpdateVerifyTestSupport.identity(of: app), runningBuild: build,
      runningVersion: UpdateVersion("0.2.0"))
  }

  /// The `CFBundleVersion` of the app at `app`.
  static func build(of app: URL) -> String? {
    let info = NSDictionary(contentsOf: app.appending(path: "Contents/Info.plist"))
    return info?["CFBundleVersion"] as? String
  }

  /// Runs `cleanup`, then again (50 ms apart, for at most `limit`) while it keeps more run
  /// folders as locked than `locked`, those a live update of the test holds; returns every
  /// report. A run lock released in this process can look held for a moment: a process
  /// another test is spawning keeps a copy of every open file, close-on-exec ones included,
  /// until its new image starts.
  static func settledCleanup(
    locked: Int = 0, within limit: Duration = .seconds(10),
    _ cleanup: () -> UpdateCleanupReport
  ) async -> [UpdateCleanupReport] {
    var reports = [cleanup()]
    let deadline = ContinuousClock.now + limit
    while let last = reports.last, last.keptLocked > locked, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(50))
      reports.append(cleanup())
    } // End of loop over the cleanups
    return reports
  } // End of static func settledCleanup(locked:within:_:)
}

/// Eligibility as the tests set it: the real facts reader over a stub bundle, with the
/// signature reading given (a stub cannot carry a Developer ID signature).
struct StubUpdateEligibility: UpdateEligibilityChecking {
  /// The stub app's path.
  let bundlePath: String
  /// Its main executable, standing in for the running one.
  let executablePath: String
  /// The signature reading.
  let signing: UpdateSigningReading
  /// The update folder.
  let root: UpdateStagingRoot

  /// See `UpdateEligibilityChecking`.
  func check() -> UpdateEligibility {
    UpdateEligibility.decide(
      UpdateEligibilityReader.facts(
        bundlePath: bundlePath, executablePath: executablePath, signing: signing, root: root))
  }
}

/// An exchanger that wraps the real one: each call can fail with an errno instead, do nothing
/// and report success, or run a hook before or after the real exchange.
final class ScriptedExchanger: UpdateBundleExchanging, Sendable {
  /// What one call does.
  enum Step: Sendable {
    /// The real exchange.
    case real
    /// Fails with this errno without exchanging.
    case fail(Int32)
    /// Reports success without exchanging.
    case pretend
    /// Runs the hook, then the real exchange.
    case before(@Sendable () -> Void)
    /// The real exchange, then the hook.
    case after(@Sendable () -> Void)
  }

  /// The steps still to run; calls past the end run the real exchange.
  private let steps: OSAllocatedUnfairLock<[Step]>
  /// The calls seen, as pairs of paths.
  private let seen = OSAllocatedUnfairLock<[[String]]>(initialState: [])

  /// An exchanger running `steps` in order.
  init(_ steps: [Step]) {
    self.steps = OSAllocatedUnfairLock(initialState: steps)
  }

  /// See `UpdateBundleExchanging`.
  func exchange(_ first: String, _ second: String) -> Int32 {
    seen.withLock { $0.append([first, second]) }
    let step = steps.withLock { $0.isEmpty ? Step.real : $0.removeFirst() }
    let real = RenameSwapExchanger()
    switch step {
    case .real: return real.exchange(first, second)
    case .fail(let code): return code
    case .pretend: return 0
    case .before(let hook):
      hook()
      return real.exchange(first, second)
    case .after(let hook):
      let status = real.exchange(first, second)
      hook()
      return status
    }
  } // End of func exchange(_:_:)

  /// The calls seen.
  var calls: [[String]] { seen.withLock { $0 } }
}

/// A relauncher that records what it was asked and answers as told (no process starts).
final class RecordingRelauncher: UpdateRelaunching, Sendable {
  /// The answer.
  let answer: Result<Int32, UpdateRelaunchError>
  /// The calls seen.
  private let seen = OSAllocatedUnfairLock<[(Int32, String)]>(initialState: [])

  /// A relauncher answering `answer`.
  init(_ answer: Result<Int32, UpdateRelaunchError>) {
    self.answer = answer
  }

  /// See `UpdateRelaunching`.
  func relaunch(after processID: Int32, bundlePath: String) -> Result<Int32, UpdateRelaunchError> {
    seen.withLock { $0.append((processID, bundlePath)) }
    return answer
  }

  /// How many times it was asked.
  var count: Int { seen.withLock { $0.count } }
}

/// A process table answering from a script, like the kernel would (PLAN.md D39, I-13b2's
/// process scan): a list call writes at most its capacity of `pids`, in order; each pid's path,
/// `kill(pid, 0)` and state answer as given (by default a path `/fake/<pid>`, 0 and alive). It
/// records the capacities asked.
final class ScriptedUpdateProcessTable: UpdateProcessTableReading, Sendable {
  /// The pids, in list order.
  let pids: [pid_t]
  /// The kernel's estimate of the pid count.
  let estimate: UpdateProcessCall<Int>
  /// The errno every list call fails with, if any.
  let listErrno: Int32?
  /// Each pid's path answer.
  let paths: [pid_t: UpdateProcessCall<String>]
  /// Each pid's `kill(pid, 0)` answer.
  let signals: [pid_t: Int32]
  /// Each pid's state.
  let states: [pid_t: UpdateProcessState]
  /// The capacities asked, in order.
  private let asked = OSAllocatedUnfairLock<[Int]>(initialState: [])

  /// A table of `pids` (see the type).
  init(
    pids: [pid_t], estimate: UpdateProcessCall<Int>? = nil, listErrno: Int32? = nil,
    paths: [pid_t: UpdateProcessCall<String>] = [:], signals: [pid_t: Int32] = [:],
    states: [pid_t: UpdateProcessState] = [:]
  ) {
    self.pids = pids
    self.estimate = estimate ?? .value(pids.count)
    self.listErrno = listErrno
    self.paths = paths
    self.signals = signals
    self.states = states
  } // End of init(pids:estimate:listErrno:paths:signals:states:)

  /// See `UpdateProcessTableReading`.
  func estimatedProcessCount() -> UpdateProcessCall<Int> { estimate }

  /// See `UpdateProcessTableReading`.
  func processIDs(capacity: Int) -> UpdateProcessCall<[pid_t]> {
    asked.withLock { $0.append(capacity) }
    if let listErrno { return .failed(errno: listErrno) }
    return .value(Array(pids.prefix(capacity)))
  }

  /// See `UpdateProcessTableReading`.
  func executablePath(of pid: pid_t) -> UpdateProcessCall<String> {
    paths[pid] ?? .value("/fake/\(pid)")
  }

  /// See `UpdateProcessTableReading`.
  func signalCheck(_ pid: pid_t) -> Int32 { signals[pid] ?? 0 }

  /// See `UpdateProcessTableReading`.
  func state(of pid: pid_t) -> UpdateProcessState { states[pid] ?? .alive }

  /// The capacities the list calls were given.
  var capacities: [Int] { asked.withLock { $0 } }
}

/// A process listing that always answers `answer` and counts its scans.
final class FixedProcessListing: UpdateProcessListing, Sendable {
  /// The answer.
  let answer: UpdateProcessScan
  /// The scans made.
  private let count = OSAllocatedUnfairLock(initialState: 0)

  /// A listing answering `answer`.
  init(_ answer: UpdateProcessScan) {
    self.answer = answer
  }

  /// See `UpdateProcessListing`.
  func scan() -> UpdateProcessScan {
    count.withLock { $0 += 1 }
    return answer
  }

  /// How many scans were made.
  var scans: Int { count.withLock { $0 } }
}

/// The review's interleaving for the leftover cleanup (PLAN.md D39, I-13b2): a live update
/// holds a run folder's lock while the app and its helpers run from the installed path. A scan
/// made while it still runs sees nothing inside the run folder, and right after that scan the
/// update swaps the old bundle into the run folder (a buried helper now runs from there) and
/// releases its lock (`finishUpdate`). Every later scan sees that helper.
final class RacingUpdateScanner: UpdateProcessListing, Sendable {
  /// The buried helper's executable inside the run folder, once the update has swapped.
  let helperPath: String
  /// Ends the update: releases the run folder's lock.
  let finishUpdate: @Sendable () -> Void
  /// Whether the update has finished.
  private let finished = OSAllocatedUnfairLock(initialState: false)
  /// The scans made.
  private let count = OSAllocatedUnfairLock(initialState: 0)

  /// A scanner for the run folder whose helper is `helperPath`.
  init(helperPath: String, finishUpdate: @escaping @Sendable () -> Void) {
    self.helperPath = helperPath
    self.finishUpdate = finishUpdate
  }

  /// See `UpdateProcessListing`.
  func scan() -> UpdateProcessScan {
    count.withLock { $0 += 1 }
    if finishIfRunning() { return .complete(["/usr/bin/true"]) }
    return .complete(["/usr/bin/true", helperPath])
  }

  /// Finishes the update if it still runs; returns whether it did.
  @discardableResult
  func finishIfRunning() -> Bool {
    let wasRunning = finished.withLock { done -> Bool in
      let running = !done
      done = true
      return running
    }
    if wasRunning { finishUpdate() }
    return wasRunning
  }

  /// How many scans were made.
  var scans: Int { count.withLock { $0 } }
}
