import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The process scan behind the leftover cleanup (PLAN.md D39, I-13b2), over an injected process
/// table: a scan is complete only when every listed process is accounted for; a failed or
/// empty pid list, a list that keeps filling its buffer and a running process whose path
/// cannot be read make it incomplete; ended processes, zombies and executables that were
/// deleted are passed over. Then the real kernel: this process listed, a real zombie and a
/// real deleted executable passed over.
@Suite("Update process scan")
struct UpdateProcessScanTests {
  /// Shorthand.
  typealias Support = UpdateInstallTestSupport

  /// The scan over `table`.
  static func scan(_ table: ScriptedUpdateProcessTable) -> UpdateProcessScan {
    SystemUpdateProcessListing(table: table).scan()
  }

  /// Every path read: complete, in list order, the kernel's pid 0 left out; the list asked
  /// once with the estimate plus 64.
  @Test func aCompleteScan() {
    let table = ScriptedUpdateProcessTable(
      pids: [0, 1, 7, 42], paths: [42: .value("/private/tmp/x/Contents/MacOS/app")])
    #expect(
      Self.scan(table) == .complete(["/fake/1", "/fake/7", "/private/tmp/x/Contents/MacOS/app"]))
    #expect(table.capacities == [4 + SystemUpdateProcessListing.extraCapacity])
  }

  /// The pid list failing is never an empty, complete scan: the estimate failing, the list
  /// failing, and a list with no pid at all.
  @Test func listFailuresAreIncomplete() {
    #expect(
      Self.scan(ScriptedUpdateProcessTable(pids: [1], estimate: .failed(errno: EPERM)))
        == .incomplete(.listFailed(errno: EPERM)))
    #expect(
      Self.scan(ScriptedUpdateProcessTable(pids: [1], listErrno: ENOMEM))
        == .incomplete(.listFailed(errno: ENOMEM)))
    #expect(Self.scan(ScriptedUpdateProcessTable(pids: [])) == .incomplete(.listFailed(errno: 0)))
  }

  /// A list that fills its whole buffer is read again with twice the room until it fits; one
  /// that still fills it after the last attempt is truncated, never taken as complete.
  @Test func aFullListIsReadAgain() {
    let grown = ScriptedUpdateProcessTable(pids: Array(1...200), estimate: .value(10))
    guard case .complete(let paths) = Self.scan(grown) else {
      Issue.record("not complete")
      return
    }
    #expect(paths.count == 200)
    #expect(grown.capacities == [74, 148, 296])
    let full = ScriptedUpdateProcessTable(pids: Array(1...5000), estimate: .value(10))
    #expect(Self.scan(full) == .incomplete(.listTruncated))
    #expect(full.capacities == [74, 148, 296, 592])
    #expect(full.capacities.count == SystemUpdateProcessListing.maximumListAttempts)
    let exact = ScriptedUpdateProcessTable(pids: Array(1...74), estimate: .value(10))
    guard case .complete(let all) = Self.scan(exact) else {
      Issue.record("not complete")
      return
    }
    #expect(all.count == 74 && exact.capacities == [74, 148])
  } // End of func aFullListIsReadAgain()

  /// A pid whose path cannot be read: incomplete while it still exists and may run from a
  /// folder (`kill` answering 0 or `EPERM`, alive, or its state unreadable; any path errno but
  /// `ENOENT`, and `ENOENT` too when its state cannot be read); passed over when it ended
  /// (`kill` `ESRCH`, or `sysctl` no longer listing it), is a zombie or exiting, or runs an
  /// executable that was deleted (`ENOENT`, alive).
  @Test func unreadablePaths() {
    let pid: pid_t = 9
    /// The scan with pid 9's path failing with `pathErrno`, its `kill` and state as given.
    func scan(_ pathErrno: Int32, kill: Int32 = 0, state: UpdateProcessState = .alive)
      -> UpdateProcessScan
    {
      Self.scan(
        ScriptedUpdateProcessTable(
          pids: [1, pid, 12], paths: [pid: .failed(errno: pathErrno)], signals: [pid: kill],
          states: [pid: state]))
    }
    let passedOver = UpdateProcessScan.complete(["/fake/1", "/fake/12"])
    #expect(scan(EPERM) == .incomplete(.pathUnreadable(errno: EPERM)))
    #expect(scan(EPERM, kill: EPERM) == .incomplete(.pathUnreadable(errno: EPERM)))
    #expect(scan(ESRCH) == .incomplete(.pathUnreadable(errno: ESRCH)))
    #expect(scan(EACCES, state: .unreadable) == .incomplete(.pathUnreadable(errno: EACCES)))
    #expect(scan(ENOENT, state: .unreadable) == .incomplete(.pathUnreadable(errno: ENOENT)))
    #expect(scan(EPERM, kill: ESRCH) == passedOver)
    #expect(scan(ESRCH, kill: ESRCH, state: .unreadable) == passedOver)
    #expect(scan(ESRCH, state: .gone) == passedOver)
    #expect(scan(ESRCH, state: .zombie) == passedOver)
    #expect(scan(ESRCH, kill: EPERM, state: .zombie) == passedOver)
    #expect(scan(ESRCH, state: .exiting) == passedOver)
    #expect(scan(EPERM, kill: EPERM, state: .exiting) == passedOver)
    #expect(scan(ENOENT) == passedOver)
    #expect(UpdateProcessScanProblem.pathUnreadable(errno: EPERM).code == "pathUnreadable.1")
    #expect(UpdateProcessScanProblem.listTruncated.code == "listTruncated")
  } // End of func unreadablePaths()

  /// The script of the child whose executable is deleted (static text; the marker's path is
  /// its first argument): it writes the marker once it runs, then waits on its input.
  static let readyScript = "print -n ready > \"$1\"; read line"

  /// The real kernel: the scan is complete and lists this test process's executable; a real
  /// zombie child (spawned, ended, not reaped) and a real process whose executable was deleted
  /// (an ad hoc copy of `/bin/zsh` in a private folder, deleted once it runs `readyScript`)
  /// leave it complete, the deleted one not listed.
  @Test func theRealScan() async throws {
    let own = SystemUpdateProcessTable().executablePath(of: getpid())
    guard case .value(let ownPath) = own,
      case .complete(let paths) = SystemUpdateProcessListing().scan()
    else {
      Issue.record("the real scan is not complete")
      return
    }
    #expect(paths.contains(ownPath))
    var zombie: pid_t = 0
    var argv: [UnsafeMutablePointer<CChar>?] = [strdup("/usr/bin/true"), nil]
    defer { free(argv[0]) }
    guard posix_spawn(&zombie, "/usr/bin/true", nil, nil, &argv, nil) == 0, zombie > 0 else {
      Issue.record("the zombie child could not be spawned")
      return
    }
    defer {
      var status: Int32 = 0
      _ = waitpid(zombie, &status, 0)
    }
    let ended = await UpdateTestSupport.waitUntil {
      SystemUpdateProcessTable().state(of: zombie) == .zombie
    }
    #expect(ended)
    #expect(SystemUpdateProcessTable().executablePath(of: zombie) == .failed(errno: ESRCH))
    #expect(SystemUpdateProcessTable().signalCheck(zombie) == 0)
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let shell = folder.appending(path: "deleted-shell")
    try FileManager.default.copyItem(at: URL(fileURLWithPath: "/bin/zsh"), to: shell)
    try await UpdateVerifyTestSupport.run(
      "/usr/bin/codesign", ["-s", "-", "--force", Support.path(shell)])
    let marker = Support.path(folder) + "/running"
    let child = Process()
    child.executableURL = shell
    child.arguments = ["-f", "-c", Self.readyScript, "deleted-shell", marker]
    child.standardInput = Pipe()
    try child.run()
    defer { Support.stop(child) }
    #expect(await UpdateTestSupport.waitUntil { FileManager.default.fileExists(atPath: marker) })
    try FileManager.default.removeItem(at: shell)
    #expect(
      SystemUpdateProcessTable().executablePath(of: child.processIdentifier)
        == .failed(errno: ENOENT))
    #expect(SystemUpdateProcessTable().state(of: child.processIdentifier) == .alive)
    guard case .complete(let after) = SystemUpdateProcessListing().scan() else {
      Issue.record("a zombie or a deleted executable made the real scan incomplete")
      return
    }
    #expect(!after.contains { $0.hasPrefix(Support.path(folder) + "/") })
  } // End of func theRealScan()
}
