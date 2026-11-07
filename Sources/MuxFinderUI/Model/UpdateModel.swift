import AppKit
import Foundation
import MuxFinderCore
import Observation

/// What the update model runs on (PLAN.md D39 *The notice (I-13c1)*): the scheduler over the
/// real transport and state store, the toggle's preferences file, the running version and
/// build, the opener of "What's new" and the wake notifications. Only the menu bar app in
/// normal mode has one (`AppLaunchOptions.createsUpdateMachinery`); every other mode, the
/// self-tests and the previews have none, so they create no transport, scheduler or state
/// store and read, write and send nothing of the update check.
public struct UpdateEnvironment: Sendable {
  /// The scheduler (not started).
  public var scheduler: UpdateScheduler
  /// Where `checkForUpdatesAutomatically` is read and saved (`PreferencesStore` in the app);
  /// `nil` reads it as on and saves nothing.
  public var preferences: (any UpdateCheckSettingStoring)?
  /// The running app's `CFBundleShortVersionString`, or `nil`.
  public var runningVersion: String?
  /// The running app's `CFBundleVersion`, or `nil`.
  public var runningBuild: String?
  /// Opens a release page in the default browser (`NSWorkspace.shared.open` in the app; tests
  /// record).
  public var openURL: @MainActor @Sendable (URL) -> Void
  /// Where `NSWorkspace.didWakeNotification` is posted (`NSWorkspace.shared.notificationCenter`
  /// in the app; tests post to a private centre); `nil` observes no wake.
  public var wakeNotifications: NotificationCenter?
  /// The wall clock the status line's relative time is measured against.
  public var now: @Sendable () -> Date
  /// The one-click update flow's pipeline, cleanup and terminator (PLAN.md D39 *The update
  /// flow (I-13c2a)*); `nil` runs no flow and no leftover cleanup.
  public var flow: UpdateFlowEnvironment?

  /// Creates an environment from its parts.
  public init(
    scheduler: UpdateScheduler, preferences: (any UpdateCheckSettingStoring)?,
    runningVersion: String?, runningBuild: String?,
    openURL: @escaping @MainActor @Sendable (URL) -> Void,
    wakeNotifications: NotificationCenter? = nil,
    now: @escaping @Sendable () -> Date = { Date() },
    flow: UpdateFlowEnvironment? = nil
  ) {
    self.scheduler = scheduler
    self.preferences = preferences
    self.runningVersion = runningVersion
    self.runningBuild = runningBuild
    self.openURL = openURL
    self.wakeNotifications = wakeNotifications
    self.now = now
    self.flow = flow
  } // End of init(scheduler:preferences:runningVersion:runningBuild:openURL:…)

  /// The real app's: `URLSessionUpdateTransport`, `UpdateStateStore` on
  /// `~/Library/Application Support/muxFinder/update-state.json`, the system clock, the
  /// version and build from `bundle`, `NSWorkspace` for "What's new" and its wake
  /// notifications, and the update flow's `UpdateFlowEnvironment.production(shortVersion:)`
  /// (the pipeline over the real update folder, `/usr/bin/open` for the relauncher,
  /// `NSApp.terminate`). Building it sends, reads, creates and writes nothing: the scheduler
  /// and the leftover cleanup run only once `UpdateModel.start()` starts them.
  @MainActor
  public static func production(
    preferences: any UpdateCheckSettingStoring, bundle: Bundle = .main
  ) -> UpdateEnvironment {
    let info = bundle.infoDictionary ?? [:]
    let version = info["CFBundleShortVersionString"] as? String
    let build = info["CFBundleVersion"] as? String
    let scheduler = UpdateScheduler(
      transport: URLSessionUpdateTransport(shortVersion: version),
      stateStore: UpdateStateStore(), runningVersion: version)
    return UpdateEnvironment(
      scheduler: scheduler, preferences: preferences, runningVersion: version,
      runningBuild: build, openURL: { SettingsEnvironment.openWithWorkspace($0) },
      wakeNotifications: NSWorkspace.shared.notificationCenter,
      flow: .production(shortVersion: version))
  } // End of static func production(preferences:bundle:)
}

/// A fixed update state for the popover and Settings galleries and tests (PLAN.md D39 *The
/// notice (I-13c1)*), from synthetic data with no scheduler.
public struct UpdateFixture: Sendable, Hashable {
  /// The scheduler's status, or `nil` before its first publication.
  public var status: UpdateCheckStatus?
  /// Whether automatic checks are on.
  public var automaticChecks = true
  /// Whether "Check for updates…" was pressed and its check has not ended.
  public var isCheckRequested = false
  /// The running version.
  public var runningVersion: String? = "0.2.0"
  /// The running build.
  public var runningBuild: String? = "2"
  /// The status line's clock.
  public var now: Date
  /// The update flow's offer and state the notice shows (PLAN.md D39 *The update views
  /// (I-13c2b)*); `nil` shows the inert flow's (no offer, idle).
  public var flow: UpdateFlowFixture?

  /// A fixture from its parts.
  public init(
    status: UpdateCheckStatus?, automaticChecks: Bool = true, isCheckRequested: Bool = false,
    runningVersion: String? = "0.2.0", runningBuild: String? = "2", now: Date,
    flow: UpdateFlowFixture? = nil
  ) {
    self.status = status
    self.automaticChecks = automaticChecks
    self.isCheckRequested = isCheckRequested
    self.runningVersion = runningVersion
    self.runningBuild = runningBuild
    self.now = now
    self.flow = flow
  } // End of init(status:automaticChecks:isCheckRequested:runningVersion:runningBuild:now:flow:)
}

/// A fixed update flow for the popover gallery and tests (PLAN.md D39 *The update views
/// (I-13c2b)*): the offer and state the notice renders, with no pipeline behind them (the
/// fixture's `UpdateFlow` stays inert, so its buttons run nothing).
public struct UpdateFlowFixture: Sendable, Hashable {
  /// The offer (`UpdateFlow.offer`).
  public var offer: UpdateFlowOffer?
  /// The state (`UpdateFlow.state`).
  public var state: UpdateFlowState

  /// A fixture from its parts.
  public init(offer: UpdateFlowOffer?, state: UpdateFlowState = .idle) {
    self.offer = offer
    self.state = state
  }

  /// What a live flow's `canUpdate` would be: Update offered, from idle or a failure.
  public var canUpdate: Bool {
    guard offer == .update else { return false }
    switch state {
    case .idle, .failed: return true
    default: return false
    }
  }
}

/// The update check's state for the popover's notice, the menu bar icon's dot and Settings ›
/// General (PLAN.md D39 *The notice (I-13c1)*): live over an `UpdateEnvironment` (normal mode
/// only), fixed over an `UpdateFixture`, or inert (no machinery: nothing shown, nothing run).
@MainActor
@Observable
public final class UpdateModel {
  /// The scheduler's latest status; `nil` before its first publication.
  public private(set) var status: UpdateCheckStatus?
  /// Whether automatic checks are on (`checkForUpdatesAutomatically`).
  public private(set) var automaticChecks = true
  /// Why the toggle could not be saved, if it could not.
  public private(set) var toggleProblem: String?
  /// Whether "Check for updates…" was pressed and its check has not ended.
  public private(set) var isCheckRequested = false
  /// The clock the status line's relative time is measured against.
  public private(set) var now: Date
  /// The running version.
  public let runningVersion: String?
  /// The running build.
  public let runningBuild: String?
  /// Whether there is update machinery or a fixture: Settings shows its section only then.
  public let isAvailable: Bool
  /// The one-click update flow (PLAN.md D39 *The update flow (I-13c2a)*): live over
  /// `UpdateEnvironment.flow`, inert otherwise.
  public let flow: UpdateFlow
  /// The flow's offer and state a fixture shows instead of the inert flow's (PLAN.md D39 *The
  /// update views (I-13c2b)*); `nil` for a live or inert model.
  public let flowFixture: UpdateFlowFixture?
  /// Speaks a VoiceOver announcement (a failure or the ask appearing, PLAN.md D39 *The update
  /// views (I-13c2b)*), only while the notice shows (`pendingAnnouncement` otherwise):
  /// `AppModel` passes its own (`AppEnvironment.announce`); `nil` says nothing; tests record
  /// through it.
  @ObservationIgnored public var announce: (@MainActor @Sendable (String) -> Void)?

  /// The environment, for a live model.
  @ObservationIgnored private let environment: UpdateEnvironment?
  /// What the flow's state last had to say (`nil` after a state with nothing to say), so each
  /// appearance of a failure or the ask is announced once.
  @ObservationIgnored private var lastAnnouncement: String?
  /// The latest failure or ask that appeared while the notice was hidden (the popover closed,
  /// the switcher open in its place, or a confirmation over its main layout), said once when
  /// the notice shows; dropped if the flow's state no longer says it by then.
  @ObservationIgnored private(set) var pendingAnnouncement: String?
  /// Whether the popover panel shows (the notice counts as seen while it does).
  @ObservationIgnored private var isPopoverVisible = false
  /// The version whose seen mark is being written, so it is written once.
  @ObservationIgnored private var markingSeen: UpdateVersion?
  /// Where the model is in its life.
  @ObservationIgnored private var lifecycle = Lifecycle.idle
  /// Reads the scheduler's statuses.
  @ObservationIgnored private var updatesTask: Task<Void, Never>?
  /// Starts the scheduler.
  @ObservationIgnored private var startTask: Task<Void, Never>?
  /// The wake observer.
  @ObservationIgnored private var wakeObserver: (any NSObjectProtocol)?
  /// Toggle saves and manual checks in progress, awaited by `stop()`.
  @ObservationIgnored private var work: [Int: Task<Void, Never>] = [:]
  /// The last work number handed out.
  @ObservationIgnored private var lastWorkID = 0
  /// The toggle's changes so far: one made while the setting is read keeps the read value from
  /// replacing it.
  @ObservationIgnored private var toggleRevision = 0
  /// The toggle's value as the preferences store holds it, as far as the model knows: the value
  /// read at start, then each saved change. A refused save puts the toggle back to it.
  @ObservationIgnored private var savedAutomaticChecks = true
  /// The last toggle change's work: the next change's waits for it (the first's for the start),
  /// so the saves and the scheduler's calls keep the order of the changes.
  @ObservationIgnored private var lastToggleWork: Task<Void, Never>?

  /// Where the model is in its life.
  private enum Lifecycle {
    /// Not started.
    case idle
    /// Started.
    case running
    /// Stopped.
    case stopped
  }

  /// A live model over `environment`; nothing runs until `start()`.
  public init(environment: UpdateEnvironment) {
    self.environment = environment
    runningVersion = environment.runningVersion
    runningBuild = environment.runningBuild
    now = environment.now()
    isAvailable = true
    flow =
      environment.flow.map { UpdateFlow(environment: $0, openURL: environment.openURL) }
      ?? .inert()
    flowFixture = nil
    if flow.isAvailable { watchFlow() }
  }

  /// A model showing `fixture`; it never runs anything.
  public init(fixture: UpdateFixture) {
    environment = nil
    status = fixture.status
    automaticChecks = fixture.automaticChecks
    isCheckRequested = fixture.isCheckRequested
    runningVersion = fixture.runningVersion
    runningBuild = fixture.runningBuild
    now = fixture.now
    isAvailable = true
    flow = .inert()
    flowFixture = fixture.flow
    lifecycle = .stopped
  } // End of init(fixture:)

  /// A model with no update machinery: no notice, no dot, no Settings section.
  private init() {
    environment = nil
    runningVersion = nil
    runningBuild = nil
    now = Date(timeIntervalSince1970: 0)
    isAvailable = false
    flow = .inert()
    flowFixture = nil
    lifecycle = .stopped
  }

  /// The inert model of every mode but the normal launch.
  public static func inert() -> UpdateModel { UpdateModel() }

  // MARK: - What is shown

  /// The release the popover's notice offers: the status's offer while it is newer than the
  /// running version, else `nil`.
  public var notice: UpdateRelease? {
    UpdateNotice.release(offer: status?.offer, runningVersion: runningVersion)
  }

  /// The release the popover's notice shows (PLAN.md D39 *The update views (I-13c2b)*): the
  /// notice, else the release the flow is working on (`UpdateFlow.preparedRelease`), so the
  /// notice stays while an update runs, and after Not now when a later check no longer offers
  /// a newer release; `nil` when there is neither. The notice's title, What's new and Release
  /// page all name it.
  public var displayedRelease: UpdateRelease? { notice ?? flow.preparedRelease }

  /// The popover's update notice (PLAN.md D39 *The update views (I-13c2b)*), through
  /// `UpdateNoticeContent.make`: the shown release (`displayedRelease`) with the flow's offer,
  /// state and `canUpdate` (a fixture's instead, when it has one); `nil` when there is nothing
  /// to show.
  public var noticeContent: UpdateNoticeContent? {
    if let fixture = flowFixture {
      guard let release = displayedRelease else { return nil }
      return UpdateNoticeContent.make(
        release: release, offer: fixture.offer, state: fixture.state,
        canUpdate: fixture.canUpdate)
    }
    let state = flow.state
    guard let release = displayedRelease else { return nil }
    return UpdateNoticeContent.make(
      release: release, offer: flow.offer, state: state, canUpdate: flow.canUpdate,
      preparedRelease: flow.preparedRelease)
  } // End of var noticeContent

  /// Whether the menu bar icon shows the dot: a notice whose version is greater than the seen
  /// one (or none is recorded).
  public var showsDot: Bool {
    UpdateNotice.showsDot(release: notice, seen: status?.noticeSeenVersion)
  }

  /// The status item's accessibility label.
  public var statusItemLabel: String {
    UpdateNotice.statusItemLabel(showsDot: showsDot)
  }

  /// Whether a check is in flight or was asked for ("Check for updates…" is disabled).
  public var isChecking: Bool {
    if isCheckRequested { return true }
    if case .checking = status?.activity { return true }
    return false
  }

  /// Settings › General's status line: the check's state or outcome, if any, then when it
  /// last succeeded.
  public var statusLines: [String] {
    UpdateNotice.statusLines(
      status: status, isCheckRequested: isCheckRequested, runningVersion: runningVersion,
      runningBuild: runningBuild, now: now)
  }

  // MARK: - Lifecycle

  /// Starts a live model once: starts the update flow's leftover cleanup (off the main actor),
  /// reads the toggle, observes the scheduler's statuses and the Mac's wake, and starts the
  /// scheduler with the toggle's value (its first automatic check at least 5 s later). A
  /// toggle change made while the setting is read wins over the value read. Never blocks the
  /// caller.
  public func start() {
    guard lifecycle == .idle, let environment else { return }
    lifecycle = .running
    flow.startCleanup()
    let scheduler = environment.scheduler
    wakeObserver = environment.wakeNotifications?.addObserver(
      forName: NSWorkspace.didWakeNotification, object: nil, queue: nil
    ) { _ in
      Task { await scheduler.woke() }
    }
    let revision = toggleRevision
    startTask = Task { [weak self] in
      let on = await Self.readToggle(environment.preferences)
      guard let self, self.lifecycle == .running else { return }
      // Toggle saves wait for this task, so none has been saved yet: the store holds `on`.
      self.savedAutomaticChecks = on
      if self.toggleRevision == revision { self.automaticChecks = on }
      let updates = await scheduler.updates()
      self.updatesTask = Task { [weak self] in
        for await status in updates { self?.apply(status) }
      }
      // The toggle as it is now; a change still to be saved tells the scheduler once saved.
      await scheduler.start(automaticChecks: self.automaticChecks)
    }
  } // End of func start()

  /// Stops the update flow (`UpdateFlow.stop()`: a prepare cancelled, an install step allowed
  /// to end, a prepared update discarded, each bounded), the scheduler (its timer, its check
  /// in flight and its stream), the wake observer and the work in progress, and returns once
  /// they ended. Later calls do nothing.
  public func stop() async {
    guard lifecycle != .stopped else { return }
    lifecycle = .stopped
    if let wakeObserver { environment?.wakeNotifications?.removeObserver(wakeObserver) }
    wakeObserver = nil
    await flow.stop()
    await startTask?.value
    await environment?.scheduler.stop()
    await updatesTask?.value
    for task in work.values { await task.value }
  } // End of func stop()

  /// Reads `checkForUpdatesAutomatically`: on when there is no store or it cannot be read.
  private static func readToggle(_ preferences: (any UpdateCheckSettingStoring)?) async -> Bool {
    guard let preferences else { return true }
    guard let loaded = try? await preferences.load() else { return true }
    return loaded.preferences.checkForUpdatesAutomatically
  }

  /// Takes a status the scheduler published (the notice may appear with it, and a pending
  /// announcement with the notice).
  private func apply(_ status: UpdateCheckStatus) {
    self.status = status
    if let environment { now = environment.now() }
    markSeenIfShown()
    deliverPendingAnnouncement()
  }

  // MARK: - Intents

  /// Measures relative times from now (Settings shows the status line).
  public func refreshNow() {
    if let environment { now = environment.now() }
  }

  /// The popover panel's main layout (where the notice is) showed or hid
  /// (`AppModel.updateNoticeVisibility()`); while it shows with the notice in it, the notice's
  /// version is recorded as seen, and a failure or ask that appeared while it was hidden is
  /// announced (`deliverPendingAnnouncement()`).
  public func popoverVisibilityChanged(_ isVisible: Bool) {
    isPopoverVisible = isVisible
    markSeenIfShown()
    deliverPendingAnnouncement()
  }

  /// Whether the notice shows: the popover's main layout is visible with the notice in it.
  private var isNoticeVisible: Bool { isPopoverVisible && displayedRelease != nil }

  /// Records the notice's version as seen through the scheduler, once, while the popover shows
  /// it and the dot is on; tells the update flow the notice shows (its eligibility read once
  /// per version), or that there is none.
  private func markSeenIfShown() {
    if lifecycle == .running, isPopoverVisible || notice == nil { flow.noticeShown(notice) }
    guard isPopoverVisible, lifecycle == .running, let environment, showsDot,
      let version = notice?.version, markingSeen != version
    else { return }
    markingSeen = version
    let scheduler = environment.scheduler
    track { [weak self] in
      let recorded = await scheduler.markNoticeSeen(version)
      if !recorded, self?.markingSeen == version { self?.markingSeen = nil }
    }
  } // End of func markSeenIfShown()

  /// "What's new": opens the shown release's page (`displayedRelease`) through the injected
  /// opener.
  public func openWhatsNew() {
    openDisplayedReleasePage()
  }

  /// "Release page" (after a failure): opens the shown release's page (`displayedRelease`)
  /// through the injected opener.
  public func openReleasePage() {
    openDisplayedReleasePage()
  }

  /// Opens `displayedRelease`'s page through the environment's opener (a fixture's and the
  /// inert model open nothing).
  private func openDisplayedReleasePage() {
    guard let environment, let page = displayedRelease?.pageURL else { return }
    environment.openURL(page)
  }

  /// A notice button was pressed: calls its method (PLAN.md D39 *The update views
  /// (I-13c2b)*). The flow's methods do nothing in a state they do not belong to, and a
  /// fixture's or the inert model's run nothing.
  public func perform(_ action: UpdateNoticeAction) {
    switch action {
    case .whatsNew: openWhatsNew()
    case .update: flow.update()
    case .download: flow.download()
    case .cancel: flow.cancel()
    case .quitAndInstall: flow.quitAndInstall()
    case .notNow: flow.notNow()
    case .installAndRelaunch: flow.installAndRelaunch()
    case .releasePage: openReleasePage()
    }
  } // End of func perform(_:)

  /// Follows the live flow's state: each change re-arms the observation and announces a
  /// failure or the ask once when it appears, or once the notice shows it
  /// (`flowStateChanged()`).
  private func watchFlow() {
    withObservationTracking {
      _ = flow.state
    } onChange: { [weak self] in
      Task { @MainActor in self?.flowStateChanged() }
    }
  }

  /// The flow's state changed: unless the model stopped (a quit), watches on and, once per
  /// appearance of a failure or the ask, makes what it says the pending announcement (the
  /// latest only: a state with nothing to say clears it), which is said at once while the
  /// notice shows, else when it shows.
  private func flowStateChanged() {
    guard lifecycle != .stopped else { return }
    watchFlow()
    let text = currentAnnouncement
    guard text != lastAnnouncement else { return }
    lastAnnouncement = text
    pendingAnnouncement = text
    deliverPendingAnnouncement()
  }

  /// What the flow's state says now (`UpdateNoticeContent.announcement(state:version:)`, with
  /// the prepared release's version, else the notice's), or `nil`.
  private var currentAnnouncement: String? {
    let version = (flow.preparedRelease ?? notice)?.version
    return UpdateNoticeContent.announcement(state: flow.state, version: version)
  }

  /// Tells VoiceOver the pending announcement once, while the notice shows; drops it when the
  /// flow's state no longer says it (the state moved on while the notice was hidden) or the
  /// model stopped.
  private func deliverPendingAnnouncement() {
    guard let text = pendingAnnouncement else { return }
    guard lifecycle != .stopped, text == currentAnnouncement else {
      pendingAnnouncement = nil
      return
    }
    guard isNoticeVisible else { return }
    pendingAnnouncement = nil
    announce?(text)
  }

  /// "Check for updates…": one manual check (with automatic checks on or off; a rate limit
  /// answers without sending), its outcome shown in the status line.
  public func checkNow() {
    guard lifecycle == .running, let environment, !isChecking else { return }
    isCheckRequested = true
    let scheduler = environment.scheduler
    track { [weak self] in
      _ = await scheduler.checkNow()
      self?.isCheckRequested = false
      self?.refreshNow()
    }
  }

  /// The toggle: once the start has read the setting and started the scheduler, and the change
  /// before it has ended, saves `checkForUpdatesAutomatically` through the preferences store
  /// and then tells the scheduler the toggle as it is; a refused save puts the toggle back to
  /// the saved value and says why.
  public func setAutomaticChecks(_ on: Bool) {
    guard lifecycle == .running, let environment, on != automaticChecks else { return }
    automaticChecks = on
    toggleRevision += 1
    toggleProblem = nil
    let scheduler = environment.scheduler
    let preferences = environment.preferences
    let before = lastToggleWork ?? startTask
    lastToggleWork = track { [weak self] in
      // After the start (its read never replaces this change, its scheduler start comes first)
      // and after the change before this one, so the saves land in order.
      await before?.value
      do {
        if let preferences { _ = try await preferences.setCheckForUpdatesAutomatically(on) }
        self?.savedAutomaticChecks = on
      } catch {
        if let self, self.automaticChecks == on {
          self.automaticChecks = self.savedAutomaticChecks
          self.toggleProblem = "Couldn't save the setting: \(error.localizedDescription)"
        }
      }
      guard let self else { return }
      await scheduler.setAutomaticChecks(self.automaticChecks)
    }
  } // End of func setAutomaticChecks(_:)

  /// Runs `body` as tracked work, which `stop()` awaits, and returns its task.
  @discardableResult
  private func track(_ body: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
    lastWorkID += 1
    let id = lastWorkID
    let task = Task { [weak self] in
      await body()
      self?.work[id] = nil
    }
    work[id] = task
    return task
  }

  /// Returns once the start and the tracked work have ended (tests).
  func workEnded() async {
    await startTask?.value
    while let task = work.values.first { await task.value }
  }
}

/// The notice's, the dot's and the status line's rules and wording (PLAN.md D39 *The notice
/// (I-13c1)*), pure so the tests and the galleries share them.
public enum UpdateNotice {
  /// The status item's label with the dot.
  public static let labelWithDot = "muxFinder, update available"
  /// The status item's label without it.
  public static let label = "muxFinder"
  /// The line while a check is in flight.
  public static let checking = "Checking for updates…"
  /// The line when no check ever succeeded.
  public static let notCheckedYet = "Not checked yet"

  /// The newer release `offer` holds when it is strictly newer than `runningVersion` (an
  /// unparseable running version offers nothing), else `nil`.
  public static func release(offer: UpdateOffer?, runningVersion: String?) -> UpdateRelease? {
    guard case .newer(let release)? = offer,
      let running = runningVersion.flatMap({ UpdateVersion($0) }), release.version > running
    else { return nil }
    return release
  }

  /// Whether the dot shows for `release`: its version greater than `seen`, or none seen.
  public static func showsDot(release: UpdateRelease?, seen: UpdateVersion?) -> Bool {
    guard let release else { return false }
    guard let seen else { return true }
    return release.version > seen
  }

  /// The status item's accessibility label.
  public static func statusItemLabel(showsDot: Bool) -> String {
    showsDot ? labelWithDot : label
  }

  /// "muxFinder 0.3.0 is available".
  public static func available(_ version: UpdateVersion) -> String {
    "muxFinder \(version) is available"
  }

  /// "You're up to date (0.2.0 (2))", in the form Settings uses for the version and build.
  public static func upToDate(runningVersion: String?, runningBuild: String?) -> String {
    guard let runningVersion else { return "You're up to date" }
    guard let runningBuild else { return "You're up to date (\(runningVersion))" }
    return "You're up to date (\(runningVersion) (\(runningBuild)))"
  }

  /// The phrase of a failed check: short, no URL or header.
  public static func failure(_ failure: UpdateCheckFailure) -> String {
    switch failure {
    case .offline: return "Couldn't check: no connection"
    case .timedOut: return "Couldn't check: no answer"
    case .httpStatus(let status): return "Couldn't check: GitHub answered \(status)"
    case .unreadableAnswer: return "Couldn't check: the answer couldn't be read"
    case .notModifiedWithoutRelease: return "Couldn't check: the answer had no release"
    case .cancelled: return "Couldn't check: the check was stopped"
    case .other: return "Couldn't check: something went wrong"
    }
  } // End of static func failure(_:)

  /// "Couldn't check: GitHub is limiting requests until 14:05" (24-hour time in `timeZone`).
  public static func rateLimited(until: Date, timeZone: TimeZone = .current) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = timeZone
    formatter.dateFormat = "HH:mm"
    return "Couldn't check: GitHub is limiting requests until \(formatter.string(from: until))"
  }

  /// The phrase of a successful check that offers nothing.
  public static func nothingOffered(_ reason: UpdateNoOfferReason) -> String {
    reason == .runningVersionUnknown
      ? "No update offered: this build has no version number"
      : "No update offered: the latest release can't be used"
  }

  /// The phrase of `outcome`.
  public static func phrase(
    _ outcome: UpdateCheckOutcome, runningVersion: String?, runningBuild: String?,
    timeZone: TimeZone = .current
  ) -> String {
    switch outcome {
    case .checked(.upToDate):
      return upToDate(runningVersion: runningVersion, runningBuild: runningBuild)
    case .checked(.newer(let release)): return available(release.version)
    case .checked(.nothingOffered(let reason)): return nothingOffered(reason)
    case .rateLimited(let until): return rateLimited(until: until, timeZone: timeZone)
    case .failed(let reason): return failure(reason)
    }
  } // End of static func phrase(_:runningVersion:runningBuild:timeZone:)

  /// Settings' status line: first the check in flight ("Checking for updates…"), else this
  /// run's last outcome, else what the kept release offers (newer or up to date); then "Last
  /// checked <relative time>" from the last successful check, or "Not checked yet".
  public static func statusLines(
    status: UpdateCheckStatus?, isCheckRequested: Bool, runningVersion: String?,
    runningBuild: String?, now: Date, timeZone: TimeZone = .current
  ) -> [String] {
    var lines: [String] = []
    let inFlight = status.map { $0.activity != .idle } ?? false
    if isCheckRequested || inFlight {
      lines.append(checking)
    } else if let outcome = status?.lastCheck?.outcome {
      lines.append(
        phrase(
          outcome, runningVersion: runningVersion, runningBuild: runningBuild,
          timeZone: timeZone))
    } else if let release = release(offer: status?.offer, runningVersion: runningVersion) {
      lines.append(available(release.version))
    } else if case .upToDate? = status?.offer {
      lines.append(upToDate(runningVersion: runningVersion, runningBuild: runningBuild))
    }
    if let success = status?.lastSuccessfulCheck {
      lines.append(RelativeTime.lastChecked(success, now: now))
    } else {
      lines.append(notCheckedYet)
    }
    return lines
  } // End of static func statusLines(status:isCheckRequested:runningVersion:…)
}
