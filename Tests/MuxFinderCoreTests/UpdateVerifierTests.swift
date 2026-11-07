import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// The verification pipeline (PLAN.md D39, I-13b1): the staging folder's rules, every step's
/// verdict in order, the first failure stopping the rest and deleting what was written (never
/// an entry it did not create), success keeping only the bundle with its identity, a bundle
/// replaced or renamed before, during or after the code check refused, a download through the
/// `URLSession` transport over the stub, and cancellation.
@Suite("Update verifier")
struct UpdateVerifierTests {
  /// Shorthand.
  typealias Support = UpdateVerifyTestSupport

  /// The release version of the stub zips.
  static let expected = UpdateVersion("0.3.0")!

  /// A zip of a well-formed unsigned stub app.
  static func stubZip() async throws -> (data: Data, url: URL, folder: URL) {
    try await Support.makeZip { source in
      try Support.makeApp(at: source.appending(path: "muxFinder.app", directoryHint: .isDirectory))
    }
  }

  /// The staging folder is refused unless it is an existing private folder of the user's with
  /// no link on its path, and once checked it must stay that folder.
  @Test func stagingFolderRules() throws {
    let base = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let path = String(base.path(percentEncoded: false).dropLast())
    let manager = FileManager.default
    #expect(throws: Never.self) { try UpdateStagingFolder(path: path) }
    #expect(throws: UpdateStagingProblem.notAPlainAbsolutePath) {
      try UpdateStagingFolder(path: "private/tmp")
    }
    #expect(throws: UpdateStagingProblem.notAPlainAbsolutePath) {
      try UpdateStagingFolder(path: path + "/../x")
    }
    #expect(throws: UpdateStagingProblem.notAPlainAbsolutePath) {
      try UpdateStagingFolder(path: "/private//tmp")
    }
    #expect(throws: UpdateStagingProblem.missing) {
      try UpdateStagingFolder(path: path + "/missing")
    }
    #expect(throws: UpdateStagingProblem.symbolicLinkOnPath) {
      try UpdateStagingFolder(path: "/tmp")
    }
    try Data().write(to: base.appending(path: "file"))
    #expect(throws: UpdateStagingProblem.notADirectory) {
      try UpdateStagingFolder(path: path + "/file")
    }
    let link = base.appending(path: "link")
    try manager.createSymbolicLink(
      atPath: link.path(percentEncoded: false), withDestinationPath: path)
    #expect(throws: UpdateStagingProblem.symbolicLinkOnPath) {
      try UpdateStagingFolder(path: link.path(percentEncoded: false))
    }
    let open = base.appending(path: "open", directoryHint: .isDirectory)
    try manager.createDirectory(at: open, withIntermediateDirectories: false)
    #expect(chmod(open.path(percentEncoded: false), 0o750) == 0)
    #expect(throws: UpdateStagingProblem.notPrivate) {
      try UpdateStagingFolder(path: open.path(percentEncoded: false))
    }
    #expect(try LaunchTestSupport.permissions(of: open) == 0o750)
    let acl = base.appending(path: "acl", directoryHint: .isDirectory)
    try manager.createDirectory(at: acl, withIntermediateDirectories: false)
    #expect(chmod(acl.path(percentEncoded: false), 0o700) == 0)
    try LaunchTestSupport.setACL(LaunchTestSupport.everyoneReadACL, on: acl)
    #expect(throws: UpdateStagingProblem.notPrivate) {
      try UpdateStagingFolder(path: acl.path(percentEncoded: false))
    }
    #expect(try LaunchTestSupport.aclEntryCount(of: acl) == 1)
    #expect(throws: UpdateStagingProblem.notOwnedByUser) {
      try UpdateStagingFolder(path: path, owner: geteuid() + 1)
    }
    // Replaced after the check: refused at the next use, nothing written.
    let swapped = base.appending(path: "swapped", directoryHint: .isDirectory)
    try manager.createDirectory(at: swapped, withIntermediateDirectories: false)
    #expect(chmod(swapped.path(percentEncoded: false), 0o700) == 0)
    let staging = try UpdateStagingFolder(path: swapped.path(percentEncoded: false))
    try manager.moveItem(at: swapped, to: base.appending(path: "aside"))
    try manager.createDirectory(at: swapped, withIntermediateDirectories: false)
    #expect(chmod(swapped.path(percentEncoded: false), 0o700) == 0)
    #expect(throws: UpdateStagingProblem.replaced) { try staging.openDirectory() }
    #expect(throws: UpdateStagingFileError.staging(.replaced)) {
      try staging.createFile(named: "x")
    }
    #expect(try Support.names(swapped).isEmpty)
  } // End of func stagingFolderRules()

  /// Every step passes in order; only `extracted/muxFinder.app` is left (the zip deleted).
  @Test func successKeepsOnlyTheBundle() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed)
    ).verifyLocalZip(
      atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
      expectedVersion: Self.expected)
    #expect(report.steps.map(\.step) == UpdateVerificationStep.allCases)
    #expect(report.steps.allSatisfy { $0.verdict == .passed })
    let bundle = try #require(report.verifiedBundle)
    #expect(bundle.relativePath == "extracted/muxFinder.app")
    #expect(bundle.path == staging.path + "/extracted/muxFinder.app")
    #expect(bundle.version == Self.expected)
    #expect(bundle.build == 3)
    #expect(
      bundle.identity
        == (try Support.identity(of: folder.appending(path: "extracted/muxFinder.app"))))
    #expect(report.cleanedUp)
    #expect(report.zipSize == zip.data.count)
    #expect(try Support.names(folder) == ["extracted"])
    #expect(try LaunchTestSupport.permissions(of: folder.appending(path: "extracted")) == 0o700)
  } // End of func successKeepsOnlyTheBundle()

  /// The bundle replaced while the code check runs (by the checker itself here, as another
  /// process could): the check's answer is not trusted, the signature step fails with
  /// `bundleChanged`, nothing after it runs, nothing is left.
  @Test func bundleReplacedDuringTheCodeCheckIsRefused() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let checker = SwappingCodeChecker()
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2", codeChecker: checker
    ).verifyLocalZip(
      atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
      expectedVersion: Self.expected)
    #expect(checker.didSwap)
    #expect(report.failure == .bundleChanged(.signature))
    #expect(report.failure?.code == "bundleChanged")
    #expect(report.failure?.reason == "the download changed while it was being checked")
    #expect(report.verdict(of: .shape) == .passed)
    #expect(report.verdict(of: .notarization) == .notRun)
    #expect(report.verdict(of: .versions) == .notRun)
    #expect(report.verifiedBundle == nil)
    #expect(report.cleanedUp)
    #expect(try Support.names(folder).isEmpty)
  } // End of func bundleReplacedDuringTheCodeCheckIsRefused()

  /// The bundle replaced (or turned into a link to the original) after the shape walk and
  /// before the code check, or after the code check and before the versions are read: refused
  /// with `bundleChanged` at that step, nothing left.
  @Test func bundleReplacedAroundTheChecksIsRefused() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let relink: @Sendable (String) throws -> Void = { path in
      let app = URL(fileURLWithPath: path, isDirectory: true)
      let aside = app.deletingLastPathComponent().appending(path: "aside.app")
      try FileManager.default.moveItem(at: app, to: aside)
      try FileManager.default.createSymbolicLink(
        atPath: path, withDestinationPath: "aside.app")
    }
    let cases: [(UpdateVerificationStep, @Sendable (String) throws -> Void, Bool)] = [
      (.signature, Support.swapBundle(atPath:), false),
      (.signature, relink, false),
      (.versions, Support.swapBundle(atPath:), true),
      (.versions, relink, true),
    ]
    for (step, change, checked) in cases {
      let (staging, folder) = try Support.makeStaging()
      defer { try? FileManager.default.removeItem(at: folder) }
      let checker = FakeUpdateCodeChecker(.passed)
      var verifier = UpdateVerifier(
        staging: staging, team: Support.team, runningBuild: "2", codeChecker: checker)
      let path = staging.path(of: UpdateVerifier.bundleRelativePath)
      verifier.checkpoint = { at in
        if at == step { try? change(path) }
      }
      let report = await verifier.verifyLocalZip(
        atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
        expectedVersion: Self.expected)
      #expect(report.failure == .bundleChanged(step), "\(step)")
      #expect(checker.paths.count == (checked ? 1 : 0), "\(step)")
      #expect(report.verdict(of: .notarization) == (checked ? .passed : .notRun), "\(step)")
      #expect(report.cleanedUp, "\(step)")
      #expect(try Support.names(folder).isEmpty, "\(step)")
    } // End of loop over the changes
  } // End of func bundleReplacedAroundTheChecksIsRefused()

  /// A digest mismatch: the download passed, the digest failed, nothing after it ran, nothing
  /// left.
  @Test func digestMismatchStopsEverything() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let checker = FakeUpdateCodeChecker(.passed)
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2", codeChecker: checker
    ).verifyLocalZip(
      atPath: zip.url.path(percentEncoded: false), sha256: String(repeating: "0", count: 64),
      expectedVersion: Self.expected)
    #expect(report.verdict(of: .download) == .passed)
    #expect(report.verdict(of: .digest) == .failed(.download(.digestMismatch)))
    #expect(report.failure?.step == .digest)
    #expect(report.failure?.code == "digestMismatch")
    #expect(report.steps.dropFirst(2).allSatisfy { $0.verdict == .notRun })
    #expect(checker.paths.isEmpty)
    #expect(try Support.names(folder).isEmpty)
  } // End of func digestMismatchStopsEverything()

  /// The code checker's answers map to the signature and notarization steps.
  @Test func codeCheckOutcomes() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let cases: [(UpdateCodeCheckResult, UpdateVerificationStep, UpdateVerificationFailure)] = [
      (.signatureFailed(.otherTeam), .signature, .signature(.otherTeam)),
      (.signatureFailed(.invalid(-67061)), .signature, .signature(.invalid(-67061))),
      (
        .notarizationFailed(.notNotarized(-67050)), .notarization,
        .notarization(.notNotarized(-67050))
      ),
    ]
    for (answer, step, failure) in cases {
      let (staging, folder) = try Support.makeStaging()
      defer { try? FileManager.default.removeItem(at: folder) }
      let report = await UpdateVerifier(
        staging: staging, team: Support.team, runningBuild: "2",
        codeChecker: FakeUpdateCodeChecker(answer)
      ).verifyLocalZip(
        atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
        expectedVersion: Self.expected)
      #expect(report.failure == failure)
      #expect(report.failure?.step == step)
      #expect(report.verdict(of: .signature) == (step == .signature ? .failed(failure) : .passed))
      #expect(report.verdict(of: .versions) == .notRun)
      #expect(try Support.names(folder).isEmpty)
    } // End of loop over the checker's answers
  } // End of func codeCheckOutcomes()

  /// An `extracted` entry that was there before is never removed or written into: the
  /// extraction fails, and only what this run created (the zip) is deleted.
  @Test func neverRemovesWhatItDidNotCreate() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let existing = folder.appending(path: "extracted", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: false)
    try Data("keep".utf8).write(to: existing.appending(path: "keep.txt"))
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed)
    ).verifyLocalZip(
      atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
      expectedVersion: Self.expected)
    #expect(report.failure == .extraction(.folderNotCreated(errno: EEXIST)))
    #expect(try Support.names(folder) == ["extracted"])
    #expect(try Support.names(existing) == ["keep.txt"])
  } // End of func neverRemovesWhatItDidNotCreate()

  /// A read-only folder unpacked from the zip is still removed by the cleanup.
  @Test func cleanupRemovesReadOnlyFolders() async throws {
    let zip = try await Support.makeZip { source in
      let app = source.appending(path: "muxFinder.app", directoryHint: .isDirectory)
      try Support.makeApp(at: app)
      let locked = app.appending(path: "Contents/Locked", directoryHint: .isDirectory)
      try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false)
      try Data("x".utf8).write(to: locked.appending(path: "f"))
      #expect(chmod(locked.path(percentEncoded: false), 0o500) == 0)
    }
    defer {
      chmod(
        zip.folder.appending(path: "source/muxFinder.app/Contents/Locked").path(
          percentEncoded: false), 0o700)
      try? FileManager.default.removeItem(at: zip.folder)
    }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.signatureFailed(.notDeveloperID))
    ).verifyLocalZip(
      atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
      expectedVersion: Self.expected)
    #expect(report.failure == .signature(.notDeveloperID))
    #expect(report.cleanedUp)
    #expect(try Support.names(folder).isEmpty)
  } // End of func cleanupRemovesReadOnlyFolders()

  /// A download through a fake transport, then every step; and one through
  /// `URLSessionUpdateDownloadTransport` over the stub (with a redirect to a GitHub download
  /// host), whose release version differs from the stub app's, so it passes every step up to
  /// the versions.
  @Test func downloadAndVerify() async throws {
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let release = Support.release(tag: "v0.3.0", body: zip.data)
    let transport = FakeUpdateDownloadTransport(.success(zip.data))
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed)
    ).downloadAndVerify(release, transport: transport)
    #expect(report.verifiedBundle?.version == Self.expected)
    #expect(
      transport.assets.map(\.downloadURL.absoluteString)
        == [UpdateSource.assetDownloadURL(forTag: "v0.3.0")])
    #expect(try Support.names(folder) == ["extracted"])

    let tag = Support.uniqueTag()
    let hopKey = Support.uniqueTag()
    let hop = URL(string: "https://release-assets.githubusercontent.com/stub/\(hopKey)/asset")!
    UpdateStubProtocol.register([.redirect(to: hop, status: 302)], key: tag)
    UpdateStubProtocol.register(
      [.http(status: 200, headers: ["Content-Length": "\(zip.data.count)"], body: zip.data)],
      key: hopKey)
    defer {
      UpdateStubProtocol.remove(tag)
      UpdateStubProtocol.remove(hopKey)
    }
    let (stubStaging, stubFolder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: stubFolder) }
    let stubReport = await UpdateVerifier(
      staging: stubStaging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed)
    ).downloadAndVerify(
      Support.release(tag: tag, body: zip.data), transport: UpdateDownloadTests.transport)
    #expect(stubReport.verdict(of: .download) == .passed)
    #expect(stubReport.verdict(of: .notarization) == .passed)
    #expect(stubReport.failure == .versions(.shortVersionNotTag))
    #expect(UpdateStubProtocol.requests(tag).count == 1)
    #expect(UpdateStubProtocol.requests(hopKey).count == 1)
    #expect(try Support.names(stubFolder).isEmpty)
  } // End of func downloadAndVerify()

  /// A failing or cancelled transfer: the download step fails (cancelled counts as such),
  /// nothing after it runs, nothing is left.
  @Test func downloadFailuresAndCancellation() async throws {
    let body = Support.randomData(1_000)
    let release = Support.release(tag: Support.uniqueTag(), body: body)
    for (answer, failure) in [
      (UpdateDownloadFailure.offline, UpdateVerificationFailure.download(.offline)),
      (.httpStatus(404), .download(.httpStatus(404))),
      (.cancelled, .cancelled(.download)),
    ] {
      let (staging, folder) = try Support.makeStaging()
      defer { try? FileManager.default.removeItem(at: folder) }
      let report = await UpdateVerifier(
        staging: staging, team: Support.team, runningBuild: "2",
        codeChecker: FakeUpdateCodeChecker(.passed)
      ).downloadAndVerify(release, transport: FakeUpdateDownloadTransport(.failure(answer)))
      #expect(report.failure == failure)
      #expect(report.failure?.step == .download)
      #expect(report.steps.dropFirst().allSatisfy { $0.verdict == .notRun })
      #expect(try Support.names(folder).isEmpty)
    } // End of loop over the transfer failures
    #expect(UpdateVerificationFailure.cancelled(.download).isCancelled)
    #expect(UpdateVerificationFailure.download(.cancelled).isCancelled)
    #expect(!UpdateVerificationFailure.download(.offline).isCancelled)

    // A task cancelled before it starts writes nothing.
    let zip = try await Self.stubZip()
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let task = Task {
      while !Task.isCancelled { await Task.yield() }
      return await UpdateVerifier(
        staging: staging, team: Support.team, runningBuild: "2",
        codeChecker: FakeUpdateCodeChecker(.passed)
      ).downloadAndVerify(
        Support.release(tag: "v0.3.0", body: zip.data),
        transport: FakeUpdateDownloadTransport(.success(zip.data)))
    }
    task.cancel()
    let report = await task.value
    #expect(report.failure?.isCancelled == true)
    #expect(try Support.names(folder).isEmpty)
  } // End of func downloadFailuresAndCancellation()
}
