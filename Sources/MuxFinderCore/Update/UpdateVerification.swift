import Darwin
import Foundation

/// The steps from a release offer to a verified bundle (PLAN.md D39, I-13b1), in order.
public enum UpdateVerificationStep: String, Sendable, Hashable, CaseIterable {
  /// The transfer into the staging folder (the probe's zip mode: the copy), with its exact
  /// size.
  case download
  /// The file's SHA-256 against the release's digest.
  case digest
  /// `ditto -x -k` into a fresh folder.
  case extraction
  /// One `muxFinder.app`, a real folder, and the bounded walk of its tree.
  case shape
  /// The signature and the requirement: identifier, Developer ID, team.
  case signature
  /// The requirement's `notarized` clause.
  case notarization
  /// `CFBundleIdentifier`, `CFBundleShortVersionString` and `CFBundleVersion`.
  case versions
}

/// Why the verification stopped (PLAN.md D39, I-13b1). `code` is the step's machine-readable
/// problem; `reason` a short English phrase for "Couldn't update: …", with no path, host or
/// Team ID.
public enum UpdateVerificationFailure: Error, Sendable, Hashable {
  /// The download or the copy failed (a digest mismatch is the `digest` step's).
  case download(UpdateDownloadFailure)
  /// Unpacking failed.
  case extraction(UpdateExtractionFailure)
  /// The unpacked contents have the wrong shape.
  case shape(UpdateShapeProblem)
  /// The signature or the requirement refused the bundle.
  case signature(UpdateSignatureProblem)
  /// The bundle is not notarized.
  case notarization(UpdateNotarizationProblem)
  /// The bundle's versions refused it.
  case versions(UpdateVersionProblem)
  /// The folder at the bundle's path was no longer the one the shape walk accepted when this
  /// step checked (renamed, replaced, or not a real folder any more).
  case bundleChanged(UpdateVerificationStep)
  /// The update was cancelled before this step.
  case cancelled(UpdateVerificationStep)

  /// The step that failed.
  public var step: UpdateVerificationStep {
    switch self {
    case .download(.digestMismatch): return .digest
    case .download: return .download
    case .extraction: return .extraction
    case .shape: return .shape
    case .signature: return .signature
    case .notarization: return .notarization
    case .versions: return .versions
    case .bundleChanged(let step): return step
    case .cancelled(let step): return step
    }
  } // End of var step

  /// The step's machine-readable problem.
  public var code: String {
    switch self {
    case .download(let failure): return failure.code
    case .extraction(let failure): return failure.code
    case .shape(let problem): return problem.code
    case .signature(let problem): return problem.code
    case .notarization(let problem): return problem.code
    case .versions(let problem): return problem.code
    case .bundleChanged: return "bundleChanged"
    case .cancelled: return "cancelled"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .download(let failure): return failure.reason
    case .extraction(let failure): return failure.reason
    case .shape(let problem): return problem.reason
    case .signature(let problem): return problem.reason
    case .notarization(let problem): return problem.reason
    case .versions(let problem): return problem.reason
    case .bundleChanged: return "the download changed while it was being checked"
    case .cancelled: return "the update was cancelled"
    }
  } // End of var reason

  /// Whether the update was cancelled rather than refused.
  public var isCancelled: Bool {
    switch self {
    case .cancelled, .download(.cancelled), .extraction(.cancelled): return true
    default: return false
    }
  }
}

/// One step's verdict.
public enum UpdateStepVerdict: Sendable, Hashable {
  /// The step passed.
  case passed
  /// The step failed.
  case failed(UpdateVerificationFailure)
  /// A step before it failed, so it did not run.
  case notRun
}

/// One step and its verdict.
public struct UpdateStepResult: Sendable, Hashable {
  /// The step.
  public let step: UpdateVerificationStep
  /// Its verdict.
  public let verdict: UpdateStepVerdict
}

/// The bundle that passed every step, kept in the staging folder.
public struct UpdateVerifiedBundle: Sendable, Hashable {
  /// Its absolute path.
  public let path: String
  /// Its path inside the staging folder (`extracted/muxFinder.app`).
  public let relativePath: String
  /// Its `CFBundleShortVersionString`.
  public let version: UpdateVersion
  /// Its `CFBundleVersion`.
  public let build: Int
  /// The identity (device and inode) of the folder the shape walk accepted, the code check
  /// checked at this path and the versions were read from. I-13b2 compares the folder at the
  /// path against it again, and runs the code check on it again, right before the swap.
  public let identity: UpdateBundleIdentity
}

/// What the verification came to.
public enum UpdateVerificationOutcome: Sendable, Hashable {
  /// Every step passed.
  case verified(UpdateVerifiedBundle)
  /// A step failed; the steps after it did not run.
  case failed(UpdateVerificationFailure)
}

/// The verification's report: every step's verdict, in order, and the outcome.
public struct UpdateVerificationReport: Sendable, Hashable {
  /// Every step, in `UpdateVerificationStep` order.
  public let steps: [UpdateStepResult]
  /// The outcome.
  public let outcome: UpdateVerificationOutcome
  /// Whether everything the verification wrote is gone except, on success, the verified
  /// bundle.
  public let cleanedUp: Bool
  /// The zip's size in bytes, once it was downloaded or copied with the expected digest.
  public let zipSize: Int?
  /// What the shape walk counted, once it passed.
  public let shape: UpdateBundleShape.Summary?

  /// The verdict of `step`.
  public func verdict(of step: UpdateVerificationStep) -> UpdateStepVerdict {
    steps.first { $0.step == step }?.verdict ?? .notRun
  }

  /// The verified bundle, when every step passed.
  public var verifiedBundle: UpdateVerifiedBundle? {
    if case .verified(let bundle) = outcome { return bundle }
    return nil
  }

  /// The failure, when a step failed.
  public var failure: UpdateVerificationFailure? {
    if case .failed(let failure) = outcome { return failure }
    return nil
  }
}

/// From a release offer (or, in the probe's zip mode, a local zip with its digest) to a
/// verified `muxFinder.app` in the staging folder (PLAN.md D39, I-13b1): the download with its
/// size and SHA-256 (`UpdateDownloader`), the archive check and `ditto -x -k` under its
/// watchdog into a fresh `extracted` folder (`UpdateExtractor`), the shape
/// (`UpdateBundleShape`), the signature, requirement and notarization (`UpdateCodeChecking`),
/// then the versions (`UpdateBundleVersions`). The first failure stops the steps after it and
/// deletes everything the verification wrote in the staging folder; on success only the zip is
/// deleted and `extracted/muxFinder.app` is kept. It never installs, moves, launches or opens
/// anything. A cancelled task stops it at the next step (the download and `ditto` stop at
/// once).
///
/// The result is bound to the bundle that was checked: the shape walk's open `muxFinder.app`
/// folder stays open and its identity (`UpdateBundleIdentity`) is recorded; the folder at the
/// bundle's path must have that identity right before and right after the code check (which
/// takes the path) and after the versions are read, and the versions are read through the open
/// folder, never a path resolved again. A renamed or replaced bundle fails with
/// `bundleChanged`. The verified bundle carries the identity for I-13b2.
public struct UpdateVerifier: Sendable {
  /// The folder `ditto` unpacks into, inside the staging folder.
  public static let extractionFolderName = "extracted"

  /// The staging folder.
  public let staging: UpdateStagingFolder
  /// The team the bundle must be signed by (I-13b2 passes the running app's).
  public let team: UpdateTeamID
  /// The running app's `CFBundleVersion`.
  public let runningBuild: String?
  /// Checks the archive and runs `ditto`.
  let extractor: UpdateExtractor
  /// Checks the signature.
  let codeChecker: any UpdateCodeChecking
  /// The shape walk's bounds.
  let shapeLimits: UpdateBundleShape.Limits
  /// Tests only: called with `.signature` right before the identity check that precedes the
  /// code check, and with `.versions` right before the versions are read.
  var checkpoint: (@Sendable (UpdateVerificationStep) async -> Void)?

  /// A verifier working in `staging` for a bundle signed by `team`, newer than the build
  /// `runningBuild`.
  public init(
    staging: UpdateStagingFolder,
    team: UpdateTeamID,
    runningBuild: String?,
    processRunner: any ProcessRunner = PosixSpawnProcessRunner(),
    codeChecker: any UpdateCodeChecking = SecurityUpdateCodeChecker(),
    shapeLimits: UpdateBundleShape.Limits = .standard,
    archiveLimits: UpdateArchiveLimits = .standard
  ) {
    self.staging = staging
    self.team = team
    self.runningBuild = runningBuild
    self.extractor = UpdateExtractor(runner: processRunner, limits: archiveLimits)
    self.codeChecker = codeChecker
    self.shapeLimits = shapeLimits
  } // End of init(staging:team:runningBuild:processRunner:codeChecker:shapeLimits:…)

  /// The verified bundle's path inside the staging folder.
  public static var bundleRelativePath: String {
    extractionFolderName + "/" + UpdateBundleShape.appName
  }

  /// Downloads `release`'s asset through `transport` and verifies it.
  public func downloadAndVerify(
    _ release: UpdateRelease,
    transport: any UpdateDownloadTransport,
    progress: @escaping @Sendable (UpdateDownloadProgress) -> Void = { _ in }
  ) async -> UpdateVerificationReport {
    let downloaded = await UpdateDownloader(transport: transport).download(
      release, into: staging, progress: progress)
    return await verify(downloaded, expected: release.version)
  }

  /// Copies the local zip at `source` in, checks it against `sha256` (lowercase hex), and
  /// verifies it as the release `expectedVersion` (the probe's zip mode).
  public func verifyLocalZip(
    atPath source: String, sha256: String, expectedVersion: UpdateVersion
  ) async -> UpdateVerificationReport {
    let copied = UpdateDownloader.copyLocalFile(
      atPath: source, expectedSHA256: sha256, into: staging)
    return await verify(copied, expected: expectedVersion)
  }

  /// What one run has done so far.
  struct Run {
    /// Verdicts so far, in order.
    var verdicts: [UpdateVerificationStep: UpdateStepVerdict] = [:]
    /// Names this run created in the staging folder, in order.
    var created: [String] = []
    /// The zip's size.
    var zipSize: Int?
    /// The shape walk's summary.
    var shape: UpdateBundleShape.Summary?
  }

  /// Runs the steps after the download or copy.
  func verify(_ downloaded: UpdateDownloadResult, expected: UpdateVersion) async
    -> UpdateVerificationReport
  {
    var run = Run()
    let file: UpdateDownloadedFile
    switch downloaded {
    case .failed(.digestMismatch):
      run.verdicts[.download] = .passed
      return finish(&run, failure: .download(.digestMismatch))
    case .failed(.cancelled):
      return finish(&run, failure: .cancelled(.download))
    case .failed(let failure):
      return finish(&run, failure: .download(failure))
    case .downloaded(let downloadedFile):
      file = downloadedFile
    }
    run.created.append(file.name)
    run.zipSize = file.size
    run.verdicts[.download] = .passed
    run.verdicts[.digest] = .passed
    if let failure = await extract(file, run: &run) { return finish(&run, failure: failure) }
    run.verdicts[.extraction] = .passed
    if Task.isCancelled { return finish(&run, failure: .cancelled(.shape)) }
    let app: UpdateBundleShape.OpenedApp
    switch checkShape() {
    case .failure(let failure):
      return finish(&run, failure: failure)
    case .success(let checked):
      app = checked.app
      run.shape = checked.summary
    }
    defer { Darwin.close(app.descriptor) }
    run.verdicts[.shape] = .passed
    return await verifyChecked(app, file: file, expected: expected, run: &run)
  } // End of func verify(_:expected:)

  /// The steps after the shape walk accepted `app` (open, with its identity): the code check
  /// bracketed by identity checks, then the versions read through `app`, then the last
  /// identity check.
  func verifyChecked(
    _ app: UpdateBundleShape.OpenedApp, file: UpdateDownloadedFile, expected: UpdateVersion,
    run: inout Run
  ) async -> UpdateVerificationReport {
    if Task.isCancelled { return finish(&run, failure: .cancelled(.signature)) }
    await checkpoint?(.signature)
    guard isStillChecked(app.identity) else {
      return finish(&run, failure: .bundleChanged(.signature))
    }
    let codeCheck = await codeChecker.check(
      bundleAt: staging.path(of: Self.bundleRelativePath), team: team)
    guard isStillChecked(app.identity) else {
      return finish(&run, failure: .bundleChanged(.signature))
    }
    switch codeCheck {
    case .signatureFailed(let problem): return finish(&run, failure: .signature(problem))
    case .notarizationFailed(let problem):
      run.verdicts[.signature] = .passed
      return finish(&run, failure: .notarization(problem))
    case .passed:
      run.verdicts[.signature] = .passed
      run.verdicts[.notarization] = .passed
    }
    if Task.isCancelled { return finish(&run, failure: .cancelled(.versions)) }
    await checkpoint?(.versions)
    let versions = checkVersions(app: app.descriptor, expected: expected)
    guard isStillChecked(app.identity) else {
      return finish(&run, failure: .bundleChanged(.versions))
    }
    switch versions {
    case .failure(let problem): return finish(&run, failure: .versions(problem))
    case .success(let facts):
      run.verdicts[.versions] = .passed
      let bundle = UpdateVerifiedBundle(
        path: staging.path(of: Self.bundleRelativePath), relativePath: Self.bundleRelativePath,
        version: facts.version, build: facts.build, identity: app.identity)
      let removed = staging.remove(named: file.name)
      return report(run, outcome: .verified(bundle), cleanedUp: removed)
    }
  } // End of func verifyChecked(_:file:expected:run:)

  /// Creates the fresh extraction folder and runs the extractor into it; the failure, or
  /// `nil`.
  func extract(_ file: UpdateDownloadedFile, run: inout Run) async -> UpdateVerificationFailure? {
    if Task.isCancelled { return .cancelled(.extraction) }
    do throws(UpdateStagingFileError) {
      try staging.createFolder(named: Self.extractionFolderName)
    } catch {
      return .extraction(.folderNotCreated(errno: error.errnoValue))
    }
    run.created.append(Self.extractionFolderName)
    let result = await extractor.extract(
      zip: staging.path(of: file.name), into: staging.path(of: Self.extractionFolderName))
    if case .failure(let failure) = result { return .extraction(failure) }
    return nil
  } // End of func extract(_:run:)

  /// The shape walk over the extraction folder: on success, the open `muxFinder.app` folder
  /// that was walked (the caller closes it) with its identity, and the walk's summary.
  func checkShape() -> Result<
    (app: UpdateBundleShape.OpenedApp, summary: UpdateBundleShape.Summary),
    UpdateVerificationFailure
  > {
    let folder: Int32
    do throws(UpdateStagingFileError) {
      folder = try staging.openFolder(atRelativePath: Self.extractionFolderName)
    } catch {
      return .failure(.shape(.unreadable(errno: error.errnoValue)))
    }
    defer { Darwin.close(folder) }
    let app: UpdateBundleShape.OpenedApp
    switch UpdateBundleShape.openApp(in: folder) {
    case .failure(let problem): return .failure(.shape(problem))
    case .success(let opened): app = opened
    }
    switch UpdateBundleShape.checkTree(app: app.descriptor, limits: shapeLimits) {
    case .failure(let problem):
      Darwin.close(app.descriptor)
      return .failure(.shape(problem))
    case .success(let summary):
      return .success((app, summary))
    }
  } // End of func checkShape()

  /// Whether the folder at the bundle's path is still the real folder with `identity`.
  func isStillChecked(_ identity: UpdateBundleIdentity) -> Bool {
    (try? staging.folderIdentity(atRelativePath: Self.bundleRelativePath)) == identity
  }

  /// Reads `Contents/Info.plist` through the open, checked app folder `app` and checks its
  /// versions.
  func checkVersions(app: Int32, expected: UpdateVersion) -> Result<
    UpdateBundleVersionFacts, UpdateVersionProblem
  > {
    guard let info = UpdateBundleVersions.readInfo(app: app) else {
      return .failure(.infoUnreadable)
    }
    return UpdateBundleVersions.check(info: info, expected: expected, runningBuild: runningBuild)
  }

  /// Records `failure`, deletes everything this run created, and returns the report.
  func finish(_ run: inout Run, failure: UpdateVerificationFailure) -> UpdateVerificationReport {
    run.verdicts[failure.step] = .failed(failure)
    var removed = true
    for name in run.created.reversed() where !staging.remove(named: name) {
      removed = false
    } // End of loop over the names this run created
    return report(run, outcome: .failed(failure), cleanedUp: removed)
  }

  /// The report of `run`.
  func report(_ run: Run, outcome: UpdateVerificationOutcome, cleanedUp: Bool)
    -> UpdateVerificationReport
  {
    let steps = UpdateVerificationStep.allCases.map {
      UpdateStepResult(step: $0, verdict: run.verdicts[$0] ?? .notRun)
    }
    return UpdateVerificationReport(
      steps: steps, outcome: outcome, cleanedUp: cleanedUp, zipSize: run.zipSize,
      shape: run.shape)
  }
}
