import Darwin
import Foundation
import Testing
import os

@testable import MuxFinderCore

/// The swap (PLAN.md D39, I-13b2; D27's binding), with stub bundles on private folders only:
/// `RENAME_SWAP` exchanges folders in different parents; the checks right before it refuse a
/// replaced installed bundle, a replaced download and a failing code check, changing nothing;
/// and every injected failure or race of the exchange puts the old bundle back only while both
/// places hold exactly what the swap left there, else renames nothing and marks the run folder
/// for recovery.
@Suite("Update swap")
struct UpdateSwapTests {
  /// Shorthand.
  typealias Support = UpdateInstallTestSupport

  /// One swap's folders: the private base, the installed stub (build 2), the run folder with a
  /// verified stub (build 3) at `extracted/muxFinder.app`, and the identities.
  struct Fixture {
    /// The private base folder (removed by `cleanUp()`).
    let base: URL
    /// The installed stub.
    let installed: URL
    /// The run folder.
    let staging: UpdateStagingFolder
    /// The verified bundle.
    let bundle: UpdateVerifiedBundle
    /// The install as eligibility recorded it.
    let install: UpdateEligibleInstall

    /// The old bundle's identity.
    var oldIdentity: UpdateBundleIdentity { install.identity }
    /// The new bundle's identity.
    var newIdentity: UpdateBundleIdentity { bundle.identity }

    /// A swap over the fixture.
    func swap(
      checker: any UpdateCodeChecking = FakeUpdateCodeChecker(.passed),
      exchanger: any UpdateBundleExchanging = RenameSwapExchanger()
    ) -> UpdateBundleSwap {
      UpdateBundleSwap(
        install: install, bundle: bundle, staging: staging, codeChecker: checker,
        exchanger: exchanger)
    }

    /// The identity at the installed path.
    func installedIdentity() -> UpdateBundleIdentity? {
      try? UpdateVerifyTestSupport.identity(of: installed)
    }

    /// The identity at the verified bundle's place.
    func stagedIdentity() -> UpdateBundleIdentity? {
      try? UpdateVerifyTestSupport.identity(of: URL(fileURLWithPath: bundle.path))
    }

    /// Removes the private folder.
    func cleanUp() {
      try? FileManager.default.removeItem(at: base)
    }
  }

  /// Builds a fixture.
  static func makeFixture() throws -> Fixture {
    let base = try UpdateTestSupport.makePrivateFolder()
    do {
      let installed = try Support.makeInstalledApp(in: base)
      let run = base.appending(path: "run", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: run, withIntermediateDirectories: false)
      #expect(chmod(Support.path(run), 0o700) == 0)
      let staging = try UpdateStagingFolder(path: Support.path(run))
      let app = run.appending(path: "extracted/muxFinder.app", directoryHint: .isDirectory)
      try UpdateVerifyTestSupport.makeApp(
        at: app, info: UpdateVerifyTestSupport.infoPlist(short: "0.3.0", build: "3"))
      let bundle = UpdateVerifiedBundle(
        path: Support.path(app), relativePath: "extracted/muxFinder.app",
        version: UpdateVersion("0.3.0")!, build: 3,
        identity: try UpdateVerifyTestSupport.identity(of: app))
      return Fixture(
        base: base, installed: installed, staging: staging, bundle: bundle,
        install: try Support.eligibleInstall(installed))
    } catch {
      try? FileManager.default.removeItem(at: base)
      throw error
    }
  } // End of static func makeFixture()

  /// The proof `RenameSwapExchanger` relies on: two folders in different parents of a private
  /// APFS folder change places, each path then holding the other folder (device and inode).
  @Test func renameSwapExchangesFoldersInDifferentParents() throws {
    let base = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let first = base.appending(path: "one/a.app", directoryHint: .isDirectory)
    let second = base.appending(path: "two/three/b.app", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: first, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: second, withIntermediateDirectories: true)
    try Data("a\n".utf8).write(to: first.appending(path: "marker"))
    let firstIdentity = try UpdateVerifyTestSupport.identity(of: first)
    let secondIdentity = try UpdateVerifyTestSupport.identity(of: second)
    #expect(RenameSwapExchanger().exchange(Support.path(second), Support.path(first)) == 0)
    #expect(try UpdateVerifyTestSupport.identity(of: first) == secondIdentity)
    #expect(try UpdateVerifyTestSupport.identity(of: second) == firstIdentity)
    #expect(FileManager.default.fileExists(atPath: Support.path(second) + "/marker"))
    #expect(
      RenameSwapExchanger().exchange(Support.path(first), Support.path(base) + "/missing")
        == ENOENT)
  } // End of func renameSwapExchangesFoldersInDifferentParents()

  /// A swap with everything in place: the installed path holds the new bundle, the run folder
  /// the old, and the code check ran on the verified bundle with the running team.
  @Test func swapsWhenEverythingMatches() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    let checker = FakeUpdateCodeChecker(.passed)
    #expect(await fixture.swap(checker: checker).run() == .swapped)
    #expect(fixture.installedIdentity() == fixture.newIdentity)
    #expect(fixture.stagedIdentity() == fixture.oldIdentity)
    #expect(Support.build(of: fixture.installed) == "3")
    #expect(checker.paths == [fixture.bundle.path])
  }

  /// The checks before the exchange refuse, changing nothing: the installed bundle replaced, a
  /// link on its path, the download replaced, the code check failing (signature or
  /// notarization), and the installed bundle replaced during the code check.
  @Test func checksBeforeTheExchange() async throws {
    let replaced = try Self.makeFixture()
    defer { replaced.cleanUp() }
    try UpdateVerifyTestSupport.swapBundle(atPath: Support.path(replaced.installed))
    #expect(await replaced.swap().run() == .failed(.installedChanged, rollback: .notNeeded))
    #expect(replaced.stagedIdentity() == replaced.newIdentity)

    let download = try Self.makeFixture()
    defer { download.cleanUp() }
    try UpdateVerifyTestSupport.swapBundle(atPath: download.bundle.path)
    #expect(await download.swap().run() == .failed(.downloadChanged, rollback: .notNeeded))
    #expect(download.installedIdentity() == download.oldIdentity)

    let unsigned = try Self.makeFixture()
    defer { unsigned.cleanUp() }
    #expect(
      await unsigned.swap(checker: FakeUpdateCodeChecker(.signatureFailed(.otherTeam))).run()
        == .failed(.signature(.otherTeam), rollback: .notNeeded))
    #expect(
      await unsigned.swap(checker: FakeUpdateCodeChecker(.notarizationFailed(.notNotarized(-1))))
        .run() == .failed(.notarization(.notNotarized(-1)), rollback: .notNeeded))
    #expect(unsigned.installedIdentity() == unsigned.oldIdentity)

    let racing = try Self.makeFixture()
    defer { racing.cleanUp() }
    var swap = racing.swap()
    let installedPath = Support.path(racing.installed)
    swap.checkpoint = { point in
      if point == .afterCodeCheck { try? UpdateVerifyTestSupport.swapBundle(atPath: installedPath) }
    }
    #expect(await swap.run() == .failed(.installedChanged, rollback: .notNeeded))
    #expect(racing.stagedIdentity() == racing.newIdentity)

    let linked = try Self.makeFixture()
    defer { linked.cleanUp() }
    let applications = linked.base.appending(path: "Applications")
    let moved = linked.base.appending(path: "Real")
    try FileManager.default.moveItem(at: applications, to: moved)
    try FileManager.default.createSymbolicLink(at: applications, withDestinationURL: moved)
    #expect(await linked.swap().run() == .failed(.installedChanged, rollback: .notNeeded))
  } // End of func checksBeforeTheExchange()

  /// A failed exchange changes nothing; one that reports success without exchanging is
  /// unconfirmed with nothing to undo.
  @Test func failedExchanges() async throws {
    let failing = try Self.makeFixture()
    defer { failing.cleanUp() }
    let exchanger = ScriptedExchanger([.fail(EXDEV)])
    #expect(
      await failing.swap(exchanger: exchanger).run()
        == .failed(.swapFailed(errno: EXDEV), rollback: .notNeeded))
    #expect(exchanger.calls == [[failing.bundle.path, Support.path(failing.installed)]])
    #expect(failing.installedIdentity() == failing.oldIdentity)

    let pretending = try Self.makeFixture()
    defer { pretending.cleanUp() }
    #expect(
      await pretending.swap(exchanger: ScriptedExchanger([.pretend])).run()
        == .failed(.swapUnconfirmed, rollback: .notNeeded))
    #expect(pretending.installedIdentity() == pretending.oldIdentity)
  } // End of func failedExchanges()

  /// Whether the fixture's run folder holds the recovery marker.
  static func isMarked(_ fixture: Fixture) -> Bool {
    var info = stat()
    return lstat(fixture.staging.path(of: UpdateStagingRoot.recoveryMarkerName), &info) == 0
  }

  /// The review's regression (PLAN.md D39, I-13b2): something else replaces the installed path
  /// right after the forward exchange. Nothing is exchanged back, the replacement stays at the
  /// installed path untouched, the old bundle stays in the run folder, the rollback requires
  /// recovery and the run folder is marked.
  @Test func aReplacementAfterTheExchangeIsNeverMoved() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    let installedPath = Support.path(fixture.installed)
    let replacement = OSAllocatedUnfairLock<UpdateBundleIdentity?>(initialState: nil)
    let exchanger = ScriptedExchanger([
      .after({
        try? UpdateVerifyTestSupport.swapBundle(atPath: installedPath)
        let identity = try? UpdateVerifyTestSupport.identity(
          of: URL(fileURLWithPath: installedPath))
        replacement.withLock { $0 = identity }
      })
    ])
    let outcome = await fixture.swap(exchanger: exchanger).run()
    #expect(
      outcome
        == .failed(.swapUnconfirmed, rollback: .recoveryRequired(runFolder: fixture.staging.path)))
    #expect(exchanger.calls.count == 1)
    let replaced = replacement.withLock { $0 }
    #expect(replaced != nil && replaced != fixture.newIdentity && replaced != fixture.oldIdentity)
    #expect(fixture.installedIdentity() == replaced)
    #expect(
      (try? String(contentsOfFile: installedPath + "/Contents/Resources/note.txt", encoding: .utf8))
        == "changed\n")
    #expect(fixture.stagedIdentity() == fixture.oldIdentity)
    #expect(Self.isMarked(fixture))
  } // End of func aReplacementAfterTheExchangeIsNeverMoved()

  /// The other places the rollback is bound to both identities: the run folder's old bundle
  /// taken away after the exchange (nothing renamed, recovery), the download replaced after a
  /// failed exchange (the old bundle in place, but the run folder holds something else:
  /// recovery, so it is kept), and a replacement of the installed path between the reverse
  /// exchange's checks and the exchange itself (it lands in the run folder: recovery, marked).
  @Test func rollbackBindsBothIdentities() async throws {
    let stagedRace = try Self.makeFixture()
    defer { stagedRace.cleanUp() }
    let stagedPath = stagedRace.bundle.path
    let stagedExchanger = ScriptedExchanger([
      .after({ try? UpdateVerifyTestSupport.swapBundle(atPath: stagedPath) })
    ])
    #expect(
      await stagedRace.swap(exchanger: stagedExchanger).run()
        == .failed(
          .swapUnconfirmed, rollback: .recoveryRequired(runFolder: stagedRace.staging.path)))
    #expect(stagedExchanger.calls.count == 1)
    #expect(stagedRace.installedIdentity() == stagedRace.newIdentity)
    #expect(Self.isMarked(stagedRace))

    let failedThenReplaced = try Self.makeFixture()
    defer { failedThenReplaced.cleanUp() }
    var failing = failedThenReplaced.swap(exchanger: ScriptedExchanger([.fail(EXDEV)]))
    let downloadPath = failedThenReplaced.bundle.path
    failing.checkpoint = { point in
      if point == .afterExchange { try? UpdateVerifyTestSupport.swapBundle(atPath: downloadPath) }
    }
    #expect(
      await failing.run()
        == .failed(
          .swapFailed(errno: EXDEV),
          rollback: .recoveryRequired(runFolder: failedThenReplaced.staging.path)))
    #expect(failedThenReplaced.installedIdentity() == failedThenReplaced.oldIdentity)
    #expect(Self.isMarked(failedThenReplaced))

    let reverseRace = try Self.makeFixture()
    defer { reverseRace.cleanUp() }
    var swap = reverseRace.swap()
    #expect(await swap.run() == .swapped)
    let installedPath = Support.path(reverseRace.installed)
    swap.checkpoint = { point in
      if point == .beforeReverse { try? UpdateVerifyTestSupport.swapBundle(atPath: installedPath) }
    }
    #expect(await swap.rollBack() == .recoveryRequired(runFolder: reverseRace.staging.path))
    #expect(reverseRace.installedIdentity() == reverseRace.oldIdentity)
    #expect(reverseRace.stagedIdentity() != reverseRace.newIdentity)
    #expect(Self.isMarked(reverseRace))
  } // End of func rollbackBindsBothIdentities()

  /// A reverse exchange that fails, or reports success without exchanging, after a successful
  /// swap leaves the swap's state (`failed`, no marker); the phrases and codes.
  @Test func reverseExchangeFailures() async throws {
    for step in [ScriptedExchanger.Step.fail(EIO), .pretend] {
      let fixture = try Self.makeFixture()
      defer { fixture.cleanUp() }
      let swap = fixture.swap(exchanger: ScriptedExchanger([.real, step]))
      #expect(await swap.run() == .swapped)
      #expect(await swap.rollBack() == .failed(runFolder: fixture.staging.path))
      #expect(fixture.installedIdentity() == fixture.newIdentity)
      #expect(fixture.stagedIdentity() == fixture.oldIdentity)
      #expect(!Self.isMarked(fixture))
    } // End of loop over the reverse exchange's failures
    let recovery = UpdateRollback.recoveryRequired(runFolder: "/private/tmp/x")
    #expect(recovery.code == "recoveryRequired")
    #expect(recovery.reason == "something else changed muxFinder during the update")
    for rollback in [UpdateRollback.notNeeded, .rolledBack, .failed(runFolder: "/private/tmp/x")] {
      #expect(rollback.reason == nil)
    }
  } // End of func reverseExchangeFailures()

  /// Undoing a successful swap (the relauncher could not start) puts the old bundle back, and
  /// undoing again has nothing to do.
  @Test func undoAfterASuccessfulSwap() async throws {
    let fixture = try Self.makeFixture()
    defer { fixture.cleanUp() }
    let swap = fixture.swap()
    #expect(await swap.run() == .swapped)
    #expect(await swap.rollBack() == .rolledBack)
    #expect(fixture.installedIdentity() == fixture.oldIdentity)
    #expect(fixture.stagedIdentity() == fixture.newIdentity)
    #expect(await swap.rollBack() == .notNeeded)
  }
}
