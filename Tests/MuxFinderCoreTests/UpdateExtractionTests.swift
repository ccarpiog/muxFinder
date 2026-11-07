import Darwin
import Foundation
import Testing

@testable import MuxFinderCore

/// Unpacking and the shape check (PLAN.md D39, I-13b1): `ditto`'s argv and how its ends map,
/// synthetic zips built with `ditto -c -k` in private folders and run through the verifier
/// (with a passing fake code checker, so only the archive check and the shape decide) — two
/// apps, no app (only a file or a folder; nothing unpacked; an empty zip), a wrong name, an
/// extra top-level file (all refused by the archive check before `ditto` runs), the app as a
/// file or a link, links out (absolute, by `..`, through another link), links inside — the
/// bounds, and the top level and a FIFO in hand-made trees. Every refusal leaves the staging
/// folder empty.
@Suite("Update extraction")
struct UpdateExtractionTests {
  /// Shorthand.
  typealias Support = UpdateVerifyTestSupport

  /// Builds a zip with `build`, verifies it in a new staging folder with a passing fake code
  /// checker, and returns the report and the staging folder's names afterwards.
  static func verify(
    limits: UpdateBundleShape.Limits = .standard,
    keepParent: Bool = false,
    _ build: (URL) throws -> Void
  ) async throws -> (UpdateVerificationReport, [String]) {
    let zip = try await Support.makeZip(keepParent: keepParent, build)
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let verifier = UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed), shapeLimits: limits)
    let report = await verifier.verifyLocalZip(
      atPath: zip.url.path(percentEncoded: false), sha256: Support.sha256(zip.data),
      expectedVersion: UpdateVersion("0.3.0")!)
    return (report, try Support.names(folder))
  } // End of static func verify(limits:keepParent:_:)

  /// The app in `source`.
  static func app(_ source: URL) -> URL {
    source.appending(path: "muxFinder.app", directoryHint: .isDirectory)
  }

  /// A well-formed app passes the shape (and, with the fake checker, everything).
  @Test func wellFormedAppPasses() async throws {
    let (report, names) = try await Self.verify { source in
      try Support.makeApp(at: Self.app(source))
      try FileManager.default.createSymbolicLink(
        atPath: Self.app(source).appending(path: "Contents/Current").path(percentEncoded: false),
        withDestinationPath: "MacOS")
      try FileManager.default.createSymbolicLink(
        atPath: Self.app(source).appending(path: "Contents/MacOS/root").path(percentEncoded: false),
        withDestinationPath: "../..")
    }
    #expect(report.verifiedBundle?.relativePath == "extracted/muxFinder.app")
    #expect(report.verdict(of: .shape) == .passed)
    #expect(report.shape?.symbolicLinks == 2)
    #expect(report.shape?.entries == 8)
    #expect(names == ["extracted"])
  } // End of func wellFormedAppPasses()

  /// Each wrong shape fails the shape step with its problem, and leaves nothing.
  @Test func wrongShapesAreRefused() async throws {
    let manager = FileManager.default
    let outside = UpdateVerificationFailure.extraction(.archive(.outsideApp))
    let cases: [(String, UpdateVerificationFailure, (URL) throws -> Void)] = [
      (
        "two apps", outside,
        { source in
          try Support.makeApp(at: Self.app(source))
          try Support.makeApp(at: source.appending(path: "Other.app", directoryHint: .isDirectory))
        }
      ),
      (
        "no app, only a file", outside,
        { source in try Data("x".utf8).write(to: source.appending(path: "readme.txt")) }
      ),
      (
        "no app, only a folder", outside,
        { source in
          try FileManager.default.createDirectory(
            at: source.appending(path: "Contents", directoryHint: .isDirectory),
            withIntermediateDirectories: false)
          try Data("x".utf8).write(to: source.appending(path: "Contents/Info.plist"))
        }
      ),
      (
        "wrong name", outside,
        { source in
          try Support.makeApp(
            at: source.appending(path: "MuxFinder.app", directoryHint: .isDirectory))
        }
      ),
      (
        "another app's name", outside,
        { source in
          try Support.makeApp(at: source.appending(path: "Other.app", directoryHint: .isDirectory))
        }
      ),
      (
        "extra top-level file", outside,
        { source in
          try Support.makeApp(at: Self.app(source))
          try Data("x".utf8).write(to: source.appending(path: "README"))
        }
      ),
      (
        "app is a file", .shape(.appNotADirectory),
        { source in try Data("x".utf8).write(to: source.appending(path: "muxFinder.app")) }
      ),
      (
        "app is a link", .shape(.appNotADirectory),
        { source in
          // The only top-level entry, a link (dangling here; it is never followed).
          try manager.createSymbolicLink(
            atPath: source.appending(path: "muxFinder.app", directoryHint: .notDirectory)
              .path(percentEncoded: false),
            withDestinationPath: "../elsewhere.app")
        }
      ),
      (
        "absolute link", .shape(.symbolicLinkAbsolute),
        { source in
          try Support.makeApp(at: Self.app(source))
          try manager.createSymbolicLink(
            atPath: Self.app(source).appending(path: "Contents/etc").path(percentEncoded: false),
            withDestinationPath: "/etc")
        }
      ),
      (
        "link out by ..", .shape(.symbolicLinkEscapes),
        { source in
          try Support.makeApp(at: Self.app(source))
          try manager.createSymbolicLink(
            atPath: Self.app(source).appending(path: "Contents/MacOS/out").path(
              percentEncoded: false),
            withDestinationPath: "../../../outside")
        }
      ),
      (
        "link out through a link", .shape(.symbolicLinkEscapes),
        { source in
          try Support.makeApp(at: Self.app(source))
          // Contents/MacOS/up leads to Contents (inside); Contents/escape climbs out through it
          // (lexically Contents, physically the folder above the app).
          try manager.createSymbolicLink(
            atPath: Self.app(source).appending(path: "Contents/MacOS/up").path(
              percentEncoded: false),
            withDestinationPath: "..")
          try manager.createSymbolicLink(
            atPath: Self.app(source).appending(path: "Contents/escape").path(percentEncoded: false),
            withDestinationPath: "MacOS/up/../..")
        }
      ),
    ]
    for (name, failure, build) in cases {
      let (report, names) = try await Self.verify(build)
      #expect(report.failure == failure, "\(name)")
      let refusedByShape = failure.step == .shape
      #expect(report.verdict(of: .extraction) == (refusedByShape ? .passed : .failed(failure)))
      #expect(report.verdict(of: .shape) == (refusedByShape ? .failed(failure) : .notRun))
      #expect(report.verdict(of: .signature) == .notRun, "\(name)")
      #expect(names.isEmpty, "\(name)")
      #expect(report.cleanedUp, "\(name)")
    } // End of loop over wrong shapes
  } // End of func wrongShapesAreRefused()

  /// The walk's bounds: entries, bytes and depth.
  @Test func boundsAreEnforced() async throws {
    let small = UpdateBundleShape.Limits(maximumEntries: 5, maximumBytes: 1 << 30, maximumDepth: 32)
    let (entries, entryNames) = try await Self.verify(limits: small) { source in
      try Support.makeApp(at: Self.app(source))
    }
    #expect(entries.failure == .shape(.tooManyEntries))
    #expect(entryNames.isEmpty)

    let tight = UpdateBundleShape.Limits(maximumEntries: 100, maximumBytes: 1_000, maximumDepth: 32)
    let (bytes, _) = try await Self.verify(limits: tight) { source in
      try Support.makeApp(at: Self.app(source))
    }
    #expect(bytes.failure == .shape(.tooLarge))

    let shallow = UpdateBundleShape.Limits(
      maximumEntries: 100, maximumBytes: 1 << 30, maximumDepth: 2)
    let (depth, _) = try await Self.verify(limits: shallow) { source in
      try Support.makeApp(at: Self.app(source))
      try FileManager.default.createDirectory(
        at: Self.app(source).appending(path: "Contents/a/b/c", directoryHint: .isDirectory),
        withIntermediateDirectories: true)
    }
    #expect(depth.failure == .shape(.tooDeep))
    #expect(UpdateBundleShape.Limits.standard.maximumEntries == 10_000)
    #expect(UpdateBundleShape.Limits.standard.maximumBytes == 256 << 20)
  } // End of func boundsAreEnforced()

  /// Nothing unpacked is `noApp` (`ditto` itself refuses an empty zip, so this is a hand-made
  /// empty folder), and an empty zip fails the extraction with nothing left.
  @Test func noAppAndEmptyZip() async throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let descriptor = open(folder.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    defer { close(descriptor) }
    guard case .failure(.noApp) = UpdateBundleShape.check(folder: descriptor) else {
      Issue.record("an empty folder passed the shape check")
      return
    }
    // The 22-byte end-of-central-directory record alone: a zip with no entries.
    let empty = Data([0x50, 0x4B, 0x05, 0x06] + Array(repeating: 0, count: 18))
    let source = folder.appending(path: "empty.zip")
    try empty.write(to: source)
    let (staging, stagingFolder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: stagingFolder) }
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed)
    ).verifyLocalZip(
      atPath: source.path(percentEncoded: false), sha256: Support.sha256(empty),
      expectedVersion: UpdateVersion("0.3.0")!)
    #expect(report.failure?.step == .extraction)
    #expect(try Support.names(stagingFolder).isEmpty)
  } // End of func noAppAndEmptyZip()

  /// The shape's top-level rules in hand-made trees (the archive check refuses such zips
  /// before `ditto` runs, so these are made by hand): two entries, another name, another
  /// case.
  @Test func topLevelInHandMadeTrees() throws {
    let cases: [(String, UpdateShapeProblem, (URL) throws -> Void)] = [
      (
        "two apps", .extraEntries,
        { folder in
          try Support.makeApp(at: Self.app(folder))
          try Support.makeApp(at: folder.appending(path: "Other.app", directoryHint: .isDirectory))
        }
      ),
      (
        "an extra file", .extraEntries,
        { folder in
          try Support.makeApp(at: Self.app(folder))
          try Data("x".utf8).write(to: folder.appending(path: "README"))
        }
      ),
      (
        "another name", .wrongName,
        { folder in
          try Support.makeApp(at: folder.appending(path: "Other.app", directoryHint: .isDirectory))
        }
      ),
    ]
    for (name, problem, build) in cases {
      let folder = try UpdateTestSupport.makePrivateFolder()
      defer { try? FileManager.default.removeItem(at: folder) }
      try build(folder)
      let descriptor = open(folder.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
      defer { close(descriptor) }
      guard case .failure(let found) = UpdateBundleShape.check(folder: descriptor) else {
        Issue.record("\(name) passed the shape check")
        continue
      }
      #expect(found == problem, "\(name)")
    } // End of loop over the hand-made trees
  } // End of func topLevelInHandMadeTrees()

  /// A FIFO (which `ditto` would write as a regular file) in a hand-made tree is refused
  /// without being opened.
  @Test func unsupportedEntryInATree() throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    try Support.makeApp(at: Self.app(folder))
    #expect(
      mkfifo(Self.app(folder).appending(path: "Contents/pipe").path(percentEncoded: false), 0o600)
        == 0)
    let descriptor = open(folder.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    defer { close(descriptor) }
    guard case .failure(.unsupportedEntry) = UpdateBundleShape.check(folder: descriptor) else {
      Issue.record("a FIFO passed the shape check")
      return
    }
  } // End of func unsupportedEntryInATree()

  /// The link rule on its own.
  @Test func linkRule() throws {
    let folder = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let root = open(folder.path(percentEncoded: false), O_RDONLY | O_DIRECTORY)
    defer { close(root) }
    try FileManager.default.createDirectory(
      at: folder.appending(path: "Contents/MacOS"), withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(
      atPath: folder.appending(path: "Contents/MacOS/up").path(percentEncoded: false),
      withDestinationPath: "..")
    let check = { (target: String, components: [String]) in
      UpdateBundleShape.linkProblem(target: target, components: components, root: root)
    }
    #expect(check("MacOS", ["Contents"]) == nil)
    #expect(check("./MacOS//x", ["Contents"]) == nil)
    #expect(check("..", ["Contents"]) == nil)
    #expect(check("../..", ["Contents"]) == .symbolicLinkEscapes)
    #expect(check("../Contents/../..", ["Contents"]) == .symbolicLinkEscapes)
    #expect(check("/Applications", ["Contents"]) == .symbolicLinkAbsolute)
    #expect(check("", ["Contents"]) == .symbolicLinkEscapes)
    #expect(check("MacOS/up/..", ["Contents"]) == .symbolicLinkEscapes)
    #expect(check("MacOS/missing/..", ["Contents"]) == nil)
  } // End of func linkRule()

  /// The failure in `result`, or `nil` when it succeeded.
  static func failure(of result: Result<Void, UpdateExtractionFailure>) -> UpdateExtractionFailure?
  {
    if case .failure(let failure) = result { return failure }
    return nil
  }

  /// `ditto`'s argv, environment and time bound, and how its ends map (no process runs; the
  /// zip is a real stub zip, which the archive check passes, and the destination a private
  /// empty folder).
  @Test func dittoInvocation() async throws {
    let zip = try await Support.makeZip { source in try Support.makeApp(at: Self.app(source)) }
    defer { try? FileManager.default.removeItem(at: zip.folder) }
    let destination = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: destination) }
    let zipPath = zip.url.path(percentEncoded: false)
    let into = destination.path(percentEncoded: false)
    let ok = RecordingProcessRunner(.result(ProcessResult(processID: 1, termination: .exited(0))))
    let passed = await UpdateExtractor(runner: ok).extract(zip: zipPath, into: into)
    #expect(Self.failure(of: passed) == nil)
    let request = ok.requests.first
    #expect(request?.executableURL.path(percentEncoded: false) == "/usr/bin/ditto")
    #expect(request?.arguments == ["-x", "-k", zipPath, into])
    #expect(request?.environment == ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"])
    #expect(request?.timeout == .seconds(120))
    let cases: [(RecordingProcessRunner.Answer, UpdateExtractionFailure)] = [
      (.result(ProcessResult(processID: 1, termination: .exited(1))), .exited(1)),
      (.result(ProcessResult(processID: 1, termination: .signaled(9))), .signaled(9)),
      (.result(ProcessResult(processID: 1, termination: .signaled(15), timedOut: true)), .timedOut),
      (.cancel, .cancelled),
      (.startFailure, .notStarted),
    ]
    for (answer, failure) in cases {
      let result = await UpdateExtractor(runner: RecordingProcessRunner(answer)).extract(
        zip: zipPath, into: into)
      #expect(Self.failure(of: result) == failure, "\(failure)")
    } // End of loop over the runner's answers
    // A missing destination is refused before `ditto` runs.
    let unused = RecordingProcessRunner(.cancel)
    let missing = await UpdateExtractor(runner: unused).extract(
      zip: zipPath, into: into + "missing")
    #expect(Self.failure(of: missing) == .folderUnreadable(errno: ENOENT))
    #expect(unused.requests.isEmpty)
  } // End of func dittoInvocation()

  /// Bytes that are not a zip (with a matching digest) fail the extraction (the archive check
  /// finds no end record) and leave nothing.
  @Test func notAZipFailsExtraction() async throws {
    let base = try UpdateTestSupport.makePrivateFolder()
    defer { try? FileManager.default.removeItem(at: base) }
    let body = Support.randomData(4_096)
    let source = base.appending(path: "release.zip")
    try body.write(to: source)
    let (staging, folder) = try Support.makeStaging()
    defer { try? FileManager.default.removeItem(at: folder) }
    let report = await UpdateVerifier(
      staging: staging, team: Support.team, runningBuild: "2",
      codeChecker: FakeUpdateCodeChecker(.passed)
    ).verifyLocalZip(
      atPath: source.path(percentEncoded: false), sha256: Support.sha256(body),
      expectedVersion: UpdateVersion("0.3.0")!)
    #expect(report.failure == .extraction(.archive(.malformed)))
    #expect(report.verdict(of: .digest) == .passed)
    #expect(report.verdict(of: .shape) == .notRun)
    #expect(try Support.names(folder).isEmpty)
  } // End of func notAZipFailsExtraction()
}
