import Foundation
import MuxFinderCore
import os

/// Why a self-test step failed, in plain words (no user data: the session is the run's own).
struct SelfTestFailure: Error {
  /// The explanation.
  let detail: String

  /// Creates a failure.
  init(_ detail: String) {
    self.detail = detail
  }
}

/// Holds the attach coordinator the self-test's model built, for cleanup.
final class CoordinatorBox: Sendable {
  /// The coordinator, once built.
  private let state = OSAllocatedUnfairLock<AttachCoordinator?>(initialState: nil)

  /// Creates an empty box.
  init() {}

  /// Keeps `coordinator`.
  func set(_ coordinator: AttachCoordinator) {
    state.withLock { $0 = coordinator }
  }

  /// The coordinator, if built.
  var value: AttachCoordinator? { state.withLock { $0 } }
}

/// Runs one self-test (PLAN.md D25) through the real `AppModel` path: a model over an
/// in-memory This Mac (no `hosts.json` is read or written; no onboarding, Settings, popover or
/// menu bar item), whose engine discovers This Mac's default tmux server and whose attach
/// coordinator's attachment index asks only connections owned by launch tabs this run opened
/// (`LaunchTabRecorder`), so the user's tmux connections never get a command, not even the
/// read-only identity question.
///
/// Once the attachment is confirmed, it checks that the coordinator buried its launch tab
/// (PLAN.md D29: `AttachResult.burial` `buried`, the tab in `buried_sessions` and in no tab),
/// and after its Detach that the tab left both by itself: the coordinator talks to iTerm2
/// through a `RecordingITerm2Integration`, so a restore or `Close` of the coordinator's (its
/// recovery of a dead buried tab) that may have removed the tab fails the step. Both checks
/// read only `ListSessions` and look only at the run's own launch tab.
///
/// Safety: it creates, attaches, detaches and kills only its own `muxfinder-test-<hex>`
/// session; it never closes an iTerm2 tab (detaching is `detach-client` through the core,
/// which waits until the launch tab is 10 s old), never runs `kill-server`, and kills its
/// session only while it is still exactly the session it created
/// (`CreatedSession.killIfUnchangedArguments`). Every wait is bounded (`SelfTestTimeouts`). On
/// any failure, and when its task is cancelled (SIGTERM or SIGINT), it cleans up: it cancels
/// the model's actions in progress and waits for them (at most the attach timeout), detaches
/// its session's attachments in its own launch tabs through the core, waits until every launch
/// tab it opened is older than the coordinator's minimum age, kills its session, and reports
/// `failed`. An action still running after that wait makes it detach and kill nothing (a launch
/// tab of unknown age may still attach the session) and print what it left and how to clean up.
///
/// Keep mode (`SelfTestRequest.keep`) stops after the attachment is confirmed and its launch
/// tab buried, and reports `kept` with the session name, the connection id and the gateway
/// session id; the app then
/// waits for SIGTERM and quits through `AppTermination`, leaving the session and the
/// connection in place.
@MainActor
public final class SelfTestDriver {
  /// How a self-test ended.
  public enum Outcome: Sendable, Equatable {
    /// Every step passed and everything was cleaned up.
    case passed
    /// A step failed or the run was interrupted; cleanup ran.
    case failed
    /// Keep mode: the attachment is confirmed and left in place.
    case kept(KeepInfo)
  }

  /// What keep mode leaves running.
  public struct KeepInfo: Sendable, Equatable {
    /// The test session's name.
    public var sessionName: String
    /// The iTerm2 tmux connection id.
    public var connectionID: String
    /// The iTerm2 session owning the connection (the launch tab).
    public var gatewaySessionID: String

    /// The line the app prints.
    public var line: String {
      "muxFinder self-test keep: session \(sessionName) connection \(connectionID) gateway "
        + "\(gatewaySessionID)"
    }

    /// How to clean up once the app quit: the probe's detach bound to the gateway, then the
    /// kill of the session by its exact name.
    public var cleanupLines: [String] {
      [
        "muxFinder self-test keep: after quitting, clean up with",
        "  swift run muxfinder-probe detach --connection \(connectionID) --gateway "
          + "\(gatewaySessionID)",
        "  tmux kill-session -t '=\(sessionName)'",
      ]
    }
  } // End of struct KeepInfo

  /// The self-test.
  public let request: SelfTestRequest
  /// The parts it runs on.
  let seams: SelfTestSeams
  /// This Mac, in memory only.
  public let host = HostConfig(displayName: "This Mac", mode: .local)
  /// The launch tabs this run opened.
  public let recorder = LaunchTabRecorder()
  /// What the coordinator talks to: `seams.iTerm2`, with each bury, restore and `Close`
  /// recorded before it is sent, so the departure step can tell whether the launch tab left
  /// by itself.
  let coordinatorITerm2: RecordingITerm2Integration
  /// The model under test, once built.
  public private(set) var model: AppModel?
  /// The coordinator the model built.
  let coordinatorBox = CoordinatorBox()
  /// The test session as tmux reported it (or as cleanup found it).
  private(set) var created: CreatedSession?
  /// When creating the test session started (seconds since 1970).
  private var creationStartedAt: Int64?
  /// The confirmed attachment.
  private(set) var confirmed: AttachmentRecord?
  /// What became of the confirmed attachment's launch tab (`AttachResult.burial`).
  private var confirmedBurial: LaunchTabBurial?
  /// Whether the detach step detached the attachment.
  private var detached = false
  /// Steps that passed.
  public private(set) var passedSteps = 0

  /// A driver for `request` over `seams`. Nothing runs until `run()`.
  public init(request: SelfTestRequest, seams: SelfTestSeams) {
    self.request = request
    self.seams = seams
    coordinatorITerm2 = RecordingITerm2Integration(base: seams.iTerm2)
  }

  /// The test session's key on This Mac, once created.
  var sessionKey: SessionKey? {
    created.map { SessionKey(hostID: host.id, server: $0.server, sessionID: $0.sessionID) }
  }

  // MARK: - Running

  /// Runs the steps and returns how the self-test ended. Cancelling the calling task
  /// interrupts the step in progress; cleanup then runs to its end in a task of its own.
  public func run() async -> Outcome {
    output(
      "muxFinder self-test \(request.kind.rawValue): session \(seams.sessionName)"
        + (request.keep ? ", keep mode" : ""))
    do {
      try await setUp()
      if let kept = try await runSteps() { return .kept(kept) }
      await stopModel()
      output("muxFinder self-test \(request.kind.rawValue): passed (\(passedSteps) steps)")
      return .passed
    } catch {
      await Task { await self.cleanUp() }.value
      output("muxFinder self-test \(request.kind.rawValue): failed")
      return .failed
    }
  } // End of func run()

  /// The steps of the self-test; returns what keep mode leaves running, or `nil` when every
  /// step ran.
  private func runSteps() async throws -> KeepInfo? {
    switch request.kind {
    case .attachLocal:
      try await step(1, "create session") { try await self.createTestSession() }
      try await step(2, "listed") { try await self.startAndWaitForSession() }
      try await step(3, "open (5 clicks)") { try await self.openConfirmed() }
      try await step(4, "launch tab buried") { try await self.checkLaunchTabBuried() }
      if request.keep { return keepInfo() }
      try await step(5, "open again") { try await self.openFocused() }
      try await step(6, "detach from this Mac") { try await self.detachHere() }
      try await step(7, "launch tab left") { try await self.checkLaunchTabLeft() }
      try await step(8, "kill session") { try await self.killTestSession() }
    case .newSessionLocal:
      try await step(1, "listed This Mac") { try await self.startAndWaitForHost() }
      try await step(2, "new session") { try await self.createThroughSheet() }
      try await step(3, "launch tab buried") { try await self.checkLaunchTabBuried() }
      if request.keep { return keepInfo() }
      try await step(4, "collision") { try await self.collideThroughSheet() }
      try await step(5, "detach from this Mac") { try await self.detachHere() }
      try await step(6, "launch tab left") { try await self.checkLaunchTabLeft() }
      try await step(7, "kill session") { try await self.killTestSession() }
    }
    return nil
  } // End of func runSteps()

  /// Runs one step and prints its PASS or FAIL line; rethrows its failure.
  private func step(
    _ number: Int,
    _ title: String,
    _ body: () async throws -> String
  ) async throws {
    let start = ContinuousClock.now
    do {
      let detail = try await body()
      output("PASS \(number) \(title) (\(Self.milliseconds(since: start)) ms): \(detail)")
      passedSteps += 1
    } catch {
      let detail: String
      switch error {
      case let failure as SelfTestFailure: detail = failure.detail
      case is CancellationError: detail = "interrupted"
      default: detail = "\(error)"
      }
      output("FAIL \(number) \(title) (\(Self.milliseconds(since: start)) ms): \(detail)")
      throw error
    }
  } // End of func step(_:_:_:)

  /// Checks iTerm2's API (read-only; it never launches iTerm2) and reports how many tmux
  /// connections this run did not open, which it never asks anything.
  private func setUp() async throws {
    let status = await seams.iTerm2.status()
    guard status.isConnected else {
      let kind = status.error?.kind ?? "unknown"
      let hint = kind == "timedOut" ? "; a modal iTerm2 dialog may be open" : ""
      output("FAIL setup: iTerm2's API is not reachable (\(kind)\(hint))")
      throw SelfTestFailure("setup")
    }
    let foreign: Int
    do {
      foreign = try await seams.iTerm2.listTmuxConnections().count
    } catch {
      output("FAIL setup: iTerm2's tmux connections could not be listed")
      throw SelfTestFailure("setup")
    }
    output(
      "setup: iTerm2 API connected (protocol \(status.protocolVersion ?? "?")), helper "
        + "\(seams.helperPath.path); \(foreign) tmux connection(s) this run did not open, which "
        + "it never asks")
  } // End of func setUp()

  // MARK: - Steps

  /// `attach-local` 1: creates the test session, its pane running `sleep`.
  private func createTestSession() async throws -> String {
    creationStartedAt = seams.wallClock()
    do throws(SessionCreationError) {
      let session = try await seams.tmux.createSession(
        named: seams.sessionName, command: sleepCommand, on: host)
      created = session
      return "\(session.sessionID.rawValue) running \(sleepCommand.joined(separator: " "))"
    } catch {
      throw SelfTestFailure("creating the session failed: \(error.kind)")
    }
  } // End of func createTestSession()

  /// `attach-local` 2: starts the model and waits until its engine lists the test session.
  private func startAndWaitForSession() async throws -> String {
    let model = startModel()
    await model.start()
    guard let created else { throw SelfTestFailure("no test session") }
    let host = self.host
    let key = try await waitFor("the engine to list the session", seams.timeouts.listing) {
      model.refreshState?.snapshot(of: host.id)?.sessions
        .first { created.matches($0.discovered) }?.key
    }
    return "listed as \(key.sessionID.rawValue) on This Mac"
  } // End of func startAndWaitForSession()

  /// `new-session-local` 1: starts the model and waits until This Mac answered.
  private func startAndWaitForHost() async throws -> String {
    let model = startModel()
    await model.start()
    let host = self.host
    _ = try await waitFor("This Mac to be listed", seams.timeouts.listing) {
      model.refreshState?.snapshot(of: host.id)?.isLive == true ? true : nil
    }
    return "This Mac listed"
  }

  /// `attach-local` 3: five clicks on Open in a row give one launch, confirmed by the core.
  private func openConfirmed() async throws -> String {
    let (model, key) = try current()
    let mark = model.finishedActions.count
    for _ in 0..<5 { model.open(key) }
    let result = try await attachResult(after: mark, for: key, model: model)
    guard result.isConfirmed, let connection = result.connectionID,
      let gateway = result.gatewaySessionID
    else { throw SelfTestFailure(Self.describe(result)) }
    guard model.activities[key] == .confirmed else {
      throw SelfTestFailure("the row does not show “Confirmed”")
    }
    let launches = recorder.launchCount(for: key)
    guard launches == 1, model.finishedActions.count == mark + 1 else {
      throw SelfTestFailure("\(launches) launch tab(s) for a burst of 5 clicks")
    }
    confirmed = AttachmentRecord(
      connectionID: connection, gatewaySessionID: gateway, launchID: result.launchID)
    confirmedBurial = result.burial
    return "confirmed: connection \(connection), gateway \(gateway), 1 launch for 5 clicks"
  } // End of func openConfirmed()

  /// `attach-local` 4: Open again focuses the attachment; no second launch.
  private func openFocused() async throws -> String {
    let (model, key) = try current()
    let mark = model.finishedActions.count
    model.open(key)
    let result = try await attachResult(after: mark, for: key, model: model)
    guard result.isFocused else { throw SelfTestFailure(Self.describe(result)) }
    guard result.connectionID == confirmed?.connectionID else {
      throw SelfTestFailure("focused another connection than the confirmed one")
    }
    guard recorder.launchCount(for: key) == 1, model.activities[key] == .focused else {
      throw SelfTestFailure("a second launch tab opened, or the row does not show the focus")
    }
    return "focused connection \(result.connectionID ?? "?"), still 1 launch"
  } // End of func openFocused()

  /// `new-session-local` 2: New session with the test name creates the session and attaches
  /// it, confirmed by the core; the sheet closes.
  private func createThroughSheet() async throws -> String {
    guard let model else { throw SelfTestFailure("no model") }
    creationStartedAt = seams.wallClock()
    let mark = model.finishedActions.count
    try fillSheet(model)
    model.createSession()
    guard model.newSessionDraft.state == .creating else {
      throw SelfTestFailure(
        "Create did not start: \(model.newSessionDraft.nameIssue ?? "the sheet refused")")
    }
    let record = try await waitFor("New session to end", seams.timeouts.attach) {
      model.finishedActions.dropFirst(mark).first { record in
        if case .created = record.outcome { return true }
        return false
      }
    }
    guard case .created(let result) = record.outcome else { throw SelfTestFailure("no result") }
    created = result.created
    guard let session = result.created, let key = record.key else {
      throw SelfTestFailure("creation failed: \(result.creationFailure?.kind ?? "?")")
    }
    guard let attach = result.attach, attach.isConfirmed, let connection = attach.connectionID,
      let gateway = attach.gatewaySessionID
    else { throw SelfTestFailure(result.attach.map(Self.describe) ?? "no attach") }
    guard model.panel == nil, model.activities[key] == .confirmed,
      recorder.launchCount(for: key) == 1
    else { throw SelfTestFailure("the sheet stayed open, or the row or launch count is wrong") }
    confirmed = AttachmentRecord(
      connectionID: connection, gatewaySessionID: gateway, launchID: attach.launchID)
    confirmedBurial = attach.burial
    return "created \(session.sessionID.rawValue) and confirmed: connection \(connection), "
      + "gateway \(gateway)"
  } // End of func createThroughSheet()

  /// `new-session-local` 3: New session with the same name is refused as a collision and offers
  /// "Open existing"; nothing launches.
  private func collideThroughSheet() async throws -> String {
    let (model, key) = try current()
    let tabs = recorder.launchTabs.count
    let mark = model.finishedActions.count
    try fillSheet(model)
    model.createSession()
    let record = try await waitFor("the second New session to end", seams.timeouts.attach) {
      model.finishedActions.dropFirst(mark).first { record in
        if case .created = record.outcome { return true }
        return false
      }
    }
    guard case .created(let result) = record.outcome,
      case .sessionExists(let check)? = result.creationFailure
    else { throw SelfTestFailure("not refused as a collision") }
    guard model.newSessionDraft.state == .collision, recorder.launchTabs.count == tabs,
      recorder.launchCount(for: key) == 1
    else { throw SelfTestFailure("the sheet does not offer “Open existing”, or a tab opened") }
    model.cancelPanel()
    return "refused (\(check.rawValue)), “Open existing” offered, nothing launched"
  } // End of func collideThroughSheet()

  /// Opens the New session sheet with This Mac and the test name.
  private func fillSheet(_ model: AppModel) throws {
    model.newSession()
    guard case .newSession = model.panel else { throw SelfTestFailure("the sheet did not open") }
    model.newSessionDraft.hostID = host.id
    model.newSessionDraft.name = seams.sessionName
  }

  /// "Detach from this Mac": offered, detaches with `detach-client` through the core, and the
  /// connection is gone (a read-only listing).
  private func detachHere() async throws -> String {
    let (model, key) = try current()
    guard model.canDetach(key) else { throw SelfTestFailure("Detach from this Mac not offered") }
    let mark = model.finishedActions.count
    model.detach(key)
    let record = try await waitFor("the detach to end", seams.timeouts.detach) {
      model.finishedActions.dropFirst(mark).first { $0.key == key }
    }
    guard case .detached(let result) = record.outcome else { throw SelfTestFailure("no detach") }
    guard result.outcome == .detached else {
      throw SelfTestFailure("detach ended \(result.outcome.rawValue)")
    }
    guard model.activities[key] == .detached else {
      throw SelfTestFailure("the row does not show “Detached”")
    }
    detached = true
    if let confirmed {
      let connections = try? await seams.iTerm2.listTmuxConnections()
      if connections?.contains(where: {
        $0.connectionID == confirmed.connectionID
          && $0.owningSessionID == confirmed.gatewaySessionID
      }) == true {
        throw SelfTestFailure("the connection is still listed after the detach")
      }
    }
    return "detached \(result.detaches.count) attachment(s) with detach-client; the session "
      + "keeps running"
  } // End of func detachHere()

  /// Both self-tests, once the attachment is confirmed (PLAN.md D29): the coordinator buried
  /// the launch tab (`AttachResult.burial` is `buried`; with iTerm2's own "Automatically bury
  /// the tmux client session" setting on, iTerm2 buried it first and the bury answered `OK`),
  /// and iTerm2 lists it in `buried_sessions` and in no tab within the burial timeout.
  private func checkLaunchTabBuried() async throws -> String {
    guard let gateway = confirmed?.gatewaySessionID else { throw SelfTestFailure("no attachment") }
    guard confirmedBurial == .buried else {
      let detail = confirmedBurial?.detail.map { " (\($0))" } ?? ""
      throw SelfTestFailure(
        "the launch tab was not buried: \(confirmedBurial?.kind ?? "no outcome")\(detail)")
    }
    let waited = try await waitForLaunchTab(gateway, at: .buried, within: seams.timeouts.burial)
    guard let elapsed = waited.elapsed else {
      throw SelfTestFailure(
        "\(Self.milliseconds(seams.timeouts.burial)) ms after the attach the launch tab is "
          + "\(waited.last.rawValue), not only in buried_sessions")
    }
    return "burial buried; the launch tab is in buried_sessions and in no tab "
      + "(\(Self.milliseconds(elapsed)) ms after the attach ended)"
  } // End of func checkLaunchTabBuried()

  /// Both self-tests, after the detach (PLAN.md D29): the launch tab leaves both iTerm2's tabs
  /// and `buried_sessions` by itself within the departure timeout (its helper restores it and
  /// exits, and the tab closes). A tab still listed fails the step, and so does one that left
  /// while the coordinator had sent a restore or a `Close` that may have touched it (its
  /// recovery of a dead buried tab; `coordinatorITerm2` records each before sending it, so any
  /// that could have removed the tab is there by the time the listing shows it gone). The tab
  /// is left as it is either way: the self-test never closes a tab.
  private func checkLaunchTabLeft() async throws -> String {
    guard let gateway = confirmed?.gatewaySessionID else { throw SelfTestFailure("no attachment") }
    let waited = try await waitForLaunchTab(gateway, at: .absent, within: seams.timeouts.departure)
    let touched = await coordinatorITerm2.restoresAndCloses(of: gateway)
    let restores = touched.filter { if case .setBuried = $0 { true } else { false } }.count
    let sent =
      "the coordinator sent \(restores) restore(s) and \(touched.count - restores) Close(s) that "
      + "may have touched it"
    guard let elapsed = waited.elapsed else {
      throw SelfTestFailure(
        "the launch tab was stranded \(waited.last.rawValue) "
          + "\(Self.milliseconds(seams.timeouts.departure)) ms after the detach"
          + (touched.isEmpty ? "" : "; \(sent)") + " (left as it is: the self-test closes no tab)")
    }
    guard touched.isEmpty else {
      throw SelfTestFailure(
        "the launch tab left \(Self.milliseconds(elapsed)) ms after the detach, but not by "
          + "itself: \(sent)")
    }
    return "the launch tab left its tab and buried_sessions by itself "
      + "\(Self.milliseconds(elapsed)) ms after the detach ended"
  } // End of func checkLaunchTabLeft()

  /// Where iTerm2 lists one launch tab (its own session id only).
  enum LaunchTabPlace: String, Sendable {
    /// In a tab of a window.
    case inTab = "in a tab"
    /// In `buried_sessions`.
    case buried = "in buried_sessions"
    /// Not listed at all.
    case absent = "gone"

    /// Where `sessions` lists `gateway`.
    init(of gateway: String, in sessions: ITerm2API.ListSessionsResponse) {
      if sessions.placement(ofSession: gateway) != nil {
        self = .inTab
      } else if sessions.buriedSessions.contains(where: { $0.uniqueIdentifier == gateway }) {
        self = .buried
      } else {
        self = .absent
      }
    } // End of init(of:in:)
  } // End of enum LaunchTabPlace

  /// Lists iTerm2's sessions (read-only; only `gateway` is looked at) every poll interval until
  /// `gateway` is at `wanted` or `timeout` passes; returns how long it took, or `nil` and where
  /// it was at the last look. A failed listing fails the step; cancelling the task throws.
  private func waitForLaunchTab(
    _ gateway: String,
    at wanted: LaunchTabPlace,
    within timeout: Duration
  ) async throws -> (elapsed: Duration?, last: LaunchTabPlace) {
    let start = ContinuousClock.now
    while true {
      try Task.checkCancellation()
      let sessions: ITerm2API.ListSessionsResponse
      do {
        sessions = try await seams.iTerm2.listSessions()
      } catch {
        throw SelfTestFailure("iTerm2's sessions could not be listed: \(error)")
      }
      let place = LaunchTabPlace(of: gateway, in: sessions)
      if place == wanted { return (ContinuousClock.now - start, place) }
      guard ContinuousClock.now - start < timeout else { return (nil, place) }
      try await Task.sleep(for: seams.timeouts.pollInterval)
    } // End of loop over the listings
  } // End of func waitForLaunchTab(_:at:within:)

  /// Kills the test session (only while it is still exactly that session).
  private func killTestSession() async throws -> String {
    guard let created else { throw SelfTestFailure("no test session") }
    let outcome = await seams.tmux.kill(created)
    guard outcome == .killed else { throw SelfTestFailure("kill ended \(outcome.rawValue)") }
    self.created = nil
    return "killed \(created.sessionID.rawValue), which was still running after the detach"
  }

  // MARK: - Cleanup

  /// After a failure or an interruption: cancels the model's actions and waits for them within
  /// the attach timeout, finds the test session by its exact name when its creation's output
  /// was lost, detaches its attachments in this run's launch tabs through the core
  /// (`detach-client`, never closing a tab), waits until every launch tab of the run is old
  /// enough, kills the session if it is still exactly the test session, prints the
  /// coordinator's log (kinds only) and stops the model.
  ///
  /// When an action is still running after that wait (a launch tab may still be opening, and
  /// its age is unknown), cleanup detaches and kills nothing, since ending the session could
  /// end a tab younger than iTerm2's 3 s limit: it reports what it left and how to clean up.
  func cleanUp() async {
    output("cleanup: started")
    let attachTimeout = seams.timeouts.attach
    let stillRunning = await model?.cancelSessionActions(within: attachTimeout) ?? []
    if created == nil, let started = creationStartedAt {
      created = await seams.tmux.findSession(
        named: seams.sessionName, createdNoEarlierThan: started - 2)
      if created != nil { output("cleanup: found the test session by its exact name") }
    }
    if stillRunning.isEmpty {
      await detachAndKill()
    } else {
      output(
        "cleanup: \(stillRunning.count) session action(s) still running after "
          + "\(Self.milliseconds(attachTimeout)) ms (\(stillRunning.joined(separator: ", "))); "
          + "nothing detached or killed, since a launch tab may still attach the session")
      if created != nil {
        output("cleanup: the test session is left; once its launch tabs are gone, clean up with")
        output("  tmux kill-session -t '=\(seams.sessionName)'")
      }
    }
    for event in await seams.diagnostics?.events() ?? [] where event.category == .attach {
      output("  log: \(event.outcome.rawValue) \(event.durationMs) ms \(event.detail)")
    }
    await stopModel()
    output("cleanup: done")
  } // End of func cleanUp()

  /// Cleanup once no action runs: detaches the test session's attachments in this run's launch
  /// tabs through the core, waits until every launch tab of the run is old enough, then kills
  /// the session if it is still exactly the test session.
  private func detachAndKill() async {
    if let key = sessionKey, !detached, let coordinator = coordinatorBox.value {
      let result = await coordinator.detach(session: key, on: host)
      output("cleanup: detach \(result.outcome.rawValue)")
    }
    if let newest = recorder.newestLaunch {
      let remaining = newest + seams.timeouts.launchTabAge - ContinuousClock.now
      if remaining > .zero {
        output("cleanup: waiting until every launch tab of this run is old enough")
        try? await Task.sleep(for: remaining)
      }
    }
    if let created {
      let outcome = await seams.tmux.kill(created)
      output("cleanup: kill \(outcome.rawValue)")
      if outcome == .killed { self.created = nil }
    }
  } // End of func detachAndKill()

  /// Stops the model (keep mode's quit, through the app's termination).
  public func shutdown() async {
    await stopModel()
  }

  /// Stops the model and prints the session actions its shutdown stopped waiting for, if any.
  private func stopModel() async {
    guard let report = await model?.shutdown(), !report.isComplete else { return }
    output(
      "muxFinder self-test: quitting left \(report.unfinishedActions.count) session action(s) "
        + "running (\(report.unfinishedActions.joined(separator: ", ")))")
  }

  // MARK: - Helpers

  /// Builds and keeps the model over an in-memory This Mac.
  private func startModel() -> AppModel {
    let made = AppModel(environment: makeEnvironment())
    model = made
    return made
  }

  /// The model's environment: This Mac in memory, an engine over the seams' discovery (no
  /// attachment checks), an attach coordinator (over `coordinatorITerm2`) whose index asks only
  /// this run's launch tabs' connections, and a shutdown that waits for session actions no
  /// longer than the attach timeout (nor than the app's own budget, so keep mode's quit stays
  /// within its deadline).
  func makeEnvironment() -> AppEnvironment {
    let seams = self.seams
    let recorder = self.recorder
    let box = coordinatorBox
    let host = self.host
    let coordinatorITerm2 = self.coordinatorITerm2
    return AppEnvironment(
      loadHosts: { .inMemory(try HostList([host])) },
      makeEngine: { hosts in RefreshCoordinator(hosts: hosts, discovery: seams.discovery) },
      makeSystemEvents: { _ in nil },
      terminate: { AppTermination.request() },
      diagnostics: seams.diagnostics,
      makeAttachCoordinator: { onUpdate in
        let index = AttachmentIndex(
          iTerm2: seams.iTerm2, clock: seams.indexClock,
          configuration: .init(includes: { connection in
            connection.owningSessionID.map(recorder.isLaunchTab) ?? false
          }))
        let coordinator = AttachCoordinator(
          iTerm2: coordinatorITerm2, discovery: seams.discovery, store: seams.store,
          helperPath: seams.helperPath, clock: seams.clock,
          configuration: seams.coordinatorConfiguration, existingAttachments: .index(index),
          sessionCreator: seams.sessionCreator, diagnostics: seams.diagnostics,
          onUpdate: { update in
            recorder.record(update)
            onUpdate(update)
          })
        box.set(coordinator)
        return coordinator
      },
      newSessionCommand: sleepCommand,
      sessionActionShutdownBudget: min(
        seams.timeouts.attach, AppModel.sessionActionShutdownBudget))
  } // End of func makeEnvironment()

  /// The test session's pane command: `sleep`, long enough for the run (an hour in keep mode,
  /// so the quit check has time), and bounded, so a session left behind ends by itself.
  var sleepCommand: [String] { ["sleep", request.keep ? "3600" : "600"] }

  /// The model and the test session's key.
  private func current() throws -> (AppModel, SessionKey) {
    guard let model, let key = sessionKey else { throw SelfTestFailure("no model or session") }
    return (model, key)
  }

  /// The attach result of the first action on `key` that ended after `mark`.
  private func attachResult(
    after mark: Int,
    for key: SessionKey,
    model: AppModel
  ) async throws -> AttachResult {
    let record = try await waitFor("the attach to end", seams.timeouts.attach) {
      model.finishedActions.dropFirst(mark).first { $0.key == key }
    }
    guard let result = record.outcome.attachResult else { throw SelfTestFailure("no attach") }
    return result
  } // End of func attachResult(after:for:model:)

  /// What keep mode prints.
  private func keepInfo() -> KeepInfo {
    KeepInfo(
      sessionName: seams.sessionName, connectionID: confirmed?.connectionID ?? "?",
      gatewaySessionID: confirmed?.gatewaySessionID ?? "?")
  }

  /// Polls `condition` every `pollInterval` until it gives a value; throws when `timeout`
  /// passes (naming `what`) or the task is cancelled.
  private func waitFor<Value>(
    _ what: String,
    _ timeout: Duration,
    _ condition: () -> Value?
  ) async throws -> Value {
    let deadline = ContinuousClock.now + timeout
    while true {
      try Task.checkCancellation()
      if let value = condition() { return value }
      guard ContinuousClock.now < deadline else {
        throw SelfTestFailure("waited \(Int(timeout / .seconds(1))) s for \(what)")
      }
      try await Task.sleep(for: seams.timeouts.pollInterval)
    }
  } // End of func waitFor(_:_:_:)

  /// An attach result in a step's failure line: its state and failure kind, and the failure's
  /// message (none holds user data).
  static func describe(_ result: AttachResult) -> String {
    guard let failure = result.failure else { return "the attach ended \(result.state.kind)" }
    let detail = failure.detail.map { " (\($0))" } ?? ""
    return "the attach failed: \(failure.kind)\(detail). \(failure.message)"
  }

  /// Writes one line of the step log.
  private func output(_ line: String) {
    seams.output(line)
  }

  /// Whole milliseconds since `start`.
  private static func milliseconds(since start: ContinuousClock.Instant) -> Int {
    milliseconds(ContinuousClock.now - start)
  }

  /// `duration` in whole milliseconds.
  private static func milliseconds(_ duration: Duration) -> Int {
    Int(duration / .milliseconds(1))
  }
}
