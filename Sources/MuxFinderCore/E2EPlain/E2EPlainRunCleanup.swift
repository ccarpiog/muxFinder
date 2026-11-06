import Foundation

// `e2e-plain`'s helpers, window closes and cleanup (PLAN.md D38 *The plain runs (I-12c3b)*): a
// window is closed only by the id the window layer's own open recorded, and only on positive
// evidence that the process it ran (the launch helper) has ended. Each helper is known by its
// launch token from the launch's own files, whatever became of its window, and cleanup asks the
// run's own helpers that still run to stop (SIGTERM) before it finishes.

extension E2EPlainRun {
  /// How closing one of the run's windows ended.
  enum CloseOutcome: Sendable, Equatable {
    /// Closed by its recorded id.
    case closed
    /// Already gone (the terminal's own settings closed it when its process ended): left as
    /// it is.
    case alreadyGone
    /// Closed before.
    case closedBefore
    /// The definition opens with `exec`, so the window has no id to close it by.
    case noWindowID
    /// Its helper still ran when the wait ended: left open.
    case helperStillRuns
    /// Its helper is not known (no early report or result), so whether its process ended
    /// cannot be told: left open.
    case helperUnknown
    /// Whether its helper still runs could not be told (the kernel's answer could not be read,
    /// or the process at its pid started after the helper's own files): left open.
    case helperUnreadable
    /// The window layer refused or failed the close (the gate's recheck among them): left.
    case refused(PlainTerminalWindowError)

    /// Whether the window is closed now (or was never the run's to close).
    var passes: Bool {
      switch self {
      case .closed, .alreadyGone, .closedBefore, .noWindowID: return true
      case .helperStillRuns, .helperUnknown, .helperUnreadable, .refused: return false
      }
    }

    /// Whether a later pass may still close it: its helper may end, or become known.
    var mayCloseLater: Bool {
      switch self {
      case .helperStillRuns, .helperUnknown, .helperUnreadable: return true
      default: return false
      }
    }

    /// The outcome in words.
    var text: String {
      switch self {
      case .closed: return "closed by its recorded id after its helper ended"
      case .alreadyGone: return "was already closed by the terminal's own settings, left as it is"
      case .closedBefore: return "was closed before"
      case .noWindowID: return "has no id (an exec definition), left to the terminal"
      case .helperStillRuns: return "left open: its helper still runs"
      case .helperUnknown: return "left open: its helper is not known, so it may still run"
      case .helperUnreadable:
        return "left open: whether its helper still runs could not be read, so it may still run"
      case .refused(let error): return "left open: the close was refused (\(error.kind))"
      }
    } // End of var text
  } // End of enum CloseOutcome

  // MARK: - Helpers

  /// Records the helper of `launchID` from the launch's early report or, when there is none,
  /// its result (both peeked, never taken), unless it is recorded already; returns the record
  /// (`nil` while neither file names one).
  @discardableResult
  func trackHelper(of launchID: LaunchToken) -> HelperProcess? {
    if let known = helpers[launchID] { return known }
    if let report = try? parts.store.peekReport(launchID) {
      helpers[launchID] = HelperProcess(
        processID: report.helperPID, aliveAt: report.attachChildStartTime)
    } else if let result = try? parts.store.peekResult(launchID),
      let endedAt = Self.startTime(of: result.endedAt)
    {
      helpers[launchID] = HelperProcess(processID: result.helperPID, aliveAt: endedAt)
    }
    return helpers[launchID]
  } // End of func trackHelper(of:)

  /// Records the helper of every launch of the run that has none yet (`trackHelper(of:)`), by
  /// launch token: independently of the windows, so a launch whose open returned an error keeps
  /// its helper too; called before any launch file is removed.
  func trackHelpers() {
    for launchID in launchIDs { trackHelper(of: launchID) }
  }

  /// Whether the helper of `launchID` runs, ended or is not known to do either, as the kernel
  /// shows its pid now; `nil` when the run knows no helper of the launch. A helper first seen
  /// running, started no later than its `aliveAt`, gets that start time recorded: from then on
  /// its pid with another start time means it ended.
  func liveness(ofHelperOf launchID: LaunchToken) -> HelperLiveness? {
    guard var helper = helpers[launchID] else { return nil }
    switch parts.processes.state(of: helper.processID) {
    case .absent:
      return .ended
    case .unreadable:
      return .unknown
    case .running(let start):
      if let known = helper.start { return start == known ? .running : .ended }
      guard Self.started(start, noLaterThan: helper.aliveAt) else { return .unknown }
      helper.start = start
      helpers[launchID] = helper
      return .running
    }
  } // End of func liveness(ofHelperOf:)

  /// Waits up to `limit` for the helper of `launchID` to end; returns how it stands then (`nil`
  /// when the run knows no helper of the launch).
  func waitForHelper(of launchID: LaunchToken, within limit: Duration) async -> HelperLiveness? {
    let deadline = ContinuousClock.now + limit
    while true {
      guard let now = liveness(ofHelperOf: launchID) else { return nil }
      guard now != .ended, ContinuousClock.now < deadline,
        (try? await Task.sleep(for: parts.budgets.pollInterval)) != nil
      else { return now }
    } // End of loop waiting for the helper
  } // End of func waitForHelper(of:within:)

  /// Whether a helper of the run may still run: one that runs, or one whose state is unknown.
  func helpersMayRun() -> Bool {
    launchIDs.contains {
      switch liveness(ofHelperOf: $0) {
      case .running?, .unknown?: return true
      case .ended?, nil: return false
      }
    }
  }

  /// Waits up to `limit`, one deadline for all, until no helper of the run may still run.
  func waitForHelpers(within limit: Duration) async {
    let deadline = ContinuousClock.now + limit
    while helpersMayRun(), ContinuousClock.now < deadline {
      guard (try? await Task.sleep(for: parts.budgets.pollInterval)) != nil else { return }
    }
  }

  /// Asks every helper of the run's that still runs, each positively identified (its own
  /// files' pid, with the start time the kernel showed while it ran), to stop: SIGTERM, which
  /// finishes a failed helper's wait for Return (PLAN.md D14), sent again every
  /// `helperSignalInterval` until it ended or `Budgets.helperShutdown` passed. Never types into
  /// or closes a window, and leaves a helper whose state is unknown alone.
  func stopHelpers(actions: inout [String]) async {
    let deadline = ContinuousClock.now + parts.budgets.helperShutdown
    var asked = Set<LaunchToken>()
    var sent = 0
    var nextSignal = ContinuousClock.now
    while ContinuousClock.now < deadline {
      let running = launchIDs.filter { liveness(ofHelperOf: $0) == .running }
      guard !running.isEmpty else { break }
      if ContinuousClock.now >= nextSignal {
        for launchID in running {
          guard let helper = helpers[launchID], let start = helper.start,
            parts.processes.terminate(
              helper.processID, startedAt: start, executable: parts.helperPath.path)
          else { continue }
          asked.insert(launchID)
          sent += 1
        } // End of loop over the helpers that still run
        nextSignal = ContinuousClock.now + Self.helperSignalInterval
      }
      guard (try? await Task.sleep(for: parts.budgets.pollInterval)) != nil else { break }
    } // End of loop asking the helpers to stop
    if !asked.isEmpty {
      actions.append(
        "asked \(asked.count) helper(s) of the run's own that still ran to stop (\(sent) SIGTERM)")
    }
  } // End of func stopHelpers(actions:)

  /// Whether `start` is no later than `bound`.
  static func started(_ start: ProcessStartTime, noLaterThan bound: ProcessStartTime) -> Bool {
    (start.seconds, start.microseconds) <= (bound.seconds, bound.microseconds)
  }

  /// `date` as a start time to compare with the kernel's (whole microseconds, rounded down), or
  /// `nil` when it is before 1970 or too far ahead to be one.
  static func startTime(of date: Date) -> ProcessStartTime? {
    let interval = date.timeIntervalSince1970
    guard interval.isFinite, interval >= 0, interval < 1e12 else { return nil }
    let seconds = interval.rounded(.down)
    let microseconds = min(((interval - seconds) * 1_000_000).rounded(.down), 999_999)
    return ProcessStartTime(seconds: Int64(seconds), microseconds: Int32(microseconds))
  }

  // MARK: - Windows

  /// Closes the window `launchID` opened, by the id the window layer recorded, once its helper
  /// has ended (waiting up to `limit`, by default `Budgets.helperEnd`); never while it may still
  /// run: only an absent pid, or the pid with another start time than the helper's, counts as
  /// ended. A helper not known yet is read from the launch's own files (`trackHelper(of:)`).
  func closeWindow(
    of launchID: LaunchToken,
    waiting limit: Duration? = nil
  ) async -> CloseOutcome {
    syncWindows()
    guard let index = openedWindows.firstIndex(where: { $0.launchID == launchID }) else {
      return .closedBefore
    }
    guard !openedWindows[index].closed else { return .closedBefore }
    guard trackHelper(of: launchID) != nil else { return .helperUnknown }
    switch await waitForHelper(of: launchID, within: limit ?? parts.budgets.helperEnd) {
    case .ended?: break
    case .running?: return .helperStillRuns
    case .unknown?, nil: return .helperUnreadable
    }
    let window = openedWindows[index].window
    guard window.windowID != nil else {
      openedWindows[index].closed = true
      return .noWindowID
    }
    let loaded = parts.loaded
    let layer = parts.windows
    let closing = await MainActor.run { () -> Result<Void, PlainTerminalWindowError> in
      do throws(PlainTerminalWindowError) {
        try layer.close(window, of: loaded)
        return .success(())
      } catch {
        return .failure(error)
      }
    }
    switch closing {
    case .success:
      openedWindows[index].closed = true
      return .closed
    case .failure(.windowGone):
      openedWindows[index].closed = true
      return .alreadyGone
    case .failure(let error):
      if let refusal = Self.gateRefusal(in: error) { gateRefusal = refusal }
      return .refused(error)
    }
  } // End of func closeWindow(of:waiting:)

  /// The window layer's error in `failure` when it came after the open's Apple event was sent
  /// (the script's open handler raised, its call failed or timed out, or it answered something
  /// its contract does not allow), so the script may have opened the window and started the
  /// helper first; `nil` for every other failure (nothing was sent, or the open never ran).
  static func uncertainOpen(_ failure: AttachFailure) -> PlainTerminalWindowError? {
    guard case .terminalWindow(let error) = failure else { return nil }
    switch error {
    case .scriptFailed(_, .callFailed(handler: .open, _)), .malformedReply(_, handler: .open):
      return error
    default:
      return nil
    }
  }

  // MARK: - Cleanup

  /// Step 9, on every way out (never cancels itself), in this order:
  /// 1. the run's own plain control clients are ended (`stop()`);
  /// 2. the backend's own client, if it still holds one, is detached with the bound detach;
  /// 3. every launch's helper is recorded by launch token from its own files, windows or not;
  /// 4. each window the run opened and did not close yet is closed by its recorded id once its
  ///    helper ended (never while it may still run; left open otherwise);
  /// 5. the run's session is killed, only while it is still exactly the created one;
  /// 6. helpers that may still run get `Budgets.helperEnd` to end (the session's end may end
  ///    them), then those still running, positively identified, are asked to stop
  ///    (`stopHelpers(actions:)`), and the windows left in 4 get one more chance;
  /// 7. a launch with no recorded window although one may be open (a helper ran for it, or its
  ///    open failed after its Apple event) is reported;
  /// 8. the helper results nobody took are taken, requests nobody took withdrawn, and the early
  ///    reports of ended helpers removed;
  /// 9. then it checks that none of its launch files, control clients or helpers is left, and,
  ///    when step 1 ran, that its session is gone (a listing that fails cannot show that), and
  ///    prints what is left to do by hand.
  public func cleanUp() async {
    let start = ContinuousClock.now
    var actions: [String] = []
    var problems: [String] = []
    var byHand: [String] = []
    await stopControlClients(actions: &actions, problems: &problems)
    await detachOwnClient(actions: &actions, problems: &problems)
    syncWindows()
    trackHelpers()
    let first = await closeOpenWindows(
      waiting: parts.budgets.helperEnd, skipping: [], actions: &actions)
    await killTestSession(actions: &actions, problems: &problems)
    syncWindows()
    trackHelpers()
    if helpersMayRun() {
      await waitForHelpers(within: parts.budgets.helperEnd)
      await stopHelpers(actions: &actions)
    }
    let final = first.filter { !$0.outcome.mayCloseLater }
    let left =
      final
      + (await closeOpenWindows(
        waiting: .zero, skipping: Set(final.map(\.launchID)), actions: &actions))
    for (launchID, outcome) in left {
      let window = openedWindows.first { $0.launchID == launchID }?.window
      problems.append("the window of launch \(launchID) \(outcome.text)")
      byHand.append(
        "close the \(parts.loaded.definition.displayName) window \(window?.windowID ?? "-") "
          + "by hand once nothing runs in it (never type into it)")
    } // End of loop over the windows left open
    reportWindowlessLaunches(problems: &problems, byHand: &byHand)
    cleanLaunchFiles(actions: &actions)
    problems += verifyClean()
    await checkSessionGone(problems: &problems, byHand: &byHand)
    let elapsed = Self.milliseconds(ContinuousClock.now - start)
    let summary = actions.isEmpty ? "nothing to clean" : actions.joined(separator: ", ")
    if problems.isEmpty, setUp {
      passedCount += 1
      output(
        "PASS \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); no test session, launch "
          + "file, control client, helper or window of the run left")
    } else {
      let reason = problems.isEmpty ? "setup failed" : problems.joined(separator: "; ")
      output("FAIL \(Self.stepCount) cleanup (\(elapsed) ms): \(summary); \(reason)")
    }
    for line in byHand { output("  \(line)") }
  } // End of func cleanUp()

  /// Ends every plain control client of the run's own that still runs.
  func stopControlClients(actions: inout [String], problems: inout [String]) async {
    var stopped = 0
    for client in controlClients where client.isRunning {
      let ended = await client.stop()
      stopped += 1
      if ended == nil { problems.append("a control client of the run could not be reaped") }
    } // End of loop over the run's control clients
    if stopped > 0 { actions.append("ended \(stopped) control client(s) of the run's own") }
  } // End of func stopControlClients(actions:problems:)

  /// Detaches the backend's own client of the session with its bound detach, if it holds one.
  func detachOwnClient(actions: inout [String], problems: inout [String]) async {
    guard let target, await backend.attachment(of: target.key) != nil else { return }
    let result = await backend.detach(session: target.key, on: parts.host)
    record = nil
    actions.append("detached the backend's client (\(result.outcome.rawValue))")
    switch result.outcome {
    case .detached, .notSent, .nothingAttached: break
    default: problems.append("the backend's detach ended \(result.outcome.rawValue)")
    }
  } // End of func detachOwnClient(actions:problems:)

  /// Closes every window of the run not closed yet and not in `skipping` (each once its helper
  /// ended, waiting up to `limit` for it) and returns those left open, with why.
  func closeOpenWindows(
    waiting limit: Duration,
    skipping: Set<LaunchToken>,
    actions: inout [String]
  ) async -> [(launchID: LaunchToken, outcome: CloseOutcome)] {
    var left: [(launchID: LaunchToken, outcome: CloseOutcome)] = []
    let pending = openedWindows.filter { !$0.closed && !skipping.contains($0.launchID) }
    for launchID in pending.map(\.launchID) {
      let outcome = await closeWindow(of: launchID, waiting: limit)
      if outcome.passes {
        actions.append("its window \(outcome.text)")
      } else {
        left.append((launchID, outcome))
      }
    } // End of loop over the windows not closed yet
    return left
  } // End of func closeOpenWindows(waiting:skipping:actions:)

  /// Kills the test session, the one step 1 recorded or, when its output was lost, the one
  /// found by its exact name, only while it is still exactly that session (the check in the
  /// same tmux command as the kill). Whether it is gone is checked afterwards
  /// (`checkSessionGone(problems:byHand:)`).
  func killTestSession(actions: inout [String], problems: inout [String]) async {
    if created == nil, case .found(let recovered) = await recoverCreatedSession() {
      created = recovered
      actions.append("found the test session by its name")
    }
    guard let created, let arguments = created.killIfUnchangedArguments,
      created.name == sessionName
    else { return }
    let result = try? await parts.tmux.run(arguments)
    let outcome = result.map {
      CreatedSession.killOutcome(
        exitStatus: $0.status, standardOutput: $0.standardOutput,
        standardError: $0.standardError)
    }
    switch outcome {
    case .killed?: actions.append("killed \(created.sessionID)")
    case .notThisSession?: actions.append("\(created.sessionID) was already gone")
    default: problems.append("kill-session failed")
    }
  } // End of func killTestSession(actions:problems:)

  /// Reports each launch of the run with no window it knows of, although a window may be open
  /// for it: a helper ran for it (its own files named one), or its open failed after the Apple
  /// event was sent (`uncertainOpen(_:)`), so the script may have opened a window and started
  /// the helper before the error or the lost reply. Such a window has no recorded id, so the
  /// run never closes it: each is a problem, with what to do by hand.
  func reportWindowlessLaunches(problems: inout [String], byHand: inout [String]) {
    let windowed = Set(openedWindows.map(\.launchID))
    for launchID in launchIDs where !windowed.contains(launchID) {
      let why: String
      if helpers[launchID] != nil {
        why = "a helper ran for it"
      } else if let failure = updates.failure(of: launchID),
        let error = Self.uncertainOpen(failure)
      {
        why = "its open failed (\(error.kind)) after the Apple event was sent"
      } else {
        continue
      }
      problems.append(
        "launch \(launchID) recorded no window although \(why), so a window of the run's may be "
          + "open")
      byHand.append(
        "look for a \(parts.loaded.definition.displayName) window of launch \(launchID) and "
          + "close it by hand once nothing runs in it (never type into it)")
    } // End of loop over the launches with no recorded window
  } // End of func reportWindowlessLaunches(problems:byHand:)

  /// Takes the helper results nobody took (each with its early report), withdraws the requests
  /// nobody took, and removes the early reports of helpers that ended; every helper is recorded
  /// from those files first (`trackHelpers()`).
  func cleanLaunchFiles(actions: inout [String]) {
    syncWindows()
    trackHelpers()
    var results = 0
    var requests = 0
    var reports = 0
    for launchID in launchIDs {
      if (try? parts.store.takeResult(launchID)) != nil { results += 1 }
      if (try? parts.store.discardRequest(launchID)) == true { requests += 1 }
      if liveness(ofHelperOf: launchID) == .ended,
        (try? parts.store.removeReport(launchID)) == true
      {
        reports += 1
      }
    } // End of loop over the run's launches
    if results > 0 { actions.append("took \(results) helper result(s) nobody took") }
    if requests > 0 { actions.append("withdrew \(requests) request(s) nobody took") }
    if reports > 0 { actions.append("removed \(reports) early report(s) of ended helpers") }
  } // End of func cleanLaunchFiles(actions:)

  /// What is left of the run: its launch files, control clients and helpers (every launch's,
  /// windows or not; one whose state is unknown counts as left).
  func verifyClean() -> [String] {
    var problems: [String] = []
    let directory = parts.store.directory
    let names = launchIDs.flatMap {
      [
        LaunchStore.requestFileName(for: $0), LaunchStore.reportFileName(for: $0),
        LaunchStore.resultFileName(for: $0),
      ]
    }
    let files = names.filter {
      FileManager.default.fileExists(
        atPath: directory.appending(path: $0).path(percentEncoded: false))
    }
    if !files.isEmpty { problems.append("\(files.count) launch file(s) of the run left") }
    let running = controlClients.filter(\.isRunning).count
    if running > 0 { problems.append("\(running) control client(s) of the run still running") }
    let states = launchIDs.compactMap { liveness(ofHelperOf: $0) }
    let helpersRunning = states.filter { $0 == .running }.count
    if helpersRunning > 0 {
      problems.append("\(helpersRunning) helper(s) of the run still running")
    }
    let unknown = states.filter { $0 == .unknown }.count
    if unknown > 0 {
      problems.append(
        "\(unknown) helper(s) of the run whose process could not be read, so they may still run")
    }
    return problems
  } // End of func verifyClean()

  /// Checks, after cleanup and only once step 1 ran (so a session may exist), that the run's
  /// session is gone from its host: absent only when `list-sessions` ran and does not list it,
  /// or tmux answered that no server runs; a listing that failed is a problem too, since
  /// whether the session is gone cannot be established.
  func checkSessionGone(problems: inout [String], byHand: inout [String]) async {
    guard creationStartedAt != nil else { return }
    let place = "tmux \(parts.tmux.location)"
    guard let names = await listSessions(format: "#{session_name}") else {
      problems.append(
        "whether the test session is gone could not be established (list-sessions failed)")
      byHand.append(
        "look for the session \(sessionName) (\(place)) and kill it by hand if it is there")
      return
    }
    guard names.contains(sessionName) else { return }
    problems.append("the test session still exists")
    byHand.append("kill the session \(sessionName) (\(place)) by hand")
  } // End of func checkSessionGone(problems:byHand:)
} // End of extension E2EPlainRun
