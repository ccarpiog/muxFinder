import Darwin
import Foundation
import os

/// Where an update is (PLAN.md D39, I-13b2), for I-13c's popover line.
public enum UpdatePipelineState: Sendable, Hashable {
  /// The download runs: `bytes` of the asset's `total`.
  case downloading(bytes: Int, total: Int)
  /// The download is complete and being checked (digest, unpacking, shape, signature,
  /// notarization, versions).
  case checking
  /// The verified bundle is being checked again and swapped in.
  case installing
  /// The swap is done and the relauncher is being started.
  case relaunching
}

/// Why an update stopped (PLAN.md D39, I-13b2). `reason` is a short phrase for "Couldn't
/// update: …" with no path, host or Team ID.
public enum UpdatePipelineFailure: Error, Sendable, Hashable {
  /// The running copy cannot update itself (checked again when the update starts).
  case notEligible(UpdateIneligibility)
  /// The update folder or the run folder could not be made ready.
  case stagingRoot(UpdateStagingRootError)
  /// I-13b1's download and verification refused the release.
  case verification(UpdateVerificationFailure)
  /// Installing failed.
  case install(UpdateInstallFailure)

  /// A stable, machine-readable name.
  public var code: String {
    switch self {
    case .notEligible(let reason): return "notEligible.\(reason.code)"
    case .stagingRoot(let error): return "stagingRoot.\(error.code)"
    case .verification(let failure): return "verification.\(failure.step.rawValue).\(failure.code)"
    case .install(let failure): return "install.\(failure.code)"
    }
  } // End of var code

  /// The reason, as a phrase after "Couldn't update: ".
  public var reason: String {
    switch self {
    case .notEligible(let reason): return reason.reason
    case .stagingRoot(let error): return error.reason
    case .verification(let failure): return failure.reason
    case .install(let failure): return failure.reason
    }
  } // End of var reason
}

/// A downloaded and verified update waiting to be installed (PLAN.md D39, I-13b2): its run
/// folder stays locked until it is installed or discarded. It can be used once.
public final class UpdatePreparedUpdate: Sendable {
  /// The release.
  public let release: UpdateRelease
  /// The verified bundle in the run folder.
  public let bundle: UpdateVerifiedBundle
  /// The running copy, as eligibility recorded it when the update started.
  public let install: UpdateEligibleInstall
  /// The run folder.
  let runFolder: UpdateRunFolder
  /// Whether `install` or `discard` has taken it.
  private let used = OSAllocatedUnfairLock(initialState: false)

  /// A prepared update.
  init(
    release: UpdateRelease, bundle: UpdateVerifiedBundle, install: UpdateEligibleInstall,
    runFolder: UpdateRunFolder
  ) {
    self.release = release
    self.bundle = bundle
    self.install = install
    self.runFolder = runFolder
  }

  /// The run folder's absolute path (diagnostics only).
  public var runFolderPath: String { runFolder.path }

  /// Takes the update for one use; `false` when it was already taken.
  func claim() -> Bool {
    used.withLock { taken in
      guard !taken else { return false }
      taken = true
      return true
    }
  }
}

/// What preparing an update came to.
public enum UpdatePrepareOutcome: Sendable {
  /// Downloaded and verified, ready to install (or discard).
  case prepared(UpdatePreparedUpdate)
  /// It failed; the run folder is gone.
  case failed(UpdatePipelineFailure)
  /// It was cancelled; the run folder is gone.
  case cancelled
}

/// What installing an update came to.
public enum UpdateInstallOutcome: Sendable, Hashable {
  /// The new bundle is installed and the relauncher (this pid) waits for the app to end;
  /// I-13c quits the app now.
  case relaunchScheduled(relauncher: Int32)
  /// Installing failed; `rollback` says whether the old bundle is in place.
  case failed(UpdateInstallFailure, rollback: UpdateRollback)
}

/// Decides eligibility when the update starts (a seam for the pipeline's tests).
public protocol UpdateEligibilityChecking: Sendable {
  /// The running copy's eligibility now.
  func check() -> UpdateEligibility
}

/// The running app's eligibility: `UpdateEligibilityReader.current(root:)`, decided.
public struct SystemUpdateEligibility: UpdateEligibilityChecking {
  /// The update folder.
  public let root: UpdateStagingRoot

  /// The running app's eligibility with the update folder `root`.
  public init(root: UpdateStagingRoot = .standard) {
    self.root = root
  }

  /// See `UpdateEligibilityChecking`.
  public func check() -> UpdateEligibility {
    UpdateEligibility.decide(UpdateEligibilityReader.current(root: root))
  }
}

/// The install pipeline I-13c drives (PLAN.md D39, I-13b2), in two calls so the app can ask
/// before quitting between them:
///
/// - `prepare(_:transport:onState:)`: eligibility again, the update folder and a fresh locked
///   run folder on the installed bundle's volume, then I-13b1's `UpdateVerifier` with the
///   running app's team and build (states `downloading`, then `checking`); cancellable (task
///   cancellation). A failure or a cancel removes the run folder.
/// - `install(_:onState:)`: the re-check and the swap (`UpdateBundleSwap`, state
///   `installing`), then the relauncher (state `relaunching`). A failure leaves the old bundle
///   in place (or says it could not); a relauncher that cannot start undoes the swap. On
///   success the run folder, holding the old bundle, is released for the leftover cleanup at
///   a later launch. It never terminates the app.
/// - `discard(_:)` removes a prepared update's run folder.
///
/// Every external effect is injected: eligibility, the update folder's location, the process
/// runner (`ditto`), the code checker, the exchange and the relauncher.
public struct UpdatePipeline: Sendable {
  /// The update folder.
  public let root: UpdateStagingRoot
  /// Decides eligibility.
  let eligibility: any UpdateEligibilityChecking
  /// Starts the relauncher.
  let relauncher: any UpdateRelaunching
  /// The pid the relauncher waits for (the app's own).
  let processID: Int32
  /// Runs `ditto`.
  let processRunner: any ProcessRunner
  /// Checks signatures (during the verification and again before the swap).
  let codeChecker: any UpdateCodeChecking
  /// Exchanges the folders.
  let exchanger: any UpdateBundleExchanging

  /// A pipeline. The app passes `SystemUpdateEligibility()`, `.standard`, a
  /// `DetachedUpdateRelauncher` with `UpdateRelauncher.systemOpener` and its own pid.
  public init(
    root: UpdateStagingRoot,
    eligibility: any UpdateEligibilityChecking,
    relauncher: any UpdateRelaunching,
    processID: Int32 = getpid(),
    processRunner: any ProcessRunner = PosixSpawnProcessRunner(),
    codeChecker: any UpdateCodeChecking = SecurityUpdateCodeChecker(),
    exchanger: any UpdateBundleExchanging = RenameSwapExchanger()
  ) {
    self.root = root
    self.eligibility = eligibility
    self.relauncher = relauncher
    self.processID = processID
    self.processRunner = processRunner
    self.codeChecker = codeChecker
    self.exchanger = exchanger
  } // End of init(root:eligibility:relauncher:processID:processRunner:codeChecker:exchanger:)

  /// Downloads `release` through `transport` and verifies it (see the type).
  public func prepare(
    _ release: UpdateRelease,
    transport: any UpdateDownloadTransport,
    onState: @escaping @Sendable (UpdatePipelineState) -> Void = { _ in }
  ) async -> UpdatePrepareOutcome {
    let install: UpdateEligibleInstall
    switch eligibility.check() {
    case .notEligible(let reason): return .failed(.notEligible(reason))
    case .eligible(let eligible): install = eligible
    }
    if Task.isCancelled { return .cancelled }
    let run: UpdateRunFolder
    do throws(UpdateStagingRootError) {
      run = try root.makeRunFolder(onDevice: install.identity.device)
    } catch {
      return .failed(.stagingRoot(error))
    }
    onState(.downloading(bytes: 0, total: release.asset?.size ?? 0))
    let checking = OSAllocatedUnfairLock(initialState: false)
    let verifier = UpdateVerifier(
      staging: run.staging, team: install.team, runningBuild: install.runningBuild,
      processRunner: processRunner, codeChecker: codeChecker)
    let report = await verifier.downloadAndVerify(release, transport: transport) { progress in
      onState(.downloading(bytes: progress.received, total: progress.expected))
      guard progress.received == progress.expected else { return }
      let first = checking.withLock { seen -> Bool in
        let wasSeen = seen
        seen = true
        return !wasSeen
      }
      if first { onState(.checking) }
    }
    switch report.outcome {
    case .failed(let failure):
      run.remove()
      return failure.isCancelled ? .cancelled : .failed(.verification(failure))
    case .verified(let bundle):
      if Task.isCancelled {
        run.remove()
        return .cancelled
      }
      return .prepared(
        UpdatePreparedUpdate(release: release, bundle: bundle, install: install, runFolder: run))
    }
  } // End of func prepare(_:transport:onState:)

  /// Installs `prepared` and starts the relauncher (see the type).
  public func install(
    _ prepared: UpdatePreparedUpdate,
    onState: @escaping @Sendable (UpdatePipelineState) -> Void = { _ in }
  ) async -> UpdateInstallOutcome {
    guard prepared.claim() else { return .failed(.alreadyUsed, rollback: .notNeeded) }
    onState(.installing)
    let swap = UpdateBundleSwap(
      install: prepared.install, bundle: prepared.bundle, staging: prepared.runFolder.staging,
      codeChecker: codeChecker, exchanger: exchanger)
    if case .failed(let failure, let rollback) = await swap.run() {
      Self.finish(prepared, after: rollback)
      return .failed(failure, rollback: rollback)
    }
    onState(.relaunching)
    switch relauncher.relaunch(after: processID, bundlePath: prepared.install.bundlePath) {
    case .success(let relauncherID):
      prepared.runFolder.release()
      return .relaunchScheduled(relauncher: relauncherID)
    case .failure(let error):
      let rollback = await swap.rollBack()
      Self.finish(prepared, after: rollback)
      return .failed(.relaunchNotStarted(errno: error.errnoValue), rollback: rollback)
    }
  } // End of func install(_:onState:)

  /// Removes a prepared update's run folder without installing it. Returns whether it is
  /// gone (`false` when the update was already used).
  @discardableResult
  public func discard(_ prepared: UpdatePreparedUpdate) -> Bool {
    guard prepared.claim() else { return false }
    return prepared.runFolder.remove()
  }

  /// After a failed install: the run folder is removed only when the exchange moved nothing
  /// out of it (`notNeeded`) or the rollback read the old bundle installed and the new one back
  /// in the run folder (`notNeeded` after an exchange, `rolledBack`); otherwise it is kept and
  /// released: after `failed` (the swap's state, for a later cleanup) and after
  /// `recoveryRequired` (marked, so no cleanup deletes it).
  static func finish(_ prepared: UpdatePreparedUpdate, after rollback: UpdateRollback) {
    switch rollback {
    case .notNeeded, .rolledBack: prepared.runFolder.remove()
    case .failed, .recoveryRequired: prepared.runFolder.release()
    }
  }
}
