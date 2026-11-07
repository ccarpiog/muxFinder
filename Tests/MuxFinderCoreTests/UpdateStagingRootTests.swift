import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The update folder and its run folders (PLAN.md D39, I-13b2), on private folders only: a
/// read-only look creates nothing; an update creates it 0700 and refuses an unusable one; each
/// run folder is fresh, 0700 and locked; and the leftover cleanup deletes only unused run
/// folders (a real child process running from one keeps it, as does a held lock), never follows
/// a link or leaves the folder, and reports its counts.
@Suite("Update staging root")
struct UpdateStagingRootTests {
  /// Shorthand.
  typealias Support = UpdateInstallTestSupport

  /// A private base folder and an update folder path two levels below it (not created).
  static func makeRoot() throws -> (base: URL, root: UpdateStagingRoot) {
    let base = try UpdateTestSupport.makePrivateFolder()
    return (base, UpdateStagingRoot(path: Support.path(base) + "/muxFinder/update"))
  }

  /// The permission bits of the entry at `path`.
  static func mode(_ path: String) -> mode_t {
    var info = stat()
    _ = lstat(path, &info)
    return info.st_mode & 0o7777
  }

  /// Looking creates nothing: missing (with the nearest folder's device), then usable once
  /// made; a link, a file, a folder open to others, one with an ACL and another user's are
  /// unusable and left as they are.
  @Test func inspectionCreatesNothing() throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    var info = stat()
    #expect(lstat(Support.path(base), &info) == 0)
    #expect(root.inspect() == .missing(device: Int64(info.st_dev)))
    #expect(!FileManager.default.fileExists(atPath: Support.path(base) + "/muxFinder"))
    let made = try root.prepare()
    #expect(made.path == root.path)
    #expect(Self.mode(root.path) == 0o700)
    #expect(root.inspect() == .usable(device: Int64(info.st_dev)))
    #expect(root.inspect(owner: geteuid() + 1) == .unusable(.notOwnedByUser))
    #expect(chmod(root.path, 0o750) == 0)
    #expect(root.inspect() == .unusable(.notPrivate))
    #expect(Self.mode(root.path) == 0o750)
    #expect(chmod(root.path, 0o700) == 0)
    try LaunchTestSupport.setACL(
      LaunchTestSupport.everyoneReadACL, on: URL(fileURLWithPath: root.path))
    #expect(root.inspect() == .unusable(.notPrivate))
    #expect(try LaunchTestSupport.aclEntryCount(of: URL(fileURLWithPath: root.path)) == 1)
    let linkBase = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: linkBase) }
    try FileManager.default.createSymbolicLink(
      atPath: Support.path(linkBase) + "/muxFinder",
      withDestinationPath: Support.path(base) + "/muxFinder")
    let linked = UpdateStagingRoot(path: Support.path(linkBase) + "/muxFinder/update")
    #expect(linked.inspect() == .unusable(.symbolicLinkOnPath))
    try Data().write(to: linkBase.appending(path: "file"))
    #expect(
      UpdateStagingRoot(path: Support.path(linkBase) + "/file/update").inspect()
        == .unusable(.notADirectory))
    #expect(
      UpdateStagingRoot(path: "relative/update").inspect() == .unusable(.notAPlainAbsolutePath))
  } // End of func inspectionCreatesNothing()

  /// An update creates the support folder and the update folder (0700) when missing, and
  /// refuses an existing update folder that is not private or is a link, changing nothing.
  @Test func preparationRules() throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    _ = try root.prepare()
    #expect(Self.mode(Support.path(base) + "/muxFinder") == 0o700)
    #expect(Self.mode(root.path) == 0o700)
    #expect(chmod(root.path, 0o755) == 0)
    #expect(throws: UpdateStagingRootError.root(.notPrivate)) { try root.prepare() }
    #expect(Self.mode(root.path) == 0o755)
    #expect(rmdir(root.path) == 0)
    let elsewhere = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    try FileManager.default.createSymbolicLink(
      atPath: root.path, withDestinationPath: Support.path(elsewhere))
    #expect(throws: UpdateStagingRootError.root(.symbolicLinkOnPath)) { try root.prepare() }
    #expect(try UpdateVerifyTestSupport.names(elsewhere).isEmpty)
    let deep = UpdateStagingRoot(path: Support.path(base) + "/a/b/update")
    #expect(throws: UpdateStagingRootError.root(.missing)) { try deep.prepare() }
    #expect(!FileManager.default.fileExists(atPath: Support.path(base) + "/a"))
  } // End of func preparationRules()

  /// Each run folder is fresh, named `run-` and 16 hex digits, 0700, I-13b1's staging folder,
  /// and locked until released; another device is refused before anything is made.
  @Test func runFolders() async throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    var info = stat()
    #expect(lstat(Support.path(base), &info) == 0)
    #expect(throws: UpdateStagingRootError.differentVolume) {
      try root.makeRunFolder(onDevice: Int64(info.st_dev) + 1)
    }
    let first = try root.makeRunFolder(onDevice: Int64(info.st_dev))
    let second = try root.makeRunFolder(onDevice: nil)
    #expect(first.name != second.name)
    #expect(UpdateStagingRoot.isRunFolderName(first.name))
    #expect(first.path == root.path + "/" + first.name)
    #expect(Self.mode(first.path) == 0o700)
    #expect(first.staging.path == first.path)
    #expect(first.isLocked)
    let probe = open(first.path + "/run.lock", O_RDONLY | O_CLOEXEC)
    #expect(probe >= 0)
    #expect(flock(probe, LOCK_EX | LOCK_NB) != 0)
    first.release()
    #expect(!first.isLocked)
    // A process another test is spawning may hold the released lock until its image starts.
    #expect(
      await UpdateTestSupport.waitUntil(within: .seconds(5)) {
        flock(probe, LOCK_EX | LOCK_NB) == 0
      })
    Darwin.close(probe)
    #expect(second.remove())
    #expect(!FileManager.default.fileExists(atPath: second.path))
    #expect(FileManager.default.fileExists(atPath: first.path))
    #expect(UpdateStagingRoot.isRunFolderName("run-0123456789abcdef"))
    for name in ["run-0123456789ABCDEF", "run-0123", "run-0123456789abcdef0", "x-0123456789abcdef"]
    {
      #expect(!UpdateStagingRoot.isRunFolderName(name), "\(name)")
    }
  } // End of func runFolders()

  /// The cleanup deletes an unused run folder (with the old bundle and a read-only folder in
  /// it), keeps one a real child process runs from until it ends, keeps a locked one, leaves
  /// other entries and a link named like a run folder alone, never follows a link inside a run
  /// folder, and reports the counts.
  @Test func cleanupKeepsWhatIsInUse() async throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let outside = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: outside) }
    try Data("keep\n".utf8).write(to: outside.appending(path: "precious"))
    let unused = try root.makeRunFolder(onDevice: nil)
    let unusedApp = URL(fileURLWithPath: unused.path + "/extracted/muxFinder.app")
    try UpdateVerifyTestSupport.makeApp(at: unusedApp)
    try FileManager.default.createSymbolicLink(
      atPath: unused.path + "/extracted/escape", withDestinationPath: Support.path(outside))
    #expect(chmod(Support.path(unusedApp) + "/Contents/Resources", 0o500) == 0)
    unused.release()
    let busy = try root.makeRunFolder(onDevice: nil)
    let inUse = try root.makeRunFolder(onDevice: nil)
    let macOS = URL(fileURLWithPath: inUse.path + "/extracted/muxFinder.app/Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let child = try await Support.startCopiedSleep(in: macOS, name: "muxfinder-launch")
    defer { Support.stop(child) }
    inUse.release()
    try FileManager.default.createSymbolicLink(
      atPath: root.path + "/run-00000000000000aa", withDestinationPath: Support.path(outside))
    try Data().write(to: URL(fileURLWithPath: root.path + "/notes.txt"))
    let reports = await Support.settledCleanup(locked: 1) { root.cleanLeftovers() }
    #expect(reports.allSatisfy { $0.skipped == nil && $0.failed == 0 })
    #expect(reports.reduce(0) { $0 + $1.removed } == 1)
    #expect(reports.last?.keptInUse == 1 && reports.last?.keptLocked == 1)
    #expect(reports.last?.ignored == 3) // update.lock, notes.txt, the link
    #expect(!FileManager.default.fileExists(atPath: unused.path))
    #expect(FileManager.default.fileExists(atPath: busy.path))
    #expect(FileManager.default.fileExists(atPath: inUse.path))
    #expect(try UpdateVerifyTestSupport.names(outside) == ["precious"])
    Support.stop(child)
    busy.release()
    let after = await Support.settledCleanup { root.cleanLeftovers() }
    #expect(after.reduce(0) { $0 + $1.removed } == 2)
    #expect(after.last?.keptInUse == 0 && after.last?.keptLocked == 0)
    #expect(after.allSatisfy { $0.failed == 0 })
    #expect(
      try UpdateVerifyTestSupport.names(URL(fileURLWithPath: root.path)).sorted() == [
        "notes.txt", "run-00000000000000aa", "update.lock",
      ])
    #expect(try UpdateVerifyTestSupport.names(outside) == ["precious"])
  } // End of func cleanupKeepsWhatIsInUse()

  /// The cleanup touches nothing without an update folder (and creates none), with one that
  /// fails its checks, or while another holder keeps the update folder's lock.
  @Test func cleanupSkipsUnusableRoots() async throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    #expect(root.cleanLeftovers() == UpdateCleanupReport(skipped: .missing))
    #expect(!FileManager.default.fileExists(atPath: Support.path(base) + "/muxFinder"))
    let run = try root.makeRunFolder(onDevice: nil)
    run.release()
    #expect(chmod(root.path, 0o755) == 0)
    #expect(root.cleanLeftovers() == UpdateCleanupReport(skipped: .unusable(.notPrivate)))
    #expect(FileManager.default.fileExists(atPath: run.path))
    #expect(chmod(root.path, 0o700) == 0)
    let holder = open(root.path + "/update.lock", O_RDONLY | O_CLOEXEC)
    // A process another test is spawning holds the lock `makeRunFolder` just released until
    // its new image starts, so the holder may have to try again for a moment.
    let held = await UpdateTestSupport.waitUntil(within: .seconds(5)) {
      flock(holder, LOCK_EX | LOCK_NB) == 0
    }
    #expect(holder >= 0 && held)
    let cleanup = UpdateLeftoverCleanup(
      root: root, owner: geteuid(), processes: SystemUpdateProcessListing(),
      lockWait: .milliseconds(300))
    let started = ContinuousClock.now
    #expect(cleanup.run() == UpdateCleanupReport(skipped: .busy))
    #expect(ContinuousClock.now - started >= .milliseconds(250))
    Darwin.close(holder)
    #expect(FileManager.default.fileExists(atPath: run.path))
    let reports = await Support.settledCleanup { root.cleanLeftovers() }
    #expect(reports.reduce(0) { $0 + $1.removed } == 1)
  } // End of func cleanupSkipsUnusableRoots()

  /// The review's regression: a live update holds a run folder's lock; a scan made then sees
  /// nothing inside it, and right after that scan the update swaps the old bundle in (a buried
  /// helper runs from it) and releases the lock. The cleanup takes the lock before it scans,
  /// so the folder is kept: locked on the first run (no scan made), in use on the next, the
  /// scan made once, after the lock was taken.
  @Test func cleanupTakesTheRunLockBeforeScanning() async throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let run = try root.makeRunFolder(onDevice: nil)
    let app = URL(fileURLWithPath: run.path + "/extracted/muxFinder.app")
    try UpdateVerifyTestSupport.makeApp(at: app)
    let scanner = RacingUpdateScanner(
      helperPath: Support.path(app) + "/Contents/MacOS/muxFinder", finishUpdate: { run.release() })
    let cleanup = UpdateLeftoverCleanup(root: root, owner: geteuid(), processes: scanner)
    let first = cleanup.run()
    #expect(first.keptLocked == 1 && first.removed == 0 && first.failed == 0)
    #expect(FileManager.default.fileExists(atPath: Support.path(app)))
    scanner.finishIfRunning()
    #expect(!run.isLocked)
    let second = await Support.settledCleanup { cleanup.run() }
    #expect(second.allSatisfy { $0.removed == 0 && $0.failed == 0 })
    #expect(second.last?.keptInUse == 1)
    #expect(FileManager.default.fileExists(atPath: Support.path(app)))
    #expect(scanner.scans == 1)
  } // End of func cleanupTakesTheRunLockBeforeScanning()

  /// A run folder a rollback marked for recovery is kept by every cleanup, whatever the
  /// marker's kind (a file, a folder, a link), with no process scan needed; an unmarked one
  /// beside it is deleted.
  @Test func cleanupKeepsRecoveryMarkedFolders() async throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let marker = UpdateStagingRoot.recoveryMarkerName
    let file = try root.makeRunFolder(onDevice: nil)
    #expect(FileManager.default.createFile(atPath: file.path + "/" + marker, contents: nil))
    let folder = try root.makeRunFolder(onDevice: nil)
    try FileManager.default.createDirectory(
      atPath: folder.path + "/" + marker, withIntermediateDirectories: false)
    let link = try root.makeRunFolder(onDevice: nil)
    try FileManager.default.createSymbolicLink(
      atPath: link.path + "/" + marker, withDestinationPath: "/private/tmp/missing")
    let unmarked = try root.makeRunFolder(onDevice: nil)
    for run in [file, folder, link, unmarked] { run.release() }
    let listing = FixedProcessListing(.complete([]))
    let cleanup = UpdateLeftoverCleanup(root: root, owner: geteuid(), processes: listing)
    let first = await Support.settledCleanup { cleanup.run() }
    #expect(first.reduce(0) { $0 + $1.removed } == 1 && first.allSatisfy { $0.failed == 0 })
    #expect(first.last?.keptForRecovery == 3)
    #expect(listing.scans == 1)
    let second = await Support.settledCleanup { cleanup.run() }
    #expect(second.allSatisfy { $0.removed == 0 })
    #expect(second.last?.keptForRecovery == 3)
    for run in [file, folder, link] {
      #expect(FileManager.default.fileExists(atPath: run.path))
    }
    #expect(!FileManager.default.fileExists(atPath: unmarked.path))
  } // End of func cleanupKeepsRecoveryMarkedFolders()

  /// An incomplete process scan keeps every run folder it was judging (counted as unverified,
  /// the problem reported), each over the injected process table: the list failing, a list
  /// that stays full, a running process whose path cannot be read. A complete scan then
  /// deletes them.
  @Test func cleanupKeepsEverythingWhenTheScanIsIncomplete() async throws {
    let (base, root) = try Self.makeRoot()
    defer { try? FileManager.default.removeItem(at: base) }
    let runs = [try root.makeRunFolder(onDevice: nil), try root.makeRunFolder(onDevice: nil)]
    for run in runs { run.release() }
    let tables: [(ScriptedUpdateProcessTable, UpdateProcessScanProblem)] = [
      (ScriptedUpdateProcessTable(pids: [1, 2], listErrno: EPERM), .listFailed(errno: EPERM)),
      (ScriptedUpdateProcessTable(pids: Array(1...5000), estimate: .value(10)), .listTruncated),
      (
        ScriptedUpdateProcessTable(pids: [1, 2, 3], paths: [2: .failed(errno: EPERM)]),
        .pathUnreadable(errno: EPERM)
      ),
    ]
    for (table, problem) in tables {
      let cleanup = UpdateLeftoverCleanup(
        root: root, owner: geteuid(), processes: SystemUpdateProcessListing(table: table))
      let reports = await Support.settledCleanup { cleanup.run() }
      #expect(reports.allSatisfy { $0.removed == 0 && $0.failed == 0 })
      #expect(reports.last?.keptUnverified == 2 && reports.last?.scanProblem == problem)
      for run in runs { #expect(FileManager.default.fileExists(atPath: run.path)) }
    } // End of loop over the incomplete scans
    let complete = UpdateLeftoverCleanup(
      root: root, owner: geteuid(),
      processes: SystemUpdateProcessListing(table: ScriptedUpdateProcessTable(pids: [1, 2, 3])))
    let reports = await Support.settledCleanup { complete.run() }
    #expect(reports.reduce(0) { $0 + $1.removed } == 2)
    #expect(reports.allSatisfy { $0.keptUnverified == 0 && $0.scanProblem == nil })
  } // End of func cleanupKeepsEverythingWhenTheScanIsIncomplete()
}
