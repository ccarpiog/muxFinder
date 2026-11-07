import Darwin
import Foundation

/// `muxfinder-probe update verify …` (PLAN.md D39, I-13b1): the arguments, the run and the
/// JSON output, over injected transports, process runner and code checker so tests never send
/// a request. The zip mode copies a local zip into `--into` and runs every step but the
/// network; the latest mode first sends `update check`'s request, then downloads the asset.
/// It never installs, swaps, launches or opens anything.
public enum UpdateVerifyProbe {
  /// Usage lines for `update verify`.
  public static let usage = """
      update verify --into <dir> --team-id <id> (--zip <file> --sha256 <hex>
                    --expect-version <x.y.z> | --latest) [--running-build <n>]
          Verify a muxFinder release zip as the one-click update would, without installing
          it: the size and SHA-256, ditto -x -k into <dir>/extracted, exactly one
          muxFinder.app with no link leading out of it, the Developer ID signature of the
          given team with the notarization, then its versions; and print each step's verdict
          as JSON (never the Team ID, never a path in your home). The verified app is left at
          <dir>/extracted/muxFinder.app; everything else written there is deleted, and on a
          failure everything. Exit 0 every check passed, 1 a check failed, 64 usage.
          --into            An existing empty private folder of yours (absolute, under
                            /private/tmp or /private/var/folders, no symbolic link on its
                            path, no permission for group or others, no access control list,
                            such as one from mktemp -d /private/tmp/mfx.XXXXXX).
          --team-id         The Team ID the release must be signed by (10 uppercase letters
                            or digits).
          --zip             A local release zip (absolute path, at most 50 MiB), copied into
                            --into; contacts no server. Needs --sha256 (its SHA-256, 64 hex
                            characters, or sha256:<hex>) and --expect-version (the release's
                            version, such as 0.2.0).
          --latest          Ask GitHub for the latest release as update check does, then
                            download its muxFinder.zip from GitHub. It contacts github.com, so
                            its real run is the user's, never an unattended run's.
          --running-build   The build the release must be newer than (default 0).
    """

  /// The running build used without `--running-build`.
  public static let defaultRunningBuild = "0"
  /// The running version of the latest mode's check (and its `User-Agent`).
  public static let checkRunningVersion = UpdateProbe.defaultRunningVersion
  /// The folders `--into` must be under.
  public static let intoPrefixes = ["/private/tmp/", "/private/var/folders/"]

  /// Where the release comes from.
  public enum Mode: Sendable, Hashable {
    /// A local zip, its SHA-256 (lowercase hex) and the release's version.
    case zip(path: String, sha256: String, expectedVersion: UpdateVersion)
    /// GitHub's latest release.
    case latest
  }

  /// Parsed options of `update verify`.
  public struct Options: Sendable, Hashable {
    /// The staging folder.
    public var into: String
    /// The team.
    public var team: UpdateTeamID
    /// Where the release comes from.
    public var mode: Mode
    /// The build the release must be newer than.
    public var runningBuild: String
  }

  /// What the run needs besides the check transport: made per run, replaced in tests.
  public struct Environment: Sendable {
    /// Makes the download transport for the running version.
    public var makeDownloadTransport: @Sendable (String) -> any UpdateDownloadTransport
    /// Runs `ditto`.
    public var processRunner: any ProcessRunner
    /// Checks the signature.
    public var codeChecker: any UpdateCodeChecking

    /// Creates an environment.
    public init(
      makeDownloadTransport: @escaping @Sendable (String) -> any UpdateDownloadTransport,
      processRunner: any ProcessRunner,
      codeChecker: any UpdateCodeChecking
    ) {
      self.makeDownloadTransport = makeDownloadTransport
      self.processRunner = processRunner
      self.codeChecker = codeChecker
    }

    /// The real one: `URLSessionUpdateDownloadTransport`, `PosixSpawnProcessRunner` and
    /// `SecurityUpdateCodeChecker`.
    public static var live: Environment {
      Environment(
        makeDownloadTransport: { URLSessionUpdateDownloadTransport(shortVersion: $0) },
        processRunner: PosixSpawnProcessRunner(),
        codeChecker: SecurityUpdateCodeChecker())
    }
  }

  /// The options that take a value.
  static let valueOptions: Set<String> = [
    "--into", "--team-id", "--zip", "--sha256", "--expect-version", "--running-build",
  ]

  /// Parses the arguments after `verify` (a help flag is handled by the caller).
  public static func parse(_ arguments: ArraySlice<String>) throws(UpdateProbe.UsageError)
    -> Options
  {
    var values: [String: String] = [:]
    var latest = false
    var remaining = arguments
    while let argument = remaining.popFirst() {
      if argument == "--latest" {
        guard !latest else { throw usage("--latest given twice") }
        latest = true
        continue
      }
      guard valueOptions.contains(argument) else { throw usage("unknown option \(argument)") }
      guard values[argument] == nil else { throw usage("\(argument) given twice") }
      guard let value = remaining.popFirst() else { throw usage("\(argument) needs a value") }
      values[argument] = value
    } // End of loop over the options
    guard let into = values["--into"] else { throw usage("verify needs --into") }
    guard let teamText = values["--team-id"] else { throw usage("verify needs --team-id") }
    guard let team = UpdateTeamID(teamText) else {
      throw usage("--team-id needs 10 uppercase letters or digits")
    }
    let runningBuild = values["--running-build"] ?? defaultRunningBuild
    guard UpdateBundleVersions.build(runningBuild) != nil else {
      throw usage("--running-build needs a build number such as 2")
    }
    let zipOptions = ["--zip", "--sha256", "--expect-version"]
    if latest {
      guard zipOptions.allSatisfy({ values[$0] == nil }) else {
        throw usage("--latest takes no --zip, --sha256 or --expect-version")
      }
      return Options(into: into, team: team, mode: .latest, runningBuild: runningBuild)
    }
    guard let zip = values["--zip"], let digestText = values["--sha256"],
      let versionText = values["--expect-version"]
    else { throw usage("verify needs --latest, or --zip with --sha256 and --expect-version") }
    guard zip.hasPrefix("/") else { throw usage("--zip needs an absolute path") }
    guard let digest = sha256(digestText) else {
      throw usage("--sha256 needs 64 hex characters (or sha256:<hex>)")
    }
    guard let version = UpdateVersion(versionText) else {
      throw usage("--expect-version needs a version such as 0.2.0")
    }
    return Options(
      into: into, team: team,
      mode: .zip(path: zip, sha256: digest, expectedVersion: version),
      runningBuild: runningBuild)
  } // End of static func parse(_:)

  /// A usage error with `message`.
  static func usage(_ message: String) -> UpdateProbe.UsageError {
    UpdateProbe.UsageError(message: message)
  }

  /// The lowercase digest in `text`: 64 hex characters, or `sha256:` plus them.
  static func sha256(_ text: String) -> String? {
    UpdateReleaseParser.sha256(text.hasPrefix("sha256:") ? text : "sha256:" + text)
  }

  /// Why `path` cannot be `--into`, or `nil`: `--state`'s rules
  /// (`UpdateProbe.stateDirectoryProblem(_:)`), under `/private/tmp` or `/private/var/folders`,
  /// and empty. Reads only.
  public static func intoProblem(_ path: String) -> String? {
    if let problem = UpdateProbe.stateDirectoryProblem(path) { return problem }
    guard intoPrefixes.contains(where: { path.hasPrefix($0) }) else {
      return "must be a folder under /private/tmp or /private/var/folders"
    }
    let staging: UpdateStagingFolder
    do throws(UpdateStagingProblem) {
      staging = try UpdateStagingFolder(path: path)
    } catch {
      return "cannot be used (\(error.code))"
    }
    guard let names = try? staging.entryNames() else { return "cannot be read" }
    guard names.isEmpty else { return "must be an empty folder" }
    return nil
  } // End of static func intoProblem(_:)

  /// Why the `--zip` file cannot be used, or `nil`: it must exist as a regular file, not a
  /// symbolic link. Reads only.
  static func zipProblem(_ path: String) -> String? {
    var info = stat()
    guard lstat(path, &info) == 0 else { return "names a file that does not exist" }
    if info.st_mode & S_IFMT == S_IFLNK {
      return "is a symbolic link; pass the path it leads to"
    }
    guard info.st_mode & S_IFMT == S_IFREG else { return "is not a regular file" }
    return nil
  }

  /// The latest mode's check facts in the output.
  public struct CheckOutput: Encodable, Sendable, Hashable {
    /// `UpdateCheckOutcome.code`.
    public var outcome: String
    /// The latest release's tag.
    public var latestTag: String?
    /// Whether it has an installable `muxFinder.zip`.
    public var assetPresent: Bool
    /// The asset's size in bytes.
    public var size: Int?
  }

  /// One step in the output.
  public struct StepOutput: Encodable, Sendable, Hashable {
    /// The step's name.
    public var step: String
    /// `passed`, `failed` or `notRun`.
    public var verdict: String
    /// The failure's code.
    public var code: String?
    /// The failure's reason.
    public var reason: String?
  }

  /// The verified bundle in the output.
  public struct BundleOutput: Encodable, Sendable, Hashable {
    /// Its path inside `--into`.
    public var path: String
    /// Its version.
    public var version: String
    /// Its build.
    public var build: Int
  }

  /// The shape walk's counts in the output.
  public struct ShapeOutput: Encodable, Sendable, Hashable {
    /// Entries below `muxFinder.app`.
    public var entries: Int
    /// Bytes in regular files.
    public var bytes: Int
    /// Symbolic links.
    public var symbolicLinks: Int
  }

  /// The JSON printed by `update verify`.
  public struct Output: Encodable, Sendable, Hashable {
    /// `zip` or `latest`.
    public var mode: String
    /// The release's version the bundle must have.
    public var expectedVersion: String?
    /// The build the release must be newer than.
    public var runningBuild: String
    /// The latest mode's check.
    public var check: CheckOutput?
    /// Every step, in order.
    public var steps: [StepOutput]
    /// `verified` or `failed`.
    public var verdict: String
    /// The step that failed.
    public var failedStep: String?
    /// The failure's code.
    public var code: String?
    /// The failure's reason, as after "Couldn't update: ".
    public var reason: String?
    /// The verified bundle.
    public var bundle: BundleOutput?
    /// The zip's size, once its digest matched.
    public var zipSize: Int?
    /// The shape walk's counts, once it passed.
    public var shape: ShapeOutput?
    /// Whether everything written is gone except, on success, the verified bundle.
    public var cleanedUp: Bool
  }

  /// Runs `update verify` with `options` and returns the exit status; `makeCheckTransport` is
  /// called only in the latest mode, once the folder and arguments are usable.
  public static func run(
    _ options: Options,
    makeCheckTransport: (String) -> any UpdateCheckTransport,
    environment: Environment,
    now: () -> Date,
    standardOutput: (String) -> Void,
    standardError: (String) -> Void
  ) async -> Int32 {
    if let problem = intoProblem(options.into) {
      standardError("muxfinder-probe: --into \(problem)")
      return UpdateProbe.usageStatus
    }
    if case .zip(let path, _, _) = options.mode, let problem = zipProblem(path) {
      standardError("muxfinder-probe: --zip \(problem)")
      return UpdateProbe.usageStatus
    }
    let staging: UpdateStagingFolder
    do throws(UpdateStagingProblem) {
      staging = try UpdateStagingFolder(path: options.into)
    } catch {
      standardError("muxfinder-probe: --into cannot be used (\(error.code))")
      return UpdateProbe.usageStatus
    }
    let verifier = UpdateVerifier(
      staging: staging, team: options.team, runningBuild: options.runningBuild,
      processRunner: environment.processRunner, codeChecker: environment.codeChecker)
    let output: Output
    switch options.mode {
    case .zip(let path, let digest, let version):
      let report = await verifier.verifyLocalZip(
        atPath: path, sha256: digest, expectedVersion: version)
      output = makeOutput(
        mode: "zip", expected: version, options: options, check: nil, report: report)
    case .latest:
      output = await latest(
        options, verifier: verifier, makeCheckTransport: makeCheckTransport,
        environment: environment, now: now)
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(output) else {
      standardError("muxfinder-probe: could not encode the output")
      return UpdateProbe.failedStatus
    }
    standardOutput(String(decoding: data, as: UTF8.self))
    return output.verdict == "verified" ? UpdateProbe.answeredStatus : UpdateProbe.failedStatus
  } // End of static func run(_:makeCheckTransport:environment:now:standardOutput:standardError:)

  /// The latest mode: one check, then the download and the rest when it offers an
  /// installable asset.
  static func latest(
    _ options: Options,
    verifier: UpdateVerifier,
    makeCheckTransport: (String) -> any UpdateCheckTransport,
    environment: Environment,
    now: () -> Date
  ) async -> Output {
    let transport = makeCheckTransport(checkRunningVersion)
    let response = await transport.latestRelease(etag: nil)
    var state = UpdateState()
    let outcome = UpdateCheck.apply(
      response, to: &state, runningVersion: checkRunningVersion, now: now())
    let release = outcome.isSuccess ? state.keptRelease : nil
    let check = CheckOutput(
      outcome: outcome.code, latestTag: release?.tag, assetPresent: release?.asset != nil,
      size: release?.asset?.size)
    guard let release, release.asset != nil else {
      var steps = UpdateVerificationStep.allCases.map {
        StepOutput(step: $0.rawValue, verdict: "notRun")
      }
      var failedStep = "check"
      var code = outcome.code
      var reason = "muxFinder couldn't find out which release is the latest"
      if outcome.isSuccess {
        let failure = UpdateDownloadFailure.noInstallableAsset
        (failedStep, code, reason) = ("download", failure.code, failure.reason)
        steps[0] = StepOutput(step: failedStep, verdict: "failed", code: code, reason: reason)
      }
      return Output(
        mode: "latest", expectedVersion: release?.version.description,
        runningBuild: options.runningBuild, check: check, steps: steps, verdict: "failed",
        failedStep: failedStep, code: code, reason: reason, bundle: nil, zipSize: nil,
        shape: nil, cleanedUp: true)
    }
    let report = await verifier.downloadAndVerify(
      release, transport: environment.makeDownloadTransport(checkRunningVersion))
    return makeOutput(
      mode: "latest", expected: release.version, options: options, check: check, report: report)
  } // End of static func latest(_:verifier:makeCheckTransport:environment:now:)

  /// The output for `report`.
  static func makeOutput(
    mode: String, expected: UpdateVersion, options: Options, check: CheckOutput?,
    report: UpdateVerificationReport
  ) -> Output {
    let steps = report.steps.map { result -> StepOutput in
      switch result.verdict {
      case .passed: return StepOutput(step: result.step.rawValue, verdict: "passed")
      case .notRun: return StepOutput(step: result.step.rawValue, verdict: "notRun")
      case .failed(let failure):
        return StepOutput(
          step: result.step.rawValue, verdict: "failed", code: failure.code,
          reason: failure.reason)
      }
    }
    let bundle = report.verifiedBundle.map {
      BundleOutput(path: $0.relativePath, version: $0.version.description, build: $0.build)
    }
    let shape = report.shape.map {
      ShapeOutput(entries: $0.entries, bytes: $0.bytes, symbolicLinks: $0.symbolicLinks)
    }
    let failure = report.failure
    return Output(
      mode: mode, expectedVersion: expected.description, runningBuild: options.runningBuild,
      check: check, steps: steps, verdict: failure == nil ? "verified" : "failed",
      failedStep: failure?.step.rawValue, code: failure?.code, reason: failure?.reason,
      bundle: bundle, zipSize: report.zipSize, shape: shape, cleanedUp: report.cleanedUp)
  } // End of static func makeOutput(mode:expected:options:check:report:)
}
