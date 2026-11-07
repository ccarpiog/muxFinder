import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The install pipeline I-13c drives (PLAN.md D39, I-13b2), end to end on private folders: a
/// stub "installed" app, the update folder injected, I-13b1's real verifier over a synthetic
/// zip with a fake code checker, the real exchange, and the real relauncher with the stand-in
/// opener waiting for a `sleep` child of the test. Also discard, refusals, a cancel, a code
/// check that fails at install and a relauncher that cannot start.
@Suite("Update pipeline")
struct UpdatePipelineTests {
  /// Shorthand.
  typealias Support = UpdateInstallTestSupport

  /// One pipeline's world.
  struct World {
    /// The private base folder.
    let base: URL
    /// The installed stub (0.2.0, build 2).
    let installed: URL
    /// The update folder.
    let root: UpdateStagingRoot
    /// The release (0.3.0) whose asset is `zip`.
    let release: UpdateRelease
    /// The release zip's bytes.
    let zip: Data
    /// The stand-in opener.
    let opener: String

    /// The eligibility over the stub with `signing`.
    func eligibility(
      _ signing: UpdateSigningReading = .read(
        isDeveloperID: true, team: UpdateVerifyTestSupport.team)
    ) -> StubUpdateEligibility {
      StubUpdateEligibility(
        bundlePath: Support.path(installed), executablePath: Support.executablePath(of: installed),
        signing: signing, root: root)
    }

    /// The update folder's entries.
    func rootNames() -> [String] {
      (try? UpdateVerifyTestSupport.names(URL(fileURLWithPath: root.path))) ?? []
    }
  }

  /// Builds a world; the caller removes `base`.
  static func makeWorld() async throws -> World {
    let base = try UpdateTestSupport.makePrivateFolder()
    do {
      let installed = try Support.makeInstalledApp(in: base)
      try FileManager.default.createDirectory(
        at: base.appending(path: "support", directoryHint: .isDirectory),
        withIntermediateDirectories: false)
      let zip = try await UpdateVerifyTestSupport.makeZip { source in
        try UpdateVerifyTestSupport.makeApp(
          at: source.appending(path: "muxFinder.app", directoryHint: .isDirectory),
          info: UpdateVerifyTestSupport.infoPlist(short: "0.3.0", build: "3"))
      }
      try? FileManager.default.removeItem(at: zip.folder)
      return World(
        base: base, installed: installed,
        root: UpdateStagingRoot(path: Support.path(base) + "/support/muxFinder/update"),
        release: UpdateVerifyTestSupport.release(tag: "v0.3.0", body: zip.data), zip: zip.data,
        opener: try Support.makeStandInOpener(in: base))
    } catch {
      try? FileManager.default.removeItem(at: base)
      throw error
    }
  } // End of static func makeWorld()

  /// Records the states a pipeline reports.
  final class StateRecorder: Sendable {
    /// The states, in order.
    private let states = OSAllocatedUnfairLock<[UpdatePipelineState]>(initialState: [])
    /// Records `state`.
    func record(_ state: UpdatePipelineState) { states.withLock { $0.append(state) } }
    /// The states so far.
    var all: [UpdatePipelineState] { states.withLock { $0 } }
  }

  /// Prepare, then install: the states in order, the run folder locked while prepared, the new
  /// bundle installed and the old one in the run folder, the relauncher waiting for the `sleep`
  /// child (nothing opened), the stand-in opener run once with the installed path after the
  /// child ends, and the next launch's cleanup deleting the run folder.
  @Test func endToEnd() async throws {
    let world = try await Self.makeWorld()
    defer { try? FileManager.default.removeItem(at: world.base) }
    let child = try Support.startSleep()
    defer { Support.stop(child) }
    let pipeline = UpdatePipeline(
      root: world.root, eligibility: world.eligibility(),
      relauncher: DetachedUpdateRelauncher(opener: world.opener, waitSeconds: 30),
      processID: child.processIdentifier, codeChecker: FakeUpdateCodeChecker(.passed))
    let recorder = StateRecorder()
    let outcome = await pipeline.prepare(
      world.release, transport: FakeUpdateDownloadTransport(.success(world.zip)),
      onState: recorder.record)
    guard case .prepared(let prepared) = outcome else {
      Issue.record("not prepared: \(outcome)")
      return
    }
    let size = world.zip.count
    #expect(recorder.all.first == .downloading(bytes: 0, total: size))
    #expect(recorder.all.contains(.downloading(bytes: size, total: size)))
    #expect(recorder.all.last == .checking)
    #expect(prepared.bundle.build == 3 && prepared.install.runningBuild == "2")
    #expect(prepared.runFolder.isLocked)
    #expect(prepared.runFolderPath.hasPrefix(world.root.path + "/run-"))
    #expect(Support.build(of: world.installed) == "2")
    let installed = await pipeline.install(prepared, onState: recorder.record)
    guard case .relaunchScheduled(let relauncher) = installed else {
      Issue.record("not installed: \(installed)")
      return
    }
    #expect(Array(recorder.all.suffix(2)) == [.installing, .relaunching])
    #expect(Support.build(of: world.installed) == "3")
    let old = URL(fileURLWithPath: prepared.runFolderPath + "/extracted/muxFinder.app")
    #expect(Support.build(of: old) == "2")
    #expect(try UpdateVerifyTestSupport.identity(of: old) == prepared.install.identity)
    #expect(!prepared.runFolder.isLocked)
    try await Task.sleep(for: .milliseconds(600))
    #expect(Support.openedLines(world.opener).isEmpty)
    Support.stop(child)
    #expect(await Support.waitForExit(relauncher) == 0)
    #expect(Support.openedLines(world.opener) == [Support.path(world.installed)])
    #expect(await pipeline.install(prepared) == .failed(.alreadyUsed, rollback: .notNeeded))
    let cleanups = await Support.settledCleanup { world.root.cleanLeftovers() }
    #expect(cleanups.reduce(0) { $0 + $1.removed } == 1)
    #expect(cleanups.allSatisfy { $0.failed == 0 })
    #expect(world.rootNames() == ["update.lock"])
  } // End of func endToEnd()

  /// A prepared update can be discarded (its run folder removed) once, and is then used.
  @Test func discard() async throws {
    let world = try await Self.makeWorld()
    defer { try? FileManager.default.removeItem(at: world.base) }
    let relauncher = RecordingRelauncher(.success(1))
    let pipeline = UpdatePipeline(
      root: world.root, eligibility: world.eligibility(), relauncher: relauncher,
      codeChecker: FakeUpdateCodeChecker(.passed))
    let outcome = await pipeline.prepare(
      world.release, transport: FakeUpdateDownloadTransport(.success(world.zip)))
    guard case .prepared(let prepared) = outcome else {
      Issue.record("not prepared")
      return
    }
    #expect(pipeline.discard(prepared))
    #expect(!FileManager.default.fileExists(atPath: prepared.runFolderPath))
    #expect(!pipeline.discard(prepared))
    #expect(await pipeline.install(prepared) == .failed(.alreadyUsed, rollback: .notNeeded))
    #expect(relauncher.count == 0)
    #expect(Support.build(of: world.installed) == "2")
  } // End of func discard()

  /// Refusals while preparing: a copy that is not eligible creates nothing; a digest mismatch
  /// fails the verification and removes the run folder.
  @Test func prepareRefusals() async throws {
    let world = try await Self.makeWorld()
    defer { try? FileManager.default.removeItem(at: world.base) }
    let development = UpdatePipeline(
      root: world.root,
      eligibility: world.eligibility(
        .read(isDeveloperID: false, team: UpdateVerifyTestSupport.team)),
      relauncher: RecordingRelauncher(.success(1)), codeChecker: FakeUpdateCodeChecker(.passed))
    guard
      case .failed(.notEligible(.notDeveloperID)) = await development.prepare(
        world.release, transport: FakeUpdateDownloadTransport(.success(world.zip)))
    else {
      Issue.record("a development copy was not refused")
      return
    }
    #expect(
      !FileManager.default.fileExists(atPath: Support.path(world.base) + "/support/muxFinder"))
    let pipeline = UpdatePipeline(
      root: world.root, eligibility: world.eligibility(),
      relauncher: RecordingRelauncher(.success(1)), codeChecker: FakeUpdateCodeChecker(.passed))
    let tampered = UpdateVerifyTestSupport.release(
      tag: "v0.3.0", body: world.zip, digest: String(repeating: "0", count: 64))
    let outcome = await pipeline.prepare(
      tampered, transport: FakeUpdateDownloadTransport(.success(world.zip)))
    guard case .failed(let failure) = outcome else {
      Issue.record("a tampered download was not refused")
      return
    }
    #expect(failure == .verification(.download(.digestMismatch)))
    #expect(failure.reason == "the download doesn't match the release's checksum")
    #expect(world.rootNames() == ["update.lock"])
  } // End of func prepareRefusals()

  /// A cancel during the download: `cancelled`, and the run folder is removed.
  @Test func cancelRemovesTheRunFolder() async throws {
    let world = try await Self.makeWorld()
    defer { try? FileManager.default.removeItem(at: world.base) }
    let pipeline = UpdatePipeline(
      root: world.root, eligibility: world.eligibility(),
      relauncher: RecordingRelauncher(.success(1)), codeChecker: FakeUpdateCodeChecker(.passed))
    let task = Task {
      await pipeline.prepare(world.release, transport: WaitingDownloadTransport())
    }
    let started = await UpdateTestSupport.waitUntil {
      world.rootNames().contains { UpdateStagingRoot.isRunFolderName($0) }
    }
    #expect(started)
    task.cancel()
    guard case .cancelled = await task.value else {
      Issue.record("not cancelled")
      return
    }
    #expect(world.rootNames() == ["update.lock"])
  } // End of func cancelRemovesTheRunFolder()

  /// Failures while installing leave the old bundle in place and remove the run folder: the
  /// code check run again before the swap refusing it, and a relauncher that cannot start
  /// (the swap undone).
  @Test func installFailures() async throws {
    let world = try await Self.makeWorld()
    defer { try? FileManager.default.removeItem(at: world.base) }
    let checker = SequencedCodeChecker([.passed, .signatureFailed(.otherTeam)])
    let refusing = UpdatePipeline(
      root: world.root, eligibility: world.eligibility(),
      relauncher: RecordingRelauncher(.success(1)), codeChecker: checker)
    guard
      case .prepared(let first) = await refusing.prepare(
        world.release, transport: FakeUpdateDownloadTransport(.success(world.zip)))
    else {
      Issue.record("not prepared")
      return
    }
    #expect(
      await refusing.install(first) == .failed(.signature(.otherTeam), rollback: .notNeeded))
    #expect(Support.build(of: world.installed) == "2")
    #expect(!FileManager.default.fileExists(atPath: first.runFolderPath))

    let relauncher = RecordingRelauncher(.failure(.spawnFailed(errno: EAGAIN)))
    let stuck = UpdatePipeline(
      root: world.root, eligibility: world.eligibility(), relauncher: relauncher,
      codeChecker: FakeUpdateCodeChecker(.passed))
    guard
      case .prepared(let second) = await stuck.prepare(
        world.release, transport: FakeUpdateDownloadTransport(.success(world.zip)))
    else {
      Issue.record("not prepared")
      return
    }
    let outcome = await stuck.install(second)
    #expect(outcome == .failed(.relaunchNotStarted(errno: EAGAIN), rollback: .rolledBack))
    #expect(relauncher.count == 1)
    #expect(Support.build(of: world.installed) == "2")
    #expect(try UpdateVerifyTestSupport.identity(of: world.installed) == second.install.identity)
    #expect(!FileManager.default.fileExists(atPath: second.runFolderPath))
    #expect(world.rootNames() == ["update.lock"])
  } // End of func installFailures()

  /// The review's regression end to end (PLAN.md D39, I-13b2): something else replaces the
  /// installed path right after the forward exchange. The install fails requiring recovery,
  /// nothing is exchanged back, the replacement stays installed untouched, no relauncher
  /// starts, the old bundle stays in the run folder (marked, released), and the next launch's
  /// cleanup keeps that run folder, again on a second run.
  @Test func aReplacementAfterTheSwapIsKept() async throws {
    let world = try await Self.makeWorld()
    defer { try? FileManager.default.removeItem(at: world.base) }
    let installedPath = Support.path(world.installed)
    let replacement = OSAllocatedUnfairLock<UpdateBundleIdentity?>(initialState: nil)
    let exchanger = ScriptedExchanger([
      .after({
        try? UpdateVerifyTestSupport.swapBundle(atPath: installedPath)
        let identity = try? UpdateVerifyTestSupport.identity(
          of: URL(fileURLWithPath: installedPath))
        replacement.withLock { $0 = identity }
      })
    ])
    let relauncher = RecordingRelauncher(.success(1))
    let pipeline = UpdatePipeline(
      root: world.root, eligibility: world.eligibility(), relauncher: relauncher,
      codeChecker: FakeUpdateCodeChecker(.passed), exchanger: exchanger)
    guard
      case .prepared(let prepared) = await pipeline.prepare(
        world.release, transport: FakeUpdateDownloadTransport(.success(world.zip)))
    else {
      Issue.record("not prepared")
      return
    }
    let outcome = await pipeline.install(prepared)
    #expect(
      outcome
        == .failed(
          .swapUnconfirmed, rollback: .recoveryRequired(runFolder: prepared.runFolderPath)))
    #expect(exchanger.calls.count == 1)
    #expect(relauncher.count == 0)
    let replaced = replacement.withLock { $0 }
    #expect(replaced != nil && replaced != prepared.bundle.identity)
    #expect(try UpdateVerifyTestSupport.identity(of: world.installed) == replaced)
    #expect(
      (try? String(contentsOfFile: installedPath + "/Contents/Resources/note.txt", encoding: .utf8))
        == "changed\n")
    let old = URL(fileURLWithPath: prepared.runFolderPath + "/extracted/muxFinder.app")
    #expect(try UpdateVerifyTestSupport.identity(of: old) == prepared.install.identity)
    #expect(
      FileManager.default.fileExists(
        atPath: prepared.runFolderPath + "/" + UpdateStagingRoot.recoveryMarkerName))
    #expect(!prepared.runFolder.isLocked)
    var expected = UpdateCleanupReport()
    expected.keptForRecovery = 1
    expected.ignored = 1 // update.lock
    for _ in 0..<2 {
      let reports = await Support.settledCleanup { world.root.cleanLeftovers() }
      #expect(reports.allSatisfy { $0.removed == 0 && $0.failed == 0 })
      #expect(reports.last == expected)
      #expect(try UpdateVerifyTestSupport.identity(of: old) == prepared.install.identity)
    } // End of loop over two cleanups
    #expect(try UpdateVerifyTestSupport.identity(of: world.installed) == replaced)
  } // End of func aReplacementAfterTheSwapIsKept()
}

/// A download transport that waits until its task is cancelled, then answers `cancelled`.
struct WaitingDownloadTransport: UpdateDownloadTransport {
  /// Waits for the cancel (at most 30 s).
  func fetch(_ asset: UpdateAsset, into sink: UpdateDownloadSink) async -> Result<
    Void, UpdateDownloadFailure
  > {
    let deadline = ContinuousClock.now + .seconds(30)
    while !Task.isCancelled, ContinuousClock.now < deadline {
      try? await Task.sleep(for: .milliseconds(20))
    }
    return .failure(.cancelled)
  }
}

/// A code checker answering from a list, one answer per call (the last repeats).
final class SequencedCodeChecker: UpdateCodeChecking, Sendable {
  /// The answers left.
  private let answers: OSAllocatedUnfairLock<[UpdateCodeCheckResult]>

  /// A checker answering `answers` in order.
  init(_ answers: [UpdateCodeCheckResult]) {
    self.answers = OSAllocatedUnfairLock(initialState: answers)
  }

  /// See `UpdateCodeChecking`.
  func check(bundleAt path: String, team: UpdateTeamID) async -> UpdateCodeCheckResult {
    answers.withLock { $0.count > 1 ? $0.removeFirst() : $0.first ?? .passed }
  }
}
