import Darwin
import Foundation

/// Exchanges two folders' places in one step: the swap's only rename (PLAN.md D39, I-13b2).
/// A seam, so tests can fail or race each exchange; the app uses `RenameSwapExchanger`.
public protocol UpdateBundleExchanging: Sendable {
  /// Exchanges the entries at the absolute paths `first` and `second` atomically. Returns 0,
  /// or the errno of the failure (nothing changed then).
  func exchange(_ first: String, _ second: String) -> Int32
}

/// The exchange through `renamex_np(first, second, RENAME_SWAP)`: both entries change places
/// atomically, so the installed path is never empty. Proven on this Mac's APFS volume
/// (2026-11-07, PLAN.md D39) with folders in different parents: afterwards each path held the
/// other folder (device and inode compared).
public struct RenameSwapExchanger: UpdateBundleExchanging {
  /// An exchanger.
  public init() {}

  /// See `UpdateBundleExchanging`.
  public func exchange(_ first: String, _ second: String) -> Int32 {
    renamex_np(first, second, UInt32(RENAME_SWAP)) == 0 ? 0 : errno
  }
}

/// Why installing a prepared update failed (PLAN.md D39, I-13b2). `reason` is a short phrase
/// for "Couldn't update: …" with no path, host or Team ID.
public enum UpdateInstallFailure: Error, Sendable, Hashable {
  /// The prepared update was already installed or discarded.
  case alreadyUsed
  /// The folder at the installed path is no longer the one eligibility recorded (renamed,
  /// replaced, a symbolic link on its path, or not a real folder any more).
  case installedChanged
  /// The verified bundle's folder is no longer the one I-13b1 checked.
  case downloadChanged
  /// The code check run again right before the swap refused the bundle's signature.
  case signature(UpdateSignatureProblem)
  /// The code check run again right before the swap found it not notarized.
  case notarization(UpdateNotarizationProblem)
  /// The exchange failed with this errno (nothing was changed by it).
  case swapFailed(errno: Int32)
  /// The exchange reported success, but the installed path does not hold the new bundle or
  /// the run folder does not hold the old one.
  case swapUnconfirmed
  /// The relauncher could not be started (this errno); the swap was undone.
  case relaunchNotStarted(errno: Int32)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .alreadyUsed: return "alreadyUsed"
    case .installedChanged: return "installedChanged"
    case .downloadChanged: return "downloadChanged"
    case .signature(let problem): return "signature.\(problem.code)"
    case .notarization(let problem): return "notarization.\(problem.code)"
    case .swapFailed(let code): return "swapFailed.\(code)"
    case .swapUnconfirmed: return "swapUnconfirmed"
    case .relaunchNotStarted(let code): return "relaunchNotStarted.\(code)"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .alreadyUsed: return "this update was already installed or discarded"
    case .installedChanged: return "this copy of muxFinder was moved or replaced"
    case .downloadChanged: return "the download changed while it was being checked"
    case .signature(let problem): return problem.reason
    case .notarization(let problem): return problem.reason
    case .swapFailed, .swapUnconfirmed: return "the app couldn't be replaced"
    case .relaunchNotStarted: return "the new version couldn't be started"
    }
  } // End of var reason
}

/// Whether the old bundle is back at the installed path after a failure (PLAN.md D39,
/// I-13b2). Each case names the state of the two places the swap uses (the installed path and
/// the verified bundle's place in the run folder), read by device and inode.
public enum UpdateRollback: Sendable, Hashable {
  /// Nothing had to be undone: the installed path holds the old bundle and the run folder the
  /// new one.
  case notNeeded
  /// The exchange was reversed: the installed path holds the old bundle again and the run
  /// folder the new one.
  case rolledBack
  /// The reverse exchange changed nothing: the installed path still holds the new bundle and
  /// the run folder the old one, as after a successful swap. `runFolder` is for diagnostics
  /// only (never in the user's phrase).
  case failed(runFolder: String)
  /// One of the two places holds something this update did not put there (another installer,
  /// the user), so nothing was renamed back (or, after a reverse exchange, the places no longer
  /// held what it exchanged): whatever is at the installed path is left there. The run folder
  /// is marked (`UpdateStagingRoot.recoveryMarkerName`) so no cleanup ever deletes it.
  /// `runFolder` is for diagnostics only (never in the user's phrase).
  case recoveryRequired(runFolder: String)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .notNeeded: return "notNeeded"
    case .rolledBack: return "rolledBack"
    case .failed: return "failed"
    case .recoveryRequired: return "recoveryRequired"
    }
  }

  /// A phrase for the user after the failure's reason, when muxFinder's folder needs the
  /// user's attention (`recoveryRequired`); `nil` otherwise.
  public var reason: String? {
    switch self {
    case .notNeeded, .rolledBack, .failed: return nil
    case .recoveryRequired: return "something else changed muxFinder during the update"
    }
  }
}

/// What the swap came to.
public enum UpdateSwapOutcome: Sendable, Hashable {
  /// The installed path holds the new bundle and the run folder the old one.
  case swapped
  /// The swap did not happen or was undone, as `rollback` says.
  case failed(UpdateInstallFailure, rollback: UpdateRollback)
}

/// The swap, bound by device and inode (PLAN.md D39, I-13b2; D27's rules). Right before it:
/// the installed path (walked with `lstat`, no symbolic link, a real folder) must hold the
/// identity eligibility recorded (`installedChanged`), and the verified bundle's folder (read
/// through the run folder without following a link) `UpdateVerifiedBundle.identity`
/// (`downloadChanged`) and pass the code check again (`UpdateCodeChecking`, the same team,
/// notarized; I-13b1's requirement for I-13b2), both identities compared again after that
/// check. Then one `RENAME_SWAP` exchange through the injected `UpdateBundleExchanging`; after
/// it the installed path must hold the new identity and the run folder the old. Any failure or
/// difference puts the old bundle back (`rollBack()`), bound to both identities: the exchange
/// is reversed only while the installed path holds exactly the new bundle and the run folder
/// exactly the old one; otherwise nothing is renamed and the run folder is marked for recovery
/// (`recoveryRequired`), so a replacement the update did not install is never moved into the
/// run folder, where a cleanup could delete it.
public struct UpdateBundleSwap: Sendable {
  /// The moments the tests' checkpoint is called at.
  enum Checkpoint: Sendable, Hashable {
    /// Before the first identity checks.
    case beforeChecks
    /// After the code check, before the identities are compared again.
    case afterCodeCheck
    /// After the exchange, before the identities are compared.
    case afterExchange
    /// Before the reverse exchange of a rollback.
    case beforeReverse
  }

  /// The installed bundle, as eligibility recorded it.
  public let install: UpdateEligibleInstall
  /// The verified bundle in the run folder.
  public let bundle: UpdateVerifiedBundle
  /// The run folder.
  public let staging: UpdateStagingFolder
  /// Runs the code check again.
  let codeChecker: any UpdateCodeChecking
  /// Exchanges the two folders.
  let exchanger: any UpdateBundleExchanging
  /// Tests only: called at each `Checkpoint`.
  var checkpoint: (@Sendable (Checkpoint) async -> Void)?

  /// A swap of `install`'s bundle for `bundle`, verified in `staging`.
  public init(
    install: UpdateEligibleInstall, bundle: UpdateVerifiedBundle, staging: UpdateStagingFolder,
    codeChecker: any UpdateCodeChecking = SecurityUpdateCodeChecker(),
    exchanger: any UpdateBundleExchanging = RenameSwapExchanger()
  ) {
    self.install = install
    self.bundle = bundle
    self.staging = staging
    self.codeChecker = codeChecker
    self.exchanger = exchanger
  }

  /// Checks again, then swaps (see the type).
  public func run() async -> UpdateSwapOutcome {
    await checkpoint?(.beforeChecks)
    if let failure = identityFailure() { return .failed(failure, rollback: .notNeeded) }
    switch await codeChecker.check(bundleAt: bundle.path, team: install.team) {
    case .passed: break
    case .signatureFailed(let problem):
      return .failed(.signature(problem), rollback: .notNeeded)
    case .notarizationFailed(let problem):
      return .failed(.notarization(problem), rollback: .notNeeded)
    }
    await checkpoint?(.afterCodeCheck)
    if let failure = identityFailure() { return .failed(failure, rollback: .notNeeded) }
    let status = exchanger.exchange(bundle.path, install.bundlePath)
    await checkpoint?(.afterExchange)
    if status == 0, placesState() == .swapped { return .swapped }
    let failure: UpdateInstallFailure = status == 0 ? .swapUnconfirmed : .swapFailed(errno: status)
    return .failed(failure, rollback: await rollBack())
  } // End of func run()

  /// Puts the old bundle back at the installed path (after a failed swap, or after a
  /// successful one whose relaunch could not start), bound to both identities (`lstat`, real
  /// folders): nothing to do while the installed path holds the old bundle and the run folder
  /// the new one (`notNeeded`); the exchange is reversed only while the installed path holds
  /// exactly the new bundle and the run folder exactly the old one; any other state renames
  /// nothing and requires recovery. After the reverse exchange the two places are read again:
  /// the old bundle installed and the new one in the run folder is `rolledBack`, the swap's
  /// state unchanged is `failed`, anything else (a race moved another folder in) requires
  /// recovery.
  public func rollBack() async -> UpdateRollback {
    switch placesState() {
    case .original: return .notNeeded
    case .swapped: break
    case .other: return requireRecovery()
    }
    await checkpoint?(.beforeReverse)
    _ = exchanger.exchange(bundle.path, install.bundlePath)
    switch placesState() {
    case .original: return .rolledBack
    case .swapped: return .failed(runFolder: staging.path)
    case .other: return requireRecovery()
    }
  } // End of func rollBack()

  /// What the installed path and the verified bundle's place in the run folder hold, by
  /// identity.
  enum PlacesState: Sendable, Hashable {
    /// The old bundle installed, the new one in the run folder (before the swap).
    case original
    /// The new bundle installed, the old one in the run folder (after the swap).
    case swapped
    /// Anything else: something this update did not put there is in one of the places.
    case other
  }

  /// Reads both places (see `PlacesState`).
  func placesState() -> PlacesState {
    let installed = installedIdentity()
    let staged = stagedIdentity()
    if installed == install.identity, staged == bundle.identity { return .original }
    if installed == bundle.identity, staged == install.identity { return .swapped }
    return .other
  }

  /// Marks the run folder for recovery (`UpdateStagingRoot.recoveryMarkerName`, created
  /// exclusively, never through a link; one already there counts) so no cleanup deletes it,
  /// and answers `recoveryRequired`. Nothing is renamed.
  func requireRecovery() -> UpdateRollback {
    if let marker = try? staging.createFile(named: UpdateStagingRoot.recoveryMarkerName) {
      Darwin.close(marker)
    }
    return .recoveryRequired(runFolder: staging.path)
  }

  /// The failure when either folder is not the one recorded, or `nil`.
  func identityFailure() -> UpdateInstallFailure? {
    if installedIdentity() != install.identity { return .installedChanged }
    if stagedIdentity() != bundle.identity { return .downloadChanged }
    return nil
  }

  /// The identity of the real folder at the installed path (no symbolic link on the way).
  func installedIdentity() -> UpdateBundleIdentity? {
    Self.folderIdentity(atPath: install.bundlePath)
  }

  /// The identity of the real folder at the verified bundle's place in the run folder.
  func stagedIdentity() -> UpdateBundleIdentity? {
    try? staging.folderIdentity(atRelativePath: bundle.relativePath)
  }

  /// The identity of the real folder at the plain absolute `path`, every component walked with
  /// `lstat` (no symbolic link); `nil` otherwise.
  static func folderIdentity(atPath path: String) -> UpdateBundleIdentity? {
    guard case .success = UpdateInstalledBundleReader.walk(path) else { return nil }
    var info = stat()
    guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { return nil }
    return UpdateBundleIdentity(info)
  }
}
