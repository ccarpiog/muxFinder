import AppKit
import Foundation
import MuxFinderCore
import Observation

/// What quitting now would lose (PLAN.md D39 *The update flow (I-13c2a)*): the ask before
/// quitting names it. Attached tmux sessions are never part of it (quitting never detaches).
public struct UpdateUnsavedWork: Sendable, Hashable {
  /// The New session window shows a draft whose name or directory has text.
  public var newSessionDraft: Bool
  /// Settings has unsaved edits (the host editor's draft or the directory list's).
  public var settingsEdits: Bool

  /// Unsaved work from its parts.
  public init(newSessionDraft: Bool = false, settingsEdits: Bool = false) {
    self.newSessionDraft = newSessionDraft
    self.settingsEdits = settingsEdits
  }

  /// Nothing unsaved.
  public static let none = UpdateUnsavedWork()

  /// Whether nothing is unsaved.
  public var isEmpty: Bool { !newSessionDraft && !settingsEdits }

  /// What is unsaved, as short phrases for I-13c2b's line ("the New session draft", "unsaved
  /// changes in Settings").
  public var items: [String] {
    var items: [String] = []
    if newSessionDraft { items.append("the New session draft") }
    if settingsEdits { items.append("unsaved changes in Settings") }
    return items
  }
}

/// A downloaded and verified update the flow holds between prepare and install (PLAN.md D39
/// *The update flow (I-13c2a)*): the pipeline's `UpdatePreparedUpdate` in the app, nothing
/// but the release in tests.
public final class UpdateFlowPrepared: Sendable {
  /// The release.
  public let release: UpdateRelease
  /// The pipeline's prepared update (`nil` for a test's stand-in).
  let prepared: UpdatePreparedUpdate?

  /// A stand-in for tests: no run folder behind it.
  public init(release: UpdateRelease) {
    self.release = release
    prepared = nil
  }

  /// The pipeline's prepared update.
  init(_ prepared: UpdatePreparedUpdate) {
    release = prepared.release
    self.prepared = prepared
  }
}

/// What preparing came to, for the flow.
public enum UpdateFlowPrepareOutcome: Sendable {
  /// Downloaded and verified.
  case prepared(UpdateFlowPrepared)
  /// It failed (the run folder is gone).
  case failed(UpdatePipelineFailure)
  /// It was cancelled (the run folder is gone).
  case cancelled
}

/// The flow's seam over I-13b2's pipeline, eligibility and leftover cleanup (PLAN.md D39 *The
/// update flow (I-13c2a)*). Every call runs off the main actor; tests pass fakes.
public protocol UpdateFlowPipeline: Sendable {
  /// The running copy's eligibility now: `nil` when eligible, else the reason (a read that
  /// fails is a reason too).
  func ineligibility() async -> UpdateIneligibility?
  /// Downloads and verifies `release` (`UpdatePipeline.prepare`); cancellable.
  func prepare(
    _ release: UpdateRelease, onState: @escaping @Sendable (UpdatePipelineState) -> Void
  ) async -> UpdateFlowPrepareOutcome
  /// Installs `prepared` and starts the relauncher (`UpdatePipeline.install`); never
  /// terminates the app.
  func install(
    _ prepared: UpdateFlowPrepared, onState: @escaping @Sendable (UpdatePipelineState) -> Void
  ) async -> UpdateInstallOutcome
  /// Removes a prepared update's run folder without installing it.
  func discard(_ prepared: UpdateFlowPrepared) async -> Bool
  /// The leftover cleanup a launch runs over the update folder (never creating it).
  func cleanLeftovers() async -> UpdateCleanupReport
}

/// The app's pipeline (PLAN.md D39 *The update flow (I-13c2a)*): `UpdatePipeline` over the
/// real update folder (`UpdateStagingRoot.standard`), `SystemUpdateEligibility`, a
/// `DetachedUpdateRelauncher` with `/usr/bin/open` (the pipeline hands it the absolute
/// installed path) and `URLSessionUpdateDownloadTransport`. Building it creates, reads and
/// sends nothing.
public struct SystemUpdateFlowPipeline: UpdateFlowPipeline {
  /// The install pipeline.
  let pipeline: UpdatePipeline
  /// The download's transport.
  let transport: any UpdateDownloadTransport
  /// Decides eligibility.
  let eligibility: any UpdateEligibilityChecking

  /// A pipeline from its parts.
  public init(
    pipeline: UpdatePipeline, transport: any UpdateDownloadTransport,
    eligibility: any UpdateEligibilityChecking
  ) {
    self.pipeline = pipeline
    self.transport = transport
    self.eligibility = eligibility
  }

  /// The running app's (see the type).
  public static func production(shortVersion: String?) -> SystemUpdateFlowPipeline {
    let root = UpdateStagingRoot.standard
    let eligibility = SystemUpdateEligibility(root: root)
    let pipeline = UpdatePipeline(
      root: root, eligibility: eligibility,
      relauncher: DetachedUpdateRelauncher(opener: UpdateRelauncher.systemOpener))
    return SystemUpdateFlowPipeline(
      pipeline: pipeline, transport: URLSessionUpdateDownloadTransport(shortVersion: shortVersion),
      eligibility: eligibility)
  } // End of static func production(shortVersion:)

  /// See `UpdateFlowPipeline`.
  public func ineligibility() async -> UpdateIneligibility? {
    let eligibility = self.eligibility
    return await Self.detached {
      if case .notEligible(let reason) = eligibility.check() { return reason }
      return nil
    }
  }

  /// See `UpdateFlowPipeline`.
  public func prepare(
    _ release: UpdateRelease, onState: @escaping @Sendable (UpdatePipelineState) -> Void
  ) async -> UpdateFlowPrepareOutcome {
    let pipeline = self.pipeline
    let transport = self.transport
    return await Self.detached {
      switch await pipeline.prepare(release, transport: transport, onState: onState) {
      case .prepared(let prepared): return .prepared(UpdateFlowPrepared(prepared))
      case .failed(let failure): return .failed(failure)
      case .cancelled: return .cancelled
      }
    }
  } // End of func prepare(_:onState:)

  /// See `UpdateFlowPipeline`.
  public func install(
    _ prepared: UpdateFlowPrepared, onState: @escaping @Sendable (UpdatePipelineState) -> Void
  ) async -> UpdateInstallOutcome {
    guard let update = prepared.prepared else {
      return .failed(.alreadyUsed, rollback: .notNeeded)
    }
    let pipeline = self.pipeline
    return await Self.detached { await pipeline.install(update, onState: onState) }
  }

  /// See `UpdateFlowPipeline`.
  public func discard(_ prepared: UpdateFlowPrepared) async -> Bool {
    guard let update = prepared.prepared else { return false }
    let pipeline = self.pipeline
    return await Self.detached { pipeline.discard(update) }
  }

  /// See `UpdateFlowPipeline`.
  public func cleanLeftovers() async -> UpdateCleanupReport {
    let root = pipeline.root
    return await Self.detached { root.cleanLeftovers() }
  }

  /// Runs `body` in a detached task (off the main actor), passing the caller's cancellation
  /// on.
  private static func detached<T: Sendable>(
    _ body: @escaping @Sendable () async -> T
  ) async -> T {
    let task = Task.detached(priority: .userInitiated, operation: body)
    return await withTaskCancellationHandler {
      await task.value
    } onCancel: {
      task.cancel()
    }
  } // End of static func detached(_:)
}

/// What the update flow runs on (PLAN.md D39 *The update flow (I-13c2a)*): the pipeline, the
/// terminator called after `relaunchScheduled` (`NSApp.terminate` in the app, so
/// `AppModel.shutdown()` runs) and the bound of a quit's other waits (an install under way is
/// never bounded: see `UpdateFlow.stop()`).
public struct UpdateFlowEnvironment: Sendable {
  /// The pipeline, eligibility and cleanup.
  public var pipeline: any UpdateFlowPipeline
  /// Quits the app normally.
  public var terminate: @MainActor @Sendable () -> Void
  /// How long a quit waits for a cancelled prepare, a discard or the launch's cleanup.
  public var quitBound: Duration

  /// An environment from its parts.
  public init(
    pipeline: any UpdateFlowPipeline, terminate: @escaping @MainActor @Sendable () -> Void,
    quitBound: Duration = .seconds(2)
  ) {
    self.pipeline = pipeline
    self.terminate = terminate
    self.quitBound = quitBound
  }

  /// The running app's: `SystemUpdateFlowPipeline.production(shortVersion:)` and
  /// `NSApp.terminate(nil)`.
  @MainActor
  public static func production(shortVersion: String?) -> UpdateFlowEnvironment {
    UpdateFlowEnvironment(
      pipeline: SystemUpdateFlowPipeline.production(shortVersion: shortVersion),
      terminate: { NSApp.terminate(nil) })
  }
}

/// Why an update stopped, for "Couldn't update: <reason>" (PLAN.md D39 *The update flow
/// (I-13c2a)*): no path, host or Team ID.
public struct UpdateFlowFailure: Sendable, Hashable {
  /// The phrase after "Couldn't update: ".
  public let reason: String
  /// A stable, machine-readable name (diagnostics and tests).
  public let code: String

  /// A failure from its parts.
  public init(reason: String, code: String) {
    self.reason = reason
    self.code = code
  }

  /// "Couldn't update: <reason>".
  public var phrase: String { "Couldn't update: \(reason)" }

  /// A prepare's failure.
  public static func prepare(_ failure: UpdatePipelineFailure) -> UpdateFlowFailure {
    UpdateFlowFailure(reason: failure.reason, code: failure.code)
  }

  /// An install's failure: the old version back in place (rolled back, or nothing to undo)
  /// gives the failure's own reason; the others say what the rollback came to.
  public static func install(
    _ failure: UpdateInstallFailure, rollback: UpdateRollback
  ) -> UpdateFlowFailure {
    let code = "install.\(failure.code)"
    switch rollback {
    case .notNeeded, .rolledBack:
      return UpdateFlowFailure(reason: failure.reason, code: code)
    case .failed:
      return UpdateFlowFailure(
        reason: "\(failure.reason), and the change couldn't be undone", code: code + ".failed")
    case .recoveryRequired:
      return UpdateFlowFailure(
        reason: rollback.reason ?? UpdateFlowText.recoveryRequired,
        code: code + ".recoveryRequired")
    }
  } // End of static func install(_:rollback:)
}

/// Where the update flow is (PLAN.md D39 *The update flow (I-13c2a)*), for I-13c2b's views.
public enum UpdateFlowState: Sendable, Hashable {
  /// Nothing runs: the offer (`UpdateFlow.offer`) shows.
  case idle
  /// The download runs: `bytes` of `total` (0 or less: unknown).
  case downloading(bytes: Int, total: Int)
  /// The download is being checked ("Checking the download…").
  case checking
  /// Downloaded and verified; the ask comes next.
  case prepared
  /// Quitting would lose this unsaved work: Quit and install, or Not now.
  case asking(UpdateUnsavedWork)
  /// "Not now": the prepared update is kept while the app runs, offered as Install and
  /// relaunch.
  case deferred
  /// The update is being installed.
  case installing
  /// Installed; the relauncher waits and the app quits.
  case relaunchScheduled
  /// It failed; Update is offered again.
  case failed(UpdateFlowFailure)

  /// The download's percent, when its total is known.
  public var percent: Int? {
    guard case .downloading(let bytes, let total) = self, total > 0 else { return nil }
    return UpdateFlowText.percent(bytes: bytes, total: total)
  }

  /// Whether a prepare runs (Cancel is offered).
  public var isPreparing: Bool {
    switch self {
    case .downloading, .checking: return true
    default: return false
    }
  }
}

/// What the notice offers (PLAN.md D39 *The update flow (I-13c2a)*).
public enum UpdateFlowOffer: Sendable, Hashable {
  /// Eligibility is being read (nothing offered yet).
  case reading
  /// Update: the running copy can update itself and the release has an asset.
  case update
  /// Download: opens the release page; `reason` says why not Update.
  case download(reason: String)
}

/// The flow's wording (PLAN.md D39 *The update flow (I-13c2a)*).
public enum UpdateFlowText {
  /// The reason when the release has no asset the app can install.
  public static let noInstallableAsset = "the release has no installable download"
  /// The reason after a rollback marked muxFinder's folder for recovery, if the core gave none.
  public static let recoveryRequired = "something else changed muxFinder during the update"
  /// "Checking the download…".
  public static let checking = "Checking the download…"

  /// The percent of `bytes` in `total` (clamped to 0…100); `nil` for an unknown total.
  public static func percent(bytes: Int, total: Int) -> Int? {
    guard total > 0 else { return nil }
    return min(100, max(0, Int((Double(bytes) / Double(total) * 100).rounded(.down))))
  }

  /// "Downloading… 40%", or "Downloading…" when the total is unknown.
  public static func downloading(bytes: Int, total: Int) -> String {
    guard let percent = percent(bytes: bytes, total: total) else { return "Downloading…" }
    return "Downloading… \(percent)%"
  }
}

/// The one-click update flow (PLAN.md D39 *The update flow (I-13c2a)*): the offer (eligibility
/// read once per notice version, off the main actor), prepare (one at a time, cancellable),
/// the ask before quitting, install and the quit after `relaunchScheduled`, a quit's bounded
/// waits, and the leftover cleanup at launch. Live only in normal mode
/// (`AppLaunchOptions.createsUpdateMachinery`); inert everywhere else (nothing runs).
@MainActor
@Observable
public final class UpdateFlow {
  /// Where the flow is.
  public private(set) var state = UpdateFlowState.idle
  /// What the notice offers; `nil` while there is no notice.
  public private(set) var offer: UpdateFlowOffer?
  /// The launch's leftover cleanup report, once it ran (diagnostics only, no alert).
  public private(set) var cleanupReport: UpdateCleanupReport?
  /// The release being prepared, prepared (asked about, or deferred) or installed: what
  /// Install and relaunch installs, whatever a later notice shows; `nil` otherwise.
  public private(set) var preparedRelease: UpdateRelease?
  /// Whether edits are refused (from the final unsaved-work decision through the install and
  /// the quit; back to `false` when the install fails while the app keeps running): the New
  /// session draft and Settings' host editor and directory list read it.
  public private(set) var locksEditing = false
  /// Whether the flow can run (normal mode only).
  public var isAvailable: Bool { environment != nil }

  /// Says what unsaved work quitting would lose (`AppModel` sets it; `nil` reads none).
  @ObservationIgnored public var unsavedWork: (@MainActor () -> UpdateUnsavedWork)?
  /// The environment, for a live flow.
  @ObservationIgnored private let environment: UpdateFlowEnvironment?
  /// Opens the release page (Download).
  @ObservationIgnored private let openURL: (@MainActor @Sendable (URL) -> Void)?
  /// The notice's release, as the offer shows it (kept while the flow is busy).
  @ObservationIgnored private var release: UpdateRelease?
  /// The latest notice (`nil`: none), retained while the flow is busy and applied after a
  /// cancel or a failure.
  @ObservationIgnored private var latestNotice: UpdateRelease?
  /// The version whose eligibility was read (or is being read), kept apart from the shown
  /// release so the same version reappearing restores its offer.
  @ObservationIgnored private var eligibilityVersion: UpdateVersion?
  /// The offer read for `eligibilityVersion` (`nil` while it is being read).
  @ObservationIgnored private var eligibilityOffer: UpdateFlowOffer?
  /// The eligibility read.
  @ObservationIgnored private var offerTask: Task<Void, Never>?
  /// The prepare under way.
  @ObservationIgnored private var prepareTask: Task<Void, Never>?
  /// The install under way.
  @ObservationIgnored private var installTask: Task<Void, Never>?
  /// The launch's cleanup.
  @ObservationIgnored private var cleanupTask: Task<Void, Never>?
  /// The prepared update not installed yet.
  @ObservationIgnored private var prepared: UpdateFlowPrepared?
  /// Whether a quit started (`stop()`).
  @ObservationIgnored private var isStopped = false
  /// Whether the terminator was called.
  @ObservationIgnored private(set) var didTerminate = false

  /// A live flow over `environment`; nothing runs until it is asked.
  public init(
    environment: UpdateFlowEnvironment, openURL: @escaping @MainActor @Sendable (URL) -> Void
  ) {
    self.environment = environment
    self.openURL = openURL
  }

  /// A flow that never runs anything (every mode but the normal launch, fixtures).
  private init() {
    environment = nil
    openURL = nil
  }

  /// The inert flow.
  public static func inert() -> UpdateFlow { UpdateFlow() }

  // MARK: - Launch

  /// Runs the leftover cleanup once, off the main actor, never blocking the caller (the
  /// launch); its counts are kept in `cleanupReport` only.
  func startCleanup() {
    guard let environment, cleanupTask == nil, !isStopped else { return }
    let pipeline = environment.pipeline
    cleanupTask = Task { [weak self] in
      let report = await pipeline.cleanLeftovers()
      self?.cleanupReport = report
    }
  }

  // MARK: - The offer

  /// The notice shows `release` (or no notice, `nil`): its eligibility is read once per
  /// version, off the main actor; a release with no asset is a Download with no read. While a
  /// prepare, a prepared update or an install is under way the latest notice is only kept,
  /// and applied once the flow is idle again (a cancel or a failure).
  func noticeShown(_ release: UpdateRelease?) {
    guard environment != nil, !isStopped else { return }
    latestNotice = release
    guard !isBusy else { return }
    showOffer(for: release)
  }

  /// Whether a prepare, a prepared update or an install is under way (the offer then stays).
  private var isBusy: Bool { state.isPreparing || prepared != nil || installTask != nil }

  /// Shows the offer for `release` (`nil`: none): the cached offer when its version was read
  /// already (or is being read), else a new read.
  private func showOffer(for release: UpdateRelease?) {
    guard let environment else { return }
    self.release = release
    guard let release else {
      offer = nil
      return
    }
    guard release.asset != nil else {
      offer = .download(reason: UpdateFlowText.noInstallableAsset)
      return
    }
    if release.version == eligibilityVersion {
      offer = eligibilityOffer ?? .reading
      return
    }
    offerTask?.cancel()
    eligibilityVersion = release.version
    eligibilityOffer = nil
    offer = .reading
    let version = release.version
    let pipeline = environment.pipeline
    offerTask = Task { [weak self] in
      let reason = await pipeline.ineligibility()
      guard let self, self.eligibilityVersion == version, !Task.isCancelled else { return }
      let offer: UpdateFlowOffer = reason.map { .download(reason: $0.reason) } ?? .update
      self.eligibilityOffer = offer
      if self.release?.version == version { self.offer = offer }
    }
  } // End of func showOffer(for:)

  /// Whether Update can be pressed now.
  public var canUpdate: Bool {
    guard environment != nil, !isStopped, offer == .update, release != nil else { return false }
    switch state {
    case .idle, .failed: return true
    default: return false
    }
  }

  /// Download: opens the notice's release page.
  public func download() {
    guard let openURL, let page = release?.pageURL else { return }
    openURL(page)
  }

  // MARK: - Prepare

  /// Update: runs the pipeline's prepare (one at a time); the states arrive in order, then
  /// the outcome: prepared (then the ask), failed (Update offered again) or cancelled (back
  /// to the offer).
  public func update() {
    guard canUpdate, let environment, let release else { return }
    let pipeline = environment.pipeline
    preparedRelease = release
    state = .downloading(bytes: 0, total: release.asset?.size ?? 0)
    let (states, sink) = AsyncStream.makeStream(of: UpdatePipelineState.self)
    prepareTask = Task { [weak self] in
      let reader = Task { @MainActor [weak self] in
        for await step in states { self?.prepareStep(step) }
      }
      let outcome = await pipeline.prepare(release) { sink.yield($0) }
      sink.finish()
      await reader.value
      await self?.prepareEnded(outcome)
    }
  } // End of func update()

  /// Cancel: ends the prepare under way as cancelled.
  public func cancel() {
    guard state.isPreparing else { return }
    prepareTask?.cancel()
  }

  /// A pipeline state during prepare: downloading never follows checking.
  private func prepareStep(_ step: UpdatePipelineState) {
    switch (step, state) {
    case (.downloading(let bytes, let total), .downloading):
      state = .downloading(bytes: bytes, total: total)
    case (.checking, .downloading): state = .checking
    default: break
    }
  }

  /// The prepare's outcome.
  private func prepareEnded(_ outcome: UpdateFlowPrepareOutcome) async {
    prepareTask = nil
    switch outcome {
    case .prepared(let update):
      if isStopped || Task.isCancelled {
        _ = await environment?.pipeline.discard(update)
        preparedRelease = nil
        state = .idle
        return
      }
      prepared = update
      state = .prepared
      ask()
    case .failed(let failure):
      preparedRelease = nil
      state = .failed(.prepare(failure))
      if case .notEligible(let reason) = failure, let release {
        eligibilityVersion = release.version
        eligibilityOffer = .download(reason: reason.reason)
      }
      showOffer(for: latestNotice)
    case .cancelled:
      preparedRelease = nil
      state = .idle
      showOffer(for: latestNotice)
    }
  } // End of func prepareEnded(_:)

  // MARK: - The ask and install

  /// Asks the unsaved-work source: none goes straight on to install; some is the ask.
  private func ask() {
    let work = unsavedWork?() ?? .none
    if work.isEmpty {
      install()
    } else {
      state = .asking(work)
    }
  }

  /// Quit and install: installs now, whatever is unsaved.
  public func quitAndInstall() {
    guard case .asking = state else { return }
    install()
  }

  /// Not now: keeps the prepared update while the app runs (offered as Install and
  /// relaunch).
  public func notNow() {
    guard case .asking = state else { return }
    state = .deferred
  }

  /// Install and relaunch (after Not now): asks again.
  public func installAndRelaunch() {
    guard state == .deferred, prepared != nil, !isStopped else { return }
    ask()
  }

  /// Installs the prepared update; after `relaunchScheduled` the terminator quits the app
  /// (in a task of its own, so the quit never waits for this one). A failure is the failed
  /// state and the app keeps running.
  private func install() {
    guard let environment, let update = prepared, installTask == nil, !isStopped else { return }
    prepared = nil
    locksEditing = true
    state = .installing
    let pipeline = environment.pipeline
    let terminate = environment.terminate
    installTask = Task { [weak self] in
      let outcome = await pipeline.install(update) { _ in }
      guard let self else { return }
      self.installTask = nil
      switch outcome {
      case .relaunchScheduled:
        self.state = .relaunchScheduled
        guard !self.isStopped else { return }
        self.didTerminate = true
        Task { @MainActor in terminate() }
      case .failed(let failure, let rollback):
        self.preparedRelease = nil
        self.state = .failed(.install(failure, rollback: rollback))
        guard !self.isStopped else { return }
        self.locksEditing = false
        self.showOffer(for: self.latestNotice)
      }
    }
  } // End of func install()

  // MARK: - Quit

  /// A quit (`AppModel.shutdown()` through `UpdateModel.stop()`): an install under way is
  /// cancelled and awaited with no deadline: the pipeline stops at its last point before the
  /// swap (`cancelled`, nothing changed), or, once the swap began, the swap, its checks and
  /// any rollback end first (local renames), so the app never quits in between and no second
  /// terminator is called; a prepare under way is cancelled, a prepared update never
  /// installed is discarded and the launch's cleanup is awaited (each at most `quitBound`).
  /// Later calls do nothing.
  func stop() async {
    guard !isStopped else { return }
    isStopped = true
    offerTask?.cancel()
    guard let environment else { return }
    if let installTask {
      installTask.cancel()
      await installTask.value
    }
    if let prepareTask {
      prepareTask.cancel()
      _ = await AppModel.ends(prepareTask, within: environment.quitBound)
    }
    if let update = prepared {
      prepared = nil
      let pipeline = environment.pipeline
      let discard = Task { _ = await pipeline.discard(update) }
      _ = await AppModel.ends(discard, within: environment.quitBound)
    }
    if let cleanupTask { _ = await AppModel.ends(cleanupTask, within: environment.quitBound) }
  } // End of func stop()

  /// Returns once no install is under way (the quit's deadline waits for it, so the app never
  /// exits between the swap's start and the end of its checks and any rollback).
  public func installEnded() async {
    while let installTask { await installTask.value }
  }

  /// Returns once the eligibility read, the prepare, the install and the cleanup under way
  /// have ended (tests).
  func workEnded() async {
    await offerTask?.value
    await cleanupTask?.value
    while let task = prepareTask ?? installTask { await task.value }
  }
}
