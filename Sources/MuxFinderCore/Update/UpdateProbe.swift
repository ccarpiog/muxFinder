import Darwin
import Foundation

/// `muxfinder-probe update …` (PLAN.md D39, Phase I-13a): the arguments, the one check and its
/// JSON output, over an injected transport so tests never send a request. The probe's file
/// wires the `URLSession` transport; its real run is the user's (*Unattended-run rules* 3).
public enum UpdateProbe {
  /// Usage lines for the `update` group.
  public static let usage = """
      update check [--running-version <x.y.z>] [--state <dir>]
          Ask GitHub once for muxFinder's latest release (GET
          https://api.github.com/repos/ccarpiog/muxFinder/releases/latest, anonymous, with
          If-None-Match when the state has an ETag) and print JSON: the outcome, whether a
          request was sent, the latest tag, whether it is newer than the running version, the
          release page, whether the installable asset muxFinder.zip and its digest are
          present, its size. During a rate limit recorded in the state nothing is sent. It
          contacts api.github.com, so its real run is the user's, never an unattended run's.
          Installs and downloads nothing. Exit 0 GitHub answered, 1 the check failed or was
          rate limited (or the state could not be saved), 64 usage.
          --running-version  The version to compare with (default 0.0.0); it is also the
                             User-Agent's (muxFinder/<x.y.z>).
          --state            A private folder of yours (absolute, no symbolic link on its
                             path, no permission for group or others, no access control
                             list, such as one from mktemp -d /private/tmp/mfx.XXXXXX) whose
                             update-state.json is read and written; any other folder is a
                             usage error, and its permissions are never changed. Without it
                             nothing is read or written.
    \(UpdateVerifyProbe.usage)
    """

  /// The running version used without `--running-version`.
  public static let defaultRunningVersion = "0.0.0"

  /// The exit status when GitHub answered.
  public static let answeredStatus: Int32 = 0
  /// The exit status when the check failed, was rate limited or its state was not saved.
  public static let failedStatus: Int32 = 1
  /// The exit status for unusable arguments (`EX_USAGE`).
  public static let usageStatus: Int32 = 64

  /// Parsed options of `update check`.
  public struct Options: Sendable, Hashable {
    /// The version compared with.
    public var runningVersion: String
    /// The private folder of `update-state.json`, or `nil`.
    public var stateDirectory: String?
  }

  /// What the arguments ask for.
  public enum Parsed: Sendable, Hashable {
    /// Print the usage; nothing is contacted.
    case help
    /// Run one check.
    case check(Options)
    /// Verify a release zip (`update verify`).
    case verify(UpdateVerifyProbe.Options)
  }

  /// Why the arguments were rejected.
  public struct UsageError: Error, Sendable, Hashable {
    /// What is wrong, in English.
    public let message: String
  }

  /// Parses the arguments after `update`.
  public static func parse(_ arguments: [String]) throws(UsageError) -> Parsed {
    guard let subcommand = arguments.first else {
      throw UsageError(message: "update needs a subcommand")
    }
    if ["help", "--help", "-h"].contains(subcommand) { return .help }
    guard subcommand == "check" || subcommand == "verify" else {
      throw UsageError(message: "unknown update subcommand")
    }
    let rest = arguments.dropFirst()
    if rest.contains("--help") || rest.contains("-h") { return .help }
    if subcommand == "verify" { return .verify(try UpdateVerifyProbe.parse(rest)) }
    var options = Options(runningVersion: defaultRunningVersion, stateDirectory: nil)
    var seen: Set<String> = []
    var remaining = rest[...]
    while let argument = remaining.popFirst() {
      guard ["--running-version", "--state"].contains(argument) else {
        throw UsageError(message: "unknown option \(argument)")
      }
      guard seen.insert(argument).inserted else {
        throw UsageError(message: "\(argument) given twice")
      }
      guard let value = remaining.popFirst() else {
        throw UsageError(message: "\(argument) needs a value")
      }
      if argument == "--running-version" {
        guard UpdateVersion(value) != nil else {
          throw UsageError(message: "--running-version needs a version such as 0.2.0")
        }
        options.runningVersion = value
      } else {
        options.stateDirectory = value
      }
    } // End of loop over the options
    return .check(options)
  } // End of static func parse(_:)

  /// The JSON printed by `update check`.
  public struct Output: Encodable, Sendable, Hashable {
    /// The version compared with.
    public var runningVersion: String
    /// `UpdateCheckOutcome.code`.
    public var outcome: String
    /// Whether a request was sent.
    public var sent: Bool
    /// The latest release's tag, when GitHub answered with one of ours.
    public var latestTag: String?
    /// Whether the latest release is newer than `runningVersion`.
    public var newer: Bool
    /// The latest release's page.
    public var releasePage: String?
    /// Whether the release has an installable `muxFinder.zip`.
    public var assetPresent: Bool
    /// Why it has none (`UpdateAssetProblem`).
    public var assetProblem: String?
    /// Whether the installable asset has a well-formed SHA-256 digest (only such an asset is
    /// installable, so this equals `assetPresent`).
    public var digestPresent: Bool
    /// The installable asset's size in bytes.
    public var size: Int?
    /// No request is sent before this date (ISO 8601), when rate limited.
    public var rateLimitedUntil: String?
    /// Whether an `ETag` is kept for the next check.
    public var etagKept: Bool
    /// The state folder's facts, with `--state`.
    public var state: StateOutput?
  }

  /// The state folder's facts in the output.
  public struct StateOutput: Encodable, Sendable, Hashable {
    /// What was found: `saved`, `missing` or `invalid.<reason>`.
    public var found: String
    /// Whether the state after the check was saved.
    public var saved: Bool
    /// Why it was not, when it was not.
    public var error: String?
  }

  /// Runs `update …` with `arguments` (the words after `update`) and returns the exit status.
  /// `makeTransport` is called only for a check that sends, with the running version (`update
  /// verify --latest` included); `verifyEnvironment` only for `update verify` with usable
  /// arguments; `--help` and unusable arguments contact nothing.
  public static func run(
    _ arguments: [String],
    makeTransport: (String) -> any UpdateCheckTransport,
    verifyEnvironment: @autoclosure () -> UpdateVerifyProbe.Environment = .live,
    now: () -> Date = { Date() },
    standardOutput: (String) -> Void,
    standardError: (String) -> Void
  ) async -> Int32 {
    let options: Options
    do throws(UsageError) {
      switch try parse(arguments) {
      case .help:
        standardOutput("usage:\n\(usage)")
        return answeredStatus
      case .check(let parsed):
        options = parsed
      case .verify(let parsed):
        return await UpdateVerifyProbe.run(
          parsed, makeCheckTransport: makeTransport, environment: verifyEnvironment(), now: now,
          standardOutput: standardOutput, standardError: standardError)
      }
    } catch {
      standardError("muxfinder-probe: \(error.message)\n\nusage:\n\(usage)")
      return usageStatus
    }
    var store: UpdateStateStore?
    if let directory = options.stateDirectory {
      if let problem = stateDirectoryProblem(directory) {
        standardError("muxfinder-probe: --state \(problem)")
        return usageStatus
      }
      store = UpdateStateStore(
        fileURL: URL(fileURLWithPath: directory, isDirectory: true).appending(
          path: UpdateStateStore.fileName, directoryHint: .notDirectory),
        directoryPolicy: .existingPrivate)
    }
    let output = await check(options, store: store, makeTransport: makeTransport, now: now)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(output) else {
      standardError("muxfinder-probe: could not encode the output")
      return failedStatus
    }
    standardOutput(String(decoding: data, as: UTF8.self))
    let answered = output.outcome != "rateLimited" && !output.outcome.hasPrefix("failed.")
    return answered && output.state?.saved != false ? answeredStatus : failedStatus
  } // End of static func run(_:makeTransport:verifyEnvironment:now:standardOutput:…)

  /// Runs one check with `options` over `store` (or an empty state) and returns its output.
  static func check(
    _ options: Options,
    store: UpdateStateStore?,
    makeTransport: (String) -> any UpdateCheckTransport,
    now: () -> Date
  ) async -> Output {
    let loaded = await store?.load()
    var state = loaded?.state ?? UpdateState()
    let outcome: UpdateCheckOutcome
    var sent = false
    if let until = UpdateCheck.activeRateLimit(state, now: now()) {
      outcome = .rateLimited(until: until)
    } else {
      state.lastAttempt = now()
      let transport = makeTransport(options.runningVersion)
      sent = true
      let response = await transport.latestRelease(etag: state.etag)
      outcome = UpdateCheck.apply(
        response, to: &state, runningVersion: options.runningVersion, now: now())
    }
    var stateOutput: StateOutput?
    if let store, let loaded {
      var saveError: String?
      if sent {
        do throws(UpdateStateStoreError) {
          try await store.save(state)
        } catch {
          saveError = error.code
        }
      }
      stateOutput = StateOutput(
        found: foundCode(loaded.found), saved: sent && saveError == nil, error: saveError)
    }
    let release = outcome.isSuccess ? state.keptRelease : nil
    var until: String?
    if case .rateLimited(let date) = outcome { until = UpdateStateCoding.text(date) }
    return Output(
      runningVersion: options.runningVersion, outcome: outcome.code, sent: sent,
      latestTag: release?.tag, newer: release.map { isNewer($0, than: options) } ?? false,
      releasePage: release?.pageURL.absoluteString, assetPresent: release?.asset != nil,
      assetProblem: release?.assetProblem?.rawValue, digestPresent: release?.asset != nil,
      size: release?.asset?.size, rateLimitedUntil: until, etagKept: state.etag != nil,
      state: stateOutput)
  } // End of static func check(_:store:makeTransport:now:)

  /// Whether `release` is newer than the options' running version.
  static func isNewer(_ release: UpdateRelease, than options: Options) -> Bool {
    UpdateOffer.evaluate(release, runningVersion: options.runningVersion).newerRelease != nil
  }

  /// `found` as the output writes it.
  static func foundCode(_ found: UpdateStateLoadResult.Found) -> String {
    switch found {
    case .saved: return "saved"
    case .missing: return "missing"
    case .invalid(let reason): return "invalid.\(reason)"
    }
  }

  /// Why `path` cannot be the state folder, or `nil`: it must be absolute, with no `.` or `..`
  /// component and no symbolic link anywhere on it, and be an existing folder of the user's
  /// that is already private (no permission for group or others, no extended ACL). Reads
  /// only: a folder that is not private is refused, never tightened (the store's
  /// `existingPrivate` policy refuses it again at the save).
  public static func stateDirectoryProblem(_ path: String) -> String? {
    guard path.hasPrefix("/") else { return "needs an absolute path" }
    let components = path.split(separator: "/").map(String.init)
    guard !components.isEmpty, !components.contains(where: { $0 == "." || $0 == ".." }) else {
      return "needs a plain path (no . or ..)"
    }
    var current = ""
    var info = stat()
    for component in components {
      current += "/" + component
      guard lstat(current, &info) == 0 else { return "names a folder that does not exist" }
      if info.st_mode & S_IFMT == S_IFLNK {
        return "has a symbolic link on its path (\(current)); pass the path it leads to"
      }
      guard info.st_mode & S_IFMT == S_IFDIR else { return "is not a folder" }
    } // End of loop over the path's components
    guard info.st_uid == geteuid() else { return "names a folder of another user" }
    guard info.st_mode & 0o077 == 0 else {
      let mode = String(info.st_mode & 0o7777, radix: 8)
      return "names a folder other users may use (mode \(mode)); pass a private one (mode 700, "
        + "such as one from mktemp -d), it is never changed"
    }
    let descriptor: Int32
    do throws(PrivateStorageError) {
      descriptor = try PrivateStorage.openDirectory(
        atPath: current, owner: geteuid(), access: .inspect)
    } catch {
      return "names a folder that cannot be opened"
    }
    defer { Darwin.close(descriptor) }
    do throws(UpdateStateStoreError) {
      try UpdateStateStore.checkAlreadyPrivate(descriptor)
    } catch .directoryNotPrivate {
      return "names a folder with an access control list (or one other users may use); pass a "
        + "private one without one, it is never changed"
    } catch {
      return "names a folder whose permissions cannot be read"
    }
    return nil
  } // End of static func stateDirectoryProblem(_:)
}
